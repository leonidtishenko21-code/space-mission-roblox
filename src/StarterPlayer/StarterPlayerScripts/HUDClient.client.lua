--[[
	HUDClient (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > HUDClient

	What it does:
	  1. Top-left panel: budget ($) and RP-1 stock with a bar.
	  2. Oil derrick window (opens with E at the console):
	     level, production, storage, time to full, upgrade button.
	  3. Label above the storage tank: how full it is in %.
	  4. Pumpjack animation: rocks faster at higher levels, stops when the storage is full.
	  5. Messages from the server ("Not enough money", etc.).

	The HUD appears only after the main menu.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local upgradeEvent = remotes:WaitForChild("UpgradeOilRig")
local notifyEvent = remotes:WaitForChild("Notify")

--------------------------------------------------------------------
-- ⚙️ SETTINGS
--------------------------------------------------------------------
local FONT_BOLD = Enum.Font.GothamBold
local FONT_REGULAR = Enum.Font.Gotham

local COLOR_BUTTON = Color3.fromRGB(76, 153, 76)
local COLOR_BUTTON_HOVER = Color3.fromRGB(98, 180, 98)
local COLOR_BORDER = Color3.fromRGB(40, 80, 40)
local COLOR_DISABLED = Color3.fromRGB(90, 95, 100)
local COLOR_PANEL = Color3.fromRGB(18, 26, 50)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(180, 195, 220)
local COLOR_FUEL = Color3.fromRGB(230, 170, 50)
local COLOR_ERROR = Color3.fromRGB(220, 80, 70)

--------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------
local function create(className, props)
	local obj = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil
	for key, value in pairs(props) do
		obj[key] = value
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end

local function tween(obj, time, goal)
	local t = TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

-- 20000 → "20 000"
local function formatNumber(n)
	local s = tostring(math.floor(n + 0.5))
	local spaced = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (spaced:gsub("^%s+", ""))
end

-- 125 → "2 min 05 s"
local function formatTime(seconds)
	seconds = math.ceil(seconds)
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	if m > 0 then
		return string.format("%d min %02d s", m, s)
	end
	return s .. " s"
end

local function addStyle(obj, radius, strokeColor, thickness)
	create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = obj })
	create("UIStroke", {
		Color = strokeColor,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = obj,
	})
end

local function makeButton(text, parent)
	local button = create("TextButton", {
		Size = UDim2.fromOffset(200, 50),
		BackgroundColor3 = COLOR_BUTTON,
		Text = text,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 22,
		AutoButtonColor = false,
		Parent = parent,
	})
	addStyle(button, 12, COLOR_BORDER, 3)
	local scale = create("UIScale", { Scale = 1, Parent = button })
	button.MouseEnter:Connect(function()
		if button.Active then
			tween(scale, 0.12, { Scale = 1.05 })
			tween(button, 0.12, { BackgroundColor3 = COLOR_BUTTON_HOVER })
		end
	end)
	button.MouseLeave:Connect(function()
		tween(scale, 0.12, { Scale = 1 })
		if button.Active then
			tween(button, 0.12, { BackgroundColor3 = COLOR_BUTTON })
		end
	end)
	return button
end

local function setButtonEnabled(button, enabled)
	button.Active = enabled
	button.AutoButtonColor = false
	button.BackgroundColor3 = enabled and COLOR_BUTTON or COLOR_DISABLED
end

--------------------------------------------------------------------
-- HUD: budget and fuel
--------------------------------------------------------------------
local hud = create("ScreenGui", {
	Name = "HUD",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = false,
	DisplayOrder = 5,
	Parent = playerGui,
})

local hudPanel = create("Frame", {
	Name = "Resources",
	Position = UDim2.fromOffset(12, 12),
	Size = UDim2.fromOffset(300, 92),
	BackgroundColor3 = COLOR_PANEL,
	BackgroundTransparency = 0.15,
	Parent = hud,
})
addStyle(hudPanel, 12, COLOR_BORDER, 2)

local budgetLabel = create("TextLabel", {
	Position = UDim2.fromOffset(14, 8),
	Size = UDim2.new(1, -28, 0, 28),
	BackgroundTransparency = 1,
	Text = "Budget: $0",
	TextColor3 = COLOR_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_BOLD,
	TextSize = 22,
	Parent = hudPanel,
})

local fuelLabel = create("TextLabel", {
	Position = UDim2.fromOffset(14, 38),
	Size = UDim2.new(1, -28, 0, 22),
	BackgroundTransparency = 1,
	Text = "RP-1: 0 / 0 kg",
	TextColor3 = COLOR_TEXT_DIM,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR,
	TextSize = 18,
	Parent = hudPanel,
})

local fuelBarBack = create("Frame", {
	Position = UDim2.fromOffset(14, 66),
	Size = UDim2.new(1, -28, 0, 12),
	BackgroundColor3 = Color3.fromRGB(35, 45, 70),
	BorderSizePixel = 0,
	Parent = hudPanel,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fuelBarBack })
local fuelBarFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = COLOR_FUEL,
	BorderSizePixel = 0,
	Parent = fuelBarBack,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fuelBarFill })

