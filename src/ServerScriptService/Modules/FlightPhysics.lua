--[[
	FlightPhysics (ModuleScript, SERVER)
	Location: ServerScriptService > Modules > FlightPhysics

	Controls the flight of an assembled rocket (RocketAssembler):
	  • VectorForce "FlightForce"       — thrust + aerodynamic drag + real gravity
	  • AlignOrientation "FlightAttitude" — smooth rocket pitch (W/S/A/D from the client)

	HOW IT IS COMPUTED (every Heartbeat):
	  1) Air pressure changes thrust and Isp:  T = T_vac − (T_vac − T_sl)·(ρ/ρ0)
	  2) Fuel flow:  ṁ = T / (Isp · g0),   Δm = ṁ · Δt
	  3) Rocket mass = Σ (DryMass + FuelMass) of all groups still attached → fuel burns off,
	     the mass drops, and TWR = T/(m·g) and the acceleration GROW during flight.
	  4) Air density:  ρ(h) = ρ0 · e^(−h/H) · (1 − h/h_top),  ρ = 0 above the Kármán line
	  5) Drag:  D = ½ · ρ · v² · Cd · A   (against the velocity)
	  6) Gravity decreases with altitude:  g(h) = g0 · (R / (R + h))²
	  7) a = (T·û + D) / m + g      — in REAL m/s²
	     a_studs = a / METERS_PER_STUD  (flight scale, see NASAData.Flight)
	     VectorForce = AssemblyMass · (a_studs + g_Roblox·ŷ)
	     Adding g_Roblox cancels Roblox's built-in gravity (196.2 studs/s²), so the rocket moves
	     with EXACTLY the acceleration a, and the physical mass of the Roblox parts has no effect.
	     🔧 BLENDER: so replacing the meshes will not change how the rocket behaves.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))

local G0 = NASAData.Constants.G0
local SIZE_M_PER_STUD = NASAData.Constants.METERS_PER_STUD -- part size scale (0.28 m)
local F = NASAData.Flight
local M_PER_STUD = F.METERS_PER_STUD                        -- altitude scale in flight (12.5 m)
local EARTH = NASAData.Planets.Earth
local RHO0 = EARTH.atmosphereDensity

--------------------------------------------------------------------
-- ⚙️ CONTROL SETTINGS
--------------------------------------------------------------------
local TURN_RATE = math.rad(12)          -- rad/s: how fast the target pitch changes
local MAX_TILT = math.rad(90)           -- no tilting past the horizon
local TELEMETRY_INTERVAL = 0.1          -- s: how often to update HUD attributes

local FlightPhysics = {}
FlightPhysics.__index = FlightPhysics

--------------------------------------------------------------------
-- Formulas
--------------------------------------------------------------------
-- ρ(h): exponential atmosphere, smoothly brought to zero at the Kármán line
function FlightPhysics.AirDensity(altitudeM)
	local top = F.ATMOSPHERE_TOP_KM * 1000
	if altitudeM >= top then
		return 0
	end
	local h = math.max(altitudeM, 0)
	return RHO0 * math.exp(-h / F.SCALE_HEIGHT_M) * (1 - h / top)
end

function FlightPhysics.AltitudeM(model, position)
	return math.max(position.Y - (model:GetAttribute("PadY") or 0), 0) * M_PER_STUD
end

