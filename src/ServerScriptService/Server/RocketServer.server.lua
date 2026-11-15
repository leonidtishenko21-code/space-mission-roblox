--[[
	RocketServer (Script)
	Місце: ServerScriptService > Server > RocketServer

	Що робить (крок 3 — збирання ракети):
	  1. BuildRocket     — перевіряє креслення (RocketMath.Validate), знімає гроші,
	                       ставить 3D-ракету на майданчик BuildPad в ангарі.
	  2. FuelRocket      — переливає RP-1 зі сховища вишки в баки ракети.
	                       Кисень (LOX) береться з повітря безкоштовно:
	                       1 кг RP-1 + 2.36 кг LOX = 3.36 кг пального.
	  3. DismantleRocket — розбирає ракету: повертає 100% грошей і RP-1 з баків
	                       (поки ракета не злетіла, це просто зміна креслення).

	Атрибути гравця:
	  Mission            — поточна місія ("Earth")
	  RocketBuilt        — true, якщо ракета стоїть на майданчику
	  RocketDesign       — креслення ракети (JSON-рядок)
	  RocketCost         — скільки $ заплачено (повертається при розбиранні)
	  RocketFuel         — скільки кг пального (RP-1 + LOX) у баках
	  RocketFuelCapacity — місткість баків, кг
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local modulesFolder = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modulesFolder:WaitForChild("NASAData"))
local RocketMath = require(modulesFolder:WaitForChild("RocketMath"))
local RocketAssembler = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("RocketAssembler"))

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local DEFAULT_MISSION = "Earth"
local RP1_SHARE = NASAData.Constants.RP1_SHARE -- ≈ 0.30
local fmt = RocketMath.FormatNumber

-- Якщо в грі кілька гравців, ракети стають у різні місця майданчика
local SLOT_OFFSETS = {
	Vector3.new(0, 0, 0),
	Vector3.new(-7, 0, -7),
	Vector3.new(7, 0, -7),
	Vector3.new(-7, 0, 7),
	Vector3.new(7, 0, 7),
}

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

local buildEvent = getRemote("BuildRocket")
local fuelEvent = getRemote("FuelRocket")
local dismantleEvent = getRemote("DismantleRocket")
local notifyEvent = getRemote("Notify")

local function notify(player, text, isError)
	notifyEvent:FireClient(player, text, isError == true)
end

local rocketsFolder = workspace:FindFirstChild("Rockets")
if not rocketsFolder then
	rocketsFolder = Instance.new("Folder")
	rocketsFolder.Name = "Rockets"
	rocketsFolder.Parent = workspace
end

--------------------------------------------------------------------
-- Місце на майданчику
--------------------------------------------------------------------
local function getPadTop()
	local hangar = workspace:FindFirstChild("Hangar")
	local building = hangar and hangar:FindFirstChild("Building")
	local pad = building and building:FindFirstChild("BuildPad")
	if pad then
		return Vector3.new(pad.Position.X, pad.Position.Y + pad.Size.Y / 2, pad.Position.Z)
	end
	return Vector3.new(0, 1.4, -70)
end

local slotOwner = {} -- [номер місця] = UserId

local function freeSlot(player)
	for slot, userId in pairs(slotOwner) do
		if userId == player.UserId then
			slotOwner[slot] = nil
		end
	end
end

local function takeSlot(player)
	freeSlot(player)
	for slot = 1, #SLOT_OFFSETS do
		if slotOwner[slot] == nil then
			slotOwner[slot] = player.UserId
			return slot
		end
	end
	return 1 -- гравців більше, ніж місць: ставимо в центр
end

--------------------------------------------------------------------
-- 3D-модель ракети: збирає RocketAssembler (ServerScriptService > Modules)
--------------------------------------------------------------------
local function removeRocketModel(player)
	for _, model in ipairs(rocketsFolder:GetChildren()) do
		if model:GetAttribute("OwnerUserId") == player.UserId then
			model:Destroy()
		end
	end
	freeSlot(player)
end

-- Коли ракету прибрано будь-як (розібрано, розбилася, гравець вийшов) — звільняємо місце
rocketsFolder.ChildRemoved:Connect(function(model)
	local userId = model:GetAttribute("OwnerUserId")
	for _, other in ipairs(rocketsFolder:GetChildren()) do
		if other:GetAttribute("OwnerUserId") == userId then
			return -- у гравця вже нова ракета — місце зайняте нею
		end
	end
	for slot, owner in pairs(slotOwner) do
		if owner == userId then
			slotOwner[slot] = nil
		end
	end
end)

local function buildRocketModel(player, design)
	removeRocketModel(player)
	local slot = takeSlot(player)
	local base = getPadTop() + SLOT_OFFSETS[slot]
	local model = RocketAssembler.Build(design, base, "Rocket: " .. player.DisplayName)
	model.Name = "Rocket_" .. player.Name
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("HangarBase", base) -- щоб повернути ракету з майданчика назад
	model.Parent = rocketsFolder
end

