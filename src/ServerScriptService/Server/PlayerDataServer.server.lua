--[[
	PlayerDataServer (Script)
	Місце: ServerScriptService > Server > PlayerDataServer

	Що робить:
	  1. Дає кожному гравцю стартовий бюджет і нафтову вишку рівня 1.
	  2. Щосекунди додає RP-1 у сховище (не більше за місткість).
	  3. Обробляє покращення вишки. Гроші перевіряє САМЕ сервер,
	     щоб гравець не міг "намалювати" собі бюджет.

	Дані гравця зберігаються як Attributes (їх бачать і сервер, і гравець):
	  Budget, RP1, RP1Capacity, RP1Rate, OilRigLevel
	(Збереження між сесіями через DataStore додамо пізніше.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local START_BUDGET = NASAData.Planets.Earth.budget -- $26 000
local TICK = 1                                     -- як часто (с) додається пальне
local PRODUCTION_SPEED = 1                         -- для тестів можна поставити 10 (у 10 разів швидше)

--------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local function getRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end

local upgradeEvent = getRemote("UpgradeOilRig")
local notifyEvent = getRemote("Notify")

-- 20000 → "20 000" (так само, як у HUDClient)
local function formatNumber(n)
	local s = tostring(math.floor(n + 0.5))
	local spaced = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (spaced:gsub("^%s+", ""))
end

local function notify(player, text, isError)
	notifyEvent:FireClient(player, text, isError == true)
end

--------------------------------------------------------------------
-- Дані гравця
--------------------------------------------------------------------
local function applyRigLevel(player, level)
	local cfg = NASAData.OilRig[level]
	player:SetAttribute("OilRigLevel", level)
	player:SetAttribute("RP1Rate", cfg.productionRate)
	player:SetAttribute("RP1Capacity", cfg.storageCapacity)
end

local function setupPlayer(player)
	if player:GetAttribute("Budget") ~= nil then
		return -- вже налаштований
	end
	player:SetAttribute("Budget", START_BUDGET)
	player:SetAttribute("RP1", 0)
	applyRigLevel(player, 1)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

--------------------------------------------------------------------
-- Покращення вишки
--------------------------------------------------------------------
upgradeEvent.OnServerEvent:Connect(function(player)
	local level = player:GetAttribute("OilRigLevel") or 1
	local nextCfg = NASAData.OilRig[level + 1]
	if not nextCfg then
		notify(player, "The derrick is already at max level.", true)
		return
	end

	local budget = player:GetAttribute("Budget") or 0
	if budget < nextCfg.upgradeCost then
		notify(player, "Not enough funds: you need $" .. formatNumber(nextCfg.upgradeCost) .. ".", true)
		return
	end

	player:SetAttribute("Budget", budget - nextCfg.upgradeCost)
	applyRigLevel(player, level + 1)
	notify(player, "Derrick upgraded to level " .. (level + 1) .. "!", false)
end)

--------------------------------------------------------------------
-- Видобуток RP-1:  нове_пальне = пальне + швидкість × час   (але ≤ місткості)
--------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(TICK)
		for _, player in ipairs(Players:GetPlayers()) do
			local rp1 = player:GetAttribute("RP1")
			local rate = player:GetAttribute("RP1Rate")
			local capacity = player:GetAttribute("RP1Capacity")
			if rp1 and rate and capacity and rp1 < capacity then
				player:SetAttribute("RP1", math.min(rp1 + rate * TICK * PRODUCTION_SPEED, capacity))
			end
		end
	end
end)
