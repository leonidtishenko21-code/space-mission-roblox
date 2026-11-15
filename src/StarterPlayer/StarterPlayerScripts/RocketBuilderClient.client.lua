--[[
	RocketBuilderClient (LocalScript)
	Місце: StarterPlayer > StarterPlayerScripts > RocketBuilderClient

	Конструктор ракети (крок 3). Відкривається клавішею E біля пульта
	"Конструктор ракети" в ангарі (Workspace > Hangar > BuilderConsole).
	  • Ліворуч  — каталог деталей (з NASAData.Modules) за категоріями.
	  • Посередині — креслення ракети і список деталей (згори вниз).
	  • Праворуч — інженерні розрахунки (маса, тяга, TWR, Δv...) і перевірки.
	Кнопка "Зібрати" просить сервер купити деталі й поставити ракету на майданчик.
	Сервер перевіряє все ще раз (RocketMath), тому підробити ракету не можна.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local modulesFolder = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modulesFolder:WaitForChild("NASAData"))
local RocketMath = require(modulesFolder:WaitForChild("RocketMath"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buildEvent = remotes:WaitForChild("BuildRocket")
local fuelEvent = remotes:WaitForChild("FuelRocket")
local dismantleEvent = remotes:WaitForChild("DismantleRocket")

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local FONT_BOLD = Enum.Font.GothamBold
local FONT_REGULAR = Enum.Font.Gotham

local COLOR_BUTTON = Color3.fromRGB(76, 153, 76)
local COLOR_BUTTON_HOVER = Color3.fromRGB(98, 180, 98)
local COLOR_BORDER = Color3.fromRGB(40, 80, 40)
local COLOR_DISABLED = Color3.fromRGB(90, 95, 100)
local COLOR_PANEL = Color3.fromRGB(18, 26, 50)
local COLOR_COLUMN = Color3.fromRGB(26, 36, 66)
local COLOR_ITEM = Color3.fromRGB(36, 50, 88)
local COLOR_ITEM_HOVER = Color3.fromRGB(50, 68, 115)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(180, 195, 220)
local COLOR_FUEL = Color3.fromRGB(230, 170, 50)
local COLOR_OK = Color3.fromRGB(110, 210, 110)
local COLOR_WARN = Color3.fromRGB(240, 190, 40)
local COLOR_ERROR = Color3.fromRGB(230, 90, 80)

local CLOSE_DISTANCE = 25 -- вікно закривається, якщо відійти від пульта далі

local TABS = {
	{ name = "Engines", cats = { engine = true } },
	{ name = "Tanks", cats = { tank = true } },
	{ name = "Capsules", cats = { command = true } },
	{ name = "Structure", cats = { structure = true } },
	{ name = "Protection", cats = { protection = true } },
	{ name = "Landing", cats = { landing = true } },
	{ name = "Power", cats = { power = true, life = true } },
	{ name = "Comms", cats = { comms = true } },
	{ name = "Science", cats = { science = true } },
}

local fmt = RocketMath.FormatNumber
local Modules = NASAData.Modules

--------------------------------------------------------------------
-- Допоміжні функції
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

local function addStyle(obj, radius, strokeColor, thickness)
	create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = obj })
	if strokeColor then
		create("UIStroke", {
			Color = strokeColor,
			Thickness = thickness,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = obj,
		})
	end
end

local function makeButton(text, parent)
	local button = create("TextButton", {
		Size = UDim2.fromOffset(200, 46),
		BackgroundColor3 = COLOR_BUTTON,
		Text = text,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 19,
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
	button.BackgroundColor3 = enabled and COLOR_BUTTON or COLOR_DISABLED
end

local function clearChildren(frame)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- для RichText: колір і екранування символів < > &
local function hex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function esc(s)
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	return s
end
local function colored(text, color)
	return '<font color="' .. hex(color) .. '">' .. esc(text) .. "</font>"
end

local function kN(newtons)
	local v = newtons / 1000
	if v < 10 then
		return string.format("%.1f kN", v)
	end
	return fmt(v) .. " kN"
end

local function copyDesign(d)
	return { stack = table.clone(d.stack), radial = table.clone(d.radial), engineCount = d.engineCount }
end

-- Короткий опис деталі в каталозі
local function moduleInfo(m)
	local parts = { "$" .. fmt(m.cost), fmt(m.dryMass) .. " kg" }
	if m.fuelCapacity then
		table.insert(parts, "fuel " .. fmt(m.fuelCapacity) .. " kg")
	end
	if m.thrustSL then
		table.insert(parts, "thrust " .. kN(m.thrustSL) .. ", Isp " .. m.ispSL .. " s")
	end
	if m.crew then
		table.insert(parts, "crew " .. m.crew)
	end
	if m.power and m.power ~= 0 then
		table.insert(parts, (m.power > 0 and "+" or "") .. m.power .. " W")
	end
	if m.maxRangeKm then
		table.insert(parts, "up to " .. fmt(m.maxRangeKm) .. " km")
	end
	table.insert(parts, m.attach == "radial" and "side" or "axial")
	return table.concat(parts, " · ")
end

--------------------------------------------------------------------
-- Стан
--------------------------------------------------------------------
local draft = RocketMath.EmptyDesign() -- креслення, яке гравець редагує
local builtDesign = nil                 -- креслення ракети, що вже стоїть на майданчику
local hintText = nil                    -- коротка підказка після невдалої дії
local designDirty = true                -- треба перемалювати список і креслення
local lastMode = nil
local lastStats = nil
local lastDesign = nil

local function isBuilt()
	return player:GetAttribute("RocketBuilt") == true
end

local function decodeBuiltDesign()
	local json = player:GetAttribute("RocketDesign")
	if type(json) ~= "string" then
		return nil
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	return ok and RocketMath.Sanitize(data) or nil
end

--------------------------------------------------------------------
-- ВІКНО
--------------------------------------------------------------------
local gui = create("ScreenGui", {
	Name = "RocketBuilder",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = false,
	DisplayOrder = 4, -- під HUD (5), щоб повідомлення сервера було видно поверх вікна
	Parent = playerGui,
})

local panel = create("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.54),
	Size = UDim2.fromScale(0.96, 0.84),
	BackgroundColor3 = COLOR_PANEL,
	Parent = gui,
})
create("UISizeConstraint", { MaxSize = Vector2.new(1120, 660), Parent = panel })
addStyle(panel, 16, COLOR_BORDER, 3)

local title = create("TextLabel", {
	Position = UDim2.fromOffset(20, 0),
	Size = UDim2.new(1, -80, 0, 50),
	BackgroundTransparency = 1,
	Text = "Rocket Builder",
	TextColor3 = COLOR_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_BOLD,
	TextSize = 24,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = panel,
})

local closeX = create("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -10, 0, 8),
	Size = UDim2.fromOffset(36, 36),
	BackgroundColor3 = COLOR_ITEM,
	Text = "X",
	TextColor3 = COLOR_TEXT,
	Font = FONT_BOLD,
	TextSize = 20,
	Parent = panel,
})
addStyle(closeX, 8)

local body = create("Frame", {
	Position = UDim2.fromOffset(12, 54),
	Size = UDim2.new(1, -24, 1, -66),
	BackgroundTransparency = 1,
	Parent = panel,
})

local function column(xScale, xOffset, wScale, wOffset)
	local f = create("Frame", {
		Position = UDim2.new(xScale, xOffset, 0, 0),
		Size = UDim2.new(wScale, wOffset, 1, 0),
		BackgroundColor3 = COLOR_COLUMN,
		Parent = body,
	})
	addStyle(f, 12)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		Parent = f,
	})
	return f
