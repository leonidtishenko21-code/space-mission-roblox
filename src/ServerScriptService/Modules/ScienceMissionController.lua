--[[
	ScienceMissionController (ModuleScript, SERVER)
	Location: ServerScriptService > Modules > ScienceMissionController

	Lunar mission zone (Workspace > Planets > MoonZone): the Lunar_Crater_Rim crater at 100 km altitude,
	with 3 beacons inside (Target_CraterBeacon + Beacons/Beacon1..3) and an ice deposit (Target_IceDeposit).

	Science tasks (work only if the instrument is on the rocket and there is enough power):
	  theodolite — laser beams (Beam) to 3 beacons: L, angle α, Δh = L·sin α
	  scan       — terrain scan with waves + real crater measurements with rays (Raycast)
	  drill      — after landing near the ice: the auger goes down, an ice sample
	Data counts (with a $ reward) only if there is an antenna — otherwise it cannot be sent to Earth.

	Gravity: near the crater g changes smoothly from Earth's to the Moon's (1.62 m/s²) —
	this is a GAME "Moon zone" (the real Moon is 384,400 km away).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local RocketMath = require(modules:WaitForChild("RocketMath"))

local M_PER_STUD = NASAData.Flight.METERS_PER_STUD
local MOON_G = NASAData.Planets.Moon.surfaceGravity

local Science = {}

--------------------------------------------------------------------
-- ⚙️ SETTINGS
--------------------------------------------------------------------
Science.SCIENCE_RANGE = 1500   -- studs (≈ 19 km) from the crater centre: instruments "see" the target from here
Science.GRAVITY_INNER = 600    -- closer — full lunar gravity
Science.GRAVITY_OUTER = 1300   -- farther — Earth gravity
Science.DRILL_RADIUS = 80      -- studs from the centre of the ice deposit (≈ 1 km)
Science.REWARD = 10000         -- [GAME] $ for each data set sent to Earth
Science.TITLES = {
	theodolite = "Laser triangulation",
	scan = "Terrain scan",
	drill = "Ice core sample",
}

local zone = workspace:WaitForChild("Planets"):WaitForChild("MoonZone", 10)
local center = zone and zone:GetAttribute("Center")
local crater = zone and zone:FindFirstChild("Lunar_Crater_Rim")
local iceSite = zone and zone:FindFirstChild("Target_IceDeposit")
local beaconFolder = zone and zone:FindFirstChild("Beacons")

local function fmt(n)
	local s = tostring(math.floor(math.abs(n) + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

local function beacons()
	local list = beaconFolder and beaconFolder:GetChildren() or {}
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

--------------------------------------------------------------------
-- Zone and gravity
--------------------------------------------------------------------
function Science.DistanceStuds(pos)
	return center and (pos - center).Magnitude or math.huge
end

-- g near the crater: smooth blend from Earth to Moon (see the header comment)
function Science.Gravity(pos, gEarth)
	if not center then
		return gEarth
	end
	local d = (pos - center).Magnitude
	local t = math.clamp((Science.GRAVITY_OUTER - d) / (Science.GRAVITY_OUTER - Science.GRAVITY_INNER), 0, 1)
	return gEarth + (MOON_G - gEarth) * t
end

-- Whether the rocket stands on the crater surface (ray down from the capsule)
-- Whether the rocket stands on the surface of any celestial body in Workspace > Planets (Moon, Mars, asteroid).
-- ray — the ray vector (along gravity, i.e. to the planet centre) or the length of a downward ray.
function Science.SurfaceBelow(core, ray)
	if typeof(ray) == "number" then
		ray = Vector3.new(0, -ray, 0)
	end
	local planets = workspace:FindFirstChild("Planets")
	if not planets then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { planets }
	return workspace:Raycast(core.Position, ray, params)
end

local zoneCount = 0
local function setBeacons(on)
	for _, b in ipairs(beacons()) do
		local light, hl = b:FindFirstChildOfClass("PointLight"), b:FindFirstChildOfClass("Highlight")
		if light then
			light.Enabled = on
		end
		if hl then
			hl.Enabled = on
		end
	end
end

-- Called ~2 times per second: updates HUD attributes and highlights the beacons when the rocket is near
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))

function Science.Update(flight)
	-- nearest target (Moon or Mars site) for the HUD
	local bestName, bestD = nil, math.huge
	for _, z in ipairs(PlanetZoneManager.GetZones()) do
		local c = z:GetAttribute("Center")
		local d = c and (flight.core.Position - c).Magnitude or math.huge
		if d < bestD then
			bestName, bestD = PlanetZoneManager.CONFIG[z:GetAttribute("Planet")].name, d
		end
	end
	flight.model:SetAttribute("TargetName", bestName)
	flight.model:SetAttribute("TargetDistanceKm", bestName and bestD * M_PER_STUD / 1000 or nil)
	local _, zoneId, zoneF = PlanetZoneManager.Locate(flight.core.Position)
	flight.model:SetAttribute("ZoneId", zoneF > 0.3 and zoneId or "")

	local d = Science.DistanceStuds(flight.core.Position)
	local inZone = d <= Science.SCIENCE_RANGE
	flight.model:SetAttribute("ZoneDistanceKm", d * M_PER_STUD / 1000)
	if inZone ~= (flight.inZone == true) then
		flight.inZone = inZone
		flight.model:SetAttribute("InScienceZone", inZone)
		zoneCount = math.max(zoneCount + (inZone and 1 or -1), 0)
		setBeacons(zoneCount > 0)
	end
end

function Science.Leave(flight)
	if flight.inZone then
		flight.inZone = false
		zoneCount = math.max(zoneCount - 1, 0)
		setBeacons(zoneCount > 0)
	end
end

--------------------------------------------------------------------
-- Rocket equipment and power balance
--------------------------------------------------------------------
function Science.Loadout(player)
	local ok, raw = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("RocketDesign") or "")
	local design = ok and RocketMath.Sanitize(raw)
	if not design then
		return nil
	end
	local stats = RocketMath.Compute(design)
	local function has(id)
		return RocketMath.HasModule(design, id)
	end
	return {
		theodolite = has("theodolite"),
		scan = has("terrain_scanner"),
		drill = has("ice_drill"),
		antenna = has("antenna_low") or has("antenna_medium") or has("antenna_high"),
		battery = has("battery"),
		power = stats.power, -- W: positive — produces, negative — consumes (sum of all parts)
		design = design,
		stats = stats,
	}
end

-- Instruments work if the power balance is ≥ 0 or there is a battery (3000 Wh reserve)
function Science.PowerOk(loadout)
	return loadout.power >= 0 or loadout.battery
end

local function findPart(model, name)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == name then
			return d
		end
	end
	return nil
end

local function checkRange(flight)
	if flight.ended then
		error("flight ended", 0)
	end
	if Science.DistanceStuds(flight.core.Position) > Science.SCIENCE_RANGE * 1.1 then
		error("the rocket left the crater zone", 0)
	end
end

--------------------------------------------------------------------
-- 1) Laser theodolite: beams to 3 beacons
--   L — distance to the beacon, α — angle below the horizon  →  Δh = L · sin α (how much lower the beacon is)
--   From three beacons with known positions the rocket position is computed (triangulation).
--------------------------------------------------------------------
local RUN = {}

