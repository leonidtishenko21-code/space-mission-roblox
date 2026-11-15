--[[
	SetupPlanets_Step6.lua — одноразовий скрипт для Studio (Edit), у Studio не зберігається.
	Планетарні зони з моделей Blender (друга партія):
	  1. Дублікати та обгортки "Scene" → ServerStorage/_ImportBackup (нічого не видаляє).
	  2. Фарбування нових моделей (після імпорту всі сірі).
	  3. Місяць: MoonZone (кратер) зсувається далі вбік (z ≈ 2710, щоб Місяць не перекривав вертикальний
	     старт), під кратером — Planet_Moon_Globe Ø2000: кратер стає ділянкою поверхні Місяця.
	  4. Марс: MarsZone — Mars_Canyon_Zone ×12 на висоті 200 км (16 000 studs), x = 3200;
	     під ним Planet_Mars_Globe Ø2400; у каньйоні — Lost_Rover_Target.
	  5. Декор: Orbital_Gateway_Node біля Місяця (як Lunar Gateway), Asteroid_Target на шляху до Марса.
	  Атрибути зон (читає PlanetZoneManager): Planet, GlobeCenter, GlobeRadius, Center, FloorY, Radius.

	⚠ Як це фактично виконано в Studio 2026-11-14 (place v39), відмінності від коду нижче:
	  • меші глобусів БЕЗ колізії (CanCollide/CanQuery = false); замість них невидима куля Part
	    "GlobeCollider" (Ball, Ø = 2·GlobeRadius) — точна колізія на мешах Ø2000+ вішала Studio.
	  • MARS_R = 1020 (куля Part не може бути більшою за 2048 studs); глобус Марса повернутий
	    CFrame.Angles(-90°, 0, 0), щоб полярна шапка не опинилася під посадковою ділянкою.
	  • ровер: (P.X + 95, поверхня, P.Z − 112); "каньйон" у цій моделі мілкий — шар Cliffs
	    накриває CanyonFloor, тому висоти брали променем.
	  • LandingPad: циліндр Ø74 на висоті центру + 0.1; MarsZone.Center/FloorY = поверхня в центрі (y ≈ 16033.2).
	  • Виконувалось частинами (дублікати → Місяць → Марс → ровер/мітки), щоб Studio не зависав.
]]

local ServerStorage = game:GetService("ServerStorage")
local C = Color3.fromRGB
local M = Enum.Material

local backup = ServerStorage:FindFirstChild("_ImportBackup")
local planets = workspace:WaitForChild("Planets")
local moonZone = planets:WaitForChild("MoonZone")

--------------------------------------------------------------------
-- 1. Дублікати
--------------------------------------------------------------------
local NEW = { "Planet_Moon_Globe", "Planet_Mars_Globe", "Mars_Canyon_Zone", "Lost_Rover_Target", "Asteroid_Target", "Orbital_Gateway_Node" }
local keep = {}
for _, c in ipairs(workspace:GetChildren()) do
	local first = c:IsA("Model") and c:GetChildren()[1]
	local isScene = c.Name == "Scene" and first and first.Name:match("_Node$")
	local isImport = c:IsA("Model") and c:FindFirstChild(c.Name .. "_Root") ~= nil
	if isScene then
		c.Parent = backup
	elseif isImport then
		if table.find(NEW, c.Name) and not keep[c.Name] then
			keep[c.Name] = c
		else
			c.Parent = backup -- повторний імпорт старих моделей (кратер, каміння, супутник…)
		end
	end
end
local function find(name)
	return keep[name] or planets:FindFirstChild(name, true)
end

