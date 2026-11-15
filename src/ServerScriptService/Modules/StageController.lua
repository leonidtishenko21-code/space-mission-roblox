--[[
	StageController (ModuleScript, SERVER)
	Location: ServerScriptService > Modules > StageController

	Stage separation and payload fairing jettison. Called from FlightServer
	(RemoteEvent TriggerStage / JettisonFairing) — the server itself checks whether it is possible.

	SEPARATING STAGE k:
	  1. Shut down the engines of k (flame, light).
	  2. Break the SeparationWeld in the Decoupler<k> folder.
	  3. Move the Stage<k> and Decoupler<k> folders out of the rocket model into a separate debris model
	     → their mass is no longer counted in FlightPhysics:MassKg().
	  4. Give the debris an impulse backwards:  J = m · Δv  (ApplyImpulse), and the rocket a small one forwards.
	  5. After 30 s the debris is removed (Debris).
	  6. Stage k+1 becomes active and its engines ignite.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local NASAData = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NASAData"))
local RocketAssembler = require(script.Parent:WaitForChild("RocketAssembler"))

local F = NASAData.Flight
local M_PER_STUD = F.METERS_PER_STUD

--------------------------------------------------------------------
-- ⚙️ SETTINGS
--------------------------------------------------------------------
local STAGE_SEPARATION_SPEED = 4     -- studs/s: how fast the stage moves back (springs/pyro bolts)
local ROCKET_KICK_SPEED = 0.5        -- studs/s: recoil on the rocket (Newton's third law)
local FAIRING_SIDE_SPEED = 6         -- studs/s: sideways separation of the fairing halves
local DEBRIS_LIFETIME = 30           -- s: then the debris is removed (optimisation)

local StageController = {}

local debrisFolder = workspace:FindFirstChild("RocketDebris")
if not debrisFolder then
	debrisFolder = Instance.new("Folder")
	debrisFolder.Name = "RocketDebris"
	debrisFolder.Parent = workspace
end

-- Moves groups into a new debris model. Returns (model, main part)
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

-- Debris falls with the REAL flight gravity (like the rocket), not with Roblox's 196 studs/s²
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
-- STAGE SEPARATION
--   flight — a FlightPhysics object. Returns ok, message
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

	-- 1) shut down the engines of the spent stage
	flight:Shutdown()

	-- 2) break the link
	if weld then
		weld:Destroy()
	end

	-- 3) move the stage + decoupler out of the model
	local folders = { decoupler }
	local stage = model:FindFirstChild("Stage" .. k)
	if stage then
		table.insert(folders, 1, stage)
	end
	local _, root = detach("SpentStage" .. k, folders)

	-- 4) separation impulse:  J = m · Δv  (the spent stage goes down/back)
	if root then
		root:SetNetworkOwner(nil)
		root:ApplyImpulse(-up * root.AssemblyMass * STAGE_SEPARATION_SPEED)
		root:ApplyAngularImpulse(Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * root.AssemblyMass * 2)
		addFallForce(root)
	end
	flight.core:ApplyImpulse(up * flight.core.AssemblyMass * ROCKET_KICK_SPEED)

	-- 6) next stage
	flight:SetActiveStage(k + 1)
	if flight:Ignite() then
		return true, "Stage " .. k .. " separated. Stage " .. (k + 1) .. " ignition!"
	end
	return true, "Stage " .. k .. " separated. Coasting on a ballistic trajectory."
end

--------------------------------------------------------------------
-- FAIRING JETTISON: the two halves move apart sideways
--   Only allowed high up: in dense air heat and drag would damage the payload.
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
				local side = cf.RightVector * sign -- the halves sit at -X / +X from the axis
				root:ApplyImpulse((side * FAIRING_SIDE_SPEED + cf.UpVector * 1) * root.AssemblyMass)
				-- the half "flips" outward at the top
				root:ApplyAngularImpulse(cf.LookVector * -sign * root.AssemblyMass * 3)
				addFallForce(root)
			end
		end
	end
	model:SetAttribute("HasFairing", false)
	return true, "Fairing jettisoned!"
end

return StageController