-- Message at the top centre
local toast = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 16),
	Size = UDim2.fromOffset(460, 44),
	AutomaticSize = Enum.AutomaticSize.Y, -- several lines (a list of errors) — the message grows downwards
	BackgroundColor3 = COLOR_PANEL,
	Text = "",
	TextColor3 = COLOR_TEXT,
	TextWrapped = true,
	Font = FONT_BOLD,
	TextSize = 20,
	Visible = false,
	Parent = hud,
})
create("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	Parent = toast,
})
addStyle(toast, 10, COLOR_BORDER, 2)
local toastStroke = toast:FindFirstChildOfClass("UIStroke")
local toastId = 0

local function showToast(text, isError)
	toastId += 1
	local myId = toastId
	toast.Text = text
	toastStroke.Color = isError and COLOR_ERROR or COLOR_BORDER
	toast.TextColor3 = isError and Color3.fromRGB(255, 200, 195) or COLOR_TEXT
	toast.Visible = true
	-- 3 s + another 1.5 s for each extra line, so there is time to read it
	local _, lineBreaks = text:gsub("\n", "")
	-- a list is left-aligned, a single sentence is centred
	toast.TextXAlignment = lineBreaks > 0 and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
	task.delay(3 + 1.5 * lineBreaks, function()
		if toastId == myId then
			toast.Visible = false
		end
	end)
end

notifyEvent.OnClientEvent:Connect(showToast)

--------------------------------------------------------------------
-- Oil derrick window
--------------------------------------------------------------------
local rigPanel = create("Frame", {
	Name = "OilRigPanel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.92, 0, 0, 470),
	BackgroundColor3 = COLOR_PANEL,
	Visible = false,
	Parent = hud,
})
create("UISizeConstraint", { MaxSize = Vector2.new(520, 470), Parent = rigPanel })
addStyle(rigPanel, 16, COLOR_BORDER, 3)

create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 54),
	BackgroundTransparency = 1,
	Text = "Oil derrick & RP-1 refinery",
	TextColor3 = COLOR_TEXT,
	Font = FONT_BOLD,
	TextSize = 26,
	Parent = rigPanel,
})

local rows = create("Frame", {
	Position = UDim2.fromOffset(24, 56),
	Size = UDim2.new(1, -48, 0, 170),
	BackgroundTransparency = 1,
	Parent = rigPanel,
})
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rows })

local function makeRow(order, labelText)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = rows,
	})
	create("TextLabel", {
		Size = UDim2.fromScale(0.55, 1),
		BackgroundTransparency = 1,
		Text = labelText,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR,
		TextSize = 19,
		Parent = row,
	})
	return create("TextLabel", {
		Position = UDim2.fromScale(0.55, 0),
		Size = UDim2.fromScale(0.45, 1),
		BackgroundTransparency = 1,
		Text = "-",
		TextColor3 = COLOR_TEXT,
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = FONT_BOLD,
		TextSize = 19,
		Parent = row,
	})
end

local levelValue = makeRow(1, "Derrick level")
local rateValue = makeRow(2, "RP-1 production")
local storedValue = makeRow(3, "In storage")
local timeValue = makeRow(4, "Until storage is full")
local budgetValue = makeRow(5, "Mission budget")

local nextLabel = create("TextLabel", {
	Position = UDim2.fromOffset(24, 232),
	Size = UDim2.new(1, -48, 0, 50),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = COLOR_FUEL,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_BOLD,
	TextSize = 18,
	Parent = rigPanel,
})

create("TextLabel", {
	Position = UDim2.fromOffset(24, 284),
	Size = UDim2.new(1, -48, 0, 92),
	BackgroundTransparency = 1,
	Text = "Why RP-1? Falcon 9 and Saturn V burn RP-1 — highly refined kerosene made from crude oil. "
		.. "For every 1 kg of RP-1 the engine also burns ~2.4 kg of liquid oxygen, so RP-1 is only ~30% of the propellant mass.",
	TextColor3 = COLOR_TEXT_DIM,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = FONT_REGULAR,
	TextSize = 16,
	Parent = rigPanel,
})

local buttonRow = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -18),
	Size = UDim2.new(1, -40, 0, 54),
	BackgroundTransparency = 1,
	Parent = rigPanel,
})
create("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 16),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = buttonRow,
})
local upgradeButton = makeButton("Upgrade", buttonRow)
upgradeButton.Size = UDim2.fromOffset(230, 50)
upgradeButton.LayoutOrder = 1
local closeButton = makeButton("Close", buttonRow)
closeButton.Size = UDim2.fromOffset(150, 50)
closeButton.LayoutOrder = 2

--------------------------------------------------------------------
-- Updating all the numbers
--------------------------------------------------------------------
local function getData()
	return {
		budget = player:GetAttribute("Budget") or 0,
		rp1 = player:GetAttribute("RP1") or 0,
		capacity = player:GetAttribute("RP1Capacity") or 1,
		rate = player:GetAttribute("RP1Rate") or 0,
		level = player:GetAttribute("OilRigLevel") or 1,
	}
end

local tankBillboardLabel -- created below

