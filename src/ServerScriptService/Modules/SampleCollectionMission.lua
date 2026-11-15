--[[
	SampleCollectionMission (ModuleScript, SERVER) — STEP 4: the "Collect a planet sample" mission
	Location: ServerScriptService > Modules > SampleCollectionMission

	Samples are PlanetSample_Moon / PlanetSample_Mars models in Workspace (Planets > MoonZone / MarsZone > Samples).
	They can be freely moved and copied in Studio: the module finds every model named
	PlanetSample_* (attributes Planet = "Moon" | "Mars", SampleName) and adds a ProximityPrompt
	"Collect planet sample" [E].

	Mission flow:
	  1) EVA on the Moon / Mars (STEP 3) → walk up to the glowing sample → hold [E]
	  2) a sealed container with the sample is attached to the spacesuit backpack (PLSS)
	     HUD status: "SAMPLE COLLECTED — RETURN TO THE CAPSULE AND REFUEL THE ROCKET"
	  3) back in the capsule → the container is moved to the capsule's cargo bay
	     (rocket model: SampleCargo, attribute SampleOnBoard)
	  4) STEP 5: ISRU refuel and landing on Earth with the sample = Sample Return

	Player attributes (read by AstronautClient):
	  SamplePlanet  = "Moon" | "Mars" | nil — where the sample is from
	  SampleName    = sample name
	  SampleStowed  = true when it is in the capsule's cargo bay

	The sample disappears after collection and appears again after RESPAWN s (for other players / later missions).
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Mission = {}
Mission.notify = nil -- function(player, text, isError) — set by FlightServer
Mission.PROMPT_DISTANCE = 9
Mission.HOLD_TIME = 1.5
Mission.RESPAWN = 90 -- s
Mission.STATUS_COLLECTED = "SAMPLE COLLECTED — RETURN TO THE CAPSULE AND REFUEL THE ROCKET"

local SUIT_NAME = "NASA_Spacesuit"
local COLORS = {
	Moon = Color3.fromRGB(140, 220, 255),
	Mars = Color3.fromRGB(255, 140, 70),
}
local FACTS = {
	Moon = "Water ice in permanently shadowed craters is a key Artemis target: it can be split into oxygen and hydrogen for rocket fuel.",
	Mars = "Just like Perseverance: the core is sealed in a tube so scientists on Earth can search it for signs of ancient life. The red color comes from iron oxides.",
}

local function say(player, text, isError)
	if Mission.notify then
		Mission.notify(player, text, isError)
	end
end

local function findRocket(player)
	local folder = workspace:FindFirstChild("Rockets")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:GetAttribute("OwnerUserId") == player.UserId then
				return m
			end
		end
	end
	return nil
end

local function newPart(parent, name, shape, size, color, material)
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
	return w
end

-- Sealed sample container: a metal cylinder, a glass window and a glowing band in the planet's colour.
-- Returns the model and its body (the container's vertical axis = the body's UpVector · cf)
local function buildContainer(name, planet, cf, scale)
	scale = scale or 1
	local color = COLORS[planet] or Color3.new(1, 1, 1)
	local model = Instance.new("Model")
	model.Name = name
	local axis = CFrame.Angles(0, 0, math.rad(90)) -- Roblox cylinder axis (X) → vertical
	local body = newPart(model, "Canister", Enum.PartType.Cylinder, Vector3.new(1.5, 0.75, 0.75) * scale,
		Color3.fromRGB(210, 214, 220), Enum.Material.Metal)
	body.CFrame = cf * axis
	body.Reflectance = 0.15
	local window = newPart(model, "Window", Enum.PartType.Cylinder, Vector3.new(0.6, 0.78, 0.78) * scale, color, Enum.Material.Glass)
	window.Transparency = 0.35
	window.CFrame = cf * CFrame.new(0, -0.15 * scale, 0) * axis
	weld(body, window)
	local band = newPart(model, "SealBand", Enum.PartType.Cylinder, Vector3.new(0.12, 0.8, 0.8) * scale, color, Enum.Material.Neon)
	band.CFrame = cf * CFrame.new(0, 0.45 * scale, 0) * axis
	weld(body, band)
	local cap = newPart(model, "Cap", Enum.PartType.Cylinder, Vector3.new(0.2, 0.62, 0.62) * scale, Color3.fromRGB(60, 62, 70), Enum.Material.Metal)
	cap.CFrame = cf * CFrame.new(0, 0.82 * scale, 0) * axis
	weld(body, cap)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 6
	light.Brightness = 1.5
	light.Parent = band
	model.PrimaryPart = body
	model:SetAttribute("Planet", planet)
	return model, body
end

--------------------------------------------------------------------
-- Player state
--------------------------------------------------------------------
local carried = {} -- [player] = { planet, name, container }

function Mission.HasSample(player)
	return player:GetAttribute("SamplePlanet") ~= nil
end

function Mission.IsStowed(player)
	return player:GetAttribute("SampleStowed") == true
end

-- remove the container from the backpack (does not touch attributes)
local function dropFromSuit(player)
	local c = carried[player]
	if c and c.container and c.container.Parent then
		c.container:Destroy()
	end
	if c then
		c.container = nil
	end
end

-- Flight ended / player left: forget the sample
function Mission.Reset(player)
	dropFromSuit(player)
	carried[player] = nil
	if player.Parent then
		player:SetAttribute("SamplePlanet", nil)
		player:SetAttribute("SampleName", nil)
		player:SetAttribute("SampleStowed", nil)
	end
end

