--[[
	NASAData (ModuleScript)
	Location: ReplicatedStorage > Modules > NASAData

	ALL the game's numbers live here: planets, rocket parts, the oil derrick.
	Other scripts read the data from here via:
		local NASAData = require(game.ReplicatedStorage.Modules.NASAData)

	Tags in comments:
		[NASA]  — real value (NASA Planetary Fact Sheet or official engine/spacecraft data)
		[GAME]  — value chosen for game balance (e.g. prices: real missions cost billions)
]]

local NASAData = {}

--------------------------------------------------------------------
-- 1. CONSTANTS
--------------------------------------------------------------------
NASAData.Constants = {
	G0 = 9.807,                 -- [NASA] standard gravity, m/s² (used in the Isp formula)
	METERS_PER_STUD = 0.28,     -- [Roblox] 1 stud ≈ 0.28 m (official Roblox ratio)

	-- Rocket propellant = RP-1 (kerosene) + liquid oxygen (LOX).
	-- Merlin engines burn about 2.36 kg of LOX per 1 kg of RP-1.
	-- So RP-1 is only ~30% of the propellant mass. In the game oxygen is taken from the air for free,
	-- while RP-1 has to be produced at the oil derrick.
	RP1_SHARE = 1 / (1 + 2.36), -- ≈ 0.30
}

--------------------------------------------------------------------
-- 1b. FLIGHT (Phase 2)
--------------------------------------------------------------------
-- ⚠️ SCALE. The character and rocket parts use 1 stud = 0.28 m (METERS_PER_STUD above).
-- But a real rocket climbs hundreds of km in 2 minutes — that is millions of studs, which Roblox cannot handle.
-- So ALTITUDE and SPEED in flight use their own scale: 1 stud = 12.5 m.
--   100 km (the Kármán line, edge of space) = 8,000 studs above the launch pad.
-- Physics (thrust, mass in kg, drag, g) is computed in REAL units (m, m/s, N, kg),
-- and only the final acceleration is converted to studs/s² — so TWR and Δv in flight match the builder.
NASAData.Flight = {
	METERS_PER_STUD = 12.5,          -- [GAME] altitude/speed scale during flight
	SCALE_HEIGHT_M = 8500,           -- [NASA] Earth's atmospheric scale height:  ρ(h) = ρ0 · e^(−h / H)
	ATMOSPHERE_TOP_KM = 100,         -- [NASA] Kármán line: above it we treat ρ = 0 (space)
	DRAG_COEFFICIENT = 0.5,          -- [GAME] Cd of a rocket with a nose cone (real ≈ 0.3–0.75)
	TARGET_ALTITUDE_KM = 100,        -- "Earth" mission goal: cross the Kármán line (suborbital flight)
	FAIRING_MIN_ALTITUDE_KM = 40,    -- [GAME] the fairing cannot be jettisoned lower: the airflow would rip it off
	MAX_ALTITUDE_KM = 400,           -- [GAME] simulation limit (ISS altitude); the flight ends above it
	ORBITAL_SPEED = 7800,            -- [NASA] first cosmic velocity near Earth, m/s (for the HUD)
	MISSION_REWARD = 20000,          -- [GAME] $ for crossing the Kármán line
	ALTITUDE_PAY_PER_KM = 150,       -- [GAME] $ per km of apogee
}

--------------------------------------------------------------------
-- 1c. EDL — entry, descent and landing (parachute and autoland). Altitudes are above the planet surface.
--------------------------------------------------------------------
NASAData.EDL = {
	CHUTE_CD = 1.5,            -- drag coefficient of the open canopy (real ≈ 1.3–1.75)
	DESIGN_SPEED = 10,         -- m/s: the canopy area is sized for this touchdown speed on EARTH
	-- Reefing (like real capsules): above REEF_ALT_KM the canopy is partly open and holds ≈ REEFED_SPEED,
	-- below it opens fully. Otherwise a descent from 10 km would take ≈ 15 min. Earth only.
	REEF_ALT_KM = 1.5,
	REEFED_SPEED = 90,
	MAX_DEPLOY_ALT_KM = 20,    -- above this the air is too thin — deploying is pointless
	MAX_Q = 35000,             -- Pa: dynamic pressure ½ρv² above which the canopy tears
	WARN_ALT_KM = 8,           -- warning zone: from 8 km … (NASA capsules open parachutes at 7–3 km)
	CRIT_ALT_KM = 2,           -- … down to 2 km; below that it is critical (if fast)
	CRIT_SPEED = 30,           -- m/s descent: below CRIT_ALT at this speed — red alert
	DESCENT_SPEED = 15,        -- m/s descent: from this speed the rocket counts as "descending"
	AUTOLAND_TOUCHDOWN = 3,    -- m/s: autoland touches the surface at this speed
}

