--[[
	EVAExitController (ModuleScript, SERVER) — STEP 3: the astronaut goes out onto the surface (EVA)
	Location: ServerScriptService > Modules > EVAExitController

	Exit [E] is allowed only on the MOON / MARS, when the rocket:
	  • stands on the surface (flight.landed), or
	  • hovers: rocket bottom < 15 studs above the ground and speed < 15 m/s
	    (then the engine gently lands the empty capsule on its own — EDL.HoldLanding)
	On Earth landing ends the flight (report → hangar), so EVA is not needed there.

	During EVA:
	  • player attributes: EVA = true, EVAGravity = planet g (m/s²), EVAPlanet = "Moon" | "Mars"
	    (AstronautClient handles low gravity, jumps and the jetpack on Space)
	  • at the hatch — a ProximityPrompt "BOARD CAPSULE [F]" (works only for the owner)
	  • the spacesuit uses O₂ (SpacesuitManager); when O₂ = 0 the astronaut loses health
	  • the astronaut's death aborts the mission
	Attribute CanEVA (player) — whether exiting is possible right now (the [E] hint in the HUD).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local modules = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modules:WaitForChild("NASAData"))
local PlanetZoneManager = require(modules:WaitForChild("PlanetZoneManager"))
local CapsuleSeatSystem = require(script.Parent:WaitForChild("CapsuleSeatSystem"))
local SpacesuitManager = require(script.Parent:WaitForChild("SpacesuitManager"))
local EDL = require(script.Parent:WaitForChild("EDLBrakingSystems"))

local M_PER_STUD = NASAData.Flight.METERS_PER_STUD

local EVA = {}
EVA.notify = nil              -- function(player, text, isError) — set by FlightServer
EVA.MAX_HOVER_ALT = 15        -- studs: below this you can jump out of a hovering capsule
EVA.MAX_HOVER_SPEED = 15      -- m/s (same as a safe landing)
EVA.MIN_UP_DOT = 0.75         -- you cannot walk on a steep side of a sphere planet (≈ 41° from the top)
EVA.BOARD_DISTANCE = 14       -- studs from the hatch
local O2_DAMAGE = 6           -- HP/s when the oxygen has run out
local STAND_OFF = 7           -- studs from the rocket edge to the exit point (clear of legs and nozzles)

local sessions = {} -- [player] = { flight, hatch, prompt, conns }

local function say(player, text, isError)
	if EVA.notify then
		EVA.notify(player, text, isError)
	end
end

local function rocketParams(flight)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { flight.model }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local marker = workspace:FindFirstChild("LandingTargetMarker")
	if marker then
		table.insert(ignore, marker)
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Distance from the core centre to the BOTTOM of the rocket along gravity (studs) — same as in FlightPhysics
local function bottomReach(flight, gdir)
	local core = flight.core
	local reach = 0
	for _, p in ipairs(flight.model:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			local cf, s = p.CFrame, p.Size
			local ext = math.abs(gdir:Dot(cf.RightVector)) * s.X / 2 + math.abs(gdir:Dot(cf.UpVector)) * s.Y / 2
				+ math.abs(gdir:Dot(cf.LookVector)) * s.Z / 2
			reach = math.max(reach, (p.Position - core.Position):Dot(gdir) + ext)
		end
	end
	return reach
end

-- Whether exiting is possible now. Returns: ok, refusal reason, data { planet, up, hovering }
function EVA.CanExit(player, flight)
	if not flight or flight.ended or not flight.core.Parent then
		return false, "The rocket is not in flight."
	end
	if not player:GetAttribute("InCapsule") or sessions[player] then
		return false, "You are not in the capsule."
	end
	local core = flight.core
	local _, planet = PlanetZoneManager.Locate(core.Position)
	if planet ~= "Moon" and planet ~= "Mars" then
		return false, "Spacewalks in open space are not allowed. Land on the Moon or Mars first."
	end
	local gVec = PlanetZoneManager.GravityVector(core.Position, 9.81)
	local gdir = gVec.Magnitude > 1e-6 and gVec.Unit or -Vector3.yAxis
	local up = -gdir
	if up.Y < EVA.MIN_UP_DOT then
		return false, "The slope here is too steep — land closer to the crater / canyon."
	end
	-- exit ONLY after landing (not while hovering or flying)
	if not flight.landed then
		return false, "You can only leave the capsule after the rocket has landed."
	end
	return true, nil, { planet = planet, up = up, hovering = false }
end

-- A point next to the rocket legs on the ground (where the astronaut stands and where the hatch for boarding is)
local function groundSpot(flight, up)
	local core = flight.core
	local side = core.CFrame.RightVector
	side = side - up * side:Dot(up)
	if side.Magnitude < 0.1 then
		side = Vector3.xAxis
	end
	side = side.Unit
	local params = rocketParams(flight)
	-- try several sides — take the first one with ground
	for i = 0, 3 do
		local dir = CFrame.fromAxisAngle(up, i * math.pi / 2):VectorToWorldSpace(side)
		-- how far the rocket (including legs) sticks out on this side
		local radius = math.clamp(bottomReach(flight, dir), 2, 30)
		local origin = core.Position + dir * (radius + STAND_OFF) + up * 25
		local hit = workspace:Raycast(origin, -up * 400, params)
		if hit then
			return hit.Position, dir
		end
	end
	return core.Position + side * (math.clamp(bottomReach(flight, side), 2, 30) + STAND_OFF), side
end

-- The SERVER runs the rocket physics (anti-cheat). The Seat and Roblox auto-ownership hand it to the client
-- of the nearest player — then the exiting character "pushes" the capsule up. We give it back to the server.
function EVA.ServerOwn(flight)
	local core = flight and flight.core
	if core and core.Parent and not core.Anchored and (core:GetNetworkOwnershipAuto() or core:GetNetworkOwner() ~= nil) then
		pcall(core.SetNetworkOwner, core, nil)
	end
end

local function clearSession(player)
	local s = sessions[player]
	if not s then
		return
	end
	sessions[player] = nil
	for _, c in ipairs(s.conns) do
		c:Disconnect()
	end
	if s.hatch and s.hatch.Parent then
		s.hatch:Destroy()
	end
	if player.Parent then
		player:SetAttribute("EVA", nil)
		player:SetAttribute("EVAGravity", nil)
		player:SetAttribute("EVAPlanet", nil)
	end
end

function EVA.IsOut(player)
	return sessions[player] ~= nil
end

--------------------------------------------------------------------
-- Boarding the capsule (ProximityPrompt "BOARD CAPSULE [F]")
--------------------------------------------------------------------
function EVA.Board(player)
	local s = sessions[player]
	if not s then
		return false
	end
	local flight = s.flight
	if flight.ended or not flight.model.Parent then
		clearSession(player)
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not s.hatch.Parent or (root.Position - s.hatch.WorldPosition).Magnitude > EVA.BOARD_DISTANCE + 6 then
		say(player, "Get closer to the capsule hatch.", true)
		return false
	end
	clearSession(player)
	if not CapsuleSeatSystem.Seat(player, flight.model) then
		say(player, "Could not get into the capsule seat.", true)
		return false
	end
	EVA.ServerOwn(flight)
	SpacesuitManager.SetJets(player, false)
	say(player, "🚀 You are in the capsule. Hatch sealed, O₂ refilling. Shift / Z — throttle for liftoff.", false)
	return true
end

--------------------------------------------------------------------
-- Leaving the capsule [E]
--------------------------------------------------------------------
function EVA.Exit(player, flight)
	local ok, reason, info = EVA.CanExit(player, flight)
	if not ok then
		say(player, "🚪 " .. reason, true)
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and humanoid.Health > 0 and character.PrimaryPart) then
		return false
	end
	if not SpacesuitManager.IsEquipped(player) then
		SpacesuitManager.Equip(player) -- you cannot go outside without a spacesuit
	end

	-- empty capsule: on the ground the engine is off, while hovering it lands gently on its own
	if info.hovering then
		EDL.HoldLanding(flight)
	elseif not (flight.edl and flight.edl.autoLand) then
		flight:SetThrottle(0)
	end
	flight:SetInput(Vector3.zero)

	local cfg = PlanetZoneManager.CONFIG[info.planet]
	local s = { flight = flight, conns = {} }
	sessions[player] = s
	-- EVA attributes first (the client releases the rocket camera), then unseating
	player:SetAttribute("EVAGravity", cfg.gravity)
	player:SetAttribute("EVAPlanet", info.planet)
	player:SetAttribute("EVA", true)
	player:SetAttribute("CanEVA", false)
	EVA.ServerOwn(flight)
	CapsuleSeatSystem.Release(player)

	local spot, dir = groundSpot(flight, info.up)
	local standPos = spot + info.up * 3.5
	local standCF = CFrame.lookAt(standPos, standPos + dir, info.up)
	character:PivotTo(standCF)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		-- the character is separate again — its movement is simulated by the player's client (no input lag)
		pcall(root.SetNetworkOwner, root, player)
		-- the client may receive the teleport before the SeatWeld removal and ignore it —
		-- then the character "jumps" onto the capsule roof. We check and retry a few times.
		task.spawn(function()
			for _ = 1, 10 do
				task.wait(0.15)
				if sessions[player] ~= s or not root.Parent then
					return
				end
				-- watch for up to 1.5 s (the astronaut may already be walking — move back only if they are above the exit point)
				local d = root.Position - standPos
				if d:Dot(info.up) > 3 or d.Magnitude > 12 then
					character:PivotTo(standCF)
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end
		end)
	end
	EVA.ServerOwn(flight)

	-- boarding hatch: a point on the ground next to the legs, attached to the rocket (moves with it)
	local hatch = Instance.new("Attachment")
	hatch.Name = "EVAHatch"
	hatch.Parent = flight.core
	hatch.WorldPosition = spot + info.up * 2.5
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardCapsule"
	prompt.ActionText = "BOARD CAPSULE"
	prompt.ObjectText = "Capsule · " .. player.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = EVA.BOARD_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Parent = hatch
	s.hatch = hatch
	s.prompt = prompt
	table.insert(s.conns, prompt.Triggered:Connect(function(who)
		if who == player then
			EVA.Board(player)
		else
			say(who, "This capsule belongs to another astronaut.", true)
		end
	end))

	-- the astronaut's death on the surface aborts the mission
	table.insert(s.conns, humanoid.Died:Connect(function()
		if sessions[player] == s then
			say(player, "☠ The astronaut died during the EVA. Mission aborted.", true)
			clearSession(player)
			if not flight.ended then
				flight:Stop("manual")
			end
		end
	end))

	say(player, string.format("🧑‍🚀 EVA ON %s! g = %.2f m/s². Space — jump, hold in the air — jetpack. Back — [F] at the hatch.",
		cfg.nameOn, cfg.gravity), false)
	if info.hovering then
		task.delay(2.5, say, player, "The empty capsule is landing softly on its own.", false)
	end
	return true
end

--------------------------------------------------------------------
-- Every half second from FlightServer: the [E] hint in the HUD
--------------------------------------------------------------------
function EVA.Update(player, flight)
	local can = false
	if player:GetAttribute("InCapsule") and not sessions[player] then
		can = EVA.CanExit(player, flight)
	end
	if player:GetAttribute("CanEVA") ~= can then
		player:SetAttribute("CanEVA", can)
	end
end

-- Flight ended / player left — clean everything up
function EVA.End(player)
	clearSession(player)
	if player.Parent then
		player:SetAttribute("CanEVA", nil)
	end
end

-- Oxygen has run out — the astronaut loses health (once per second)
local timer = 0
RunService.Heartbeat:Connect(function(dt)
	timer += dt
	if timer < 1 then
		return
	end
	timer = 0
	for player in pairs(sessions) do
		local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 and (player:GetAttribute("SuitO2") or 100) <= 0 then
			h:TakeDamage(O2_DAMAGE)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	clearSession(player)
end)

return EVA
