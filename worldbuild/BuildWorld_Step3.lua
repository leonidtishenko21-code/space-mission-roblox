--[[
	BuildWorld_Step3 — ОДНОРАЗОВИЙ скрипт-будівельник (крок 3: збирання ракети).
	Запускається ОДИН раз у режимі редагування (Edit), НЕ під час Play:
	  • через Claude Code (Roblox_Studio MCP), або
	  • вручну: View → Command Bar → вставити весь код → Enter.

	Що будує:
	  Workspace > Hangar > BuilderConsole — пульт "Конструктор ракети" біля майданчика BuildPad
	  Workspace > Rockets                 — папка, куди сервер ставить зібрані ракети
	  ReplicatedStorage > Remotes         — BuildRocket, FuelRocket, DismantleRocket

	⚠️ Повторний запуск видаляє і будує заново лише BuilderConsole.
	   Ангар (крок 2) не чіпає.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--------------------------------------------------------------------
-- Допоміжні функції (як у BuildWorld_Step2)
--------------------------------------------------------------------
local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		if key ~= "Parent" then
			p[key] = value
		end
	end
	p.Parent = props.Parent
	return p
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

local DARK = Color3.fromRGB(45, 48, 55)
local BLUE = Color3.fromRGB(25, 60, 120)
local YELLOW = Color3.fromRGB(240, 190, 40)

--------------------------------------------------------------------
-- 1. Remotes і папка для ракет
--------------------------------------------------------------------
local remotes = ensureFolder("Remotes", ReplicatedStorage)
ensureRemote("BuildRocket", remotes)
ensureRemote("FuelRocket", remotes)
ensureRemote("DismantleRocket", remotes)
ensureFolder("Rockets", workspace)

--------------------------------------------------------------------
-- 2. Пульт конструктора (ліворуч від майданчика BuildPad, екран дивиться на +X)
--------------------------------------------------------------------
local hangar = workspace:FindFirstChild("Hangar")
assert(hangar, "Не знайдено Workspace > Hangar. Спочатку запусти BuildWorld_Step2.")

local old = hangar:FindFirstChild("BuilderConsole")
if old then
	old:Destroy()
end
local console = Instance.new("Model")
console.Name = "BuilderConsole"
console.Parent = hangar

local stand = part({ Name = "Stand", Size = Vector3.new(3, 3, 6), Position = Vector3.new(-18, 2.5, -64),
	Color = DARK, Material = Enum.Material.Metal, Parent = console })
console.PrimaryPart = stand

local screen = part({ Name = "Screen", Size = Vector3.new(0.4, 3.6, 5.6), Position = Vector3.new(-16.4, 5.8, -64),
	Color = BLUE, Material = Enum.Material.SmoothPlastic, Parent = console })
sign(screen, Enum.NormalId.Right, "КОНСТРУКТОР РАКЕТИ\n[E] відкрити", Color3.new(1, 1, 1), BLUE)

-- жовта смуга на стійці
part({ Name = "Stripe", Size = Vector3.new(0.1, 0.4, 6), Position = Vector3.new(-16.45, 3.6, -64),
	Color = YELLOW, Material = Enum.Material.SmoothPlastic, Parent = console })

local prompt = Instance.new("ProximityPrompt")
prompt.ActionText = "Відкрити"
prompt.ObjectText = "Конструктор ракети"
prompt.KeyboardKeyCode = Enum.KeyCode.E
prompt.HoldDuration = 0
prompt.MaxActivationDistance = 12
prompt.RequiresLineOfSight = false
prompt.Parent = screen

--------------------------------------------------------------------
-- 3. Streaming: пульт завжди завантажений у гравця
--------------------------------------------------------------------
console.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

print("✅ Крок 3: пульт конструктора, папка Rockets і remotes готові.")