end

local catalogCol = column(0, 0, 0.33, -6)
local designCol = column(0.33, 2, 0.29, -6)
local statsCol = column(0.62, 2, 0.38, -2)

--------------------------------------------------------------------
-- Ліва колонка: каталог
--------------------------------------------------------------------
local tabsFrame = create("Frame", {
	Size = UDim2.new(1, 0, 0, 108),
	BackgroundTransparency = 1,
	Parent = catalogCol,
})
create("UIGridLayout", {
	CellSize = UDim2.new(1 / 3, -4, 0, 32),
	CellPadding = UDim2.fromOffset(4, 4),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = tabsFrame,
})

local catalogList = create("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 114),
	Size = UDim2.new(1, 0, 1, -114),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	Parent = catalogCol,
})
create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = catalogList })

local catalogLock = create("TextLabel", {
	Position = UDim2.fromOffset(0, 114),
	Size = UDim2.new(1, 0, 1, -114),
	BackgroundColor3 = COLOR_PANEL,
	BackgroundTransparency = 0.15,
	Text = "Rocket built.\nTo change it, press Disassemble.",
	TextColor3 = COLOR_TEXT,
	TextWrapped = true,
	Font = FONT_BOLD,
	TextSize = 18,
	ZIndex = 10,
	Visible = false,
	Parent = catalogCol,
})
addStyle(catalogLock, 8)

--------------------------------------------------------------------
-- Середня колонка: креслення + список деталей
--------------------------------------------------------------------
create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundTransparency = 1,
	Text = "Your rocket",
	TextColor3 = COLOR_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_BOLD,
	TextSize = 18,
	Parent = designCol,
})

