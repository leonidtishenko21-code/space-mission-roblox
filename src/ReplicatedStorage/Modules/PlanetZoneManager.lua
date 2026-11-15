--[[
	PlanetZoneManager (ModuleScript, SHARED — server and client)
	Location: ReplicatedStorage > Modules > PlanetZoneManager

	Planet zones (Workspace > Planets > MoonZone / MarsZone). Each zone is a large globe
	(a landmark in space) with a landing site on its top (crater / canyon).
	Zone attributes: Planet ("Moon"/"Mars"), GlobeCenter, GlobeRadius, Center, FloorY.

	Planet influence f = 0…1 depends on the altitude above the globe surface:
	  closer than INNER — full planet gravity, beyond OUTER — Earth gravity, smooth blend in between.
	These are GAME zones: the real Moon is 384,400 km away, Mars tens of millions of km.

	"Down" stays −Y everywhere: so you can only land and walk on the top of the globe
	(where the landing site is) — a deliberate simplification so the Roblox camera and physics stay stable.
]]

local NASAData = require(script.Parent:WaitForChild("NASAData"))
local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

local PlanetZoneManager = {}

PlanetZoneManager.CONFIG = {
	Moon = {
		name = "Moon",
		nameOn = "THE MOON",
		gravity = NASAData.Planets.Moon.surfaceGravity,   -- 1.62 m/s² ≈ 0.16 g
		airDensity = 0,                                   -- vacuum: no drag
		scaleHeightM = 0,
		inner = 500,                                      -- studs above the globe surface: full influence
		outer = 1200,                                     -- beyond this — no influence
		color = Color3.fromRGB(240, 190, 40),
	},
	Mars = {
		name = "Mars",
		nameOn = "MARS",
		gravity = NASAData.Planets.Mars.surfaceGravity,   -- 3.72 m/s² ≈ 0.38 g
		airDensity = NASAData.Planets.Mars.atmosphereDensity, -- 0.020 kg/m³ — 60 times thinner than Earth's
		scaleHeightM = 11100,                             -- [NASA] Mars atmospheric scale height
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

-- Nearest zone: returns zoneModel, id, f (0…1), altitude above the site (m)
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
	-- altitude above the SPHERE surface (works from any side of the planet)
	local altitudeM = math.max((pos - best:GetAttribute("GlobeCenter")).Magnitude - best:GetAttribute("GlobeRadius"), 0) * M_PER_STUD
	return best, bestId, bestF, altitudeM
end

-- g near a planet: smooth blend from Earth g to the planet's g
function PlanetZoneManager.Gravity(pos, gEarth)
	local z, id, f = PlanetZoneManager.Locate(pos)
	if not z then
		return gEarth
	end
	return gEarth + (PlanetZoneManager.CONFIG[id].gravity - gEarth) * f
end

-- SPHERICAL GRAVITY (vector, m/s²).
--   Near Earth the world is flat: g = (0, −gEarth, 0).
--   Near the Moon/Mars — towards the globe CENTRE from any side:
--       g = g_surface · (R / r)²,   direction (centre − point).Unit
--   In between — smooth blend by influence f (see Locate).
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

-- Which surface we are over and at what altitude (m): "Moon" / "Mars" near a planet, otherwise "Earth"
-- (the ground is at Y = 0).
function PlanetZoneManager.Surface(pos)
	local z, id, f, altitudeM = PlanetZoneManager.Locate(pos)
	if z and f > 0.3 then
		return id, altitudeM
	end
	return "Earth", math.max(pos.Y, 0) * M_PER_STUD
end

-- "Up" at this point: away from the planet centre (or +Y near Earth)
function PlanetZoneManager.UpAt(pos)
	local g = PlanetZoneManager.GravityVector(pos, 9.807)
	return g.Magnitude > 1e-6 and -g.Unit or Vector3.yAxis
end

-- Air density: Earth's fades out, and in the Mars atmosphere ρ = ρ0 · e^(−h/H)
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
