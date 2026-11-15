--[[
	MissionVictoryClient (LocalScript) — КРОК 5: фінальне вікно перемоги NASA «Sample Return Mission»
	Місце: StarterPlayer > StarterPlayerScripts > MissionVictoryClient

	Сервер (FlightServer.buildReport) ставить report.sampleReturn = true, коли ракета м'яко сіла
	на Землю зі зразком Місяця / Марса у вантажному відсіку капсули. Тоді поверх
	звичайного звіту відкривається це вікно з максимальним рейтингом (100 / 100, клас S).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local reportEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FlightReport")

local NASA_BLUE = Color3.fromRGB(11, 61, 145)
local NASA_RED = Color3.fromRGB(252, 61, 33)
local GOLD = Color3.fromRGB(255, 205, 80)
local PLANETS = {
	Moon = { name = "THE MOON", color = Color3.fromRGB(150, 220, 255), icon = "🌑" },
	Mars = { name = "MARS", color = Color3.fromRGB(255, 140, 70), icon = "🔴" },
}

local function create(className, props)
	local i = Instance.new(className)
	for k, v in pairs(props) do
		if k ~= "Parent" then
			i[k] = v
		end
	end
	i.Parent = props.Parent
	return i
end
local function corner(p, r)
	create("UICorner", { CornerRadius = UDim.new(0, r), Parent = p })
end
local function fmt(n)
	local s = tostring(math.floor(math.abs(n) + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

local current = nil

local function show(r)
	if current then
		current:Destroy()
	end
	local planet = PLANETS[r.samplePlanet] or PLANETS.Moon

	local gui = create("ScreenGui", {
		Name = "SampleReturnVictory",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 60,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	gui:SetAttribute("KeepInFlight", true)
	current = gui

	-- тло: зоряний космос
	local bg = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(4, 8, 22),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	create("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(10, 25, 70), Color3.fromRGB(2, 4, 12)),
		Rotation = 90,
		Parent = bg,
	})
	local rng = Random.new()
	for _ = 1, 70 do
		local s = rng:NextNumber(1, 3)
		create("Frame", {
			Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber()),
			Size = UDim2.fromOffset(s, s),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = rng:NextNumber(0, 0.6),
			BorderSizePixel = 0,
			Parent = bg,
		})
	end
	TweenService:Create(bg, TweenInfo.new(0.6), { BackgroundTransparency = 0.08 }):Play()

	-- панель
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.fromOffset(620, 520),
		BackgroundColor3 = Color3.fromRGB(12, 20, 44),
		Parent = gui,
	})
	corner(panel, 18)
	create("UIStroke", { Color = GOLD, Thickness = 3, Parent = panel })
	create("UISizeConstraint", { MaxSize = Vector2.new(620, 520), Parent = panel })
	create("UIAspectRatioConstraint", { AspectRatio = 620 / 520, Parent = panel })
	local scale = create("UIScale", { Scale = 0.6, Parent = panel })
	TweenService:Create(scale, TweenInfo.new(0.55, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	TweenService:Create(panel, TweenInfo.new(0.55, Enum.EasingStyle.Back), { Position = UDim2.fromScale(0.5, 0.5) }):Play()

	-- шапка NASA
	local header = create("Frame", {
		Size = UDim2.new(1, 0, 0, 92),
		BackgroundColor3 = NASA_BLUE,
		Parent = panel,
	})
	corner(header, 18)
	create("Frame", { -- рівний низ шапки
		Position = UDim2.new(0, 0, 1, -18),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundColor3 = NASA_BLUE,
		BorderSizePixel = 0,
		Parent = header,
	})
	local badge = create("TextLabel", {
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Text = "NASA",
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = NASA_BLUE,
		Parent = header,
	})
	corner(badge, 32)
	create("UIStroke", { Color = NASA_RED, Thickness = 3, Parent = badge })
	create("TextLabel", {
		Position = UDim2.fromOffset(96, 12),
		Size = UDim2.new(1, -110, 0, 40),
		BackgroundTransparency = 1,
		Text = "MISSION ACCOMPLISHED",
		Font = Enum.Font.GothamBlack,
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = header,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(96, 52),
		Size = UDim2.new(1, -110, 0, 26),
		BackgroundTransparency = 1,
		Text = "SAMPLE RETURN MISSION · A SAMPLE FROM " .. planet.name .. " IS ON EARTH",
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = GOLD,
		Parent = header,
	})

	-- зразок
	local sampleBox = create("Frame", {
		Position = UDim2.fromOffset(24, 108),
		Size = UDim2.new(1, -48, 0, 70),
		BackgroundColor3 = Color3.fromRGB(20, 32, 64),
		Parent = panel,
	})
	corner(sampleBox, 12)
	create("UIStroke", { Color = planet.color, Thickness = 2, Parent = sampleBox })
	create("TextLabel", {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.fromOffset(56, 70),
		BackgroundTransparency = 1,
		Text = "🧪",
		TextSize = 40,
		Parent = sampleBox,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(78, 10),
		Size = UDim2.new(1, -92, 0, 26),
		BackgroundTransparency = 1,
		Text = r.sampleName or "Planet sample",
		Font = Enum.Font.GothamBold,
		TextSize = 19,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = planet.color,
		Parent = sampleBox,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(78, 38),
		Size = UDim2.new(1, -92, 0, 22),
		BackgroundTransparency = 1,
		Text = planet.icon .. " sealed container intact · delivered to the NASA JSC lab",
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(200, 210, 230),
		Parent = sampleBox,
	})

	-- показники польоту
	local stats = create("Frame", {
		Position = UDim2.fromOffset(24, 192),
		Size = UDim2.new(1, -48, 0, 150),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	create("UIGridLayout", {
		CellSize = UDim2.new(0.5, -6, 0, 44),
		CellPadding = UDim2.fromOffset(12, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stats,
	})
	local function stat(order, label, value)
		local f = create("Frame", { LayoutOrder = order, BackgroundColor3 = Color3.fromRGB(18, 28, 56), Parent = stats })
		corner(f, 8)
		create("TextLabel", {
			Position = UDim2.fromOffset(12, 3),
			Size = UDim2.new(1, -24, 0, 16),
			BackgroundTransparency = 1,
			Text = label,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.fromRGB(150, 165, 195),
			Parent = f,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(12, 18),
			Size = UDim2.new(1, -24, 0, 22),
			BackgroundTransparency = 1,
			Text = value,
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			Parent = f,
		})
	end
	local t = r.time or 0
	stat(1, "Apogee", string.format("%.0f km", r.apogeeKm or 0))
	stat(2, "Mission time", string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60)))
	stat(3, "Earth landing", string.format("%.1f m/s · safe", r.impactSpeed or 0))
	stat(4, "Max speed", string.format("%s m/s", fmt(r.maxSpeed or 0)))
	stat(5, "Science data", tostring(#(r.science or {})) .. " sets + sample")
	stat(6, "Mission budget", "+$" .. fmt(r.rewards or 0))

	-- рейтинг
	local rating = create("Frame", {
		Position = UDim2.fromOffset(24, 352),
		Size = UDim2.new(1, -48, 0, 84),
		BackgroundColor3 = Color3.fromRGB(40, 32, 8),
		Parent = panel,
	})
	corner(rating, 12)
	create("UIStroke", { Color = GOLD, Thickness = 2, Parent = rating })
	create("TextLabel", {
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.new(0.62, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "ENGINEERING EFFICIENCY RATING",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = GOLD,
		Parent = rating,
	})
	local stars = create("TextLabel", {
		Position = UDim2.fromOffset(16, 28),
		Size = UDim2.new(0.62, 0, 0, 44),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBlack,
		TextSize = 38,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = GOLD,
		Parent = rating,
	})
	local scoreLabel = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(200, 70),
		BackgroundTransparency = 1,
		Text = "0 / 100 · S",
		Font = Enum.Font.GothamBlack,
		TextSize = 36,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = rating,
	})
	-- анімація: зірки та лічильник до 100
	task.spawn(function()
		task.wait(0.6)
		for i = 1, 5 do
			if not gui.Parent then
				return
			end
			stars.Text = string.rep("★", i) .. string.rep("☆", 5 - i)
			task.wait(0.15)
		end
		local score = r.score or 100
		for v = 0, score, 4 do
			if not gui.Parent then
				return
			end
			scoreLabel.Text = v .. " / 100 · " .. (r.grade or "S")
			task.wait(0.02)
		end
		scoreLabel.Text = score .. " / 100 · " .. (r.grade or "S")
	end)

	local button = create("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(260, 46),
		BackgroundColor3 = NASA_RED,
		Text = "CONTINUE → MISSION REPORT",
		Font = Enum.Font.GothamBlack,
		TextSize = 17,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = panel,
	})
	corner(button, 10)
	button.Activated:Connect(function()
		TweenService:Create(bg, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(scale, TweenInfo.new(0.3), { Scale = 0.7 }):Play()
		task.delay(0.3, function()
			if current == gui then
				current = nil
			end
			gui:Destroy()
		end)
	end)

	-- конфеті кольорів NASA
	local colors = { NASA_RED, Color3.new(1, 1, 1), NASA_BLUE, GOLD, planet.color }
	local pieces = {}
	for i = 1, 60 do
		local p = create("Frame", {
			Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber(-0.6, 0)),
			Size = UDim2.fromOffset(rng:NextInteger(6, 10), rng:NextInteger(10, 16)),
			BackgroundColor3 = colors[i % #colors + 1],
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = gui,
		})
		pieces[p] = { v = rng:NextNumber(0.12, 0.25), spin = rng:NextNumber(-200, 200), drift = rng:NextNumber(-0.03, 0.03) }
	end
	local elapsed = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if not gui.Parent or elapsed > 7 then
			conn:Disconnect()
			for p in pairs(pieces) do
				if p.Parent then
					p:Destroy()
				end
			end
			return
		end
		for p, s in pairs(pieces) do
			p.Position += UDim2.fromScale(s.drift * dt, s.v * dt)
			p.Rotation += s.spin * dt
		end
	end)
end

reportEvent.OnClientEvent:Connect(function(r)
	if type(r) == "table" and r.sampleReturn then
		show(r)
	end
end)
