--[[
	EnvironmentManager (LocalScript)
	Місце: StarterPlayer > StarterPlayerScripts > EnvironmentManager

	Щокадру (RenderStepped) дивиться, де камера, і плавно (Lerp) змінює небо та світло:
	  0–15 км   — денне блакитне небо, щільна атмосфера (як налаштовано в Lighting)
	  15–50 км  — темно-синя стратосфера: серпанок зникає (Haze → 0), атмосфера рідшає
	  50+ км    — КОСМОС: зоряний скайбокс (ReplicatedStorage/SpaceSky) з туманностями, атмосфера = 0,
	              яскраве Сонце (без атмосфери світло різкіше), легкий Bloom і контраст.
	              Сонце лишається на небі — тому ракету й планети освітлено, а не "ніч".
	  Біля Марса (PlanetZoneManager) — розріджена помаранчева атмосфера з пиловим серпанком,
	              яка перекриває чорний космос (на Місяці атмосфери немає — там космос).

	Висота в км = (Y − рівень землі) · NASAData.Flight.METERS_PER_STUD / 1000.
	Біля землі скрипт нічого не змінює — лише запам'ятовує поточні налаштування (їх може міняти
	меню графіки MainMenuClient), а після польоту повертає їх.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))
local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local GROUND_Y = 0
local START_KM = 0.3
local STRATO_FROM, STRATO_TO = 15, 50
local SPACE_FROM, SPACE_TO = 50, 75
local SKY_SWAP_AT = 0.35          -- частка "космосу", з якої вмикається зоряний скайбокс

local STRATO = {
	AtmosphereColor = Color3.fromRGB(25, 40, 95),
	AtmosphereDecay = Color3.fromRGB(10, 20, 60),
}
local SPACE = {
	Ambient = Color3.fromRGB(35, 35, 45),          -- тіні в космосі глибокі
	OutdoorAmbient = Color3.fromRGB(75, 75, 92),
	Brightness = 3.2,                              -- Сонце без атмосфери
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
	Brightness = 2.3,                              -- Сонце далі, світла менше
}

--------------------------------------------------------------------
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- плавний перехід 0→1 між двома висотами (smoothstep)
local function band(km, from, to)
	local t = math.clamp((km - from) / (to - from), 0, 1)
	return t * t * (3 - 2 * t)
end

local spaceSky = ReplicatedStorage:WaitForChild("SpaceSky"):Clone()
local daySky = nil

-- Зоряний скайбокс вмикаємо, лише якщо його текстури справді завантажились (нові зображення
-- спершу проходять модерацію Roblox). Інакше — запасний варіант: ніч із вбудованими зорями.
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
		task.wait(30) -- перевіряємо знову кожні 30 с (до 10 хв)
	end
end)
local spaceColor = Instance.new("ColorCorrectionEffect")
spaceColor.Name = "SpaceColor"
spaceColor.Enabled = false
spaceColor.Parent = Lighting

local base = nil      -- збережене «земне» освітлення
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
			daySky.Parent = nil      -- лише на цьому клієнті
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
	local s = band(km, STRATO_FROM, STRATO_TO)   -- 0 → 1: стратосфера
	local c = band(km, SPACE_FROM, SPACE_TO)     -- 0 → 1: космос
	local low = band(km, START_KM, STRATO_FROM)  -- серпанок поступово зникає ще в тропосфері
	local _, zoneId, zoneF = PlanetZoneManager.Locate(focus)
	local m = zoneId == "Mars" and zoneF or 0    -- 0 → 1: атмосфера Марса
	local space = c * (1 - m)

	if spaceSkyReady then
		setSpaceSky(space > SKY_SWAP_AT)
		Lighting.ClockTime = base.ClockTime      -- Сонце лишається на небі
	else
		-- запасний варіант: Roblox показує зорі та чорне небо лише вночі
		setSpaceSky(false)
		Lighting.ClockTime = lerp(base.ClockTime, NIGHT_CLOCK, space)
		if daySky and base.StarCount then
			daySky.StarCount = math.floor(lerp(base.StarCount, FALLBACK_STARS, space))
		end
	end

	-- Світло
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

	-- Атмосфера: серпанок і щільність → 0, а біля Марса — помаранчевий пил
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
			restore()        -- повернулися на землю
			modified = false
		end
		capture()            -- біля землі просто запам'ятовуємо налаштування графіки
		return
	end
	if not base then
		capture()
	end
	modified = true
	apply(km, focus)
end)
