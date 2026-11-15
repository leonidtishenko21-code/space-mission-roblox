--[[
	FlightClient (LocalScript) — FlightHUD
	Місце: StarterPlayer > StarterPlayerScripts > FlightClient

	1. Панель запуску (справа внизу):
	     в ангарі   — «НА СТАРТОВИЙ МАЙДАНЧИК» (коли ракета зібрана й заправлена)
	     на старті   — «ЗАПУСК [ENTER]» (відлік 3-2-1) або «Повернути в ангар»
	2. Польотний пульт (під час польоту решта UI ховається):
	     висота (км), вертикальна та орбітальна (горизонтальна) швидкість (м/с),
	     пальне активного ступеня (%), TWR, шкала висоти з ціллю місії,
	     кнопки «ВІДСТРІЛ СТУПЕНЯ [SPACE]», «СКИНУТИ ОБТІЧНИК [F]», «ЗАВЕРШИТИ».
	3. Керування: W/S/A/D — нахил ракети відносно камери (надсилається на сервер).

	Дані: висота й швидкість рахуються тут з позиції ракети (плавно, щокадру),
	пальне/TWR/маса — з атрибутів моделі, які оновлює FlightPhysics на сервері.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local HttpService = game:GetService("HttpService")
local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))
local RocketMath = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("RocketMath"))
local PlanetZoneManager = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("PlanetZoneManager"))
local F = NASAData.Flight
local M_PER_STUD = F.METERS_PER_STUD

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local launchEvent = remotes:WaitForChild("LaunchRocket")
local inputEvent = remotes:WaitForChild("FlightInput")
local stageEvent = remotes:WaitForChild("TriggerStage")
local fairingEvent = remotes:WaitForChild("JettisonFairing")
local notifyEvent = remotes:WaitForChild("Notify")
local scienceEvent = remotes:WaitForChild("ScienceAction")
local attitudeEvent = remotes:WaitForChild("AttitudeMode")
local edlEvent = remotes:WaitForChild("EDLAction")
local EDLC = NASAData.EDL
local reportEvent = remotes:WaitForChild("FlightReport")

--------------------------------------------------------------------
-- 🎨 Стиль
--------------------------------------------------------------------
local COLOR_BG = Color3.fromRGB(14, 18, 28)
local COLOR_PANEL = Color3.fromRGB(24, 30, 44)
local COLOR_TEXT = Color3.fromRGB(235, 238, 245)
local COLOR_DIM = Color3.fromRGB(150, 160, 180)
local COLOR_ACCENT = Color3.fromRGB(240, 190, 40)
local COLOR_OK = Color3.fromRGB(90, 200, 120)
local COLOR_WARN = Color3.fromRGB(240, 160, 50)
local COLOR_ERROR = Color3.fromRGB(230, 80, 70)
local COLOR_BUTTON = Color3.fromRGB(45, 55, 78)
local FONT_BOLD = Enum.Font.GothamBold
local FONT = Enum.Font.Gotham

local function create(className, props)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function style(frame, radius, strokeColor)
	create("UICorner", { CornerRadius = UDim.new(0, radius or 8), Parent = frame })
	if strokeColor then
		create("UIStroke", { Color = strokeColor, Thickness = 1.5, Transparency = 0.3, Parent = frame })
	end
end

local function makeButton(text, parent, size, color)
	local b = create("TextButton", {
		Size = size,
		BackgroundColor3 = color or COLOR_BUTTON,
		Text = text,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 16,
		TextWrapped = true,
		AutoButtonColor = true,
		Parent = parent,
	})
	style(b, 8)
	return b
end

local fmt = function(n)
	local negative = n < 0
	local s = tostring(math.floor(math.abs(n) + 0.5))
	s = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", "")
	return (negative and "−" or "") .. s
end

--------------------------------------------------------------------
-- Інтерфейс
--------------------------------------------------------------------
local gui = create("ScreenGui", {
	Name = "FlightHUD",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 20,
	Parent = playerGui,
})

-- 1) Панель запуску ------------------------------------------
local launchPanel = create("Frame", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.fromOffset(300, 150),
	BackgroundColor3 = COLOR_BG,
	BackgroundTransparency = 0.15,
	Visible = false,
	Parent = gui,
})
style(launchPanel, 10, COLOR_ACCENT)
local launchTitle = create("TextLabel", {
	Position = UDim2.fromOffset(12, 8),
	Size = UDim2.new(1, -24, 0, 40),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = COLOR_TEXT,
	Font = FONT_BOLD,
	TextSize = 15,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = launchPanel,
})
local primaryButton = makeButton("", launchPanel, UDim2.new(1, -24, 0, 46), Color3.fromRGB(200, 70, 40))
primaryButton.Position = UDim2.fromOffset(12, 50)
local secondaryButton = makeButton("", launchPanel, UDim2.new(1, -24, 0, 34))
secondaryButton.Position = UDim2.fromOffset(12, 104)
secondaryButton.TextSize = 14

-- 2) Польотний пульт ----------------------------------------
local flightFrame = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = gui,
})

-- Телеметрія (зліва зверху)
local telemetry = create("Frame", {
	Position = UDim2.fromOffset(16, 56),
	Size = UDim2.fromOffset(280, 382),
	BackgroundColor3 = COLOR_BG,
	BackgroundTransparency = 0.2,
	Parent = flightFrame,
})
style(telemetry, 10, Color3.fromRGB(80, 100, 140))
create("UIPadding", {
	PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
	Parent = telemetry,
})
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = telemetry })

local rowOrder = 0
local function row(labelText, big)
	rowOrder += 1
	local r = create("Frame", { Size = UDim2.new(1, 0, 0, big and 34 or 22), BackgroundTransparency = 1, LayoutOrder = rowOrder, Parent = telemetry })
	create("TextLabel", {
		Size = UDim2.new(0.55, 0, 1, 0), BackgroundTransparency = 1, Text = labelText,
		TextColor3 = COLOR_DIM, Font = FONT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Parent = r,
	})
	return create("TextLabel", {
		Position = UDim2.fromScale(0.4, 0), Size = UDim2.new(0.6, 0, 1, 0), BackgroundTransparency = 1, Text = "-",
		TextColor3 = COLOR_TEXT, Font = FONT_BOLD, TextSize = big and 26 or 16,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = r,
	})
end

local zoneLabel = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Text = "TROPOSPHERE",
	TextColor3 = COLOR_ACCENT, Font = FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 0, Parent = telemetry,
})
local altValue = row("Altitude", true)
local vsValue = row("Vertical speed")
local hsValue = row("Orbital speed")
local twrValue = row("TWR")
local massValue = row("Mass")
local stageValue = row("Stage")
local throttleValue = row("Throttle")
local attitudeValue = row("Attitude")
local powerValue = row("Power")
local zoneValue = row("🎯 Target")

