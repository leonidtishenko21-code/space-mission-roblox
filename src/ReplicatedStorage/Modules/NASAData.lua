--[[
	NASAData (ModuleScript)
	Місце: ReplicatedStorage > Modules > NASAData

	Тут зберігаються ВСІ числа гри: планети, деталі ракети, нафтова вишка.
	Інші скрипти беруть дані звідси через:
		local NASAData = require(game.ReplicatedStorage.Modules.NASAData)

	Позначки в коментарях:
		[NASA]  — реальне значення (NASA Planetary Fact Sheet або офіційні дані двигуна/корабля)
		[ГРА]   — значення для балансу гри (наприклад, ціни: справжні місії коштують мільярди)
]]

local NASAData = {}

--------------------------------------------------------------------
-- 1. КОНСТАНТИ
--------------------------------------------------------------------
NASAData.Constants = {
	G0 = 9.807,                 -- [NASA] стандартне прискорення вільного падіння, м/с² (для формули Isp)
	METERS_PER_STUD = 0.28,     -- [Roblox] 1 stud ≈ 0.28 м (офіційне співвідношення Roblox)

	-- Ракетне пальне = RP-1 (гас) + рідкий кисень (LOX).
	-- У двигунах Merlin на 1 кг RP-1 припадає приблизно 2.36 кг LOX.
	-- Отже RP-1 — це лише ~30% маси пального. Кисень у грі добувається з повітря безкоштовно,
	-- а RP-1 треба виробляти на нафтовій вишці.
	RP1_SHARE = 1 / (1 + 2.36), -- ≈ 0.30
}

--------------------------------------------------------------------
-- 1b. ПОЛІТ (Фаза 2)
--------------------------------------------------------------------
-- ⚠️ МАСШТАБ. Персонаж і деталі ракети мають масштаб 1 stud = 0.28 м (METERS_PER_STUD вище).
-- Але справжня ракета за 2 хвилини піднімається на сотні км — це мільйони studs, Roblox так не вміє.
-- Тому ВИСОТА й ШВИДКІСТЬ під час польоту мають власний масштаб: 1 stud = 12.5 м.
--   100 км (лінія Кармана, межа космосу) = 8 000 studs над стартовим майданчиком.
-- Фізика (тяга, маса в кг, опір, g) рахується в СПРАВЖНІХ одиницях (м, м/с, Н, кг),
-- а вже готове прискорення переводиться в studs/с² — тому TWR і Δv у польоті ті самі, що в конструкторі.
NASAData.Flight = {
	METERS_PER_STUD = 12.5,          -- [ГРА] масштаб висоти/швидкості в польоті
	SCALE_HEIGHT_M = 8500,           -- [NASA] шкала висот атмосфери Землі:  ρ(h) = ρ0 · e^(−h / H)
	ATMOSPHERE_TOP_KM = 100,         -- [NASA] лінія Кармана: вище вважаємо ρ = 0 (космос)
	DRAG_COEFFICIENT = 0.5,          -- [ГРА] Cd ракети з носовим конусом (реально ≈ 0.3–0.75)
	TARGET_ALTITUDE_KM = 100,        -- ціль місії «Земля»: перетнути лінію Кармана (суборбітальний політ)
	FAIRING_MIN_ALTITUDE_KM = 40,    -- [ГРА] нижче обтічник скидати не можна: зірве потоком повітря
	MAX_ALTITUDE_KM = 400,           -- [ГРА] межа симуляції (висота МКС); вище політ завершується
	ORBITAL_SPEED = 7800,            -- [NASA] перша космічна швидкість біля Землі, м/с (для HUD)
	MISSION_REWARD = 20000,          -- [ГРА] $ за перетин лінії Кармана
	ALTITUDE_PAY_PER_KM = 150,       -- [ГРА] $ за кожен км апогею (після аварії — половина)
}

