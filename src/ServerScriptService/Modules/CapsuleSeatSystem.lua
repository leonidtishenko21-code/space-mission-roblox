--[[
	CapsuleSeatSystem (ModuleScript, СЕРВЕР) — КРОК 1: персонаж летить усередині капсули
	Місце: ServerScriptService > Modules > CapsuleSeatSystem

	  AddSeat(model, pod)     — RocketAssembler.Build: невидиме крісло PilotSeat у капсулі (Capsule_Dragon / Capsule_Mercury),
	                            приварене до ядра польоту. Рухається разом із ракетою (MoveTo / Unlock).
	  Seat(player, model)     — «На стартовий стіл»: саджає персонажа в крісло, блокує вистрибування
	  SetLocked(player, bool) — блок виходу (JumpPower = 0). КРОК 3 (EVA) знімає блок після посадки
	  Release(player)         — висадити й повернути все як було (перед телепортом / знищенням ракети)

	Атрибути гравця (читає AstronautClient): InCapsule, CapsuleLocked

	Фізика: деталі персонажа стають Massless, поки він у кріслі — центр мас ракети не зміщується,
	а FlightPhysics усе одно рахує силу від core.AssemblyMass, тож прискорення лишаються точними.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local CapsuleSeatSystem = {}

CapsuleSeatSystem.SEAT_NAME = "PilotSeat"
local SEAT_HEIGHT = 1.2 -- studs над дном капсули
local GHOST_AFTER_EXIT = 1.5 -- с: стільки після висадки персонаж ще проходить крізь корпус ракети

-- Група колізій астронавта: не зітвовхується з корпусом ракети. Інакше в момент посадки в крісло
-- чи виходу (персонаж на кадр опиняється всередині капсули) фізика підкидає ракету.
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

-- Невидимість у кріслі: астронавт сидить ВСЕРЕДИНІ капсули — його не видно нікому (і скафандр,
-- який з'являється на лінії Кармана, теж). Оригінальна прозорість повертається при виході.
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
		task.defer(hideOne, s, d) -- скафандр / контейнер, додані в польоті
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
-- Крісло в капсулі (викликає RocketAssembler.Build)
--------------------------------------------------------------------
function CapsuleSeatSystem.AddSeat(model, pod, collisionGroup)
	if not pod then
		return nil
	end
	local bottom = pod:FindFirstChild("BottomMount")
	-- сірі циліндри повернуті (вісь Roblox-циліндра — X), тому висота деталі = Size.X
	local base = bottom and bottom.WorldPosition or (pod.Position - Vector3.new(0, pod.Size.X / 2, 0))

	local seat = Instance.new("Seat")
	seat.Name = CapsuleSeatSystem.SEAT_NAME
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.CFrame = CFrame.new(base + Vector3.new(0, SEAT_HEIGHT, 0))
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false -- ніхто не сяде випадково, торкнувшись ракети; садимо лише через Seat:Sit()
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
-- Блок вистрибування
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
-- Висадка
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
	-- ще трохи проходимо крізь корпус (поки клієнт переносить персонажа назовні)
	local character = s.character
	task.delay(GHOST_AFTER_EXIT, function()
		if sessions[player] == nil and character.Parent then
			setGhost(character, false)
		end
	end)
end

--------------------------------------------------------------------
-- Посадка в крісло
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
			-- блок знято (КРОК 3) і гравець вийшов сам — прибираємо сесію
			CapsuleSeatSystem.Release(player)
			return
		end
		-- під час розгону вийти не можна: повертаємо в крісло
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