--------------------------------------------------------------------
-- Creating a flight
--------------------------------------------------------------------
function FlightPhysics.new(model, callbacks)
	local core = model.PrimaryPart
	local coreAtt = core:FindFirstChild("FlightCore")

	local self = setmetatable({}, FlightPhysics)
	self.model = model
	self.core = core
	self.coreAtt = coreAtt
	self.callbacks = callbacks or {}
	self.activeStage = 1
	self.engineOn = false
	self.inputOmega = Vector3.zero         -- turn request (world axis × strength 0…1.8) from W/S/A/D/Q/E
	self.targetCF = coreAtt.WorldCFrame.Rotation -- target rocket orientation (6DOF, unconstrained)
	self.attitudeMode = "sas"             -- "sas" | "free" | "retrograde" | "radial"
	self.gravityVec = Vector3.new(0, -NASAData.Planets.Earth.surfaceGravity, 0)
	self.upAt = Vector3.yAxis
	model:SetAttribute("AttitudeMode", "sas")
	self.liftedOff = false
	self.apogeeM = 0
	self.maxSpeed = 0
	self.time = 0
	self.telemetryTimer = 0
	self.ended = false
	self.lastThrust = 0
	self.speedLog = {}
	self.landed = false
	self.startY = core.Position.Y -- lift-off is measured from the capsule's start position, not from the table level
	self.throttle = 1
	model:SetAttribute("Throttle", 1)
	self.gravity = NASAData.Planets.Earth.surfaceGravity

	-- The diameter for the drag area uses the part scale (1 stud = 0.28 m)
	local diameterM = (model:GetAttribute("MaxDiameter") or 4) * SIZE_M_PER_STUD
	self.area = math.pi * (diameterM / 2) ^ 2

	-- The capsule (core) is above the rocket bottom: "ground contact" = the core is no higher than this (+4 studs margin)
	local base = model:GetAttribute("BasePosition") or core.Position
	self.groundContactM = (core.Position.Y - base.Y + 4) * M_PER_STUD

	local force = Instance.new("VectorForce")
	force.Name = "FlightForce"
	force.Attachment0 = coreAtt
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true -- no torque: orientation is handled by AlignOrientation
	force.Force = Vector3.zero
	force.Parent = core
	self.force = force

	local align = Instance.new("AlignOrientation")
	align.Name = "FlightAttitude"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = coreAtt
	align.MaxTorque = math.huge
	align.MaxAngularVelocity = 1.5
	align.Responsiveness = 15
	align.CFrame = self.targetCF
	align.Parent = core
	self.align = align

	-- RCS attitude thrusters (Draco): more of them turn the rocket faster, and while turning
	-- they fire short white jets of cold gas
	self.rcsPuffs = {}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p.Name == "rcs_draco" then
			local a = Instance.new("Attachment")
			a.Name = "RCSNozzle"
			a.Parent = p
			local e = Instance.new("ParticleEmitter")
			e.Name = "RCSPuff"
			e.Texture = "rbxasset://textures/particles/smoke_main.dds"
			e.Color = ColorSequence.new(Color3.fromRGB(240, 245, 255))
			e.Size = NumberSequence.new(0.4, 1.4)
			e.Transparency = NumberSequence.new(0.2, 1)
			e.Lifetime = NumberRange.new(0.25, 0.4)
			e.Speed = NumberRange.new(14, 20)
			e.SpreadAngle = Vector2.new(180, 180)
			e.Rate = 40
			e.Enabled = false
			e.Parent = a
			table.insert(self.rcsPuffs, e)
		end
	end
	self.rcsCount = #self.rcsPuffs
	model:SetAttribute("RCSCount", self.rcsCount)
	self.turnRate = math.rad(10)

	model:SetAttribute("ActiveStage", 1)
	return self
end

--------------------------------------------------------------------
-- Stages and mass
--------------------------------------------------------------------
function FlightPhysics:GetStage(k)
	return self.model:FindFirstChild("Stage" .. (k or self.activeStage))
end

-- Mass in kg = everything still flying in the model (separated groups are moved out of the model)
function FlightPhysics:MassKg()
	local m = 0
	for _, g in ipairs(self.model:GetChildren()) do
		if g:IsA("Folder") then
			m += (g:GetAttribute("DryMass") or 0) + (g:GetAttribute("FuelMass") or 0)
		end
	end
	return math.max(m, 1)
end

local function setEngineFX(stage, on)
	if not stage then
		return
	end
	for _, d in ipairs(stage:GetDescendants()) do
		if d.Name == "Flame" and d:IsA("ParticleEmitter") then
			d.Enabled = on
		elseif d.Name == "EngineLight" and d:IsA("PointLight") then
			d.Enabled = on
		end
	end
end

-- Ignite the engines of the active stage (if there is an engine and fuel)
function FlightPhysics:Ignite()
	local stage = self:GetStage()
	if not stage or (stage:GetAttribute("Thrust") or 0) <= 0 or (stage:GetAttribute("FuelMass") or 0) <= 0 then
		self.engineOn = false
		self.model:SetAttribute("EngineOn", false)
		return false
	end
	self.engineOn = true
	self.fxKey = nil
	setEngineFX(stage, true)
	self.model:SetAttribute("EngineOn", true)
	return true
end