--------------------------------------------------------------------
-- 1c. EDL — вхід, зниження, посадка (парашут і автопосадка). Висоти — над поверхнею планети.
--------------------------------------------------------------------
NASAData.EDL = {
	CHUTE_CD = 1.5,            -- коефіцієнт опору розкритого купола (реально ≈ 1.3–1.75)
	DESIGN_SPEED = 10,         -- м/с: на таку швидкість приземлення на ЗЕМЛІ розраховується площа купола
	-- Рифлення (як у справжніх капсул): вище REEF_ALT_KM купол розкритий частково і тримає ≈ REEFED_SPEED,
	-- нижче — розкривається повністю. Інакше зниження з 10 км тривало б ≈ 15 хв. Тільки на Землі.
	REEF_ALT_KM = 1.5,
	REEFED_SPEED = 90,
	MAX_DEPLOY_ALT_KM = 20,    -- вище повітря надто розріджене — розкривати марно
	MAX_Q = 35000,             -- Па: швидкісний напір ½ρv², вище якого купол рветься
	WARN_ALT_KM = 8,           -- зона попередження: від 8 км … (капсули NASA розкривають парашути на 7–3 км)
	CRIT_ALT_KM = 2,           -- … до 2 км; нижче — критично (якщо швидко)
	CRIT_SPEED = 30,           -- м/с спуску: нижче CRIT_ALT з такою швидкістю — червона тривога
	DESCENT_SPEED = 15,        -- м/с спуску: з цієї швидкості вважаємо, що ракета "знижується"
	AUTOLAND_TOUCHDOWN = 3,    -- м/с: з такою швидкістю автопосадка торкається поверхні
}