local preview = create("Frame", {
	Position = UDim2.fromOffset(0, 30),
	Size = UDim2.new(0.4, -4, 1, -30),
	BackgroundColor3 = Color3.fromRGB(10, 14, 30),
	ClipsDescendants = true,
	Parent = designCol,
})
addStyle(preview, 8)

local designList = create("ScrollingFrame", {
	Position = UDim2.new(0.4, 4, 0, 30),
	Size = UDim2.new(0.6, -4, 1, -30),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	Parent = designCol,
})
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = designList })

--------------------------------------------------------------------
-- Права колонка: розрахунки, перевірки, кнопки
--------------------------------------------------------------------
local rows = create("Frame", {
	Size = UDim2.new(1, 0, 0, 12 * 24),
	BackgroundTransparency = 1,
	Parent = statsCol,
})
create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = rows })

local statRows = {} -- для адаптивної висоти (див. layoutStats)

local function makeRow(order, labelText)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = rows,
	})
	local label = create("TextLabel", {
		Size = UDim2.fromScale(0.5, 1),
		BackgroundTransparency = 1,
		Text = labelText,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR,
		TextSize = 15,
		Parent = row,
	})
	local value = create("TextLabel", {
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.5, 1),
		BackgroundTransparency = 1,
		Text = "-",
		TextColor3 = COLOR_TEXT,
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = FONT_BOLD,
		TextSize = 15,
		Parent = row,
	})
	table.insert(statRows, { frame = row, label = label, value = value })
	return value
end

local costValue = makeRow(1, "Cost")
local budgetValue = makeRow(2, "Budget")
local dryValue = makeRow(3, "Dry mass")
local fuelCapValue = makeRow(4, "Propellant (RP-1 + LOX)")
local wetValue = makeRow(5, "Liftoff mass")
local thrustValue = makeRow(6, "Sea-level thrust")
local twrValue = makeRow(7, "TWR = F / (m·g)")
local dvValue = makeRow(8, "Δv = Isp·g0·ln(m0/m1)")
local burnValue = makeRow(9, "Engine burn time")
local rp1Value = makeRow(10, "RP-1 to fuel")
local powerValue = makeRow(11, "Power balance")
local comValue = makeRow(12, "Center of mass offset")
local structureValue = makeRow(13, "Structure / aerodynamics")
structureValue.TextTruncate = Enum.TextTruncate.AtEnd

local messagesFrame = create("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 12 * 24 + 6),
	Size = UDim2.new(1, 0, 1, -(12 * 24 + 6) - 100),
	BackgroundColor3 = Color3.fromRGB(14, 20, 40),
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	Parent = statsCol,
})
addStyle(messagesFrame, 8)
create("UIPadding", {
	PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 10),
	Parent = messagesFrame,
})
local messagesLabel = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "",
	RichText = true,
	TextColor3 = COLOR_TEXT_DIM,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = FONT_REGULAR,
	TextSize = 15,
	Parent = messagesFrame,
})

-- Адаптивна висота: на невеликому екрані рядки розрахунків стискаються, щоб вікно повідомлень
-- завжди мало щонайменше MIN_MESSAGES px і текст не налазив на рядки (знизу 100 px — кнопки).
local MIN_MESSAGES = 70
local function layoutStats()
	local h = statsCol.AbsoluteSize.Y
	if h <= 0 then
		return
	end
	local rowH = math.clamp(math.floor((h - 100 - 6 - MIN_MESSAGES) / #statRows), 16, 24)
	local textSize = (rowH >= 22 and 15) or (rowH >= 19 and 14) or 12
	for _, r in ipairs(statRows) do
		r.frame.Size = UDim2.new(1, 0, 0, rowH)
		r.label.TextSize = textSize
		r.value.TextSize = textSize
	end
	local top = rowH * #statRows + 6
	rows.Size = UDim2.new(1, 0, 0, rowH * #statRows)
	messagesFrame.Position = UDim2.fromOffset(0, top)
	messagesFrame.Size = UDim2.new(1, 0, 1, -top - 100)
end
statsCol:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutStats)
layoutStats()

-- Смужка пального (видно, коли ракету зібрано)
local fuelBox = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, -54),
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = statsCol,
})
local fuelText = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = COLOR_FUEL,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_BOLD,
	TextSize = 15,
	Parent = fuelBox,
})
local fuelBarBack = create("Frame", {
	Position = UDim2.fromOffset(0, 24),
	Size = UDim2.new(1, 0, 0, 12),
	BackgroundColor3 = Color3.fromRGB(35, 45, 70),
	BorderSizePixel = 0,
	Parent = fuelBox,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fuelBarBack })
local fuelBarFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = COLOR_FUEL,
	BorderSizePixel = 0,
	Parent = fuelBarBack,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fuelBarFill })