--------------------------------------------------------------------
-- Гравці
--------------------------------------------------------------------
local function clearRocketAttributes(player)
	player:SetAttribute("RocketBuilt", false)
	player:SetAttribute("RocketDesign", nil)
	player:SetAttribute("RocketCost", nil)
	player:SetAttribute("RocketFuel", nil)
	player:SetAttribute("RocketFuelCapacity", nil)
	player:SetAttribute("RocketState", nil)
end

local function setupPlayer(player)
	if player:GetAttribute("Mission") == nil then
		player:SetAttribute("Mission", DEFAULT_MISSION)
	end
	if player:GetAttribute("RocketBuilt") == nil then
		player:SetAttribute("RocketBuilt", false)
	end
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerRemoving:Connect(removeRocketModel)

--------------------------------------------------------------------
-- 1. Зібрати ракету
--------------------------------------------------------------------
buildEvent.OnServerEvent:Connect(function(player, rawDesign)
	if player:GetAttribute("RocketBuilt") then
		notify(player, "Your rocket is already on the pad. Disassemble it first.", true)
		return
	end
	local design = RocketMath.Sanitize(rawDesign)
	if not design then
		return
	end

	local budget = player:GetAttribute("Budget") or 0
	local missionId = player:GetAttribute("Mission") or DEFAULT_MISSION
	-- Сервер перевіряє ВСЕ сам — клієнту не довіряємо
	local errors, _, stats = RocketMath.Validate(design, budget, missionId)
	if #errors == 1 then
		notify(player, errors[1], true)
		return
	elseif #errors > 1 then
		-- показуємо всі помилки одразу, кожну з нового рядка
		notify(player, "The rocket cannot be built:\n• " .. table.concat(errors, "\n• "), true)
		return
	end

	player:SetAttribute("Budget", budget - stats.cost)
	player:SetAttribute("RocketCost", stats.cost)
	player:SetAttribute("RocketFuel", 0)
	player:SetAttribute("RocketFuelCapacity", stats.fuel)
	player:SetAttribute("RocketDesign", HttpService:JSONEncode(design))
	player:SetAttribute("RocketState", "Hangar")
	player:SetAttribute("RocketBuilt", true) -- останнім: клієнт уже має креслення

	buildRocketModel(player, design)
	notify(player, "Rocket built for $" .. fmt(stats.cost) .. "! Now fuel it up.", false)
end)

--------------------------------------------------------------------
-- 2. Заправити ракету
--   RP-1, якого бракує = (місткість − пальне) × частка RP-1
--   пальне, що додалося = RP-1 / частка RP-1   (решта — кисень з повітря)
--------------------------------------------------------------------
fuelEvent.OnServerEvent:Connect(function(player)
	if not player:GetAttribute("RocketBuilt") then
		return
	end
	if (player:GetAttribute("RocketState") or "Hangar") ~= "Hangar" then
		notify(player, "The rocket is not in the hangar: bring it back from the pad first.", true)
		return
	end
	local fuel = player:GetAttribute("RocketFuel") or 0
	local capacity = player:GetAttribute("RocketFuelCapacity") or 0
	local rp1Missing = (capacity - fuel) * RP1_SHARE
	if rp1Missing < 0.5 then
		notify(player, "Tanks are already full.", false)
		return
	end

	local rp1 = player:GetAttribute("RP1") or 0
	if rp1 < 1 then
		notify(player, "No RP-1 in storage. Wait for the derrick.", true)
		return
	end

	local take = math.min(rp1, rp1Missing)
	local added = take / RP1_SHARE
	local newFuel = fuel + added
	if capacity - newFuel < 1 then
		newFuel = capacity
	end
	player:SetAttribute("RP1", rp1 - take)
	player:SetAttribute("RocketFuel", newFuel)

	if newFuel >= capacity then
		notify(player, "Fueled: +" .. fmt(take) .. " kg RP-1 and +" .. fmt(added - take) .. " kg LOX.", false)
	else
		notify(player, "Partially fueled (+" .. fmt(take) .. " kg RP-1). Wait for the derrick.", false)
	end
end)

--------------------------------------------------------------------
-- 3. Розібрати ракету
--------------------------------------------------------------------
dismantleEvent.OnServerEvent:Connect(function(player)
	if not player:GetAttribute("RocketBuilt") then
		return
	end
	if (player:GetAttribute("RocketState") or "Hangar") ~= "Hangar" then
		notify(player, "The rocket is not in the hangar: bring it back from the pad first.", true)
		return
	end
	local refund = player:GetAttribute("RocketCost") or 0
	local fuel = player:GetAttribute("RocketFuel") or 0
	local rp1 = player:GetAttribute("RP1") or 0
	local capacity = player:GetAttribute("RP1Capacity") or rp1

	player:SetAttribute("Budget", (player:GetAttribute("Budget") or 0) + refund)
	-- RP-1 з баків повертається у сховище (що не влізе — втрачається)
	player:SetAttribute("RP1", math.min(rp1 + fuel * RP1_SHARE, math.max(capacity, rp1)))
	clearRocketAttributes(player) -- RocketBuilt = false першим

	removeRocketModel(player)
	notify(player, "Rocket disassembled: refunded $" .. fmt(refund) .. ".", false)
end)