--------------------------------------------------------------------
-- 2. ПЛАНЕТИ ТА ЦІЛІ МІСІЙ
--------------------------------------------------------------------
-- studPosition  — де об'єкт стоїть на карті Roblox (будуватимемо в наступних кроках)
-- realDistanceKm — справжня відстань від Землі (показуватиметься на телеметрії)
-- surfaceGravity — м/с²,  radiusKm — км,  atmosphereDensity — кг/м³ біля поверхні
NASAData.Planets = {
	Earth = {
		order = 1,
		name = "Earth",
		studPosition = Vector3.new(0, 0, 0),
		realDistanceKm = 0,
		surfaceGravity = 9.807,       -- [NASA]
		radiusKm = 6371,              -- [NASA] середній радіус
		atmosphereDensity = 1.225,    -- [NASA] на рівні моря
		temperatureC = 15,            -- [NASA] середня
		parachutesWork = true,
		budget = 26000,               -- [ГРА] вистачає на вишку рів. 2 ($8 000) + ракету 3× Rutherford ($17 500)
		requiredEquipment = { "pod_mercury", "tank_small", "engine_rutherford", "nosecone" },
		mission = "Calibrate the gyroscope and verify the launch pad altitude.",
	},

	ISS = {
		order = 2,
		name = "International Space Station (ISS)",
		studPosition = Vector3.new(0, 8000, 0),
		realDistanceKm = 410,         -- [NASA] МКС літає на висоті ~400–420 км
		-- На висоті МКС гравітація ще ~8.7 м/с², але станція весь час "падає" по орбіті,
		-- тому всередині невагомість. У грі вважаємо g = 0.
		surfaceGravity = 0,
		radiusKm = 0,
		atmosphereDensity = 0,
		temperatureC = -100,          -- [NASA] у тіні
		parachutesWork = false,
		budget = 35000,
		requiredEquipment = { "rcs_draco", "docking_port", "oxygen_tank", "antenna_low" },
		mission = "Soft docking (speed < 2.0 m/s) and a laser inspection of the station solar arrays.",
		dockingMaxSpeed = 2.0,        -- м/с
	},

	Moon = {
		order = 3,
		name = "Moon",
		studPosition = Vector3.new(0, 20000, 0),
		realDistanceKm = 384400,      -- [NASA] середня відстань Земля–Місяць
		surfaceGravity = 1.62,        -- [NASA]
		radiusKm = 1737.4,            -- [NASA]
		atmosphereDensity = 0,        -- вакуум — парашути НЕ працюють
		temperatureC = -173,          -- [NASA] вночі
		parachutesWork = false,
		budget = 50000,
		requiredEquipment = { "landing_legs", "engine_rutherford", "thermal_insulation", "antenna_medium", "theodolite" },
		mission = "Crater triangulation: 3 survey beacons, measure L and angle α, compute the depth Δh = L·sin(α).",
	},

	Mars = {
		order = 4,
		name = "Mars",
		studPosition = Vector3.new(0, 38000, 0),
		-- [NASA] відстань змінюється: від 54.6 млн км (найближче) до ~401 млн км. Беремо середню.
		realDistanceKm = 225000000,
		surfaceGravity = 3.721,       -- [NASA]
		radiusKm = 3389.5,            -- [NASA]
		atmosphereDensity = 0.020,    -- [NASA] приблизно в 60 разів менше, ніж на Землі
		temperatureC = -65,           -- [NASA] середня
		parachutesWork = true,        -- працюють, але слабо: потрібен ще й двигун
		budget = 120000,
		requiredEquipment = { "heat_shield", "parachute", "engine_rutherford", "heater", "battery", "antenna_high", "terrain_scanner", "ice_drill" },
		mission = "Find a flat site for a base (slope < 5°), place markers, drill for ice, send the data to Earth.",
		maxSlopeDegrees = 5,
	},

	-- Фаза 2 (поки без місця на карті)
	Venus = {
		order = 5,
		name = "Venus",
		studPosition = nil,
		realDistanceKm = 41000000,    -- [NASA] найменша відстань
		surfaceGravity = 8.87,        -- [NASA]
		radiusKm = 6051.8,            -- [NASA]
		atmosphereDensity = 65,       -- [NASA] у ~53 рази щільніша за земну
		temperatureC = 464,           -- [NASA]
		parachutesWork = true,
		budget = 0,
		requiredEquipment = {},
		mission = "Phase 2",
	},

	Mercury = {
		order = 6,
		name = "Mercury",
		studPosition = nil,
		realDistanceKm = 77000000,    -- [NASA] найменша відстань (приблизно)
		surfaceGravity = 3.70,        -- [NASA]
		radiusKm = 2439.7,            -- [NASA]
		atmosphereDensity = 0,
		temperatureC = 167,           -- [NASA] середня
		parachutesWork = false,
		budget = 0,
		requiredEquipment = {},
		mission = "Phase 2",
	},
}

