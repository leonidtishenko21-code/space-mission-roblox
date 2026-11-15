--[[
	SetupAssets_Step5.lua — одноразовий скрипт для Studio (Edit / Command Bar), у Studio не зберігається.
	Що робить з моделями, імпортованими з Blender у Workspace:
	  1. Залишає по ОДНІЙ копії кожної моделі; дублікати й обгортки "Scene" переносить
	     у ServerStorage/_ImportBackup (нічого не видаляє).
	  2. Фарбує деталі за назвами (після імпорту всі сірі): FrameRed → червоний, Cells → сині панелі тощо.
	  3. Деталі ракети → ServerStorage/RocketParts (префаби): Anchored, без колізій, Massless,
	     атрибути BoxMin/BoxMax/RefDiameter + Attachment BottomMount/TopMount (+ NozzlePoint у двигунів).
	     Масу/тягу НЕ дублюємо в атрибути: єдине джерело чисел — NASAData.
	  4. Інфраструктура: Launch_Table + Launch_Tower + Ground_LOX_Tanks на LaunchPad,
	     Hangar_Gantry_Crane в ангарі, Lunar_Crater_Rim + маяки + лід + каміння → Planets/MoonZone.
	Повторний запуск безпечний: шукає моделі і в Workspace, і там, куди їх уже переніс.
]]

local ServerStorage = game:GetService("ServerStorage")
local PhysicsService = game:GetService("PhysicsService")
local C = Color3.fromRGB
local M = Enum.Material

--------------------------------------------------------------------
-- 0. Групи зіткнень
--------------------------------------------------------------------
for _, g in ipairs({ "Rocket", "RocketDebris", "LaunchStructure" }) do
	if not PhysicsService:IsCollisionGroupRegistered(g) then
		PhysicsService:RegisterCollisionGroup(g)
	end
end
PhysicsService:CollisionGroupSetCollidable("Rocket", "RocketDebris", false)
PhysicsService:CollisionGroupSetCollidable("RocketDebris", "RocketDebris", false)
PhysicsService:CollisionGroupSetCollidable("LaunchStructure", "Rocket", false)
PhysicsService:CollisionGroupSetCollidable("LaunchStructure", "RocketDebris", false)

local function folder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end
local backup = folder(ServerStorage, "_ImportBackup")
local rocketParts = folder(ServerStorage, "RocketParts")

--------------------------------------------------------------------
-- 1. По одній копії кожної моделі
--------------------------------------------------------------------
local keep = {}
local function isImported(m)
	return m:IsA("Model") and m:FindFirstChild(m.Name .. "_Root") ~= nil
end
local function isScene(m)
	local first = m:IsA("Model") and m.Name == "Scene" and m:GetChildren()[1]
	return first and first.Name:match("_Node$") ~= nil
end
for _, c in ipairs(workspace:GetChildren()) do
	if isScene(c) then
		c.Parent = backup
	elseif isImported(c) then
		if keep[c.Name] then
			c.Parent = backup
		else
			keep[c.Name] = c
		end
	end
end
-- повторний запуск: моделі вже могли бути перенесені
local function find(name)
	if keep[name] then
		return keep[name]
	end
	local m = rocketParts:FindFirstChild(name) or workspace:FindFirstChild(name, true)
	keep[name] = m
	return m
end

