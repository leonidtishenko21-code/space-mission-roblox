--[[
	RocketAssembler (ModuleScript, SERVER)
	Location: ServerScriptService > Modules > RocketAssembler
	(on the server, not in ReplicatedStorage: clients cannot see or read this code)

	Builds a 3D rocket from the blueprint (RocketMath.Layout) out of grey primitives (Greybox):

	  Rocket_<name> (Model, PrimaryPart = capsule with Attachment "FlightCore")
	  ├─ Stage1       (Folder)  engines + tanks of the bottom stage
	  ├─ Decoupler1   (Folder)  ring + SeparationWeld (broken by StageController)
	  ├─ Stage2 …      (Folder)
	  ├─ Payload      (Folder)  capsule, cone, side instruments, label
	  ├─ FairingLeft  (Folder)  fairing half + SeparationWeld
	  └─ FairingRight (Folder)

	Folder attributes (read by FlightPhysics):
	  all groups:  DryMass (kg)
	  StageN:      FuelMass, FuelCapacity (kg), Thrust / ThrustVac (N), Isp / IspVac (s), EngineId
	Model attributes: OwnerUserId, State ("Hangar" | "OnPad" | "Flight"), StageCount, ActiveStage,
	  BasePosition (Vector3 — centre of the rocket bottom), PadY, HasFairing

	Mount points (Attachment) on every part:
	  BottomMount / TopMount — bottom and top of the module on the axis (orientation: +Y = rocket up)
	  NozzlePoint            — nozzle exit (+Y points DOWN, where the flame goes)
	  SideMount              — side mount (RCS, antennas, science instruments)

	🔧 BLENDER: when MeshParts are ready, add an Attachment "BottomMount" to each mesh at the same
	point (module bottom) and call RocketAssembler.ReplaceVisual(greyPart, meshTemplate).
	Physics does NOT change: masses come from attributes, not from part sizes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local ServerStorage = game:GetService("ServerStorage")

local modulesFolder = ReplicatedStorage:WaitForChild("Modules")
local NASAData = require(modulesFolder:WaitForChild("NASAData"))
local RocketMath = require(modulesFolder:WaitForChild("RocketMath"))
local CapsuleSeatSystem = require(script.Parent:WaitForChild("CapsuleSeatSystem"))

local Modules = NASAData.Modules

local RocketAssembler = {}

--------------------------------------------------------------------
-- Collision groups: separated stages and the fairing do not push the rocket
--------------------------------------------------------------------
RocketAssembler.ROCKET_GROUP = "Rocket"
RocketAssembler.DEBRIS_GROUP = "RocketDebris"

for _, name in ipairs({ RocketAssembler.ROCKET_GROUP, RocketAssembler.DEBRIS_GROUP }) do
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end
PhysicsService:CollisionGroupSetCollidable(RocketAssembler.ROCKET_GROUP, RocketAssembler.DEBRIS_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(RocketAssembler.DEBRIS_GROUP, RocketAssembler.DEBRIS_GROUP, false)

--------------------------------------------------------------------
-- Basic parts
--------------------------------------------------------------------
local UP = CFrame.Angles(0, 0, math.rad(90)) -- a Roblox cylinder's axis is X, rotate it upright

local function newPart(parent, name, size, cframe, color, material, canCollide, shape)
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape -- set the shape BEFORE the size so Roblox does not change Size
	end
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = canCollide ~= false
	p.CollisionGroup = RocketAssembler.ROCKET_GROUP
	p.Parent = parent
	return p
end

-- Vertical cylinder: bottom at height y0, height h, diameter d
local function vCylinder(parent, name, base, x, z, y0, h, d, color, material)
	return newPart(parent, name, Vector3.new(h, d, d),
		CFrame.new(base + Vector3.new(x, y0 + h / 2, z)) * UP, color, material, true, Enum.PartType.Cylinder)
end

-- Stepped cone: the diameter changes smoothly from d0 (bottom) to d1 (top). Returns all pieces.
local function taper(parent, name, base, y0, h, d0, d1, color, material, segments)
	local parts = {}
	for k = 1, segments do
		local t = (k - 0.5) / segments
		table.insert(parts, vCylinder(parent, name, base, 0, 0, y0 + (k - 1) * h / segments, h / segments,
			d0 + (d1 - d0) * t, color, material))
	end
	return parts
end

-- Attachment at a world point. Orientation: +Y = up (or down if flipDown), regardless of the part's rotation
local function addMount(part, name, worldPos, flipDown)
	local a = Instance.new("Attachment")
	a.Name = name
	a.Parent = part
	local cf = CFrame.new(worldPos)
	if flipDown then
		cf *= CFrame.Angles(math.pi, 0, 0)
	end
	a.WorldCFrame = cf
	return a
end

-- Engine flame and light at NozzlePoint (off until the stage is ignited)
local function addEngineFX(nozzle, bellDiameter)
	local flame = Instance.new("ParticleEmitter")
	flame.Name = "Flame"
	flame.Texture = "rbxasset://textures/particles/fire_main.dds"
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 245, 210)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 160, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 50, 20)),
	})
	flame.LightEmission = 1
	flame.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, bellDiameter * 0.8),
		NumberSequenceKeypoint.new(1, bellDiameter * 2.2),
	})
	flame.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	flame.Lifetime = NumberRange.new(0.25, 0.45)
	flame.Rate = 90
	flame.Speed = NumberRange.new(30, 40)
	flame.SpreadAngle = Vector2.new(5, 5)
	flame.EmissionDirection = Enum.NormalId.Top -- the attachment's +Y = down from the nozzle
	-- the flame moves with the nozzle: otherwise it is invisible at hundreds of studs/s
	flame.LockedToPart = true
	flame.Enabled = false
	flame.Parent = nozzle

	local light = Instance.new("PointLight")
	light.Name = "EngineLight"
	light.Color = Color3.fromRGB(255, 170, 70)
	light.Range = 18
	light.Brightness = 4
	light.Enabled = false
	light.Parent = nozzle
