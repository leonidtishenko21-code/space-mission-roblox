--[[
	SetupSpace_Step7.lua — одноразовий скрипт для Studio (Edit), у Studio не зберігається.
	"Гарний космос":
	  1. ReplicatedStorage/SpaceSky — зоряний скайбокс (текстури згенеровані tools/make_space_skybox.ps1,
	     завантажені в Roblox). EnvironmentManager на клієнті вмикає його вище ~60 км замість денного неба:
	     небо чорне із зорями й туманностями, а Сонце світить (не ніч, як було раніше).
	  2. Workspace/EarthSurface — "Земля" навколо космодрому, щоб з орбіти під ракетою була планета,
	     а не сірий квадрат у порожнечі: зелений пояс навколо Baseplate, океан до горизонту, материки, хмари.
	     Хмари — лише далеко від космодрому (не висять над ангаром), без колізій.
	  Повторний запуск перебудовує EarthSurface з тим самим seed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local C = Color3.fromRGB

-- 1. Зоряний скайбокс
local SKY = {
	SkyboxBk = "rbxassetid://126135769716206",
	SkyboxDn = "rbxassetid://109176878579156",
	SkyboxFt = "rbxassetid://94229788425476",
	SkyboxLf = "rbxassetid://92070408615023",
	SkyboxRt = "rbxassetid://135278797048518",
	SkyboxUp = "rbxassetid://133832901191312",
}
local spaceSky = ReplicatedStorage:FindFirstChild("SpaceSky") or Instance.new("Sky")
spaceSky.Name = "SpaceSky"
for k, v in pairs(SKY) do
	spaceSky[k] = v
end
spaceSky.StarCount = 0               -- зорі вже намальовані на текстурах
spaceSky.CelestialBodiesShown = true -- Сонце видно
spaceSky.SunAngularSize = 14
spaceSky.MoonAngularSize = 0
spaceSky.Parent = ReplicatedStorage

-- 2. Земля навколо космодрому
-- Model (а не Folder): ModelStreamingMode = Persistent, інакше стрімінг сховає далекі плитки
local earth = workspace:FindFirstChild("EarthSurface") or Instance.new("Model")
earth.Name = "EarthSurface"
earth.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
earth.Parent = workspace
earth:ClearAllChildren()
local TILE = 2048
local function block(name, size, pos, color, material, transparency, collide)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = pos
	p.Color = color
	p.Material = material
	p.Transparency = transparency or 0
	p.CanCollide = collide ~= false
	p.CanQuery = collide ~= false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = earth
	return p
end
local rnd = Random.new(2026)
for ix = -4, 4 do
	for iz = -4, 4 do
		if not (ix == 0 and iz == 0) then -- у центрі — Baseplate космодрому
			local nearBase = math.abs(ix) <= 1 and math.abs(iz) <= 1
			local pos = Vector3.new(ix * TILE, -2.5, iz * TILE)
			if nearBase then
				block("Land", Vector3.new(TILE, 4, TILE), pos + Vector3.new(0, 0.4, 0), C(88, 128, 70), Enum.Material.Grass)
			else
				block("Ocean", Vector3.new(TILE, 4, TILE), pos, C(28, 78, 150), Enum.Material.SmoothPlastic)
			end
		end
	end
end
-- материки й острови на океані
for i = 1, 26 do
	local x, z = rnd:NextNumber(-9000, 9000), rnd:NextNumber(-9000, 9000)
	if math.max(math.abs(x), math.abs(z)) > 3300 then
		local w, d = rnd:NextNumber(600, 2000), rnd:NextNumber(500, 1800)
		local green = rnd:NextNumber() < 0.7
		block("Continent", Vector3.new(w, 4, d), Vector3.new(x, -2.0, z),
			green and C(80, 120, 65) or C(190, 165, 115), green and Enum.Material.Grass or Enum.Material.Sand)
	end
end
-- хмари: напівпрозорі пласкі "плями" на висоті 8–11 км (650–900 studs), далеко від космодрому
for i = 1, 70 do
	local x, z = rnd:NextNumber(-9000, 9000), rnd:NextNumber(-9000, 9000)
	if math.max(math.abs(x), math.abs(z)) > 2600 then
		block("Cloud", Vector3.new(rnd:NextNumber(250, 900), rnd:NextNumber(8, 20), rnd:NextNumber(200, 700)),
			Vector3.new(x, rnd:NextNumber(650, 900), z), C(245, 245, 250), Enum.Material.SmoothPlastic, 0.25, false)
	end
end
return "SpaceSky + EarthSurface: " .. #earth:GetChildren() .. " parts"
