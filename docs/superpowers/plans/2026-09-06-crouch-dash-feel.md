# 下蹲 & 冲刺手感优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉"空中松开 S 仍卡蹲",下蹲可蹲走;冲刺 0.4s 保留长距离但跳跃可打断、撞墙自然停、空中冲刺重力×0.35、收尾平滑。

**Architecture:** 全部改动在 `player.gd` 的下蹲/冲刺/垂直重力几段 + `PlayerParams` 加 2 个 const + 一个 headless 冒烟。状态仍用现有 `is_squat`/`is_charge`/`charge_timer`(已在 `capture_state` 覆盖),不新增网络字段 → PvP C2 孪生不受影响。

**Tech Stack:** Godot 4.7.1 GDScript。测试 = `extends SceneTree` / scene 模式 headless 冒烟(项目无单测框架,见 CLAUDE.md「测试」节)。

## Global Constraints

- Godot 4.7.1 标准编辑器(非 mono),headless 冒烟。
- 玩家参数只改 `core/player_params.gd` 的 const;`player.gd` 在实例变量里引用(见 11-17 行模式),不要改成 autoload。
- `is_squat` 由"边沿 toggle"改为"逐帧推导"后,仍是 `capture_state` 的 `squat` 字段名,不改名。
- 不新增网络/协议字段;`charge_duration`/`crouch_walk_speed`/`charge_air_gravity_mult` 都是实例启动时读 const,两端同参。
- 测试约定:冒烟脚本用户自跑;实现过程用 `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`。
- 完成后跑 4 个回归(enemy_logic/reconcile/twin/match)+ 新 move_feel 冒烟须全绿。

---

## File Structure

- **Modify** `core/player_params.gd` — `charge_duration` 0.6→0.4;加 `crouch_walk_speed`、`charge_air_gravity_mult`。
- **Modify** `scenes/player/player.gd` — 头部加 2 个实例常量;下蹲段重写为逐帧推导+蹲走;跳跃触发处加"打断冲刺";水平速度段支持蹲走目标;垂直重力段×`charge_air_gravity_mult`;`move_and_slide` 后加撞墙停冲刺。
- **Create** `tests/move_feel_smoke.gd` / `.tscn` / `.sh` — 头less 冒烟断言:卡蹲修复、蹲速上限、跳打断、撞墙停、空中重力削减。
- **Modify** `CLAUDE.md` — 玩家小节补一句下蹲/冲刺语义(可选收尾)。

---

### Task 1: PlayerParams 常量 + player.gd 实例变量

**Files:**
- Modify: `core/player_params.gd:21-25`
- Modify: `scenes/player/player.gd:8-11`(charge 变量区)

**Interfaces:**
- Produces: `PlayerParams.charge_duration = 0.4`, `PlayerParams.crouch_walk_speed = 245`, `PlayerParams.charge_air_gravity_mult = 0.35`;`player.gd` 新增实例变量 `crouch_walk_speed`、`charge_air_gravity_mult`。

- [ ] **Step 1: 改 `PlayerParams` 冲刺/下蹲参数区**

`core/player_params.gd`,当前 21-25 行:
```gdscript
# ── 冲刺 ──
const charge_down_velocity: float = 2000.0
const charge_velocity: float = 1500.0
const charge_duration: float = 0.6
const charge_dir_window: float = 0.3  # 冲刺方向沿用最近移动方向的窗口(秒)
```
改为:
```gdscript
# ── 冲刺 ──
const charge_down_velocity: float = 2000.0
const charge_velocity: float = 1500.0
const charge_duration: float = 0.4    # 0.6→0.4(600px,保留长距离但可跳/墙打断)
const charge_air_gravity_mult: float = 0.35   # 空中冲刺重力倍率(<1=变平)
const charge_dir_window: float = 0.3  # 冲刺方向沿用最近移动方向的窗口(秒)
```

- [ ] **Step 2: 加下蹲参数(放在跳跃参数区之后、冲刺区之前)**