--------------------------------------------------------------------
-- 2. Кольори
--------------------------------------------------------------------
local PAINT = {
	Planet_Moon_Globe = { Highlands = { C(185, 185, 188), M.Slate }, Maria = { C(105, 105, 112), M.Slate }, BrightCraters = { C(225, 225, 228), M.Slate } },
	Planet_Mars_Globe = { Surface = { C(200, 105, 60), M.Sand }, Canyons = { C(140, 65, 40), M.Sandstone },
		DarkRegions = { C(130, 65, 42), M.Sand }, PolarCaps = { C(240, 240, 245), M.Snow } },
	Mars_Canyon_Zone = { Ground = { C(198, 120, 75), M.Sand }, CanyonFloor = { C(165, 90, 55), M.Sandstone },
		Cliffs = { C(150, 80, 50), M.Sandstone }, Dunes = { C(225, 175, 125), M.Sand }, Boulders = { C(125, 70, 45), M.Slate },
		PadMarkers = { C(235, 235, 235), M.SmoothPlastic }, PadLights = { C(255, 70, 50), M.Neon } },
	Lost_Rover_Target = { Body = { C(235, 235, 235), M.SmoothPlastic }, Deck = { C(60, 62, 68), M.Metal },
		SolarCells = { C(30, 50, 125), M.Glass }, Wheels = { C(45, 45, 50), M.Metal }, Suspension = { C(175, 175, 180), M.Metal },
		Mast = { C(175, 175, 180), M.Metal }, CameraHead = { C(235, 235, 235), M.SmoothPlastic }, Lenses = { C(40, 70, 130), M.Glass },
		Antenna = { C(230, 230, 230), M.Metal }, Beacon = { C(255, 50, 40), M.Neon }, RTG = { C(70, 72, 78), M.Metal },
		Reflector = { C(225, 165, 45), M.Metal } },
	Asteroid_Target = { Rock = { C(105, 100, 96), M.Slate }, IceVein1 = { C(150, 225, 240), M.Ice }, IceVein2 = { C(150, 225, 240), M.Ice },
		OreVein = { C(200, 160, 60), M.Metal } },
	Orbital_Gateway_Node = { Hull = { C(235, 235, 235), M.SmoothPlastic }, Bands = { C(45, 47, 52), M.Metal },
		Windows = { C(50, 100, 170), M.Glass }, SolarCells = { C(30, 50, 125), M.Glass }, SolarFrame = { C(150, 150, 155), M.Metal },
		Radiators = { C(230, 230, 230), M.SmoothPlastic }, RadiatorLines = { C(150, 150, 155), M.Metal },
		DockingRing = { C(160, 160, 165), M.Metal }, Thrusters = { C(55, 55, 60), M.Metal }, Handrails = { C(225, 165, 45), M.Metal },
		Antenna = { C(200, 200, 205), M.Metal } },
}
-- precise = точна колізія (PreciseConvexDecomposition). ЛИШЕ для посадкових ділянок:
-- на гігантських глобусах її перерахунок вішає Studio на десятки хвилин (перевірено).
local function prep(m, scale, collide, precise)
	m:ScaleTo(scale)
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			local short = p.Name:gsub("^" .. m.Name .. "_", "")
			if short == "Root" then
				p.Transparency = 1
				p.CanCollide = false
				p.CanQuery = false
			else
				local rule = PAINT[m.Name] and PAINT[m.Name][short]
				if rule then
					p.Color = rule[1]
					p.Material = rule[2]
				end
				p.CanCollide = collide ~= false
				if precise and collide ~= false and p:IsA("MeshPart") then
					p.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
				end
			end
		end
	end
	m.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
end

local function marker(parent, pos, text, color)
	local part = parent:FindFirstChild("ZoneMarker") or Instance.new("Part")
	part.Name = "ZoneMarker"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = pos
	part.Parent = parent
	part:ClearAllChildren()
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(260, 50)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 100000
	bb.Parent = part
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = text
	tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.3
	tl.Font = Enum.Font.GothamBold
	tl.TextSize = 20
	tl.Parent = bb
	return part
end

local function disc(folder, name, xz, topY, diameter)
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
	p.Parent = folder
	return p
end

local function rayDown(model, x, z, fromY)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	return workspace:Raycast(Vector3.new(x, fromY, z), Vector3.new(0, -2000, 0), params)
end

--------------------------------------------------------------------
-- 3. Місяць
--------------------------------------------------------------------
local MOON_Z = 2710
local oldCenter = moonZone:GetAttribute("Center")
if math.abs(oldCenter.Z - MOON_Z) > 1 then
	local shift = Vector3.new(0, 0, MOON_Z - oldCenter.Z)
	moonZone:PivotTo(moonZone:GetPivot() + shift)
	moonZone:SetAttribute("Center", oldCenter + shift)
end
local moonCenter = moonZone:GetAttribute("Center")
local crater = moonZone:FindFirstChild("Lunar_Crater_Rim")
local craterBottom = crater:GetPivot().Position.Y
local MOON_R = 1000
local moonGlobe = find("Planet_Moon_Globe")
prep(moonGlobe, MOON_R * 2 / 30)
moonGlobe.Parent = moonZone
-- верх сфери на 2 studs вище низу кратера: кратер "вростає" в поверхню Місяця
local moonGlobeCenter = Vector3.new(moonCenter.X, craterBottom + 2 - MOON_R, moonCenter.Z)
moonGlobe:PivotTo(CFrame.new(moonGlobeCenter) * CFrame.Angles(math.rad(-90), 0, 0)) -- темні "моря" дивляться вгору
moonZone:SetAttribute("Planet", "Moon")
moonZone:SetAttribute("GlobeCenter", moonGlobeCenter)
moonZone:SetAttribute("GlobeRadius", MOON_R)
local moonMarker = moonZone:FindFirstChild("ZoneMarker")
if moonMarker then
	moonMarker:ClearAllChildren()