--------------------------------------------------------------------
-- 3. ДЕТАЛІ РАКЕТИ
--------------------------------------------------------------------
-- attach = "stack"  → кріпиться по центральній осі (зверху/знизу)
-- attach = "radial" → кріпиться збоку (впливає на центр мас!)
-- cost — $ [ГРА];  dryMass — кг без пального;  fuelCapacity — кг пального (RP-1 + LOX)
-- thrustSL / thrustVac — тяга біля Землі / у вакуумі, Н
-- ispSL / ispVac — питомий імпульс біля Землі / у вакуумі, с
-- power — Вт: плюс = виробляє, мінус = споживає
NASAData.Modules = {
	------------------ КОМАНДНІ КАПСУЛИ ------------------
	pod_mercury = {
		name = "Capsule (Mercury style)", category = "command", attach = "stack",
		cost = 6000, dryMass = 1355, power = -150, crew = 1, -- [NASA] маса капсули Mercury ≈ 1355 кг
	},
	pod_dragon = {
		name = "Capsule (Dragon style)", category = "command", attach = "stack",
		cost = 15000, dryMass = 9525, power = -400, crew = 4, -- [NASA/SpaceX] Crew Dragon ≈ 9525 кг
	},

	------------------ ПАЛИВНІ БАКИ (RP-1 + LOX) ------------------
	tank_small = {
		name = "Small RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 2000, dryMass = 250, fuelCapacity = 3000, -- [ГРА]
	},
	tank_medium = {
		name = "Medium RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 6000, dryMass = 1500, fuelCapacity = 25000, -- [ГРА]
	},
	tank_large = {
		name = "Large RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 18000, dryMass = 6000, fuelCapacity = 120000, -- [ГРА]
	},

	------------------ ДВИГУНИ (усі справжні двигуни на RP-1) ------------------
	engine_rutherford = {
		name = "Rutherford engine (Electron)", category = "engine", attach = "stack",
		cost = 3000, dryMass = 35,                      -- [NASA/Rocket Lab] ≈ 35 кг
		thrustSL = 24000, thrustVac = 25800,            -- Н
		ispSL = 303, ispVac = 311,                      -- с
	},
	engine_merlin = {
		name = "Merlin 1D engine (Falcon 9)", category = "engine", attach = "stack",
		cost = 10000, dryMass = 470,                    -- [SpaceX] ≈ 470 кг
		thrustSL = 845000, thrustVac = 914000,          -- Н
		ispSL = 282, ispVac = 311,                      -- с
	},
	engine_f1 = {
		name = "F-1 engine (Saturn V)", category = "engine", attach = "stack",
		cost = 35000, dryMass = 8400,                   -- [NASA] ≈ 8400 кг
		thrustSL = 6770000, thrustVac = 7770000,        -- Н
		ispSL = 263, ispVac = 304,                      -- с
	},
	rcs_draco = {
		-- Справжній Draco працює на іншому паливі; у грі спрощено до спільного бака.
		name = "RCS thrusters (Draco)", category = "engine", attach = "radial",
		cost = 2500, dryMass = 60,
		thrustSL = 400, thrustVac = 400, ispSL = 300, ispVac = 300, -- [SpaceX] ≈ 400 Н, Isp ≈ 300 с
	},

	------------------ КОНСТРУКЦІЯ ТА ЗАХИСТ ------------------
	nosecone = {
		name = "Nose cone", category = "structure", attach = "stack",
		cost = 500, dryMass = 80,
	},
	interstage = {
		name = "Interstage ring", category = "structure", attach = "stack",
		cost = 1500, dryMass = 300,
	},
	decoupler = {
		-- Ставиться МІЖ ступенями: усе, що під ним, відлітає разом з ним після відстрілу.
		name = "Decoupler (stage separation)", category = "structure", attach = "stack",
		cost = 1000, dryMass = 60, -- [ГРА] кільце з піроболтами
	},
	fairing = {
		-- Накриває капсулу зверху; на висоті розкривається на дві половинки.
		name = "Payload fairing (2 halves)", category = "structure", attach = "stack",
		cost = 1500, dryMass = 150, -- [ГРА] (обтічник Electron ≈ 50 кг)
	},
	heat_shield = {
		name = "Heat shield", category = "protection", attach = "stack",
		cost = 7000, dryMass = 600, maxEntryTempC = 2000,
	},
	thermal_insulation = {
		name = "Thermal insulation", category = "protection", attach = "radial",
		cost = 2000, dryMass = 120, minTempC = -200,
	},
	parachute = {
		name = "Parachute", category = "landing", attach = "stack",
		cost = 2500, dryMass = 150,
	},
	landing_legs = {
		name = "Shock-absorbing landing legs", category = "landing", attach = "radial",
		cost = 3000, dryMass = 200, maxLandingSpeed = 5, -- м/с [ГРА]
	},
	docking_port = {
		name = "Docking port", category = "structure", attach = "stack",
		cost = 4000, dryMass = 320,
	},

	------------------ ЕНЕРГІЯ ------------------
	solar_panel = {
		-- Біля Марса сонця в ~2.3 раза менше, тому панель дасть ~43% потужності.
		name = "Solar panel", category = "power", attach = "radial",
		cost = 2500, dryMass = 60, power = 1500,
	},
	battery = {
		name = "Battery pack", category = "power", attach = "radial",
		cost = 1500, dryMass = 90, capacityWh = 3000,
	},
	heater = {
		name = "Heater", category = "life", attach = "radial",
		cost = 1200, dryMass = 40, power = -150,
	},
	oxygen_tank = {
		name = "O₂ tank", category = "life", attach = "radial",
		cost = 1000, dryMass = 110,
	},

	------------------ ЗВ'ЯЗОК ------------------
	antenna_low = {
		name = "Small antenna", category = "comms", attach = "radial",
		cost = 800, dryMass = 5, power = -20, maxRangeKm = 2000,         -- до орбіти/МКС
	},
	antenna_medium = {
		name = "Medium antenna", category = "comms", attach = "radial",
		cost = 3000, dryMass = 25, power = -60, maxRangeKm = 500000,     -- до Місяця
	},
	antenna_high = {
		name = "Large dish antenna", category = "comms", attach = "radial",
		cost = 9000, dryMass = 120, power = -200, maxRangeKm = 450000000, -- до Марса
	},

	------------------ НАУКОВІ ТА ГЕОДЕЗИЧНІ ПРИЛАДИ ------------------
	theodolite = {
		name = "Laser theodolite", category = "science", attach = "radial",
		cost = 4000, dryMass = 30, power = -30,
	},
	terrain_scanner = {
		name = "Terrain scanner", category = "science", attach = "radial",
		cost = 6000, dryMass = 75, power = -120,
	},
	ice_drill = {
		name = "Ice drill", category = "science", attach = "radial",
		cost = 8000, dryMass = 350, power = -400,
	},
}