local buttonRow = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 48),
	BackgroundTransparency = 1,
	Parent = statsCol,
})
create("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = buttonRow,
})
local leftButton = makeButton("Clear", buttonRow)
leftButton.Size = UDim2.new(0.4, -5, 0, 46)
leftButton.LayoutOrder = 1
local rightButton = makeButton("Build", buttonRow)
rightButton.Size = UDim2.new(0.6, -5, 0, 46)
rightButton.LayoutOrder = 2

--------------------------------------------------------------------
-- Редагування креслення
--------------------------------------------------------------------
local refresh -- оголошено нижче
local updateCatalogCompat -- оголошено нижче (червона рамка «НЕСУМІСНИЙ ДІАМЕТР»)

local function changed(hint)
	hintText = hint
	designDirty = true
	refresh()
	if updateCatalogCompat then
		updateCatalogCompat()
	end
end

local function addModule(id)
	if isBuilt() then
		return
	end
	local m = Modules[id]
	local stack = draft.stack

	if m.attach == "radial" then
		if #draft.radial >= RocketMath.MAX_RADIAL then
			changed("There are already " .. RocketMath.MAX_RADIAL .. " side parts — no more room.")
			return
		end
		table.insert(draft.radial, id)
	elseif RocketMath.IsMainEngine(id) then
		local top = #stack
		if RocketMath.IsTopCap(stack[top]) then
			top -= 1
		end
		if top >= 2 and stack[top] == "decoupler" then
			-- нагорі декуплер → це двигун наступного ступеня
			if #stack >= RocketMath.MAX_STACK then
				changed("There are already " .. RocketMath.MAX_STACK .. " parts on the main axis.")
				return
			end
			table.insert(stack, top + 1, id)
		elseif stack[1] == id then
			-- такий самий двигун → ще один у кластер
			if draft.engineCount >= RocketMath.MAX_ENGINES then
				changed("Maximum " .. RocketMath.MAX_ENGINES .. " engines per cluster.")
				return
			end
			draft.engineCount += 1
		elseif RocketMath.IsMainEngine(stack[1]) then
			stack[1] = id -- інший двигун → заміняємо
			draft.engineCount = 1
		else
			if #stack >= RocketMath.MAX_STACK then
				changed("There are already " .. RocketMath.MAX_STACK .. " parts on the main axis.")
				return
			end
			table.insert(stack, 1, id) -- двигун завжди вниз
			draft.engineCount = 1
		end
	else
		if #stack >= RocketMath.MAX_STACK then
			changed("There are already " .. RocketMath.MAX_STACK .. " parts on the main axis.")
			return
		end
		-- нова деталь стає нагору, але під носовий обтічник
		if not RocketMath.IsTopCap(id) and RocketMath.IsTopCap(stack[#stack]) then
			table.insert(stack, #stack, id)
		else
			table.insert(stack, id)
		end
	end
	changed(nil)
end

local function moveStack(index, delta)
	local stack = draft.stack
	local target = index + delta
	if target < 1 or target > #stack then
		return
	end
	stack[index], stack[target] = stack[target], stack[index]
	changed(nil)
end

local function removeStack(index)
	table.remove(draft.stack, index)
	if not RocketMath.IsMainEngine(draft.stack[1]) then
		draft.engineCount = 1
	end
	changed(nil)
end

local function removeRadial(index)
	table.remove(draft.radial, index)
	changed(nil)
end

local function setEngineCount(n)
	draft.engineCount = math.clamp(n, 1, RocketMath.MAX_ENGINES)
	changed(nil)
end

--------------------------------------------------------------------
-- Каталог
--------------------------------------------------------------------
local currentTab = 1
local tabButtons = {}

-- Сумісність діаметрів: чи стане креслення гіршим, якщо поставити цю деталь нагору (як робить addModule)
local catalogItems = {}
local function breaksDiameter(id)
	local m = Modules[id]
	if isBuilt() or m.attach ~= "stack" or RocketMath.IsMainEngine(id) then
		return false
	end
	local d = copyDesign(draft)
	local stack = d.stack
	if not RocketMath.IsTopCap(id) and RocketMath.IsTopCap(stack[#stack]) then
		table.insert(stack, #stack, id)
	else
		table.insert(stack, id)
	end
	return #RocketMath.DiameterCheck(d) > #RocketMath.DiameterCheck(draft)
end

updateCatalogCompat = function()
	for _, it in ipairs(catalogItems) do
		local bad = breaksDiameter(it.id)
		it.warn.Visible = bad
		it.stroke.Enabled = bad
	end
end

local function rebuildCatalog()
	clearChildren(catalogList)
	catalogItems = {}
	local missionId = player:GetAttribute("Mission") or "Earth"
	local planet = NASAData.Planets[missionId]
	local required = {}
	if planet then
		for _, id in ipairs(planet.requiredEquipment) do
			required[id] = true
		end
	end

	local items = {}
	for id, m in pairs(Modules) do
		if TABS[currentTab].cats[m.category] then
			table.insert(items, { id = id, m = m })
		end
	end
	table.sort(items, function(a, b)
		if a.m.cost ~= b.m.cost then
			return a.m.cost < b.m.cost
		end
		return a.id < b.id
	end)

	for i, item in ipairs(items) do
		local btn = create("TextButton", {
			Size = UDim2.new(1, -8, 0, 64),
			BackgroundColor3 = COLOR_ITEM,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = catalogList,
		})
		addStyle(btn, 8, required[item.id] and COLOR_WARN or nil, 2)
		create("Frame", {
			Position = UDim2.fromOffset(8, 10),
			Size = UDim2.fromOffset(6, 44),
			BackgroundColor3 = RocketMath.ColorFor(item.id),
			BorderSizePixel = 0,
			Parent = btn,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(22, 5),
			Size = UDim2.new(1, -60, 0, 22),
			BackgroundTransparency = 1,
			Text = (required[item.id] and "★ " or "") .. item.m.name,
			TextColor3 = COLOR_TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Font = FONT_BOLD,
			TextSize = 15,
			Parent = btn,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(22, 27),
			Size = UDim2.new(1, -60, 0, 34),
			BackgroundTransparency = 1,
			Text = moduleInfo(item.m),
			TextColor3 = COLOR_TEXT_DIM,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Font = FONT_REGULAR,
			TextSize = 13,
			Parent = btn,
		})
		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			BackgroundTransparency = 1,
			Text = "+",
			TextColor3 = COLOR_OK,
			Font = FONT_BOLD,
			TextSize = 28,
			Parent = btn,
		})
		btn.MouseEnter:Connect(function()
			btn.BackgroundColor3 = COLOR_ITEM_HOVER
		end)
		btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = COLOR_ITEM
		end)
		btn.Activated:Connect(function()
			addModule(item.id)
		end)
		-- червона рамка: деталь ширша за верхній модуль на кресленні
		local stroke = create("UIStroke", {
			Name = "CompatStroke", Color = COLOR_ERROR, Thickness = 2.5, Enabled = false, Parent = btn,
		})
		local warn = create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -36, 0, 3),
			Size = UDim2.fromOffset(150, 14),
			BackgroundTransparency = 1,
			Text = "DIAMETER MISMATCH",
			TextColor3 = COLOR_ERROR,
			TextXAlignment = Enum.TextXAlignment.Right,
			Font = FONT_BOLD,
			TextSize = 11,
			Visible = false,
			ZIndex = 3,
			Parent = btn,
		})
		table.insert(catalogItems, { id = item.id, stroke = stroke, warn = warn })
	end
	updateCatalogCompat()

	for k, tb in ipairs(tabButtons) do
		tb.BackgroundColor3 = (k == currentTab) and COLOR_BUTTON or COLOR_ITEM
	end
