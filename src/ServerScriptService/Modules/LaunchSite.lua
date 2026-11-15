--[[
	LaunchSite (ModuleScript, СЕРВЕР)
	Місце: ServerScriptService > Modules > LaunchSite

	Стартовий комплекс з Blender (Workspace > LaunchPad):
	  Launch_Table      — стартовий стіл; у газовідвідному жолобі (Deflector) — дим і іскри при запуску
	  Launch_Tower      — пускова вежа; на T−2 с відхиляється назад на шарнірі (TweenService)
	  Ground_LOX_Tanks  — баки рідкого кисню: пара випаровування + пункт «Рідкий кисень (LOX)»
	Одночасно на майданчику може бути лише ОДНА ракета (TryClaim / Release).
]]

local TweenService = game:GetService("TweenService")

local LaunchSite = {}

local pad = workspace:WaitForChild("LaunchPad")
local tower = pad:FindFirstChild("Launch_Tower")
local launchTable = pad:FindFirstChild("Launch_Table")
local lox = pad:FindFirstChild("Ground_LOX_Tanks")

--------------------------------------------------------------------
-- ⚙️ НАЛАШТУВАННЯ
--------------------------------------------------------------------
local TOWER_TILT = math.rad(-22)   -- наскільки вежа відхиляється від ракети
local SMOKE_TIME = 10              -- с: скільки валить дим із жолоба після запалювання

--------------------------------------------------------------------
-- Зайнятість майданчика
--------------------------------------------------------------------
local padOwner = nil
function LaunchSite.TryClaim(userId)
	if padOwner == nil or padOwner == userId then
		padOwner = userId
		return true
	end
	return false
end
function LaunchSite.Release(userId)
	if padOwner == userId then
		padOwner = nil
	end
end

--------------------------------------------------------------------
-- Вежа: поворот навколо шарніра в основі (pivot вежі = шарнір, локальна X — вісь шарніра)
--------------------------------------------------------------------
local towerValue, homePivot
if tower then
	homePivot = tower:GetAttribute("HomePivot") or tower:GetPivot()
	towerValue = Instance.new("CFrameValue")
	towerValue.Value = homePivot
	towerValue.Changed:Connect(function(cf)
		tower:PivotTo(cf)
	end)
	tower:PivotTo(homePivot)
end

local function tweenTower(target, seconds)
	if towerValue then
		TweenService:Create(towerValue, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Value = target }):Play()
	end
end
function LaunchSite.RetractTower()
	if homePivot then
		tweenTower(homePivot * CFrame.Angles(TOWER_TILT, 0, 0), 2)
	end
end
function LaunchSite.ResetTower()
	if homePivot then
		tweenTower(homePivot, 4)
	end
end

--------------------------------------------------------------------
-- Дим, іскри та пара
--------------------------------------------------------------------
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"

local function makeAttachment(part, worldCFrame, name)
	local a = Instance.new("Attachment")
	a.Name = name
	a.Parent = part
	a.WorldCFrame = worldCFrame
	return a
end

local function smoke(parent, size, speed, rate)
	local e = Instance.new("ParticleEmitter")
	e.Name = "LaunchSmoke"
	e.Texture = SMOKE_TEX
	e.Color = ColorSequence.new(Color3.fromRGB(235, 235, 235), Color3.fromRGB(170, 170, 170))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.4), NumberSequenceKeypoint.new(1, size * 2) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.7, 0.5), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(4, 7)
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.SpreadAngle = Vector2.new(25, 12)
	e.Drag = 0.8
	e.Acceleration = Vector3.new(0, 5, 0)
	e.RotSpeed = NumberRange.new(-40, 40)
	e.Rotation = NumberRange.new(0, 360)
	e.Rate = rate
	e.EmissionDirection = Enum.NormalId.Front -- -Z атачмента
	e.Enabled = false
	e.Parent = parent
	return e
end

local function sparks(parent)
	local e = Instance.new("ParticleEmitter")
	e.Name = "LaunchSparks"
	e.Texture = SPARK_TEX
	e.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 110, 30))
	e.LightEmission = 1
	e.Size = NumberSequence.new(1.6, 0.3)
	e.Lifetime = NumberRange.new(0.5, 1.1)
	e.Speed = NumberRange.new(60, 110)
	e.SpreadAngle = Vector2.new(30, 20)
	e.Acceleration = Vector3.new(0, -80, 0)
	e.Rate = 120
	e.EmissionDirection = Enum.NormalId.Front
	e.Enabled = false
	e.Parent = parent
	return e
end

local launchFX = {}
if launchTable then
	local deflector = launchTable:FindFirstChild("Launch_Table_Deflector")
	local surface = pad:FindFirstChild("LaunchSurface")
	if deflector then
		-- жолоб тягнеться вздовж локальної Z столу і відкривається на +Z: туди й летить дим
		local cf = deflector.CFrame
		local out = (cf * CFrame.new(0, 0, deflector.Size.Z / 2)).Position
		local dir = cf:VectorToWorldSpace(Vector3.zAxis)
		local a = makeAttachment(deflector, CFrame.lookAt(out, out + dir + Vector3.new(0, 0.15, 0)), "TrenchExit")
		table.insert(launchFX, smoke(a, 14, 70, 70))
		table.insert(launchFX, sparks(a))
	end
	if surface then
		-- клуби диму навколо столу
		local top = surface.Position + Vector3.new(0, surface.Size.Y / 2, 0)
		for i = 0, 3 do
			local dir = CFrame.Angles(0, i * math.pi / 2 + math.pi / 4, 0).LookVector
			local a = makeAttachment(surface, CFrame.lookAt(top, top + dir), "SmokeRing" .. i)
			table.insert(launchFX, smoke(a, 10, 35, 25))
		end
	end
end

local vapor
if lox then
	local tanks = lox:FindFirstChild("Ground_LOX_Tanks_Tanks")
	if tanks then
		local top = tanks.Position + Vector3.new(0, tanks.Size.Y / 2, 0)
		local a = makeAttachment(tanks, CFrame.lookAt(top, top + Vector3.yAxis), "Vent")
		vapor = smoke(a, 4, 6, 3)
		vapor.Name = "LOXVapor"
		vapor.Lifetime = NumberRange.new(2, 4)
		vapor.Transparency = NumberSequence.new(0.5, 1)
		vapor.Enabled = true -- кріогенне пальне постійно випаровується (−183 °C)

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "LOXPrompt"
		prompt.ActionText = "Liquid Oxygen (LOX)"
		prompt.ObjectText = "LOX Tanks"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance = 25
		prompt.RequiresLineOfSight = false
		prompt.Parent = tanks
		LaunchSite.LOXPrompt = prompt
	end
end

-- Під час відліку баки LOX «дихають» сильніше (скидання тиску)
function LaunchSite.SetVenting(on)
	if vapor then
		vapor.Rate = on and 25 or 3
	end
end

-- T−0: дим і іскри з газовідвідного жолоба
function LaunchSite.Ignition()
	for _, e in ipairs(launchFX) do
		e.Enabled = true
	end
	task.delay(SMOKE_TIME, function()
		for _, e in ipairs(launchFX) do
			e.Enabled = false
		end
	end)
end

return LaunchSite
