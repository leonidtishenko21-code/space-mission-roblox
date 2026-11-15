--[[
	SpacesuitManager (ModuleScript, SERVER) — STEP 2: NASA spacesuit
	Location: ServerScriptService > Modules > SpacesuitManager

	Builds the spacesuit in code and welds it (WeldConstraint) to the character (R15 and R6):
	  Head       — white pressure helmet + gold reflective visor, neck ring,
	               headlamp (SpotLight, key L)
	  UpperTorso — PLSS life-support backpack with an O₂ / power indicator,
	               DCM chest control unit, thrusters (ParticleEmitter "JetFX")
	All parts: Massless, no collisions — they do not affect walking or rocket physics.

	API: Equip(player) / Unequip(player) / IsEquipped(player) / ToggleLight(player) / SetJets(player, on)
	Player attributes: SuitEquipped, SuitO2 (0–100), SuitPower (0–100), SuitLight, SuitJets

	Life support: inside the capsule (InCapsule) supplies refill, outside they are used up.
	[GAME] A real PLSS has O₂ for ~8 h; in the game — O2_MINUTES minutes, no death, only a warning.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SpacesuitManager = {}

SpacesuitManager.SUIT_NAME = "NASA_Spacesuit"
SpacesuitManager.notify = nil -- function(player, text, isError) — set by FlightServer

local O2_MINUTES = 10
local LIGHT_DRAIN = 0.35 -- % of power per second
local JET_DRAIN = 1.5
local BASE_DRAIN = 0.08

local WHITE = Color3.fromRGB(242, 242, 238)
local GREY = Color3.fromRGB(170, 172, 178)
local DARK = Color3.fromRGB(45, 48, 55)
local GOLD = Color3.fromRGB(214, 168, 52)
local NASA_BLUE = Color3.fromRGB(11, 61, 145)

local suits = {} -- [player] = { folder, light, lens, jets = {}, labels = {}, warned = {} }

--------------------------------------------------------------------
-- Parts
--------------------------------------------------------------------
local function newPart(folder, name, shape, size, color, material)
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Parent = folder
	return p
end

-- place a part relative to a body part and weld it
local function attach(p, bodyPart, offset)
	p.CFrame = bodyPart.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = bodyPart
	w.Part1 = p
	w.Parent = p
	return p
end

-- O₂ / power indicator on a face of the part
local function addDisplay(p, face, pixelsPerStud)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SuitDisplay"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.Parent = p

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(15, 20, 30)
	bg.BorderSizePixel = 0
	bg.Parent = gui

	local function bar(y, color)
		local back = Instance.new("Frame")
		back.Position = UDim2.new(0.08, 0, y, 0)
		back.Size = UDim2.new(0.84, 0, 0.16, 0)
		back.BackgroundColor3 = Color3.fromRGB(40, 45, 55)
		back.BorderSizePixel = 0
		back.Parent = bg
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = back
		return fill
	end

	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromScale(0.05, 0.04)
	text.Size = UDim2.fromScale(0.9, 0.42)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(120, 255, 160)
	text.Text = "O₂ 100%  ⚡ 100%"
	text.Parent = bg

	return {
		text = text,
		o2 = bar(0.52, Color3.fromRGB(90, 200, 255)),
		power = bar(0.76, Color3.fromRGB(255, 200, 60)),
	}
end

local function addJet(pack, x, packSize)
	local nozzle = newPart(pack.Parent, "JetNozzle", Enum.PartType.Cylinder, Vector3.new(0.3, 0.35, 0.35), DARK, Enum.Material.Metal)
	attach(nozzle, pack, CFrame.new(x, -packSize.Y / 2 - 0.1, 0.1) * CFrame.Angles(0, 0, math.rad(90)))

	local att = Instance.new("Attachment")
	att.Name = "JetPoint"
	att.Position = Vector3.new(x, -packSize.Y / 2 - 0.25, 0.1) -- the attachment's +Y = backpack up
	att.Parent = pack

	local fx = Instance.new("ParticleEmitter")
	fx.Name = "JetFX"
	fx.Texture = "rbxasset://textures/particles/smoke_main.dds"
	fx.Color = ColorSequence.new(Color3.fromRGB(220, 240, 255), Color3.fromRGB(150, 190, 255))
	fx.LightEmission = 0.7
	fx.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1.4) })
	fx.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	fx.Lifetime = NumberRange.new(0.25, 0.45)
	fx.Rate = 70
	fx.Speed = NumberRange.new(10, 16)
	fx.SpreadAngle = Vector2.new(8, 8)
	fx.EmissionDirection = Enum.NormalId.Bottom -- jet points down
	fx.Enabled = false
	fx.Parent = att
	return fx
end