end

--------------------------------------------------------------------
-- 🔧 BLENDER: meshes from ServerStorage/RocketParts (prepared by SetupAssets_Step5.lua)
-- The grey primitives stay as an invisible physics shell (collisions, welds, flame),
-- and the meshes are visual only: Massless, no collisions. So flight physics does not depend on the meshes.
--------------------------------------------------------------------
local partsFolder = ServerStorage:FindFirstChild("RocketParts")

-- which mesh is put on an axis module and how it is scaled
--   stretch — diameter and height separately (tanks, decoupler, fairing): the meshes are not rotated, so this is exact
--   uniform — one scale from the diameter (engines, capsules): proportions are not distorted
local STACK_MESH = {
	engine_rutherford = { "Engine_Rutherford", "uniform" },
	engine_merlin = { "Engine_Merlin1D", "uniform" },
	engine_f1 = { "Engine_F1", "uniform" },
	tank_small = { "Tank_Stage2", "stretch" },
	tank_medium = { "Tank_Stage2", "stretch" },
	tank_large = { "Tank_Stage1", "stretch" },
	decoupler = { "Decoupler_Interstage", "stretch" },
	pod_mercury = { "Capsule_Mercury", "uniform" },
	pod_dragon = { "Capsule_Dragon", "uniform" },
}
-- side instruments: mesh and its height in studs
local RADIAL_MESH = {
	rcs_draco = { "Thruster_RCS_Draco", 1.2 },
	solar_panel = { "Power_SolarPanel", 5 },
	antenna_high = { "Comm_HighGainAntenna", 3 },
	antenna_medium = { "Comm_HighGainAntenna", 1.8 },
	theodolite = { "Sci_LaserTheodolite", 1.4 },
	terrain_scanner = { "Sci_TerrainScanner", 2.2 },
	ice_drill = { "Sci_IceDrill", 4 },
}

local function hide(parts)
	for _, p in ipairs(parts) do
		p.Transparency = 1
	end
end

