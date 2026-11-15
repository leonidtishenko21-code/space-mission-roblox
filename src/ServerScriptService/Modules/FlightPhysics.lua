--[[
	FlightPhysics (ModuleScript, СЕРВЕР)
	Місце: ServerScriptService > Modules > FlightPhysics

	Керує польотом зібраної ракети (RocketAssembler):
	  • VectorForce "FlightForce"       — тяга + аеродинамічний опір + справжня гравітація
	  • AlignOrientation "FlightAttitude" — плавний нахил ракети (W/S/A/D з клієнта)

	ЯК РАХУЄТЬСЯ (кожен Heartbeat):
	  1) Тиск повітря змінює тягу і Isp:  T = T_vac − (T_vac − T_sl)·(ρ/ρ0)
	  2) Витрата пального:  ṁ = T / (Isp · g0),   Δm = ṁ · Δt
	  3) Маса ракети = Σ (DryMass + FuelMass) усіх груп, що ще приєднані → пальне вигорає,
	     маса падає, і TWR = T/(m·g) та прискорення РОСТУТЬ під час польоту.
	  4) Щільність атмосфери:  ρ(h) = ρ0 · e^(−h/H) · (1 − h/h_top),  ρ = 0 вище лінії Кармана
	  5) Опір:  D = ½ · ρ · v² · Cd · A   (проти напрямку швидкості)
	  6) Гравітація спадає з висотою:  g(h) = g0 · (R / (R + h))²
	  7) a = (T·û + D) / m + g      — у СПРАВЖНІХ м/с²
	     a_studs = a / METERS_PER_STUD  (масштаб польоту, див. NASAData.Flight)
	     VectorForce = AssemblyMass · (a_studs + g_Roblox·ŷ)
	     Додаток g_Roblox компенсує вбудовану гравітацію Roblox (196.2 studs/с²), тож ракета рухається
	     РІВНО з прискоренням a, а фізична маса деталей Roblox ні на що не впливає.
	     🔧 BLENDER: тому заміна мешів не змінить поведінки ракети.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))

local G0 = NASAData.Constants.G0
local SIZE_M_PER_STUD = NASAData.Constants.METERS_PER_STUD -- розмір деталей (0.28 м)
local F = NASAData.Flight
local M_PER_STUD = F.METERS_PER_STUD                        -- висота в польоті (12.5 м)
local EARTH = NASAData.Planets.Earth
local RHO0 = EARTH.atmosphereDensity

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ КЕРУВАННЯ
--------------------------------------------------------------------
local TURN_RATE = math.rad(12)          -- рад/с: наскільки швидко змінюється цільовий нахил
local MAX_TILT = math.rad(90)           -- далі за горизонт не нахиляємо
local TELEMETRY_INTERVAL = 0.1          -- с: як часто оновлювати атрибути для HUD

local FlightPhysics = {}
FlightPhysics.__index = FlightPhysics

--------------------------------------------------------------------
-- Формули
--------------------------------------------------------------------
-- ρ(h): експоненційна атмосфера, плавно доведена до нуля на лінії Кармана
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
-- Створення польоту
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
	self.inputOmega = Vector3.zero         -- запит повороту (світова вісь × сила 0…1.8) від W/S/A/D/Q/E
	self.targetCF = coreAtt.WorldCFrame.Rotation -- цільова орієнтація ракети (6DOF, без обмежень)
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
	self.startY = core.Position.Y -- зліт рахуємо від стартової позиції капсули, а не від рівня столу
	self.throttle = 1
	model:SetAttribute("Throttle", 1)
	self.gravity = NASAData.Planets.Earth.surfaceGravity

	-- Діаметр для площі опору беремо в масштабі деталей (1 stud = 0.28 м)
	local diameterM = (model:GetAttribute("MaxDiameter") or 4) * SIZE_M_PER_STUD
	self.area = math.pi * (diameterM / 2) ^ 2

	-- Капсула (ядро) вище за низ ракети: "торкання землі" = ядро не вище цієї висоти (+4 studs запасу)
	local base = model:GetAttribute("BasePosition") or core.Position
	self.groundContactM = (core.Position.Y - base.Y + 4) * M_PER_STUD

	local force = Instance.new("VectorForce")
	force.Name = "FlightForce"
	force.Attachment0 = coreAtt
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true -- без крутного моменту: орієнтацією керує AlignOrientation
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

	-- Двигуни орієнтації RCS (Draco): їхня кількість прискорює поворот, а під час повороту
	-- з них б'ють короткі білі струмені холодного газу
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
-- Ступені та маса
--------------------------------------------------------------------
function FlightPhysics:GetStage(k)
	return self.model:FindFirstChild("Stage" .. (k or self.activeStage))
end

-- Маса в кг = усе, що ще летить у моделі (відділені групи виносяться з моделі)
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

