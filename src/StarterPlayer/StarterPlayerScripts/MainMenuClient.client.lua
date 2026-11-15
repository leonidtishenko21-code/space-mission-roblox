--[[
	MainMenuClient (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > MainMenuClient

	What it does:
	  1. Builds the main menu (Play / Settings / About).
	  2. After "Play" it smoothly shows a loading screen with NASA photos.
	  3. Really preloads the game assets with ContentProvider:PreloadAsync() and shows %.
	  4. The "Skip >>" button takes the player straight to the Hangar.

	The whole interface is created by the script, so nothing has to be done in StarterGui by hand.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------
-- ⚙️ SETTINGS — CHANGE THEM HERE
--------------------------------------------------------------------
local GAME_TITLE = "SPACE MISSION"
local SUBTITLE = "An engineering space mission simulator"
local VERSION_TEXT = "Phase 1  •  v0.1"

-- Your team's names (for the "About" window)
local TEAM_NICKNAMES = { "Leonid Tishchenko", "Rostyslav Sakhno", "Illia Moroz" }

-- NASA photos for the loading screen. Put the IDs here after uploading them to Roblox:
-- example: "rbxassetid://1234567890"
local LOADING_IMAGES = {
	-- "rbxassetid://0000000000",
}

-- If some characters show up as squares, change this to Enum.Font.Arial
local FONT_BOLD = Enum.Font.GothamBold
local FONT_REGULAR = Enum.Font.Gotham

local MIN_LOADING_TIME = 2.5 -- seconds: so the loading screen does not vanish instantly
local BATCH_SIZE = 25        -- how many objects to preload at a time

-- Colours from the spec
local COLOR_BUTTON = Color3.fromRGB(76, 153, 76)
local COLOR_BUTTON_HOVER = Color3.fromRGB(98, 180, 98)
local COLOR_BORDER = Color3.fromRGB(40, 80, 40)
local COLOR_PANEL = Color3.fromRGB(18, 26, 50)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(180, 195, 220)
local COLOR_OFF = Color3.fromRGB(150, 60, 60)

-- Fun NASA facts during loading
local FACTS = {
	"Gravity on the Moon is 1.62 m/s² — about 1/6 of Earth's.",
	"The Saturn V had 5 F-1 engines burning RP-1 and liquid oxygen.",
	"The ISS orbits Earth once roughly every 90 minutes.",
	"Atmospheric pressure on Mars is less than 1% of Earth's.",
	"A radio signal from Mars takes 3 to 22 minutes to reach Earth.",
	"There is no air drag in a vacuum: to stop, you must fire the engine against your motion.",
}

--------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------

-- Creates an object and sets its properties right away.
-- Parent is set last — Roblox works faster that way.
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

-- Disable character controls while the menu is open
-- PlayerModule is looked up in the background (task.spawn) so the menu appears immediately.
-- The desired state is remembered and applied once the controls are found.
local controls = nil
local wantedControlsEnabled = true

local function applyControls()
	if controls then
		if wantedControlsEnabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

task.spawn(function()
	pcall(function()
		local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5))
		controls = playerModule:GetControls()
	end)
	applyControls()
end)

local function setControls(enabled)
	wantedControlsEnabled = enabled
	applyControls()
end

-- Hide the default Roblox UI (chat, player list) while the menu is open
local function setCoreGui(enabled)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, enabled)
	end)
end

-- Draws random "stars" in the background
local function addStars(parent, count)
	for _ = 1, count do
		local size = math.random(1, 3)
		create("Frame", {
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.fromScale(math.random(), math.random()),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = math.random() * 0.6,
			BorderSizePixel = 0,
			ZIndex = 1,
			Parent = parent,
		})
	end
end

