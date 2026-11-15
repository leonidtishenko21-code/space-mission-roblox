--[[
	AstronautClient (LocalScript) — КРОКИ 1–3, клієнт
	Місце: StarterPlayer > StarterPlayerScripts > AstronautClient

	  [V]  — вигляд «Ззовні / З кабіни», поки астронавт у кріслі капсули (атрибут InCapsule)
	         у кабіні: ПКМ + миша — оглянутись
	  [L]  — налобний ліхтарик скафандра
	  [K]  — зняти скафандр (сервер дозволяє лише на Землі)
	  Space в повітрі у скафандрі — мікродвигуни ранця (під час EVA — справжня тяга, витрачає заряд)
	  [E]  — КРОК 3: вийти з капсули (коли сервер виставив CanEVA; інакше E — крен ракети)
	  EVA (атрибут EVA): низька гравітація Місяця / Марса (VectorForce на HumanoidRootPart),
	       високі повільні стрибки, повернення — ProximityPrompt «СІСТИ В КАПСУЛУ [F]»
	Поки CapsuleLocked = true, стан Jumping вимкнено — вистрибнути з крісла під час розгону не вийде.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local suitEvent = remotes:WaitForChild("SpacesuitAction")
local evaEvent = remotes:WaitForChild("EVAAction")

local PRIORITY = Enum.ContextActionPriority.High.Value + 200
local EYE_HEIGHT = 2.6     -- studs від крісла до очей сидячого астронавта
local LOOK_SENS = 0.004    -- рад на піксель
local HIDE_GROUPS = { "Payload", "FairingLeft", "FairingRight" } -- з кабіни не затуляють огляд

--------------------------------------------------------------------
-- UI: підказка вигляду + стан скафандра
--------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "AstronautHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui:SetAttribute("KeepInFlight", true) -- FlightClient не ховає цей HUD під час польоту
gui.Parent = player:WaitForChild("PlayerGui")

local function label(y)
	local t = Instance.new("TextLabel")
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Position = UDim2.new(0.5, 0, 0, y)
	t.Size = UDim2.fromOffset(460, 26)
	t.BackgroundColor3 = Color3.fromRGB(10, 14, 24)
	t.BackgroundTransparency = 0.35
	t.TextColor3 = Color3.fromRGB(230, 235, 245)
	t.Font = Enum.Font.GothamMedium
	t.TextSize = 14
	t.Visible = false
	t.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = t
	return t
end
local viewLabel = label(64)
local suitLabel = label(94)
local evaLabel = label(124)
evaLabel.Size = UDim2.fromOffset(560, 26)
-- КРОК 4: статус місії «Збір екземпляра планети»
local missionLabel = label(158)
missionLabel.Size = UDim2.fromOffset(640, 34)
missionLabel.Font = Enum.Font.GothamBlack
missionLabel.TextSize = 16
local missionStroke = Instance.new("UIStroke")
missionStroke.Thickness = 2
missionStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
missionStroke.Parent = missionLabel

-- рамка ілюмінатора у вигляді з кабіни
local porthole = Instance.new("Frame")
porthole.Size = UDim2.fromScale(1, 1)
porthole.BackgroundTransparency = 1
porthole.Visible = false
porthole.Parent = gui
local stroke = Instance.new("UIStroke")
stroke.Thickness = 70
stroke.Color = Color3.fromRGB(25, 27, 32)
stroke.Transparency = 0.15
stroke.Parent = porthole
local round = Instance.new("UICorner")
round.CornerRadius = UDim.new(0.18, 0)
round.Parent = porthole

--------------------------------------------------------------------
-- Допоміжне
--------------------------------------------------------------------
local function findRocket()
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

local function humanoidOf()
	return player.Character and player.Character:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------------------
-- Камера «Ззовні / З кабіни»
--------------------------------------------------------------------
local cockpit = false
local look = Vector2.zero -- yaw, pitch
local hidden = {}         -- частини, які ховаємо локально (LocalTransparencyModifier)
local hiddenRefresh = 0
local mouseLocked = false

local function collectHidden()
	hidden = {}
	local rocket = findRocket()
	if player.Character then
		for _, d in ipairs(player.Character:GetDescendants()) do
			if d:IsA("BasePart") or d:IsA("Decal") then
				table.insert(hidden, d)
			end
		end
	end
	if rocket then
		for _, name in ipairs(HIDE_GROUPS) do
			local g = rocket:FindFirstChild(name)
			if g then
				for _, d in ipairs(g:GetDescendants()) do
					if d:IsA("BasePart") then
						table.insert(hidden, d)
					end
				end
			end
		end
	end
end

local function setMouseLock(on)
	if on ~= mouseLocked then
		mouseLocked = on
		UserInputService.MouseBehavior = on and Enum.MouseBehavior.LockCurrentPosition or Enum.MouseBehavior.Default
	end
end

local function updateViewLabel()
	local inCapsule = player:GetAttribute("InCapsule") == true
	viewLabel.Visible = inCapsule
	porthole.Visible = inCapsule and cockpit
	if cockpit then
		viewLabel.Text = "🎥 View: COCKPIT  ·  [V] — outside  ·  RMB — look around"
	else
		viewLabel.Text = "🎥 View: OUTSIDE  ·  [V] — cockpit"
	end
end

local function setCockpit(on)
	if on == cockpit then
		return
	end
	cockpit = on
	if on then
		look = Vector2.zero
		collectHidden()
		camera.CameraType = Enum.CameraType.Scriptable
	else
		for _, p in ipairs(hidden) do
			if p.Parent then
				p.LocalTransparencyModifier = 0
			end
		end
		hidden = {}
		setMouseLock(false)
		camera.CameraType = Enum.CameraType.Custom
		-- у польоті FlightClient сам наводить камеру на ракету; на стартовому столі — ми
		local rocket = findRocket()
		if player:GetAttribute("InCapsule") and rocket and rocket.PrimaryPart then
			camera.CameraSubject = rocket.PrimaryPart
		else
			local h = humanoidOf()
			if h then
				camera.CameraSubject = h
			end
		end
	end
	updateViewLabel()
end

local function onViewKey(_, state)
	if state == Enum.UserInputState.Begin then
		setCockpit(not cockpit)
	end
	return Enum.ContextActionResult.Sink
end

-- Камера кабіни: на висоті очей над кріслом, дивиться вздовж носа ракети.
-- Пріоритет Camera: тремтіння FlightClient (Camera + 1) додається поверх.
RunService:BindToRenderStep("CapsuleCockpitCamera", Enum.RenderPriority.Camera.Value, function(dt)
	if not cockpit then
		return
	end
	local rocket = findRocket()
	local seat = rocket and rocket:FindFirstChild("PilotSeat", true)
	local core = rocket and rocket.PrimaryPart
	if not (seat and core) then
		setCockpit(false)
		return
	end

	-- оглядання мишею з затиснутою ПКМ
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		setMouseLock(true)
		local d = UserInputService:GetMouseDelta()
		look = Vector2.new(math.clamp(look.X - d.X * LOOK_SENS, -1.7, 1.7), math.clamp(look.Y - d.Y * LOOK_SENS, -1.2, 1.2))
	else
		setMouseLock(false)
	end

	local fc = core:FindFirstChild("FlightCore")
	local axis = fc and fc.WorldCFrame or core.CFrame
	local nose = axis.UpVector
	local eye = seat.Position + nose * EYE_HEIGHT
	camera.CFrame = CFrame.lookAt(eye, eye + nose, axis.LookVector)
		* CFrame.Angles(0, look.X, 0) * CFrame.Angles(look.Y, 0, 0)
	camera.Focus = CFrame.new(eye)

	-- свій персонаж і корпус капсули не затуляють огляд (інші гравці бачать усе як є)
	hiddenRefresh += dt
	if hiddenRefresh > 1 then
		hiddenRefresh = 0
		collectHidden()
	end
	for _, p in ipairs(hidden) do
		p.LocalTransparencyModifier = 1
	end
end)

--------------------------------------------------------------------
-- Крісло: блок стрибка і клавіша V
--------------------------------------------------------------------
local function applyJumpLock()
	local h = humanoidOf()
	if h then
		h:SetStateEnabled(Enum.HumanoidStateType.Jumping, player:GetAttribute("CapsuleLocked") ~= true)
	end
end

local function onCapsuleChanged()
	if player:GetAttribute("InCapsule") then
		ContextActionService:BindActionAtPriority("CapsuleView", onViewKey, false, PRIORITY, Enum.KeyCode.V)
		-- на стартовому столі камера дивиться на ракету, а не в спину персонажу
		local rocket = findRocket()
		if not cockpit and rocket and rocket.PrimaryPart then
			camera.CameraSubject = rocket.PrimaryPart
		end
	else
		ContextActionService:UnbindAction("CapsuleView")
		setCockpit(false)
		local h = humanoidOf()
		if h then
			camera.CameraSubject = h
		end
	end
	applyJumpLock()
	updateViewLabel()
end

player:GetAttributeChangedSignal("InCapsule"):Connect(onCapsuleChanged)
player:GetAttributeChangedSignal("CapsuleLocked"):Connect(applyJumpLock)
player.CharacterAdded:Connect(function(character)
	character:WaitForChild("Humanoid")
	setCockpit(false)
	applyJumpLock()
end)
onCapsuleChanged()

--------------------------------------------------------------------
-- Скафандр: ліхтарик [L], зняти [K], мікродвигуни (Space у повітрі)
--------------------------------------------------------------------
local function onSuitKey(_, state, input)
	if state == Enum.UserInputState.Begin then
		if input.KeyCode == Enum.KeyCode.L then
			suitEvent:FireServer("light")
		elseif input.KeyCode == Enum.KeyCode.K then
			suitEvent:FireServer("remove")
		end
	end
	return Enum.ContextActionResult.Sink
end

local function refreshSuit()
	local equipped = player:GetAttribute("SuitEquipped") == true
	if equipped then
		ContextActionService:BindActionAtPriority("SuitKeys", onSuitKey, false, PRIORITY, Enum.KeyCode.L, Enum.KeyCode.K)
	else
		ContextActionService:UnbindAction("SuitKeys")
	end
	suitLabel.Visible = equipped
	if equipped then
		local o2 = player:GetAttribute("SuitO2") or 100
		local power = player:GetAttribute("SuitPower") or 100
		suitLabel.Text = string.format("🧑‍🚀 NASA SPACESUIT  ·  O₂ %d%%  ·  ⚡ %d%%  ·  headlamp [L] %s",
			math.floor(o2 + 0.5), math.floor(power + 0.5), player:GetAttribute("SuitLight") and "ON" or "off")
		suitLabel.TextColor3 = (o2 < 25 or power < 15) and Color3.fromRGB(255, 110, 100) or Color3.fromRGB(230, 235, 245)
	end
end
for _, name in ipairs({ "SuitEquipped", "SuitO2", "SuitPower", "SuitLight" }) do
	player:GetAttributeChangedSignal(name):Connect(refreshSuit)
end
refreshSuit()

local jetsOn = false
local function setJets(on)
	if on ~= jetsOn then
		jetsOn = on
		suitEvent:FireServer("jets", on)
	end
end

--------------------------------------------------------------------
-- КРОК 3: вихід [E] і фізика EVA
--------------------------------------------------------------------
local JUMP_HEIGHT = 9        -- studs: стрибок у низькій гравітації (повільний і довгий)
local JET_ACCEL = 1.8        -- тяга ранця у «вагах» місцевої гравітації: > 1 — піднімає
local JET_MAX_UP = 18        -- studs/с: стеля швидкості підйому на ранці
local JET_PUSH = 22          -- studs/с²: поштовх уперед (куди йде персонаж)
local JET_MAX_SIDE = 28
local PLANET_NAMES = { Moon = "MOON", Mars = "MARS" }

local function onExitKey(_, state)
	if state == Enum.UserInputState.Begin then
		evaEvent:FireServer("exit")
	end
	return Enum.ContextActionResult.Sink
end

local function refreshEVAHud()
	local canExit = player:GetAttribute("InCapsule") == true and player:GetAttribute("CanEVA") == true
	if canExit then
		-- вищий пріоритет за FlightClient: E виводить з капсули замість крену
		ContextActionService:BindActionAtPriority("EVAExit", onExitKey, false, PRIORITY, Enum.KeyCode.E)
	else
		ContextActionService:UnbindAction("EVAExit")
	end
	local eva = player:GetAttribute("EVA") == true
	evaLabel.Visible = canExit or eva
	if eva then
		evaLabel.Text = string.format("🌑 EVA · %s · g = %.2f m/s²  ·  Space — jump / jetpack  ·  [F] at the hatch — board",
			PLANET_NAMES[player:GetAttribute("EVAPlanet")] or "SURFACE", player:GetAttribute("EVAGravity") or 0)
		evaLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	elseif canExit then
		evaLabel.Text = "🚪 [E] — EXIT THE CAPSULE ONTO THE SURFACE"
		evaLabel.TextColor3 = Color3.fromRGB(140, 255, 160)
	end
end
for _, name in ipairs({ "InCapsule", "CanEVA", "EVA", "EVAPlanet", "EVAGravity" }) do
	player:GetAttributeChangedSignal(name):Connect(refreshEVAHud)
end
refreshEVAHud()

-- Статус місії збору зразка (атрибути SamplePlanet / SampleStowed виставляє SampleCollectionMission)
local STATUS_COLLECTED = "SAMPLE COLLECTED — RETURN TO THE CAPSULE AND REFUEL THE ROCKET"
local function rocketFuelFull()
	local rocket = findRocket()
	return rocket ~= nil and (rocket:GetAttribute("StageFuelPct") or 0) >= 99
end
local function refreshMission()
	local planet = player:GetAttribute("SamplePlanet")
	local stowed = player:GetAttribute("SampleStowed") == true
	local eva = player:GetAttribute("EVA") == true
	if planet and stowed and rocketFuelFull() then
		missionLabel.Text = "🚀 SAMPLE ON BOARD, TANKS FULL — LAUNCH FOR EARTH AND LAND WITH [P]"
		missionLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
		missionStroke.Color = Color3.fromRGB(80, 200, 120)
	elseif planet and not stowed then
		missionLabel.Text = "🧪 " .. STATUS_COLLECTED
		missionLabel.TextColor3 = Color3.fromRGB(255, 225, 110)
		missionStroke.Color = Color3.fromRGB(255, 190, 60)
	elseif planet and stowed then
		missionLabel.Text = "📦 SAMPLE IN THE CARGO BAY — REFUEL THE ROCKET AND RETURN TO EARTH"
		missionLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
		missionStroke.Color = Color3.fromRGB(80, 200, 120)
	elseif eva then
		missionLabel.Text = "🎯 MISSION: find a glowing sample in the crater and hold [E] — Collect planet sample"
		missionLabel.TextColor3 = Color3.fromRGB(200, 225, 255)
		missionStroke.Color = Color3.fromRGB(90, 140, 220)
	end
	missionLabel.Visible = planet ~= nil or eva
end
for _, name in ipairs({ "SamplePlanet", "SampleStowed", "EVA" }) do
	player:GetAttributeChangedSignal(name):Connect(refreshMission)
end
refreshMission()

--------------------------------------------------------------------
-- КРОК 5: кнопка «⛽ ISRU» і шкала синтезу палива (атрибути CanISRU / ISRUProgress)
--------------------------------------------------------------------
local isruButton = Instance.new("TextButton")
isruButton.Name = "ISRUButton"
isruButton.AnchorPoint = Vector2.new(0.5, 0)
isruButton.Position = UDim2.new(0.5, 0, 0, 200)
isruButton.Size = UDim2.fromOffset(330, 40)
isruButton.BackgroundColor3 = Color3.fromRGB(210, 120, 30)
isruButton.TextColor3 = Color3.new(1, 1, 1)
isruButton.Font = Enum.Font.GothamBlack
isruButton.TextSize = 16
isruButton.Text = "⛽ REFUEL ROCKET · ISRU"
isruButton.Visible = false
isruButton.Parent = gui
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = isruButton
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 200, 110)
	s.Thickness = 2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = isruButton
end
isruButton.Activated:Connect(function()
	evaEvent:FireServer("isru")
end)

local isruBar = Instance.new("Frame")
isruBar.Name = "ISRUProgress"
isruBar.AnchorPoint = Vector2.new(0.5, 0)
isruBar.Position = UDim2.new(0.5, 0, 0, 200)
isruBar.Size = UDim2.fromOffset(460, 34)
isruBar.BackgroundColor3 = Color3.fromRGB(10, 14, 24)
isruBar.BackgroundTransparency = 0.2
isruBar.Visible = false
isruBar.Parent = gui
local isruFill = Instance.new("Frame")
isruFill.Size = UDim2.fromScale(0, 1)
isruFill.BackgroundColor3 = Color3.fromRGB(255, 160, 50)
isruFill.BorderSizePixel = 0
isruFill.Parent = isruBar
local isruText = Instance.new("TextLabel")
isruText.Size = UDim2.fromScale(1, 1)
isruText.BackgroundTransparency = 1
isruText.TextColor3 = Color3.new(1, 1, 1)
isruText.TextStrokeTransparency = 0.4
isruText.Font = Enum.Font.GothamBlack
isruText.TextSize = 15
isruText.ZIndex = 2
isruText.Parent = isruBar
for _, inst in ipairs({ isruBar, isruFill }) do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = inst
end

local function refreshISRU()
	local k = player:GetAttribute("ISRUProgress")
	isruBar.Visible = k ~= nil
	isruButton.Visible = k == nil and player:GetAttribute("CanISRU") == true
	if k then
		isruFill.Size = UDim2.fromScale(math.clamp(k, 0, 1), 1)
		isruText.Text = string.format("⛽ ISRU FUEL SYNTHESIS → TANK: %d%%", math.floor(k * 100))
	end
	refreshMission()
end
for _, name in ipairs({ "CanISRU", "ISRUProgress" }) do
	player:GetAttributeChangedSignal(name):Connect(refreshISRU)
end
refreshISRU()

-- статус «баки повні» залежить від телеметрії ракети — оновлюємо раз на секунду
task.spawn(function()
	while true do
		task.wait(1)
		if player:GetAttribute("SamplePlanet") then
			refreshMission()
		end
	end
end)

-- Низька гравітація: workspace.Gravity — земна; VectorForce знімає зайве так, щоб
-- ефективне g = workspace.Gravity · (gпланети / 9.81): Місяць ≈ ⅙, Марс ≈ ⅓ земної
local evaForce, evaAttachment, savedJump = nil, nil, nil
local function clearEVAPhysics()
	if evaForce then
		evaForce:Destroy()
		evaForce = nil
	end
	if evaAttachment then
		evaAttachment:Destroy()
		evaAttachment = nil
	end
	local h = humanoidOf()
	if savedJump and h then
		h.UseJumpPower, h.JumpPower = savedJump[1], savedJump[2]
	end
	savedJump = nil
end
player.CharacterAdded:Connect(function()
	evaForce, evaAttachment, savedJump = nil, nil, nil
end)

RunService.Heartbeat:Connect(function()
	local h = humanoidOf()
	local eva = player:GetAttribute("EVA") == true
	local holdingSpace = UserInputService:IsKeyDown(Enum.KeyCode.Space) and not UserInputService:GetFocusedTextBox()
	local airborne = h ~= nil and h.FloorMaterial == Enum.Material.Air
	local want = player:GetAttribute("SuitEquipped") == true
		and not player:GetAttribute("InCapsule")
		and airborne and holdingSpace
	setJets(want)

	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not (eva and h and root and h.Health > 0) then
		if evaForce then
			clearEVAPhysics()
		end
		return
	end
	if not evaForce or evaForce.Parent ~= root then
		clearEVAPhysics()
		evaAttachment = Instance.new("Attachment")
		evaAttachment.Name = "EVAGravityAttachment"
		evaAttachment.Parent = root
		evaForce = Instance.new("VectorForce")
		evaForce.Name = "EVAGravity"
		evaForce.Attachment0 = evaAttachment
		evaForce.RelativeTo = Enum.ActuatorRelativeTo.World
		evaForce.ApplyAtCenterOfMass = true
		evaForce.Parent = root
		savedJump = { h.UseJumpPower, h.JumpPower }
	end
	local ratio = math.clamp((player:GetAttribute("EVAGravity") or 9.81) / 9.81, 0.05, 1)
	local gEff = workspace.Gravity * ratio
	h.UseJumpPower = true
	h.JumpPower = math.sqrt(2 * gEff * JUMP_HEIGHT) -- v = √(2·g·h)

	local mass = root.AssemblyMass
	local accel = Vector3.new(0, workspace.Gravity - gEff, 0) -- компенсація зайвої земної гравітації
	-- ранець: тяга вгору та в бік руху, поки є заряд
	if want and (player:GetAttribute("SuitPower") or 0) > 0 then
		local v = root.AssemblyLinearVelocity
		if v.Y < JET_MAX_UP then
			accel += Vector3.new(0, gEff * JET_ACCEL, 0)
		end
		local move = h.MoveDirection
		local side = Vector3.new(v.X, 0, v.Z)
		if move.Magnitude > 0.1 and side:Dot(move.Unit) < JET_MAX_SIDE then
			accel += move.Unit * JET_PUSH
		end
	end
	evaForce.Force = accel * mass
end)