--------------------------------------------------------------------
-- 4. НАФТОВА ВИШКА ТА ЗАВОД RP-1
--------------------------------------------------------------------
-- [ГРА] Справжні заводи виробляють набагато більше — тут числа зменшені для гри.
NASAData.OilRig = {
	-- (у 4 рази швидше за початковий баланс, щоб не чекати на пальне)
	[1] = { productionRate = 20,  storageCapacity = 40000,  upgradeCost = 0 },     -- кг RP-1 за секунду, кг
	[2] = { productionRate = 60,  storageCapacity = 120000, upgradeCost = 8000 },
	[3] = { productionRate = 160, storageCapacity = 300000, upgradeCost = 20000 },
}

--------------------------------------------------------------------
-- 5. ДОПОМІЖНІ ФУНКЦІЇ (формули з ТЗ)
--------------------------------------------------------------------

function NASAData.GetPlanet(planetId)
	return NASAData.Planets[planetId]
end

function NASAData.GetModule(moduleId)
	return NASAData.Modules[moduleId]
end

-- g(h) = g_поверхні · (R / (R + h))²
-- altitudeMeters — висота над поверхнею в метрах
function NASAData.GravityAtAltitude(planetId, altitudeMeters)
	local planet = NASAData.Planets[planetId]
	if not planet or planet.radiusKm == 0 then
		return 0
	end
	local R = planet.radiusKm * 1000 -- переводимо км у метри
	local h = math.max(altitudeMeters, 0)
	return planet.surfaceGravity * (R / (R + h)) ^ 2
end

-- TWR = F / (m · g)
function NASAData.TWR(thrustN, totalMassKg, gravity)
	if totalMassKg <= 0 or gravity <= 0 then
		return math.huge -- у невагомості TWR "нескінченний"
	end
	return thrustN / (totalMassKg * gravity)
end

-- ṁ = F / (Isp · g0)   → скільки кг пального згорає за секунду
function NASAData.FuelBurnRate(thrustN, isp)
	return thrustN / (isp * NASAData.Constants.G0)
end

-- S = v² / (2 · a_eff),   a_eff = F_гальм / m − g
function NASAData.BrakingDistance(speed, brakingThrustN, totalMassKg, gravity)
	local aEff = brakingThrustN / totalMassKg - gravity
	if aEff <= 0 then
		return math.huge -- двигун не може загальмувати: тяги замало
	end
	return speed ^ 2 / (2 * aEff)
end

return NASAData