--------------------------------------------------------------------
-- 2. PLANETS AND MISSION TARGETS
--------------------------------------------------------------------
-- studPosition  — where the object stands on the Roblox map
-- realDistanceKm — real distance from Earth (shown in telemetry)
-- surfaceGravity — m/s²,  radiusKm — km,  atmosphereDensity — kg/m³ at the surface
NASAData.Planets = {
	Earth = {
		order = 1,
		name = "Earth",
		studPosition = Vector3.new(0, 0, 0),
		realDistanceKm = 0,
		surfaceGravity = 9.807,       -- [NASA]
		radiusKm = 6371,              -- [NASA] mean radius
		atmosphereDensity = 1.225,    -- [NASA] at sea level
		temperatureC = 15,            -- [NASA] mean
		parachutesWork = true,
		budget = 26000,               -- [GAME] enough for a level-2 derrick ($8,000) + a 3× Rutherford rocket ($17,500)
		requiredEquipment = { "pod_mercury", "tank_small", "engine_rutherford", "nosecone" },
		mission = "Calibrate the gyroscope and verify the launch pad altitude.",
	},

	ISS = {
		order = 2,
		name = "International Space Station (ISS)",
		studPosition = Vector3.new(0, 8000, 0),
		realDistanceKm = 410,         -- [NASA] the ISS flies at ~400–420 km
		-- At ISS altitude gravity is still ~8.7 m/s², but the station is constantly "falling" in orbit,
		-- so inside it is weightless. In the game we use g = 0.
		surfaceGravity = 0,
		radiusKm = 0,
		atmosphereDensity = 0,
		temperatureC = -100,          -- [NASA] in shadow
		parachutesWork = false,
		budget = 35000,
		requiredEquipment = { "rcs_draco", "docking_port", "oxygen_tank", "antenna_low" },
		mission = "Soft docking (speed < 2.0 m/s) and a laser inspection of the station solar arrays.",
		dockingMaxSpeed = 2.0,        -- m/s
	},

	Moon = {
		order = 3,
		name = "Moon",
		studPosition = Vector3.new(0, 20000, 0),
		realDistanceKm = 384400,      -- [NASA] mean Earth–Moon distance
		surfaceGravity = 1.62,        -- [NASA]
		radiusKm = 1737.4,            -- [NASA]
		atmosphereDensity = 0,        -- vacuum — parachutes do NOT work
		temperatureC = -173,          -- [NASA] at night
		parachutesWork = false,
		budget = 50000,
		requiredEquipment = { "landing_legs", "engine_rutherford", "thermal_insulation", "antenna_medium", "theodolite" },
		mission = "Crater triangulation: 3 survey beacons, measure L and angle α, compute the depth Δh = L·sin(α).",
	},

	Mars = {
		order = 4,
		name = "Mars",
		studPosition = Vector3.new(0, 38000, 0),
		-- [NASA] the distance varies from 54.6 million km (closest) to ~401 million km. We use the average.
		realDistanceKm = 225000000,
		surfaceGravity = 3.721,       -- [NASA]
		radiusKm = 3389.5,            -- [NASA]
		atmosphereDensity = 0.020,    -- [NASA] about 60 times thinner than on Earth
		temperatureC = -65,           -- [NASA] mean
		parachutesWork = true,        -- they work, but weakly: an engine is needed too
		budget = 120000,
		requiredEquipment = { "heat_shield", "parachute", "engine_rutherford", "heater", "battery", "antenna_high", "terrain_scanner", "ice_drill" },
		mission = "Find a flat site for a base (slope < 5°), place markers, drill for ice, send the data to Earth.",
		maxSlopeDegrees = 5,
	},

	-- Phase 2 (no place on the map yet)
	Venus = {
		order = 5,
		name = "Venus",
		studPosition = nil,
		realDistanceKm = 41000000,    -- [NASA] closest distance
		surfaceGravity = 8.87,        -- [NASA]
		radiusKm = 6051.8,            -- [NASA]
		atmosphereDensity = 65,       -- [NASA] ~53 times denser than Earth's
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
		realDistanceKm = 77000000,    -- [NASA] closest distance (approximate)
		surfaceGravity = 3.70,        -- [NASA]
		radiusKm = 2439.7,            -- [NASA]
		atmosphereDensity = 0,
		temperatureC = 167,           -- [NASA] mean
		parachutesWork = false,
		budget = 0,
		requiredEquipment = {},
		mission = "Phase 2",
	},
}