-- Green button with a border and a hover animation
local function makeButton(text, order, parent)
	local button = create("TextButton", {
		Name = text,
		Size = UDim2.fromOffset(300, 64),
		BackgroundColor3 = COLOR_BUTTON,
		Text = text,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 28,
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 5,
		Parent = parent,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 14), Parent = button })
	create("UIStroke", {
		Color = COLOR_BORDER,
		Thickness = 4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = button,
	})
	local scale = create("UIScale", { Scale = 1, Parent = button })

	button.MouseEnter:Connect(function()
		tween(scale, 0.15, { Scale = 1.07 })
		tween(button, 0.15, { BackgroundColor3 = COLOR_BUTTON_HOVER })
	end)
	button.MouseLeave:Connect(function()
		tween(scale, 0.15, { Scale = 1 })
		tween(button, 0.15, { BackgroundColor3 = COLOR_BUTTON })
	end)

	return button
end

--------------------------------------------------------------------
-- TRANSITION SCREEN (black fade)
--------------------------------------------------------------------
local fadeGui = create("ScreenGui", {
	Name = "FadeGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 100,
	Parent = playerGui,
})
local fadeFrame = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = fadeGui,
})

-- transparency: 0 = fully black, 1 = transparent
local function fadeTo(transparency, time)
	local t = tween(fadeFrame, time or 0.5, { BackgroundTransparency = transparency })
	t.Completed:Wait()
end

--------------------------------------------------------------------
-- MAIN MENU
--------------------------------------------------------------------
local menuGui = create("ScreenGui", {
	Name = "MainMenuGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 10,
	Parent = playerGui,
})

local background = create("Frame", {
	Name = "Background",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	Parent = menuGui,
})
create("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(14, 22, 52), Color3.fromRGB(2, 4, 12)),
	Rotation = 90,
	Parent = background,
})
addStars(background, 140)

create("TextLabel", {
	Name = "Title",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.2),
	Size = UDim2.new(0.9, 0, 0, 70),
	BackgroundTransparency = 1,
	Text = GAME_TITLE,
	TextColor3 = COLOR_TEXT,
	Font = FONT_BOLD,
	TextScaled = true,
	ZIndex = 5,
	Parent = background,
})
create("TextLabel", {
	Name = "Subtitle",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.2, 55),
	Size = UDim2.new(0.9, 0, 0, 28),
	BackgroundTransparency = 1,
	Text = SUBTITLE,
	TextColor3 = COLOR_TEXT_DIM,
	Font = FONT_REGULAR,
	TextSize = 22,
	ZIndex = 5,
	Parent = background,
})
create("TextLabel", {
	Name = "Version",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -12),
	Size = UDim2.fromOffset(300, 22),
	BackgroundTransparency = 1,
	Text = VERSION_TEXT,
	TextColor3 = COLOR_TEXT_DIM,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR,
	TextSize = 16,
	ZIndex = 5,
	Parent = background,
})

-- Column of three buttons
local buttonHolder = create("Frame", {
	Name = "Buttons",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.6),
	Size = UDim2.fromOffset(340, 260),
	BackgroundTransparency = 1,
	ZIndex = 5,
	Parent = background,
})
create("UIListLayout", {
	Padding = UDim.new(0, 20),
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = buttonHolder,
})

local playButton = makeButton("Play", 1, buttonHolder)
local settingsButton = makeButton("Settings", 2, buttonHolder)
local aboutButton = makeButton("About", 3, buttonHolder)

-- Window template (for Settings and About)
local function makePanel(name, titleText)
	local panel = create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.58),
		Size = UDim2.new(0.92, 0, 0, 440),
		BackgroundColor3 = COLOR_PANEL,
		Visible = false,
		ZIndex = 10,
		Parent = background,
	})
	create("UISizeConstraint", { MaxSize = Vector2.new(580, 440), Parent = panel })
	create("UICorner", { CornerRadius = UDim.new(0, 16), Parent = panel })
	create("UIStroke", { Color = COLOR_BORDER, Thickness = 3, Parent = panel })

	create("TextLabel", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 60),
		BackgroundTransparency = 1,
		Text = titleText,
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 30,
		ZIndex = 11,
		Parent = panel,
	})

	local content = create("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(20, 66),
		Size = UDim2.new(1, -40, 1, -150),
		BackgroundTransparency = 1,
		ZIndex = 11,
		Parent = panel,
	})

	local backButton = makeButton("Back", 0, panel)
	backButton.AnchorPoint = Vector2.new(0.5, 1)
	backButton.Position = UDim2.new(0.5, 0, 1, -16)
	backButton.Size = UDim2.fromOffset(200, 52)
	backButton.TextSize = 24
	backButton.ZIndex = 12
	backButton.MouseButton1Click:Connect(function()
		panel.Visible = false
		buttonHolder.Visible = true
	end)

	return panel, content
