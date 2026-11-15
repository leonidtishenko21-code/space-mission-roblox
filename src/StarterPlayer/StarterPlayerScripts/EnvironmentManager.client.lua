--[[
	EnvironmentManager (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > EnvironmentManager

	Every frame (RenderStepped) it checks where the camera is and smoothly (Lerp) changes the sky and lighting:
	  0–15 km   — blue daytime sky, dense atmosphere (as set in Lighting)
	  15–50 km  — dark blue stratosphere: the haze fades (Haze → 0), the atmosphere thins
	  50+ km    — SPACE: starry skybox (ReplicatedStorage/SpaceSky) with nebulae, atmosphere = 0,
	              a bright Sun (light is harsher without an atmosphere), light Bloom and contrast.
	              The Sun stays in the sky — so the rocket and planets are lit, it is not "night".
	  Near Mars (PlanetZoneManager) — a thin orange atmosphere with dusty haze
	              that covers the black of space (the Moon has no atmosphere — space there).

	Altitude in km = (Y − ground level) · NASAData.Flight.METERS_PER_STUD / 1000.
	Near the ground the script changes nothing — it only remembers the current settings (they can be changed
	by the MainMenuClient graphics menu), and restores them after the flight.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))
local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

--------------------------------------------------------------------
-- ⚙️ SETTINGS
--------------------------------------------------------------------
local GROUND_Y = 0
local START_KM = 0.3
local STRATO_FROM, STRATO_TO = 15, 50
local SPACE_FROM, SPACE_TO = 50, 75
local SKY_SWAP_AT = 0.35          -- "space" fraction at which the starry skybox turns on

local STRATO = {
	AtmosphereColor = Color3.fromRGB(25, 40, 95),
	AtmosphereDecay = Color3.fromRGB(10, 20, 60),
}
local SPACE = {
	Ambient = Color3.fromRGB(35, 35, 45),          -- deep shadows in space
	OutdoorAmbient = Color3.fromRGB(75, 75, 92),
	Brightness = 3.2,                              -- the Sun without an atmosphere
	Exposure = 0.1,
	Bloom = 1.6,
}
local MARS = {
	AtmosphereColor = Color3.fromRGB(210, 120, 80),
	AtmosphereDecay = Color3.fromRGB(150, 80, 50),
	Density = 0.38,
	Haze = 2.2,
	Ambient = Color3.fromRGB(110, 85, 75),
	OutdoorAmbient = Color3.fromRGB(165, 120, 95),
	Brightness = 2.3,                              -- the Sun is farther, less light
}

--------------------------------------------------------------------
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- smooth 0→1 transition between two altitudes (smoothstep)
local function band(km, from, to)
	local t = math.clamp((km - from) / (to - from), 0, 1)
	return t * t * (3 - 2 * t)
end

local spaceSky = ReplicatedStorage:WaitForChild("SpaceSky"):Clone()
local daySky = nil

-- The starry skybox is turned on only if its textures have really loaded (new images
-- go through Roblox moderation first). Otherwise — the fallback: night with built-in stars.
local spaceSkyReady = false
local NIGHT_CLOCK = 23.9
local FALLBACK_STARS = 5000
task.spawn(function()
	local ContentProvider = game:GetService("ContentProvider")
	local faces = { spaceSky.SkyboxBk, spaceSky.SkyboxDn, spaceSky.SkyboxFt, spaceSky.SkyboxLf, spaceSky.SkyboxRt, spaceSky.SkyboxUp }
	for attempt = 1, 20 do
		local ok = 0
		pcall(function()
			ContentProvider:PreloadAsync(faces, function(_, status)
				if status == Enum.AssetFetchStatus.Success then
					ok += 1
				end
			end)
		end)
		if ok == #faces then
			spaceSkyReady = true
			return
		end
		task.wait(30) -- check again every 30 s (up to 10 min)
	end
end)
local spaceColor = Instance.new("ColorCorrectionEffect")
spaceColor.Name = "SpaceColor"
spaceColor.Enabled = false
spaceColor.Parent = Lighting

local base = nil      -- saved "Earth" lighting
local modified = false

local function capture()
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	daySky = Lighting:FindFirstChildOfClass("Sky") or daySky
	base = {
		ClockTime = Lighting.ClockTime,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Brightness = Lighting.Brightness,
		Exposure = Lighting.ExposureCompensation,
		Bloom = bloom and bloom.Intensity,
		StarCount = daySky and daySky.StarCount,
		atm = atm and {
			Density = atm.Density, Haze = atm.Haze, Glare = atm.Glare,
			Color = atm.Color, Decay = atm.Decay,
		},
	}
end

local function setSpaceSky(on)
	if on and spaceSky.Parent ~= Lighting then
		if daySky then
			daySky.Parent = nil      -- on this client only
		end
		spaceSky.Parent = Lighting
	elseif not on and spaceSky.Parent then
		spaceSky.Parent = nil
		if daySky then
			daySky.Parent = Lighting
		end
	end
end

local function restore()
	if not base then
		return
	end
	setSpaceSky(false)
	spaceColor.Enabled = false
	Lighting.ClockTime = base.ClockTime
	if daySky and base.StarCount then
		daySky.StarCount = base.StarCount
	end
	Lighting.Ambient = base.Ambient
	Lighting.OutdoorAmbient = base.OutdoorAmbient
	Lighting.Brightness = base.Brightness
	Lighting.ExposureCompensation = base.Exposure
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom and base.Bloom then
		bloom.Intensity = base.Bloom
	end
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm and base.atm then
		for k, v in pairs(base.atm) do
			atm[k] = v
		end
	end
end

local function apply(km, focus)
	local s = band(km, STRATO_FROM, STRATO_TO)   -- 0 → 1: stratosphere
	local c = band(km, SPACE_FROM, SPACE_TO)     -- 0 → 1: space
	local low = band(km, START_KM, STRATO_FROM)  -- the haze starts fading already in the troposphere
	local _, zoneId, zoneF = PlanetZoneManager.Locate(focus)
	local m = zoneId == "Mars" and zoneF or 0    -- 0 → 1: Mars atmosphere
	local space = c * (1 - m)

	if spaceSkyReady then
		setSpaceSky(space > SKY_SWAP_AT)
		Lighting.ClockTime = base.ClockTime      -- the Sun stays in the sky
	else
		-- fallback: Roblox shows stars and a black sky only at night
		setSpaceSky(false)
		Lighting.ClockTime = lerp(base.ClockTime, NIGHT_CLOCK, space)
		if daySky and base.StarCount then
			daySky.StarCount = math.floor(lerp(base.StarCount, FALLBACK_STARS, space))
		end
	end

	-- Lighting
	Lighting.Ambient = base.Ambient:Lerp(SPACE.Ambient, space):Lerp(MARS.Ambient, m)
	Lighting.OutdoorAmbient = base.OutdoorAmbient:Lerp(SPACE.OutdoorAmbient, space):Lerp(MARS.OutdoorAmbient, m)
	Lighting.Brightness = lerp(lerp(base.Brightness, SPACE.Brightness, space), MARS.Brightness, m)
	Lighting.ExposureCompensation = lerp(base.Exposure, SPACE.Exposure, space)
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom and base.Bloom then
		bloom.Intensity = lerp(base.Bloom, SPACE.Bloom, space)
	end
	spaceColor.Enabled = space > 0.01
	spaceColor.Contrast = 0.12 * space
	spaceColor.Saturation = 0.15 * space
	spaceColor.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(235, 240, 255), space)

	-- Atmosphere: haze and density → 0, and near Mars — orange dust
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm and base.atm then
		atm.Haze = lerp(lerp(base.atm.Haze, 0, math.max(low, s)), MARS.Haze, m)
		atm.Glare = lerp(base.atm.Glare, 0, math.max(s, m))
		atm.Density = lerp(lerp(lerp(base.atm.Density, base.atm.Density * 0.35, s), 0, c), MARS.Density, m)
		atm.Color = base.atm.Color:Lerp(STRATO.AtmosphereColor, s):Lerp(MARS.AtmosphereColor, m)
		atm.Decay = base.atm.Decay:Lerp(STRATO.AtmosphereDecay, s):Lerp(MARS.AtmosphereDecay, m)
	end
end

RunService.RenderStepped:Connect(function()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local focus = camera.Focus.Position
	local km = math.max(focus.Y - GROUND_Y, 0) * M_PER_STUD / 1000

	if km < START_KM then
		if modified then
			restore()        -- back on the ground
			modified = false
		end
		capture()            -- near the ground we just remember the graphics settings
		return
	end
	if not base then
		capture()
	end
	modified = true
	apply(km, focus)
end)