在 `core/player_params.gd` 的 `jump_cut_factor`(19 行)与 `# ── 冲刺 ──`(21 行)之间插入:
```gdscript
# ── 下蹲 ──
const crouch_walk_speed: float = 245.0   # 蹲走水平速度(≈0.35×move_speed)
```

- [ ] **Step 3: player.gd 头部加实例变量**

`scenes/player/player.gd` 8-11 行现在是:
```gdscript
var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity   # 冲刺速度
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间（秒）
var move_speed: float = PlayerParams.move_speed
```
在 `charge_duration` 行后追加一行 `charge_air_gravity_mult`,并把 `move_speed` 后追加 `crouch_walk_speed`:
```gdscript
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间（秒）
var charge_air_gravity_mult: float = PlayerParams.charge_air_gravity_mult  # 空中冲刺重力倍率
var move_speed: float = PlayerParams.move_speed
var crouch_walk_speed: float = PlayerParams.crouch_walk_speed  # 蹲走水平速度
```

- [ ] **Step 4: 验证能解析**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import`
Expected: 无 parse error,退出 0。

- [ ] **Step 5: Commit**

```bash
git add core/player_params.gd scenes/player/player.gd
git commit -m "feat: 下蹲/冲刺参数——冲刺 0.4s、蹲走 245、空中冲刺重力×0.35"
```

---

### Task 2: 下蹲改逐帧推导 + 蹲走(修"空中松开仍蹲")

**Files:**
- Modify: `scenes/player/player.gd:259-271`(下蹲段)
- Modify: `scenes/player/player.gd:282-304`(水平速度段)

**Interfaces:**
- Consumes: Task 1 的 `crouch_walk_speed` 实例变量。
- Produces: 每帧 `is_squat` 由"在地面 && 按住 down && 非 latched && 非 in_water"推导;蹲态水平目标 = `horizontal_input * crouch_walk_speed * mult.x`。

- [ ] **Step 1: 重写下蹲段(含空中下冲保留)**

`scenes/player/player.gd` 259-271 行现在:
```gdscript
	# ---------- 下蹲 ----------
	if not latched and not in_water:
		if is_on_floor():
			if input_source.is_action_just_pressed("down"):
				velocity.x = 0
				is_charge = false
				is_squat = true
			if input_source.is_action_just_released("down"):
				is_squat = false
		else:
			# 空中下冲:身在梯/链格上不能下冲(否则跳上去按↓可直接穿梯/链),只能抓住爬。
			if input_source.is_action_just_pressed("down") and not climb.is_over_climb_tile():
				velocity.y = charge_down_velocity
```
改为:
```gdscript
	# ---------- 下蹲 / 空中下冲 ----------
	if not latched and not in_water:
		# 空中按 S 下冲(不在梯/链格上)。
		if not is_on_floor() and input_source.is_action_just_pressed("down") \
				and not climb.is_over_climb_tile():
			velocity.y = charge_down_velocity
		# 下蹲 = 在地面 且 按住 S,逐帧推导——不用 just_pressed/just_released 边沿。
		# 旧实现 release 分支套在 if is_on_floor() 内:空中松开 S 不执行 → 落地仍蹲(卡蹲)。
		var want_squat := is_on_floor() and input_source.is_action_pressed("down")
		if want_squat and not is_squat:
			is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
		is_squat = want_squat
```

- [ ] **Step 2: 水平速度段支持蹲走**

`scenes/player/player.gd` 282-304 行现在(else 分支):
```gdscript
		else:
			var target_velocity_x = horizontal_input * move_speed * mult.x
			if horizontal_input != 0 and not is_squat:
				if is_on_floor():
					velocity.x = _approach(velocity.x, target_velocity_x, accel_ground, delta)
				else:
					velocity.x = _approach(velocity.x, target_velocity_x, accel_air, delta)
			else:
				if is_on_floor():
					velocity.x = _approach(velocity.x, 0.0, brake_ground, delta)
				else:
					velocity.x = _approach(velocity.x, 0.0, brake_air, delta)
				# 指数缓动逼近不到 0，接近 0 时直接吸附，避免贴地滑行
				if absf(velocity.x) < STOP_SNAP:
					velocity.x = 0.0
