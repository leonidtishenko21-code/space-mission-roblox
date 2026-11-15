--[[
	PlanetZoneManager (ModuleScript, СПІЛЬНИЙ — сервер і клієнт)
	Місце: ReplicatedStorage > Modules > PlanetZoneManager

	Планетарні зони (Workspace > Planets > MoonZone / MarsZone). Кожна зона — це великий глобус
	(орієнтир у космосі) і посадкова ділянка на його верхівці (кратер / каньйон).
	Атрибути зони: Planet ("Moon"/"Mars"), GlobeCenter, GlobeRadius, Center, FloorY.

	Вплив планети f = 0…1 залежить від висоти над поверхнею глобуса:
	  ближче INNER — повне тяжіння планети, далі OUTER — земне, між ними плавний перехід.
	Це УМОВНІ зони для гри: справжній Місяць за 384 400 км, Марс — за десятки мільйонів км.

	Напрямок "вниз" лишається −Y скрізь: тому сідати і ходити можна лише на верхівці глобуса
	(там і стоїть ділянка) — це свідоме спрощення, щоб камера і фізика Roblox працювали стабільно.
]]

local NASAData = require(script.Parent:WaitForChild("NASAData"))
local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

local PlanetZoneManager = {}

PlanetZoneManager.CONFIG = {
	Moon = {
		name = "Moon",
		nameOn = "THE MOON",
		gravity = NASAData.Planets.Moon.surfaceGravity,   -- 1.62 м/с² ≈ 0.16 g
		airDensity = 0,                                   -- вакуум: опору немає
		scaleHeightM = 0,
		inner = 500,                                      -- studs над поверхнею глобуса: повний вплив
		outer = 1200,                                     -- далі — вже не впливає
		color = Color3.fromRGB(240, 190, 40),
	},
	Mars = {
		name = "Mars",
		nameOn = "MARS",
		gravity = NASAData.Planets.Mars.surfaceGravity,   -- 3.72 м/с² ≈ 0.38 g
		airDensity = NASAData.Planets.Mars.atmosphereDensity, -- 0.020 кг/м³ — у 60 разів рідше за земне
		scaleHeightM = 11100,                             -- [NASA] шкала висот атмосфери Марса
		inner = 500,
		outer = 1300,
		color = Color3.fromRGB(255, 150, 90),
	},
}

local zones = nil
local function getZones()
	if zones and #zones > 0 then
		return zones
	end
	zones = {}
	local planets = workspace:FindFirstChild("Planets")
	if planets then
		for _, z in ipairs(planets:GetChildren()) do
			local id = z:GetAttribute("Planet")
			if id and PlanetZoneManager.CONFIG[id] and z:GetAttribute("GlobeCenter") then
				table.insert(zones, z)
			end
		end
	end
	return zones
end
PlanetZoneManager.GetZones = getZones

function PlanetZoneManager.GetZone(id)
	for _, z in ipairs(getZones()) do
		if z:GetAttribute("Planet") == id then
			return z
		end
	end
	return nil
end

-- Найближча зона: повертає zoneModel, id, f (0…1), висота над ділянкою (м)
function PlanetZoneManager.Locate(pos)
	local best, bestId, bestF = nil, nil, 0
	for _, z in ipairs(getZones()) do
		local id = z:GetAttribute("Planet")
		local cfg = PlanetZoneManager.CONFIG[id]
		local above = (pos - z:GetAttribute("GlobeCenter")).Magnitude - z:GetAttribute("GlobeRadius")
		local f = math.clamp((cfg.outer - above) / (cfg.outer - cfg.inner), 0, 1)
		if f > bestF then
			best, bestId, bestF = z, id, f
		end
	end
	if not best then
		return nil, nil, 0, nil
	end
	-- висота над поверхнею СФЕРИ (працює з будь-якого боку планети)
	local altitudeM = math.max((pos - best:GetAttribute("GlobeCenter")).Magnitude - best:GetAttribute("GlobeRadius"), 0) * M_PER_STUD
	return best, bestId, bestF, altitudeM
end

-- g біля планети: плавний перехід від земного g до g планети
function PlanetZoneManager.Gravity(pos, gEarth)
	local z, id, f = PlanetZoneManager.Locate(pos)
	if not z then
		return gEarth
	end
	return gEarth + (PlanetZoneManager.CONFIG[id].gravity - gEarth) * f
end

-- СФЕРИЧНА ГРАВІТАЦІЯ (вектор, м/с²).
--   Біля Землі світ плаский: g = (0, −gEarth, 0).
--   Біля Місяця/Марса — до ЦЕНТРУ глобуса з будь-якого боку:
--       g = gповерхні · (R / r)²,   напрямок (центр − точка).Unit
--   Між ними — плавний перехід за впливом f (див. Locate).
function PlanetZoneManager.GravityVector(pos, gEarth)
	local earth = Vector3.new(0, -gEarth, 0)
	local z, id, f = PlanetZoneManager.Locate(pos)
	if not z then
		return earth
	end
	local center = z:GetAttribute("GlobeCenter")
	local R = z:GetAttribute("GlobeRadius")
	local toCenter = center - pos
	local r = math.max(toCenter.Magnitude, R)
	local planet = toCenter.Unit * PlanetZoneManager.CONFIG[id].gravity * (R / r) ^ 2
	return earth:Lerp(planet, f)
end

-- Над якою поверхнею ми зараз і на якій висоті (м): "Moon" / "Mars" біля планети, інакше "Earth"
-- (земля — на рівні Y = 0).
function PlanetZoneManager.Surface(pos)
	local z, id, f, altitudeM = PlanetZoneManager.Locate(pos)
	if z and f > 0.3 then
		return id, altitudeM
	end
	return "Earth", math.max(pos.Y, 0) * M_PER_STUD
end

-- "Верх" у цій точці: від центру планети (або +Y біля Землі)
function PlanetZoneManager.UpAt(pos)
	local g = PlanetZoneManager.GravityVector(pos, 9.807)
	return g.Magnitude > 1e-6 and -g.Unit or Vector3.yAxis
end

-- Щільність повітря: земна зникає, а в атмосфері Марса ρ = ρ0 · e^(−h/H)
function PlanetZoneManager.AirDensity(pos, rhoEarth)
	local z, id, f, altitudeM = PlanetZoneManager.Locate(pos)
	if not z then
		return rhoEarth
	end
	local cfg = PlanetZoneManager.CONFIG[id]
	local rho = 0
	if cfg.airDensity > 0 then
		rho = cfg.airDensity * math.exp(-altitudeM / cfg.scaleHeightM)
	end
	return rhoEarth * (1 - f) + rho * f
end

return PlanetZoneManager
