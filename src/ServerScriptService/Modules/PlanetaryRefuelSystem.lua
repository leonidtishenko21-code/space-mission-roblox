--[[
	PlanetaryRefuelSystem (ModuleScript, СЕРВЕР) — КРОК 5: дозаправка на планеті (NASA ISRU)
	Місце: ServerScriptService > Modules > PlanetaryRefuelSystem

	ISRU (In-Situ Resource Utilization) — паливо з місцевих ресурсів:
	  Місяць: водяний лід → електроліз  2H₂O → 2H₂ + O₂  (рідкий кисень + водень)
	  Марс:    реакція Сабатьє  CO₂ + 4H₂ → CH₄ + 2H₂O  (+ MOXIE: CO₂ → O₂, як на Perseverance)

	Станції — моделі ISRU_RefuelStation у зонах Місяця / Марса (атрибут Planet; деталі Terminal,
	HoseNozzle з Attachment HoseStart, Screen з ISRUDisplay). Їх можна пересувати в Studio.

	Як заправитись:
	  • ракета стоїть на поверхні (flight.landed) не далі RANGE studs від станції тієї ж планети;
	  • астронавт у скафандрі підходить до термінала → [E] «ПРОТЯГНУТИ ШЛАНГ ISRU»,
	    або кнопка «⛽ ISRU» у HUD (атрибут гравця CanISRU) — прямо з кабіни;
	  • шланг (Beam) тягнеться від станції до бака активного ступеня, синтез 0% → 100% за REFUEL_TIME с
	    відновлює FuelMass до FuelCapacity. Потім — зворотний старт (Shift / Z).

	Атрибути гравця: CanISRU (bool), ISRUProgress (0…1, nil — не заправляється).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlanetZoneManager = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("PlanetZoneManager"))

local ISRU = {}
ISRU.notify = nil          -- function(player, text, isError) — виставляє FlightServer
ISRU.getFlight = nil       -- function(player) -> flight — виставляє FlightServer
ISRU.RANGE = 180           -- studs: ракета має стояти в посадковій зоні кратера біля станції
ISRU.REFUEL_TIME = 7       -- с: синтез і заправка 0 → 100%
ISRU.PROMPT_DISTANCE = 10

local PROCESS = {
	Moon = { color = Color3.fromRGB(150, 220, 255), text = "electrolysis of lunar ice: 2H₂O → 2H₂ + O₂" },
	Mars = { color = Color3.fromRGB(255, 150, 70), text = "Sabatier reaction from carbon dioxide: CO₂ + 4H₂ → CH₄ + 2H₂O" },
}

local stations = {} -- [model] = { planet, terminal, nozzle, start, display, busy }
local jobs = {}     -- [player] = { station, flight, stage, from, cap, t, beam, beam2, att }

local function say(player, text, isError)
	if ISRU.notify then
		ISRU.notify(player, text, isError)
	end
end

local function setDisplay(st, text, color)
	if st.display then
		st.display.Text = text
		st.display.TextColor3 = color or Color3.fromRGB(120, 255, 170)
	end
end

-- Найбільша деталь активного ступеня = бак, до нього тягнемо шланг
local function tankPart(stage)
	local best, vol = nil, 0
	for _, p in ipairs(stage:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 then
			local v = p.Size.X * p.Size.Y * p.Size.Z
			if v > vol then
				best, vol = p, v
			end
		end
	end
	return best
end

-- Найближча станція тієї ж планети, до якої дістає ракета
local function stationFor(flight)
	local pos = flight.core.Position
	local _, planet = PlanetZoneManager.Locate(pos)
	local best, bestD = nil, ISRU.RANGE
	for model, st in pairs(stations) do
		if model.Parent and st.planet == planet then
			local d = (model:GetPivot().Position - pos).Magnitude
			if d <= bestD then
				best, bestD = model, d
			end
		end
	end
	return best, bestD, planet
end

-- Чи можна заправити ракету зараз. Повертає ok, причина, станція, ступінь
function ISRU.CanRefuel(player, flight, station)
	if not flight or flight.ended or not flight.core.Parent then
		return false, "No rocket to refuel."
	end
	if jobs[player] then
		return false, "Refueling is already in progress."
	end
	local near, dist, planet = stationFor(flight)
	if station and station ~= near then
		if stations[station] and stations[station].planet ~= planet then
			return false, "Your rocket is on a different planet."
		end
		if (station:GetPivot().Position - flight.core.Position).Magnitude > ISRU.RANGE then
			return false, string.format("The rocket is too far from the station (hose reaches %d studs). Land inside the crater landing zone.", ISRU.RANGE)
		end
		near = station
	end
	if not near then
		return false, "No ISRU station nearby. Land in the crater landing zone on the Moon or Mars."
	end
	if not flight.landed then
		return false, "Land the rocket first — refueling works only on the surface."
	end
	if stations[near].busy and stations[near].busy ~= player then
		return false, "The station is in use by another astronaut."
	end
	local stage = flight:GetStage()
	if not stage or (stage:GetAttribute("Thrust") or 0) <= 0 then
		return false, "The active stage has no engine — nothing to refuel."
	end
	local cap = stage:GetAttribute("FuelCapacity") or 0
	if cap <= 0 then
		return false, "The stage has no tank."
	end
	if (stage:GetAttribute("FuelMass") or 0) >= cap * 0.995 then
		return false, "Tanks are already full — ready for liftoff!"
	end
	return true, nil, near, stage
end

--------------------------------------------------------------------
-- Шланг
--------------------------------------------------------------------
local function makeHose(station, stage, planet)
	local st = stations[station]
	local tank = tankPart(stage)
	if not (st.start and tank) then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "ISRUHoseEnd"
	att.Parent = tank
	-- точка на поверхні бака з боку станції
	local toStation = st.start.WorldPosition - tank.Position
	local side = Vector3.new(toStation.X, 0, toStation.Z)
	side = side.Magnitude > 0.1 and side.Unit or Vector3.xAxis
	local r = math.min(tank.Size.Y, tank.Size.Z) / 2
	att.WorldPosition = tank.Position + side * (r + 0.1)

	local color = (PROCESS[planet] or PROCESS.Moon).color
	local hose = Instance.new("Beam")
	hose.Name = "ISRUHose"
	hose.Attachment0 = st.start
	hose.Attachment1 = att
	hose.Width0, hose.Width1 = 0.55, 0.55
	hose.Color = ColorSequence.new(Color3.fromRGB(35, 37, 42))
	hose.LightInfluence = 1
	hose.Segments = 24
	hose.FaceCamera = true
	-- провисання шланга (дуга вниз)
	local len = (att.WorldPosition - st.start.WorldPosition).Magnitude
	hose.CurveSize0 = -len * 0.25
	hose.CurveSize1 = len * 0.25
	hose.Parent = st.start.Parent

	-- світний потік палива всередині шланга
	local flow = hose:Clone()
	flow.Name = "ISRUFlow"
	flow.Width0, flow.Width1 = 0.28, 0.28
	flow.Color = ColorSequence.new(color)
	flow.LightEmission = 1
	flow.LightInfluence = 0
	flow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	flow.TextureMode = Enum.TextureMode.Wrap
	flow.TextureLength = 2
	flow.TextureSpeed = 3
	flow.Transparency = NumberSequence.new(0.2)
	flow.Parent = st.start.Parent
	return { hose = hose, flow = flow, att = att }
end

local function finish(player, ok, text)
	local job = jobs[player]
	if not job then
		return
	end
	jobs[player] = nil
	local st = stations[job.station]
	if st then
		st.busy = nil
	end
	if player.Parent then
		player:SetAttribute("ISRUProgress", nil)
	end
	if job.flight.model.Parent then
		job.flight.model:SetAttribute("ISRUProgress", nil)
	end
	if job.fx and job.fx.flow then
		job.fx.flow.Enabled = false
	end
	if st then
		setDisplay(st, ok and "ISRU\nTANK ✔ 100%" or "ISRU\nABORTED", ok and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 120, 100))
		task.delay(6, function()
			if not st.busy then
				setDisplay(st, "ISRU\nREADY")
			end
		end)
	end
	-- шланг відчеплюється трохи згодом (відразу — якщо ракета злетіла)
	local fx = job.fx
	task.delay(ok and 1.5 or 0, function()
		if fx then
			for _, i in pairs(fx) do
				if i.Parent then
					i:Destroy()
				end
			end
		end
	end)
	if text then
		say(player, text, not ok)
	end
end

--------------------------------------------------------------------
-- Запуск заправки
--------------------------------------------------------------------
function ISRU.Start(player, station)
	local flight = ISRU.getFlight and ISRU.getFlight(player)
	local ok, reason, near, stage = ISRU.CanRefuel(player, flight, station)
	if not ok then
		say(player, "⛽ " .. reason, reason ~= "Tanks are already full — ready for liftoff!")
		return false
	end
	local st = stations[near]
	local planet = st.planet
	local fx = makeHose(near, stage, planet)
	st.busy = player
	jobs[player] = {
		station = near,
		flight = flight,
		stage = stage,
		from = stage:GetAttribute("FuelMass") or 0,
		cap = stage:GetAttribute("FuelCapacity"),
		t = 0,
		fx = fx,
	}
	flight:SetThrottle(0)
	player:SetAttribute("ISRUProgress", 0)
	setDisplay(st, "ISRU\nSYNTHESIS 0%", Color3.fromRGB(255, 220, 110))
	say(player, "⛽ ISRU hose connected. Fuel synthesis: " .. (PROCESS[planet] or PROCESS.Moon).text, false)
	return true
end

-- Щопівсекунди з FlightServer: чи показувати кнопку «⛽ ISRU»
function ISRU.Update(player, flight)
	local can = false
	if not jobs[player] and flight.landed then
		can = ISRU.CanRefuel(player, flight) == true
	end
	if player:GetAttribute("CanISRU") ~= can then
		player:SetAttribute("CanISRU", can)
	end
end

function ISRU.End(player)
	if jobs[player] then
		finish(player, false, nil)
	end
	if player.Parent then
		player:SetAttribute("CanISRU", nil)
	end
end

-- Процес заправки (плавна шкала 0 → 100%)
RunService.Heartbeat:Connect(function(dt)
	for player, job in pairs(jobs) do
		local flight = job.flight
		if flight.ended or not job.stage.Parent or not job.stage:IsDescendantOf(flight.model) then
			finish(player, false, nil)
		elseif not flight.landed then
			finish(player, false, "⛽ ISRU hose torn off: the rocket moved. Refueling aborted.")
		else
			job.t += dt
			local k = math.clamp(job.t / ISRU.REFUEL_TIME, 0, 1)
			job.stage:SetAttribute("FuelMass", job.from + (job.cap - job.from) * k)
			local pct = math.floor(k * 100)
			if pct ~= job.lastPct then
				job.lastPct = pct
				player:SetAttribute("ISRUProgress", k)
				flight.model:SetAttribute("ISRUProgress", k)
				local st = stations[job.station]
				if st then
					setDisplay(st, string.format("ISRU\nSYNTHESIS %d%%", pct), Color3.fromRGB(255, 220, 110))
				end
			end
			if k >= 1 then
				job.stage:SetAttribute("FuelMass", job.cap)
				local sample = player:GetAttribute("SamplePlanet") ~= nil
				finish(player, true, "✅ TANK REFUELED 100% (ISRU). "
					.. (sample and "Board the capsule and launch for Earth: Shift / Z — throttle, [P] — parachute or autoland."
						or "Do not forget to collect a planet sample before liftoff!"))
			end
		end
	end
end)

--------------------------------------------------------------------
-- Станції: підказка «ПРОТЯГНУТИ ШЛАНГ ISRU» [E] біля термінала
--------------------------------------------------------------------
local function wire(model)
	if stations[model] or not model:IsA("Model") then
		return
	end
	local terminal = model:FindFirstChild("Terminal", true)
	local nozzle = model:FindFirstChild("HoseNozzle", true)
	if not terminal then
		return
	end
	local start = nozzle and nozzle:FindFirstChild("HoseStart")
	if not start then
		start = Instance.new("Attachment")
		start.Name = "HoseStart"
		start.Parent = nozzle or terminal
	end
	local screen = model:FindFirstChild("Screen", true)
	local gui = screen and screen:FindFirstChild("ISRUDisplay")
	local planet = model:GetAttribute("Planet")
	if not planet then
		local _, id = PlanetZoneManager.Locate(model:GetPivot().Position)
		planet = id or "Moon"
	end
	stations[model] = {
		planet = planet,
		terminal = terminal,
		start = start,
		display = gui and gui:FindFirstChild("Status"),
	}
	local prompt = terminal:FindFirstChild("ISRUPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ISRUPrompt"
		prompt.Parent = terminal
	end
	prompt.ActionText = "CONNECT ISRU HOSE"
	prompt.ObjectText = "Refueling station"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.8
	prompt.MaxActivationDistance = ISRU.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player)
		if player:GetAttribute("EVA") ~= true then
			say(player, "⛽ Only a suited astronaut on EVA can use the terminal.", true)
			return
		end
		ISRU.Start(player, model)
	end)
	setDisplay(stations[model], "ISRU\nREADY")
end

for _, d in ipairs(workspace:GetDescendants()) do
	if d.Name == "ISRU_RefuelStation" then
		wire(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if d.Name == "ISRU_RefuelStation" then
		task.defer(wire, d)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if jobs[player] then
		finish(player, false, nil)
	end
end)

return ISRU