```
改为:
```gdscript
		else:
			# 蹲走:蹲态目标换成 crouch_walk_speed(可小步左右移动);非蹲态走 move_speed。
			var speed_target := crouch_walk_speed if is_squat else move_speed
			var target_velocity_x = horizontal_input * speed_target * mult.x
			if horizontal_input != 0:
				if is_on_floor():
					velocity.x = _approach(velocity.x, target_velocity_x, accel_ground, delta)
				else:
					velocity.x = _approach(velocity.x, target_velocity_x, accel_air, delta)
			else:
				if is_on_floor():
					velocity.x = _approach(velocity.x, 0.0, brake_ground, delta)
				else:
					velocity.x = _approach(velocity.x, 0.0, brake_air, delta)
				# 指数缓动逼近不到 0，接近 0 时直接吸附，避免贴地滑行
				if absf(velocity.x) < STOP_SNAP:
					velocity.x = 0.0
```

- [ ] **Step 3: 验证解析**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import`
Expected: 退出 0,无 parse error。

- [ ] **Step 4: Commit**

```bash
git add scenes/player/player.gd
git commit -m "fix: 下蹲改逐帧推导(空中松开不再卡蹲)+ 蹲走支持"
```

---

### Task 3: 冲刺——跳打断 / 撞墙停 / 空中重力 / 收尾平滑

**Files:**
- Modify: `scenes/player/player.gd:233-257`(垂直/跳跃段)
- Modify: `scenes/player/player.gd:282-290`(冲刺水平段收尾)
- Modify: `scenes/player/player.gd:351-356`(`move_and_slide` 后插撞墙停)

**Interfaces:**
- Consumes: Task 1 的 `charge_air_gravity_mult`。
- Produces: 跳跃触发时 `is_charge=false`(保留水平动量);撞到水平墙 → `is_charge=false` 且 `velocity.x=0`;空中冲刺垂直重力×`charge_air_gravity_mult`;冲刺自然结束时不再 `velocity.x -= charge*0.5` 突变。

- [ ] **Step 1: 垂直重力段×空中冲刺倍率**

`scenes/player/player.gd` 233-239 行现在:
```gdscript
	if not latched and not in_water:
		if is_on_floor():
			coyote_timer = coyote_time
		else:
			velocity.y += gravity * delta
			coyote_timer = maxf(coyote_timer - delta, 0.0)
```
改为:
```gdscript
	if not latched and not in_water:
		if is_on_floor():
			coyote_timer = coyote_time
		else:
			# 空中冲刺重力削减:冲刺那几帧重力×charge_air_gravity_mult(变平,可跨沟)。
			var grav_mult := charge_air_gravity_mult if is_charge else 1.0
			velocity.y += gravity * grav_mult * delta
			coyote_timer = maxf(coyote_timer - delta, 0.0)
```

- [ ] **Step 2: 跳跃触发处打断冲刺**

`scenes/player/player.gd` 247-252 行现在:
```gdscript
		# 触发跳跃：有缓冲输入且在地面或土狼窗口内
		if jump_buffer_timer > 0.0 and (is_on_floor() or coyote_timer > 0.0) and not is_squat:
			velocity.y = jump_velocity * mult.y
			jump_buffer_timer = 0.0
			coyote_timer = 0.0
			jump_cut_applied = false
```
改为:
```gdscript
		# 触发跳跃：有缓冲输入且在地面或土狼窗口内
		if jump_buffer_timer > 0.0 and (is_on_floor() or coyote_timer > 0.0) and not is_squat:
			# 冲刺中按跳 = 打断冲刺转跳跃,保留当前水平速度作动量(下方 accel/air-brake 平滑接管)。
			if is_charge:
				is_charge = false
				charge_timer = 0.0
			velocity.y = jump_velocity * mult.y
			jump_buffer_timer = 0.0
			coyote_timer = 0.0
			jump_cut_applied = false
```

