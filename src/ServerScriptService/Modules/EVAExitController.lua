--[[
	EVAExitController (ModuleScript, СЕРВЕР) — КРОК 3: вихід астронавта на поверхню (EVA)
	Місце: ServerScriptService > Modules > EVAExitController

	Вихід [E] дозволено лише на МІСЯЦІ / МАРСІ, коли ракета:
	  • стоїть на поверхні (flight.landed), або
	  • зависає: низ ракети < 15 studs над ґрунтом і швидкість < 15 м/с
	    (тоді двигун сам м'яко садить порожню капсулу — EDL.HoldLanding)
	На Землі посадка завершує політ (звіт → ангар), тому EVA там не потрібне.

	Під час EVA:
	  • атрибути гравця: EVA = true, EVAGravity = g планети (м/с²), EVAPlanet = "Moon" | "Mars"
	    (AstronautClient робить низьку гравітацію, стрибки та ранець на Space)
	  • біля люка — ProximityPrompt «СІСТИ В КАПСУЛУ [F]» (спрацьовує лише для власника)
	  • скафандр витрачає O₂ (SpacesuitManager); коли O₂ = 0 — астронавт тратить здоров'я
	  • загибель астронавта перериває місію
	Атрибут CanEVA (гравець) — чи можна зараз вийти (підказка [E] у HUD).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))
local CapsuleSeatSystem = require(script.Parent:WaitForChild("CapsuleSeatSystem"))
local SpacesuitManager = require(script.Parent:WaitForChild("SpacesuitManager"))
local EDL = require(script.Parent:WaitForChild("EDLBrakingSystems"))

local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

local EVA = {}
EVA.notify = nil              -- function(player, text, isError) — виставляє FlightServer
EVA.MAX_HOVER_ALT = 15        -- studs: нижче — можна вистрибнути із завислої капсули
EVA.MAX_HOVER_SPEED = 15      -- м/с (як безпечна посадка)
EVA.MIN_UP_DOT = 0.75         -- на крутому боці планети-сфери ходити не вийде (≈ 41° від вершини)
EVA.BOARD_DISTANCE = 14       -- studs від люка
local O2_DAMAGE = 6           -- HP/с, коли кисень скінчився
local STAND_OFF = 7           -- studs від краю ракети до точки виходу (опори й сопла не заважають)

local sessions = {} -- [player] = { flight, hatch, prompt, conns }

local function say(player, text, isError)
	if EVA.notify then
		EVA.notify(player, text, isError)
	end
end

local function rocketParams(flight)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { flight.model }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local marker = workspace:FindFirstChild("LandingTargetMarker")
	if marker then
		table.insert(ignore, marker)
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Відстань від центру ядра до НИЗУ ракети вздовж гравітації (studs) — як у FlightPhysics
local function bottomReach(flight, gdir)
	local core = flight.core
	local reach = 0
	for _, p in ipairs(flight.model:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			local cf, s = p.CFrame, p.Size
			local ext = math.abs(gdir:Dot(cf.RightVector)) * s.X / 2 + math.abs(gdir:Dot(cf.UpVector)) * s.Y / 2
				+ math.abs(gdir:Dot(cf.LookVector)) * s.Z / 2
			reach = math.max(reach, (p.Position - core.Position):Dot(gdir) + ext)
		end
	end
	return reach
end

-- Чи можна зараз вийти. Повертає: ok, причина відмови, дані { planet, up, hovering }
function EVA.CanExit(player, flight)
	if not flight or flight.ended or not flight.core.Parent then
		return false, "The rocket is not in flight."
	end
	if not player:GetAttribute("InCapsule") or sessions[player] then
		return false, "You are not in the capsule."
	end
	local core = flight.core
	local _, planet = PlanetZoneManager.Locate(core.Position)
	if planet ~= "Moon" and planet ~= "Mars" then
		return false, "Spacewalks in open space are not allowed. Land on the Moon or Mars first."
	end
	local gVec = PlanetZoneManager.GravityVector(core.Position, 9.81)
	local gdir = gVec.Magnitude > 1e-6 and gVec.Unit or -Vector3.yAxis
	local up = -gdir
	if up.Y < EVA.MIN_UP_DOT then
		return false, "The slope here is too steep — land closer to the crater / canyon."
	end
	-- вихід ЛИШЕ після посадки (зависання чи політ — не можна)
	if not flight.landed then
		return false, "You can only leave the capsule after the rocket has landed."
	end
	return true, nil, { planet = planet, up = up, hovering = false }
end

-- Точка біля опор ракети на ґрунті (де стає астронавт і де люк для повернення)
local function groundSpot(flight, up)
	local core = flight.core
	local side = core.CFrame.RightVector
	side = side - up * side:Dot(up)
	if side.Magnitude < 0.1 then
		side = Vector3.xAxis
	end
	side = side.Unit
	local params = rocketParams(flight)
	-- пробуємо кілька боків — беремо перший, де є ґрунт
	for i = 0, 3 do
		local dir = CFrame.fromAxisAngle(up, i * math.pi / 2):VectorToWorldSpace(side)
		-- наскільки ракета (разом із опорами) виступає в цей бік
		local radius = math.clamp(bottomReach(flight, dir), 2, 30)
		local origin = core.Position + dir * (radius + STAND_OFF) + up * 25
		local hit = workspace:Raycast(origin, -up * 400, params)
		if hit then
			return hit.Position, dir
		end
	end
	return core.Position + side * (math.clamp(bottomReach(flight, side), 2, 30) + STAND_OFF), side
end

-- Фізику ракети веде СЕРВЕР (античит). Крісло Seat і авто-розподіл Roblox віддають її клієнту
-- найближчого гравця — тоді персонаж, що виходить, «виштовхує» капсулу вгору. Повертаємо серверу.
function EVA.ServerOwn(flight)
	local core = flight and flight.core
	if core and core.Parent and not core.Anchored and (core:GetNetworkOwnershipAuto() or core:GetNetworkOwner() ~= nil) then
		pcall(core.SetNetworkOwner, core, nil)
	end
end

local function clearSession(player)
	local s = sessions[player]
	if not s then
		return
	end
	sessions[player] = nil
	for _, c in ipairs(s.conns) do
		c:Disconnect()
	end
	if s.hatch and s.hatch.Parent then
		s.hatch:Destroy()
	end
	if player.Parent then
		player:SetAttribute("EVA", nil)
		player:SetAttribute("EVAGravity", nil)
		player:SetAttribute("EVAPlanet", nil)
	end
end

function EVA.IsOut(player)
	return sessions[player] ~= nil
end

--------------------------------------------------------------------
-- Повернення в капсулу (ProximityPrompt «СІСТИ В КАПСУЛУ [F]»)
--------------------------------------------------------------------
function EVA.Board(player)
	local s = sessions[player]
	if not s then
		return false
	end
	local flight = s.flight
	if flight.ended or not flight.model.Parent then
		clearSession(player)
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not s.hatch.Parent or (root.Position - s.hatch.WorldPosition).Magnitude > EVA.BOARD_DISTANCE + 6 then
		say(player, "Get closer to the capsule hatch.", true)
		return false
	end
	clearSession(player)
	if not CapsuleSeatSystem.Seat(player, flight.model) then
		say(player, "Could not get into the capsule seat.", true)
		return false
	end
	EVA.ServerOwn(flight)
	SpacesuitManager.SetJets(player, false)
	say(player, "🚀 You are in the capsule. Hatch sealed, O₂ refilling. Shift / Z — throttle for liftoff.", false)
	return true
end

--------------------------------------------------------------------
-- Вихід з капсули [E]
--------------------------------------------------------------------
function EVA.Exit(player, flight)
	local ok, reason, info = EVA.CanExit(player, flight)
	if not ok then
		say(player, "🚪 " .. reason, true)
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and humanoid.Health > 0 and character.PrimaryPart) then
		return false
	end
	if not SpacesuitManager.IsEquipped(player) then
		SpacesuitManager.Equip(player) -- без скафандра назовні не вийдеш
	end

	-- порожня капсула: на ґрунті — двигун вимкнено, у зависанні — сама м'яко сідає
	if info.hovering then
		EDL.HoldLanding(flight)
	elseif not (flight.edl and flight.edl.autoLand) then
		flight:SetThrottle(0)
	end
	flight:SetInput(Vector3.zero)

	local cfg = PlanetZoneManager.CONFIG[info.planet]
	local s = { flight = flight, conns = {} }
	sessions[player] = s
	-- спершу атрибути EVA (клієнт відпускає камеру ракети), потім висадка
	player:SetAttribute("EVAGravity", cfg.gravity)
	player:SetAttribute("EVAPlanet", info.planet)
	player:SetAttribute("EVA", true)
	player:SetAttribute("CanEVA", false)
	EVA.ServerOwn(flight)
	CapsuleSeatSystem.Release(player)

	local spot, dir = groundSpot(flight, info.up)
	local standPos = spot + info.up * 3.5
	local standCF = CFrame.lookAt(standPos, standPos + dir, info.up)
	character:PivotTo(standCF)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		-- персонаж знову окремий — його рух симулює клієнт гравця (без затримки керування)
		pcall(root.SetNetworkOwner, root, player)
		-- клієнт може отримати телепорт раніше, ніж зняття SeatWeld, і проігнорувати його —
		-- тоді персонаж «вистрибує» на дах капсули. Перевіряємо і повторюємо кілька разів.
		task.spawn(function()
			for _ = 1, 10 do
				task.wait(0.15)
				if sessions[player] ~= s or not root.Parent then
					return
				end
				-- до 1.5 с стежимо (астронавт уже може йти — повертаємо лише якщо він над точкою виходу)
				local d = root.Position - standPos
				if d:Dot(info.up) > 3 or d.Magnitude > 12 then
					character:PivotTo(standCF)
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end
		end)
	end
	EVA.ServerOwn(flight)

	-- люк для повернення: точка на ґрунті біля опор, прив'язана до ракети (їде разом із нею)
	local hatch = Instance.new("Attachment")
	hatch.Name = "EVAHatch"
	hatch.Parent = flight.core
	hatch.WorldPosition = spot + info.up * 2.5
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardCapsule"
	prompt.ActionText = "BOARD CAPSULE"
	prompt.ObjectText = "Capsule · " .. player.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = EVA.BOARD_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Parent = hatch
	s.hatch = hatch
	s.prompt = prompt
	table.insert(s.conns, prompt.Triggered:Connect(function(who)
		if who == player then
			EVA.Board(player)
		else
			say(who, "This capsule belongs to another astronaut.", true)
		end
	end))

	-- загибель астронавта на поверхні перериває місію
	table.insert(s.conns, humanoid.Died:Connect(function()
		if sessions[player] == s then
			say(player, "☠ The astronaut died during the EVA. Mission aborted.", true)
			clearSession(player)
			if not flight.ended then
				flight:Stop("manual")
			end
		end
	end))

	say(player, string.format("🧑‍🚀 EVA ON %s! g = %.2f m/s². Space — jump, hold in the air — jetpack. Back — [F] at the hatch.",
		cfg.nameOn, cfg.gravity), false)
	if info.hovering then
		task.delay(2.5, say, player, "The empty capsule is landing softly on its own.", false)
	end
	return true
end

--------------------------------------------------------------------
-- Щопівсекунди з FlightServer: підказка [E] у HUD
--------------------------------------------------------------------
function EVA.Update(player, flight)
	local can = false
	if player:GetAttribute("InCapsule") and not sessions[player] then
		can = EVA.CanExit(player, flight)
	end
	if player:GetAttribute("CanEVA") ~= can then
		player:SetAttribute("CanEVA", can)
	end
end

-- Політ завершено / гравець вийшов — прибираємо все
function EVA.End(player)
	clearSession(player)
	if player.Parent then
		player:SetAttribute("CanEVA", nil)
	end
end

-- Кисень скінчився — астронавт тратить здоров'я (раз на секунду)
local timer = 0
RunService.Heartbeat:Connect(function(dt)
	timer += dt
	if timer < 1 then
		return
	end
	timer = 0
	for player in pairs(sessions) do
		local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 and (player:GetAttribute("SuitO2") or 100) <= 0 then
			h:TakeDamage(O2_DAMAGE)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	clearSession(player)
end)

return EVA