-- Запалити двигуни активного ступеня (якщо є двигун і пальне)
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

-- Викликає StageController після відстрілу
function FlightPhysics:SetActiveStage(k)
	self.activeStage = k
	self.model:SetAttribute("ActiveStage", k)
end

-- Запит повороту від гравця: світовий вектор (вісь повороту × сила натискання)
function FlightPhysics:SetInput(omega)
	self.inputOmega = omega
end

-- Режими орієнтації:
--   sas        — стабілізація: тримає останній напрямок, клавіші повертають його
--   free       — без стабілізації: ракета крутиться за інерцією, клавіші додають обертання (RCS)
--   retrograde — автонаведення соплом вперед (ніс проти швидкості) — для гальмування
--   radial     — соплом до планети (ніс від її центру) — для посадки де завгодно на сфері
local MODES = { sas = true, free = true, retrograde = true, radial = true }
function FlightPhysics:SetAttitudeMode(mode)
	if not MODES[mode] then
		return
	end
	if mode == "sas" or mode == "free" then
		self.targetCF = self.coreAtt.WorldCFrame.Rotation -- тримати там, куди дивимось зараз
	end
	self.attitudeMode = mode
	self.model:SetAttribute("AttitudeMode", mode)
end

-- Швидкість повороту: гіроскопи капсули + кожен RCS Draco; важча ракета (більший момент
-- інерції) розвертається повільніше:  ω = (10° + 8°·N_RCS)/с · √(8000 кг / m)
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
		-- на старті ракета тримає вертикаль
		self.align.Enabled = true
		self.align.CFrame = self.targetCF
		return
	end
	local mode = self.attitudeMode
	if hasInput and (mode == "retrograde" or mode == "radial") then
		self:SetAttitudeMode("sas") -- ручне керування скасовує автонаведення
		mode = "sas"
	end

	if mode == "free" then
		-- без стабілізації: клавіші розкручують / гальмують обертання, далі — за інерцією
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
						axis = self.targetCF.RightVector -- ціль рівно позаду: будь-яка перпендикулярна вісь
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

-- Дросель 0…1 (Shift/Ctrl — більше/менше, Z — повний, X — вимкнути)
function FlightPhysics:SetThrottle(t)
	self.throttle = math.clamp(t, 0, 1)
	self.model:SetAttribute("Throttle", self.throttle)
end

