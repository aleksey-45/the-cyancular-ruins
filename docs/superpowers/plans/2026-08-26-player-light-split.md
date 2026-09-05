# player.gd 轻量拆分实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 player.gd(448 行)中最自包含的攀爬/战斗/武器三块抽成 Player.tscn 子节点组件,根脚本降到约 250 行,行为与公开接口完全不变。

**Architecture:** 新增 3 个空 Node 子节点(`Climb`/`Combat`/`Weapons`)挂各自脚本,根 `player.gd` 保持 CharacterBody2D 并每物理帧显式按固定顺序驱动组件,杜绝节点调度乱序。跨组件状态经根显式传参,组件只通过 `body`(父节点)引用操作。

**Tech Stack:** Godot 4.7.1(GDScript)、`class_name` 组件、Player.tscn 手改 ext_resource。

## Global Constraints

- Godot 4.7.1 标准控制台:`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`。
- **公开 API 契约一字不改**(外部调用方零改动):`take_hit(source_pos, damage, ignore_iframes=false, knockback=-1.0)`、`get_facing()`、`set_facing(v)`、`is_downed()`、`apply_recoil(push)`、信号 `hp_changed(current, max)`、`player` 组、`collision_layer=2`/`collision_mask=5`/scale 2.5。
- **组件不写自己的 `_physics_process`/`_process`** —— 根每帧显式调用,物理顺序与现状一致。
- 跨组件状态经根传参;组件内部状态各自私有(`_latched`/`knock_velocity`/`_weapon`),组件间不互相引用。
- **无 -s 可实例化的玩家单测**(player.gd 引用 autoload `GameParameters`,实测 `-s` 阶段连编译都失败)。本计划用「源码级契约 lint + 每任务 headless 启动验证」替代 test-first;手感由用户进游戏验证。
- 每任务结束跑验证后单独提交;提交时**只 add 本任务的文件**,不碰工作区其他并发改动。
- 依赖:`MazeGenerator`/`TileDefs`/`PlayerParams` 均为 `class_name`(非 autoload),组件内可直接引用;`GameParameters`(autoload)仅在真实运行时可用。

---

### Task 1: 契约守卫 + 基线验证

**Files:**
- Create: `Tests/player_contract_smoke.gd`

**Interfaces:**
- Produces: `player_contract_smoke.gd` —— 源码级守卫:检查根公开接口存在、组件文件/类名存在、根每物理帧驱动三个组件、武器注册表 5 槽完整。所有 task 完成前组件检查 FAIL,完成后全 PASS。

- [ ] **Step 1: 创建契约守卫测试**

```gdscript
extends SceneTree
# 玩家公开接口契约守卫:拆分重构期间保证公开 API 不被改名/删掉。
# 源码级检查(player.gd 在 -s 阶段因 autoload 无法实例化,见 CLAUDE.md 冒烟注释)。

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/player/player.gd")
	var lsrc := FileAccess.get_file_as_string("res://scenes/player/climb_component.gd")
	var csrc := FileAccess.get_file_as_string("res://scenes/player/combat_component.gd")
	var wsrc := FileAccess.get_file_as_string("res://scenes/player/weapon_component.gd")
	# 根公开方法(外部调用方依赖,签名必须保持)
	for sig in [
		"func take_hit(",
		"func get_facing(",
		"func set_facing(",
		"func is_downed(",
		"func apply_recoil(",
		"signal hp_changed(",
		"add_to_group(\"player\")",
	]:
		_check(src.contains(sig), "player.gd 含 " + sig)
	# 三个组件文件 + class_name
	var comps: Array = [
		[lsrc, "climb_component.gd", "class_name ClimbComponent"],
		[csrc, "combat_component.gd", "class_name CombatComponent"],
		[wsrc, "weapon_component.gd", "class_name WeaponComponent"],
	]
	for pair in comps:
		_check(str(pair[0]).length() > 0 and str(pair[0]).contains(str(pair[2])),
				"含 " + str(pair[1]) + " 的 " + str(pair[2]))
	# 武器注册表 5 槽(挪到 weapon 组件)
	for k in ["1", "2", "3", "4", "5"]:
		_check(wsrc.contains("\"%s\"" % k), "weapon 注册表含槽 %s" % k)
	# 根每物理帧显式驱动三个组件
	_check(src.contains("climb.update("), "根驱动 climb.update")
	_check(src.contains("combat.apply_knock("), "根驱动 combat.apply_knock")
	_check(src.contains("weapons.movement_multiplier()"), "根驱动 weapons.movement_multiplier")

	if _failures.is_empty():
		print("\nCONTRACT OK")
		quit(0)
	else:
		printerr("\nCONTRACT FAIL: %d 项" % _failures.size())
		quit(1)
```