end

--------------------------------------------------------------------
-- SETTINGS: special effects and sky graphics
--------------------------------------------------------------------

-- 1) Special effects (ParticleEmitter, Trail, Beam)
local vfxEnabled = true
player:SetAttribute("VFXEnabled", true) -- other scripts (engine fire) can check this

local function isVfx(obj)
	return obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
end

local function applyVfx(enabled)
	vfxEnabled = enabled
	player:SetAttribute("VFXEnabled", enabled)
	for _, obj in ipairs(workspace:GetDescendants()) do
		if isVfx(obj) then
			if not enabled and obj.Enabled then
				-- remember that WE turned this effect off
				obj:SetAttribute("HiddenBySettings", true)
				obj.Enabled = false
			elseif enabled and obj:GetAttribute("HiddenBySettings") then
				obj:SetAttribute("HiddenBySettings", nil)
				obj.Enabled = true
			end
		end
	end
end

-- New effects that appear later are also turned off if VFX are disabled
workspace.DescendantAdded:Connect(function(obj)
	if not vfxEnabled and isVfx(obj) and obj.Enabled then
		obj:SetAttribute("HiddenBySettings", true)
		obj.Enabled = false
	end
end)

-- 2) Sky graphics: shadows, atmosphere, clouds, lighting effects
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
local originalDensity = atmosphere and atmosphere.Density or 0
local originalShadows = Lighting.GlobalShadows
local originalEffects = {}
for _, effect in ipairs(Lighting:GetChildren()) do
	if effect:IsA("PostEffect") then -- Bloom, SunRays, ColorCorrection, etc.
		originalEffects[effect] = effect.Enabled
	end
end

local function applySky(high)
	Lighting.GlobalShadows = high and originalShadows or false
	if atmosphere then
		atmosphere.Density = high and originalDensity or originalDensity * 0.5
	end
	local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds")
	if clouds then
		clouds.Enabled = high
	end
	for effect, wasEnabled in pairs(originalEffects) do
		if effect.Parent then
			effect.Enabled = high and wasEnabled or false
		end
	end
end

local function makeToggle(parent, order, labelText, onText, offText, startValue, onChanged)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 60),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 11,
		Parent = parent,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -150, 1, 0),
		BackgroundTransparency = 1,
		Text = labelText,
		TextColor3 = COLOR_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Font = FONT_BOLD,
		TextSize = 22,
		ZIndex = 11,
		Parent = row,
	})
	local toggle = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(130, 44),
		TextColor3 = COLOR_TEXT,
		Font = FONT_BOLD,
		TextSize = 20,
		AutoButtonColor = false,
		ZIndex = 12,
		Parent = row,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = toggle })
	create("UIStroke", { Color = COLOR_BORDER, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = toggle })

	local value = startValue
	local function refresh()
		toggle.Text = value and onText or offText
		toggle.BackgroundColor3 = value and COLOR_BUTTON or COLOR_OFF
	end
	refresh()

	toggle.MouseButton1Click:Connect(function()
		value = not value
		refresh()
		onChanged(value)
	end)
	return row
end

