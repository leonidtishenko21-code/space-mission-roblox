--[[
	StageController (ModuleScript, СЕРВЕР)
	Місце: ServerScriptService > Modules > StageController

	Відстріл ступенів і скидання головного обтічника. Викликається з FlightServer
	(RemoteEvent TriggerStage / JettisonFairing) — сервер сам перевіряє, чи це можливо.

	ВІДСТРІЛ СТУПЕНЯ k:
	  1. Вимикаємо двигуни k (полум'я, світло).
	  2. Розриваємо SeparationWeld у папці Decoupler<k>.
	  3. Папки Stage<k> і Decoupler<k> виносимо з моделі ракети в окрему модель-уламок
	     → їхня маса більше не рахується в FlightPhysics:MassKg().
	  4. Уламку даємо імпульс назад:  J = m · Δv  (ApplyImpulse), а ракеті — маленький вперед.
	  5. Через 30 с уламок видаляється (Debris).
	  6. Активним стає ступінь k+1, його двигуни запалюються.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))
local RocketAssembler = require(script.Parent:WaitForChild("RocketAssembler"))

local F = NASAData.Flight
local M_PER_STUD = F.METERS_PER_STUD

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local STAGE_SEPARATION_SPEED = 4     -- studs/с: з якою швидкістю ступінь відходить назад (пружини/піроболти)
local ROCKET_KICK_SPEED = 0.5        -- studs/с: віддача на ракету (третій закон Ньютона)
local FAIRING_SIDE_SPEED = 6         -- studs/с: розведення половинок обтічника вбік
local DEBRIS_LIFETIME = 30           -- с: потім уламки видаляються (оптимізація)

local StageController = {}

local debrisFolder = workspace:FindFirstChild("RocketDebris")
if not debrisFolder then
	debrisFolder = Instance.new("Folder")
	debrisFolder.Name = "RocketDebris"
	debrisFolder.Parent = workspace
end

-- Переносить групи в нову модель-уламок. Повертає (модель, головна деталь)
local function detach(name, folders)
	local debrisModel = Instance.new("Model")
	debrisModel.Name = name
	local root
	for _, f in ipairs(folders) do
		for _, d in ipairs(f:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CollisionGroup = RocketAssembler.DEBRIS_GROUP
				root = root or d
			end
		end
		f.Parent = debrisModel
	end
	debrisModel.Parent = debrisFolder
	Debris:AddItem(debrisModel, DEBRIS_LIFETIME)
	return debrisModel, root
end

-- Уламок падає зі СПРАВЖНЬОЮ гравітацією польоту (як і ракета), а не з Roblox-овими 196 studs/с²
local function addFallForce(root)
	local att = Instance.new("Attachment")
	att.Name = "FallCore"
	att.Parent = root
	local f = Instance.new("VectorForce")
	f.Attachment0 = att
	f.RelativeTo = Enum.ActuatorRelativeTo.World
	f.ApplyAtCenterOfMass = true
	local gStuds = NASAData.Planets.Earth.surfaceGravity / M_PER_STUD
	f.Force = Vector3.new(0, root.AssemblyMass * (workspace.Gravity - gStuds), 0)
	f.Parent = root
end

--------------------------------------------------------------------
-- ВІДСТРІЛ СТУПЕНЯ
--   flight — об'єкт FlightPhysics. Повертає ok, повідомлення
--------------------------------------------------------------------
function StageController.TriggerStage(flight)
	local model = flight.model
	local k = flight.activeStage
	local decoupler = model:FindFirstChild("Decoupler" .. k)
	if not decoupler then
		return false, "This is the last stage — nothing left to separate."
	end
	local weld = decoupler:FindFirstChild("SeparationWeld")
	local up = flight.coreAtt.WorldCFrame.UpVector

	-- 1) двигуни відпрацьованого ступеня — вимкнути
	flight:Shutdown()

	-- 2) розрив зв'язку
	if weld then
		weld:Destroy()
	end

	-- 3) винести ступінь + декуплер з моделі
	local folders = { decoupler }
	local stage = model:FindFirstChild("Stage" .. k)
	if stage then
		table.insert(folders, 1, stage)
	end
	local _, root = detach("SpentStage" .. k, folders)

	-- 4) імпульс відділення:  J = m · Δv  (відпрацьований ступінь — вниз/назад)
	if root then
		root:SetNetworkOwner(nil)
		root:ApplyImpulse(-up * root.AssemblyMass * STAGE_SEPARATION_SPEED)
		root:ApplyAngularImpulse(Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * root.AssemblyMass * 2)
		addFallForce(root)
	end
	flight.core:ApplyImpulse(up * flight.core.AssemblyMass * ROCKET_KICK_SPEED)

	-- 6) наступний ступінь
	flight:SetActiveStage(k + 1)
	if flight:Ignite() then
		return true, "Stage " .. k .. " separated. Stage " .. (k + 1) .. " ignition!"
	end
	return true, "Stage " .. k .. " separated. Coasting on a ballistic trajectory."
end

--------------------------------------------------------------------
-- СКИДАННЯ ОБТІЧНИКА: дві половинки розводяться в боки
--   Дозволено лише високо: в щільному повітрі тепло та опір пошкодили б корисний вантаж.
--------------------------------------------------------------------
function StageController.JettisonFairing(flight)
	local model = flight.model
	local left, right = model:FindFirstChild("FairingLeft"), model:FindFirstChild("FairingRight")
	if not left and not right then
		return false, "No fairing (or it was already jettisoned)."
	end
	local altitudeKm = math.max(flight.core.Position.Y - (model:GetAttribute("PadY") or 0), 0) * M_PER_STUD / 1000
	if altitudeKm < F.FAIRING_MIN_ALTITUDE_KM then
		return false, string.format("Too early: %.0f km. Jettison the fairing above %d km, where the air is very thin.",
			altitudeKm, F.FAIRING_MIN_ALTITUDE_KM)
	end

	local cf = flight.coreAtt.WorldCFrame
	for _, pair in ipairs({ { left, -1 }, { right, 1 } }) do
		local folder, sign = pair[1], pair[2]
		if folder then
			local weld = folder:FindFirstChild("SeparationWeld")
			if weld then
				weld:Destroy()
			end
			local _, root = detach(folder.Name, { folder })
			if root then
				root:SetNetworkOwner(nil)
				local side = cf.RightVector * sign -- половинки стоять по -X / +X від осі
				root:ApplyImpulse((side * FAIRING_SIDE_SPEED + cf.UpVector * 1) * root.AssemblyMass)
				-- половинка "відкидається" верхом назовні
				root:ApplyAngularImpulse(cf.LookVector * -sign * root.AssemblyMass * 3)
				addFallForce(root)
			end
		end
	end
	model:SetAttribute("HasFairing", false)
	return true, "Fairing jettisoned!"
end

return StageController
