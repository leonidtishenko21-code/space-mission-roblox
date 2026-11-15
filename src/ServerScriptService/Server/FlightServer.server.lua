--[[
	FlightServer (Script)
	Місце: ServerScriptService > Server > FlightServer

	Зв'язує все докупи (Фаза 2–3 — політ і наукова місія):
	  ангар ──ToPad──▶ стартовий стіл ──Ignite (відлік T−5)──▶ політ ──(удар / завершення)──▶ звіт ▶ ангар
	             ◀──ToHangar──

	Відлік на сервері (бачать усі гравці): T−2 відводиться пускова вежа, T−0 — запалювання,
	дим та іскри з газовідвідного жолоба (LaunchSite).

	RemoteEvents (ReplicatedStorage > Remotes):
	  LaunchRocket(action)   — "ToPad" | "ToHangar" | "Ignite" | "End"
	  FlightInput(dir)       — Vector3 (X, 0, Z): куди нахиляти ракету (W/S/A/D відносно камери)
	  TriggerStage()         — відстріл ступеня
	  JettisonFairing()      — скинути обтічник
	  ScienceAction(kind)    — "theodolite" | "scan" | "drill" (ScienceMissionController)
	  FlightReport (сервер → клієнт) — підсумок місії для вікна звіту

	Атрибут гравця RocketState: "Hangar" | "OnPad" | "Flight" (дублює State моделі для клієнта).
	Клієнту не довіряємо: усі перевірки стану — тут.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local RocketMath = require(modules:WaitForChild("RocketMath"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))
local serverModules = ServerScriptService:WaitForChild("Modules")
local RocketAssembler = require(serverModules:WaitForChild("RocketAssembler"))
local FlightPhysics = require(serverModules:WaitForChild("FlightPhysics"))
local StageController = require(serverModules:WaitForChild("StageController"))
local LaunchSite = require(serverModules:WaitForChild("LaunchSite"))
local Science = require(serverModules:WaitForChild("ScienceMissionController"))
local EDL = require(serverModules:WaitForChild("EDLBrakingSystems"))
local CapsuleSeatSystem = require(serverModules:WaitForChild("CapsuleSeatSystem"))
local SpacesuitManager = require(serverModules:WaitForChild("SpacesuitManager"))
local EVA = require(serverModules:WaitForChild("EVAExitController"))
local SampleMission = require(serverModules:WaitForChild("SampleCollectionMission"))
local ISRU = require(serverModules:WaitForChild("PlanetaryRefuelSystem"))

local F = NASAData.Flight
local COUNTDOWN = 5               -- с: відлік T−5 … T−0
local TOWER_AT = 2                -- на T−2 відводимо вежу
local FUEL_BONUS = 5000           -- [ГРА] $ максимум за економію палива (пропорційно залишку)
local SAMPLE_RETURN_REWARD = 100000 -- [ГРА] $ за доставлений на Землю зразок (Sample Return Mission)

--------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local function getRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end

local launchEvent = getRemote("LaunchRocket")
local inputEvent = getRemote("FlightInput")
local stageEvent = getRemote("TriggerStage")
local fairingEvent = getRemote("JettisonFairing")
local scienceEvent = getRemote("ScienceAction")
local reportEvent = getRemote("FlightReport")
local attitudeEvent = getRemote("AttitudeMode")
local edlEvent = getRemote("EDLAction")
local notifyEvent = getRemote("Notify")
local suitEvent = getRemote("SpacesuitAction") -- "light" | "jets" (bool) | "remove"
-- КРОК 5: EVAAction "isru" — кнопка «⛽ ISRU» у HUD (дозаправка на планеті)
local evaEvent = getRemote("EVAAction")        -- "exit" (КРОК 3: [E] — вийти з капсули)

local function notify(player, text, isError)
	notifyEvent:FireClient(player, text, isError == true)
end
SpacesuitManager.notify = notify
EVA.notify = notify
SampleMission.notify = notify
ISRU.notify = notify

local fmt = function(n)
	local s = tostring(math.floor(math.abs(n) + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

--------------------------------------------------------------------
-- Допоміжне
--------------------------------------------------------------------
local flights = {}       -- [player] = FlightPhysics
local counting = {}      -- [player] = true під час відліку
local lastCommand = {}   -- [player] = os.clock() (захист від спаму кнопок)
ISRU.getFlight = function(player)
	return flights[player]
end

local function findRocket(player)
	local folder = workspace:FindFirstChild("Rockets")
	if not folder then
		return nil
	end
	for _, m in ipairs(folder:GetChildren()) do
		if m:GetAttribute("OwnerUserId") == player.UserId then
			return m
		end
	end
	return nil
end

local function setState(player, model, state)
	if model then
		model:SetAttribute("State", state)
	end
	player:SetAttribute("RocketState", state)
end

local function teleport(player, cframe)
	-- спершу висаджуємо з крісла: інакше PivotTo потягне за собою всю ракету
	CapsuleSeatSystem.Release(player)
	local character = player.Character
	if character and character.PrimaryPart then
		character:PivotTo(cframe)
	end
end

-- Оглядовий майданчик: перед стартовим столом, обличчям до ракети
local function viewingSpot()
	local base = RocketAssembler.GetLaunchBase()
	local pos = Vector3.new(base.X, 5, base.Z - 55)
	return CFrame.lookAt(pos, Vector3.new(base.X, pos.Y, base.Z))
end

local function hangarSpot()
	local hangar = workspace:FindFirstChild("Hangar")
	local spawnPart = hangar and hangar:FindFirstChild("HangarSpawn")
	if spawnPart then
		return spawnPart.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(0, 5, -40)
end

local function clearRocket(player)
	player:SetAttribute("RocketBuilt", false)
	player:SetAttribute("RocketDesign", nil)
	player:SetAttribute("RocketCost", nil)
	player:SetAttribute("RocketFuel", nil)
	player:SetAttribute("RocketFuelCapacity", nil)
	player:SetAttribute("RocketState", nil)
end

local function designOf(player)
	local ok, raw = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("RocketDesign") or "")
	return ok and RocketMath.Sanitize(raw) or nil
end

-- Скільки палива лишилось у ракеті (частка від заправленого на старті)
local function fuelLeftFraction(flight)
	local left = 0
	for _, g in ipairs(flight.model:GetChildren()) do
		if g:IsA("Folder") then
			left += g:GetAttribute("FuelMass") or 0
		end
	end
	return flight.startFuel and flight.startFuel > 0 and math.clamp(left / flight.startFuel, 0, 1) or 0
end

--------------------------------------------------------------------
-- Звіт місії: оцінка інженерної ефективності
--   +30 космос (≥100 км) · +15 за кожен набір наукових даних · +15 посадка в кратері
--   +до 10 за залишок палива · −20 аварія
--------------------------------------------------------------------
local END_TITLES = {
	crash = "💥 The rocket crashed",
	landed = "The rocket returned to Earth intact",
	maxAltitude = "🚀 Left the simulation limit (" .. F.MAX_ALTITUDE_KM .. " km)",
	noLiftoff = "The rocket never lifted off the pad",
	manual = "Flight ended",
}

-- $ за висоту (апогей) — нараховується після БУДЬ-якого польоту, успішного чи ні
local function altitudePayOf(flight)
	return math.floor(flight.apogeeM / 1000 * F.ALTITUDE_PAY_PER_KM / 100 + 0.5) * 100
end

local function buildReport(player, flight, reason)
	local design = designOf(player)
	local stats = design and RocketMath.Compute(design)
	local science = flight.science or { log = {}, reward = 0 }
	local fuelLeft = fuelLeftFraction(flight)
	local reachedSpace = flight.apogeeM >= F.TARGET_ALTITUDE_KM * 1000

	local score = 0
	if reachedSpace then
		score += 30
	end
	score += 15 * #science.log
	if flight.landedOnSurface then
		score += flight.hardLanding and 5 or 15
	end
	local landedOn = {}
	for id in pairs(flight.landedZones or {}) do
		table.insert(landedOn, PlanetZoneManager.CONFIG[id].name)
	end
	score += math.floor(10 * fuelLeft + 0.5)
	if reason == "crash" then
		score -= 20
	end
	score = math.clamp(score, 0, 100)
	local grade = (score >= 85 and "A") or (score >= 65 and "B") or (score >= 40 and "C") or "D"

	-- 🏆 КРОК 5: Sample Return Mission — м'яка посадка на Землю зі зразком у вантажному відсіку
	local sampleReturn = reason == "landed" and not flight.hardLanding
		and player:GetAttribute("SamplePlanet") ~= nil and player:GetAttribute("SampleStowed") == true
	local sampleReward = 0
	if sampleReturn then
		score = 100 -- максимальний рейтинг
		grade = "S"
		sampleReward = SAMPLE_RETURN_REWARD
	end

	-- бонус за економію палива — лише якщо місія щось дала (космос або наука)
	local fuelBonus = 0
	if reason ~= "crash" and (reachedSpace or #science.log > 0) then
		fuelBonus = math.floor(FUEL_BONUS * fuelLeft / 100 + 0.5) * 100
	end

	-- оплата за висоту: $ за кожен км апогею — ЗАВЖДИ повна, навіть після аварії
	local altitudePay = altitudePayOf(flight)

	return {
		title = sampleReturn and "🏆 SAMPLE RETURN MISSION — SAMPLE DELIVERED TO EARTH"
			or END_TITLES[reason] or "Flight ended",
		reason = reason,
		crashed = reason == "crash",
		apogeeKm = flight.apogeeM / 1000,
		maxSpeed = flight.maxSpeed,
		time = flight.time,
		impactSpeed = flight.impactSpeed,
		cost = player:GetAttribute("RocketCost") or 0,
		deltaV = stats and stats.deltaV or 0,
		fuelLeftPct = fuelLeft * 100,
		reachedSpace = reachedSpace,
		landedOnCrater = flight.landedOnSurface == true,
		landedOn = landedOn,
		science = science.log,
		rewards = (reachedSpace and F.MISSION_REWARD or 0) + science.reward + fuelBonus + altitudePay + sampleReward,
		sampleReturn = sampleReturn,
		sampleReward = sampleReward,
		hardLanding = flight.hardLanding == true,
		fuelBonus = fuelBonus,
		altitudePay = altitudePay,
		score = score,
		grade = grade,
		-- КРОК 4: зразок планети (переможне вікно Sample Return — КРОК 5)
		samplePlanet = player:GetAttribute("SamplePlanet"),
		sampleName = player:GetAttribute("SampleName"),
		sampleOnBoard = player:GetAttribute("SampleStowed") == true,
	}
end

--------------------------------------------------------------------
-- Політ
--------------------------------------------------------------------
local function onEnded(player, flight, reason)
	flights[player] = nil
	EVA.End(player) -- астронавт на поверхні: прибираємо люк і атрибути EVA
	ISRU.End(player) -- шланг дозаправки
	Science.Leave(flight)
	EDL.Cleanup(flight) -- маяк майданчика та купол
	local model = flight.model

	-- Гравець сам завершив політ, жодного разу не сівши: автореспавн, бюджет — як на момент старту
	-- (нагороди цього польоту скасовуються, звіт не показуємо)
	local aborted = reason == "manual" and not flight.landedOnSurface
	local abortPay = aborted and altitudePayOf(flight) or 0
	if aborted and player.Parent and flight.budgetAtLaunch then
		player:SetAttribute("Budget", flight.budgetAtLaunch + abortPay) -- бюджет старту + оплата за висоту
	end

	if reason ~= "lost" and not aborted and player.Parent then
		local report = buildReport(player, flight, reason)
		local payout = report.fuelBonus + report.altitudePay + report.sampleReward
		if payout > 0 then
			player:SetAttribute("Budget", (player:GetAttribute("Budget") or 0) + payout)
		end
		reportEvent:FireClient(player, report)
	end

	if reason == "crash" and flight.core.Parent then
		local boom = Instance.new("Explosion")
		boom.Position = flight.core.Position
		boom.BlastPressure = 0
		boom.DestroyJointRadiusPercent = 0
		boom.BlastRadius = 12
		boom.Parent = workspace
		task.wait(1.5)
	else
		task.wait(0.5)
	end

	CapsuleSeatSystem.Release(player)
	SampleMission.Reset(player) -- звіт уже врахував зразок; наступна місія — з порожнім контейнером
	if model.Parent then
		model:Destroy()
	end
	LaunchSite.Release(player.UserId)
	task.delay(2, LaunchSite.ResetTower)
	if player.Parent then
		-- Ракета витрачена: гроші та пальне не повертаються (на відміну від розбирання в ангарі)
		clearRocket(player)
		player.ReplicationFocus = nil
		if aborted then
			SpacesuitManager.Unequip(player)
			player:LoadCharacter() -- автореспавн
			task.delay(1.5, notify, player, string.format("Flight aborted without landing. You respawned: budget restored to $%s + $%s altitude pay (apogee %.1f km).",
				fmt(flight.budgetAtLaunch or 0), fmt(abortPay), flight.apogeeM / 1000), false)
			return
		end
		teleport(player, hangarSpot())
		if SpacesuitManager.IsEquipped(player) then
			task.delay(3, notify, player, "🧑‍🚀 You are back on Earth. Press [K] to take off the spacesuit.", false)
		end
	end
end

local function startFlight(player, model)
	RocketAssembler.Unlock(model) -- зняття блокування на старт
	setState(player, model, "Flight")
	player.ReplicationFocus = model.PrimaryPart -- стрімінг вантажить світ навколо ракети, а не персонажа

	local flight
	flight = FlightPhysics.new(model, {
		gravityVector = PlanetZoneManager.GravityVector, -- біля Місяця / Марса — сферичне тяжіння до центру
		edl = EDL.Step,                                  -- парашут і автопосадка
		notify = function(text, isError)
			notify(player, text, isError)
		end,
		density = PlanetZoneManager.AirDensity,  -- розріджена атмосфера Марса (опір під час посадки)
		surface = Science.SurfaceBelow,          -- посадка на планету не завершує політ
		onBurnout = function(_, k)
			if model:FindFirstChild("Decoupler" .. k) then
				notify(player, "Stage " .. k .. " is out of fuel — separate it [SPACE]!", false)
			else
				notify(player, "Out of fuel. The rocket is now coasting on a ballistic trajectory.", false)
			end
		end,
		onTargetReached = function()
			player:SetAttribute("Budget", (player:GetAttribute("Budget") or 0) + F.MISSION_REWARD)
			notify(player, "🎉 Kármán line (" .. F.TARGET_ALTITUDE_KM .. " km) crossed — you are in space! +$" .. fmt(F.MISSION_REWARD), false)
			-- вихід у космос: астронавт надягає скафандр NASA
			if SpacesuitManager.Equip(player) then
				task.delay(2.5, notify, player, "🧑‍🚀 NASA spacesuit sealed. [L] — headlamp, [V] — cockpit view.", false)
			end
		end,
		onSurfaceLanding = function(f, impact)
			local _, id = PlanetZoneManager.Locate(f.core.Position)
			local cfg = id and PlanetZoneManager.CONFIG[id]
			f.landedZone = id
			f.landedZones = f.landedZones or {}
			if id then
				f.landedZones[id] = true
			end
			model:SetAttribute("LandedZone", id or "")
			local where = cfg and ("ON " .. cfg.nameOn) or "ON THE SURFACE"
			if f.hardLanding then
				notify(player, string.format("⚠ HARD LANDING %s (%.0f m/s): landing legs damaged. Safe is up to 15 m/s; landing legs and a gentle throttle help.", where, impact), true)
			else
				notify(player, string.format("✅ SUCCESSFUL LANDING %s (%.1f m/s)!", where, impact)
					.. (id == "Moon" and " You can drill for ice now." or ""), false)
			end
		end,
		onEnded = function(_, reason)
			onEnded(player, flight, reason)
		end,
	})
	local fuel = 0
	for _, g in ipairs(model:GetChildren()) do
		if g:IsA("Folder") then
			fuel += g:GetAttribute("FuelMass") or 0
		end
	end
	flight.startFuel = fuel
	flight.budgetAtLaunch = player:GetAttribute("Budget") or 0 -- для автореспавну без посадки
	EDL.Attach(flight)
	flights[player] = flight
	flight:Start()
	notify(player, "Liftoff! W/S/A/D — tilt the rocket, SPACE — stage separation. 🎯 Target: the lunar crater at 100 km.", false)
end

-- Відлік T−5 … T−0 (атрибут моделі Countdown бачать усі клієнти)
local function runCountdown(player, model)
	counting[player] = true
	LaunchSite.SetVenting(true)
	for t = COUNTDOWN, 1, -1 do
		if not model.Parent or not player.Parent or player:GetAttribute("RocketState") ~= "OnPad" then
			counting[player] = nil
			LaunchSite.SetVenting(false)
			if model.Parent then
				model:SetAttribute("Countdown", nil)
			end
			return
		end
		model:SetAttribute("Countdown", t)
		if t == TOWER_AT then
			LaunchSite.RetractTower()
		end
		task.wait(1)
	end
	model:SetAttribute("Countdown", 0)
	counting[player] = nil
	LaunchSite.SetVenting(false)
	LaunchSite.Ignition()
	startFlight(player, model)
	task.delay(1.5, function()
		if model.Parent then
			model:SetAttribute("Countdown", nil)
		end
	end)
end

--------------------------------------------------------------------
-- Команди гравця
--------------------------------------------------------------------
launchEvent.OnServerEvent:Connect(function(player, action)
	if type(action) ~= "string" then
		return
	end
	local now = os.clock()
	if lastCommand[player] and now - lastCommand[player] < 0.5 then
		return
	end
	lastCommand[player] = now

	local model = findRocket(player)
	local state = player:GetAttribute("RocketState")

	if action == "ToPad" then
		if not model or not player:GetAttribute("RocketBuilt") or (state or "Hangar") ~= "Hangar" then
			return
		end
		local fuel = player:GetAttribute("RocketFuel") or 0
		if fuel <= 0 then
			notify(player, "The tanks are empty — fuel the rocket in the builder first.", true)
			return
		end
		if not LaunchSite.TryClaim(player.UserId) then
			notify(player, "The launch pad is occupied by another rocket. Wait for it to lift off.", true)
			return
		end
		LaunchSite.ResetTower()
		RocketAssembler.LaunchPadSpawn(model, fuel)
		setState(player, model, "OnPad")
		-- КРОК 1: астронавт сідає в крісло капсули (старі ракети без крісла — оглядовий майданчик)
		local seated = CapsuleSeatSystem.Seat(player, model)
		if not seated then
			teleport(player, viewingSpot())
		end
		local cap = player:GetAttribute("RocketFuelCapacity") or fuel
		notify(player, string.format("Rocket on the launch pad (fuel %d%%).%s Press LAUNCH.",
			math.floor(fuel / math.max(cap, 1) * 100 + 0.5),
			seated and " You are in the capsule: [V] — outside / cockpit view." or ""), false)

	elseif action == "ToHangar" then
		if not model or state ~= "OnPad" or counting[player] then
			return
		end
		RocketAssembler.MoveTo(model, model:GetAttribute("HangarBase"))
		setState(player, model, "Hangar")
		LaunchSite.Release(player.UserId)
		teleport(player, hangarSpot())

	elseif action == "Ignite" then
		if not model or state ~= "OnPad" or flights[player] or counting[player] then
			return
		end
		task.spawn(runCountdown, player, model)

	elseif action == "End" then
		local flight = flights[player]
		if flight then
			flight:Stop("manual")
		end
	end
end)

inputEvent.OnServerEvent:Connect(function(player, dir, throttle)
	local flight = flights[player]
	if not flight or typeof(dir) ~= "Vector3" or dir ~= dir then -- dir ~= dir відкидає NaN
		return
	end
	-- поки астронавт назовні (EVA), керувати ракетою нікому
	if EVA.IsOut(player) then
		return
	end
	-- під час автопосадки дроселем керує EDL, а не гравець
	if type(throttle) == "number" and throttle == throttle and not (flight.edl and flight.edl.autoLand) then
		flight:SetThrottle(throttle)
	end
	-- dir — запит повороту (світова вісь × сила); обмежуємо силу
	if dir.Magnitude > 1.8 then
		dir = dir.Unit * 1.8
	end
	flight:SetInput(dir)
end)

stageEvent.OnServerEvent:Connect(function(player)
	local flight = flights[player]
	if not flight or EVA.IsOut(player) then
		return
	end
	local now = os.clock()
	if flight.lastStageTime and now - flight.lastStageTime < 1 then
		return
	end
	flight.lastStageTime = now
	local ok, message = StageController.TriggerStage(flight)
	notify(player, message, not ok)
end)

fairingEvent.OnServerEvent:Connect(function(player)
	local flight = flights[player]
	if not flight then
		return
	end
	local ok, message = StageController.JettisonFairing(flight)
	notify(player, message, not ok)
end)

-- EDL: парашут / автопосадка (клавіша P)
edlEvent.OnServerEvent:Connect(function(player, action)
	local flight = flights[player]
	if not flight or action ~= "parachute" or EVA.IsOut(player) then
		return
	end
	local now = os.clock()
	if flight.lastEdlTime and now - flight.lastEdlTime < 0.6 then
		return
	end
	flight.lastEdlTime = now
	local ok, message = EDL.Activate(flight)
	notify(player, message, not ok)
end)

-- Режим орієнтації: "sas" | "free" | "retrograde" | "radial" (FlightPhysics перевіряє значення)
attitudeEvent.OnServerEvent:Connect(function(player, mode)
	local flight = flights[player]
	if flight and type(mode) == "string" then
		flight:SetAttitudeMode(mode)
	end
end)

-- Скафандр: ліхтарик [L], мікродвигуни (візуально), зняття [K] — лише на Землі, не в польоті
local lastSuitCommand = {}
suitEvent.OnServerEvent:Connect(function(player, action, value)
	if type(action) ~= "string" or not SpacesuitManager.IsEquipped(player) then
		return
	end
	if action == "jets" then
		-- двигуни працюють лише поза кріслом
		SpacesuitManager.SetJets(player, value == true and not player:GetAttribute("InCapsule"))
		return
	end
	local now = os.clock()
	if lastSuitCommand[player] and now - lastSuitCommand[player] < 0.3 then
		return
	end
	lastSuitCommand[player] = now
	if action == "light" then
		local ok, message = SpacesuitManager.ToggleLight(player)
		notify(player, message, not ok)
	elseif action == "remove" then
		if flights[player] or counting[player] or player:GetAttribute("InCapsule") then
			notify(player, "You can only take off the spacesuit on Earth after landing.", true)
			return
		end
		SpacesuitManager.Unequip(player)
		notify(player, "Spacesuit removed and sent for servicing. Great mission!", false)
	end
end)

-- КРОК 3: вихід з капсули [E] (усі перевірки — EVAExitController.CanExit)
local lastEvaCommand = {}
evaEvent.OnServerEvent:Connect(function(player, action)
	if action ~= "exit" and action ~= "board" and action ~= "sample" and action ~= "isru" then
		return
	end
	local now = os.clock()
	if lastEvaCommand[player] and now - lastEvaCommand[player] < 1 then
		return
	end
	lastEvaCommand[player] = now
	if action == "exit" then
		EVA.Exit(player, flights[player])
	elseif action == "isru" then
		ISRU.Start(player) -- кнопка HUD: найближча станція, усі перевірки — у модулі
	elseif action == "sample" then
		-- запасний шлях до ProximityPrompt зразка: усі перевірки (EVA, дистанція) — у модулі
		SampleMission.CollectNearest(player)
	else
		-- запасний шлях до ProximityPrompt (кнопка / мобільні): дистанцію до люка перевіряє EVA.Board
		EVA.Board(player)
	end
end)

scienceEvent.OnServerEvent:Connect(function(player, kind)
	local flight = flights[player]
	if not flight or type(kind) ~= "string" then
		return
	end
	local ok, message = Science.Run(flight, player, kind, notify)
	notify(player, message, not ok)
end)

-- Пункт «Рідкий кисень (LOX)» біля баків: скільки LOX у ракеті і навіщо він
if LaunchSite.LOXPrompt then
	LaunchSite.LOXPrompt.Triggered:Connect(function(player)
		local fuel = player:GetAttribute("RocketFuel") or 0
		local loxKg = fuel * (1 - NASAData.Constants.RP1_SHARE)
		local text = "❄ Liquid oxygen (LOX), −183 °C. RP-1 engines burn ≈ 2.36 kg of LOX per 1 kg of kerosene."
		if fuel > 0 then
			text ..= string.format("\nYour rocket tanks hold: %s kg LOX + %s kg RP-1.", fmt(loxKg), fmt(fuel - loxKg))
		else
			text ..= "\nOxygen is loaded automatically together with RP-1 in the builder."
		end
		notify(player, text, false)
	end)
end

-- Наукова зона: атрибути для HUD і підсвічування маяків (~2 рази на секунду)
local zoneTimer = 0
RunService.Heartbeat:Connect(function(dt)
	zoneTimer += dt
	if zoneTimer < 0.5 then
		return
	end
	zoneTimer = 0
	for player, flight in pairs(flights) do
		if not flight.ended and flight.core.Parent then
			Science.Update(flight)
			EVA.ServerOwn(flight) -- крісло з астронавтом віддає ракету клієнту — повертаємо серверу
			EVA.Update(player, flight)
			ISRU.Update(player, flight)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local flight = flights[player]
	if flight then
		flight:Stop("lost")
	end
	flights[player] = nil
	counting[player] = nil
	lastCommand[player] = nil
	lastSuitCommand[player] = nil
	lastEvaCommand[player] = nil
	EVA.End(player)
	ISRU.End(player)
	SampleMission.Reset(player)
	CapsuleSeatSystem.Release(player)
	LaunchSite.Release(player.UserId)
end)