- [ ] **Step 2: 运行契约守卫,确认对组件部分 RED**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd`
Expected: 根公开接口 7 项 ok;组件 3 项 FAIL(climb/combat/weapon_component.gd 还不存在);weapon 注册表 5 项 FAIL;根驱动 3 项 FAIL(尚未接入)。退出码 1。

- [ ] **Step 3: 跑一次 headless 基线启动,确认重构前游戏正常**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90`
Expected: 无 `SCRIPT ERROR` 行;末尾打印 `[EnemySpawner] spawned N enemies from map`。

- [ ] **Step 4: Commit**

```bash
git add Tests/player_contract_smoke.gd
git commit -m "test: 玩家公开接口契约守卫(拆分基线 RED)"
```

---

### Task 2: 抽取 ClimbComponent(攀爬)

**Files:**
- Create: `Scenes/Player/climb_component.gd`
- Modify: `Scenes/Player/Player.tscn`(加 ext_resource + Climb 节点)
- Modify: `Scenes/Player/player.gd`(删攀爬块、接线)

**Interfaces:**
- Consumes: `player.gd` 的 `is_squat`(参数传入)、`body.velocity`/`body.global_position`、`MazeGenerator`/`TileDefs`/`PlayerParams`。
- Produces: `ClimbComponent.update(mult: Vector2, delta: float, is_squat: bool) -> bool`、`is_latched() -> bool`;根新增 `cancel_jump_state()` 供组件在「跳离梯顶」时清跳跃缓冲。

- [ ] **Step 1: 创建 `Scenes/Player/climb_component.gd`**