rowOrder += 1
local fuelRow = create("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = rowOrder, Parent = telemetry })
local fuelText = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Text = "Stage fuel: -",
	TextColor3 = COLOR_DIM, Font = FONT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Parent = fuelRow,
})
local fuelBarBg = create("Frame", {
	Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 14), BackgroundColor3 = COLOR_PANEL, Parent = fuelRow,
})
style(fuelBarBg, 6)
local fuelBar = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLOR_OK, Parent = fuelBarBg })
style(fuelBar, 6)

-- Шкала висоти з ціллю місії (справа)
local LADDER_MAX_KM = F.TARGET_ALTITUDE_KM * 1.3
local ladder = create("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -24, 0.45, 0),
	Size = UDim2.fromOffset(150, 340),
	BackgroundColor3 = COLOR_BG,
	BackgroundTransparency = 0.25,
	Parent = flightFrame,
})
style(ladder, 10, Color3.fromRGB(80, 100, 140))
local track = create("Frame", {
	Position = UDim2.new(0, 18, 0, 14), Size = UDim2.new(0, 10, 1, -28),
	BackgroundColor3 = Color3.fromRGB(60, 120, 200), BorderSizePixel = 0, Parent = ladder,
})
create("UIGradient", {
	Rotation = 90,
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(5, 5, 15)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(20, 40, 110)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 170, 240)),
	}),
	Parent = track,
})
local function ladderY(km)
	return 1 - math.clamp(km / LADDER_MAX_KM, 0, 1)
end
local function ladderMark(km, text, color)
	create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -4, ladderY(km), 0), Size = UDim2.fromOffset(18, 2),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = track,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 20, ladderY(km), 0), Size = UDim2.fromOffset(110, 16),
		BackgroundTransparency = 1, Text = text, TextColor3 = color, Font = FONT, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = track,
	})
end
ladderMark(15, "15 km · stratosphere", COLOR_DIM)
ladderMark(50, "50 km · mesosphere", COLOR_DIM)
ladderMark(F.FAIRING_MIN_ALTITUDE_KM, F.FAIRING_MIN_ALTITUDE_KM .. " km · fairing", Color3.fromRGB(120, 180, 230))
ladderMark(F.TARGET_ALTITUDE_KM, "🎯 " .. F.TARGET_ALTITUDE_KM .. " km · space", COLOR_ACCENT)
local marker = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(22, 8),
	BackgroundColor3 = COLOR_TEXT, BorderSizePixel = 0, ZIndex = 3, Parent = track,
})
style(marker, 4)
local apogeeMark = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(16, 2),
	BackgroundColor3 = COLOR_WARN, BorderSizePixel = 0, ZIndex = 2, Parent = track,
})
local ladderOver = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -2), Size = UDim2.new(1, 0, 0, 14),
	BackgroundTransparency = 1, Text = "", TextColor3 = COLOR_ACCENT, Font = FONT_BOLD, TextSize = 12, Parent = ladder,
})

-- Кнопки (внизу по центру)
local buttonBar = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -20), Size = UDim2.fromOffset(780, 70),
	BackgroundTransparency = 1, Parent = flightFrame,
})
local stageButton = makeButton("STAGE SEPARATION [SPACE]", buttonBar, UDim2.fromOffset(300, 70))
stageButton.TextSize = 18
local stageStroke = create("UIStroke", { Color = COLOR_ACCENT, Thickness = 3, Transparency = 1, Parent = stageButton })
local fairingButton = makeButton("JETTISON FAIRING [F]", buttonBar, UDim2.fromOffset(220, 70))
fairingButton.Position = UDim2.fromOffset(320, 0)
local chuteButton = makeButton("PARACHUTE [P]", buttonBar, UDim2.fromOffset(220, 70))
chuteButton.Position = UDim2.fromOffset(560, 0)
local chuteStroke = create("UIStroke", { Color = Color3.fromRGB(255, 170, 40), Thickness = 3, Transparency = 1, Parent = chuteButton })

-- Банер сповіщень EDL (по центру): жовтий — час розкривати парашут, червоний — критично, зелений — гальмування
local edlBanner = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -168), Size = UDim2.fromOffset(600, 64),
	BackgroundColor3 = Color3.fromRGB(40, 30, 10), BackgroundTransparency = 0.1, Visible = false, Parent = flightFrame,
})
style(edlBanner, 10)
local edlStroke = create("UIStroke", { Color = COLOR_WARN, Thickness = 3, Parent = edlBanner })
local edlTitle = create("TextLabel", {
	Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 30), BackgroundTransparency = 1, Text = "",
	TextColor3 = COLOR_WARN, Font = FONT_BOLD, TextSize = 22, TextScaled = false, Parent = edlBanner,
})
local edlSub = create("TextLabel", {
	Position = UDim2.fromOffset(10, 36), Size = UDim2.new(1, -20, 0, 20), BackgroundTransparency = 1, Text = "",
	TextColor3 = COLOR_TEXT, Font = FONT, TextSize = 14, Parent = edlBanner,
})

-- Звуки: короткий сигнал телеметрії і свист повітря (вбудовані звуки Roblox)
local beepSound = create("Sound", { Name = "TelemetryBeep", SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Parent = gui })
local windSound = create("Sound", { Name = "Wind", SoundId = "rbxasset://sounds/action_falling.mp3", Volume = 0, Looped = true, Parent = gui })

-- Режими орієнтації (над кнопками ступенів)
local attitudeBar = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -98), Size = UDim2.fromOffset(620, 34),
	BackgroundTransparency = 1, Parent = flightFrame,
})
create("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10),
	HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = attitudeBar,
})
local ATTITUDE_BUTTONS = {
	{ mode = "sas", text = "SAS [T]", width = 150 },
	{ mode = "retrograde", text = "RETROGRADE [R]", width = 190 },
	{ mode = "radial", text = "NOZZLE TO PLANET [G]", width = 250 },
}
for _, b in ipairs(ATTITUDE_BUTTONS) do
	b.button = makeButton(b.text, attitudeBar, UDim2.fromOffset(b.width, 34))
	b.button.TextSize = 13
end -- обробники натискань — нижче, після setAttitude

local endButton = makeButton("END FLIGHT", flightFrame, UDim2.fromOffset(170, 34), Color3.fromRGB(110, 40, 40))
endButton.AnchorPoint = Vector2.new(1, 0)
endButton.Position = UDim2.new(1, -16, 0, 56)
endButton.TextSize = 13

