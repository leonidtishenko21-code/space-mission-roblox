--[[
	RocketMath (ModuleScript)
	Місце: ReplicatedStorage > Modules > RocketMath

	Спільна "інженерна" логіка конструктора ракети (крок 3):
	  • Compute  — вартість, маса, тяга, TWR, Δv, час роботи двигуна, зміщення центру мас
	  • Validate — чи можна зібрати ракету (помилки) і що варто покращити (попередження)
	  • Layout   — як деталі стоять одна на одній (висоти й діаметри в studs)
	Його використовують І клієнт (показує числа), І сервер (перевіряє перед покупкою),
	тому числа завжди однакові, а підробити ракету через FireServer не вийде.

	Ракета (design) — це таблиця:
	  {
	    stack = { "engine_rutherford", "tank_small", "pod_mercury", "nosecone" }, -- ЗНИЗУ ВГОРУ
	    radial = { "antenna_low" },   -- деталі збоку
	    engineCount = 3,              -- скільки двигунів у нижньому кластері
	  }                               -- (справжня ракета Electron має 9 двигунів Rutherford)
]]

local NASAData = require(script.Parent:WaitForChild("NASAData"))

local Modules = NASAData.Modules
local G0 = NASAData.Constants.G0
local METERS_PER_STUD = NASAData.Constants.METERS_PER_STUD

local RocketMath = {}

--------------------------------------------------------------------
-- ⚙️ ПРАВИЛА
--------------------------------------------------------------------
RocketMath.MAX_STACK = 12           -- деталей по центральній осі (з урахуванням ступенів)
RocketMath.MAX_RADIAL = 6           -- деталей збоку
RocketMath.MAX_ENGINES = 9          -- двигунів у кластері (як в Electron)
RocketMath.MIN_TWR = 1.0            -- менше → ракета не відірветься від землі
RocketMath.GOOD_TWR = 1.2           -- менше → злітає дуже повільно (попередження)
RocketMath.MAX_COM_OFFSET_CM = 3    -- більше → центр мас зміщений (попередження)
RocketMath.DEFAULT_DIAMETER = 4     -- studs
RocketMath.ENGINE_MOUNT_HEIGHT = 0.4

--------------------------------------------------------------------
-- Вигляд деталей (studs): h — висота, d — діаметр знизу, top — діаметр зверху,
-- grow — на скільки ширша за деталь під нею (тепловий щит)
--------------------------------------------------------------------
-- Висоти двигунів і капсул підібрані за пропорціями мешів з Blender (ServerStorage/RocketParts),
-- щоб вони не розтягувались: h = d · (висота / діаметр меша).
RocketMath.Visual = {
	pod_mercury = { h = 8.9, d = 3.4, top = 0.9 },   -- разом із вежею системи аварійного порятунку
	pod_dragon = { h = 6, d = 5, top = 2.6 },
	tank_small = { h = 4, d = 4 },
	tank_medium = { h = 8, d = 5 },
	tank_large = { h = 14, d = 7 },
	engine_rutherford = { h = 2, d = 1.2 },
	engine_merlin = { h = 5.8, d = 2.4 },
	engine_f1 = { h = 7.6, d = 4 },
	nosecone = { h = 3, top = 0.3 },
	interstage = { h = 1.2 },
	heat_shield = { h = 0.5, grow = 0.4 },
	parachute = { h = 1.2 }, -- контейнер парашута бере діаметр деталі під ним
	docking_port = { h = 0.8, d = 2.4 },
	decoupler = { h = 2.5 },
	-- wrap = обтічник накриває капсулу під ним (циліндр висотою з капсулу + конус h)
	fairing = { h = 3.5, top = 0.4, wrap = true },
}