-- Sample in the capsule's cargo bay: the container is welded to the capsule floor next to the seat
function Mission.Stow(player)
	local c = carried[player]
	if not c or player:GetAttribute("SampleStowed") then
		return false
	end
	local model = findRocket(player)
	local seat = model and model:FindFirstChild("PilotSeat", true)
	if not seat then
		return false
	end
	dropFromSuit(player)
	local old = model:FindFirstChild("SampleCargo", true)
	if old then
		old:Destroy()
	end
	local up = seat.CFrame.UpVector
	local cf = CFrame.lookAt(seat.Position, seat.Position + seat.CFrame.LookVector, up)
		* CFrame.new(0.9, 0.55, 0.6)
	local cargo, body = buildContainer("SampleCargo", c.planet, cf, 0.9)
	for _, p in ipairs(cargo:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = seat.Anchored
			p.CollisionGroup = seat.CollisionGroup
		end
	end
	weld(seat, body)
	cargo.Parent = seat.Parent
	model:SetAttribute("SampleOnBoard", c.planet)
	player:SetAttribute("SampleStowed", true)
	say(player, "📦 Sample container secured in the capsule cargo bay. Refuel the rocket and bring it home to Earth!", false)
	return true
end

--------------------------------------------------------------------
-- Collecting a sample
--------------------------------------------------------------------
local function collect(player, sample, prompt)
	local planet = sample:GetAttribute("Planet")
	if player:GetAttribute("EVA") ~= true then
		say(player, "Only a suited astronaut on a surface EVA [E] can collect a sample.", true)
		return
	end
	if Mission.HasSample(player) then
		say(player, "Your container is already full — deliver this sample to Earth first.", true)
		return
	end
	local character = player.Character
	local suit = character and character:FindFirstChild(SUIT_NAME)
	local pack = suit and suit:FindFirstChild("PLSS_Backpack")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (pack and root) or not sample.PrimaryPart then
		return
	end
	if (root.Position - sample.PrimaryPart.Position).Magnitude > Mission.PROMPT_DISTANCE + 6 then
		return
	end

	-- sealed container — on the right side of the PLSS backpack
	local ps = pack.Size
	local cf = pack.CFrame * CFrame.new(ps.X / 2 + 0.42, -ps.Y * 0.1, 0)
	local container, body = buildContainer("SampleContainer", planet, cf, 1)
	weld(pack, body)
	container.Parent = suit -- removed together with the spacesuit

	local name = sample:GetAttribute("SampleName") or "Planet sample"
	carried[player] = { planet = planet, name = name, container = container }
	player:SetAttribute("SampleName", name)
	player:SetAttribute("SampleStowed", false)
	player:SetAttribute("SamplePlanet", planet)

	-- the sample disappears and after RESPAWN s appears again in the same place
	local parent = sample.Parent
	prompt.Enabled = false
	sample.Parent = ServerStorage
	task.delay(Mission.RESPAWN, function()
		if parent and parent.Parent then
			sample.Parent = parent
			prompt.Enabled = true
		end
	end)

	say(player, "🧪 " .. name .. " — sealed in the container on your backpack. " .. Mission.STATUS_COLLECTED .. ".", false)
	if FACTS[planet] then
		task.delay(4, say, player, "🔬 " .. FACTS[planet], false)
	end
end

local wired = setmetatable({}, { __mode = "k" })
local function wire(sample)
	if wired[sample] or not sample:IsA("Model") then
		return
	end
	local core = sample.PrimaryPart or sample:FindFirstChild("Core") or sample:FindFirstChildWhichIsA("BasePart")
	if not core then
		return
	end
	wired[sample] = true
	if sample:GetAttribute("Planet") == nil then
		sample:SetAttribute("Planet", sample.Name:match("PlanetSample_(%a+)") or "Moon")
	end
	local prompt = core:FindFirstChild("CollectPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "CollectPrompt"
		prompt.Parent = core
	end
	prompt.ActionText = "Collect planet sample"
	prompt.ObjectText = sample:GetAttribute("SampleName") or "Sample"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = Mission.HOLD_TIME
	prompt.MaxActivationDistance = Mission.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player)
		collect(player, sample, prompt)
	end)
end

-- Fallback path (button / tests): take the nearest sample within the prompt range
function Mission.CollectNearest(player)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local best, bestD = nil, Mission.PROMPT_DISTANCE + 1
	for sample in pairs(wired) do
		if sample.Parent and sample:IsDescendantOf(workspace) and sample.PrimaryPart then
			local d = (sample.PrimaryPart.Position - root.Position).Magnitude
			if d < bestD then
				best, bestD = sample, d
			end
		end
	end
	if not best then
		return false
	end
	collect(player, best, best.PrimaryPart:FindFirstChild("CollectPrompt"))
	return true
end

for _, d in ipairs(workspace:GetDescendants()) do
	if d.Name:match("^PlanetSample_") then
		wire(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if d.Name:match("^PlanetSample_") then
		task.defer(wire, d)
	end
end)

-- Back in the capsule with a sample → move it to the cargo bay
local function hook(player)
	player:GetAttributeChangedSignal("InCapsule"):Connect(function()
		if player:GetAttribute("InCapsule") and carried[player] and not player:GetAttribute("SampleStowed") then
			Mission.Stow(player)
		end
	end)
	player.CharacterRemoving:Connect(function()
		-- died with the sample on the backpack — the sample is lost (in the capsule it is safe)
		if carried[player] and not player:GetAttribute("SampleStowed") then
			Mission.Reset(player)
		end
	end)
end
for _, p in ipairs(Players:GetPlayers()) do
	hook(p)
end
Players.PlayerAdded:Connect(hook)
Players.PlayerRemoving:Connect(function(player)
	carried[player] = nil
end)

return Mission
