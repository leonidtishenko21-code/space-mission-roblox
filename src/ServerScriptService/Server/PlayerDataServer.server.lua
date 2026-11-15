--[[
	PlayerDataServer (Script)
	Location: ServerScriptService > Server > PlayerDataServer

	What it does:
	  1. Gives every player a starting budget and a level-1 oil derrick.
	  2. Adds RP-1 to storage every second (no more than the capacity).
	  3. Handles derrick upgrades. Money is checked by the SERVER,
	     so a player cannot "draw" themselves a budget.

	Player data is stored as Attributes (visible to both the server and the player):
	  Budget, RP1, RP1Capacity, RP1Rate, OilRigLevel
	(Saving between sessions with DataStore will be added later.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))

--------------------------------------------------------------------
-- ⚙️ SETTINGS
--------------------------------------------------------------------
local START_BUDGET = NASAData.Planets.Earth.budget -- $26 000
local TICK = 1                                     -- how often (s) fuel is added
local PRODUCTION_SPEED = 1                         -- for testing you can set 10 (10 times faster)

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

-- 20000 → "20 000" (same as in HUDClient)
local function formatNumber(n)
	local s = tostring(math.floor(n + 0.5))
	local spaced = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (spaced:gsub("^%s+", ""))
end

local function notify(player, text, isError)
	notifyEvent:FireClient(player, text, isError == true)
end

--------------------------------------------------------------------
-- Player data
--------------------------------------------------------------------
local function applyRigLevel(player, level)
	local cfg = NASAData.OilRig[level]
	player:SetAttribute("OilRigLevel", level)
	player:SetAttribute("RP1Rate", cfg.productionRate)
	player:SetAttribute("RP1Capacity", cfg.storageCapacity)
end

local function setupPlayer(player)
	if player:GetAttribute("Budget") ~= nil then
		return -- already set up
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
-- Derrick upgrade
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
-- RP-1 production:  new_fuel = fuel + rate × time   (but ≤ capacity)
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