local CATEGORY_COLORS = {
	command = Color3.fromRGB(70, 75, 85),
	tank = Color3.fromRGB(235, 235, 235),
	engine = Color3.fromRGB(60, 60, 65),
	structure = Color3.fromRGB(200, 60, 40),
	protection = Color3.fromRGB(120, 70, 40),
	landing = Color3.fromRGB(240, 140, 40),
	power = Color3.fromRGB(40, 80, 170),
	life = Color3.fromRGB(80, 170, 200),
	comms = Color3.fromRGB(200, 200, 210),
	science = Color3.fromRGB(240, 190, 40),
}

local SPECIAL_COLORS = {
	interstage = Color3.fromRGB(45, 48, 55),
	docking_port = Color3.fromRGB(150, 150, 160),
	thermal_insulation = Color3.fromRGB(220, 180, 60),
	decoupler = Color3.fromRGB(230, 180, 30),
	fairing = Color3.fromRGB(245, 245, 245),
}

function RocketMath.ColorFor(moduleId)
	if SPECIAL_COLORS[moduleId] then
		return SPECIAL_COLORS[moduleId]
	end
	local m = Modules[moduleId]
	return (m and CATEGORY_COLORS[m.category]) or Color3.fromRGB(180, 180, 180)
end

--------------------------------------------------------------------
-- Допоміжні функції
--------------------------------------------------------------------

-- 20000 → "20 000",  -150 → "-150"
function RocketMath.FormatNumber(n)
	local negative = n < 0
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local spaced = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	spaced = spaced:gsub("^%s+", "")
	return (negative and "-" or "") .. spaced
end
local fmt = RocketMath.FormatNumber

-- Головний двигун = двигун, що кріпиться по осі (RCS Draco кріпиться збоку і не рахується)
function RocketMath.IsMainEngine(moduleId)
	local m = moduleId and Modules[moduleId]
	return m ~= nil and m.category == "engine" and m.attach == "stack"
end

function RocketMath.EmptyDesign()
	return { stack = {}, radial = {}, engineCount = 1 }
end

function RocketMath.HasModule(design, moduleId)
	return table.find(design.stack, moduleId) ~= nil or table.find(design.radial, moduleId) ~= nil
end

-- Деталь, яка може стояти лише на самій верхівці
function RocketMath.IsTopCap(moduleId)
	return moduleId == "nosecone" or moduleId == "fairing"
end

