--[[
	CapsuleSeatSystem (ModuleScript, SERVER) — STEP 1: the character flies inside the capsule
	Location: ServerScriptService > Modules > CapsuleSeatSystem

	  AddSeat(model, pod)     — RocketAssembler.Build: an invisible PilotSeat in the capsule (Capsule_Dragon / Capsule_Mercury),
	                            welded to the flight core. It moves together with the rocket (MoveTo / Unlock).
	  Seat(player, model)     — "To the launch pad": seats the character and blocks jumping out
	  SetLocked(player, bool) — exit lock (JumpPower = 0). STEP 3 (EVA) removes the lock after landing
	  Release(player)         — unseat and restore everything (before a teleport / rocket destruction)

	Player attributes (read by AstronautClient): InCapsule, CapsuleLocked

	Physics: the character's parts become Massless while seated — the rocket's centre of mass does not shift,
	and FlightPhysics computes the force from core.AssemblyMass anyway, so accelerations stay exact.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local CapsuleSeatSystem = {}

CapsuleSeatSystem.SEAT_NAME = "PilotSeat"
local SEAT_HEIGHT = 1.2 -- studs above the capsule floor
local GHOST_AFTER_EXIT = 1.5 -- s: for this long after exiting the character still passes through the rocket body

-- Astronaut collision group: does not collide with the rocket body. Otherwise, when sitting down
-- or exiting (the character is inside the capsule for a frame), physics throws the rocket up.
local ASTRONAUT_GROUP = "Astronaut"
local ROCKET_GROUP = "Rocket"
pcall(function()
	if not PhysicsService:IsCollisionGroupRegistered(ASTRONAUT_GROUP) then
		PhysicsService:RegisterCollisionGroup(ASTRONAUT_GROUP)
	end
	if not PhysicsService:IsCollisionGroupRegistered(ROCKET_GROUP) then
		PhysicsService:RegisterCollisionGroup(ROCKET_GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(ASTRONAUT_GROUP, ROCKET_GROUP, false)
end)

-- Invisible in the seat: the astronaut sits INSIDE the capsule — nobody can see them (nor the spacesuit
-- that appears at the Kármán line). The original transparency is restored on exit.
local function hideOne(s, d)
	if (d:IsA("BasePart") or d:IsA("Decal")) and s.hidden[d] == nil and d.Name ~= "HumanoidRootPart" then
		s.hidden[d] = d.Transparency
		d.Transparency = 1
	elseif d:IsA("ParticleEmitter") and s.hidden[d] == nil then
		s.hidden[d] = d.Enabled
		d.Enabled = false
	end
end
local function hideCharacter(s)
	for _, d in ipairs(s.character:GetDescendants()) do
		hideOne(s, d)
	end
	table.insert(s.conns, s.character.DescendantAdded:Connect(function(d)
		task.defer(hideOne, s, d) -- spacesuit / container added during flight
	end))
end
local function showCharacter(s)
	for d, v in pairs(s.hidden) do
		if d.Parent then
			if typeof(v) == "boolean" then
				d.Enabled = v
			else
				d.Transparency = v
			end
		end
	end
	s.hidden = {}
end

local function setGhost(character, on)
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			if on and d.CollisionGroup == "Default" then
				d.CollisionGroup = ASTRONAUT_GROUP
			elseif not on and d.CollisionGroup == ASTRONAUT_GROUP then
				d.CollisionGroup = "Default"
			end
		end
	end
end

local sessions = {} -- [player] = { seat, humanoid, character, conns, massless, jump, locked }

--------------------------------------------------------------------
-- Seat in the capsule (called by RocketAssembler.Build)
--------------------------------------------------------------------
function CapsuleSeatSystem.AddSeat(model, pod, collisionGroup)
	if not pod then
		return nil
	end
	local bottom = pod:FindFirstChild("BottomMount")
	-- grey cylinders are rotated (a Roblox cylinder's axis is X), so the part height = Size.X
	local base = bottom and bottom.WorldPosition or (pod.Position - Vector3.new(0, pod.Size.X / 2, 0))

	local seat = Instance.new("Seat")
	seat.Name = CapsuleSeatSystem.SEAT_NAME
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.CFrame = CFrame.new(base + Vector3.new(0, SEAT_HEIGHT, 0))
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false -- nobody sits down by accident when touching the rocket; seating only via Seat:Sit()
	seat.CanQuery = false
	seat.Massless = true
	seat.Anchored = pod.Anchored
	seat.CollisionGroup = collisionGroup or pod.CollisionGroup
	seat.Parent = pod.Parent

	local weld = Instance.new("WeldConstraint")
	weld.Name = "SeatMount"
	weld.Part0 = pod
	weld.Part1 = seat
	weld.Parent = seat
	return seat
end

function CapsuleSeatSystem.FindSeat(model)
	return model and model:FindFirstChild(CapsuleSeatSystem.SEAT_NAME, true)
end

function CapsuleSeatSystem.IsSeated(player)
	local s = sessions[player]
	return s ~= nil and s.seat.Occupant == s.humanoid
end

function CapsuleSeatSystem.GetSeat(player)
	local s = sessions[player]
	return s and s.seat
end

--------------------------------------------------------------------
-- Jump-out lock
--------------------------------------------------------------------
function CapsuleSeatSystem.SetLocked(player, locked)
	local s = sessions[player]
	if not s then
		return
	end
	s.locked = locked
	local h = s.humanoid
	if locked then
		h.JumpPower = 0
		h.JumpHeight = 0
	else
		h.UseJumpPower, h.JumpPower, h.JumpHeight = s.jump[1], s.jump[2], s.jump[3]
	end
	player:SetAttribute("CapsuleLocked", locked)
end

--------------------------------------------------------------------
-- Unseating
--------------------------------------------------------------------
function CapsuleSeatSystem.Release(player)
	local s = sessions[player]
	if not s then
		return
	end
	sessions[player] = nil
	for _, c in ipairs(s.conns) do
		c:Disconnect()
	end
	showCharacter(s)
	for p in pairs(s.massless) do
		if p.Parent then
			p.Massless = false
		end
	end
	local h = s.humanoid
	if h.Parent then
		h.UseJumpPower, h.JumpPower, h.JumpHeight = s.jump[1], s.jump[2], s.jump[3]
		if s.seat.Parent and s.seat.Occupant == h then
			local seatWeld = s.seat:FindFirstChild("SeatWeld")
			if seatWeld then
				seatWeld:Destroy()
			end
		end
		h.Sit = false
	end
	if player.Parent then
		player:SetAttribute("InCapsule", nil)
		player:SetAttribute("CapsuleLocked", nil)
	end
	-- keep passing through the body a little longer (while the client moves the character outside)
	local character = s.character
	task.delay(GHOST_AFTER_EXIT, function()
		if sessions[player] == nil and character.Parent then
			setGhost(character, false)
		end
	end)
end

--------------------------------------------------------------------
-- Sitting down
--------------------------------------------------------------------
function CapsuleSeatSystem.Seat(player, model)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = CapsuleSeatSystem.FindSeat(model)
	if not (humanoid and humanoid.Health > 0 and seat and character.PrimaryPart) then
		return false
	end
	CapsuleSeatSystem.Release(player)

	local s = {
		seat = seat,
		humanoid = humanoid,
		character = character,
		conns = {},
		massless = {},
		locked = false,
		jump = { humanoid.UseJumpPower, humanoid.JumpPower, humanoid.JumpHeight },
		hidden = {},
	}
	sessions[player] = s

	humanoid.Sit = false
	setGhost(character, true)
	character:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
	seat:Sit(humanoid)

	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") and not d.Massless then
			s.massless[d] = true
			d.Massless = true
		end
	end
	CapsuleSeatSystem.SetLocked(player, true)
	hideCharacter(s)
	player:SetAttribute("InCapsule", true)

	table.insert(s.conns, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if sessions[player] ~= s or seat.Occupant == humanoid then
			return
		end
		if not s.locked then
			-- the lock was removed (STEP 3) and the player left on their own — clear the session
			CapsuleSeatSystem.Release(player)
			return
		end
		-- leaving is not allowed during ascent: put them back in the seat
		task.defer(function()
			if sessions[player] == s and s.locked and seat.Occupant == nil and seat.Parent
				and humanoid.Health > 0 and character.Parent then
				seat:Sit(humanoid)
			end
		end)
	end))
	table.insert(s.conns, humanoid.Died:Connect(function()
		CapsuleSeatSystem.Release(player)
	end))
	table.insert(s.conns, seat.AncestryChanged:Connect(function()
		if not seat:IsDescendantOf(workspace) then
			CapsuleSeatSystem.Release(player)
		end
	end))
	return true
end

Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
end)

return CapsuleSeatSystem