```gdscript
class_name ClimbComponent
extends Node

# 攀爬(梯子/锁链)子系统:中心/脚底在通道格按上主动攀附,不受重力。
# 由根 player.gd 每物理帧显式调用(不在本组件写 _physics_process,保证物理帧顺序)。

var body: CharacterBody2D

var _latched: bool = false   # 攀附状态:中心在通道格(梯/锁链)即攀附,不受重力

const STOP_SNAP := 1.0       # 与根一致:水平速度低于此值归零

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_latched() -> bool:
	return _latched

# 攀爬判定与攀附状态机:中心(或脚底)在通道格按上主动攀附(不受重力)。
# **到顶 = 脚底进入梯子上方一格才停**(以脚底为参考格);再按上 = 跳离梯子。
# 上爬按瓦片 climb_speed 倍(梯 1.6/锁链 2.0),下降按 climb_descent_speed 倍(梯 2.0),
# 锁链无下降倍率(0)→ 解除攀附交给重力自由落体;松开挂住。返回「正在垂直攀爬」。
func update(mult: Vector2, delta: float, is_squat: bool) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty() or is_squat:
		_latched = false
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var foot_pos := body.global_position + Vector2(0.0, _climb_foot_offset())
	var foot_cell := MazeGenerator.cell_of(foot_pos, GameParameters.TILE_SIZE, cols, rows)
	var center_cell := MazeGenerator.cell_of(body.global_position, GameParameters.TILE_SIZE, cols, rows)
	var fv: int = grid[foot_cell.y][foot_cell.x]
	var cv: int = grid[center_cell.y][center_cell.x]
	# 爬速取脚底/中心所在梯子的倍率较大者:基地时脚踩地中心在梯里、到顶时中心出梯脚还在梯里
	var cs: float = maxf(TileDefs.climb_speed(fv / 16), TileDefs.climb_speed(cv / 16))
	var foot_in_channel := fv != 0 and TileDefs.climb_speed(fv / 16) > 0.0
	var center_in_channel := cv != 0 and TileDefs.climb_speed(cv / 16) > 0.0
	var climb_input := Input.get_axis("up", "down")
	# 进入攀附:中心或脚底在通道格且「刚按下上」(主动抓;不是按住——跳离梯子后按着上也抓不回)
	# 退出:中心与脚底都不在通道格,且脚底不在梯顶(到顶 = 挂住不算退出)
	if not _latched and (center_in_channel or foot_in_channel) and Input.is_action_just_pressed("up"):
		_latched = true
	if _latched and not center_in_channel and not foot_in_channel and not _foot_at_ladder_top(foot_cell):
		_latched = false
	if not _latched:
		return false
	if climb_input < 0.0:
		if foot_in_channel or not _foot_at_ladder_top(foot_cell):
			# 脚底还没跨过梯顶(在梯子里/在梯子下方)→ 上爬:climb_speed × 瓦片倍率
			var spd := PlayerParams.climb_speed * cs * mult.y
			body.velocity.y = climb_input * spd
			body.velocity.x = _approach(body.velocity.x, 0.0, PlayerParams.brake_ground, delta)
			if absf(body.velocity.x) < STOP_SNAP:
				body.velocity.x = 0.0
			return true
		# 脚底进入梯子上方一格 → 到顶:再按上 = 跳离梯子,进入上方空间
		if Input.is_action_just_pressed("up"):
			_latched = false
			body.velocity.y = PlayerParams.jump_velocity * mult.y
			body.cancel_jump_state()
			return false
		body.velocity.y = 0.0  # 到顶挂住(松开/再按上可跳)
		return true
	elif climb_input > 0.0:
		var dcs := TileDefs.climb_descent_speed(fv / 16)
		if dcs <= 0.0:
			# 锁链(无下降倍率)= 自由落体:解除攀附交给重力,落下不再抓回
			_latched = false
			return false
		body.velocity.y = climb_input * PlayerParams.climb_speed * dcs * mult.y
		body.velocity.x = _approach(body.velocity.x, 0.0, PlayerParams.brake_ground, delta)
		if absf(body.velocity.x) < STOP_SNAP:
			body.velocity.x = 0.0
		return true
	body.velocity.y = 0.0  # 挂住:不受重力,原地停留
	return false

# 脚底所在格下方是否仍是梯子 → 脚底刚跨过梯顶(进入上方格),这是「到顶」,不解除攀附。
func _foot_at_ladder_top(foot_cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var below: int = grid[posmod(foot_cell.y + 1, rows)][foot_cell.x]
	return below != 0 and TileDefs.climb_speed(below / 16) > 0.0

# 脚底到玩家中心的距离(攀爬姿态 FLY 碰撞箱底部,含 scale 2.5)。
func _climb_foot_offset() -> float:
	return 57.0

# 指数缓动(根移动逻辑同款,仅用于攀爬时把横速归零)。
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
```

- [ ] **Step 2: Player.tscn 加 Climb 节点**

在 `[ext_resource ... "res://scenes/player/Player.tscn"]` 现有 ext_resource 行后追加一行(uid 缺省,首次在编辑器打开时补):

```
[ext_resource type="Script" path="res://scenes/player/climb_component.gd" id="3_climb"]
```

在 `[node name="WeaponSlot" ...]` 行后追加:

```
[node name="Climb" type="Node" parent="."]
script = ExtResource("3_climb")
```

- [ ] **Step 3: player.gd 删攀爬块、接线**

3a. 在 `@export var weapon_slot: Node2D` 后加:

```gdscript
@onready var climb: ClimbComponent = $Climb
```

3b. 删掉状态标志里的 `_latched`:

```gdscript
# 状态标志
var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 1=右，-1=左
```

3c. 整段删除函数 `_update_climb`(原 107-163 行)、`_foot_at_ladder_top`(167-173)、`_climb_foot_offset`(177-178)。

3d. `_physics_process` 里把:

```gdscript
	# ---------- 攀爬(梯子/锁链:攀附不受重力,按住上/下爬,锁链更快,下降更快) ----------
	var climbing := _update_climb(mult, delta)
	var latched := _latched
```

换成:

```gdscript
	# ---------- 攀爬(梯子/锁链:攀附不受重力,按住上/下爬,锁链更快,下降更快) ----------
	var climbing := climb.update(mult, delta, is_squat)
	var latched := climb.is_latched()
```

3e. `apply_recoil` 里 `if _latched:` 换成 `if climb.is_latched():`(攀爬状态已移出根)。

3f. 在 `apply_recoil` 后加:

```gdscript
# 攀爬跳离梯顶时清跳跃缓冲/土狼/截断标记:防止残留输入造成二次起跳(由 climb 组件调用)。
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false
```

- [ ] **Step 4: 验证**

Run 1(契约): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd`
Expected: 根接口 7 项 ok;`climb_component.gd` 检查 ok、根驱动 `climb.update` ok;combat/weapon 组件 + 武器注册表 + 根驱动 combat/weapon 2 项仍 FAIL。退出码 1(预期,其余组件未抽)。

Run 2(启动): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90`
Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 5: Commit**

```bash
git add Scenes/Player/climb_component.gd Scenes/Player/Player.tscn Scenes/Player/player.gd
git commit -m "refactor: 攀爬逻辑抽到 ClimbComponent(行为不变)"
```

---

### Task 3: 抽取 WeaponComponent(武器)

**Files:**
- Create: `Scenes/Player/weapon_component.gd`
- Modify: `Scenes/Player/Player.tscn`(加 ext_resource + Weapons 节点)
- Modify: `Scenes/Player/player.gd`(删武器块、接线)

**Interfaces:**
- Consumes: `player.gd` 的 `weapon_slot`(经 `body.weapon_slot`)、`facing_direction`(经 `body.facing_direction`)、`is_squat`/`climb.is_latched()`(参数传入)。
- Produces: `WeaponComponent.equip(slot: String)`、`movement_multiplier() -> Vector2`、`apply_recoil(push: float, is_squat: bool, is_latched: bool)`、`cancel_aim()`(供 combat 倒地时调用)。

- [ ] **Step 1: 创建 `Scenes/Player/weapon_component.gd`**

```gdscript
class_name WeaponComponent
extends Node

# 武器子系统:注册表/换枪/移动惩罚/后坐。枪实例挂在 body.weapon_slot 下。
# 由根 player.gd 驱动(equip 在 _ready/换枪输入,movement_multiplier 每物理帧,
# apply_recoil 由 weapon_base 经根转发)。

const WEAPONS: Dictionary = {
	"1": "res://scenes/weapons/pistol_test.tscn",
	"2": "res://scenes/weapons/rifle_test.tscn",
	"3": "res://scenes/weapons/m82a1.tscn",
	"4": "res://scenes/weapons/s686.tscn",
	"5": "res://scenes/weapons/grenade_launcher.tscn",
}

var _weapon: WeaponBase = null
var body: CharacterBody2D

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func equip(slot: String) -> void:
	# 切枪继承旧武器剩余冷却:后摇不能被切枪取消(queue_free 前先捕获)
	var inherit_cd := 0.0
	if _weapon != null:
		inherit_cd = _weapon.fire_cd_timer
		_weapon.queue_free()
	var scene: PackedScene = load(WEAPONS[slot])
	if scene == null:
		push_error("weapon scene not found: " + str(WEAPONS[slot]))
		return
	if body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_weapon = scene.instantiate() as WeaponBase
	body.weapon_slot.add_child(_weapon)
	_weapon.equip(body, inherit_cd)

func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1  # 攀爬时后坐力降到 0.1(在梯/锁链上开火基本不后推)
	body.velocity.x -= body.facing_direction * push

func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()
```