--------------------------------------------------------------------
-- Indicator updates
--------------------------------------------------------------------
local function refreshDisplays(player)
	local suit = suits[player]
	if not suit then
		return
	end
	local o2 = player:GetAttribute("SuitO2") or 100
	local power = player:GetAttribute("SuitPower") or 100
	for _, d in ipairs(suit.labels) do
		d.text.Text = string.format("O₂ %d%%  ⚡ %d%%", math.floor(o2 + 0.5), math.floor(power + 0.5))
		d.text.TextColor3 = (o2 < 25 or power < 15) and Color3.fromRGB(255, 90, 80) or Color3.fromRGB(120, 255, 160)
		d.o2.Size = UDim2.fromScale(math.clamp(o2 / 100, 0, 1), 1)
		d.power.Size = UDim2.fromScale(math.clamp(power / 100, 0, 1), 1)
	end
end

--------------------------------------------------------------------
-- Put on / take off
--------------------------------------------------------------------
function SpacesuitManager.IsEquipped(player)
	local suit = suits[player]
	return suit ~= nil and suit.folder.Parent ~= nil
end

function SpacesuitManager.Equip(player)
	if SpacesuitManager.IsEquipped(player) then
		return true
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local torso = character and (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso"))
	if not (head and torso) then
		return false
	end

	local folder = Instance.new("Folder")
	folder.Name = SpacesuitManager.SUIT_NAME
	folder.Parent = character
	local suit = { folder = folder, jets = {}, labels = {}, warned = {} }

	-- HELMET ------------------------------------------------------
	local hs = head.Size
	local d = math.clamp(math.max(hs.Y, hs.Z) * 1.9, 1.8, 3)
	attach(newPart(folder, "Helmet", Enum.PartType.Ball, Vector3.one * d, WHITE), head, CFrame.new(0, 0.08 * d, 0))
	-- visor: a gold sphere sticking out a little at the front (the gold coating reflects solar IR and UV)
	local visor = newPart(folder, "GoldVisor", Enum.PartType.Ball, Vector3.one * d * 0.86, GOLD, Enum.Material.Metal)
	visor.Reflectance = 0.35
	attach(visor, head, CFrame.new(0, 0.1 * d, -0.12 * d))
	attach(newPart(folder, "NeckRing", Enum.PartType.Cylinder, Vector3.new(0.25, d * 0.78, d * 0.78), GREY, Enum.Material.Metal),
		head, CFrame.new(0, -0.4 * d, 0) * CFrame.Angles(0, 0, math.rad(90)))

	-- headlamp
	local lamp = newPart(folder, "HeadLamp", nil, Vector3.new(0.4, 0.28, 0.3), DARK, Enum.Material.Metal)
	attach(lamp, head, CFrame.new(0.24 * d, 0.36 * d, -0.3 * d))
	local lens = newPart(folder, "HeadLampLens", nil, Vector3.new(0.28, 0.18, 0.05), Color3.fromRGB(120, 120, 110), Enum.Material.SmoothPlastic)
	attach(lens, lamp, CFrame.new(0, 0, -0.17))
	local light = Instance.new("SpotLight")
	light.Name = "HeadLight"
	light.Face = Enum.NormalId.Front
	light.Angle = 70
	light.Range = 45
	light.Brightness = 4
	light.Shadows = true
	light.Color = Color3.fromRGB(255, 248, 225)
	light.Enabled = false
	light.Parent = lamp
	suit.light, suit.lens = light, lens

	-- PLSS BACKPACK ----------------------------------------------
	local ts = torso.Size
	local packSize = Vector3.new(ts.X * 0.95, ts.Y * 1.25, 0.9)
	local pack = newPart(folder, "PLSS_Backpack", nil, packSize, WHITE)
	attach(pack, torso, CFrame.new(0, ts.Y * 0.05, ts.Z / 2 + packSize.Z / 2)) -- +Z = back
	local stripe = newPart(folder, "PLSS_Stripe", nil, Vector3.new(packSize.X + 0.02, 0.18, packSize.Z + 0.02), NASA_BLUE)
	attach(stripe, pack, CFrame.new(0, packSize.Y * 0.32, 0))
	for _, side in ipairs({ -1, 1 }) do
		attach(newPart(folder, "O2Tank", Enum.PartType.Cylinder, Vector3.new(packSize.Y * 0.85, 0.42, 0.42), GREY, Enum.Material.Metal),
			pack, CFrame.new(side * packSize.X * 0.3, 0, packSize.Z / 2 + 0.18) * CFrame.Angles(0, 0, math.rad(90)))
	end
	-- indicator on top of the backpack (seen by the camera from behind) and the DCM chest unit
	local screen = newPart(folder, "PLSS_Display", nil, Vector3.new(packSize.X * 0.7, 0.45, 0.06), DARK)
	attach(screen, pack, CFrame.new(0, packSize.Y * 0.12, packSize.Z / 2 + 0.42))
	table.insert(suit.labels, addDisplay(screen, Enum.NormalId.Back, 80))
	local dcm = newPart(folder, "DCM_ChestPanel", nil, Vector3.new(ts.X * 0.55, ts.Y * 0.32, 0.3), WHITE)
	attach(dcm, torso, CFrame.new(0, -ts.Y * 0.05, -ts.Z / 2 - 0.15))
	table.insert(suit.labels, addDisplay(dcm, Enum.NormalId.Front, 70))

	-- backpack thrusters (visible to everyone; STEP 3 adds the thrust)
	for _, side in ipairs({ -1, 1 }) do
		table.insert(suit.jets, addJet(pack, side * packSize.X * 0.32, packSize))
	end

	suits[player] = suit
	if player:GetAttribute("SuitO2") == nil then
		player:SetAttribute("SuitO2", 100)
	end
	if player:GetAttribute("SuitPower") == nil then
		player:SetAttribute("SuitPower", 100)
	end
	player:SetAttribute("SuitLight", false)
	player:SetAttribute("SuitJets", false)
	player:SetAttribute("SuitEquipped", true)
	refreshDisplays(player)
	return true
end

function SpacesuitManager.Unequip(player)
	local suit = suits[player]
	suits[player] = nil
	if suit and suit.folder.Parent then
		suit.folder:Destroy()
	end
	if player.Parent then
		player:SetAttribute("SuitEquipped", false)
		player:SetAttribute("SuitLight", nil)
		player:SetAttribute("SuitJets", nil)
		player:SetAttribute("SuitO2", nil)
		player:SetAttribute("SuitPower", nil)
	end
end

--------------------------------------------------------------------
-- Headlamp and thrusters
--------------------------------------------------------------------
local function setLight(player, on)
	local suit = suits[player]
	if not suit then
		return
	end
	suit.light.Enabled = on
	suit.lens.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
	suit.lens.Color = on and Color3.fromRGB(255, 250, 220) or Color3.fromRGB(120, 120, 110)
	player:SetAttribute("SuitLight", on)
end

function SpacesuitManager.ToggleLight(player)
	if not SpacesuitManager.IsEquipped(player) then
		return false, "Put on your spacesuit first."
	end
	local on = not player:GetAttribute("SuitLight")
	if on and (player:GetAttribute("SuitPower") or 0) <= 0 then
		return false, "Suit battery is empty — return to the capsule."
	end
	setLight(player, on)
	return true, on and "🔦 Headlamp ON" or "Headlamp OFF"
end

function SpacesuitManager.SetJets(player, on)
	local suit = suits[player]
	if not suit then
		return
	end
	on = on == true and (player:GetAttribute("SuitPower") or 0) > 0
	for _, fx in ipairs(suit.jets) do
		fx.Enabled = on
	end
	player:SetAttribute("SuitJets", on)
end

--------------------------------------------------------------------
-- Life support (once per second)
--------------------------------------------------------------------
local function warnOnce(player, suit, key, text)
	if not suit.warned[key] and SpacesuitManager.notify then
		suit.warned[key] = true
		SpacesuitManager.notify(player, text, true)
	end
end

local timer = 0
RunService.Heartbeat:Connect(function(dt)
	timer += dt
	if timer < 1 then
		return
	end
	local step = timer
	timer = 0
	for player, suit in pairs(suits) do
		if not suit.folder.Parent then
			suits[player] = nil
			continue
		end
		local o2 = player:GetAttribute("SuitO2") or 100
		local power = player:GetAttribute("SuitPower") or 100
		if player:GetAttribute("InCapsule") then
			-- the capsule charges the backpack and refills the oxygen
			o2 = math.min(100, o2 + 5 * step)
			power = math.min(100, power + 3 * step)
			suit.warned = {}
		else
			o2 = math.max(0, o2 - 100 / (O2_MINUTES * 60) * step)
			local drain = BASE_DRAIN
				+ (player:GetAttribute("SuitLight") and LIGHT_DRAIN or 0)
				+ (player:GetAttribute("SuitJets") and JET_DRAIN or 0)
			power = math.max(0, power - drain * step)
			if power <= 0 then
				setLight(player, false)
				SpacesuitManager.SetJets(player, false)
				warnOnce(player, suit, "power0", "⚡ Suit battery depleted: headlamp and thrusters are off.")
			end
			if o2 <= 25 then
				warnOnce(player, suit, "o2low", "⚠ Suit oxygen below 25% — head back to the capsule!")
			end
			if o2 <= 0 then
				warnOnce(player, suit, "o2zero", "⛔ Out of oxygen! Get to the capsule now.")
			end
		end
		player:SetAttribute("SuitO2", o2)
		player:SetAttribute("SuitPower", power)
		refreshDisplays(player)
	end
end)

-- New character (respawn) — it has no spacesuit
local function hook(player)
	player.CharacterRemoving:Connect(function()
		SpacesuitManager.Unequip(player)
	end)
end
Players.PlayerAdded:Connect(hook)
for _, p in ipairs(Players:GetPlayers()) do
	hook(p)
end
Players.PlayerRemoving:Connect(function(player)
	suits[player] = nil
end)

return SpacesuitManager
