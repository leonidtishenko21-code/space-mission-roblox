--[[
	EDLBrakingSystems (ModuleScript, СЕРВЕР)
	Місце: ServerScriptService > Modules > EDLBrakingSystems

	EDL = Entry, Descent, Landing (вхід, зниження, посадка). Клавіша P / кнопка «ПАРАШУТ» у HUD.

	ПАРАШУТ (Земля, Марс — де є атмосфера):
	  • потрібен модуль «Парашут» на ракеті; розкривається нижче MAX_DEPLOY_ALT_KM;
	  • площа купола розраховується під масу ракети так, щоб на Землі сідати ≈ 7 м/с
	    (так роблять інженери NASA):  A = 2·m·g / (ρ₀·v²·Cd)
	  • опір купола:  F = ½·ρ·v²·Cd·A  (проти швидкості), купол розкривається за 1.5 с;
	  • якщо швидкісний напір ½ρv² > MAX_Q — купол рветься (розкривати треба вище й повільніше);
	  • поки купол відкритий — ракета тримається днищем до планети; після посадки купол відстрілюється.
	  На Марсі повітря у 60 разів рідше — той самий купол гальмує лише до ≈ 55 м/с,
	  тому там потрібне ще й гальмування двигуном (як у справжніх місій Curiosity / Perseverance).

	АВТОПОСАДКА (Місяць та будь-який вакуум): парашут без повітря фізично НЕ працює,
	  тому P вмикає автоматичне гальмування ДВИГУНОМ (як у Apollo LM / Surveyor): ракета розвертається
	  соплом до планети, а дросель тримає швидкість спуску v = 3 + 0.06·h (м/с). Витрачає пальне.

	🧲 НАВЕДЕННЯ НА МАЙДАНЧИК («магніт»): автопосадка сама веде ракету в точку призначення:
	  Місяць — BeaconPad у кратері, Марс — LandingPad у каньйоні, Земля — майданчик біля стартового столу
	  (як Falcon 9 на LZ-1). Перевизначити точку: атрибут зони LandingTarget (Vector3)
	  або деталь Workspace > EarthLandingZone.
	  Горизонталь: бажана швидкість до цілі v = min(k·d, VH_MAX), корекція a = (v_баж − v)·K
	  ([ГРА] допомога пілоту — пальне на неї не витрачається).
	  Вертикаль: спуск сповільнюється, щоб ракета встигла долетіти; далеко від цілі біля
	  поверхні вона зависає на HOLD_ALT_M і сідає лише над майданчиком.
	  Купол на Землі теж керований (слабший «магніт», як парафойл).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))

local E = NASAData.EDL
local RHO0 = NASAData.Planets.Earth.atmosphereDensity
local G0 = NASAData.Planets.Earth.surfaceGravity

local EDL = {}

local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

-- 🧲 Наведення (усе в метрах і м/с)
local GAIN_POS = 0.35      -- 1/с: бажана швидкість до цілі = 0.35 · відстань
local GAIN_VEL = 1.2       -- 1/с: як швидко вирівнюємо швидкість
local VH_MAX = 250         -- м/с: найшвидший горизонтальний переліт
local A_MAGNET = 25        -- м/с²: сила «магніту» автопосадки
local A_MAGNET_CHUTE = 8   -- м/с²: керований купол
local LAND_RADIUS_M = 20   -- м: ближче цієї відстані від центру майданчика можна сідати
local HOLD_ALT_M = 60      -- м: далеко від цілі нижче не опускаємось
-- На Місяці / Марсі (сфери) ракета часто входить у зону ЗБОКУ чи ЗНИЗУ (планета висить над Землею),
-- а майданчик — на верхівці. Тому «магніт» веде її ВЗДОВЖ СФЕРИ (дугою великого кола),
-- а безпечна висота над сферою зростає з відстанню: над валом кратера та схилами пролітаємо вище.
local HOLD_PER_M = 0.5     -- м безпечної висоти на кожен метр до цілі (лише сфери)
local HOLD_MAX_M = 3000    -- м: стеля безпечної висоти
local CLIMB_MAX = 40       -- м/с: набір висоти до безпечної — без ривків (економимо паливо)
local EARTH_LZ_OFFSET = Vector3.new(0, 0, 160) -- studs від стартового столу (подалі від вежі та ангара)
local PAD_NAMES = { Moon = "BeaconPad", Mars = "LandingPad" } -- LandingColliders зони