--------------------------------------------------------------------
-- 2. Кольори за назвами деталей
--------------------------------------------------------------------
local WHITE, DARK, METAL_DARK = C(235, 235, 235), C(42, 44, 50), C(60, 62, 68)
local SILVER, GOLD, YELLOW = C(175, 175, 180), C(225, 165, 45), C(240, 190, 30)
local OVERRIDES = { -- повна назва → { колір, матеріал }
	Hangar_Gantry_Crane_Legs = { YELLOW, M.Metal }, Hangar_Gantry_Crane_Bridge = { YELLOW, M.Metal },
	Hangar_Gantry_Crane_Hook = { YELLOW, M.Metal }, Sci_IceDrill_Frame = { YELLOW, M.Metal },
	Capsule_Mercury_Body = { DARK, M.Metal }, Capsule_Mercury_Details = { DARK, M.Metal },
	Capsule_Mercury_Canister = { DARK, M.Metal },
	Capsule_Dragon_ThrusterPods = { DARK, M.Metal }, Capsule_Dragon_BaseBand = { C(60, 50, 45), M.Metal },
	Decoupler_Interstage_Shell = { C(38, 38, 42), M.SmoothPlastic }, Decoupler_Interstage_Rings = { C(70, 70, 75), M.Metal },
	Orbital_Relay_Sat_Bus = { C(215, 165, 60), M.Foil },
	Launch_Tower_Platforms = { DARK, M.Metal }, Launch_Tower_Hinge = { DARK, M.Metal }, Launch_Tower_Cables = { DARK, M.Metal },
	Ground_LOX_Tanks_Legs = { DARK, M.Metal },
	Sci_LaserTheodolite_Yoke = { WHITE, M.SmoothPlastic }, Sci_LaserTheodolite_Head = { WHITE, M.SmoothPlastic },
	Launch_Table_Deflector = { C(90, 90, 95), M.Concrete },
}
local RULES = { -- перше збігання за фрагментом назви
	{ "WindowFrames", DARK, M.Metal }, { "Window", C(60, 110, 170), M.Glass }, { "LidarGlass", C(40, 90, 150), M.Glass },
	{ "Lens", C(50, 100, 170), M.Glass }, { "Cells", C(30, 50, 125), M.Glass }, { "Panels", C(30, 50, 125), M.Glass },
	{ "HazardYellow", YELLOW, M.SmoothPlastic }, { "HazardBlack", C(30, 30, 32), M.SmoothPlastic },
	{ "FrameRed", C(200, 45, 40), M.Metal }, { "FrameWhite", WHITE, M.Metal }, { "EscapeTower", C(210, 50, 40), M.Metal },
	{ "MarkersRed", C(225, 40, 40), M.Neon }, { "MarkersWhite", C(240, 240, 240), M.SmoothPlastic },
	{ "NavLights", C(255, 60, 60), M.Neon }, { "Emitter", C(220, 50, 40), M.SmoothPlastic },
	{ "Ice", C(170, 215, 240), M.Ice }, { "HeatShield", C(120, 75, 45), M.SmoothPlastic },
	{ "Pump", GOLD, M.Metal }, { "Manifold", GOLD, M.Metal }, { "Feed", GOLD, M.Metal }, { "Valves", YELLOW, M.Metal },
	{ "Nozzle", C(55, 55, 60), M.Metal }, { "Rings", C(120, 120, 125), M.Metal }, { "Chamber", C(75, 75, 80), M.Metal },
	{ "Pipes", SILVER, M.Metal }, { "Exhaust", SILVER, M.Metal }, { "Cables", SILVER, M.Metal }, { "Auger", SILVER, M.Metal },
	{ "Bit", SILVER, M.Metal }, { "Hinge", SILVER, M.Metal }, { "Struts", SILVER, M.Metal }, { "Rails", SILVER, M.Metal },
	{ "Ladders", SILVER, M.Metal },
	{ "Concrete", C(190, 190, 185), M.Concrete }, { "Pad", C(190, 190, 185), M.Concrete },
	{ "Leg", DARK, M.Metal }, { "Stripes", C(35, 35, 40), M.SmoothPlastic }, { "Band", C(35, 35, 40), M.SmoothPlastic },
	{ "Flanges", C(205, 205, 210), M.Metal }, { "Ribs", C(200, 200, 205), M.SmoothPlastic }, { "Stringers", C(200, 200, 205), M.Metal },
	{ "Steel", METAL_DARK, M.Metal }, { "Deflector", METAL_DARK, M.Metal }, { "Mount", METAL_DARK, M.Metal },
	{ "Clamp", METAL_DARK, M.Metal }, { "Base", METAL_DARK, M.Metal }, { "Housing", C(200, 200, 205), M.Metal },
	{ "Motor", METAL_DARK, M.Metal }, { "Trolley", METAL_DARK, M.Metal }, { "Winch", METAL_DARK, M.Metal },
	{ "Wheels", METAL_DARK, M.Metal }, { "Platforms", METAL_DARK, M.Metal }, { "Adapter", METAL_DARK, M.Metal },
	{ "Latches", C(150, 150, 155), M.Metal }, { "GridFin", METAL_DARK, M.Metal }, { "Yoke", METAL_DARK, M.Metal },
	{ "Head", METAL_DARK, M.Metal }, { "Mast", C(150, 150, 155), M.Metal }, { "Lidar", C(150, 150, 155), M.Metal },
	{ "SwingArm", C(200, 45, 40), M.Metal }, { "Frame", C(150, 150, 155), M.Metal },
	{ "RocksLight", C(178, 178, 180), M.Slate }, { "RockLight", C(178, 178, 180), M.Slate },
	{ "Rocks", C(118, 118, 122), M.Slate }, { "Rock", C(140, 140, 144), M.Slate }, { "Ground", C(160, 160, 162), M.Slate },
	{ "Shell", WHITE, M.SmoothPlastic }, { "Body", WHITE, M.SmoothPlastic }, { "NoseCone", WHITE, M.SmoothPlastic },
	{ "Tanks", WHITE, M.SmoothPlastic }, { "Dish", WHITE, M.SmoothPlastic }, { "DockingPort", C(200, 200, 205), M.Metal },
	{ "Hook", METAL_DARK, M.Metal },
}
local function paint(model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			if p.Name:match("_Root$") then
				p.Transparency = 1
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			else
				local rule = OVERRIDES[p.Name]
				if not rule then
					local short = p.Name:gsub("^" .. model.Name .. "_", "")
					for _, r in ipairs(RULES) do
						if short:find(r[1], 1, true) then
							rule = { r[2], r[3] }
							break
						end
					end
				end
				if rule then
					p.Color = rule[1]
					p.Material = rule[2]
				end
			end
		end
	end
end
for _, m in pairs(keep) do
	paint(m)
end

--------------------------------------------------------------------
-- 3. Префаби деталей ракети
--------------------------------------------------------------------
local ROCKET_TEMPLATES = {
	"Tank_Stage1", "Tank_Stage2", "Decoupler_Interstage", "Adapter_Cone", "Fairing_Half",
	"Capsule_Mercury", "Capsule_Dragon", "Engine_Rutherford", "Engine_Merlin1D", "Engine_F1",
	"Thruster_RCS_Draco", "Sci_LaserTheodolite", "Sci_TerrainScanner", "Sci_IceDrill",
	"Power_SolarPanel", "Comm_HighGainAntenna",
}
local function bounds(model)
	local pv = model:GetPivot().Position
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and not p.Name:match("_Root$") then
			local h = p.Size / 2
			lo = lo:Min(p.Position - h - pv)
			hi = hi:Max(p.Position + h - pv)
		end
	end
	return lo, hi
end
for _, name in ipairs(ROCKET_TEMPLATES) do
	local m = find(name)
	if m then
		m.Parent = rocketParts
		m:PivotTo(CFrame.new())
		for _, p in ipairs(m:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.Massless = true
				p.CollisionGroup = "Rocket"
			end
		end
		local lo, hi = bounds(m)
		m:SetAttribute("BoxMin", lo)
		m:SetAttribute("BoxMax", hi)
		-- діаметр "корпусу" (без труб і опор): за деталлю Body/Shell, якщо є
		local ref = math.max(hi.X - lo.X, hi.Z - lo.Z)
		for _, p in ipairs(m:GetChildren()) do
			if p:IsA("BasePart") and (p.Name:match("_Body$") or p.Name:match("_Shell$") or p.Name:match("_Nozzle$")) then
				ref = math.max(p.Size.X, p.Size.Z)
				break
			end
		end
		m:SetAttribute("RefDiameter", ref)
		local root = m:FindFirstChild(name .. "_Root")
		for _, a in ipairs(root:GetChildren()) do
			if a:IsA("Attachment") then
				a:Destroy()
			end
		end
		local function mount(n, pos, down)
			local a = Instance.new("Attachment")
			a.Name = n
			a.Parent = root
			a.WorldCFrame = CFrame.new(pos) * (down and CFrame.Angles(math.pi, 0, 0) or CFrame.identity)
		end
		local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
		mount("BottomMount", Vector3.new(cx, lo.Y, cz))
		mount("TopMount", Vector3.new(cx, hi.Y, cz))
		if name:match("^Engine_") then
			mount("NozzlePoint", Vector3.new(0, lo.Y, 0), true)
		end
	end
end

--------------------------------------------------------------------
-- 4. Інфраструктура
--------------------------------------------------------------------
local function prep(m, scale, group, collide)
	if m:GetScale() ~= 1 then
		m:ScaleTo(1)
	end
	m:ScaleTo(scale)
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			if not p.Name:match("_Root$") then
				p.CanCollide = collide ~= false
			end
			if group then
				p.CollisionGroup = group
			end
		end
	end
	m.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
end

local launchPad = workspace:WaitForChild("LaunchPad")
local pad = launchPad:FindFirstChild("Pad")
local halfY = 0.5 * (math.abs(pad.CFrame.RightVector.Y) * pad.Size.X + math.abs(pad.CFrame.UpVector.Y) * pad.Size.Y
	+ math.abs(pad.CFrame.LookVector.Y) * pad.Size.Z)
local padTop = pad.Position.Y + halfY
local center = Vector3.new(pad.Position.X, padTop, pad.Position.Z)
local oldTower = launchPad:FindFirstChild("Tower")
if oldTower then
	oldTower.Parent = backup
end

-- Стартовий стіл (×3): вежа збоку (+X), газовідвідний жолоб відкривається на −X
local TABLE_SCALE = 3
local ROT = CFrame.Angles(0, -math.pi / 2, 0)
local launchTable = find("Launch_Table")
prep(launchTable, TABLE_SCALE, "LaunchStructure")
launchTable.Parent = launchPad
launchTable:PivotTo(CFrame.new(center) * ROT)
local surfaceTop = padTop + 3.03 * TABLE_SCALE

-- Невидима опора для ракети (меші столу з ракетою не стикаються)
local surface = launchPad:FindFirstChild("LaunchSurface") or Instance.new("Part")
surface.Name = "LaunchSurface"
surface.Anchored = true
surface.Size = Vector3.new(12, 1, 12)
surface.CFrame = CFrame.new(center.X, surfaceTop - 0.5, center.Z)
surface.Transparency = 1
surface.CanCollide = true
surface.Parent = launchPad
local point = launchPad:FindFirstChild("LaunchPoint")
if point then
	point.Position = Vector3.new(center.X, surfaceTop + 1, center.Z)
	point.Transparency = 1
	point.CanCollide = false
end

-- Пускова вежа (×3) на TowerMount столу; стріли дивляться на ракету
local tower = find("Launch_Tower")
prep(tower, TABLE_SCALE, "LaunchStructure")
tower.Parent = launchPad
local mountPart = launchTable:FindFirstChild("Launch_Table_TowerMount")
local towerBase = Vector3.new(mountPart.Position.X, mountPart.Position.Y + mountPart.Size.Y / 2, mountPart.Position.Z)
local towerPivot = CFrame.new(towerBase) * ROT
tower:PivotTo(towerPivot)
tower:SetAttribute("HomePivot", towerPivot)

-- Баки рідкого кисню поруч зі столом
local lox = find("Ground_LOX_Tanks")
prep(lox, 2.5)
lox.Parent = launchPad
local baseplate = workspace:FindFirstChild("Baseplate")
local groundY = baseplate and (baseplate.Position.Y + baseplate.Size.Y / 2) or 0
lox:PivotTo(CFrame.new(center.X - 34, groundY, center.Z + 8) * CFrame.Angles(0, math.pi / 2, 0))

-- Козловий кран над майданчиком збирання в ангарі
local hangar = workspace:WaitForChild("Hangar")
local crane = find("Hangar_Gantry_Crane")
prep(crane, 1.15)
crane.Parent = hangar
local buildPad = hangar.Building:FindFirstChild("BuildPad")
local floor = hangar.Building:FindFirstChild("Floor")
local floorTop = floor.Position.Y + floor.Size.Y / 2
crane:PivotTo(CFrame.new(buildPad.Position.X, floorTop, buildPad.Position.Z))
for _, n in ipairs({ "Hangar_Gantry_Crane_Cables", "Hangar_Gantry_Crane_Hook", "Hangar_Gantry_Crane_HookBlock" }) do
	local p = crane:FindFirstChild(n)
	if p then
		p.CanCollide = false
	end
end

--------------------------------------------------------------------
-- 5. Зона місячної місії: кратер на висоті 100 км (8000 studs), убік від старту
--------------------------------------------------------------------
local ZONE_ALTITUDE_STUDS = 8000   -- 100 км у масштабі польоту (12.5 м/stud)
local ZONE_OFFSET = Vector3.new(0, 0, 1200) -- 15 км убік, щоб кратер не стояв просто над стартом
local planets = workspace:WaitForChild("Planets")
local zone = planets:FindFirstChild("MoonZone") or Instance.new("Model")
zone.Name = "MoonZone"
zone.Parent = planets
zone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

local CRATER_SCALE = 10
local craterPos = Vector3.new(center.X, surfaceTop + ZONE_ALTITUDE_STUDS, center.Z) + ZONE_OFFSET
local crater = find("Lunar_Crater_Rim")
prep(crater, CRATER_SCALE)
crater.Parent = zone
crater:PivotTo(CFrame.new(craterPos))
local floorY = craterPos.Y + 0.25 * CRATER_SCALE

local beaconSite = find("Target_CraterBeacon")
prep(beaconSite, 5)
beaconSite.Parent = zone
beaconSite:PivotTo(CFrame.new(craterPos.X, floorY + 0.3 * 5, craterPos.Z))

local ice = find("Target_IceDeposit")
prep(ice, 5)
ice.Parent = zone
ice:PivotTo(CFrame.new(craterPos.X + 48, floorY + 0.35 * 5, craterPos.Z + 10) * CFrame.Angles(0, math.rad(20), 0))

-- 3 маяки для лазерної тріангуляції: світні кулі над червоними мітками меша (мітки на ±2.8 від центру)
local beacons = zone:FindFirstChild("Beacons") or Instance.new("Folder")
beacons.Name = "Beacons"
beacons.Parent = zone
beacons:ClearAllChildren()
local bp = beaconSite:GetPivot().Position
for i, off in ipairs({ Vector3.new(2.8, 0, 0), Vector3.new(0, 0, 2.8), Vector3.new(-2.8, 0, 0) }) do
	local b = Instance.new("Part")
	b.Name = "Beacon" .. i
	b.Shape = Enum.PartType.Ball
	b.Size = Vector3.new(2.2, 2.2, 2.2)
	b.Material = M.Neon
	b.Color = C(255, 70, 60)
	b.Anchored = true
	b.CanCollide = false
	b.Position = bp + off * 5 + Vector3.new(0, 1.5 * 5 + 0.6, 0)
	b.Parent = beacons
	local light = Instance.new("PointLight")
	light.Color = C(255, 80, 60)
	light.Range = 30
	light.Brightness = 3
	light.Enabled = false
	light.Parent = b
	local hl = Instance.new("Highlight")
	hl.FillColor = C(255, 90, 60)
	hl.OutlineColor = C(255, 230, 120)
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	hl.Parent = b
end

-- Каміння на валу кратера
local rocks = zone:FindFirstChild("Rocks") or Instance.new("Folder")
rocks.Name = "Rocks"
rocks.Parent = zone
local rockSpots = {
	{ "Surface_Rock_A_Boulder", 4, -70, 40 }, { "Surface_Rock_B_Outcrop", 4, 60, -65 },
	{ "Surface_Rock_C_Spire", 5, -40, -80 }, { "Surface_Rock_D_Scree", 5, 30, 70 },
}
for _, s in ipairs(rockSpots) do
	local r = find(s[1])
	if r then
		prep(r, s[2])
		r.Parent = rocks
		local origin = Vector3.new(craterPos.X + s[3], craterPos.Y + 60, craterPos.Z + s[4])
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { crater }
		local hit = workspace:Raycast(origin, Vector3.new(0, -120, 0), params)
		r:PivotTo(CFrame.new(hit and hit.Position or (origin - Vector3.new(0, 55, 0))) * CFrame.Angles(0, math.rad(s[3]), 0))
	end
end

-- Супутник-ретранслятор над кратером (декорація)
local relay = find("Orbital_Relay_Sat")
if relay then
	prep(relay, 5, nil, false)
	relay.Parent = zone
	relay:PivotTo(CFrame.new(craterPos + Vector3.new(160, 260, -120)) * CFrame.Angles(0, math.rad(30), math.rad(15)))
end

-- Мітка, яку видно здалеку
local markerPart = zone:FindFirstChild("ZoneMarker") or Instance.new("Part")
markerPart.Name = "ZoneMarker"
markerPart.Anchored = true
markerPart.CanCollide = false
markerPart.CanQuery = false
markerPart.Transparency = 1
markerPart.Size = Vector3.one
markerPart.Position = Vector3.new(craterPos.X, floorY + 40, craterPos.Z)
markerPart.Parent = zone
markerPart:ClearAllChildren()
local bb = Instance.new("BillboardGui")
bb.Size = UDim2.fromOffset(240, 50)
bb.AlwaysOnTop = true
bb.MaxDistance = 100000
bb.Parent = markerPart
local tl = Instance.new("TextLabel")
tl.Size = UDim2.fromScale(1, 1)
tl.BackgroundTransparency = 1
tl.Text = "🎯 Місячний кратер"
tl.TextColor3 = C(240, 190, 40)
tl.TextStrokeTransparency = 0.3
tl.Font = Enum.Font.GothamBold
tl.TextSize = 20
tl.Parent = bb

-- Точна колізія для кратера й цілей: з Default вона місцями на 1.6 stud вища за видиме дно
for _, p in ipairs(zone:GetDescendants()) do
	if p:IsA("MeshPart") and p.CanCollide and not p.Name:match("_Root$") then
		p.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
	end
end

-- Невидимі пласкі опори для посадки: колізія великого увігнутого меша кратера нестабільна
-- (ракета повільно "тоне"), тому на рівних ділянках ракета стоїть на простих циліндрах.
-- Висоти виміряні променями: дно кратера рівне до r≈60 studs (+0.05), лід +2.15, вал маяків +2.72.
local colliders = zone:FindFirstChild("LandingColliders") or Instance.new("Folder")
colliders.Name = "LandingColliders"
colliders.Parent = zone
colliders:ClearAllChildren()
local floorCenter = Vector3.new(craterPos.X, floorY, craterPos.Z)
local function disc(name, xz, topY, diameter)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(2, diameter, diameter)
	p.CFrame = CFrame.new(xz.X, topY - 1, xz.Z) * CFrame.Angles(0, 0, math.rad(90))
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true
	p.CanTouch = false
	p.Transparency = 1
	p.Parent = colliders
end
disc("CraterFloor", floorCenter, floorY + 0.1, 120)
disc("IcePad", ice:GetPivot().Position, floorY + 2.25, 36)
disc("BeaconPad", beaconSite:GetPivot().Position, floorY + 2.8, 54)

zone:SetAttribute("Center", Vector3.new(craterPos.X, floorY, craterPos.Z))
zone:SetAttribute("FloorY", floorY)
zone:SetAttribute("Radius", 12.4 * CRATER_SCALE)
zone.PrimaryPart = markerPart

return string.format("OK: padTop=%.2f surfaceTop=%.2f crater=%s floorY=%.1f templates=%d backup=%d",
	padTop, surfaceTop, tostring(craterPos), floorY, #rocketParts:GetChildren(), #backup:GetChildren())
