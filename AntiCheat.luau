--!strict
-- ServerScriptService/AntiCheat  (обычный Script, RunContext = Server)
-- ВСЁ В ОДНОМ ФАЙЛЕ: серверный античит + killbrick'и + автоматический самотест (только Studio).
--
-- Публичное API для других серверных скриптов:
--   player:SetAttribute("AC_GraceUntil", os.clock() + 2)  -- перед серверным телепортом (чекпоинт и т.п.)
--   player:SetAttribute("KillImmune", true)               -- неуязвимость к killbrick'ам (геймпасс, тестер)
-- Атрибуты, выставленные клиентом, на сервер не реплицируются, поэтому подделать их нельзя.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local CONFIG = {
	CheckInterval = 0.2,        -- как часто проверяем игрока (сек)
	MaxSpeed = 45,              -- макс. горизонтальная скорость (studs/сек)
	ExpectedWalkSpeed = 16,     -- нормальный WalkSpeed в вашей игре
	MaxTeleportDistance = 40,   -- макс. смещение за один интервал без разрешения сервера
	MaxHoverTime = 1.5,         -- сколько можно "висеть" в воздухе (сек)
	ViolationsToRollback = 3,   -- нарушений для отката позиции
	ViolationsToKick = 8,       -- нарушений для кика
	ViolationDecaySeconds = 10, -- через сколько секунд без нарушений счётчик уменьшается на 1
	KillBrickTag = "KillBrick", -- тег (CollectionService) для killbrick'ов
	RunSelfTest = true,         -- самотест при запуске (работает ТОЛЬКО в Studio)
}

type State = {
	lastPos: Vector3?,
	violations: number,
	lastViolationAt: number,
	hoverTime: number,
	lastSafeCFrame: CFrame?,
}

local states: { [Player]: State } = {}

-- ========== Вспомогательные функции ==========

local function inGrace(player: Player): boolean
	local g = player:GetAttribute("AC_GraceUntil")
	return typeof(g) == "number" and os.clock() < g
end

local function getParts(player: Player): (Humanoid?, BasePart?)
	local char = player.Character
	if not char then return nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and root and root:IsA("BasePart") then
		return hum, root
	end
	return nil, nil
end

local function flag(player: Player, st: State, reason: string)
	st.violations += 1
	st.lastViolationAt = os.clock()
	warn(("[AntiCheat] %s: %s (нарушений: %d)"):format(player.Name, reason, st.violations))

	if st.violations >= CONFIG.ViolationsToKick then
		player:Kick("Обнаружено нечестное поведение.")
		return
	end

	if st.violations >= CONFIG.ViolationsToRollback and st.lastSafeCFrame then
		local _, root = getParts(player)
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = st.lastSafeCFrame
			st.lastPos = st.lastSafeCFrame.Position
		end
	end
end

local function resetState(player: Player)
	local st = states[player]
	if not st then return end
	st.lastPos = nil
	st.hoverTime = 0
	st.lastSafeCFrame = nil
	player:SetAttribute("AC_GraceUntil", os.clock() + 3) -- льгота на спавн
end

-- ========== Проверки ==========

local function checkPlayer(player: Player, st: State, dt: number)
	local now = os.clock()
	local hum, root = getParts(player)
	if not hum or not root then
		st.lastPos = nil
		return
	end

	-- затухание нарушений
	if st.violations > 0 and now - st.lastViolationAt > CONFIG.ViolationDecaySeconds then
		st.violations -= 1
		st.lastViolationAt = now
	end

	if inGrace(player) then
		st.lastPos = root.Position
		st.hoverTime = 0
		st.lastSafeCFrame = root.CFrame
		return
	end

	local pos = root.Position
	local last = st.lastPos
	st.lastPos = pos
	if not last then
		st.lastSafeCFrame = root.CFrame
		return
	end

	local delta = pos - last
	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local suspicious = false

	-- 1) Телепорт
	if delta.Magnitude > CONFIG.MaxTeleportDistance and delta.Y > -CONFIG.MaxTeleportDistance then
		flag(player, st, ("телепорт на %.0f studs"):format(delta.Magnitude))
		suspicious = true
	end

	-- 2) Скорость
	local speed = horizontal / math.max(dt, 1e-3)
	if not suspicious and speed > CONFIG.MaxSpeed then
		flag(player, st, ("скорость %.0f studs/с"):format(speed))
		suspicious = true
	end

	-- 3) Полёт / зависание в воздухе
	local state = hum:GetState()
	local legitAir = state == Enum.HumanoidStateType.Climbing
		or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.GettingUp
	if hum.FloorMaterial == Enum.Material.Air and not legitAir then
		if root.AssemblyLinearVelocity.Y > -8 then
			st.hoverTime += dt
		else
			st.hoverTime = math.max(0, st.hoverTime - dt)
		end
		if st.hoverTime > CONFIG.MaxHoverTime then
			flag(player, st, "полёт/зависание в воздухе")
			st.hoverTime = 0
			suspicious = true
		end
	else
		st.hoverTime = 0
	end

	-- 4) Параметры Humanoid (сервер видит реплицированные значения)
	if hum.WalkSpeed > CONFIG.ExpectedWalkSpeed + 2 then
		flag(player, st, ("изменён WalkSpeed (%.0f)"):format(hum.WalkSpeed))
		hum.WalkSpeed = CONFIG.ExpectedWalkSpeed
	end
	if hum.JumpPower > 80 or hum.JumpHeight > 30 or hum.HipHeight > 10 then
		flag(player, st, "изменённые параметры Humanoid")
		hum.JumpPower = 50
		hum.HipHeight = 0
	end

	if not suspicious and hum.FloorMaterial ~= Enum.Material.Air then
		st.lastSafeCFrame = root.CFrame
	end