local function setState(flight, state)
	flight.edl.chute = state
	flight.model:SetAttribute("ParachuteState", state)
end

--------------------------------------------------------------------
-- 🧲 Точка призначення: повертає позицію (studs) і «верх» у цій точці
--------------------------------------------------------------------
function EDL.LandingTarget(planetId)
	if planetId == "Moon" or planetId == "Mars" then
		local zone = PlanetZoneManager.GetZone(planetId)
		if not zone then
			return nil
		end
		local globe = zone:GetAttribute("GlobeCenter")
		local pos = zone:GetAttribute("LandingTarget")
		if typeof(pos) ~= "Vector3" then
			local colliders = zone:FindFirstChild("LandingColliders")
			local pad = colliders and colliders:FindFirstChild(PAD_NAMES[planetId])
			if pad and pad:IsA("BasePart") then
				local up = (pad.Position - globe).Unit
				-- верхня грань майданчика (деталь може бути повернутим циліндром)
				local cf, s = pad.CFrame, pad.Size
				local half = math.abs(up:Dot(cf.RightVector)) * s.X / 2 + math.abs(up:Dot(cf.UpVector)) * s.Y / 2
					+ math.abs(up:Dot(cf.LookVector)) * s.Z / 2
				pos = pad.Position + up * half
			else
				pos = zone:GetAttribute("Center")
			end
		end
		if typeof(pos) ~= "Vector3" then
			return nil
		end
		return pos, (pos - globe).Unit
	end

	-- Земля: деталь EarthLandingZone або точка поруч ізо стартовим столом
	local lz = workspace:FindFirstChild("EarthLandingZone")
	if lz and lz:IsA("BasePart") then
		return lz.Position + Vector3.new(0, lz.Size.Y / 2, 0), Vector3.yAxis
	end
	local padModel = workspace:FindFirstChild("LaunchPad")
	local pad = padModel and padModel:FindFirstChild("Pad")
	local base = (pad and pad.Position or Vector3.new(0, 0, 110)) + EARTH_LZ_OFFSET
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { workspace:FindFirstChild("Rockets") }
	local hit = workspace:Raycast(Vector3.new(base.X, 80, base.Z), Vector3.new(0, -200, 0), params)
	return Vector3.new(base.X, hit and hit.Position.Y or 0, base.Z), Vector3.yAxis
end

-- Маяк цілі: зелене кільце на майданчику + світловий стовп (бачать усі гравці)
local function hideMarker(flight)
	local m = flight.edl and flight.edl.marker
	if m then
		flight.edl.marker = nil
		m:Destroy()
	end
end

local function showMarker(flight, pos, up)
	hideMarker(flight)
	local side = math.abs(up.Y) < 0.9 and up:Cross(Vector3.yAxis).Unit or up:Cross(Vector3.xAxis).Unit
	local folder = Instance.new("Model")
	folder.Name = "LandingTargetMarker"
	local function piece(name, shape, size, cf, transparency)
		local p = Instance.new("Part")
		if shape then
			p.Shape = shape
		end
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(60, 255, 140)
		p.Transparency = transparency
		p.Size = size
		p.CFrame = cf
		p.Parent = folder
		return p
	end
	-- вісь циліндра Roblox — X, тому X = «вгору» планети
	piece("Ring", Enum.PartType.Cylinder, Vector3.new(0.2, 18, 18), CFrame.fromMatrix(pos + up * 0.15, up, side), 0.55)
	piece("Pillar", nil, Vector3.new(0.8, 400, 0.8), CFrame.fromMatrix(pos + up * 200, side, up), 0.65)
	folder.Parent = workspace
	flight.edl.marker = folder
end

local function setAutoLand(flight, on, planetId)
	local st = flight.edl
	st.autoLand = on
	flight.model:SetAttribute("AutoLand", on)
	if on then
		local pos, up = EDL.LandingTarget(planetId)
		st.target = pos and { pos = pos, up = up, planet = planetId } or nil
		local zone = (planetId == "Moon" or planetId == "Mars") and PlanetZoneManager.GetZone(planetId)
		if st.target and zone then
			st.target.globe = zone:GetAttribute("GlobeCenter")
			st.target.radius = zone:GetAttribute("GlobeRadius")
		end
		if pos then
			showMarker(flight, pos, up)
		end
	else
		if st.chute ~= "open" then
			st.target = nil
			hideMarker(flight)
		end
		flight.model:SetAttribute("AutoLandTargetM", nil)
	end