- [ ] **Step 2: Player.tscn 加 Weapons 节点**

ext_resource 行后追加:

```
[ext_resource type="Script" path="res://scenes/player/weapon_component.gd" id="4_wpn"]
```

Climb 节点后追加:

```
[node name="Weapons" type="Node" parent="."]
script = ExtResource("4_wpn")
```

- [ ] **Step 3: player.gd 删武器块、接线**

3a. `@onready var climb: ClimbComponent = $Climb` 后加:

```gdscript
@onready var weapons: WeaponComponent = $Weapons
```

3b. 删掉 `const WEAPONS: Dictionary`(原 47-54 行)和 `var _weapon: WeaponBase = null`(56)。

3c. `_ready` 里 `_equip_weapon(WEAPONS["1"])` 换成:

```gdscript
	weapons.equip("1")
```

3d. `_physics_process` 里 `var mult := _movement_multiplier()` 换成:

```gdscript
	var mult := weapons.movement_multiplier()
```

3e. 整段删除 `_equip_weapon`(396-411)、`_movement_multiplier`(413-416)。

3f. `apply_recoil` 整个换成:

```gdscript
func apply_recoil(push: float) -> void:
	weapons.apply_recoil(push, is_squat, climb.is_latched())
```

3g. `_downed` 里取消瞄准的引用改走组件(`_weapon` 已移入组件,不换会悬空引用编译错误):

```gdscript
	if _weapon != null:
		_weapon.cancel_aim()
```
换成一行:
```gdscript
	weapons.cancel_aim()
```

3h. `_unhandled_input` 里 `_equip_weapon(WEAPONS[slot])` 换成 `weapons.equip(slot)`。

- [ ] **Step 4: 验证**

Run 1(契约): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd`
Expected: 根接口 ok、climb ok、weapon 组件 + 注册表 5 槽 ok、`weapons.movement_multiplier()` 驱动 ok;仅 combat 组件 + `combat.apply_knock` 驱动 2 项仍 FAIL。退出码 1。

Run 2(启动): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90`
Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 5: Commit**

```bash
git add Scenes/Player/weapon_component.gd Scenes/Player/Player.tscn Scenes/Player/player.gd
git commit -m "refactor: 武器管理抽到 WeaponComponent(行为不变)"
```

---

### Task 4: 抽取 CombatComponent(战斗)

**Files:**
- Create: `Scenes/Player/combat_component.gd`
- Modify: `Scenes/Player/Player.tscn`(加 ext_resource + Combat 节点)
- Modify: `Scenes/Player/player.gd`(删战斗块、接线)

**Interfaces:**
- Consumes: `body.get_facing()`(被击退方向兜底)、`body.velocity`/`body.global_position`/`body.modulate`/`body.rotation`/`body.animator`、根 `cancel_charge()`(命中落地时打断冲刺)。
- Produces: `CombatComponent.take_hit(...)`(签名同旧)、`is_downed()`、`update_iframe_blink(delta)`、`apply_knock(delta)`、信号 `hp_changed(current, max)`、信号 `downed`(根连到 `weapons.cancel_aim`)。

- [ ] **Step 1: 创建 `Scenes/Player/combat_component.gd`**