create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -140), Size = UDim2.fromOffset(980, 20),
	BackgroundTransparency = 1, Text = "W/S/A/D — pitch/yaw · Q/E — roll · Shift/Ctrl — throttle · Z/X — 100%/0 · T — SAS · R — retrograde · G — nozzle to planet",
	TextColor3 = COLOR_DIM, Font = FONT, TextSize = 13, TextStrokeTransparency = 0.6, Parent = flightFrame,
})

-- Наукові прилади (зліва внизу, під телеметрією): кнопки лише для встановлених на ракеті приладів
local sciencePanel = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -20),
	Size = UDim2.fromOffset(230, 200),
	BackgroundColor3 = COLOR_BG,
	BackgroundTransparency = 0.2,
	Visible = false,
	Parent = flightFrame,
})
style(sciencePanel, 10, Color3.fromRGB(80, 160, 200))
create("UIPadding", {
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = sciencePanel,
})
create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = sciencePanel })
create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Text = "SCIENCE INSTRUMENTS", LayoutOrder = 0,
	TextColor3 = Color3.fromRGB(120, 200, 240), Font = FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
	Parent = sciencePanel,
})
local SCIENCE = {
	{ kind = "theodolite", module = "theodolite", label = "📐 Laser theodolite" },
	{ kind = "scan", module = "terrain_scanner", label = "🛰 Terrain scanner" },
	{ kind = "drill", module = "ice_drill", label = "🧊 Ice drill" },
}
for i, s in ipairs(SCIENCE) do
	s.button = makeButton(s.label, sciencePanel, UDim2.new(1, 0, 0, 36))
	s.button.TextSize = 14
	s.button.LayoutOrder = i
	s.button.Activated:Connect(function()
		scienceEvent:FireServer(s.kind)
	end)
end
local scienceStatus = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Text = "", LayoutOrder = 10, TextWrapped = true,
	TextColor3 = COLOR_DIM, Font = FONT, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Parent = sciencePanel,
})
local progressBg = create("Frame", { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = COLOR_PANEL, LayoutOrder = 11, Parent = sciencePanel })
style(progressBg, 4)
local progressBar = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(80, 200, 255), Parent = progressBg })
style(progressBar, 4)

-- 3) Відлік і повідомлення ---------------------------------------
local countdownLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromOffset(400, 140),
	BackgroundTransparency = 1, Text = "", TextColor3 = COLOR_ACCENT, Font = FONT_BOLD, TextSize = 110,
	TextStrokeTransparency = 0.3, Visible = false, Parent = gui,
})

local toast = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 56), Size = UDim2.fromOffset(560, 0),
	AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLOR_BG, BackgroundTransparency = 0.1,
	Text = "", TextColor3 = COLOR_TEXT, Font = FONT_BOLD, TextSize = 16, TextWrapped = true,
	Visible = false, Parent = gui,
})
style(toast, 8)
create("UIPadding", {
	PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
	PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = toast,
})
local toastStroke = create("UIStroke", { Color = COLOR_ACCENT, Thickness = 2, Parent = toast })
local toastId = 0
local function showToast(text, isError)
	toastId += 1
	local id = toastId
	toast.Text = text
	toastStroke.Color = isError and COLOR_ERROR or COLOR_ACCENT
	toast.Visible = true
	task.delay(5, function()
		if toastId == id then
			toast.Visible = false
		end
	end)
end

--------------------------------------------------------------------
-- Стан
--------------------------------------------------------------------
local mode = "none"          -- "none" | "hangar" | "pad" | "flight"
local lastFlightEnd = 0
local counting = false
local hiddenGuis = {}
local savedZoom = nil
local keys = { W = 0, S = 0, A = 0, D = 0, Q = 0, E = 0, Up = 0, Down = 0 }
local throttle = 1
local lastSentThrottle = 1
local THROTTLE_RATE = 0.6 -- за секунду, поки тримаєш Shift / Ctrl
local lastSentDir = Vector3.zero
local lastSendTime = 0
local lastFrame = nil
local lastBeep = 0

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

local function altitudeZone(km)
	if km < 15 then
		return "TROPOSPHERE", Color3.fromRGB(130, 190, 255)
	elseif km < 50 then
		return "STRATOSPHERE", Color3.fromRGB(100, 140, 230)
	elseif km < 85 then
		return "MESOSPHERE", Color3.fromRGB(150, 130, 230)
	elseif km < F.TARGET_ALTITUDE_KM then
		return "THERMOSPHERE", Color3.fromRGB(200, 140, 230)
	end
	return "SPACE", COLOR_ACCENT
end

--------------------------------------------------------------------
-- Керування в польоті (ContextActionService перехоплює W/A/S/D/Space у персонажа)
--------------------------------------------------------------------
local KEY_MAP = {
	[Enum.KeyCode.W] = "W", [Enum.KeyCode.Up] = "W",
	[Enum.KeyCode.S] = "S", [Enum.KeyCode.Down] = "S",
	[Enum.KeyCode.A] = "A", [Enum.KeyCode.Left] = "A",
	[Enum.KeyCode.D] = "D", [Enum.KeyCode.Right] = "D",
	[Enum.KeyCode.Q] = "Q", [Enum.KeyCode.E] = "E",
}

-- Режими орієнтації (див. FlightPhysics:SetAttitudeMode)
local MODE_NAMES = {
	sas = "SAS — stability assist",
	free = "free rotation",
	retrograde = "retrograde (nozzle forward)",
	radial = "nozzle to planet",
}
local function setAttitude(mode)
	attitudeEvent:FireServer(mode)
end

local function onAttitude(_, inputState, input)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local rocket = findRocket()
	local current = rocket and rocket:GetAttribute("AttitudeMode") or "sas"
	if input.KeyCode == Enum.KeyCode.T then
		setAttitude(current == "free" and "sas" or "free")
	elseif input.KeyCode == Enum.KeyCode.R then
		setAttitude(current == "retrograde" and "sas" or "retrograde")
	elseif input.KeyCode == Enum.KeyCode.G then -- V зайнята перемиканням камери (AstronautClient)
		setAttitude(current == "radial" and "sas" or "radial")
	end
	return Enum.ContextActionResult.Sink
end

local function onTilt(_, inputState, input)
	local k = KEY_MAP[input.KeyCode]
	if k then
		keys[k] = (inputState == Enum.UserInputState.Begin) and 1 or 0
	end
	return Enum.ContextActionResult.Sink
end

for _, b in ipairs(ATTITUDE_BUTTONS) do
	b.button.Activated:Connect(function()
		local rocket = findRocket()
		local current = rocket and rocket:GetAttribute("AttitudeMode") or "sas"
		if b.mode == "sas" then
			setAttitude(current == "sas" and "free" or "sas")
		else
			setAttitude(current == b.mode and "sas" or b.mode)
		end
	end)
end

