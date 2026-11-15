--[[
	BuildWorld_Step2 — ОДНОРАЗОВИЙ скрипт-будівельник.
	Запускається ОДИН раз у режимі редагування (Edit), НЕ під час Play:
	  • через Claude Code (Roblox_Studio MCP), або
	  • вручну: View → Command Bar → вставити весь код → Enter.

	Що будує:
	  Workspace > Hangar > Building   — ангар збирання (підлога, стіни, дах, лампи, майданчик BuildPad)
	  Workspace > OilRig              — нафтова вишка, качалка, сховище RP-1, завод, пульт керування
	  Workspace > LaunchPad           — стартовий майданчик (знадобиться в кроці 4)
	  ReplicatedStorage > Remotes     — UpgradeOilRig, Notify (зв'язок гравець ↔ сервер)

	⚠️ Повторний запуск ВИДАЛЯЄ і будує заново Hangar.Building, OilRig та LaunchPad.
	   Якщо ти вже змінив їх вручну — не запускай повторно.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--------------------------------------------------------------------
-- Допоміжні функції
--------------------------------------------------------------------
local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.Shape then
		p.Shape = props.Shape
	end
	for key, value in pairs(props) do
		if key ~= "Parent" and key ~= "Shape" then
			p[key] = value
		end
	end
	p.Parent = props.Parent
	return p
end

-- Вертикальний циліндр. У Roblox вісь циліндра — X, тому повертаємо на 90° навколо Z.
local function cylinder(name, height, diameter, position, color, material, parent)
	return part({
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, diameter, diameter),
		CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Material = material or Enum.Material.Metal,
		Parent = parent,
	})
end

local function sign(partObj, face, text, textColor, bgColor)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = partObj
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bgColor or Color3.fromRGB(20, 30, 20)
	label.BackgroundTransparency = bgColor and 0 or 1
	label.Text = text
	label.TextColor3 = textColor or Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
	return gui
end

local function freshModel(name, parent)
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function ensureFolder(name, parent)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

local function ensureRemote(name, parent)
	local r = parent:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = parent
	end
	return r
end

-- Кольори
local CONCRETE = Color3.fromRGB(150, 150, 150)
local WALL = Color3.fromRGB(205, 210, 215)
local DARK = Color3.fromRGB(45, 48, 55)
local RED = Color3.fromRGB(200, 60, 40)
local WHITE = Color3.fromRGB(240, 240, 240)
local YELLOW = Color3.fromRGB(240, 190, 40)
local GREEN = Color3.fromRGB(76, 153, 76)

--------------------------------------------------------------------
-- 1. Remotes
--------------------------------------------------------------------
local remotes = ensureFolder("Remotes", ReplicatedStorage)
ensureRemote("UpgradeOilRig", remotes)
ensureRemote("Notify", remotes)

--------------------------------------------------------------------
-- 2. АНГАР  (центр: 0, 0, -60;  двері дивляться на +Z, до точки старту)
--------------------------------------------------------------------
local hangarFolder = ensureFolder("Hangar", workspace)
local building = freshModel("Building", hangarFolder)

local floor = part({ Name = "Floor", Size = Vector3.new(90, 1, 70), Position = Vector3.new(0, 0.5, -60),
	Color = CONCRETE, Material = Enum.Material.Concrete, Parent = building })
building.PrimaryPart = floor

part({ Name = "BackWall", Size = Vector3.new(90, 30, 2), Position = Vector3.new(0, 16, -95),
	Color = WALL, Material = Enum.Material.Metal, Parent = building })
part({ Name = "LeftWall", Size = Vector3.new(2, 30, 70), Position = Vector3.new(-45, 16, -60),
	Color = WALL, Material = Enum.Material.Metal, Parent = building })
part({ Name = "RightWall", Size = Vector3.new(2, 30, 70), Position = Vector3.new(45, 16, -60),
	Color = WALL, Material = Enum.Material.Metal, Parent = building })
-- передня стіна з великими воротами 40 studs
part({ Name = "FrontWallLeft", Size = Vector3.new(25, 30, 2), Position = Vector3.new(-32.5, 16, -25),
	Color = WALL, Material = Enum.Material.Metal, Parent = building })
part({ Name = "FrontWallRight", Size = Vector3.new(25, 30, 2), Position = Vector3.new(32.5, 16, -25),
	Color = WALL, Material = Enum.Material.Metal, Parent = building })
local lintel = part({ Name = "DoorTop", Size = Vector3.new(40, 6, 2), Position = Vector3.new(0, 28, -25),
	Color = DARK, Material = Enum.Material.Metal, Parent = building })
sign(lintel, Enum.NormalId.Back, "АНГАР ЗБИРАННЯ", YELLOW)

part({ Name = "Roof", Size = Vector3.new(92, 2, 72), Position = Vector3.new(0, 32, -60),
	Color = DARK, Material = Enum.Material.Metal, Parent = building })

-- лампи під дахом
for _, x in ipairs({ -25, 0, 25 }) do
	for _, z in ipairs({ -45, -75 }) do
		local lamp = part({ Name = "Lamp", Size = Vector3.new(8, 0.5, 2), Position = Vector3.new(x, 30.7, z),
			Color = Color3.fromRGB(255, 250, 230), Material = Enum.Material.Neon, CanCollide = false, Parent = building })
		local light = Instance.new("PointLight")
		light.Range = 45
		light.Brightness = 1.5
		light.Parent = lamp
	end
end

-- майданчик, де в кроці 3 збиратимемо ракету
local buildPad = part({ Name = "BuildPad", Size = Vector3.new(24, 0.4, 24), Position = Vector3.new(0, 1.2, -70),
	Color = DARK, Material = Enum.Material.DiamondPlate, Parent = building })
-- жовта рамка навколо майданчика
for _, data in ipairs({
	{ Vector3.new(25, 0.5, 0.6), Vector3.new(0, 1.25, -82.3) },
	{ Vector3.new(25, 0.5, 0.6), Vector3.new(0, 1.25, -57.7) },
	{ Vector3.new(0.6, 0.5, 25), Vector3.new(-12.3, 1.25, -70) },
	{ Vector3.new(0.6, 0.5, 25), Vector3.new(12.3, 1.25, -70) },
}) do
	part({ Name = "PadStripe", Size = data[1], Position = data[2], Color = YELLOW,
		Material = Enum.Material.SmoothPlastic, Parent = building })
end
buildPad:SetAttribute("Info", "Тут збирається ракета (крок 3)")

-- точка появи в ангарі
local hangarSpawn = hangarFolder:FindFirstChild("HangarSpawn")
if not hangarSpawn then
	hangarSpawn = part({ Name = "HangarSpawn", Size = Vector3.new(4, 1, 4), Transparency = 1,
		CanCollide = false, Parent = hangarFolder })
end
hangarSpawn.Position = Vector3.new(0, 3, -45)

-- переносимо стандартну точку відродження всередину ангару
local spawnLocation = workspace:FindFirstChildOfClass("SpawnLocation")
if spawnLocation then
	spawnLocation.Position = Vector3.new(0, 1.5, -40)
	spawnLocation.Size = Vector3.new(6, 1, 6)
	spawnLocation.Transparency = 1
	spawnLocation.CanCollide = false
	local decal = spawnLocation:FindFirstChildOfClass("Decal")
	if decal then
		decal.Transparency = 1
	end
end

--------------------------------------------------------------------
-- 3. НАФТОВА ВИШКА ТА ЗАВОД RP-1  (ліворуч від ангару, центр: -100, 0, -60)
--------------------------------------------------------------------
local rig = freshModel("OilRig", workspace)

local rigBase = part({ Name = "Base", Size = Vector3.new(40, 1, 36), Position = Vector3.new(-100, 0.5, -60),
	Color = DARK, Material = Enum.Material.DiamondPlate, Parent = rig })
rig.PrimaryPart = rigBase

-- Вежа (derrick): 4 опори + поперечки
local derrick = Instance.new("Model")
derrick.Name = "Derrick"
derrick.Parent = rig
for _, x in ipairs({ -114, -106 }) do
	for _, z in ipairs({ -64, -56 }) do
		part({ Name = "Leg", Size = Vector3.new(1, 30, 1), Position = Vector3.new(x, 16, z),
			Color = RED, Material = Enum.Material.Metal, Parent = derrick })
	end
end
for _, y in ipairs({ 7, 13, 19, 25 }) do
	for _, z in ipairs({ -64, -56 }) do
		part({ Name = "Bar", Size = Vector3.new(8, 0.6, 0.6), Position = Vector3.new(-110, y, z),
			Color = WHITE, Material = Enum.Material.Metal, Parent = derrick })
	end
	for _, x in ipairs({ -114, -106 }) do
		part({ Name = "Bar", Size = Vector3.new(0.6, 0.6, 8), Position = Vector3.new(x, y, -60),
			Color = WHITE, Material = Enum.Material.Metal, Parent = derrick })
	end
end
part({ Name = "Top", Size = Vector3.new(10, 1, 10), Position = Vector3.new(-110, 31.5, -60),
	Color = RED, Material = Enum.Material.Metal, Parent = derrick })
cylinder("DrillPipe", 30, 0.8, Vector3.new(-110, 16, -60), Color3.fromRGB(120, 120, 120), Enum.Material.Metal, derrick)

-- Качалка (pump jack): коромисло гойдається (анімацію робить HUDClient)
part({ Name = "PumpStand", Size = Vector3.new(2, 4, 2), Position = Vector3.new(-106, 3, -46),
	Color = DARK, Material = Enum.Material.Metal, Parent = rig })
local pumpArm = Instance.new("Model")
pumpArm.Name = "PumpArm"
pumpArm.Parent = rig
part({ Name = "Beam", Size = Vector3.new(12, 1, 1), Position = Vector3.new(-106, 5.5, -46),
	Color = YELLOW, Material = Enum.Material.Metal, Parent = pumpArm })
part({ Name = "Head", Size = Vector3.new(1.5, 3, 1.5), Position = Vector3.new(-111.5, 4.5, -46),
	Color = YELLOW, Material = Enum.Material.Metal, Parent = pumpArm })
part({ Name = "Counterweight", Size = Vector3.new(2, 2, 2), Position = Vector3.new(-101, 5.5, -46),
	Color = DARK, Material = Enum.Material.Metal, Parent = pumpArm })
pumpArm.WorldPivot = CFrame.new(-106, 5.5, -46) -- точка, навколо якої гойдається

-- Сховище RP-1
cylinder("StorageTank", 14, 10, Vector3.new(-90, 8, -70), WHITE, Enum.Material.Metal, rig)
cylinder("TankRoof", 0.6, 10.6, Vector3.new(-90, 15.3, -70), RED, Enum.Material.Metal, rig)

-- Завод (refinery) з трубою і димом
part({ Name = "Refinery", Size = Vector3.new(8, 6, 6), Position = Vector3.new(-93, 4, -50),
	Color = Color3.fromRGB(110, 120, 130), Material = Enum.Material.Metal, Parent = rig })
local chimney = cylinder("Chimney", 20, 3, Vector3.new(-86, 11, -50), Color3.fromRGB(90, 90, 95), Enum.Material.Metal, rig)
local smokePoint = Instance.new("Attachment")
smokePoint.Name = "SmokePoint"
smokePoint.Position = Vector3.new(10, 0, 0) -- верх труби (локальна вісь X дивиться вгору)
smokePoint.Parent = chimney
local smoke = Instance.new("ParticleEmitter")
smoke.Name = "Smoke"
smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
smoke.EmissionDirection = Enum.NormalId.Right
smoke.Color = ColorSequence.new(Color3.fromRGB(170, 170, 170))
smoke.Size = NumberSequence.new(2, 7)
smoke.Transparency = NumberSequence.new(0.4, 1)
smoke.Lifetime = NumberRange.new(4, 6)
smoke.Rate = 6
smoke.Speed = NumberRange.new(3, 5)
smoke.SpreadAngle = Vector2.new(15, 15)
smoke.Acceleration = Vector3.new(0.5, 1, 0)
smoke.Parent = smokePoint

-- Пульт керування (дивиться в бік ангару, +X)
local panel = part({ Name = "ControlPanel", Size = Vector3.new(1, 5, 4), Position = Vector3.new(-82, 3.5, -60),
	Color = DARK, Material = Enum.Material.Metal, Parent = rig })
sign(panel, Enum.NormalId.Right, "НАФТОВА ВИШКА\n[E] керувати", Color3.new(1, 1, 1), GREEN)
local prompt = Instance.new("ProximityPrompt")
prompt.ActionText = "Керувати"
prompt.ObjectText = "Нафтова вишка"
prompt.KeyboardKeyCode = Enum.KeyCode.E
prompt.HoldDuration = 0
prompt.MaxActivationDistance = 12
prompt.RequiresLineOfSight = false
prompt.Parent = panel

--------------------------------------------------------------------
-- 4. СТАРТОВИЙ МАЙДАНЧИК (перед ангаром, знадобиться в кроці 4)
--------------------------------------------------------------------
local launchPad = freshModel("LaunchPad", workspace)
local padDisc = cylinder("Pad", 2, 40, Vector3.new(0, 1, 110), CONCRETE, Enum.Material.Concrete, launchPad)
launchPad.PrimaryPart = padDisc
part({ Name = "Tower", Size = Vector3.new(3, 40, 3), Position = Vector3.new(16, 22, 110),
	Color = RED, Material = Enum.Material.Metal, Parent = launchPad })
part({ Name = "LaunchPoint", Size = Vector3.new(2, 2, 2), Position = Vector3.new(0, 4, 110),
	Transparency = 1, CanCollide = false, Parent = launchPad })

--------------------------------------------------------------------
-- 5. STREAMING: ці моделі завжди завантажені в гравця повністю
--    (StreamingEnabled лишається увімкненим — знадобиться для далеких планет)
--------------------------------------------------------------------
for _, model in ipairs({ building, rig, launchPad }) do
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
end

print("✅ Крок 2: ангар, нафтова вишка і стартовий майданчик побудовані.")