-- Places a copy of the template so that its bottom on the axis (0, BoxMin.Y, 0) lands at the point bottom.
--   mode "stretch": XZ → diameter (by the body's RefDiameter), Y → height
--   mode "uniform": everything × diameter / RefDiameter
--   mode "height":  everything × height / template height
-- Returns the created MeshParts (or nil if there is no template — then the grey primitive stays)
local function placeMesh(templateName, parent, bottom, diameter, height, mode, rotation)
	local tpl = partsFolder and partsFolder:FindFirstChild(templateName)
	if not tpl then
		return nil
	end
	local lo, hi = tpl:GetAttribute("BoxMin"), tpl:GetAttribute("BoxMax")
	local ref = tpl:GetAttribute("RefDiameter")
	local sizeY = hi.Y - lo.Y
	local scale
	if mode == "stretch" then
		scale = Vector3.new(diameter / ref, height / sizeY, diameter / ref)
	elseif mode == "height" then
		scale = Vector3.one * (height / sizeY)
	else
		scale = Vector3.one * (diameter / ref)
	end
	local anchor = Vector3.new(0, lo.Y, 0)
	local origin = CFrame.new(bottom) * (rotation or CFrame.identity)
	local parts = {}
	for _, p in ipairs(tpl:GetDescendants()) do
		if p:IsA("BasePart") and not p.Name:match("_Root$") then
			local c = p:Clone()
			c:ClearAllChildren()
			c.Size = p.Size * scale
			c.CFrame = origin * CFrame.new((p.Position - anchor) * scale) -- template parts are not rotated
			c.Anchored = true
			c.Massless = true
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.CollisionGroup = RocketAssembler.ROCKET_GROUP
			c:SetAttribute("Visual", true)
			c.Parent = parent
			table.insert(parts, c)
		end
	end
	return parts
end

-- Side parts. Returns the created pieces (the first is the main one, it holds the SideMount)
local function radialPart(parent, base, r)
	local color = RocketMath.ColorFor(r.id)
	local dir = Vector3.new(math.cos(r.angle), 0, math.sin(r.angle)) -- "outward" direction
	local function at(distance, y)
		return base + dir * distance + Vector3.new(0, y, 0)
	end
	local function facing(pos) -- local -Z axis points outward
		return CFrame.lookAt(pos, pos + dir)
	end
	local grey = Color3.fromRGB(120, 120, 120)
	local parts = {}
	local function add(p)
		table.insert(parts, p)
		return p
	end

	if r.id == "solar_panel" then
		add(newPart(parent, "SolarStrut", Vector3.new(0.15, 0.15, 0.4), facing(at(r.radius + 0.1, r.y)), grey, Enum.Material.Metal, false))
		add(newPart(parent, "SolarPanel", Vector3.new(0.1, 1.8, 3.2), facing(at(r.radius + 1.7, r.y)), color, Enum.Material.Glass, false))
	elseif r.id == "landing_legs" then
		-- the top leans towards the rocket, the bottom outward
		add(newPart(parent, "LandingLeg", Vector3.new(0.4, 3, 0.4), facing(at(r.radius + 0.6, r.y + 0.7)) * CFrame.Angles(math.rad(25), 0, 0),
			color, Enum.Material.Metal, false))
		add(newPart(parent, "LandingFoot", Vector3.new(1.2, 0.2, 1.2), facing(at(r.radius + 1.3, r.y - 0.7)),
			Color3.fromRGB(60, 60, 65), Enum.Material.Metal, false))
	elseif r.id == "antenna_low" or r.id == "antenna_medium" or r.id == "antenna_high" then
		local dishSize = (r.id == "antenna_low" and 0.6) or (r.id == "antenna_medium" and 1.2) or 2.2
		add(newPart(parent, "AntennaMast", Vector3.new(0.2, 0.2, 1), facing(at(r.radius + 0.5, r.y)), grey, Enum.Material.Metal, false))
		local dishPos = at(r.radius + 1.05, r.y)
		add(newPart(parent, "AntennaDish", Vector3.new(0.2, dishSize, dishSize),
			facing(dishPos) * CFrame.Angles(0, math.rad(90), 0), color, Enum.Material.Metal, false, Enum.PartType.Cylinder))
	else
		add(newPart(parent, r.id, Vector3.new(0.8, 1.2, 0.8), facing(at(r.radius + 0.4, r.y)), color, Enum.Material.Metal, false))
	end

	-- SideMount: a point on the body surface, +Z points outward
	local mount = Instance.new("Attachment")
	mount.Name = "SideMount"
	mount.Parent = parts[1]
	local p = at(r.radius, r.y)
	mount.WorldCFrame = CFrame.lookAt(p, p - dir)

	-- 🔧 BLENDER: the instrument mesh is pressed against the body, the template's +X points outward
	local meshInfo = RADIAL_MESH[r.id]
	local tpl = meshInfo and partsFolder and partsFolder:FindFirstChild(meshInfo[1])
	if tpl then
		local lo, hi = tpl:GetAttribute("BoxMin"), tpl:GetAttribute("BoxMax")
		local k = meshInfo[2] / (hi.Y - lo.Y)
		local halfWidth = math.max(hi.X - lo.X, hi.Z - lo.Z) * k / 2
		local bottom = at(r.radius + halfWidth, r.y - meshInfo[2] / 2)
		local mesh = placeMesh(meshInfo[1], parent, bottom, nil, meshInfo[2], "height", CFrame.Angles(0, -r.angle, 0))
		if mesh then
			hide(parts)
			for _, m in ipairs(mesh) do
				table.insert(parts, m)
			end
		end
	end
	return parts
end

--------------------------------------------------------------------
-- ASSEMBLY
--------------------------------------------------------------------
-- design — a validated blueprint (RocketMath.Sanitize + Validate),
-- base — world point of the rocket bottom. Returns a Model (with no Parent yet).
function RocketAssembler.Build(design, base, label)
	local layout = RocketMath.Layout(design)
	local stats = RocketMath.Compute(design)
	local stages = stats.stages
	local nStages = #stages

	local model = Instance.new("Model")
	model.Name = "Rocket"

	local groups, roots = {}, {}
	local function group(name)
		local g = groups[name]
		if not g then
			g = Instance.new("Folder")
			g.Name = name
			g:SetAttribute("DryMass", 0)
			g.Parent = model
			groups[name] = g
		end
		return g
	end
	local function addMass(name, kg)
		local g = group(name)
		g:SetAttribute("DryMass", g:GetAttribute("DryMass") + kg)
	end
	-- all pieces of one module get the same key (for mesh replacement)
	local function tag(parts, key)
		for _, p in ipairs(parts) do
			p:SetAttribute("ModuleKey", key)
			if not roots[p.Parent.Name] then
				roots[p.Parent.Name] = p
			end
		end
	end

	local function groupFor(piece)
		local category = Modules[piece.id].category
		if piece.id == "decoupler" then
			return "Decoupler" .. piece.stage
		end
		if piece.stage == nStages and category ~= "engine" and category ~= "tank" then
			return "Payload"
		end
		return "Stage" .. piece.stage
	end

	-- 1) Stage 1 engine cluster: the nozzle bell is wider at the bottom
	local e = layout.engines
	if e then
		local g = group("Stage1")
		local color = RocketMath.ColorFor(e.id)
		local mount = vCylinder(g, "EngineMount", base, 0, 0, e.mountY, RocketMath.ENGINE_MOUNT_HEIGHT, e.mountDiameter,
			Color3.fromRGB(45, 48, 55), Enum.Material.Metal)
		tag({ mount }, e.id .. ":1")
		addMount(mount, "BottomMount", base)
		addMount(mount, "TopMount", base + Vector3.new(0, e.mountY + RocketMath.ENGINE_MOUNT_HEIGHT, 0))
		for n, off in ipairs(e.offsets) do
			local bell = {}
			for k = 1, 3 do
				local t = (k - 0.5) / 3
				table.insert(bell, vCylinder(g, "Engine", base, off.X, off.Y, (k - 1) * e.bellHeight / 3, e.bellHeight / 3,
					e.bellDiameter * (1 - 0.45 * t), color, Enum.Material.Metal))
			end
			tag(bell, e.id .. ":1:" .. n)
			local nozzle = addMount(bell[1], "NozzlePoint", base + Vector3.new(off.X, 0, off.Y), true)
			addEngineFX(nozzle, e.bellDiameter)
			local info = STACK_MESH[e.id]
			if info and placeMesh(info[1], g, base + Vector3.new(off.X, 0, off.Y), e.bellDiameter, e.bellHeight, info[2]) then
				hide(bell)
			end
		end
		addMass("Stage1", Modules[e.id].dryMass * design.engineCount)
	end

	-- 2) Parts on the axis
	local podPart = nil
	local fairingPiece = nil
	for _, p in ipairs(layout.pieces) do
		local m = Modules[p.id]
		if p.id == "fairing" then
			fairingPiece = p
		else
			local gName = groupFor(p)
			local g = group(gName)
			local color = RocketMath.ColorFor(p.id)
			local material = m.category == "tank" and Enum.Material.SmoothPlastic or Enum.Material.Metal
			local parts
			if math.abs(p.d0 - p.d1) < 0.01 then
				parts = { vCylinder(g, p.id, base, 0, 0, p.y0, p.h, p.d0, color, material) }
			else
				parts = taper(g, p.id, base, p.y0, p.h, p.d0, p.d1, color, material, p.isEngine and 3 or 5)
			end
			if m.category == "tank" then
				-- a dark band in the middle of the tank, like on real rockets
				table.insert(parts, vCylinder(g, "TankBand", base, 0, 0, p.y0 + p.h / 2 - 0.2, 0.4, p.d0 + 0.08,
					Color3.fromRGB(30, 30, 35), Enum.Material.SmoothPlastic))
			end
			tag(parts, p.id .. ":" .. p.index)
			addMount(parts[1], "BottomMount", base + Vector3.new(0, p.y0, 0))
			addMount(parts[1], "TopMount", base + Vector3.new(0, p.y0 + p.h, 0))
			-- interface diameters (m) — see RocketMath.DiameterCheck
			local bottomD, topD = RocketMath.PieceDiameters(p)
			parts[1]:SetAttribute("BottomDiameter", math.floor(bottomD * 100 + 0.5) / 100)
			parts[1]:SetAttribute("TopDiameter", math.floor(topD * 100 + 0.5) / 100)
			if p.isEngine then
				local nozzle = addMount(parts[1], "NozzlePoint", base + Vector3.new(0, p.y0, 0), true)
				addEngineFX(nozzle, p.d0)
			end
			if m.category == "command" and not podPart then
				podPart = parts[1]
			end
			local info = STACK_MESH[p.id]
			if info and placeMesh(info[1], g, base + Vector3.new(0, p.y0, 0), p.d0, p.h, info[2]) then
				hide(parts)
			end
			addMass(gName, m.dryMass)
			if m.fuelCapacity then
				g:SetAttribute("FuelCapacity", (g:GetAttribute("FuelCapacity") or 0) + m.fuelCapacity)
			end
		end
	end

	-- 3) Side parts go into Payload (they fly with the capsule)
	for k, r in ipairs(layout.radial) do
		local parts = radialPart(group("Payload"), base, r)
		tag(parts, r.id .. ":r" .. k)
		addMass("Payload", Modules[r.id].dryMass)
	end

	-- 4) Label above the rocket (visible to everyone)
	local labelAnchor = newPart(group("Payload"), "LabelAnchor", Vector3.new(1, 1, 1),
		CFrame.new(base + Vector3.new(0, layout.height + 2, 0)), Color3.new(1, 1, 1), nil, false)
	labelAnchor.Transparency = 1
	labelAnchor.Massless = true
	if not roots.Payload then
		roots.Payload = labelAnchor
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(220, 40)
	billboard.MaxDistance = 120
	billboard.Parent = labelAnchor
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = label or "Rocket"
	text.TextColor3 = Color3.fromRGB(240, 190, 40)
	text.TextStrokeTransparency = 0.4
	text.Font = Enum.Font.GothamBold
	text.TextSize = 20
	text.Parent = billboard

	-- 5) Payload fairing: two halves (left -X, right +X)
	--    🔧 BLENDER: a pair of MeshPart shells will go here; for now it is a stack of rectangular blocks.
	if fairingPiece then
		local p = fairingPiece
		local color = RocketMath.ColorFor("fairing")
		local straight = p.straightH or 0
		local coneH = p.h - straight
		local segs = {}
		if straight > 0 then
			table.insert(segs, { y0 = p.y0, h = straight, d = p.d0 })
		end
		for k = 1, 4 do
			local t = (k - 0.5) / 4
			table.insert(segs, { y0 = p.y0 + straight + (k - 1) * coneH / 4, h = coneH / 4, d = p.d0 + (p.d1 - p.d0) * t })
		end
		for _, side in ipairs({ { "FairingLeft", -1 }, { "FairingRight", 1 } }) do
			local g = group(side[1])
			local parts = {}
			for _, s in ipairs(segs) do
				local half = newPart(g, "FairingShell", Vector3.new(s.d / 2, s.h, s.d),
					CFrame.new(base + Vector3.new(side[2] * s.d / 4, s.y0 + s.h / 2, 0)), color, Enum.Material.SmoothPlastic, false)
				table.insert(parts, half)
			end
			tag(parts, "fairing:" .. p.index .. ":" .. side[1])
			-- 🔧 BLENDER: the Fairing_Half template is the left shell (−X); the right one is the same, rotated 180°
			local rot = side[2] > 0 and CFrame.Angles(0, math.pi, 0) or CFrame.identity
			if placeMesh("Fairing_Half", g, base + Vector3.new(0, p.y0, 0), p.d0, p.h, "stretch", rot) then
				hide(parts)
			end
			addMount(parts[1], "BottomMount", base + Vector3.new(side[2] * p.d0 / 4, p.y0, 0))
			addMass(side[1], Modules.fairing.dryMass / 2)
		end
	end

	-- 6) Stage attributes (thrust, Isp, propellant)
	for k, st in ipairs(stages) do
		local g = groups["Stage" .. k]
		if g then
			g:SetAttribute("Index", k)
			g:SetAttribute("FuelCapacity", g:GetAttribute("FuelCapacity") or 0)
			g:SetAttribute("FuelMass", 0)
			g:SetAttribute("EngineId", st.engineId or "")
			g:SetAttribute("Thrust", st.thrustSL)      -- N, at sea level
			g:SetAttribute("ThrustVac", st.thrustVac)  -- N, in vacuum
			g:SetAttribute("Isp", st.ispSL)            -- s
			g:SetAttribute("IspVac", st.ispVac)        -- s
		end
	end

	-- 7) Welding. Inside a group — to its root; groups — in a chain from bottom to top.
	--    The "decoupler → next group" link is a SeparationWeld: breaking it cuts off everything below.
	local function weld(a, b, parent, name)
		local w = Instance.new("WeldConstraint")
		w.Name = name or "Weld"
		w.Part0 = a
		w.Part1 = b
		w.Parent = parent
		return w
	end
	for name, g in pairs(groups) do
		local root = roots[name]
		for _, d in ipairs(g:GetDescendants()) do
			if d:IsA("BasePart") and d ~= root then
				weld(root, d, root)
			end
		end
	end
	local chain = {}
	for k = 1, nStages do
		for _, name in ipairs({ "Stage" .. k, "Decoupler" .. k }) do
			if roots[name] then
				table.insert(chain, name)
			end
		end
	end
	table.insert(chain, "Payload")
	for i = 2, #chain do
		local below, above = chain[i - 1], chain[i]
		if below:sub(1, 9) == "Decoupler" then
			weld(roots[below], roots[above], groups[below], "SeparationWeld")
		else
			weld(roots[below], roots[above], groups[above])
		end
	end
	for _, name in ipairs({ "FairingLeft", "FairingRight" }) do
		if roots[name] then
			weld(roots.Payload, roots[name], groups[name], "SeparationWeld")
		end
	end

	-- 8) Flight core: the capsule flies to the end, so VectorForce/AlignOrientation live on it
	local core = podPart or roots.Payload
	local coreAtt = Instance.new("Attachment")
	coreAtt.Name = "FlightCore"
	coreAtt.Parent = core
	coreAtt.WorldCFrame = CFrame.new(core.Position) -- +Y = rocket axis
	model.PrimaryPart = core

	-- 9) Pilot seat inside the capsule (Capsule_Dragon / Capsule_Mercury) — CapsuleSeatSystem
	CapsuleSeatSystem.AddSeat(model, core, RocketAssembler.ROCKET_GROUP)

	model:SetAttribute("State", "Hangar")
	model:SetAttribute("StageCount", nStages)
	model:SetAttribute("ActiveStage", 1)
	model:SetAttribute("BasePosition", base)
	model:SetAttribute("HasFairing", fairingPiece ~= nil)
	model:SetAttribute("MaxDiameter", layout.maxDiameter)
	model:SetAttribute("HeightStuds", layout.height)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	return model