-- Полум'я пропорційне дроселю; на 0% двигун "гасне" візуально
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
-- КРОК ФІЗИКИ
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
	local vel = velStuds * M_PER_STUD                   -- м/с
	local rho = FlightPhysics.AirDensity(altitudeM)
	if self.callbacks.density then
		rho = self.callbacks.density(pos, rho) -- наприклад, розріджена атмосфера Марса
	end
	local pressure = rho / RHO0                          -- 1 біля Землі, 0 у космосі

	-- 1–2) Тяга і витрата пального активного ступеня
	local thrust = 0
	local stage = self:GetStage()
	if self.engineOn and stage then
		local tSL, tVac = stage:GetAttribute("Thrust"), stage:GetAttribute("ThrustVac")
		local iSL, iVac = stage:GetAttribute("Isp"), stage:GetAttribute("IspVac")
		-- дросель 0…100%: тяга і витрата пального пропорційні йому (Isp не змінюється)
		local T = (tVac - (tVac - tSL) * pressure) * self.throttle
		local isp = iVac - (iVac - iSL) * pressure
		local mdot = T / (isp * G0)                      -- ṁ = F / (Isp · g0), кг/с
		local burn = mdot * dt
		local fuel = stage:GetAttribute("FuelMass") or 0
		if fuel <= burn then
			-- пальне скінчилося посеред кроку: тяга лише на частину кроку
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
	-- повторне запалювання: двигун вимкнений, але гравець дав дросель і в ступені ще є пальне
	if not self.engineOn and self.throttle > 0 and stage and (stage:GetAttribute("FuelMass") or 0) > 0 then
		self:Ignite()
	end
	self:UpdateFlameFX()

	-- 3) Маса ракети зараз
	local massKg = self:MassKg()

	-- 4–5) Аеродинамічний опір  D = ½·ρ·v²·Cd·A
	local speed = vel.Magnitude
	local dragAccel = Vector3.zero
	if rho > 0 and speed > 0.1 then
		local D = 0.5 * rho * speed * speed * F.DRAG_COEFFICIENT * self.area
		local aD = D / massKg
		-- захист чисельної стійкості: опір за один крок не може розвернути швидкість
		aD = math.min(aD, speed / math.max(dt, 1 / 240) * 0.5)
		dragAccel = -vel.Unit * aD
	end

	-- 6) Гравітація — ВЕКТОР: біля Землі вниз (−Y), біля Місяця/Марса — до центру планети:
	--    g = gповерхні · (R / r)²  (PlanetZoneManager.GravityVector)
	local gEarth = NASAData.GravityAtAltitude("Earth", altitudeM)
	local gVec = Vector3.new(0, -gEarth, 0)
	if self.callbacks.gravityVector then
		gVec = self.callbacks.gravityVector(pos, gEarth)
	end
	local g = gVec.Magnitude
	self.gravity = g
	self.gravityVec = gVec
	self.upAt = g > 1e-6 and -gVec.Unit or Vector3.yAxis

	-- 7) Прискорення і сила для Roblox
	local up = self.coreAtt.WorldCFrame.UpVector           -- фактична вісь ракети
	-- 6b) EDL: парашут (додатковий опір) і автопосадка (керує дроселем) — EDLBrakingSystems
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

	-- Усі прискорення — в РЕАЛЬНИХ м/с² (маса ракети в кг з атрибутів), а сила для Roblox =
	-- AssemblyMass · a: тож і тяга, і вільне падіння мають точні прискорення NASA незалежно від маси деталей.
	-- Без тяги тут лише гравітація і опір (ніяких LinearVelocity, що гальмували б падіння).
	local accel = up * (thrust / massKg) + dragAccel + gVec + edlAccel -- м/с²
	local accelStuds = accel / M_PER_STUD
	local assemblyMass = core.AssemblyMass
	self.force.Force = assemblyMass * (accelStuds + Vector3.new(0, workspace.Gravity, 0))

	-- Орієнтація 6DOF (див. UpdateAttitude)
	self:UpdateAttitude(dt, vel, massKg)

	-- Стан польоту
	-- зліт = піднялась на 30 м вище за стартову позицію (капсула стоїть високо над столом, тому
	-- раніше ракета вважалась «злетілою» ще на столі і при повільному старті «сідала» через 0.5 с)
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
	-- Удар об землю: після зльоту ракета раптово зупинилась біля землі.
	-- Швидкість перед зупинкою вирішує: аварія чи м'яка посадка.
	-- Швидкість удару = максимальна швидкість спуску в останні ~100 м над землею
	-- (під час самого удару ракета підскакує й гальмує, тому миттєва швидкість не підходить)
	if altitudeM > self.groundContactM + 200 then
		self.approachSpeed = 0
	elseif vel.Y < 0 and altitudeM < self.groundContactM + 100 then
		self.approachSpeed = math.max(self.approachSpeed or 0, speed)
	end
	-- журнал швидкостей за останні 2 с — для швидкості удару о поверхню кратера
	table.insert(self.speedLog, { self.time, speed })
	while self.speedLog[1] and self.time - self.speedLog[1][1] > 2 do
		table.remove(self.speedLog, 1)
	end
	-- швидкість удару: ≤ 15 м/с — м'яка посадка, ≤ 25 — жорстка (пошкоджені опори), більше — аварія
	local maxSafe = NASAData.Modules.landing_legs.maxLandingSpeed * 3
	local maxHard = maxSafe + 10
	local nearGround = altitudeM < self.groundContactM
	local onSurface = false
	if not nearGround and speed < 3 and self.callbacks.surface then
		-- промінь від капсули до фактичного низу ракети (+0.8 stud): повільне зависання над
		-- поверхнею — ще не посадка; після відстрілу ступенів низ ракети вищий
		-- промінь йде ВЗДОВЖ ГРАВІТАЦІЇ (до центру планети): так посадка рахується й на боці сфери
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
			-- повернулась на Землю: політ закінчено
			-- швидкість удару = максимум за останні 2 с перед зупинкою (як на Місяці / Марсі).
			-- Раніше брали максимум УСІЄЇ швидкості нижче ~100 м над грунтом: горизонтальний переліт
			-- автопосадки до майданчика (250 м/с) зараховувався як «удар» і м'яка посадка ставала аварією.
			local impact = 0
			for _, e in ipairs(self.speedLog) do
				impact = math.max(impact, e[2])
			end
			self.impactSpeed = impact
			self.hardLanding = self.impactSpeed > maxSafe and self.impactSpeed <= maxHard
			self:Stop(self.impactSpeed > maxHard and "crash" or "landed")
			return
		elseif self.restTime > 0.5 and not self.landed then
			-- сіла на поверхню кратера: політ триває (можна бурити і злітати знову)
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
	-- Впала за край карти (нижче рівня старту): це теж аварія, а не тихе зникнення ракети
	if pos.Y < (model:GetAttribute("PadY") or 0) - 60 then
		self.impactSpeed = speed
		self:Stop("crash")
		return
	end
	-- Не злетіла: двигун вимкнений, а ракета так і стоїть
	if not self.liftedOff and not self.engineOn and self.time > 3 then
		self:Stop("noLiftoff")
		return
	end

	-- Телеметрія для HUD (атрибути моделі реплікуються клієнтам)
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
-- Запуск / зупинка
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