```gdscript
class_name CombatComponent
extends Node

# 战斗子系统:生命/无敌帧/爆炸击退向量/倒地。hp_changed 由根转发给 HUD。
# 由根 player.gd 驱动(take_hit 经根转发、apply_knock/update_iframe_blink 每物理帧)。

signal hp_changed(current: int, max: int)
signal downed   # 倒地瞬间触发,根连到 weapons.cancel_aim(保持旧 _downed 里的取消瞄准)

var max_hp: int = PlayerParams.player_max_hp
var hp: int = PlayerParams.player_max_hp
var iframes: float = 0.0
var downed: bool = false
var knock_velocity: Vector2 = Vector2.ZERO  # 爆炸专属击退向量(独立于移动速度,指数衰减)

var body: CharacterBody2D

const IFRAME_BLINK_RATE := 20.0   # 无敌帧闪烁频率(每秒明暗切换次数)

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_downed() -> bool:
	return downed

# 无敌帧递减 + 闪烁,每物理帧由根在移动逻辑前调用。
func update_iframe_blink(delta: float) -> void:
	iframes = maxf(iframes - delta, 0.0)
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes: 特殊攻击(如冲撞)穿透无敌帧,但命中后照常刷新 iframes。
	if downed or (iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	body.cancel_charge()
	hp -= damage
	iframes = PlayerParams.iframes_time
	var away := (body.global_position - source_pos).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		# 常规命中:固定击退直接覆盖(原行为)
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		# 爆炸:设独立击退向量(叠加,不覆盖移动),随帧指数衰减
		knock_velocity = away * knockback
	# 大伤害反馈:一次扣血 >25% 最大血 → 相机震动(幅度随伤害比例增强)
	var hit_ratio := float(damage) / float(max_hp)
	if hit_ratio > 0.25:
		var cam: Camera2D = body.get_viewport().get_camera_2d()
		if cam != null and cam.has_method("shake"):
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity。
# (地面把向下击退吃掉后再减回去会把玩家弹起,改用独立位移结算)
func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

func _downed() -> void:
	downed = true
	# 不取消物理:保留当前速度/击退,尸体继续受重力/冲击(与敌人统一)
	body.rotation = -PI / 2.0 * float(body.get_facing())
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.stop()
	downed.emit()
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(true)
```

- [ ] **Step 2: Player.tscn 加 Combat 节点**

ext_resource 行后追加:

```
[ext_resource type="Script" path="res://scenes/player/combat_component.gd" id="5_cmb"]
```

Weapons 节点后追加:

```
[node name="Combat" type="Node" parent="."]
script = ExtResource("5_cmb")
```

- [ ] **Step 3: player.gd 删战斗块、接线**

3a. `@onready var weapons: WeaponComponent = $Weapons` 后加:

```gdscript
@onready var combat: CombatComponent = $Combat
```

3b. 删掉战斗状态变量(原 39-43 行):

```gdscript
	# ── 战斗 ──
	var max_hp: int = PlayerParams.player_max_hp
	var hp: int = PlayerParams.player_max_hp
	var iframes: float = 0.0
	var downed: bool = false
	var knock_velocity: Vector2 = Vector2.ZERO  # 爆炸专属击退向量(独立于移动速度,指数衰减)
```

3c. 删掉 `signal hp_changed(current: int, max: int)`(58 行),在姿态状态机上方加回(公共契约保持在根):

```gdscript
signal hp_changed(current: int, max: int)   # 转发自 CombatComponent,HUD 接口不变
```

3d. 删掉 `const IFRAME_BLINK_RATE := 20.0`(79 行,已入 combat)。

3e. `_ready` 在 `add_to_group("player")` 后、缓存碰撞箱前,加连线(并把原 `hp_changed.emit(hp, max_hp)` 换成):

```gdscript
	# 转发 combat 的生命/倒地信号到根(外部只认根上的 hp_changed;倒地 → 取消瞄准)
	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.downed.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)
```

3f. `_physics_process` 开头,把:

```gdscript
func _physics_process(delta: float) -> void:
	if downed:
```