- [ ] **Step 3: 冲刺自然结束改平滑(去掉 0.5 突变半刹)**

`scenes/player/player.gd` 284-289 行现在:
```gdscript
		if is_charge:
			velocity.x = charge_velocity * facing_direction
			charge_timer -= delta
			if charge_timer <= 0:
				is_charge = false
				velocity.x -= charge_velocity * facing_direction * 0.5
```
改为:
```gdscript
		if is_charge:
			velocity.x = charge_velocity * facing_direction
			charge_timer -= delta
			if charge_timer <= 0:
				is_charge = false
				# 收尾交回下方 accel/air-brake 平滑减速,不做 1500→750 突变半刹。
```

- [ ] **Step 4: move_and_slide 后加"撞水平墙 → 停冲刺"**

`scenes/player/player.gd` 355-358 行现在:
```gdscript
	# ---------- 执行移动 ----------
	move_and_slide()

	# ---------- 弹性瓦片（如树叶）:弱反弹 ----------
```
改为:
```gdscript
	# ---------- 执行移动 ----------
	move_and_slide()

	# ---------- 冲刺撞水平墙 → 立即结束(不再顶着墙冲满) ----------
	if is_charge:
		for i in range(get_slide_collision_count()):
			var col := get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				is_charge = false
				charge_timer = 0.0
				velocity.x = 0.0
				break

	# ---------- 弹性瓦片（如树叶）:弱反弹 ----------
```

- [ ] **Step 5: 验证解析**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import`
Expected: 退出 0。

- [ ] **Step 6: Commit**

```bash
git add scenes/player/player.gd
git commit -m "feat: 冲刺跳/墙可打断、空中重力×0.35、收尾平滑"
```

---

### Task 4: move_feel 冒烟(下蹲/冲刺行为回归)

**Files:**
- Create: `tests/move_feel_smoke.gd`
- Create: `tests/move_feel_smoke.tscn`
- Create: `tests/move_feel_smoke.sh`

**Interfaces:**
- Consumes: Task 1-3 的行为。
- Produces: `SMOKE_MOVE_FEEL OK`(退出 0)或 `SMOKE_MOVE_FEEL FAIL: ...`(退出 1)。

- [ ] **Step 1: 写 `tests/move_feel_smoke.gd`**

```gdscript
extends Node
# 下蹲/冲刺手感冒烟(scene 模式 headless):手动喂 NetworkInputSource 逐帧驱动单个 Player,
# 断言:
#  1) 卡蹲修复:空中松开 S 后落地不再蹲(is_squat=false)。
#  2) 蹲走:蹲态喂水平轴,速度收敛到 crouch_walk_speed 附近且远小于 move_speed。
#  3) 冲刺按跳打断:is_charge=false 且保留水平动量(velocity.x 仍大)。
#  4) 冲刺撞水平墙:is_charge 立即 false 且 velocity.x≈0。
#  5) 空中冲刺重力削减:空中冲刺单 tick 的 vy 增量 ≈ gravity*charge_air_gravity_mult*dt,
#     明显小于不冲刺时的 gravity*dt。
# 跑法:用户自跑(见 move_feel_smoke.sh / CLAUDE.md)。通过 = SMOKE_MOVE_FEEL OK。

const BIT_UP := NetworkInputSource.BIT_UP
const BIT_DOWN := NetworkInputSource.BIT_DOWN
const BIT_CHARGE := NetworkInputSource.BIT_CHARGE

const COLS := 40
const ROWS := 14
const TILE := 64
const WALL_X := 8            # 竖直墙列:测试冲刺撞墙停
const DT := 1.0 / 60.0
const WARMUP := 50           # 无输入落到地面

var p = null                 # Player(手动步进)
var src: NetworkInputSource = NetworkInputSource.new()
var _tick := 0
var _fail := ""