RUN.theodolite = function(flight)
	local src = findPart(flight.model, "Sci_LaserTheodolite_Emitter") or flight.core
	local a0 = Instance.new("Attachment")
	a0.Name = "LaserOrigin"
	a0.Parent = src
	Debris:AddItem(a0, 8)
	local lines, heights = {}, {}
	for i, b in ipairs(beacons()) do
		checkRange(flight)
		local a1 = Instance.new("Attachment")
		a1.Parent = b
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Color = ColorSequence.new(Color3.fromRGB(255, 60, 50))
		beam.LightEmission = 1
		beam.Width0 = 0.6
		beam.Width1 = 0.6
		beam.FaceCamera = true
		beam.Transparency = NumberSequence.new(0.1)
		beam.Parent = b
		Debris:AddItem(beam, 8)
		Debris:AddItem(a1, 8)

		local v = b.Position - src.Position
		local L = v.Magnitude * M_PER_STUD                           -- m
		local alpha = math.asin(math.clamp(-v.Y / v.Magnitude, -1, 1))  -- rad, down from the horizon
		local dh = L * math.sin(alpha)                                 -- Δh = L·sin α
		table.insert(heights, dh)
		table.insert(lines, string.format("Beacon %d: L = %.2f km, α = %.1f° → Δh = L·sin α = %.2f km", i, L / 1000, math.deg(alpha), dh / 1000))
		flight.model:SetAttribute("ScanProgress", i / 3 * 100)
		task.wait(1.5)
	end
	local avg = 0
	for _, h in ipairs(heights) do
		avg += h / #heights
	end
	return "📐 Triangulation complete:\n" .. table.concat(lines, "\n")
		.. string.format("\nRocket altitude above the beacons ≈ %.2f km.", avg / 1000)