function FlightPhysics:Shutdown()
	self.engineOn = false
	self.fxKey = nil
	setEngineFX(self:GetStage(), false)
	self.model:SetAttribute("EngineOn", false)
end

-- Called by StageController after separation
function FlightPhysics:SetActiveStage(k)
	self.activeStage = k
	self.model:SetAttribute("ActiveStage", k)
end

-- Turn request from the player: a world vector (turn axis × key strength)
function FlightPhysics:SetInput(omega)
	self.inputOmega = omega
end

-- Attitude modes:
--   sas        — stability assist: holds the last direction, the keys rotate it
--   free       — no stabilisation: the rocket spins by inertia, the keys add rotation (RCS)
--   retrograde — auto-pointing nozzle first (nose against the velocity) — for braking
--   radial     — nozzle towards the planet (nose away from its centre) — for landing anywhere on a sphere
local MODES = { sas = true, free = true, retrograde = true, radial = true }
function FlightPhysics:SetAttitudeMode(mode)
	if not MODES[mode] then
		return
	end
	if mode == "sas" or mode == "free" then
		self.targetCF = self.coreAtt.WorldCFrame.Rotation -- hold where we are pointing now
	end
	self.attitudeMode = mode
	self.model:SetAttribute("AttitudeMode", mode)
end

-- Turn rate: capsule gyroscopes + every RCS Draco; a heavier rocket (larger moment
-- of inertia) turns slower:  ω = (10° + 8°·N_RCS)/s · √(8000 kg / m)
function FlightPhysics:UpdateTurnRate(massKg)
	local baseDeg = 10 + 8 * self.rcsCount
	self.turnRate = math.rad(baseDeg) * math.clamp(math.sqrt(8000 / math.max(massKg, 1)), 0.35, 1.6)
end

function FlightPhysics:UpdateAttitude(dt, vel, massKg)
	self:UpdateTurnRate(massKg)
	local rate = self.turnRate
	local omega = self.inputOmega
	local hasInput = omega.Magnitude > 0.01
	local turning = false
	if not self.liftedOff then
		-- at lift-off the rocket holds vertical
		self.align.Enabled = true
		self.align.CFrame = self.targetCF
		return
	end
	local mode = self.attitudeMode
	if hasInput and (mode == "retrograde" or mode == "radial") then
		self:SetAttitudeMode("sas") -- manual control cancels auto-pointing
		mode = "sas"
	end

	if mode == "free" then
		-- no stabilisation: the keys spin up / slow down the rotation, then it continues by inertia
		self.align.Enabled = false
		if hasInput then
			self.core.AssemblyAngularVelocity += omega * rate * dt
			turning = true
		end
		self.targetCF = self.coreAtt.WorldCFrame.Rotation
	else
		self.align.Enabled = true
		if mode == "retrograde" or mode == "radial" then
			local dir = (mode == "radial" and self.upAt) or (vel.Magnitude > 1 and -vel.Unit) or nil
			if dir then
				local nose = self.targetCF.UpVector
				local angle = math.acos(math.clamp(nose:Dot(dir), -1, 1))
				local axis = nose:Cross(dir)
				if angle > 1e-3 then
					if axis.Magnitude < 1e-5 then
						axis = self.targetCF.RightVector -- target directly behind: any perpendicular axis will do
					end
					self.targetCF = CFrame.fromAxisAngle(axis.Unit, math.min(angle, rate * dt)) * self.targetCF
					turning = angle > math.rad(2)
				end
			end
		elseif hasInput then
			local strength = math.min(omega.Magnitude, 1.5)
			self.targetCF = CFrame.fromAxisAngle(omega.Unit, strength * rate * dt) * self.targetCF
			turning = true
		end
		self.align.CFrame = self.targetCF
		self.align.MaxAngularVelocity = rate * 1.6
	end
	if turning ~= self.rcsOn then
		self.rcsOn = turning
		for _, e in ipairs(self.rcsPuffs) do
			if e.Parent then
				e.Enabled = turning
			end
		end
	end
end

-- Throttle 0…1 (Shift/Ctrl — up/down, Z — full, X — cut)
function FlightPhysics:SetThrottle(t)
	self.throttle = math.clamp(t, 0, 1)
	self.model:SetAttribute("Throttle", self.throttle)
end