local function onThrottle(_, inputState, input)
	local down = inputState == Enum.UserInputState.Begin
	local k = input.KeyCode
	if k == Enum.KeyCode.LeftShift or k == Enum.KeyCode.RightShift then
		keys.Up = down and 1 or 0
	elseif k == Enum.KeyCode.LeftControl or k == Enum.KeyCode.RightControl then
		keys.Down = down and 1 or 0
	elseif down and k == Enum.KeyCode.Z then
		throttle = 1
	elseif down and k == Enum.KeyCode.X then
		throttle = 0
	end
	return Enum.ContextActionResult.Sink
end

local function onStage(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		stageEvent:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function onParachute(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		edlEvent:FireServer("parachute")
	end
	return Enum.ContextActionResult.Sink
end

local function onFairing(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		fairingEvent:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local PRIORITY = Enum.ContextActionPriority.High.Value + 100

local function bindFlightControls()
	ContextActionService:BindActionAtPriority("FlightTilt", onTilt, false, PRIORITY,
		Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.A, Enum.KeyCode.D,
		Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Q, Enum.KeyCode.E)
	ContextActionService:BindActionAtPriority("FlightAttitude", onAttitude, false, PRIORITY,
		Enum.KeyCode.T, Enum.KeyCode.R, Enum.KeyCode.G)
	ContextActionService:BindActionAtPriority("FlightStage", onStage, false, PRIORITY, Enum.KeyCode.Space)
	ContextActionService:BindActionAtPriority("FlightFairing", onFairing, false, PRIORITY, Enum.KeyCode.F)
	ContextActionService:BindActionAtPriority("FlightEDL", onParachute, false, PRIORITY, Enum.KeyCode.P)
	ContextActionService:BindActionAtPriority("FlightThrottle", onThrottle, false, PRIORITY,
		Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl,
		Enum.KeyCode.Z, Enum.KeyCode.X)
	throttle = 1
	lastSentThrottle = 1
end

local function unbindFlightControls()
	ContextActionService:UnbindAction("FlightTilt")
	ContextActionService:UnbindAction("FlightStage")
	ContextActionService:UnbindAction("FlightFairing")
	ContextActionService:UnbindAction("FlightThrottle")
	ContextActionService:UnbindAction("FlightAttitude")
	ContextActionService:UnbindAction("FlightEDL")
	windSound:Stop()
	edlBanner.Visible = false
	for k in pairs(keys) do
		keys[k] = 0
	end
end

--------------------------------------------------------------------
-- Вхід / вихід з режиму польоту
--------------------------------------------------------------------
-- Спорядження ракети (для кнопок приладів і енергобалансу) — з креслення RocketDesign
local loadout = nil
local function readLoadout()
	local ok, raw = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("RocketDesign") or "")
	local design = ok and RocketMath.Sanitize(raw)
	if not design then
		return nil
	end
	local modules = {}
	for _, id in ipairs(design.stack) do
		modules[id] = true
	end
	for _, id in ipairs(design.radial) do
		modules[id] = true
	end
	return {
		modules = modules,
		power = RocketMath.Compute(design).power,
		battery = modules.battery == true,
		antenna = modules.antenna_low or modules.antenna_medium or modules.antenna_high or false,
	}
end

local function enterFlight()
	loadout = readLoadout()
	-- ховаємо UI ангара (HUD, конструктор тощо) — пам'ятаємо, що саме сховали
	hiddenGuis = {}
	for _, g in ipairs(playerGui:GetChildren()) do
		-- KeepInFlight: HUD астронавта (AstronautClient) потрібен саме в польоті
		if g:IsA("ScreenGui") and g ~= gui and g.Enabled and not g:GetAttribute("KeepInFlight") then
			g.Enabled = false
			table.insert(hiddenGuis, g)
		end
	end
	local rocket = findRocket()
	if rocket and rocket.PrimaryPart then
		camera.CameraSubject = rocket.PrimaryPart
	end
	savedZoom = { player.CameraMinZoomDistance, player.CameraMaxZoomDistance }
	player.CameraMaxZoomDistance = 600
	player.CameraMinZoomDistance = 45 -- віддаляємо камеру, щоб було видно всю ракету
	task.delay(0.5, function()
		if mode == "flight" then
			player.CameraMinZoomDistance = 8
		end
	end)
	bindFlightControls()
	flightFrame.Visible = true
end

local function exitFlight()
	unbindFlightControls()
	flightFrame.Visible = false
	for _, g in ipairs(hiddenGuis) do
		if g.Parent then
			g.Enabled = true
		end
	end
	hiddenGuis = {}
	if savedZoom then
		player.CameraMinZoomDistance = savedZoom[1]
		player.CameraMaxZoomDistance = savedZoom[2]
		savedZoom = nil
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	inputEvent:FireServer(Vector3.zero)
	lastSentDir = Vector3.zero
	lastFlightEnd = os.clock()
end

--------------------------------------------------------------------
-- Відлік і запуск
--------------------------------------------------------------------
-- Відлік веде сервер (атрибут ракети Countdown: 5…1, 0 = ПУСК): так його бачать усі гравці,
-- а вежа й дим синхронізовані з ним.
local function startCountdown()
	if counting or mode ~= "pad" then
		return
	end
	counting = true
	launchEvent:FireServer("Ignite")
	task.delay(2, function()
		counting = false
	end)
end

local lastCountdown = nil
local function showCountdown(value)
	if value == lastCountdown then
		return
	end
	lastCountdown = value
	if value == nil then
		countdownLabel.Visible = false
		return
	end
	countdownLabel.Visible = true
	countdownLabel.Text = value > 0 and ("T−" .. value) or "LIFTOFF!"
	countdownLabel.TextTransparency = 0
	TweenService:Create(countdownLabel, TweenInfo.new(0.9), { TextTransparency = value > 0 and 0.6 or 0.2 }):Play()
end

local function onLaunchKey(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		task.spawn(startCountdown)
	end
	return Enum.ContextActionResult.Sink
end

primaryButton.Activated:Connect(function()
	if mode == "hangar" then
		if (player:GetAttribute("RocketFuel") or 0) > 0 then
			launchEvent:FireServer("ToPad")
		end
	elseif mode == "pad" then
		task.spawn(startCountdown)
	end
end)
secondaryButton.Activated:Connect(function()
	if mode == "pad" and not lastCountdown then
		launchEvent:FireServer("ToHangar")
	end
end)
stageButton.Activated:Connect(function()
	stageEvent:FireServer()
end)
fairingButton.Activated:Connect(function()
	fairingEvent:FireServer()
end)
chuteButton.Activated:Connect(function()
	edlEvent:FireServer("parachute")
end)
endButton.Activated:Connect(function()
	launchEvent:FireServer("End")
end)

--------------------------------------------------------------------
-- Перемикання режимів за атрибутами гравця
--------------------------------------------------------------------
local function refreshMode()
	local state = player:GetAttribute("RocketState")
	local newMode = "none"
	if player:GetAttribute("InGame") == true and player:GetAttribute("RocketBuilt") == true then
		if state == "Flight" then
			newMode = "flight"
		elseif state == "OnPad" then
			newMode = "pad"
		else
			newMode = "hangar"
		end
	end

	if newMode ~= mode then
		if mode == "flight" then
			exitFlight()
		end
		if mode == "pad" then
			ContextActionService:UnbindAction("LaunchKey")
		end
		mode = newMode
		if mode == "flight" then
			enterFlight()
		elseif mode == "pad" then
			ContextActionService:BindActionAtPriority("LaunchKey", onLaunchKey, false, PRIORITY, Enum.KeyCode.Return)
		end
	end

	-- панель запуску
	-- поки відкритий конструктор, панель ховається: інакше вона накриває його кнопки «Розібрати / Заправити»
	launchPanel.Visible = (mode == "hangar" or mode == "pad") and player:GetAttribute("BuilderOpen") ~= true
	if mode == "hangar" then
		local fuel = player:GetAttribute("RocketFuel") or 0
		local cap = player:GetAttribute("RocketFuelCapacity") or 0
		local pct = cap > 0 and math.floor(fuel / cap * 100 + 0.5) or 0
		launchTitle.Text = "🚀 Rocket in the hangar · fuel " .. pct .. "%"
		primaryButton.Text = fuel > 0 and "TO THE LAUNCH PAD" or "Fuel the rocket first"
		primaryButton.BackgroundColor3 = fuel > 0 and Color3.fromRGB(200, 70, 40) or COLOR_BUTTON
		primaryButton.AutoButtonColor = fuel > 0
		secondaryButton.Visible = false
		launchPanel.Size = UDim2.fromOffset(300, 108)
	elseif mode == "pad" then
		launchTitle.Text = "Rocket on the launch pad. All systems nominal."
		primaryButton.Text = "LAUNCH [ENTER]"
		primaryButton.BackgroundColor3 = Color3.fromRGB(200, 70, 40)
		primaryButton.AutoButtonColor = true
		secondaryButton.Visible = true
		secondaryButton.Text = "↩ Back to the hangar"
		launchPanel.Size = UDim2.fromOffset(300, 150)
	end
end

for _, name in ipairs({ "RocketState", "RocketBuilt", "InGame", "RocketFuel", "RocketFuelCapacity", "BuilderOpen" }) do
	player:GetAttributeChangedSignal(name):Connect(refreshMode)
end
refreshMode()

-- КРОК 3 (EVA): поки астронавт на поверхні, W/A/S/D/Space/F керують персонажем, а не ракетою,
-- камера дивиться на астронавта, пульт польоту сховано
local evaActive = false
local function refreshEVA()
	local want = mode == "flight" and player:GetAttribute("EVA") == true
	if want == evaActive then
		return
	end
	evaActive = want
	if want then
		unbindFlightControls()
		flightFrame.Visible = false
		player.CameraMinZoomDistance = 0.5
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	elseif mode == "flight" then
		-- повернувся в капсулу: пульт назад, дросель 0 (не злітаємо самі собою)
		bindFlightControls()
		throttle = 0
		lastSentThrottle = 0
		inputEvent:FireServer(Vector3.zero, 0)
		flightFrame.Visible = true
		player.CameraMinZoomDistance = 8
	end
end
player:GetAttributeChangedSignal("EVA"):Connect(refreshEVA)
player:GetAttributeChangedSignal("RocketState"):Connect(function()
	if mode ~= "flight" then
		evaActive = false
	end
	refreshEVA()
end)

notifyEvent.OnClientEvent:Connect(function(text, isError)
	-- у ангарі повідомлення показує HUDClient; у польоті його UI схований — показуємо ми
	if mode == "flight" or os.clock() - lastFlightEnd < 3 then
		showToast(text, isError)
	end
end)

--------------------------------------------------------------------
-- Оновлення пульта щокадру
--------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	local padRocket = (mode == "pad" or mode == "flight") and findRocket()
	showCountdown(padRocket and padRocket:GetAttribute("Countdown") or nil)
	if mode ~= "flight" or evaActive then
		return
	end
	local rocket = findRocket()
	local core = rocket and rocket.PrimaryPart
	if not core then
		return
	end
	if camera.CameraSubject ~= core then
		camera.CameraSubject = core
	end

	-- Поворот 6DOF відносно КАМЕРИ (так інтуїтивно з будь-якого ракурсу):
	--   W/S — ніс від тебе / до тебе (тангаж), A/D — ніс вліво / вправо (рискання),
	--   Q/E — крен навколо осі ракети. На сервер йде світовий вектор кутової швидкості ω.
	local camCF = camera.CFrame
	local nose = core:FindFirstChild("FlightCore") and core.FlightCore.WorldCFrame.UpVector or Vector3.yAxis
	local dir = camCF.RightVector * -(keys.W - keys.S) + camCF.LookVector * (keys.D - keys.A) + nose * ((keys.E or 0) - (keys.Q or 0))
	local now = os.clock()
	local dt = math.min(now - (lastFrame or now), 0.1)
	lastFrame = now
	throttle = math.clamp(throttle + (keys.Up - keys.Down) * THROTTLE_RATE * dt, 0, 1)
	if ((dir - lastSentDir).Magnitude > 0.05 or math.abs(throttle - lastSentThrottle) > 0.01) and now - lastSendTime > 0.05 then
		inputEvent:FireServer(dir, throttle)
		lastSentDir = dir
		lastSentThrottle = throttle
		lastSendTime = now
	end
	-- орієнтація: режим і швидкість повороту (залежить від RCS Draco і маси)
	local attMode = rocket:GetAttribute("AttitudeMode") or "sas"
	attitudeValue.Text = string.format("%s · %.0f°/s", attMode == "free" and "free" or (attMode == "sas" and "SAS") or (attMode == "retrograde" and "retrograde") or "to planet",
		rocket:GetAttribute("TurnRateDeg") or 0)
	attitudeValue.TextColor3 = attMode == "free" and COLOR_WARN or COLOR_TEXT
	for _, b in ipairs(ATTITUDE_BUTTONS) do
		local active = (b.mode == attMode)
		b.button.BackgroundColor3 = active and Color3.fromRGB(40, 110, 170) or COLOR_BUTTON
		if b.mode == "sas" then
			b.button.Text = attMode == "free" and "SAS OFF [T]" or "SAS [T]"
			b.button.BackgroundColor3 = attMode == "free" and Color3.fromRGB(110, 70, 30) or (active and Color3.fromRGB(40, 110, 170) or COLOR_BUTTON)
		end
	end
	throttleValue.Text = string.format("%d%%", math.floor(throttle * 100 + 0.5))
	throttleValue.TextColor3 = throttle > 0 and COLOR_TEXT or COLOR_WARN

	-- Телеметрія
	local padY = rocket:GetAttribute("PadY") or 0
	local altKm = math.max(core.Position.Y - padY, 0) * M_PER_STUD / 1000
	local vel = core.AssemblyLinearVelocity * M_PER_STUD -- м/с
	-- "вертикаль" — від центру планети (біля Землі — +Y): на боці сфери швидкості теж вірні
	local localUp = PlanetZoneManager.UpAt(core.Position)
	local vs = vel:Dot(localUp)
	local hs = (vel - localUp * vs).Magnitude

	altValue.Text = altKm < 10 and string.format("%.2f km", altKm) or string.format("%.1f km", altKm)
	vsValue.Text = (vs >= 0 and "▲ " or "▼ ") .. fmt(math.abs(vs)) .. " m/s"
	vsValue.TextColor3 = vs >= 0 and COLOR_TEXT or COLOR_WARN
	hsValue.Text = fmt(hs) .. " / " .. fmt(F.ORBITAL_SPEED) .. " m/s"
	local zone, zoneColor = altitudeZone(altKm)
	-- біля планети: її назва, тяжіння і висота над її поверхнею
	local pZone, pId, pF, pAltM = PlanetZoneManager.Locate(core.Position)
	if pZone and pF > 0.3 then
		local cfg = PlanetZoneManager.CONFIG[pId]
		zone = string.format("%s · g = %.2f m/s²", cfg.nameOn, PlanetZoneManager.Gravity(core.Position, 9.807))
		zoneColor = cfg.color
		altValue.Text = (pAltM < 10000 and string.format("%.2f km", pAltM / 1000) or string.format("%.1f km", pAltM / 1000))
	end
	zoneLabel.Text = zone
	zoneLabel.TextColor3 = zoneColor

	local twr = rocket:GetAttribute("TWR") or 0
	twrValue.Text = twr > 0 and string.format("%.2f", twr) or "— (engine off)"
	twrValue.TextColor3 = (twr == 0 and COLOR_DIM) or (twr < 1 and COLOR_WARN) or COLOR_OK
	massValue.Text = fmt(rocket:GetAttribute("MassKg") or 0) .. " kg"

	local active = rocket:GetAttribute("ActiveStage") or 1
	local count = rocket:GetAttribute("StageCount") or 1
	stageValue.Text = active .. " / " .. count .. ((rocket:GetAttribute("EngineOn") and "  🔥") or "")

	local fuelPct = rocket:GetAttribute("StageFuelPct") or 0
	fuelText.Text = string.format("Stage %d fuel: %d%%", active, math.floor(fuelPct + 0.5))
	fuelBar.Size = UDim2.fromScale(math.clamp(fuelPct / 100, 0, 1), 1)
	fuelBar.BackgroundColor3 = (fuelPct < 10 and COLOR_ERROR) or (fuelPct < 30 and COLOR_WARN) or COLOR_OK

	-- Шкала висоти
	marker.Position = UDim2.new(0.5, 0, ladderY(altKm), 0)
	apogeeMark.Position = UDim2.new(0.5, 0, ladderY(rocket:GetAttribute("ApogeeKm") or 0), 0)
	ladderOver.Text = altKm > LADDER_MAX_KM and ("▲ " .. math.floor(altKm) .. " km") or ""

	-- Кнопка відстрілу: підсвічується, коли пальне ступеня = 0% і є що відділяти
	local hasNext = rocket:FindFirstChild("Decoupler" .. active) ~= nil
	if hasNext and fuelPct <= 0.5 then
		local pulse = (math.sin(now * 8) + 1) / 2
		stageButton.BackgroundColor3 = Color3.fromRGB(200, 70, 40):Lerp(Color3.fromRGB(255, 140, 40), pulse)
		stageStroke.Transparency = 0.6 * (1 - pulse)
	elseif hasNext then
		stageButton.BackgroundColor3 = COLOR_BUTTON
		stageStroke.Transparency = 1
	else
		stageButton.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
		stageStroke.Transparency = 1
	end
	stageButton.TextColor3 = hasNext and COLOR_TEXT or COLOR_DIM
	stageButton.Text = hasNext and "STAGE SEPARATION [SPACE]" or "LAST STAGE"

	local hasFairing = rocket:GetAttribute("HasFairing") == true
	fairingButton.Visible = hasFairing
	local fairingReady = altKm >= F.FAIRING_MIN_ALTITUDE_KM
	fairingButton.BackgroundColor3 = fairingReady and Color3.fromRGB(40, 110, 170) or COLOR_BUTTON
	fairingButton.Text = fairingReady and "JETTISON FAIRING [F]"
		or ("FAIRING: above " .. F.FAIRING_MIN_ALTITUDE_KM .. " km")

	----------------------------------------------------------------
	-- EDL: сповіщення про оптимальний момент розкриття парашута
	--   зниження = радіальна швидкість спрямована до планети (vs < −DESCENT_SPEED)
	--   жовтий: 15 … 3 км над поверхнею · червоний: < 3 км і швидше 30 м/с · зелений: гальмування
	--   Оптимальний момент — коли висота < 20 км і швидкісний напір ½ρv² менший за ліміт купола.
	----------------------------------------------------------------
	local surfaceId, surfaceAltM = PlanetZoneManager.Surface(core.Position)
	local rho = rocket:GetAttribute("AirDensity") or 0
	local speedNow = vel.Magnitude
	local q = 0.5 * rho * speedNow * speedNow
	local hasChute = rocket:GetAttribute("HasParachute") == true
	local chuteState = rocket:GetAttribute("ParachuteState") or "stowed"
	local autoLand = rocket:GetAttribute("AutoLand") == true
	local descending = vs < -EDLC.DESCENT_SPEED
	local vacuum = rho < 1e-4
	local level, title, sub = nil, nil, nil -- level: "warn" | "crit" | "ok"
	local planetName = (surfaceId == "Moon" and "THE MOON") or (surfaceId == "Mars" and "MARS") or "EARTH"
	if rocket:GetAttribute("Landed") == true then
		level = nil
	elseif chuteState == "open" then
		level, title = "ok", "🪂 PARACHUTE DEPLOYED — BRAKING"
		sub = string.format("descent %.0f m/s · altitude %.1f km", math.max(-vs, 0), surfaceAltM / 1000)
			.. (rocket:GetAttribute("ChuteReefed") and string.format(" · reefed canopy until %.1f km", EDLC.REEF_ALT_KM) or "")
			.. (surfaceId == "Mars" and -vs > 15 and " · on Mars, finish braking with the engine!" or "")
	elseif autoLand then
		level, title = "ok", "🧲 AUTOLAND — GUIDING TO THE PAD"
		local toPadM = rocket:GetAttribute("AutoLandTargetM")
		sub = string.format("descent %.1f m/s · altitude %.2f km", math.max(-vs, 0), surfaceAltM / 1000)
			.. (toPadM and (toPadM >= 1000 and string.format(" · %.1f km to the pad", toPadM / 1000)
				or string.format(" · %.0f m to the pad", toPadM)) or "")
			.. " · P — turn off"
	elseif descending and surfaceAltM < EDLC.WARN_ALT_KM * 1000 then
		local critical = surfaceAltM < EDLC.CRIT_ALT_KM * 1000 and -vs > EDLC.CRIT_SPEED
		level = critical and "crit" or "warn"
		if vacuum then
			title = critical and "CRITICAL ALTITUDE! ENGAGE AUTOLAND [P]" or ("WARNING: DESCENDING TO " .. planetName .. "! AUTOLAND [P]")
			sub = "no atmosphere — a parachute will not open, you can only brake with the engine"
		elseif not hasChute or chuteState ~= "stowed" then
			title = critical and "CRITICAL ALTITUDE! ENGAGE AUTOLAND [P]" or "WARNING: DESCENDING! AUTOLAND [P]"
			sub = (chuteState == "torn" and "canopy torn" or "no parachute")
				.. " — P: powered autoland to the pad, or R (retrograde) + Shift (throttle)"
		else
			title = critical and "CRITICAL ALTITUDE! DEPLOY THE PARACHUTE NOW [P]" or "WARNING: DESCENDING! DEPLOY THE PARACHUTE [P]"
			if q > EDLC.MAX_Q then
				sub = string.format("⚠ too fast right now: dynamic pressure %.0f kPa > %.0f kPa — the canopy will tear; brake with the engine", q / 1000, EDLC.MAX_Q / 1000)
			else
				sub = string.format("✔ optimal moment: dynamic pressure %.0f / %.0f kPa · descent %.0f m/s · %.1f km", q / 1000, EDLC.MAX_Q / 1000, -vs, surfaceAltM / 1000)
			end
		end
	end
	edlBanner.Visible = level ~= nil
	if level then
		local pulse = (math.sin(now * (level == "crit" and 10 or 5)) + 1) / 2
		local color = (level == "ok" and COLOR_OK) or (level == "crit" and COLOR_ERROR) or COLOR_WARN
		edlTitle.Text = title
		edlTitle.TextColor3 = color
		edlSub.Text = sub or ""
		edlStroke.Color = color
		edlStroke.Transparency = level == "ok" and 0.2 or (0.6 * (1 - pulse))
		edlBanner.BackgroundColor3 = (level == "ok" and Color3.fromRGB(10, 35, 20)) or (level == "crit" and Color3.fromRGB(50, 10, 10)) or Color3.fromRGB(45, 32, 8)
		-- звуковий сигнал телеметрії: частіше в критичній зоні
		if level ~= "ok" and now - (lastBeep or 0) > (level == "crit" and 1.2 or 3.5) then
			lastBeep = now
			beepSound:Play()
		end
	end
	-- кнопка парашута: підсвічується, коли час розкривати
	local wantP = level == "warn" or level == "crit"
	-- P працює завжди: на Землі з парашутом — купол, інакше — автопосадка на майданчик
	local chuteFirst = surfaceId == "Earth" and hasChute and chuteState == "stowed"
	chuteButton.Visible = true
	chuteButton.Text = (autoLand and "🧲 AUTOLAND ✔ [P]")
		or (chuteFirst and "PARACHUTE [P]")
		or (chuteState == "open" and surfaceId == "Earth" and "PARACHUTE ✔ · 🧲 [P]")
		or "🧲 AUTOLAND [P]"
	if wantP then
		local pulse = (math.sin(now * 8) + 1) / 2
		chuteButton.BackgroundColor3 = Color3.fromRGB(200, 110, 20):Lerp(Color3.fromRGB(255, 170, 40), pulse)
		chuteStroke.Transparency = 0.5 * (1 - pulse)
	else
		chuteButton.BackgroundColor3 = (chuteState == "open" or autoLand) and Color3.fromRGB(40, 120, 70) or COLOR_BUTTON
		chuteStroke.Transparency = 1
	end
	-- свист повітря за швидкісним напором (у вакуумі тиша)
	local windVol = math.clamp(q / 30000, 0, 0.8)
	if windVol > 0.02 then
		if not windSound.IsPlaying then
			windSound:Play()
		end
		windSound.Volume = windVol
		windSound.PlaybackSpeed = 0.8 + math.clamp(speedNow / 600, 0, 0.6)
	elseif windSound.IsPlaying then
		windSound:Stop()
	end
	if autoLand then
		throttleValue.Text = string.format("AUTO %d%%", math.floor((rocket:GetAttribute("Throttle") or 0) * 100 + 0.5))
	end

	-- Енергобаланс (Вт) і ціль місії
	local lo = loadout
	if lo then
		powerValue.Text = (lo.power > 0 and "+" or "") .. fmt(lo.power) .. " W" .. (lo.battery and " 🔋" or "")
		powerValue.TextColor3 = (lo.power >= 0 and COLOR_OK) or (lo.battery and COLOR_WARN) or COLOR_ERROR
	end
	local inZone = rocket:GetAttribute("InScienceZone") == true
	local landed = rocket:GetAttribute("Landed") == true
	local targetKm = rocket:GetAttribute("TargetDistanceKm")
	local targetName = rocket:GetAttribute("TargetName")
	local landedZone = rocket:GetAttribute("LandedZone")
	if landed then
		local cfg = landedZone and PlanetZoneManager.CONFIG[landedZone]
		zoneValue.Text = cfg and ("on the surface: " .. cfg.name) or "on the surface"
		zoneValue.TextColor3 = COLOR_OK
	elseif targetKm and targetName then
		zoneValue.Text = string.format("%s · %.1f km", targetName, targetKm) .. (inZone and " ✔" or "")
		zoneValue.TextColor3 = inZone and COLOR_OK or COLOR_TEXT
	end

	-- Наукові прилади
	local anyInstrument = false
	local busy = rocket:GetAttribute("ScienceBusy") or ""
	local done = rocket:GetAttribute("ScienceDone") or ""
	for _, s in ipairs(SCIENCE) do
		local has = lo and lo.modules[s.module] == true
		s.button.Visible = has
		if has then
			anyInstrument = true
			local isDone = done:find(s.kind, 1, true) ~= nil
			local ready = (s.kind == "drill" and landed) or (s.kind ~= "drill" and inZone)
			if isDone then
				s.button.Text = s.label .. " ✔"
				s.button.BackgroundColor3 = Color3.fromRGB(40, 90, 60)
			elseif busy == s.kind then
				s.button.Text = s.label .. "…"
				s.button.BackgroundColor3 = Color3.fromRGB(40, 110, 170)
			else
				s.button.Text = s.label
				s.button.BackgroundColor3 = ready and Color3.fromRGB(40, 110, 170) or COLOR_BUTTON
			end
			s.button.TextColor3 = (ready or isDone) and COLOR_TEXT or COLOR_DIM
		end
	end
	sciencePanel.Visible = anyInstrument
	if anyInstrument then
		if busy ~= "" then
			scienceStatus.Text = "Instrument running…"
		elseif lo and lo.power < 0 and not lo.battery then
			scienceStatus.Text = "⚠ Not enough power: add a solar panel or a battery."
		elseif lo and not lo.antenna then
			scienceStatus.Text = "⚠ No antenna: the data cannot be sent to Earth."
		elseif inZone or landed then
			scienceStatus.Text = "The crater is within instrument range." .. (landed and "" or " Drill — after landing.")
		else
			scienceStatus.Text = "Fly to the crater (closer than 19 km)."
		end
		local prog = busy ~= "" and (rocket:GetAttribute("ScanProgress") or 0) or 0
		progressBar.Size = UDim2.fromScale(math.clamp(prog / 100, 0, 1), 1)
	end
end)

--------------------------------------------------------------------
-- Вібрація камери під час роботи двигунів біля Землі (після оновлення камери Roblox)
--------------------------------------------------------------------
RunService:BindToRenderStep("FlightCameraShake", Enum.RenderPriority.Camera.Value + 1, function()
	if mode ~= "flight" then
		return
	end
	local rocket = findRocket()
	local core = rocket and rocket.PrimaryPart
	if not core then
		return
	end
	local amp = 0
	if rocket:GetAttribute("EngineOn") and (rocket:GetAttribute("Throttle") or 1) > 0.05 then
		local altKm = math.max(core.Position.Y - (rocket:GetAttribute("PadY") or 0), 0) * M_PER_STUD / 1000
		amp = math.rad(0.35) * math.clamp(1 - altKm / 15, 0, 1) -- слабшає з висотою (розріджене повітря)
	end
	-- трусить і від набігаючого потоку при швидкому падінні: швидкісний напір q = ½ρv²
	local v = core.AssemblyLinearVelocity.Magnitude * M_PER_STUD
	local q = 0.5 * (rocket:GetAttribute("AirDensity") or 0) * v * v
	amp = math.max(amp, math.rad(0.45) * math.clamp(q / 25000, 0, 1))
	if amp > 0 then
		camera.CFrame *= CFrame.Angles((math.random() - 0.5) * amp, (math.random() - 0.5) * amp, 0)
	end
end)

--------------------------------------------------------------------
-- Звіт місії NASA (після завершення польоту)
--------------------------------------------------------------------
local reportFrame = nil
reportEvent.OnClientEvent:Connect(function(r)
	if type(r) ~= "table" then
		return
	end
	if reportFrame then
		reportFrame:Destroy()
	end
	local shade = create("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45,
		ZIndex = 50, Parent = gui,
	})
	reportFrame = shade
	local win = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(460, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLOR_BG, ZIndex = 51, Parent = shade,
	})
	style(win, 12, r.crashed and COLOR_ERROR or COLOR_ACCENT)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20),
		PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16), Parent = win,
	})
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = win })
	local order = 0
	local function line(text, color, size, bold)
		order += 1
		return create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
			Text = text, TextColor3 = color or COLOR_TEXT, Font = bold and FONT_BOLD or FONT, TextSize = size or 15,
			TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = order, ZIndex = 52, Parent = win,
		})
	end
	local function pair(label, value, color)
		order += 1
		local row = create("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = order, ZIndex = 52, Parent = win })
		create("TextLabel", {
			Size = UDim2.fromScale(0.6, 1), BackgroundTransparency = 1, Text = label, TextColor3 = COLOR_DIM, Font = FONT,
			TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 52, Parent = row,
		})
		create("TextLabel", {
			Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 1, Text = value,
			TextColor3 = color or COLOR_TEXT, Font = FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 52, Parent = row,
		})
	end
	line("MISSION REPORT", COLOR_DIM, 12, true)
	line(r.title or "Flight ended", r.crashed and COLOR_ERROR or COLOR_ACCENT, 22, true)
	pair("Apogee", string.format("%.1f km", r.apogeeKm or 0), (r.reachedSpace and COLOR_OK) or nil)
	pair("Max speed", fmt(r.maxSpeed or 0) .. " m/s")
	pair("Flight time", string.format("%d s", r.time or 0))
	if r.impactSpeed then
		pair("Impact speed", fmt(r.impactSpeed) .. " m/s", r.crashed and COLOR_ERROR or COLOR_OK)
	end
	pair("Rocket cost", "$" .. fmt(r.cost or 0))
	pair("Rocket Δv (Tsiolkovsky)", fmt(r.deltaV or 0) .. " m/s")
	pair("Fuel remaining", string.format("%d%%", math.floor((r.fuelLeftPct or 0) + 0.5)))
	local landedOn = r.landedOn or {}
	pair("Planet landing", #landedOn > 0 and (table.concat(landedOn, ", ") .. " ✔") or (r.landedOnCrater and "yes ✔" or "no"),
		(#landedOn > 0 or r.landedOnCrater) and COLOR_OK or COLOR_DIM)
	local sci = r.science or {}
	pair("Science data", #sci > 0 and table.concat(sci, ", ") or "—", #sci > 0 and COLOR_OK or COLOR_DIM)
	if (r.altitudePay or 0) > 0 then
		pair(string.format("Altitude pay ($%d/km)", F.ALTITUDE_PAY_PER_KM),
			"+$" .. fmt(r.altitudePay), COLOR_OK)
	end
	if (r.fuelBonus or 0) > 0 then
		pair("Fuel efficiency bonus", "+$" .. fmt(r.fuelBonus), COLOR_OK)
	end
	pair("Flight rewards", "+$" .. fmt(r.rewards or 0), COLOR_ACCENT)
	line(string.format("Engineering efficiency: %d / 100  ·  grade %s", r.score or 0, r.grade or "-"),
		COLOR_ACCENT, 17, true)
	order += 1
	local back = makeButton("Return to the hangar", win, UDim2.new(1, 0, 0, 42), Color3.fromRGB(200, 70, 40))
	back.LayoutOrder = order
	back.ZIndex = 52
	back.Activated:Connect(function()
		shade:Destroy()
		if reportFrame == shade then
			reportFrame = nil
		end
	end)
end)