end

--------------------------------------------------------------------
-- 2) Terrain scanner: waves + crater measurement with rays (16 directions from the centre)
--------------------------------------------------------------------
local function wave(origin)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.ForceField
	ball.Color = Color3.fromRGB(80, 200, 255)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Size = Vector3.one * 4
	ball.Position = origin
	ball.Parent = workspace
	TweenService:Create(ball, TweenInfo.new(1.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 500, Transparency = 1 }):Play()
	Debris:AddItem(ball, 2)
end

local function measureCrater()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { crater }
	local function heightAt(x, z)
		local hit = workspace:Raycast(Vector3.new(x, center.Y + 300, z), Vector3.new(0, -600, 0), params)
		return hit and hit.Position.Y or nil
	end
	local floor = heightAt(center.X, center.Z) or center.Y
	local rimSum, radiusSum, maxSlope, n = 0, 0, 0, 0
	for k = 0, 15 do
		local a = k / 16 * 2 * math.pi
		local dx, dz = math.cos(a), math.sin(a)
		local best, bestR, prevH = -math.huge, 0, floor
		for r = 5, 160, 5 do
			local h = heightAt(center.X + dx * r, center.Z + dz * r)
			if h then
				if h > best then
					best, bestR = h, r
				end
				if r <= bestR then
					maxSlope = math.max(maxSlope, math.deg(math.atan2(h - prevH, 5)))
				end
				prevH = h
			end
		end
		if best > -math.huge then
			rimSum += best
			radiusSum += bestR
			n += 1
		end
	end
	if n == 0 then
		return 0, 0, 0
	end
	return (rimSum / n - floor) * M_PER_STUD, 2 * radiusSum / n * M_PER_STUD, maxSlope
end

RUN.scan = function(flight)
	local DURATION, step = 8, 0.5
	local t = 0
	while t < DURATION do
		checkRange(flight)
		if t % 2 == 0 then
			wave(flight.core.Position)
		end
		flight.model:SetAttribute("ScanProgress", t / DURATION * 100)
		task.wait(step)
		t += step
	end
	flight.model:SetAttribute("ScanProgress", 100)
	local depth, diameter, slope = measureCrater()
	return string.format("🛰 Crater terrain: diameter %.1f km, depth %s m, slopes up to %.0f°.\n"
		.. "The flat floor in the center (slope < 5°) is suitable for landing.", diameter / 1000, fmt(depth), slope)
end