end

--------------------------------------------------------------------
-- MOVING
--------------------------------------------------------------------
function RocketAssembler.MoveTo(model, newBase)
	local old = model:GetAttribute("BasePosition")
	model:PivotTo(model:GetPivot() + (newBase - old))
	model:SetAttribute("BasePosition", newBase)
end

-- Top of the launch table (Workspace > LaunchPad > Pad) under the LaunchPoint
function RocketAssembler.GetLaunchBase()
	local padModel = workspace:FindFirstChild("LaunchPad")
	-- launch table from Blender: the rocket stands on an invisible LaunchSurface support inside the clamp ring
	local surface = padModel and padModel:FindFirstChild("LaunchSurface")
	if surface then
		return surface.Position + Vector3.new(0, surface.Size.Y / 2, 0)
	end
	local pad = padModel and padModel:FindFirstChild("Pad")
	local point = padModel and padModel:FindFirstChild("LaunchPoint")
	if not pad then
		return Vector3.new(0, 2, 110)
	end
	local cf, size = pad.CFrame, pad.Size
	-- half-height of a rotated part along world Y
	local halfY = 0.5 * (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z)
	local xz = point and point.Position or pad.Position
	return Vector3.new(xz.X, pad.Position.Y + halfY, xz.Z)
end

-- Moves the fuelled rocket from the hangar to the launch pad.
-- Fuel from the player's tanks (RocketFuel) is shared between stages in proportion to their capacity.
-- The rocket stays LOCKED (Anchored) until the "Launch" command — see Unlock.
function RocketAssembler.LaunchPadSpawn(model, fuelKg)
	local totalCap = 0
	for _, g in ipairs(model:GetChildren()) do
		if g:IsA("Folder") and g:GetAttribute("FuelCapacity") then
			totalCap += g:GetAttribute("FuelCapacity")
		end
	end
	local ratio = totalCap > 0 and math.clamp(fuelKg / totalCap, 0, 1) or 0
	for _, g in ipairs(model:GetChildren()) do
		if g:IsA("Folder") and g:GetAttribute("FuelCapacity") then
			g:SetAttribute("FuelMass", g:GetAttribute("FuelCapacity") * ratio)
		end
	end

	local base = RocketAssembler.GetLaunchBase()
	RocketAssembler.MoveTo(model, base)
	model:SetAttribute("PadY", base.Y)
	model:SetAttribute("State", "OnPad")
	return base