换成:

```gdscript
func _physics_process(delta: float) -> void:
	if combat.is_downed():
```

3g. 紧接其后,把:

```gdscript
	iframes = maxf(iframes - delta, 0.0)
	# 无敌帧闪烁
	if iframes > 0.0:
		modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		modulate.a = 1.0
```

换成:

```gdscript
	combat.update_iframe_blink(delta)
```

3h. 两处(倒地分支 + 正常路径)的:

```gdscript
		move_and_collide(knock_velocity * delta)
		knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)
```

都换成(每处一行):

```gdscript
		combat.apply_knock(delta)
```

3i. 把 `take_hit` 整函数(355-382)换成转发器:

```gdscript
func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
```

3j. `is_downed()` 换成:

```gdscript
func is_downed() -> bool:
	return combat.is_downed()
```

3k. 整段删除 `_downed`(425-437)。

3l. 加 `cancel_charge`(combat 命中落地时调用;is_charge 所有权留根):

```gdscript
# combat 命中落地时调用:冲刺被打断,否则下一帧 is_charge 分支会用冲刺速度覆盖击退。
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0
```

3m. `_unhandled_input` 里 `if downed:` 换成 `if combat.is_downed():`。

- [ ] **Step 4: 验证**

Run 1(契约): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd`
Expected: 全部 ok,末尾打印 `CONTRACT OK`,退出码 0。

Run 2(启动): `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90`
Expected: 无 `SCRIPT ERROR`;末尾 `[EnemySpawner] spawned N enemies from map`。

- [ ] **Step 5: Commit**

```bash
git add Scenes/Player/combat_component.gd Scenes/Player/Player.tscn Scenes/Player/player.gd
git commit -m "refactor: 战斗/生命/倒地抽到 CombatComponent(行为不变)"
```

---

### Task 5: 终验 + CLAUDE.md 同步

**Files:**
- Modify: `CLAUDE.md`(玩家一节补充组件结构)
- Modify: `Tests/player_contract_smoke.gd`(无改动,仅复跑)

- [ ] **Step 1: 跑共享依赖冒烟 + 契约 + 启动三连**

Run 1(现有冒烟,确认共享依赖无回归):
`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd`
Expected: 打印 `SMOKE OK` 退出码 0。

Run 2(契约): 同 Task 4 Step 4 Run 1,Expected `CONTRACT OK`。

Run 3(启动): 同 Task 4 Step 4 Run 2,Expected 无 `SCRIPT ERROR`。

- [ ] **Step 2: 更新 CLAUDE.md 玩家一节**

在 `### 玩家(Scenes/Player/player.gd)` 一节末尾追加组件说明:

```markdown
- **结构(轻量拆分)**:根 `player.gd` 只留移动/姿态/物理帧编排;攀爬(梯/锁链)、战斗(生命/无敌/击退/倒地)、武器(注册表/换枪/后坐)分别抽成 `ClimbComponent`/`CombatComponent`/`WeaponComponent`(Player.tscn 子节点)。组件**不写自己的 `_physics_process`**,由根每帧显式按顺序调用(`climb.update → 移动 → combat.apply_knock → move_and_slide`)。跨组件状态经根传参;根公开接口 `take_hit/get_facing/set_facing/is_downed/apply_recoil` 与 `hp_changed` 信号原样保留(HUD/敌人/武器零改动)。契约守卫 `Tests/player_contract_smoke.gd`(源码级)保接口不漂。
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 同步玩家组件化结构"
```

- [ ] **Step 4: 交用户手感验证**

请用户在游戏里跑一遍:移动/跳跃/冲刺/下蹲/梯子与锁链攀爬(上爬/下降/挂住/到顶跳离)/受击(普通击退+爆炸击退+倒地暗角)/换枪 1-5 与后坐/攀爬中开火后坐衰减。接口不变,预期零行为差异。