local function refresh()
	local d = getData()
	local fraction = math.clamp(d.rp1 / d.capacity, 0, 1)

	-- HUD
	budgetLabel.Text = "Budget: $" .. formatNumber(d.budget)
	fuelLabel.Text = "RP-1: " .. formatNumber(d.rp1) .. " / " .. formatNumber(d.capacity) .. " kg"
	tween(fuelBarFill, 0.3, { Size = UDim2.fromScale(fraction, 1) })

	-- Derrick window
	levelValue.Text = d.level .. " / " .. #NASAData.OilRig
	rateValue.Text = formatNumber(d.rate) .. " kg/s"
	storedValue.Text = formatNumber(d.rp1) .. " / " .. formatNumber(d.capacity) .. " kg"
	budgetValue.Text = "$" .. formatNumber(d.budget)

	-- Time to full = (capacity − stock) / rate
	if d.rp1 >= d.capacity then
		timeValue.Text = "Storage full"
	elseif d.rate > 0 then
		timeValue.Text = formatTime((d.capacity - d.rp1) / d.rate)
	else
		timeValue.Text = "-"
	end

	local nextCfg = NASAData.OilRig[d.level + 1]
	if nextCfg then
		nextLabel.Text = "Level " .. (d.level + 1) .. ": " .. formatNumber(nextCfg.productionRate) .. " kg/s, storage "
			.. formatNumber(nextCfg.storageCapacity) .. " kg"
		upgradeButton.Text = "Upgrade ($" .. formatNumber(nextCfg.upgradeCost) .. ")"
		setButtonEnabled(upgradeButton, d.budget >= nextCfg.upgradeCost)
	else
		nextLabel.Text = "Maximum level reached."
		upgradeButton.Text = "Maxed out"
		setButtonEnabled(upgradeButton, false)
	end

	if tankBillboardLabel then
		tankBillboardLabel.Text = "RP-1: " .. math.floor(fraction * 100) .. "%\n" .. formatNumber(d.rp1) .. " kg"
	end
end

player.AttributeChanged:Connect(refresh)

upgradeButton.MouseButton1Click:Connect(function()
	if upgradeButton.Active then
		upgradeEvent:FireServer()
	end
end)

closeButton.MouseButton1Click:Connect(function()
	rigPanel.Visible = false
end)

--------------------------------------------------------------------
-- World objects: console, storage tank, pumpjack
--------------------------------------------------------------------
local rig = workspace:WaitForChild("OilRig", 10)
if rig then
	-- E at the console opens/closes the window
	local panel = rig:FindFirstChild("ControlPanel")
	local prompt = panel and panel:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Triggered:Connect(function()
			rigPanel.Visible = not rigPanel.Visible
			refresh()
		end)
	end

	-- Close the window if the player walks far away from the console
	RunService.Heartbeat:Connect(function()
		if rigPanel.Visible and panel then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - panel.Position).Magnitude > 25 then
				rigPanel.Visible = false
			end
		end
	end)

	-- Label above the storage tank (only this player sees it)
	local tank = rig:FindFirstChild("StorageTank")
	if tank then
		local billboard = create("BillboardGui", {
			Name = "TankInfo",
			Adornee = tank,
			Size = UDim2.fromOffset(200, 64),
			StudsOffsetWorldSpace = Vector3.new(0, 10, 0),
			MaxDistance = 150,
			ResetOnSpawn = false,
			Parent = playerGui,
		})
		tankBillboardLabel = create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = COLOR_PANEL,
			BackgroundTransparency = 0.2,
			Text = "",
			TextColor3 = COLOR_FUEL,
			Font = FONT_BOLD,
			TextSize = 22,
			Parent = billboard,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = tankBillboardLabel })
	end

	-- The pumpjack rocks; the speed depends on the level; it stops when the storage is full
	local arm = rig:FindFirstChild("PumpArm")
	if arm then
		local basePivot = arm:GetPivot()
		local phase = 0
		RunService.RenderStepped:Connect(function(dt)
			local d = getData()
			if d.rp1 < d.capacity then
				phase += dt * (1 + d.level * 0.7)
			end
			arm:PivotTo(basePivot * CFrame.Angles(0, 0, math.sin(phase) * 0.25))
		end)
	end
else
	warn("[HUD] Workspace > OilRig not found. Run BuildWorld_Step2.")
end

--------------------------------------------------------------------
-- Showing the HUD after the main menu
--------------------------------------------------------------------
local function showHud()
	hud.Enabled = true
	refresh()
end

-- MainMenuClient sets the attribute InGame = true when the player gets into the hangar
local function checkInGame()
	if player:GetAttribute("InGame") == true then
		showHud()
	end
end

player:GetAttributeChangedSignal("InGame"):Connect(checkInGame)
checkInGame()

-- While the rocket builder is open the resource panel is hidden: the builder shows the budget and RP-1 itself,
-- and the panel covered its title (the BuilderOpen attribute is set by RocketBuilderClient)
player:GetAttributeChangedSignal("BuilderOpen"):Connect(function()
	hudPanel.Visible = player:GetAttribute("BuilderOpen") ~= true
end)

refresh()