--------------------------------------------------------------------
-- 3. ROCKET PARTS
--------------------------------------------------------------------
-- attach = "stack"  → mounted on the central axis (above/below)
-- attach = "radial" → mounted on the side (shifts the centre of mass!)
-- cost — $ [GAME];  dryMass — kg without propellant;  fuelCapacity — kg of propellant (RP-1 + LOX)
-- thrustSL / thrustVac — thrust at sea level / in vacuum, N
-- ispSL / ispVac — specific impulse at sea level / in vacuum, s
-- power — W: positive = produces, negative = consumes
NASAData.Modules = {
	------------------ COMMAND PODS ------------------
	pod_mercury = {
		name = "Capsule (Mercury style)", category = "command", attach = "stack",
		cost = 6000, dryMass = 1355, power = -150, crew = 1, -- [NASA] Mercury capsule mass ≈ 1355 kg
	},
	pod_dragon = {
		name = "Capsule (Dragon style)", category = "command", attach = "stack",
		cost = 15000, dryMass = 9525, power = -400, crew = 4, -- [NASA/SpaceX] Crew Dragon ≈ 9525 kg
	},

	------------------ FUEL TANKS (RP-1 + LOX) ------------------
	tank_small = {
		name = "Small RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 2000, dryMass = 250, fuelCapacity = 3000, -- [GAME]
	},
	tank_medium = {
		name = "Medium RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 6000, dryMass = 1500, fuelCapacity = 25000, -- [GAME]
	},
	tank_large = {
		name = "Large RP-1/LOX tank", category = "tank", attach = "stack",
		cost = 18000, dryMass = 6000, fuelCapacity = 120000, -- [GAME]
	},

	------------------ ENGINES (all real RP-1 engines) ------------------
	engine_rutherford = {
		name = "Rutherford engine (Electron)", category = "engine", attach = "stack",
		cost = 3000, dryMass = 35,                      -- [NASA/Rocket Lab] ≈ 35 kg
		thrustSL = 24000, thrustVac = 25800,            -- N
		ispSL = 303, ispVac = 311,                      -- s
	},
	engine_merlin = {
		name = "Merlin 1D engine (Falcon 9)", category = "engine", attach = "stack",
		cost = 10000, dryMass = 470,                    -- [SpaceX] ≈ 470 kg
		thrustSL = 845000, thrustVac = 914000,          -- N
		ispSL = 282, ispVac = 311,                      -- s
	},
	engine_f1 = {
		name = "F-1 engine (Saturn V)", category = "engine", attach = "stack",
		cost = 35000, dryMass = 8400,                   -- [NASA] ≈ 8400 kg
		thrustSL = 6770000, thrustVac = 7770000,        -- N
		ispSL = 263, ispVac = 304,                      -- s
	},
	rcs_draco = {
		-- The real Draco uses a different propellant; the game simplifies it to the shared tank.
		name = "RCS thrusters (Draco)", category = "engine", attach = "radial",
		cost = 2500, dryMass = 60,
		thrustSL = 400, thrustVac = 400, ispSL = 300, ispVac = 300, -- [SpaceX] ≈ 400 N, Isp ≈ 300 s
	},

	------------------ STRUCTURE AND PROTECTION ------------------
	nosecone = {
		name = "Nose cone", category = "structure", attach = "stack",
		cost = 500, dryMass = 80,
	},
	interstage = {
		name = "Interstage ring", category = "structure", attach = "stack",
		cost = 1500, dryMass = 300,
	},
	decoupler = {
		-- Goes BETWEEN stages: everything below it falls away together with it after separation.
		name = "Decoupler (stage separation)", category = "structure", attach = "stack",
		cost = 1000, dryMass = 60, -- [GAME] ring with pyro bolts
	},
	fairing = {
		-- Covers the capsule from above; at altitude it splits into two halves.
		name = "Payload fairing (2 halves)", category = "structure", attach = "stack",
		cost = 1500, dryMass = 150, -- [GAME] (Electron fairing ≈ 50 kg)
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
		cost = 3000, dryMass = 200, maxLandingSpeed = 5, -- m/s [GAME]
	},
	docking_port = {
		name = "Docking port", category = "structure", attach = "stack",
		cost = 4000, dryMass = 320,
	},

	------------------ POWER ------------------
	solar_panel = {
		-- Near Mars sunlight is ~2.3 times weaker, so the panel gives ~43% of its power.
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

	------------------ COMMUNICATIONS ------------------
	antenna_low = {
		name = "Small antenna", category = "comms", attach = "radial",
		cost = 800, dryMass = 5, power = -20, maxRangeKm = 2000,         -- to orbit/ISS
	},
	antenna_medium = {
		name = "Medium antenna", category = "comms", attach = "radial",
		cost = 3000, dryMass = 25, power = -60, maxRangeKm = 500000,     -- to the Moon
	},
	antenna_high = {
		name = "Large dish antenna", category = "comms", attach = "radial",
		cost = 9000, dryMass = 120, power = -200, maxRangeKm = 450000000, -- to Mars
	},

	------------------ SCIENCE AND SURVEY INSTRUMENTS ------------------
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
-- 4. OIL DERRICK AND RP-1 REFINERY
--------------------------------------------------------------------
-- [GAME] Real refineries produce far more — the numbers are reduced for the game.
NASAData.OilRig = {
	-- (4 times faster than the original balance, so players don't wait for fuel)
	[1] = { productionRate = 20,  storageCapacity = 40000,  upgradeCost = 0 },     -- kg of RP-1 per second, kg
	[2] = { productionRate = 60,  storageCapacity = 120000, upgradeCost = 8000 },
	[3] = { productionRate = 160, storageCapacity = 300000, upgradeCost = 20000 },
}

--------------------------------------------------------------------
-- 5. HELPER FUNCTIONS (formulas from the spec)
--------------------------------------------------------------------

function NASAData.GetPlanet(planetId)
	return NASAData.Planets[planetId]
end

function NASAData.GetModule(moduleId)
	return NASAData.Modules[moduleId]
end

-- g(h) = g_surface · (R / (R + h))²
-- altitudeMeters — altitude above the surface in metres
function NASAData.GravityAtAltitude(planetId, altitudeMeters)
	local planet = NASAData.Planets[planetId]
	if not planet or planet.radiusKm == 0 then
		return 0
	end
	local R = planet.radiusKm * 1000 -- convert km to metres
	local h = math.max(altitudeMeters, 0)
	return planet.surfaceGravity * (R / (R + h)) ^ 2
end

-- TWR = F / (m · g)
function NASAData.TWR(thrustN, totalMassKg, gravity)
	if totalMassKg <= 0 or gravity <= 0 then
		return math.huge -- in zero gravity TWR is "infinite"
	end
	return thrustN / (totalMassKg * gravity)
end

-- ṁ = F / (Isp · g0)   → how many kg of propellant burn per second
function NASAData.FuelBurnRate(thrustN, isp)
	return thrustN / (isp * NASAData.Constants.G0)
end

-- S = v² / (2 · a_eff),   a_eff = F_brake / m − g
function NASAData.BrakingDistance(speed, brakingThrustN, totalMassKg, gravity)
	local aEff = brakingThrustN / totalMassKg - gravity
	if aEff <= 0 then
		return math.huge -- the engine cannot stop the rocket: not enough thrust
	end
	return speed ^ 2 / (2 * aEff)
end

return NASAData