end
marker(moonZone, moonCenter + Vector3.new(0, 40, 0), "🌕 Місяць · кратер", C(240, 190, 40))

local gateway = find("Orbital_Gateway_Node")
prep(gateway, 4)
gateway.Parent = moonZone
gateway:PivotTo(CFrame.new(moonCenter + Vector3.new(-350, 450, -300)) * CFrame.Angles(0, math.rad(35), math.rad(10)))

--------------------------------------------------------------------
-- 4. Марс
--------------------------------------------------------------------
local launchSurface = workspace.LaunchPad:FindFirstChild("LaunchSurface")
local surfaceTop = launchSurface.Position.Y + launchSurface.Size.Y / 2
local MARS_POS = Vector3.new(3200, surfaceTop + 16000, 110) -- 200 км над стартом, 40 км убік
local CANYON_SCALE = 12
local MARS_R = 1200

local marsZone = planets:FindFirstChild("MarsZone") or Instance.new("Model")
marsZone.Name = "MarsZone"
marsZone.Parent = planets
marsZone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

local canyon = find("Mars_Canyon_Zone")
prep(canyon, CANYON_SCALE, true, true)
canyon.Parent = marsZone
canyon:PivotTo(CFrame.new(MARS_POS))

local marsGlobe = find("Planet_Mars_Globe")
prep(marsGlobe, MARS_R * 2 / 30)
marsGlobe.Parent = marsZone
local marsGlobeCenter = Vector3.new(MARS_POS.X, MARS_POS.Y + 2 - MARS_R, MARS_POS.Z)
marsGlobe:PivotTo(CFrame.new(marsGlobeCenter))

-- посадковий майданчик у центрі (білі мітки): висота поверхні — променем
local padHit = rayDown(canyon, MARS_POS.X, MARS_POS.Z, MARS_POS.Y + 300)
local padY = padHit and padHit.Position.Y or (MARS_POS.Y + 2.1 * CANYON_SCALE)
local colliders = marsZone:FindFirstChild("LandingColliders") or Instance.new("Folder")
colliders.Name = "LandingColliders"
colliders.Parent = marsZone
colliders:ClearAllChildren()
disc(colliders, "LandingPad", MARS_POS, padY + 0.1, 6.2 * CANYON_SCALE)

-- ровер ховається на дні каньйону (смуга CanyonFloor на −Z від центру)
local rover = find("Lost_Rover_Target")
prep(rover, 3)
rover.Parent = marsZone
local roverX, roverZ = MARS_POS.X + 95, MARS_POS.Z - 9.3 * CANYON_SCALE
local roverHit = rayDown(canyon, roverX, roverZ, MARS_POS.Y + 300)
rover:PivotTo(CFrame.new(roverX, roverHit and roverHit.Position.Y or MARS_POS.Y, roverZ) * CFrame.Angles(0, math.rad(-35), 0))
local beacon = rover:FindFirstChild("Lost_Rover_Target_Beacon")
if beacon and not beacon:FindFirstChild("RoverLight") then
	local light = Instance.new("PointLight")
	light.Name = "RoverLight"
	light.Color = C(255, 60, 50)
	light.Range = 20
	light.Brightness = 2
	light.Enabled = false
	light.Parent = beacon
end

marker(marsZone, Vector3.new(MARS_POS.X, padY + 50, MARS_POS.Z), "🔴 Марс · каньйон", C(255, 150, 90))
marsZone:SetAttribute("Planet", "Mars")
marsZone:SetAttribute("GlobeCenter", marsGlobeCenter)
marsZone:SetAttribute("GlobeRadius", MARS_R)
marsZone:SetAttribute("Center", Vector3.new(MARS_POS.X, padY, MARS_POS.Z))
marsZone:SetAttribute("FloorY", padY)
marsZone:SetAttribute("Radius", 15 * CANYON_SCALE)
marsZone.PrimaryPart = marsZone:FindFirstChild("ZoneMarker")

-- Астероїд на шляху до Марса (з ним можна зіткнутися!)
local asteroid = find("Asteroid_Target")
prep(asteroid, 6)
asteroid.Parent = planets
asteroid:PivotTo(CFrame.new(1500, surfaceTop + 10500, 600) * CFrame.Angles(math.rad(20), math.rad(40), 0))

return string.format("moon center=%s globe=%s | mars pad=%.1f globe=%s rover=%s | backup=%d",
	tostring(moonCenter), tostring(moonGlobeCenter), padY, tostring(marsGlobeCenter), tostring(rover:GetPivot().Position), #backup:GetChildren())