local settingsPanel, settingsContent = makePanel("SettingsPanel", "Settings")
create("UIListLayout", {
	Padding = UDim.new(0, 14),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = settingsContent,
})
makeToggle(settingsContent, 1, "Special effects", "ON", "OFF", true, applyVfx)
makeToggle(settingsContent, 2, "Sky quality", "HIGH", "LOW", true, applySky)
create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 60),
	BackgroundTransparency = 1,
	Text = "If the game lags, turn off special effects and set the sky quality to low.",
	TextColor3 = COLOR_TEXT_DIM,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR,
	TextSize = 18,
	LayoutOrder = 3,
	ZIndex = 11,
	Parent = settingsContent,
})

--------------------------------------------------------------------
-- ABOUT
--------------------------------------------------------------------
local aboutPanel, aboutContent = makePanel("AboutPanel", "About")

local scroll = create("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ZIndex = 11,
	Parent = aboutContent,
})

local aboutText = "<b>Development team:</b>\n" .. table.concat(TEAM_NICKNAMES, ", ")
	.. "\n\n<b>Inspiration:</b>\nReal NASA programs (Apollo, Artemis, the Mars rovers), "
	.. "plus the games Kerbal Space Program and Spaceflight Simulator."
	.. "\n\n<b>The engineering challenge:</b>\nEvery space mission is a trade-off. "
	.. "Your budget is limited, and every part adds mass, uses power and costs money. "
	.. "A bigger engine means a heavier rocket and more fuel. Forget the antenna and your data never reaches Earth. "
	.. "Mount a heavy instrument on one side only and the rocket will drift sideways."
	.. "\n\nBuild your ship, plan your braking distance, make a soft landing "
	.. "and complete survey missions on the Moon and Mars."

create("TextLabel", {
	Size = UDim2.new(1, -12, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	RichText = true,
	Text = aboutText,
	TextColor3 = COLOR_TEXT,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = FONT_REGULAR,
	TextSize = 19,
	ZIndex = 11,
	Parent = scroll,
})

settingsButton.MouseButton1Click:Connect(function()
	buttonHolder.Visible = false
	settingsPanel.Visible = true
end)
aboutButton.MouseButton1Click:Connect(function()
	buttonHolder.Visible = false
	aboutPanel.Visible = true
end)

--------------------------------------------------------------------
-- LOADING SCREEN
--------------------------------------------------------------------
local loadingGui = create("ScreenGui", {
	Name = "LoadingScreen",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 20,
	Enabled = false,
	Parent = playerGui,
})

local loadingBg = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(4, 6, 16),
	BorderSizePixel = 0,
	Parent = loadingGui,
})
addStars(loadingBg, 160)

local photo = create("ImageLabel", {
	Name = "NASAPhoto",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ScaleType = Enum.ScaleType.Crop,
	Image = LOADING_IMAGES[1] or "",
	ZIndex = 2,
	Parent = loadingBg,
})

-- A dark band at the bottom so the text is readable on any photo
local bottomShade = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 200),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BorderSizePixel = 0,
	ZIndex = 3,
	Parent = loadingBg,
})
create("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new(1, 0.15),
	Parent = bottomShade,
})

local factLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -110),
	Size = UDim2.new(0.85, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = FACTS[math.random(1, #FACTS)],
	TextColor3 = COLOR_TEXT_DIM,
	TextWrapped = true,
	Font = FONT_REGULAR,
	TextSize = 20,
	ZIndex = 4,
	Parent = loadingBg,
})

local percentLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -64),
	Size = UDim2.new(0.85, 0, 0, 30),
	BackgroundTransparency = 1,
	Text = "Loading the NASA world: 0%",
	TextColor3 = COLOR_TEXT,
	Font = FONT_BOLD,
	TextSize = 24,
	ZIndex = 4,
	Parent = loadingBg,
})

local barBack = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -36),
	Size = UDim2.new(0.7, 0, 0, 16),
	BackgroundColor3 = Color3.fromRGB(30, 40, 60),
	BorderSizePixel = 0,
	ZIndex = 4,
	Parent = loadingBg,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = barBack })
create("UIStroke", { Color = COLOR_BORDER, Thickness = 2, Parent = barBack })

local barFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = COLOR_BUTTON,
	BorderSizePixel = 0,
	ZIndex = 5,
	Parent = barBack,
})
create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = barFill })

local skipButton = makeButton("Skip >>", 0, loadingBg)
skipButton.AnchorPoint = Vector2.new(1, 1)
skipButton.Position = UDim2.new(1, -20, 1, -70)
skipButton.Size = UDim2.fromOffset(220, 52)
skipButton.TextSize = 22
skipButton.ZIndex = 6

local function setProgress(fraction)
	fraction = math.clamp(fraction, 0, 1)
	tween(barFill, 0.2, { Size = UDim2.fromScale(fraction, 1) })
	percentLabel.Text = "Loading the NASA world: " .. math.floor(fraction * 100) .. "%"
end

--------------------------------------------------------------------
-- GOING TO THE HANGAR
--------------------------------------------------------------------
local function teleportToHangar()
	local character = player.Character or player.CharacterAdded:Wait()
	local hangar = workspace:WaitForChild("Hangar", 5)
	local spawnPart = hangar and hangar:FindFirstChild("HangarSpawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		-- place the character 3 studs above the point so it does not get stuck in the floor
		character:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
	else
		warn("[MainMenu] Workspace > Hangar > HangarSpawn not found — the player stays in place.")
	end
end

local finished = false

local function finishLoading()
	if finished then
		return
	end
	finished = true

	fadeTo(0, 0.4)
	loadingGui:Destroy()
	menuGui:Destroy()
	teleportToHangar()
	player:SetAttribute("InGame", true)
	setControls(true)
	setCoreGui(true)
	fadeTo(1, 0.7)
	fadeGui:Destroy()
end

skipButton.MouseButton1Click:Connect(finishLoading)

-- NASA photo slideshow and changing facts
local function startSlideshow()
	task.spawn(function()
		local index = 1
		while not finished do
			task.wait(5)
			if finished then
				break
			end
			factLabel.Text = FACTS[math.random(1, #FACTS)]
			if #LOADING_IMAGES > 1 then
				index = index % #LOADING_IMAGES + 1
				tween(photo, 0.5, { ImageTransparency = 1 }).Completed:Wait()
				if finished then
					break
				end
				photo.Image = LOADING_IMAGES[index]
				tween(photo, 0.5, { ImageTransparency = 0 })
			end
		end
	end)
end

-- Real loading: Progress (%) = loaded / total × 100
local function startLoading()
	startSlideshow()

	task.spawn(function()
		local startTime = os.clock()

		-- the photos first, so the background appears quickly
		pcall(function()
			ContentProvider:PreloadAsync({ photo })
		end)

		local toLoad = {}
		for _, obj in ipairs(workspace:GetDescendants()) do
			table.insert(toLoad, obj)
		end
		for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
			table.insert(toLoad, obj)
		end

		local total = #toLoad
		local loaded = 0

		while loaded < total and not finished do
			local batch = {}
			for i = loaded + 1, math.min(loaded + BATCH_SIZE, total) do
				table.insert(batch, toLoad[i])
			end
			pcall(function()
				ContentProvider:PreloadAsync(batch)
			end)
			loaded += #batch
			setProgress(loaded / total)
		end

		if finished then
			return
		end
		setProgress(1)

		-- wait the minimum time so the player has a chance to see the screen
		while os.clock() - startTime < MIN_LOADING_TIME and not finished do
			task.wait(0.1)
		end
		task.wait(0.4)
		finishLoading()
	end)
end

--------------------------------------------------------------------
-- THE "PLAY" BUTTON
--------------------------------------------------------------------
local playPressed = false
playButton.MouseButton1Click:Connect(function()
	if playPressed then
		return
	end
	playPressed = true

	fadeTo(0, 0.5)
	menuGui.Enabled = false
	loadingGui.Enabled = true
	fadeTo(1, 0.5)
	startLoading()
end)

--------------------------------------------------------------------
-- START
--------------------------------------------------------------------
setControls(false)
setCoreGui(false)