-- The flame is proportional to the throttle; at 0% the engine visually "goes out"
function FlightPhysics:UpdateFlameFX()
	local key = self.engineOn and math.floor(self.throttle * 20 + 0.5) or -1
	if key == self.fxKey then
		return
	end
	self.fxKey = key
	local stage = self:GetStage()
	if not stage then
		return
	end
	local on = self.engineOn and self.throttle > 0.02
	for _, d in ipairs(stage:GetDescendants()) do
		if d.Name == "Flame" and d:IsA("ParticleEmitter") then
			d.Enabled = on
			d.Rate = 20 + 70 * self.throttle
		elseif d.Name == "EngineLight" and d:IsA("PointLight") then
			d.Enabled = on
			d.Brightness = 1 + 3 * self.throttle
		end
	end
end

--------------------------------------------------------------------
-- PHYSICS STEP
--------------------------------------------------------------------
function FlightPhysics:Step(dt)
	local model, core = self.model, self.core
	if self.ended then
		return
	end
	if not model.Parent or not core.Parent or core.Parent.Parent ~= model then
		self:Stop("lost")
		return
	end
	self.time += dt

	local pos = core.Position
	local velStuds = core.AssemblyLinearVelocity
	local altitudeM = FlightPhysics.AltitudeM(model, pos)
	local vel = velStuds * M_PER_STUD                   -- m/s
	local rho = FlightPhysics.AirDensity(altitudeM)
	if self.callbacks.density then
		rho = self.callbacks.density(pos, rho) -- e.g. the thin Mars atmosphere
	end
	local pressure = rho / RHO0                          -- 1 near Earth, 0 in space

	-- 1–2) Thrust and fuel flow of the active stage
	local thrust = 0
	local stage = self:GetStage()
	if self.engineOn and stage then
		local tSL, tVac = stage:GetAttribute("Thrust"), stage:GetAttribute("ThrustVac")
		local iSL, iVac = stage:GetAttribute("Isp"), stage:GetAttribute("IspVac")
		-- throttle 0…100%: thrust and fuel flow are proportional to it (Isp does not change)
		local T = (tVac - (tVac - tSL) * pressure) * self.throttle
		local isp = iVac - (iVac - iSL) * pressure
		local mdot = T / (isp * G0)                      -- ṁ = F / (Isp · g0), kg/s
		local burn = mdot * dt
		local fuel = stage:GetAttribute("FuelMass") or 0
		if fuel <= burn then
			-- fuel ran out mid-step: thrust only for part of the step
			thrust = burn > 0 and T * fuel / burn or 0
			stage:SetAttribute("FuelMass", 0)
			self:Shutdown()
			if self.callbacks.onBurnout then
				task.spawn(self.callbacks.onBurnout, self, self.activeStage)
			end
		else
			stage:SetAttribute("FuelMass", fuel - burn)
			thrust = T
		end
	end
	self.lastThrust = thrust
	-- re-ignition: the engine is off, but the player raised the throttle and the stage still has fuel
	if not self.engineOn and self.throttle > 0 and stage and (stage:GetAttribute("FuelMass") or 0) > 0 then
		self:Ignite()
	end
	self:UpdateFlameFX()

	-- 3) Current rocket mass
	local massKg = self:MassKg()

	-- 4–5) Aerodynamic drag  D = ½·ρ·v²·Cd·A
	local speed = vel.Magnitude
	local dragAccel = Vector3.zero
	if rho > 0 and speed > 0.1 then
		local D = 0.5 * rho * speed * speed * F.DRAG_COEFFICIENT * self.area
		local aD = D / massKg
		-- numerical stability guard: drag cannot reverse the velocity in a single step
		aD = math.min(aD, speed / math.max(dt, 1 / 240) * 0.5)
		dragAccel = -vel.Unit * aD
	end

	-- 6) Gravity is a VECTOR: near Earth it points down (−Y), near the Moon/Mars — to the planet centre:
	--    g = g_surface · (R / r)²  (PlanetZoneManager.GravityVector)
	local gEarth = NASAData.GravityAtAltitude("Earth", altitudeM)
	local gVec = Vector3.new(0, -gEarth, 0)
	if self.callbacks.gravityVector then
		gVec = self.callbacks.gravityVector(pos, gEarth)
	end
	local g = gVec.Magnitude
	self.gravity = g
	self.gravityVec = gVec
	self.upAt = g > 1e-6 and -gVec.Unit or Vector3.yAxis

	-- 7) Acceleration and force for Roblox
	local up = self.coreAtt.WorldCFrame.UpVector           -- actual rocket axis
	-- 6b) EDL: parachute (extra drag) and autoland (controls the throttle) — EDLBrakingSystems
	local edlAccel = Vector3.zero
	if self.callbacks.edl then
		local availT = 0
		local st = self:GetStage()
		if st and (st:GetAttribute("FuelMass") or 0) > 0 then
			local tSL, tVac = st:GetAttribute("Thrust") or 0, st:GetAttribute("ThrustVac") or 0
			availT = tVac - (tVac - tSL) * pressure
		end
		edlAccel = self.callbacks.edl(self, dt, {
			vel = vel, rho = rho, massKg = massKg, gVec = gVec, up = self.upAt, thrustAvail = availT,
		})
	end

	-- All accelerations are in REAL m/s² (rocket mass in kg from attributes), and the force for Roblox =
	-- AssemblyMass · a: so both thrust and free fall have exact NASA accelerations regardless of part mass.
	-- Without thrust only gravity and drag act here (no LinearVelocity that would slow the fall).
	local accel = up * (thrust / massKg) + dragAccel + gVec + edlAccel -- m/s²
	local accelStuds = accel / M_PER_STUD
	local assemblyMass = core.AssemblyMass
	self.force.Force = assemblyMass * (accelStuds + Vector3.new(0, workspace.Gravity, 0))

	-- 6DOF orientation (see UpdateAttitude)
	self:UpdateAttitude(dt, vel, massKg)

	-- Flight state
	-- lift-off = rose 30 m above the start position (the capsule sits high above the table, so
	-- previously the rocket counted as "launched" while still on the table and "landed" after 0.5 s on a slow start)
	if not self.liftedOff and (pos - Vector3.new(pos.X, self.startY, pos.Z)).Y * M_PER_STUD > 30 then
		self.liftedOff = true
	end
	if altitudeM > self.apogeeM then
		self.apogeeM = altitudeM
	end
	self.maxSpeed = math.max(self.maxSpeed, speed)

	if not self.reachedTarget and altitudeM >= F.TARGET_ALTITUDE_KM * 1000 then
		self.reachedTarget = true
		if self.callbacks.onTargetReached then
			task.spawn(self.callbacks.onTargetReached, self)
		end
	end
	if altitudeM >= F.MAX_ALTITUDE_KM * 1000 then
		self:Stop("maxAltitude")
		return
	end
	-- Ground impact: after lift-off the rocket suddenly stopped near the ground.
	-- The speed before stopping decides: crash or soft landing.
	-- Impact speed = maximum descent speed in the last ~100 m above the ground
	-- (during the impact itself the rocket bounces and slows, so the instantaneous speed is not suitable)
	if altitudeM > self.groundContactM + 200 then
		self.approachSpeed = 0
	elseif vel.Y < 0 and altitudeM < self.groundContactM + 100 then
		self.approachSpeed = math.max(self.approachSpeed or 0, speed)
	end
	-- speed log for the last 2 s — for the impact speed on the crater surface
	table.insert(self.speedLog, { self.time, speed })
	while self.speedLog[1] and self.time - self.speedLog[1][1] > 2 do
		table.remove(self.speedLog, 1)
	end
	-- impact speed: ≤ 15 m/s — soft landing, ≤ 25 — hard (damaged legs), more — crash
	local maxSafe = NASAData.Modules.landing_legs.maxLandingSpeed * 3
	local maxHard = maxSafe + 10
	local nearGround = altitudeM < self.groundContactM
	local onSurface = false
	if not nearGround and speed < 3 and self.callbacks.surface then
		-- ray from the capsule to the actual rocket bottom (+0.8 stud): slow hovering above
		-- the surface is not a landing yet; after stage separation the rocket bottom is higher
		-- the ray goes ALONG GRAVITY (to the planet centre): so landing also counts on the side of a sphere
		local gdir = g > 1e-6 and gVec.Unit or -Vector3.yAxis
		local reach = 0
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then
				local cf, s = p.CFrame, p.Size
				local ext = math.abs(gdir:Dot(cf.RightVector)) * s.X / 2 + math.abs(gdir:Dot(cf.UpVector)) * s.Y / 2
					+ math.abs(gdir:Dot(cf.LookVector)) * s.Z / 2
				reach = math.max(reach, (p.Position - core.Position):Dot(gdir) + ext)
			end
		end
		onSurface = self.callbacks.surface(core, gdir * (reach + 0.8)) ~= nil
	end
	if self.liftedOff and speed < 3 and (nearGround or onSurface) then
		self.restTime = (self.restTime or 0) + dt
		if self.restTime > 0.5 and nearGround then
			-- back on Earth: the flight is over
			-- impact speed = maximum over the last 2 s before stopping (same as on the Moon / Mars).
			-- Previously the maximum of the TOTAL speed below ~100 m above the ground was used: the horizontal autoland
			-- transfer to the pad (250 m/s) counted as an "impact" and a soft landing became a crash.
			local impact = 0
			for _, e in ipairs(self.speedLog) do
				impact = math.max(impact, e[2])
			end
			self.impactSpeed = impact
			self.hardLanding = self.impactSpeed > maxSafe and self.impactSpeed <= maxHard
			self:Stop(self.impactSpeed > maxHard and "crash" or "landed")
			return
		elseif self.restTime > 0.5 and not self.landed then
			-- landed on the crater surface: the flight continues (you can drill and take off again)
			local impact = 0
			for _, e in ipairs(self.speedLog) do
				impact = math.max(impact, e[2])
			end
			self.impactSpeed = impact
			if impact > maxHard then
				self:Stop("crash")
				return
			end
			self.hardLanding = impact > maxSafe
			self.landed = true
			self.landedOnSurface = true
			model:SetAttribute("Landed", true)
			if self.callbacks.onSurfaceLanding then
				task.spawn(self.callbacks.onSurfaceLanding, self, impact)
			end
		end
	else
		self.restTime = 0
		if self.landed and speed > 3 then
			self.landed = false
			model:SetAttribute("Landed", false)
		end
	end
	-- Fell off the edge of the map (below the start level): that is a crash too, not a silent disappearance
	if pos.Y < (model:GetAttribute("PadY") or 0) - 60 then
		self.impactSpeed = speed
		self:Stop("crash")
		return
	end
	-- Did not lift off: the engine is off and the rocket is still standing
	if not self.liftedOff and not self.engineOn and self.time > 3 then
		self:Stop("noLiftoff")
		return
	end

	-- HUD telemetry (model attributes replicate to clients)
	self.telemetryTimer += dt
	if self.telemetryTimer >= TELEMETRY_INTERVAL then
		self.telemetryTimer = 0
		local st = self:GetStage()
		local fuelPct = 0
		local availableThrust = 0
		if st then
			local cap = st:GetAttribute("FuelCapacity") or 0
			fuelPct = cap > 0 and (st:GetAttribute("FuelMass") or 0) / cap * 100 or 0
			if (st:GetAttribute("FuelMass") or 0) > 0 then
				local tSL, tVac = st:GetAttribute("Thrust") or 0, st:GetAttribute("ThrustVac") or 0
				availableThrust = tVac - (tVac - tSL) * pressure
			end
		end
		model:SetAttribute("StageFuelPct", fuelPct)
		model:SetAttribute("TWR", g > 0 and availableThrust / (massKg * g) or 0) -- TWR = F / (m·g)
		model:SetAttribute("MassKg", massKg)
		model:SetAttribute("ApogeeKm", self.apogeeM / 1000)
		model:SetAttribute("AirDensity", rho)
		model:SetAttribute("TurnRateDeg", math.deg(self.turnRate))
		model:SetAttribute("GravityMS2", g)
	end
end

--------------------------------------------------------------------
-- Launch / stop
--------------------------------------------------------------------
function FlightPhysics:Start()
	self:Ignite()
	self.conn = RunService.Heartbeat:Connect(function(dt)
		self:Step(dt)
	end)
end

-- reason: "crash" | "landed" | "maxAltitude" | "noLiftoff" | "manual" | "lost"
function FlightPhysics:Stop(reason)
	if self.ended then
		return
	end
	self.ended = true
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	if self.force.Parent then
		self.force.Force = Vector3.zero
	end
	if self.callbacks.onEnded then
		task.spawn(self.callbacks.onEnded, self, reason)
	end
end

return FlightPhysics