func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	var spawn := Vector2(2 * TILE + TILE * 0.5, 12 * TILE + TILE * 0.5)  # 贴地出生
	p = preload("res://scenes/player/Player.tscn").instantiate()
	p.name = "MoveFeel"
	p.set_input_source(src)
	host.add_child(p)
	p.global_position = spawn
	p.set_physics_process(false)
	print("[move_feel] 计划:卡蹲/蹲走/跳打断/撞墙停/空中重力")

func _build_grid() -> Array[Array]:
	var wall := 31
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			var v := 0
			if y == ROWS - 1:
				v = wall                       # 底行地面
			elif x == WALL_X and y < ROWS - 1:
				v = wall                       # 竖直墙列(0..12)
			row.append(v)
		grid.append(row)
	return grid

# 喂一帧:清边沿 → apply(held/pressed/released/ax)→ 手动步进
func _feed(held: int, pressed: int, released: int, ax: float) -> void:
	src.clear_edges()
	src.apply_packet({"seq": _tick, "ax": ax, "held": held,
		"pressed": pressed, "released": released, "weapon": 0, "aim": Vector2(1.0, 0.0)})
	p._physics_process(DT)
	_tick += 1

func _step_idle(n: int) -> void:
	for _i in range(n):
		_feed(0, 0, 0, 0.0)

func _reset() -> void:
	p.global_position = Vector2(2 * TILE + TILE * 0.5, 12 * TILE + TILE * 0.5)
	p.velocity = Vector2.ZERO
	p.is_charge = false
	p.is_squat = false
	p.charge_timer = 0.0
	_src_clear_all()
	_step_idle(3)   # 落到地面站稳

func _src_clear_all() -> void:
	src.clear_edges()
	src.reset_state()

func _physics_process(_delta: float) -> void:
	if p == null or not _fail.is_empty():
		return
	if _tick >= 4000:
		_finish()
		return
	# 依次执行各测试场景(每场景内部 _feed/_step 推进,全部走完即 PASS)
	match _tick:
		0:
			_reset()
			_test_crouch_air_release()
		1:
			_reset()
			_test_crouch_walk_speed()
		2:
			_reset()
			_test_dash_jump_cancel()
		3:
			_reset()
			_test_dash_wall_stop()
		4:
			_reset()
			_test_air_dash_gravity()
		5:
			_finish()

# 1) 卡蹲:空中松开 S 落地不再蹲。用"下蹲后把玩家抬到空中再松开 S"复现旧 bug 触发路径。
func _test_crouch_air_release() -> void:
	# 地面按住 S → 蹲
	for _i in range(6):
		_feed(BIT_DOWN, BIT_DOWN, 0, 0.0)
	if not p.is_squat:
		_fail_now("地面按住 S 未下蹲"); return
	# 抬到空中(等效击飞/下冲离地),仍按住 S:is_squat 应随离地清 false(逐帧推导)
	p.global_position.y -= 200.0
	p.velocity = Vector2.ZERO
	for _i in range(3):
		_feed(BIT_DOWN, 0, 0, 0.0)
	if p.is_squat:
		_fail_now("离地仍蹲(is_squat 未随地面条件清除)"); return
	# 空中松开 S(原 bug:release 分支套在 is_on_floor 内不执行 → 落地仍蹲)
	for _i in range(3):
		_feed(0, 0, BIT_DOWN, 0.0)
	# 落地(松开 S)
	for _i in range(30):
		_feed(0, 0, 0, 0.0)
	if p.is_on_floor() and p.is_squat:
		_fail_now("落地后仍蹲(卡蹲未修)"); return

# 2) 蹲走:蹲态喂左/右轴,速度收敛到 crouch_walk_speed 附近且 << move_speed。
func _test_crouch_walk_speed() -> void:
	for _i in range(6):
		_feed(BIT_DOWN, BIT_DOWN, 0, 0.0)
	if not p.is_squat:
		_fail_now("crouch_walk:未进入蹲态"); return
	# 朝远离墙的方向(左,墙在 x=8,出生 x=2 左边开阔)走
	for _i in range(40):
		_feed(BIT_DOWN, 0, 0, -1.0)
	var vx: float = absf(p.velocity.x)
	var expect := p.crouch_walk_speed
	if vx > expect * 1.3:
		_fail_now("蹲走速度超预期: %.1f > 245×1.3" % vx); return
	if vx < expect * 0.5:
		_fail_now("蹲走速度过小: %.1f < 245×0.5" % vx); return
	if vx > p.move_speed * 0.6:
		_fail_now("蹲走速度疑似用了 full move_speed: %.1f" % vx); return