end

-- ========== Killbrick'и ==========
-- Part с тегом "KillBrick" убивает игрока при касании, кроме случаев:
--   * сервер пометил игрока атрибутом KillImmune = true
--   * на персонаже есть ForceField (стандартный спавн-щит)

local function onKillBrickTouched(hit: BasePart)
	local char = hit.Parent
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	local player = Players:GetPlayerFromCharacter(char)
	if player and player:GetAttribute("KillImmune") == true then return end
	if char:FindFirstChildOfClass("ForceField") then return end

	hum.Health = 0
end

local function setupKillBrick(inst: Instance)
	if inst:IsA("BasePart") then
		inst.Touched:Connect(onKillBrickTouched)
	end
end

for _, inst in CollectionService:GetTagged(CONFIG.KillBrickTag) do
	setupKillBrick(inst)
end
CollectionService:GetInstanceAddedSignal(CONFIG.KillBrickTag):Connect(setupKillBrick)

-- ========== Самотест (только Studio) ==========
-- Симулирует нарушения на сервере и печатает PASS/FAIL в Output.
-- Запускается один раз для первого игрока, через 5 сек после появления персонажа.

local selfTestStarted = false

local function runSelfTest(player: Player)
	task.wait(5) -- ждём окончания льготного периода после спавна

	local st = states[player]
	local hum, root = getParts(player)
	if not st or not hum or not root then
		warn("[SelfTest] персонаж не найден, тест отменён")
		return
	end

	local origin = root.CFrame

	local function reset()
		st.violations = 0
		st.hoverTime = 0
	end
	local function grace(sec: number)
		player:SetAttribute("AC_GraceUntil", os.clock() + sec)
	end
	local function report(name: string, ok: boolean)
		print(("[SelfTest] %-28s %s"):format(name, ok and "PASS" or "FAIL"))
	end
	local function spawnBrick(): Part
		local b = Instance.new("Part")
		b.Size = Vector3.new(8, 8, 8)
		b.Anchored = true
		b.CanCollide = false
		b.Transparency = 0.6
		b.Position = origin.Position + origin.LookVector * 20
		b.Parent = workspace
		CollectionService:AddTag(b, CONFIG.KillBrickTag)
		return b
	end

	print("[SelfTest] === старт ===")

	-- 1) WalkSpeed
	reset()
	hum.WalkSpeed = 100
	task.wait(1)
	report("WalkSpeed 100", st.violations > 0 and hum.WalkSpeed <= CONFIG.ExpectedWalkSpeed)

	-- 2) Телепорт
	reset()
	root.CFrame = root.CFrame + root.CFrame.LookVector * 100
	task.wait(0.6)
	report("Телепорт на 100 studs", st.violations > 0)
	reset()
	grace(1.5)
	root.CFrame = origin
	task.wait(1.8)

	-- 3) Зависание в воздухе
	reset()
	root.CFrame = origin + Vector3.new(0, 15, 0)
	root.Anchored = true
	task.wait(3)
	report("Зависание в воздухе", st.violations > 0)
	root.Anchored = false
	task.wait(2)

	-- 4) JumpPower
	reset()
	hum.UseJumpPower = true
	hum.JumpPower = 150
	task.wait(0.6)
	report("JumpPower 150", st.violations > 0 and hum.JumpPower <= 80)

	-- 5) Killbrick при неуязвимости (не должен убить)
	reset()
	grace(1.5)
	root.CFrame = origin
	task.wait(1.8)
	player:SetAttribute("KillImmune", true)
	local brick1 = spawnBrick()
	grace(2)
	root.CFrame = CFrame.new(brick1.Position)
	task.wait(1)
	report("Killbrick + KillImmune", hum.Health > 0)
	brick1:Destroy()
	grace(1.5)
	root.CFrame = origin
	task.wait(1.8)

	-- 6) Killbrick без неуязвимости (должен убить)
	player:SetAttribute("KillImmune", false)
	local brick2 = spawnBrick()
	grace(2)
	root.CFrame = CFrame.new(brick2.Position)
	task.wait(1)
	report("Killbrick без иммунитета", hum.Health <= 0)
	brick2:Destroy()

	print("[SelfTest] === конец ===")
end

-- ========== Подключение игроков и главный цикл ==========

local function onPlayerAdded(player: Player)
	states[player] = {
		lastPos = nil,
		violations = 0,
		lastViolationAt = os.clock(),
		hoverTime = 0,
		lastSafeCFrame = nil,
	}

	player.CharacterAdded:Connect(function()
		resetState(player)
	end)
	if player.Character then
		resetState(player)
	end

	if CONFIG.RunSelfTest and RunService:IsStudio() and not selfTestStarted then
		selfTestStarted = true
		if player.Character then
			task.spawn(runSelfTest, player)
		else
			player.CharacterAdded:Once(function()
				task.spawn(runSelfTest, player)
			end)
		end
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	onPlayerAdded(p)
end
Players.PlayerRemoving:Connect(function(p)
	states[p] = nil
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < CONFIG.CheckInterval then return end
	local step = acc
	acc = 0
	for player, st in states do
		checkPlayer(player, st, step)
	end
end)