end

for k, tab in ipairs(TABS) do
	local tb = create("TextButton", {
		BackgroundColor3 = COLOR_ITEM,
		Text = tab.name,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextScaled = true,
		LayoutOrder = k,
		Parent = tabsFrame,
	})
	create("UITextSizeConstraint", { MaxTextSize = 14, Parent = tb })
	create("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = tb })
	addStyle(tb, 6)
	tb.Activated:Connect(function()
		currentTab = k
		rebuildCatalog()
	end)
	tabButtons[k] = tb
end

--------------------------------------------------------------------
-- Список деталей у ракеті
--------------------------------------------------------------------
local function addSection(order, text)
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 22),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_BOLD,
		TextSize = 14,
		LayoutOrder = order,
		Parent = designList,
	})
end

-- buttons = { { "текст", колір, функція }, ... }
local function addDesignRow(order, moduleId, text, buttons)
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLOR_ITEM,
		LayoutOrder = order,
		Parent = designList,
	})
	addStyle(row, 6)
	create("Frame", {
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(0, 4, 1, -8),
		BackgroundColor3 = RocketMath.ColorFor(moduleId),
		BorderSizePixel = 0,
		Parent = row,
	})
	-- назва (може переноситися на 2 рядки) і під нею кнопки
	local content = create("Frame", {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = row,
	})
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = content })
	create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = content })
	create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = COLOR_TEXT,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR,
		TextSize = 14,
		LayoutOrder = 1,
		Parent = content,
	})

	if #buttons > 0 then
		local holder = create("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			Parent = content,
		})
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = holder,
		})
		for i, b in ipairs(buttons) do
			local btn = create("TextButton", {
				Size = UDim2.fromOffset(30, 24),
				BackgroundColor3 = b[2] or COLOR_ITEM_HOVER,
				Text = b[1],
				TextColor3 = COLOR_TEXT,
				Font = FONT_BOLD,
				TextSize = 16,
				LayoutOrder = i,
				Parent = holder,
			})
			addStyle(btn, 6)
			btn.Activated:Connect(b[3])
		end
	end