--------------------------------------------------------------------
-- СТУПЕНІ: stack ділиться на ступені декуплерами (знизу вгору).
--   Декуплер належить ступеню ПІД ним — відлітає разом із ним.
--   Ступінь 1 — нижній (працює першим), останній — з капсулою.
--   Двигун ступеня стоїть першим у своєму сегменті. Кластер з engineCount — лише в ступені 1,
--   у верхніх ступенях по одному двигуну (як другий ступінь Electron).
--------------------------------------------------------------------
function RocketMath.SplitStages(design)
	local stack = design.stack
	local stages = {}
	local first = 1
	for i, id in ipairs(stack) do
		if id == "decoupler" then
			table.insert(stages, { first = first, last = i, decouplerIndex = i })
			first = i + 1
		end
	end
	if first <= #stack or #stages == 0 then
		table.insert(stages, { first = first, last = #stack })
	end
	for k, st in ipairs(stages) do
		st.index = k
		local firstId = stack[st.first]
		if RocketMath.IsMainEngine(firstId) then
			st.engineId = firstId
			st.engineCount = (st.first == 1) and design.engineCount or 1
		end
	end
	return stages
end

-- Перевіряє дані, що прийшли від гравця: лише відомі деталі, розумні розміри
function RocketMath.Sanitize(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local design = RocketMath.EmptyDesign()
	if type(raw.stack) == "table" then
		for i = 1, math.min(#raw.stack, RocketMath.MAX_STACK) do
			local id = raw.stack[i]
			if type(id) == "string" and Modules[id] then
				table.insert(design.stack, id)
			end
		end
	end
	if type(raw.radial) == "table" then
		for i = 1, math.min(#raw.radial, RocketMath.MAX_RADIAL) do
			local id = raw.radial[i]
			if type(id) == "string" and Modules[id] then
				table.insert(design.radial, id)
			end
		end
	end
	local n = tonumber(raw.engineCount)
	if n and n == n then -- n == n відкидає NaN
		design.engineCount = math.clamp(math.floor(n), 1, RocketMath.MAX_ENGINES)
	end
	return design
end

--------------------------------------------------------------------
-- LAYOUT: де стоїть кожна деталь (у studs, від низу ракети)
--------------------------------------------------------------------

-- Розставляє N двигунів по колу (якщо їх > 7 — один ще й у центрі)
local function clusterOffsets(count, mountDiameter, bellDiameter)
	if count <= 1 then
		return { Vector2.zero }
	end
	local list = {}
	local ringCount = count
	if count > 7 then
		table.insert(list, Vector2.zero)
		ringCount = count - 1
	end
	local r = math.max(mountDiameter / 2 - bellDiameter / 2 - 0.1, bellDiameter * 0.55)
	for k = 1, ringCount do
		local a = (k - 1) / ringCount * 2 * math.pi
		table.insert(list, Vector2.new(math.cos(a) * r, math.sin(a) * r))
	end
	return list
end

function RocketMath.Layout(design)
	local stack = design.stack
	local stages = RocketMath.SplitStages(design)
	local nStages = #stages
	local stageOf = {}
	for _, st in ipairs(stages) do
		for i = st.first, st.last do
			stageOf[i] = st.index
		end
	end
	local layout = {
		pieces = {}, engines = nil, radial = {}, height = 0, maxDiameter = 0,
		stageCount = nStages, stageBottom = { [1] = 0 },
	}

	local function track(d)
		if d > layout.maxDiameter then
			layout.maxDiameter = d
		end
	end

	local y = 0
	local prevD = RocketMath.DEFAULT_DIAMETER
	local first = 1

	-- 1) Кластер двигунів унизу + плита кріплення
	if RocketMath.IsMainEngine(stack[1]) then
		local v = RocketMath.Visual[stack[1]] or { h = 1.6, d = 1.2 }
		local nextV = stack[2] and RocketMath.Visual[stack[2]]
		local mountD = (nextV and nextV.d) or RocketMath.DEFAULT_DIAMETER
		layout.engines = {
			id = stack[1],
			stage = 1,
			bellHeight = v.h,
			bellDiameter = v.d,
			mountY = v.h,
			mountDiameter = mountD,
			offsets = clusterOffsets(design.engineCount, mountD, v.d),
		}
		y = v.h + RocketMath.ENGINE_MOUNT_HEIGHT
		prevD = mountD
		track(mountD)
		first = 2
	end

	-- 2) Решта деталей по осі
	local lastTankD, prevPiece = nil, nil
	for i = first, #stack do
		local id = stack[i]
		local v = RocketMath.Visual[id] or { h = 1 }
		local m = Modules[id]
		local st = stageOf[i] or nStages
		if layout.stageBottom[st] == nil then
			layout.stageBottom[st] = y
		end
		local piece
		if RocketMath.IsMainEngine(id) then
			-- двигун верхнього ступеня (стоїть на декуплері): дзвін сопла ширший унизу
			local bell = v.d or 1.2
			piece = { id = id, index = i, stage = st, y0 = y, h = v.h, d0 = bell, d1 = bell * 0.55, isEngine = true }
		elseif v.wrap and prevPiece and Modules[prevPiece.id].category == "command" then
			-- обтічник накриває капсулу: починається від її низу
			local d0 = math.max(prevPiece.d0, lastTankD or 0) + 0.3
			piece = {
				id = id, index = i, stage = st, y0 = prevPiece.y0, h = prevPiece.h + v.h,
				d0 = d0, d1 = v.top or d0, straightH = prevPiece.h,
			}
		else
			local d0 = v.d or prevD
			if v.grow then
				d0 = prevD + v.grow
			end
			piece = { id = id, index = i, stage = st, y0 = y, h = v.h, d0 = d0, d1 = v.top or d0 }
		end
		table.insert(layout.pieces, piece)
		track(piece.d0)
		if m and m.category == "tank" then
			lastTankD = piece.d0
		end
		y = piece.y0 + piece.h
		prevD = piece.d1
		prevPiece = piece
	end
	layout.height = y

	-- 3) Бічні деталі: рівномірно по колу, на ОСТАННЬОМУ ступені (вони летять разом із капсулою):
	--    на середині найбільшого бака цього ступеня, або на капсулі
	local bodyD, bodyY, bestTankH, podPiece = nil, nil, -1, nil
	for _, p in ipairs(layout.pieces) do
		if p.stage == nStages then
			local category = Modules[p.id].category
			if category == "tank" and p.h > bestTankH then
				bestTankH = p.h
				bodyD = p.d0
				bodyY = p.y0 + p.h / 2
			elseif category == "command" then
				podPiece = p
			end
		end
	end
	if not bodyD and podPiece then
		bodyD = podPiece.d0
		bodyY = podPiece.y0 + podPiece.h * 0.3
	end
	bodyD = bodyD or math.max(layout.maxDiameter, 1)
	bodyY = bodyY or y / 2
	local n = #design.radial
	for k, id in ipairs(design.radial) do
		local m = Modules[id]
		local entry = { id = id, angle = (k - 1) / n * 2 * math.pi, radius = bodyD / 2, y = bodyY, stage = nStages }
		if m and m.category == "landing" then
			-- посадкові опори — біля двигунів останнього ступеня
			if nStages == 1 and layout.engines then
				entry.radius = layout.engines.mountDiameter / 2
			end
			entry.y = (layout.stageBottom[nStages] or 0) + 0.8
		end
		table.insert(layout.radial, entry)
	end

	return layout
end

--------------------------------------------------------------------
-- СУМІСНІСТЬ ДІАМЕТРІВ (зверху вниз і знизу вгору)
--   У кожної деталі є BottomDiameter (нижній стикувальний зріз) і TopDiameter (верхній), у метрах.
--   Правило:  верхній.BottomDiameter ≤ нижній.TopDiameter  (такого ж діаметра або вужчий),
--   інакше широкий модуль нависає над вузьким і на Max-Q (макс. аеродинамічний напір) корпус руйнується.
--   Винятки:
--     • двигуни верхніх ступенів висять всередині декуплера — у перевірці не беруть участі;
--     • адаптивні деталі (декуплер, міжступеневе кільце, конус, парашут) беруть діаметр нижньої;
--     • головний обтічник може бути ширшим: у нього конічна нижня спідниця;
--     • тепловий щит навмисно трохи ширший за деталь під ним (захищає капсулу).
--------------------------------------------------------------------
local DIAMETER_EXEMPT = { fairing = true, heat_shield = true }

-- Повертає список порушень: { upper = id, lower = id, upperD = м, lowerD = м }
function RocketMath.DiameterCheck(design, layout)
	layout = layout or RocketMath.Layout(design)
	local problems = {}
	local prev = nil -- остання "несуча" деталь під поточною
	for _, p in ipairs(layout.pieces) do
		if not p.isEngine then
			if prev and not DIAMETER_EXEMPT[p.id] and p.d0 > prev.d1 + 0.01 then
				table.insert(problems, {
					upper = p.id, lower = prev.id,
					upperD = p.d0 * METERS_PER_STUD, lowerD = prev.d1 * METERS_PER_STUD,
				})
			end
			prev = p
		end
	end
	return problems
end

-- Діаметри модуля в метрах (для атрибутів деталей і підказок)
function RocketMath.PieceDiameters(piece)
	return piece.d0 * METERS_PER_STUD, piece.d1 * METERS_PER_STUD
end

--------------------------------------------------------------------
-- COMPUTE: усі інженерні числа ракети
--------------------------------------------------------------------
function RocketMath.Compute(design)
	local s = {
		cost = 0, dryMass = 0, fuel = 0, power = 0,
		thrustSL = 0, thrustVac = 0, ispSL = 0, ispVac = 0,
		twr = 0, deltaV = 0, burnRate = 0, burnTime = 0,
	}

	local stages = RocketMath.SplitStages(design)
	local nStages = #stages
	local stageOf = {}
	for _, st in ipairs(stages) do
		st.dryMass, st.fuel, st.cost = 0, 0, 0
		st.thrustSL, st.thrustVac, st.ispSL, st.ispVac = 0, 0, 0, 0
		st.deltaV, st.burnTime, st.burnRate = 0, 0, 0
		for i = st.first, st.last do
			stageOf[i] = st
		end
	end

	local function add(id, count, st)
		local m = Modules[id]
		s.cost += m.cost * count
		s.dryMass += m.dryMass * count
		s.fuel += (m.fuelCapacity or 0) * count
		s.power += (m.power or 0) * count
		if st then
			st.cost += m.cost * count
			st.dryMass += m.dryMass * count
			st.fuel += (m.fuelCapacity or 0) * count
		end
	end
	for i, id in ipairs(design.stack) do
		local st = stageOf[i]
		add(id, (st and st.engineId and i == st.first) and st.engineCount or 1, st)
	end
	for _, id in ipairs(design.radial) do
		add(id, 1, stages[nStages]) -- бічні деталі летять у верхньому ступені
	end

	for _, st in ipairs(stages) do
		if st.engineId then
			local e = Modules[st.engineId]
			st.thrustSL = e.thrustSL * st.engineCount
			st.thrustVac = e.thrustVac * st.engineCount
			st.ispSL = e.ispSL
			st.ispVac = e.ispVac
		end
	end

	-- Тяга на старті = тяга ступеня 1
	local first = stages[1]
	if first and first.engineId then
		s.thrustSL, s.thrustVac = first.thrustSL, first.thrustVac
		s.ispSL, s.ispVac = first.ispSL, first.ispVac
	end

	-- Стартова (повна) маса = суха маса + пальне
	s.wetMass = s.dryMass + s.fuel

	-- TWR = F / (m · g)  — біля поверхні Землі
	if s.wetMass > 0 then
		s.twr = NASAData.TWR(s.thrustSL, s.wetMass, NASAData.Planets.Earth.surfaceGravity)
	end

	-- Формула Ціолковського ДЛЯ КОЖНОГО СТУПЕНЯ, згори вниз:
	--   m0ₖ = маса всіх ступенів від k до верху (з пальним)
	--   m1ₖ = m0ₖ − пальне ступеня k
	--   Δvₖ = Ispₖ · g0 · ln(m0ₖ / m1ₖ),    Δv = Σ Δvₖ
	-- ṁ = F / (Isp · g0) — скільки кг пального згорає за секунду
	local above = 0
	for k = nStages, 1, -1 do
		local st = stages[k]
		local m0 = above + st.dryMass + st.fuel
		local m1 = m0 - st.fuel
		st.m0 = m0
		if st.engineId and st.fuel > 0 and m1 > 0 then
			st.deltaV = st.ispVac * G0 * math.log(m0 / m1)
			st.burnRate = NASAData.FuelBurnRate(st.thrustSL, st.ispSL)
			st.burnTime = st.fuel / st.burnRate
			st.twr = NASAData.TWR(st.thrustVac, m0, NASAData.Planets.Earth.surfaceGravity)
		end
		s.deltaV += st.deltaV
		s.burnTime += st.burnTime
		above = m0
	end
	s.burnRate = first and first.burnRate or 0
	s.stages = stages

	-- Скільки RP-1 треба для повної заправки (решта — кисень LOX)
	s.rp1Needed = s.fuel * NASAData.Constants.RP1_SHARE

	-- Зміщення центру мас від осі через бічні деталі:  x_cm = Σ(mᵢ · xᵢ) / M
	local layout = RocketMath.Layout(design)
	local sx, sz = 0, 0
	for _, r in ipairs(layout.radial) do
		local m = Modules[r.id]
		sx += m.dryMass * math.cos(r.angle) * r.radius
		sz += m.dryMass * math.sin(r.angle) * r.radius
	end
	local offsetStuds = s.wetMass > 0 and math.sqrt(sx * sx + sz * sz) / s.wetMass or 0
	s.comOffsetCm = offsetStuds * METERS_PER_STUD * 100
	s.heightM = layout.height * METERS_PER_STUD
	s.layout = layout
	s.diameterProblems = RocketMath.DiameterCheck(design, layout)

	return s
end

--------------------------------------------------------------------
-- Обладнання, обов'язкове для місії
--------------------------------------------------------------------
-- Вимоги місії "за функцією": будь-який двигун / бак / капсула по осі
local GENERIC_REQUIREMENTS = {
	engine = { name = "Main engine (any)", test = function(id)
		return RocketMath.IsMainEngine(id)
	end },
	tank = { name = "Fuel tank (any)", test = function(id)
		return Modules[id] and Modules[id].category == "tank"
	end },
	command = { name = "Command capsule (any)", test = function(id)
		return Modules[id] and Modules[id].category == "command"
	end },
}

function RocketMath.MissionChecklist(design, missionId)
	local list = {}
	local planet = NASAData.Planets[missionId]
	if not planet then
		return list
	end
	for _, id in ipairs(planet.requiredEquipment) do
		local m = Modules[id]
		local ok = RocketMath.HasModule(design, id)
		local name = m and m.name or id
		if id == "nosecone" and not ok then
			ok = RocketMath.HasModule(design, "fairing") -- обтічник теж захищає нос
		end
		-- Двигун, бак і капсула по осі — будь-яка модель тієї ж категорії (наприклад, Merlin замість
		-- Rutherford): місія вимагає функцію, а не конкретну марку. Прилади та бічні деталі — саме ті.
		local generic = m and m.attach == "stack" and GENERIC_REQUIREMENTS[m.category]
		if generic then
			name = generic.name
			ok = false
			for _, sid in ipairs(design.stack) do
				if generic.test(sid) then
					ok = true
					break
				end
			end
		end
		table.insert(list, { id = id, name = name, ok = ok })
	end
	return list
end

--------------------------------------------------------------------
-- VALIDATE: errors (не можна збирати) і warnings (можна, але варто покращити)
--------------------------------------------------------------------
function RocketMath.Validate(design, budget, missionId)
	local errors, warnings = {}, {}
	local stats = RocketMath.Compute(design)
	local stack, radial = design.stack, design.radial

	local function err(text)
		table.insert(errors, text)
	end
	local function warnText(text)
		table.insert(warnings, text)
	end

	if #stack == 0 then
		err("The rocket is empty. Start with an engine: it always goes at the bottom.")
		return errors, warnings, stats
	end
	if #stack > RocketMath.MAX_STACK then
		err("Too many parts on the main axis (max " .. RocketMath.MAX_STACK .. ").")
	end
	if #radial > RocketMath.MAX_RADIAL then
		err("Too many side parts (max " .. RocketMath.MAX_RADIAL .. ").")
	end

	-- Як кріпиться кожна деталь
	for _, id in ipairs(stack) do
		if Modules[id].attach ~= "stack" then
			err(Modules[id].name .. " can only be attached on the side.")
		end
	end
	for _, id in ipairs(radial) do
		if Modules[id].attach ~= "radial" then
			err(Modules[id].name .. " can only be attached on the main axis.")
		end
	end

	-- Порядок деталей
	if not RocketMath.IsMainEngine(stack[1]) then
		err("An engine must be at the bottom.")
	end
	for i = 2, #stack do
		if RocketMath.IsMainEngine(stack[i]) and stack[i - 1] ~= "decoupler" then
			err("An engine goes at the bottom of the rocket or right above a decoupler (the next stage engine).")
			break
		end
	end

	-- Ступені
	local stages = stats.stages
	if stack[1] == "decoupler" then
		err("A decoupler cannot be at the very bottom.")
	elseif stack[#stack] == "decoupler" then
		err("A decoupler cannot be at the top: the next stage must sit above it.")
	end
	for k = 1, #stages - 1 do
		local st = stages[k]
		if not st.engineId then
			err("Stage " .. k .. " has no engine: every lower stage starts with an engine.")
		elseif st.fuel <= 0 then
			err("Stage " .. k .. " has no fuel tank.")
		end
	end
	local topStage = stages[#stages]
	if #stages > 1 and topStage.engineId and topStage.fuel <= 0 then
		warnText("The upper stage engine will not work without a tank.")
	end

	local podIndex, podCount, tankCount, lastTank = nil, 0, 0, 0
	for i, id in ipairs(stack) do
		local category = Modules[id].category
		if category == "command" then
			podCount += 1
			podIndex = i
		elseif category == "tank" then
			tankCount += 1
			lastTank = i
		end
	end
	if podCount == 0 then
		err("A command capsule is required.")
	elseif podCount > 1 then
		err("Only one capsule is allowed.")
	end
	if tankCount == 0 then
		err("At least one fuel tank is required.")
	end
	if podIndex and lastTank > podIndex then
		err("The capsule must be above all tanks.")
	end
	if podIndex and podIndex < topStage.first then
		err("The capsule must be in the last (top) stage — above all decouplers.")
	end
	local caps = 0
	for i, id in ipairs(stack) do
		if RocketMath.IsTopCap(id) then
			caps += 1
			if i ~= #stack then
				err(Modules[id].name .. " must be at the very top.")
			end
		end
	end
	if caps > 1 then
		err("Only one item can go on top: a nose cone OR a fairing.")
	end
	if table.find(stack, "fairing") and stack[#stack - 1] and Modules[stack[#stack - 1]].category ~= "command" then
		warnText("Place the fairing right above the capsule so it covers it.")
	end

	-- Конструкція: верхній модуль не може бути ширшим за нижній
	for _, pr in ipairs(stats.diameterProblems or {}) do
		err(string.format("Structure: \"%s\" (Ø %.2f m) is wider than \"%s\" below it (Ø %.2f m). "
			.. "The upper module must have the same or a smaller diameter — otherwise the hull may break up at Max-Q.",
			Modules[pr.upper].name, pr.upperD, Modules[pr.lower].name, pr.lowerD))
	end

	-- Фізика: чи злетить?
	if stats.thrustSL > 0 and stats.twr < RocketMath.MIN_TWR then
		err(string.format("TWR = %.2f < 1: thrust is lower than weight, the rocket will not lift off. Add engines or reduce mass.", stats.twr))
	elseif stats.thrustSL > 0 and stats.twr < RocketMath.GOOD_TWR then
		warnText(string.format("TWR = %.2f: the rocket will climb very slowly. TWR ≥ %.1f is better.", stats.twr, RocketMath.GOOD_TWR))
	end

	-- Центр мас
	if stats.comOffsetCm > RocketMath.MAX_COM_OFFSET_CM then
		warnText(string.format("Center of mass is off by %.1f cm — the rocket will lean. Place matching side parts opposite each other.", stats.comOffsetCm))
	end

	-- Обладнання місії
	local missing = {}
	for _, item in ipairs(RocketMath.MissionChecklist(design, missionId)) do
		if not item.ok then
			table.insert(missing, item.name)
		end
	end
	if #missing > 0 then
		local planet = NASAData.Planets[missionId]
		err("Mission \"" .. (planet and planet.name or missionId) .. "\" is missing: " .. table.concat(missing, ", ") .. ".")
	end

	-- Гроші
	if stats.cost > budget then
		err("You are short $" .. fmt(stats.cost - budget) .. " (the rocket costs $" .. fmt(stats.cost) .. ").")
	end

	return errors, warnings, stats
end

return RocketMath