end

-- Горизонтальний «магніт». Повертає: прискорення (м/с²), відстань до цілі по горизонталі (м),
-- час дольоту (с)
local function magnet(flight, vel, maxAccel)
	local tgt = flight.edl.target
	if not tgt then
		return Vector3.zero, 0, 0
	end
	if tgt.globe then
		-- сфера: відстань = дуга великого кола, напрямок — по дотичній до цілі у точці ракети
		local a = flight.core.Position - tgt.globe
		local b = tgt.pos - tgt.globe
		local upL = a.Unit
		local ang = math.acos(math.clamp(upL:Dot(b.Unit), -1, 1))
		local dist = ang * tgt.radius * M_PER_STUD
		local tangent = b.Unit - upL * b.Unit:Dot(upL)
		local brakeSpeed = math.sqrt(2 * 0.6 * math.max(maxAccel, 0.1) * dist)
		local speedWanted = math.min(dist * GAIN_POS, brakeSpeed, VH_MAX)
		local vWanted = (dist > 0.5 and tangent.Magnitude > 1e-6) and tangent.Unit * speedWanted or Vector3.zero
		local vH = vel - upL * vel:Dot(upL)
		local acc = (vWanted - vH) * GAIN_VEL
		if acc.Magnitude > maxAccel then
			acc = acc.Unit * maxAccel
		end
		return acc, dist, dist / math.max(speedWanted, 0.5)
	end
	local r = (flight.core.Position - tgt.pos) * M_PER_STUD
	local h = r:Dot(tgt.up)
	local d = r - tgt.up * h
	local dist = d.Magnitude
	-- швидкість, з якої ще встигнемо загальмувати до цілі:  v = √(2·a·d)  (60% сили магніту — запас)
	local brakeSpeed = math.sqrt(2 * 0.6 * math.max(maxAccel, 0.1) * dist)
	local speedWanted = math.min(dist * GAIN_POS, brakeSpeed, VH_MAX)
	local vWanted = dist > 0.5 and -d.Unit * speedWanted or Vector3.zero
	local vH = vel - tgt.up * vel:Dot(tgt.up)
	local a = (vWanted - vH) * GAIN_VEL
	if a.Magnitude > maxAccel then
		a = a.Unit * maxAccel
	end
	return a, dist, dist / math.max(speedWanted, 0.5)
end

local function stageHasFuel(flight)
	local stage = flight:GetStage()
	return stage ~= nil and (stage:GetAttribute("FuelMass") or 0) > 0 and (stage:GetAttribute("ThrustVac") or 0) > 0
end

-- Викликається один раз після FlightPhysics.new
function EDL.Attach(flight)
	local has = false
	for _, p in ipairs(flight.model:GetDescendants()) do
		if p:IsA("BasePart") and p.Name == "parachute" then
			has = true
			break
		end
	end
	flight.edl = { hasChute = has, chute = "stowed", openT = 0, area = 0, autoLand = false }
	flight.model:SetAttribute("HasParachute", has)
	flight.model:SetAttribute("ParachuteState", "stowed")
	flight.model:SetAttribute("AutoLand", false)
end