end

local function rebuildDesignList(design, built)
	clearChildren(designList)
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	addSection(nextOrder(), "Main axis (top to bottom):")
	if #design.stack == 0 then
		addSection(nextOrder(), "  empty — add an engine")
	end
	for i = #design.stack, 1, -1 do
		local id = design.stack[i]
		local isEngine = i == 1 and RocketMath.IsMainEngine(id)
		local text = Modules[id].name
		local buttons = {}
		if isEngine then
			text = text .. "  ×" .. design.engineCount
		end
		if not built then
			if isEngine then
				table.insert(buttons, { "-", nil, function() setEngineCount(draft.engineCount - 1) end })
				table.insert(buttons, { "+", nil, function() setEngineCount(draft.engineCount + 1) end })
			else
				if i < #design.stack then
					table.insert(buttons, { "↑", nil, function() moveStack(i, 1) end })
				end
				local belowIsEngine = i - 1 == 1 and RocketMath.IsMainEngine(design.stack[1])
				if i > 1 and not belowIsEngine then
					table.insert(buttons, { "↓", nil, function() moveStack(i, -1) end })
				end
			end
			table.insert(buttons, { "X", COLOR_ERROR, function() removeStack(i) end })
		end
		addDesignRow(nextOrder(), id, text, buttons)
	end

	addSection(nextOrder(), "Side:")
	if #design.radial == 0 then
		addSection(nextOrder(), "  none")
	end
	for i, id in ipairs(design.radial) do
		local buttons = {}
		if not built then
			table.insert(buttons, { "X", COLOR_ERROR, function() removeRadial(i) end })
		end
		addDesignRow(nextOrder(), id, Modules[id].name, buttons)
	end
end

--------------------------------------------------------------------
-- Креслення (вид збоку)
--------------------------------------------------------------------
local function drawPreview(design, stats)
	clearChildren(preview)
	local size = preview.AbsoluteSize
	if size.X < 20 or size.Y < 40 then
		return
	end
	if #design.stack == 0 and #design.radial == 0 then
		create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "Your blueprint will appear here",
			TextColor3 = COLOR_TEXT_DIM,
			TextWrapped = true,
			Font = FONT_REGULAR,
			TextSize = 14,
			Parent = preview,
		})
		return
	end

	local layout = stats.layout
	local width = layout.maxDiameter + 4
	local height = math.max(layout.height, 2)
	local scale = math.min((size.X - 12) / width, (size.Y - 40) / height, 30)
	local groundY = size.Y - 12
	local cx = size.X / 2

	local function rect(x, yBottom, w, h, color, z)
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromOffset(cx + x * scale, groundY - yBottom * scale),
			Size = UDim2.fromOffset(math.max(w * scale, 1), math.max(h * scale, 1)),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = z or 2,
			Parent = preview,
		})
	end

	create("Frame", {
		Position = UDim2.fromOffset(0, groundY),
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = COLOR_TEXT_DIM,
		BorderSizePixel = 0,
		Parent = preview,
	})

	local e = layout.engines
	if e then
		local color = RocketMath.ColorFor(e.id)
		for _, off in ipairs(e.offsets) do
			rect(off.X, 0, e.bellDiameter, e.bellHeight * 0.5, color, 3)
			rect(off.X, e.bellHeight * 0.5, e.bellDiameter * 0.6, e.bellHeight * 0.5, color, 3)
		end
		rect(0, e.mountY, e.mountDiameter, RocketMath.ENGINE_MOUNT_HEIGHT, Color3.fromRGB(45, 48, 55), 2)
	end

	for _, p in ipairs(layout.pieces) do
		local color = RocketMath.ColorFor(p.id)
		if math.abs(p.d0 - p.d1) < 0.01 then
			rect(0, p.y0, p.d0, p.h, color, 2)
		else
			for k = 1, 4 do
				local t = (k - 0.5) / 4
				rect(0, p.y0 + (k - 1) * p.h / 4, p.d0 + (p.d1 - p.d0) * t, p.h / 4, color, 2)
			end
		end
		if Modules[p.id].category == "tank" then
			rect(0, p.y0 + p.h / 2 - 0.2, p.d0, 0.4, Color3.fromRGB(30, 30, 35), 3)
		end
	end

	-- бічні деталі: проєкція на вид спереду (ті, що "ззаду", малюємо під корпусом)
	for _, r in ipairs(layout.radial) do
		local x = math.cos(r.angle) * (r.radius + 0.4)
		local behind = math.sin(r.angle) > 0.3
		rect(x, r.y - 0.4, 0.8, 0.8, RocketMath.ColorFor(r.id), behind and 1 or 4)
	end

	create("TextLabel", {
		Position = UDim2.fromOffset(6, 4),
		Size = UDim2.new(1, -12, 0, 18),
		BackgroundTransparency = 1,
		Text = string.format("Height: %.1f m", stats.heightM),
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR,
		TextSize = 13,
		ZIndex = 5,
		Parent = preview,
	})