# 3) 冲刺按跳打断:is_charge 清 false 且保留水平动量。
func _test_dash_jump_cancel() -> void:
	for _i in range(3):
		_feed(BIT_CHARGE, BIT_CHARGE, 0, 1.0)   # 面向右冲
	if not p.is_charge:
		_fail_now("未进入冲刺"); return
	for _i in range(5):
		_feed(BIT_CHARGE, 0, 0, 1.0)
	# 按跳打断
	_feed(BIT_UP | BIT_CHARGE, BIT_UP, 0, 1.0)
	if p.is_charge:
		_fail_now("按跳后仍 is_charge(未打断)"); return
	if p.velocity.y >= 0.0:
		_fail_now("按跳后未起跳 vy=%.1f" % p.velocity.y); return
	if absf(p.velocity.x) < 800.0:
		_fail_now("打断后水平动量丢失 vx=%.1f(<800)" % p.velocity.x); return

# 4) 冲刺撞水平墙停。出生在墙(WALL_X=8)左侧,向右冲,~0.22s 撞墙,应提前停。
func _test_dash_wall_stop() -> void:
	for _i in range(3):
		_feed(BIT_CHARGE, BIT_CHARGE, 0, 1.0)
	for _i in range(20):   # 20 tick ≈ 0.33s > 撞墙所需 ~0.22s,< 0.4s 冲满
		_feed(BIT_CHARGE, 0, 0, 1.0)
		if not p.is_charge and _tick < 200:
			break
	if p.is_charge:
		_fail_now("撞墙后仍在冲刺"); return
	if absf(p.velocity.x) > 50.0:
		_fail_now("撞墙停后 vx 未清: %.1f" % p.velocity.x); return
	if p.global_position.x > WALL_X * TILE + TILE * 0.5:
		_fail_now("穿墙: x=%.1f 超过墙列 %d" % [p.global_position.x, WALL_X]); return

# 5) 空中冲刺重力削减:在无地面、离地足够高处,比较"冲刺 vs 不冲刺"单 tick vy 增量。
func _test_air_dash_gravity() -> void:
	# 把玩家放到高空,给一个下落速度,不冲刺测一 tick 增量
	p.global_position = Vector2(2 * TILE + TILE * 0.5, 3 * TILE + TILE * 0.5)
	p.velocity = Vector2(0.0, 300.0)
	p.is_charge = false
	var vy0 := p.velocity.y
	_feed(0, 0, 0, 0.0)
	var dvy_normal := p.velocity.y - vy0
	# 复位,空中冲刺测一 tick 增量
	p.global_position = Vector2(2 * TILE + TILE * 0.5, 3 * TILE + TILE * 0.5)
	p.velocity = Vector2(0.0, 300.0)
	p.is_charge = false
	p.is_squat = false
	_feed(BIT_CHARGE, BIT_CHARGE, 0, 0.0)   # 进入空中冲刺(本帧起 is_charge)
	var vy1 := p.velocity.y
	_feed(BIT_CHARGE, 0, 0, 0.0)
	var dvy_charge := p.velocity.y - vy1
	if dvy_normal <= 0.0:
		_fail_now("空中无冲刺 vy 未增大(测试无效)"); return
	var ratio := dvy_charge / dvy_normal
	var mult := p.charge_air_gravity_mult
	if ratio > mult + 0.15 or ratio < mult - 0.15:
		_fail_now("空中冲刺重力倍率不符: 实测 %.2f 期望≈%.2f(±0.15)" % [ratio, mult]); return