--------------------------------------------------------------------
-- 3) Drill: the auger (Auger + Bit from the Sci_IceDrill mesh) goes down and up
--------------------------------------------------------------------
RUN.drill = function(flight)
	local parts, welds, homes = {}, {}, {}
	for _, d in ipairs(flight.model:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Sci_IceDrill_Auger" or d.Name == "Sci_IceDrill_Bit") then
			table.insert(parts, d)
		end
	end
	-- temporarily detach the auger from the rocket, otherwise its motion would move the whole rocket
	for _, w in ipairs(flight.model:GetDescendants()) do
		if w:IsA("WeldConstraint") and (table.find(parts, w.Part0) or table.find(parts, w.Part1)) then
			w.Enabled = false
			table.insert(welds, w)
		end
	end
	local depth = 0
	for _, p in ipairs(parts) do
		homes[p] = p.CFrame
		p.Anchored = true
		depth = math.max(depth, p.Size.Y * 0.8)
	end
	local chips
	if parts[1] then
		local low = parts[1]
		for _, p in ipairs(parts) do
			if p.Position.Y < low.Position.Y then
				low = p
			end
		end
		local a = Instance.new("Attachment")
		a.Parent = low
		a.Position = Vector3.new(0, -low.Size.Y / 2, 0)
		chips = Instance.new("ParticleEmitter")
		chips.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		chips.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
		chips.Size = NumberSequence.new(0.6, 0.1)
		chips.Speed = NumberRange.new(6, 12)
		chips.SpreadAngle = Vector2.new(60, 60)
		chips.Acceleration = Vector3.new(0, -MOON_G / M_PER_STUD * 20, 0)
		chips.Lifetime = NumberRange.new(0.6, 1.2)
		chips.Rate = 40
		chips.Parent = a
		Debris:AddItem(a, 9)
	end

	local function restore()
		for _, p in ipairs(parts) do
			if p.Parent then
				local home = homes[p]
				-- restore relative to the rocket's current position (it may have settled a little)
				p.CFrame = home
				p.Anchored = false
			end
		end
		for _, w in ipairs(welds) do
			if w.Parent then
				w.Enabled = true
			end
		end
		if chips then
			chips.Enabled = false
		end
	end

	local ok, err = pcall(function()
		local down = {}
		for _, p in ipairs(parts) do
			local tw = TweenService:Create(p, TweenInfo.new(3, Enum.EasingStyle.Sine), { CFrame = homes[p] - Vector3.new(0, depth, 0) })
			tw:Play()
			table.insert(down, tw)
		end
		for i = 1, 9 do
			if flight.ended or not flight.landed then
				error("the rocket lifted off while drilling", 0)
			end
			flight.model:SetAttribute("ScanProgress", i / 9 * 100)
			task.wait(0.5)
		end
		for _, p in ipairs(parts) do
			TweenService:Create(p, TweenInfo.new(1.5, Enum.EasingStyle.Sine), { CFrame = homes[p] }):Play()
		end
		task.wait(1.6)
	end)
	restore()
	if not ok then
		error(err, 0)
	end
	local holeM = depth * NASAData.Constants.METERS_PER_STUD -- the drill is a rocket part, scale 0.28 m/stud
	return string.format("🧊 Drilled %.1f m of regolith. Ice sample: %.1f kg, H₂O ≈ %d%%.\n"
		.. "Water means drinking water, oxygen and hydrogen fuel for a future base.",
		holeM, 0.8 + math.random() * 0.8, math.random(88, 96))
end

--------------------------------------------------------------------
-- STARTING A TASK
--   kind: "theodolite" | "scan" | "drill";  notify(player, text, isError)
--   Returns ok, message. The result arrives later via notify.
--------------------------------------------------------------------
function Science.Run(flight, player, kind, notify)
	if not RUN[kind] then
		return false, "Unknown instrument."
	end
	flight.science = flight.science or { done = {}, log = {}, reward = 0 }
	local st = flight.science
	if st.busy then
		return false, "Wait: the instrument is still running."
	end
	if st.done[kind] then
		return false, "This data has already been collected."
	end
	local lo = Science.Loadout(player)
	if not lo or not lo[kind] then
		return false, "The rocket does not carry this instrument."
	end
	if not Science.PowerOk(lo) then
		return false, string.format("Power balance %d W: not enough power for the instruments. Add a solar panel or a battery.", lo.power)
	end
	local pos = flight.core.Position
	if kind == "drill" then
		if not flight.landed then
			return false, "The drill works only after landing in the crater."
		end
		local icePos = iceSite and iceSite:GetPivot().Position or center
		local d = Vector3.new(pos.X - icePos.X, 0, pos.Z - icePos.Z).Magnitude
		if d > Science.DRILL_RADIUS then
			return false, string.format("The ice deposit is %.1f km away — land closer (within %.1f km).",
				d * M_PER_STUD / 1000, Science.DRILL_RADIUS * M_PER_STUD / 1000)
		end
	elseif Science.DistanceStuds(pos) > Science.SCIENCE_RANGE then
		return false, string.format("The crater is too far: get closer than %.0f km.", Science.SCIENCE_RANGE * M_PER_STUD / 1000)
	end

	st.busy = true
	flight.model:SetAttribute("ScienceBusy", kind)
	flight.model:SetAttribute("ScanProgress", 0)
	task.spawn(function()
		local ok, result = pcall(RUN[kind], flight)
		st.busy = false
		if flight.model.Parent then
			flight.model:SetAttribute("ScienceBusy", "")
		end
		if not player.Parent then
			return
		end
		if not ok then
			notify(player, "Instrument stopped: " .. tostring(result) .. ".", true)
			return
		end
		st.done[kind] = true
		table.insert(st.log, Science.TITLES[kind])
		local doneList = {}
		for k in pairs(st.done) do
			table.insert(doneList, k)
		end
		if flight.model.Parent then
			flight.model:SetAttribute("ScienceDone", table.concat(doneList, ","))
		end
		if lo.antenna then
			st.reward += Science.REWARD
			player:SetAttribute("Budget", (player:GetAttribute("Budget") or 0) + Science.REWARD)
			notify(player, result .. "\n📡 Data transmitted to Earth: +$" .. fmt(Science.REWARD), false)
		else
			notify(player, result .. "\n⚠ No antenna — the data stays on board and will not be paid for.", false)
		end
	end)
	local starts = {
		theodolite = "Laser theodolite: aiming beams at the beacons...",
		scan = "Terrain scanner ON. Stay in the crater zone for 8 s.",
		drill = "Drilling for ice... Do not lift off!",
	}
	return true, starts[kind]
end

return Science