end

-- Unlocking for launch: parts become physical, the server runs the simulation (anti-cheat)
function RocketAssembler.Unlock(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
		end
	end
	if model.PrimaryPart then
		model.PrimaryPart:SetNetworkOwner(nil)
	end
end

--------------------------------------------------------------------
-- 🔧 BLENDER: replacing a grey primitive with a MeshPart
--   greyPart     — any piece of the module (the rest is found by ModuleKey)
--   meshTemplate — a MeshPart with Attachment "BottomMount" at the module bottom
-- The mesh is placed so its BottomMount matches the grey part's BottomMount, then welded,
-- and the grey pieces become invisible. Masses/thrust do not change (they are in folder attributes).
--------------------------------------------------------------------
function RocketAssembler.ReplaceVisual(greyPart, meshTemplate)
	local key = greyPart:GetAttribute("ModuleKey")
	local siblings = {}
	for _, p in ipairs(greyPart.Parent:GetChildren()) do
		if p:IsA("BasePart") and key and p:GetAttribute("ModuleKey") == key then
			table.insert(siblings, p)
		end
	end
	local mountPart = greyPart
	for _, p in ipairs(siblings) do
		if p:FindFirstChild("BottomMount") then
			mountPart = p
		end
	end
	local mount = mountPart:FindFirstChild("BottomMount")

	local mesh = meshTemplate:Clone()
	local meshMount = mesh:FindFirstChild("BottomMount")
	if mount and meshMount then
		mesh.CFrame = mount.WorldCFrame * meshMount.CFrame:Inverse()
	else
		mesh.CFrame = mountPart.CFrame
	end
	mesh.Anchored = mountPart.Anchored
	mesh.CanCollide = false
	mesh.Massless = true
	mesh.CollisionGroup = mountPart.CollisionGroup
	mesh:SetAttribute("ModuleKey", key)
	mesh.Parent = mountPart.Parent
	local w = Instance.new("WeldConstraint")
	w.Part0 = mountPart
	w.Part1 = mesh
	w.Parent = mesh
	for _, p in ipairs(siblings) do
		p.Transparency = 1
	end
	return mesh
end

return RocketAssembler