func _fail_now(msg: String) -> void:
	_fail = msg

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_MOVE_FEEL FAIL: %s (tick=%d)" % [_fail, _tick])
		get_tree().quit(1)
		return
	print("SMOKE_MOVE_FEEL OK: 卡蹲/蹲走/跳打断/撞墙停/空中重力 全过(tick=%d)" % _tick)
	get_tree().quit(0)
```

- [ ] **Step 2: 写 `tests/move_feel_smoke.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/move_feel_smoke.gd" id="1"]

[node name="MoveFeelSmoke" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 写 `tests/move_feel_smoke.sh`**

```bash
#!/usr/bin/env bash
# 下蹲/冲刺手感冒烟。通过 = SMOKE_MOVE_FEEL OK 退出 0。用户自跑。
set -u
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
LOG="tests/move_feel_smoke.log"
"$GODOT" --headless --path . res://tests/move_feel_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_MOVE_FEEL OK" "$LOG"; then
  echo "[move_feel] PASS"
  exit 0
else
  echo "[move_feel] FAIL —— 见 $LOG"
  exit 1
fi
```

- [ ] **Step 4: 跑冒烟**

Run: `timeout 90 bash tests/move_feel_smoke.sh`
Expected: 首次运行若实现已含 Task 2/3,应直接 `SMOKE_MOVE_FEEL OK`;若任一步 FAIL,按其消息回到对应 Task 检查逻辑(常见:蹲速加速窗不够、撞墙 tick 数、空中重力复位后 is_on_floor 残留导致跳分支,需微调 `_reset` 或 `_test` 内的喂帧数——冒烟实现可调,不必改游戏逻辑;若改的是游戏逻辑则说明实现偏离 spec,先修实现)。

- [ ] **Step 5: Commit**

```bash
git add tests/move_feel_smoke.gd tests/move_feel_smoke.tscn tests/move_feel_smoke.sh
git commit -m "test: 下蹲/冲刺手感冒烟(卡蹲/蹲走/跳打断/撞墙停/空中重力)"
```

---

### Task 5: 回归 + 文档

**Files:**
- Modify: `CLAUDE.md`(玩家小节,补一句下蹲/冲刺语义)
- 回归:跑 4 个既有冒烟 + 新 move_feel

- [ ] **Step 1: 更新 CLAUDE.md 玩家小节**

在 `scenes/player/player.gd` 描述那一行的"下蹲"或"冲刺"处补一句(如原文有"下蹲/冲刺/镜头数值全在 PlayerParams"),在句内追加:
> 冲刺 0.4s 可被跳跃/撞墙打断、空中冲刺重力×0.35;下蹲为按住 S 逐帧推导(非边沿),可蹲走(crouch_walk_speed)。

- [ ] **Step 2: 跑全量回归**

Run(各 ~10-120s):
```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
bash tests/pvp_reconcile_smoke.sh
bash tests/pvp_twin_smoke.sh
bash tests/pvp_match_smoke.sh
bash tests/move_feel_smoke.sh
```
Expected: 各自打印 SMOKE OK / SMOKE_RECONCILE OK / SMOKE_TWIN OK / SMOKE PASS / SMOKE_MOVE_FEEL OK。任一失败停下排查(尤其 twin:若 capture/restore 需新增字段会报字段发散——本设计未加新状态字段,应不触发)。

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 玩家小节补下蹲/冲刺新语义"
```

---

## Self-Review

- **Spec coverage:** spec 的下蹲卡蹲修复→Task2;蹲走→Task2+Task1 参数;冲刺 0.4→Task1;跳打断/撞墙停/重力×0.35/收尾平滑→Task3;测试→Task4;CLAUDE.md→Task5。全部覆盖。
- **Placeholder scan:** 每步含完整代码/命令,无 TBD/TODO。
- **Type consistency:** 全程用 `is_squat`/`is_charge`/`charge_timer`/`crouch_walk_speed`/`charge_air_gravity_mult`,Task1 定义、Task2/3 消费、Task4 断言一致。