end

preview:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if lastDesign and lastStats then
		drawPreview(lastDesign, lastStats)
	end
end)

--------------------------------------------------------------------
-- Оновлення всього вікна
--------------------------------------------------------------------
refresh = function()
	local built = isBuilt()
	local design = built and (builtDesign or RocketMath.EmptyDesign()) or draft
	local budget = player:GetAttribute("Budget") or 0
	local rp1 = player:GetAttribute("RP1") or 0
	local missionId = player:GetAttribute("Mission") or "Earth"
	local planet = NASAData.Planets[missionId]

	-- коли ракета вже куплена, гроші не перевіряємо
	local errors, warnings, s = RocketMath.Validate(design, built and math.huge or budget, missionId)

	title.Text = "Rocket Builder — mission: " .. (planet and planet.name or missionId)

	-- Числа
	costValue.Text = "$" .. fmt(s.cost)
	costValue.TextColor3 = (built or s.cost <= budget) and COLOR_TEXT or COLOR_ERROR
	budgetValue.Text = "$" .. fmt(budget)
	dryValue.Text = fmt(s.dryMass) .. " kg"
	fuelCapValue.Text = fmt(s.fuel) .. " kg"
	wetValue.Text = fmt(s.wetMass) .. " kg"
	thrustValue.Text = s.thrustSL > 0 and kN(s.thrustSL) or "-"

	if s.thrustSL > 0 and s.wetMass > 0 then
		twrValue.Text = string.format("%.2f", s.twr)
		twrValue.TextColor3 = (s.twr < RocketMath.MIN_TWR and COLOR_ERROR)
			or (s.twr < RocketMath.GOOD_TWR and COLOR_WARN) or COLOR_OK
	else
		twrValue.Text = "-"
		twrValue.TextColor3 = COLOR_TEXT
	end
	dvValue.Text = s.deltaV > 0 and (fmt(s.deltaV) .. " m/s") or "-"
	burnValue.Text = s.burnTime > 0 and string.format("%.0f s", s.burnTime) or "-"
	rp1Value.Text = fmt(s.rp1Needed) .. " kg (have " .. fmt(rp1) .. ")"
	rp1Value.TextColor3 = rp1 >= s.rp1Needed and COLOR_TEXT or COLOR_WARN
	powerValue.Text = (s.power > 0 and "+" or "") .. fmt(s.power) .. " W"
	comValue.Text = string.format("%.1f cm", s.comOffsetCm)
	comValue.TextColor3 = s.comOffsetCm > RocketMath.MAX_COM_OFFSET_CM and COLOR_WARN or COLOR_TEXT
	local dp = s.diameterProblems or {}
	if #design.stack == 0 then
		structureValue.Text = "-"
		structureValue.TextColor3 = COLOR_TEXT
	elseif #dp == 0 then
		structureValue.Text = "OK (joints are sealed)"
		structureValue.TextColor3 = COLOR_OK
	else
		structureValue.Text = "ERROR: the upper module is wider!"
		structureValue.TextColor3 = COLOR_ERROR
	end

	-- Повідомлення
	local lines = {}
	if planet then
		table.insert(lines, colored("Mission: " .. planet.mission, COLOR_TEXT))
		table.insert(lines, "")
		table.insert(lines, colored("Required equipment:", COLOR_TEXT))
		for _, item in ipairs(RocketMath.MissionChecklist(design, missionId)) do
			if item.ok then
				table.insert(lines, colored("  [✓] " .. item.name, COLOR_OK))
			else
				table.insert(lines, colored("  [  ] " .. item.name, COLOR_TEXT_DIM))
			end
		end
		table.insert(lines, "")
	end

	if built then
		local fuel = player:GetAttribute("RocketFuel") or 0
		local capacity = player:GetAttribute("RocketFuelCapacity") or 0
		if fuel < capacity then
			table.insert(lines, colored("The rocket is on the pad. Fuel it: RP-1 comes from the derrick storage, "
				.. "and oxygen (LOX) is taken from the air for free.", COLOR_FUEL))
		else
			table.insert(lines, colored("The rocket is fueled and ready. Head to the launch pad!", COLOR_OK))
		end
	else
		if hintText then
			table.insert(lines, colored("• " .. hintText, COLOR_WARN))
		end
		for _, text in ipairs(errors) do
			table.insert(lines, colored("• " .. text, COLOR_ERROR))
		end
		for _, text in ipairs(warnings) do
			table.insert(lines, colored("• " .. text, COLOR_WARN))
		end
		if #errors == 0 then
			table.insert(lines, colored("All good — ready to build!", COLOR_OK))
		end
	end
	messagesLabel.Text = table.concat(lines, "\n")

	-- Пальне в зібраній ракеті
	fuelBox.Visible = built
	if built then
		local fuel = player:GetAttribute("RocketFuel") or 0
		local capacity = math.max(player:GetAttribute("RocketFuelCapacity") or 1, 1)
		fuelText.Text = "Fuel in tanks: " .. fmt(fuel) .. " / " .. fmt(capacity) .. " kg"
		tween(fuelBarFill, 0.3, { Size = UDim2.fromScale(math.clamp(fuel / capacity, 0, 1), 1) })
	end

	-- Кнопки
	if built then
		local fuel = player:GetAttribute("RocketFuel") or 0
		local capacity = player:GetAttribute("RocketFuelCapacity") or 0
		leftButton.Text = "Disassemble"
		setButtonEnabled(leftButton, true)
		if fuel >= capacity then
			rightButton.Text = "Tanks full"
			setButtonEnabled(rightButton, false)
		else
			rightButton.Text = "Refuel"
			setButtonEnabled(rightButton, rp1 >= 1)
		end
	else
		leftButton.Text = "Clear"
		setButtonEnabled(leftButton, #draft.stack + #draft.radial > 0)
		rightButton.Text = "Build ($" .. fmt(s.cost) .. ")"
		setButtonEnabled(rightButton, #errors == 0)
	end
	catalogLock.Visible = built

	-- Список і креслення перемальовуємо лише після змін
	local mode = built and "built" or "edit"
	if designDirty or mode ~= lastMode then
		designDirty = false
		lastMode = mode
		rebuildDesignList(design, built)
		lastDesign, lastStats = design, s
		drawPreview(design, s)
	end
end

leftButton.Activated:Connect(function()
	if not leftButton.Active then
		return
	end
	if isBuilt() then
		dismantleEvent:FireServer()
	else
		draft = RocketMath.EmptyDesign()
		changed(nil)
	end
end)

rightButton.Activated:Connect(function()
	if not rightButton.Active then
		return
	end
	if isBuilt() then
		fuelEvent:FireServer()
	else
		buildEvent:FireServer(copyDesign(draft))
	end
end)

--------------------------------------------------------------------
-- Зміни від сервера
--------------------------------------------------------------------
local function syncBuilt()
	if isBuilt() then
		builtDesign = decodeBuiltDesign()
	elseif builtDesign then
		-- ракету розібрали: її креслення повертається в редактор
		draft = copyDesign(builtDesign)
		builtDesign = nil
	end
	designDirty = true
end

player.AttributeChanged:Connect(function(name)
	if name == "RocketBuilt" or name == "RocketDesign" then
		syncBuilt()
	elseif name == "Mission" then
		rebuildCatalog()
	end
	if gui.Enabled then
		refresh()
		updateCatalogCompat()
	end
end)

--------------------------------------------------------------------
-- Відкриття біля пульта
--------------------------------------------------------------------
local function setOpen(open)
	gui.Enabled = open
	-- HUDClient ховає свою панель ресурсів, щоб вона не накривала заголовок конструктора
	player:SetAttribute("BuilderOpen", open)
	if open then
		hintText = nil
		designDirty = true
		refresh()
	end
end

closeX.Activated:Connect(function()
	setOpen(false)
end)

local hangar = workspace:WaitForChild("Hangar", 10)
local console = hangar and hangar:WaitForChild("BuilderConsole", 10)
local screen = console and console:WaitForChild("Screen", 10)
local prompt = screen and screen:FindFirstChildOfClass("ProximityPrompt")
if prompt then
	prompt.Triggered:Connect(function()
		setOpen(not gui.Enabled)
	end)
	RunService.Heartbeat:Connect(function()
		if gui.Enabled then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - screen.Position).Magnitude > CLOSE_DISTANCE then
				setOpen(false)
			end
		end
	end)
else
	warn("[RocketBuilder] Workspace > Hangar > BuilderConsole > Screen not found. Run BuildWorld_Step3.")
end

syncBuilt()
rebuildCatalog()