--------------------------------------------------------------------
-- Візуал купола: діаметр = CANOPY_SCALE × найбільший діаметр ракети (не менше CANOPY_MIN),
-- стропи — Beam до верху ракети. Справжні куполи в ~10 разів ширші за капсулу (Mercury: 1.9 м → 19 м),
-- у грі — 5×, щоб купол вміщався в кадр разом із ракетою.
local CANOPY_SCALE = 5
local CANOPY_MIN = 18 -- studs
-- 🔧 BLENDER: сюди можна підставити MeshPart купола замість еліпсоїда
--------------------------------------------------------------------
local function topOffset(flight, up)
	local top = 0
	for _, p in ipairs(flight.model:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 or (p:IsA("BasePart") and p.CanCollide) then
			local cf, s = p.CFrame, p.Size
			local ext = math.abs(up:Dot(cf.RightVector)) * s.X / 2 + math.abs(up:Dot(cf.UpVector)) * s.Y / 2
				+ math.abs(up:Dot(cf.LookVector)) * s.Z / 2
			top = math.max(top, (p.Position - flight.core.Position):Dot(up) + ext)
		end
	end
	return top
end

local function buildCanopy(flight)
	local model, core = flight.model, flight.core
	local rocketCF = flight.coreAtt.WorldCFrame
	local up = rocketCF.UpVector
	local D = math.max(CANOPY_SCALE * (model:GetAttribute("MaxDiameter") or 4), CANOPY_MIN)
	local top = topOffset(flight, up)
	local folder = Instance.new("Folder")
	folder.Name = "Parachute"
	folder.Parent = model

	local center = core.Position + up * (top + D * 0.9)
	local dome = Instance.new("Part")
	dome.Name = "Canopy"
	dome.Size = Vector3.new(D, D * 0.5, D)
	dome.CFrame = CFrame.fromMatrix(center, rocketCF.RightVector, up)
	dome.Color = Color3.fromRGB(255, 120, 40)
	dome.Material = Enum.Material.Fabric
	dome.CanCollide = false
	dome.CanQuery = false
	dome.CanTouch = false
	dome.Massless = true
	dome.CastShadow = false
	dome.CollisionGroup = "Rocket"
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(0.08, 0.08, 0.08)
	mesh.Parent = dome
	dome.Parent = folder
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = core
	weld.Part1 = dome
	weld.Parent = dome

	-- стропи: 6 точок на краю купола → верх ракети
	local anchor = Instance.new("Attachment")
	anchor.Name = "ChuteRiser"
	anchor.Parent = core
	anchor.WorldPosition = core.Position + up * top
	for k = 1, 6 do
		local a = k / 6 * 2 * math.pi
		local edge = Instance.new("Attachment")
		edge.Parent = dome
		edge.Position = Vector3.new(math.cos(a) * D * 0.48, -D * 0.05, math.sin(a) * D * 0.48)
		local beam = Instance.new("Beam")
		beam.Attachment0 = anchor
		beam.Attachment1 = edge
		beam.Width0 = 0.15
		beam.Width1 = 0.25
		beam.Color = ColorSequence.new(Color3.fromRGB(230, 230, 230))
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Transparency = NumberSequence.new(1) -- проявляються разом із куполом
		beam.Parent = dome
	end
	flight.edl.canopy = dome
	flight.edl.riser = anchor

	-- розкриття за 0.8 с
	TweenService:Create(mesh, TweenInfo.new(0.8, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = Vector3.one }):Play()
	task.delay(0.25, function()
		for _, b in ipairs(dome:GetChildren()) do
			if b:IsA("Beam") then
				b.Transparency = NumberSequence.new(0.1)
			end
		end
	end)
	return D
end

local function removeCanopy(flight, torn)
	local dome = flight.edl.canopy
	flight.edl.canopy = nil
	if flight.edl.riser then
		flight.edl.riser:Destroy()
		flight.edl.riser = nil
	end
	if not dome or not dome.Parent then
		return
	end
	local mesh = dome:FindFirstChildOfClass("SpecialMesh")
	for _, b in ipairs(dome:GetChildren()) do
		if b:IsA("Beam") then
			b:Destroy()
		end
	end
	if mesh then
		TweenService:Create(mesh, TweenInfo.new(torn and 0.3 or 0.8), { Scale = Vector3.new(0.05, 0.05, 0.05) }):Play()
	end
	TweenService:Create(dome, TweenInfo.new(torn and 0.3 or 0.8), { Transparency = 1 }):Play()
	task.delay(1, function()
		local folder = dome.Parent
		if folder then
			folder:Destroy()
		end
	end)
end

--------------------------------------------------------------------
-- Клавіша P. Повертає ok, повідомлення
--------------------------------------------------------------------
-- Розкриття купола (Земля, Марс). Повертає ok, повідомлення
local deployChute

local function planetHere(pos)
	local _, zoneId, f, zoneAltM = PlanetZoneManager.Locate(pos)
	if zoneId and f > 0 then
		return zoneId, zoneAltM
	end
	return "Earth", math.max(pos.Y, 0) * M_PER_STUD
end

local PLACE = { Moon = "pad in the lunar crater", Mars = "pad in the Martian canyon", Earth = "landing zone next to the launch pad" }

local function targetInfo(flight)
	local tgt = flight.edl.target
	if not tgt then
		return ""
	end
	local d = (flight.core.Position - tgt.pos) * M_PER_STUD
	local horizontal = (d - tgt.up * d:Dot(tgt.up)).Magnitude
	return string.format(" 🧲 Target: %s (%.1f km).", PLACE[tgt.planet] or "landing pad", horizontal / 1000)
end

function EDL.Activate(flight)
	local st = flight.edl
	if not st then
		return false, "Landing system unavailable."
	end
	local core = flight.core
	local rho = flight.lastRho or 0

	-- повторне P — вимкнути автопосадку
	if st.autoLand then
		setAutoLand(flight, false)
		flight:SetAttitudeMode("sas")
		return true, "Autoland OFF — you have control."
	end

	local planetId, altM = planetHere(core.Position)

	-- МІСЯЦЬ / МАРС: автопосадка двигуном із наведенням на майданчик
	if planetId == "Moon" or planetId == "Mars" then
		if not stageHasFuel(flight) then
			return false, "Autoland needs fuel in the active stage!"
		end
		setAutoLand(flight, true, planetId)
		flight:SetAttitudeMode("radial")
		local msg = "🔥 AUTOLAND (like the Apollo LM): the rocket will fly to the pad and land by itself."
			.. targetInfo(flight) .. " P — turn off."
		-- на Марсі купол допомагає економити пальне (як у Perseverance: парашут + двигуни)
		if planetId == "Mars" and st.hasChute and st.chute == "stowed" and rho >= 1e-4
			and altM <= E.MAX_DEPLOY_ALT_KM * 1000 then
			local ok, chuteMsg = deployChute(flight, altM, planetId)
			msg ..= ok and " + 🪂 parachute to save fuel." or ("\n" .. chuteMsg)
		end
		return true, msg
	end

	-- ЗЕМЛЯ: спершу парашут (якщо є), інакше автопосадка двигуном на майданчик (як Falcon 9)
	if not (st.hasChute and st.chute == "stowed") then
		if not stageHasFuel(flight) then
			if not st.hasChute then
				return false, "No parachute and no fuel in the active stage — autoland is impossible. Add a Parachute in the builder."
			end
			return false, st.chute == "open" and "The parachute is already open and steering to the pad."
				or "The parachute is already used and there is no fuel for autoland."
		end
		setAutoLand(flight, true, "Earth")
		flight:SetAttitudeMode("radial")
		return true, "🔥 EARTH AUTOLAND (like Falcon 9 at LZ-1): the rocket will return and land by itself."
			.. targetInfo(flight) .. " P — turn off."
	end
	if rho < 1e-4 then
		return false, "ERROR: no atmosphere, the parachute will not open! Deploy it in dense air (below "
			.. E.MAX_DEPLOY_ALT_KM .. " km)."
	end
	local ok, msg = deployChute(flight, altM, "Earth")
	if ok then
		-- керований купол: зносить до майданчика
		local pos, up = EDL.LandingTarget("Earth")
		st.target = { pos = pos, up = up, planet = "Earth" }
		showMarker(flight, pos, up)
		msg ..= targetInfo(flight)
	end
	return ok, msg
end

deployChute = function(flight, altM, planetId)
	local st = flight.edl
	local rho = flight.lastRho or 0
	local vel = flight.core.AssemblyLinearVelocity * M_PER_STUD
	if altM > E.MAX_DEPLOY_ALT_KM * 1000 then
		return false, string.format("Too early: %.0f km. Above %d km the air is too thin — the canopy will not inflate.",
			altM / 1000, E.MAX_DEPLOY_ALT_KM)
	end

	-- швидкісний напір q = ½ρv²: забагато — стропи не витримають
	local q = 0.5 * rho * vel.Magnitude ^ 2
	buildCanopy(flight)
	if q > E.MAX_Q then
		setState(flight, "torn")
		task.delay(0.4, removeCanopy, flight, true)
		return false, string.format("💥 CANOPY TORN! Dynamic pressure %.0f kPa > %.0f kPa. Deploy higher or brake with the engine first.",
			q / 1000, E.MAX_Q / 1000)
	end

	-- площа купола під масу ракети:  A = 2·m·g₀ / (ρ₀·v²·Cd)
	local mass = flight:MassKg()
	st.area = 2 * mass * G0 / (RHO0 * E.DESIGN_SPEED ^ 2 * E.CHUTE_CD)
	st.openT = 0
	setState(flight, "open")
	flight:SetAttitudeMode("radial")
	local diameterM = math.sqrt(4 * st.area / math.pi)
	local extra = planetId == "Mars" and " The Martian air is very thin — finish braking with the engine before touchdown!" or ""
	return true, string.format("🪂 PARACHUTE DEPLOYED — BRAKING. Canopy Ø%.0f m for a %s kg rocket.%s",
		diameterM, string.format("%d", math.floor(mass + 0.5)), extra)
end

--------------------------------------------------------------------
-- КРОК ФІЗИКИ (викликає FlightPhysics). Повертає додаткове прискорення (м/с²)
--   info: vel (м/с), rho, massKg, gVec, up, thrustAvail (Н, на 100% дроселя), altM
--------------------------------------------------------------------
function EDL.Step(flight, dt, info)
	local st = flight.edl
	if not st then
		return Vector3.zero
	end
	flight.lastRho = info.rho
	local _, altM = PlanetZoneManager.Surface(flight.core.Position)
	info.altM = altM
	local extra = Vector3.zero

	if st.chute == "open" then
		if flight.landed then
			-- після посадки купол відстрілюється, щоб не заважати виходу астронавта
			setState(flight, "cut")
			removeCanopy(flight)
			if not st.autoLand then
				st.target = nil
				hideMarker(flight)
			end
			if flight.callbacks.notify then
				flight.callbacks.notify("Canopy released after landing.", false)
			end
		else
			st.openT += dt
			local k = math.clamp(st.openT / 1.5, 0, 1) -- купол наповнюється поступово
			-- рифлення на Землі: вище REEF_ALT площа менша в (vпосадки / vриф)² разів
			local planetId = PlanetZoneManager.Surface(flight.core.Position)
			local reefed = planetId == "Earth" and info.altM > E.REEF_ALT_KM * 1000
			local area = st.area * (reefed and (E.DESIGN_SPEED / E.REEFED_SPEED) ^ 2 or 1)
			if st.reefed ~= reefed then
				st.reefed = reefed
				flight.model:SetAttribute("ChuteReefed", reefed)
				local mesh = st.canopy and st.canopy:FindFirstChildOfClass("SpecialMesh")
				if mesh then
					TweenService:Create(mesh, TweenInfo.new(1.2), { Scale = reefed and Vector3.new(0.55, 0.7, 0.55) or Vector3.one }):Play()
				end
				if not reefed and st.openT > 1 and flight.callbacks.notify then
					flight.callbacks.notify("🪂 Canopy fully open — soft descent to touchdown.", false)
				end
			end
			local speed = info.vel.Magnitude
			if speed > 0.1 and info.rho > 0 then
				local D = 0.5 * info.rho * speed * speed * E.CHUTE_CD * area * k -- F = ½ρv²·Cd·A
				local a = math.min(D / info.massKg, speed / math.max(dt, 1 / 240) * 0.5)
				extra = -info.vel.Unit * a
			end
			if flight.attitudeMode ~= "radial" then
				flight:SetAttitudeMode("radial") -- днищем до планети, щоб не перекинутись
			end
			-- 🧲 керований купол (без автопосадки — вона має свій, сильніший «магніт»)
			if st.target and not st.autoLand then
				local pull, dist = magnet(flight, info.vel, A_MAGNET_CHUTE)
				extra += pull
				flight.model:SetAttribute("AutoLandTargetM", dist)
			end
		end
	end

	if st.autoLand then
		if flight.landed then
			local hadTarget = st.target ~= nil
			local _, dist = magnet(flight, info.vel, 0)
			setAutoLand(flight, false)
			flight:SetThrottle(0)
			if not hadTarget then
				if flight.callbacks.notify then
					flight.callbacks.notify("✅ The capsule landed softly on its own. Engine off.", false)
				end
			elseif flight.callbacks.notify then
				flight.callbacks.notify(string.format("✅ Autoland complete: %.0f m from the pad center. Engine off.", dist), false)
			end
		else
			if flight.attitudeMode ~= "radial" then
				flight:SetAttitudeMode("radial")
			end
			-- цільова швидкість спуску зменшується з висотою:  v = 3 + 0.06·h  (м/с)
			-- h — від НИЗУ ракети (капсула вище за опори на groundContactM − 4 studs)
			local bottomAltM = math.max(info.altM - (flight.groundContactM - 4 * NASAData.Flight.METERS_PER_STUD), 0)
			local vR = info.vel:Dot(info.up)
			-- профіль спуску (м/с): повільний фінальний захід (≤ 18 м/с нижче 600 м), вище — швидше:
			--   v = 3 + 0.025·h + 0.035·max(h − 600, 0); у зоні підходу (~300 м) ≈ 10 м/с < 15 м/с
			-- ВИЩЕ — «самогубне гальмування» як у Falcon 9: не повільніше за швидкість, з якої двигун ще
			-- встигне зупинити ракету:  v = √(2 · ½·(aмакс − g) · h)  (половина запасу тяги — резерв).
			-- Раніше тут був стеля 120 м/с: з висоти кількох км ракета хвилинами «висіла» на двигуні та
			-- спалювала паливо зворотного рейсу (на Землі не вистачало вже на фінальних 500 м).
			--   нижче FINAL_ALT_M — ≤ 10 м/с (ця зона й вирішує «швидкість удару» у FlightPhysics, безпечно ≤ 15),
			--   вище — рівне гальмування 45% запасу тяги: v = 10 + √(2·0.45·(aмакс − g)·(h − FINAL_ALT_M))
			local FINAL_ALT_M = 500 -- з запасом: удар FlightPhysics міряє в останніх ~290 м (Земля)
			local gNow = info.gVec.Magnitude
			local aBrake = info.thrustAvail / math.max(info.massKg, 1) - gNow
			local descend
			if bottomAltM <= FINAL_ALT_M then
				descend = math.min(10, E.AUTOLAND_TOUCHDOWN + 0.05 * bottomAltM) -- 10 м/с, у самому низу 3–5
			elseif aBrake > 0.3 then
				descend = 10 + math.sqrt(2 * 0.45 * aBrake * (bottomAltM - FINAL_ALT_M))
			else
				descend = math.min(10 + 0.05 * (bottomAltM - FINAL_ALT_M), 120) -- тяги замало: обережно
			end
			descend = math.max(descend, E.AUTOLAND_TOUCHDOWN)
			-- 🧲 магніт: тягнемо до майданчика і не даємо сісти набік
			if st.target then
				local pull, dist, eta = magnet(flight, info.vel, A_MAGNET)
				extra += pull
				flight.model:SetAttribute("AutoLandTargetM", dist)
				if dist > LAND_RADIUS_M then
					-- спускаємось не швидше, ніж встигнемо долетіти, а біля землі — зависаємо
					local hold = HOLD_ALT_M
					if st.target.globe then
						hold = math.clamp(dist * HOLD_PER_M, HOLD_ALT_M, HOLD_MAX_M)
					else
						-- Земля: далеко від майданчика летимо вище (вежа, ангар, рельєф)
						hold = math.clamp(dist * 0.1, HOLD_ALT_M, 800)
					end
					descend = math.min(descend, math.max(bottomAltM - hold, 0) / math.max(eta, 0.5))
					if bottomAltM < hold then
						descend = math.max((bottomAltM - hold) * 0.3, -CLIMB_MAX) -- − = набрати висоту
					end
				end
			end
			local target = -descend
			local nose = flight.coreAtt.WorldCFrame.UpVector
			local aligned = nose:Dot(info.up) > math.cos(math.rad(25))
			local aMax = info.thrustAvail / math.max(info.massKg, 1)
			local throttle = 0
			if aligned and aMax > 0 then
				local hover = info.gVec.Magnitude / aMax -- дросель, що тримає ракету на місці
				-- додаткове прискорення = 0.5 · (цільова − фактична швидкість)
				throttle = math.clamp(hover + (target - vR) * 2.0 / aMax, 0, 1)
			end
			flight:SetThrottle(throttle)
		end
	end
	return extra
end

-- КРОК 3 (EVA): астронавт вийшов, поки ракета зависала низько над поверхнею —
-- двигун сам м'яко садить її ВЕРТИКАЛЬНО, без «магніту» до майданчика
function EDL.HoldLanding(flight)
	local st = flight.edl
	if not st or flight.landed then
		return
	end
	st.autoLand = true
	st.target = nil
	hideMarker(flight)
	flight.model:SetAttribute("AutoLand", true)
	flight.model:SetAttribute("AutoLandTargetM", nil)
end

function EDL.Cleanup(flight)
	if flight.edl and flight.edl.canopy then
		removeCanopy(flight)
	end
	if flight.edl then
		hideMarker(flight)
	end
end

return EDL
