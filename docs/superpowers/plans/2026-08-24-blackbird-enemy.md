# BlackBird 敌人实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增地面敌人「BlackBird」——睡眠→随机游走→瞬移到玩家面朝反方向的地面落点→带跳跃的冲锋打 6 伤→大后跳(命中/未命中都)→回游走→玩家远离入睡。

**Architecture:** `EnemyBlackBird extends EnemyBase`(同 JumpBird 模式,地面敌人,不用飞行寻路)。独立状态机 `enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }`,数值集中到 `EnemyParams.BlackBird` 嵌套类。场景 `EnemyBlackBird.tscn` 已存在(贴图/动画/碰撞体),需补脚本/scale/碰撞层/数值。注册到 `data/enemies.json`(与 HTML 编辑器共用)。

**Tech Stack:** Godot 4.7.1 标准版(GDScript)。唯一"测试"是 `Tests/enemy_logic_smoke.gd`(`extends SceneTree`, `-s` 跑,成功打印 `SMOKE OK`)。

## Global Constraints

- Godot 不在 PATH,冒烟命令用绝对路径:
  `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd`
- 冒烟测试约定 `-s` 阶段 autoload 未实例化:测试代码只用 `GameParameters.TILE_SIZE`(const),不静态引用 autoload 实例变量。
- 碰撞层:层1=地形、层2=玩家、层3=敌人(值4)。敌人 `collision_layer=4`、`collision_mask=7`。
- 敌人数值放 `EnemyParams` 嵌套类;战斗数值(hp/contact_damage/knockback_strength)由场景 @export 提供。
- 状态机模式:子类定义 `enum State` + `_set_state()`/`_state_timer`,覆写 `_ai(delta)`,动画直接 `_anim.play()`。
- 玩家伤害: `player.take_hit(source_pos, damage, ignore_iframes=false, knockback=-1)`;冲锋用 `ignore_iframes=true` 穿透无敌帧。
- 玩家朝向: `player.get_facing() -> int`(±1)。
- 环面:实体每帧 `_wrap()` 锚定玩家最近副本;格子坐标取模用 `posmod`。

---

### Task 1: 参数 + 脚本 + 场景补全

**Files:**
- Modify: `Globals/enemyParams.gd`(加 `class BlackBird`)
- Create: `Scenes/Enemies/enemy_black_bird.gd`
- Modify: `Scenes/Enemies/EnemyBlackBird.tscn`(补脚本/scale/碰撞层/数值)

**Interfaces:**
- Produces: `EnemyBlackBird`(class_name)、`EnemyParams.BlackBird`(嵌套类,常量见下)、`EnemyBlackBird.tscn`(可实例化,`state==0` 初始休眠)。
- Later tasks 依赖: 冒烟测试 `load("res://scenes/enemies/EnemyBlackBird.tscn")` 后 `instantiate()`; `EnemySpawner.TYPES` 经 enemies.json 注册( Task 2 )。

- [ ] **Step 1: 加 EnemyParams.BlackBird**

在 `Globals/enemyParams.gd` 的 `class JumpBird:` 之后、文件末尾前插入:

```gdscript
class BlackBird:
	const wake_radius: float = 950.0     # 玩家多近苏醒
	const sleep_radius: float = 1200.0   # 玩家多远入睡(离开范围)
	const wander_speed: float = 240.0    # 随机游走速度
	const wander_min_t: float = 0.7      # 换向间隔下限(秒)
	const wander_max_t: float = 1.8      # 换向间隔上限(秒)
	const flank_check_interval: float = 1.6  # 游走中瞬移判定周期(秒)
	const flank_distance: float = 400.0  # 玩家后方目标距离(px)
	const flank_search_cells: int = 4    # 理想落点周围搜索半径(格;比 spec 的 3 略大,容错地形)
	const teleport_drop: float = 60.0    # 瞬移到落点上方高度(px),再下落
	const landing_timeout: float = 0.6   # 落地兜底(秒)
	const charge_speed: float = 1100.0   # 冲锋水平速度
	const charge_damage: int = 6         # 冲锋伤害(穿透无敌帧)
	const charge_timeout: float = 1.2    # 冲锋超时 → 未命中大后跳
	const charge_jump_velocity: float = -650.0  # 遇墙自动跳初速
	const back_hop_up: float = -720.0    # 大后跳高度
	const back_hop_away: float = 460.0   # 大后跳距离
	const death_flash_time: float = 0.5  # 死亡白闪时长(秒),闪完销毁
```

- [ ] **Step 2: 写 enemy_black_bird.gd**

创建 `Scenes/Enemies/enemy_black_bird.gd`:

```gdscript
class_name EnemyBlackBird
extends EnemyBase

# 绕背瞬移刺客:睡眠 → 随机游走 → 周期性判定「玩家面朝反方向」的地板格落点(LOS 通)
# → 起飞动作 → 瞬移落地 → 带跳跃的地面冲锋打 6 伤 → 大后跳(命中/未命中都) → 回游走。
# 地面敌人(同 JumpBird 模式),全程受重力,不用飞行寻路。

enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }

var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _wander_timer: float = 0.0       # 下次随机换向剩余
var _wander_dir: float = 1.0         # 游走方向(±1)
var _flank_check_timer: float = 0.0  # 瞬移判定周期剩余
var _flank_cell: Vector2i = Vector2i(-1, -1)  # 选定落点格
var _landing_timer: float = 0.0      # 瞬移后落地兜底
var _charge_timer: float = 0.0       # 冲锋超时
var _back_hop_cd: float = 0.0        # 后跳落地冷却
var _death_timer: float = -1.0       # 死亡白闪剩余;<0 表示未死亡


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	_set_state(State.SLEEP)
	_anim.play("sleep")
	_align_contact_area()


# 接触范围与身体对齐:黑鸟碰撞箱按 scale 2.5 世界约 100px,ContactArea 由 EnemyBase
# 代码创建(不在场景里),这里把形状放大并下移对齐身体中心。
func _align_contact_area() -> void:
	var area := get_node_or_null("ContactArea") as Area2D
	if area != null:
		for child in area.get_children():
			if child is CollisionShape2D:
				var area_shape := RectangleShape2D.new()
				area_shape.size = Vector2(46, 36)
				child.shape = area_shape
				child.position = Vector2(4, 4)
				break


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_timer > 0.0:
				_wake_timer -= delta
				if _wake_timer <= 0.0:
					_set_state(State.WAKE)
			elif _sleep_anim_timer > 0.0:
				_sleep_anim_timer -= delta
				if _sleep_anim_timer <= 0.0:
					_anim.play("sleep")
			else:
				_anim.play("sleep")
				if dist <= EnemyParams.BlackBird.wake_radius:
					_anim.play("wake_up")
					_wake_timer = _anim_duration("wake_up")
		State.WAKE:
			if _wake_timer > 0.0:
				_wake_timer -= delta
			if _wake_timer <= 0.0:
				_set_state(State.WANDER)
				_wander_timer = 0.2
				_flank_check_timer = 0.5  # 先游走一会再判定瞬移,避免一醒就闪
		State.WANDER:
			_anim.play("run")
			if dist > EnemyParams.BlackBird.sleep_radius:
				_set_state(State.SLEEP)
				_anim.play("fall_asleep")
				_sleep_anim_timer = _anim_duration("fall_asleep")
				velocity.x = 0.0
				return
			_wander_timer -= delta
			if _wander_timer <= 0.0:
				_wander_timer = randf_range(EnemyParams.BlackBird.wander_min_t, EnemyParams.BlackBird.wander_max_t)
				_wander_dir = 1.0 if randf() < 0.5 else -1.0
			velocity.x = _wander_dir * EnemyParams.BlackBird.wander_speed
			_flank_check_timer -= delta
			if _flank_check_timer <= 0.0:
				_flank_check_timer = EnemyParams.BlackBird.flank_check_interval
				if _find_flank_cell():
					velocity.x = 0.0
					_set_state(State.TAKE_OFF)
					_anim.play("take_off")
					_state_timer = _anim_duration("take_off")
		State.TAKE_OFF:
			_state_timer -= delta
			if _state_timer <= 0.0:
				if _flank_cell == Vector2i(-1, -1):
					_set_state(State.WANDER)  # 兜底:无落点不该进 TAKE_OFF
					return
				_teleport_to_flank()
				_set_state(State.CHARGE)
				_charge_timer = EnemyParams.BlackBird.charge_timeout
				_landing_timer = EnemyParams.BlackBird.landing_timeout
				_anim.play("run")
		State.CHARGE:
			_anim.play("run")
			# 瞬移后先落地(只受重力),落地或兜底后才开始水平冲锋
			if _landing_timer > 0.0:
				_landing_timer -= delta
				if is_on_floor() or _landing_timer <= 0.0:
					_landing_timer = 0.0
				else:
					velocity.x = 0.0
					return
			if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
				_on_charge_hit_player()
				return
			_charge_timer -= delta
			if _charge_timer <= 0.0:
				_start_back_hop()
				return
			var dir := toroidal_dir_to_player()
			velocity.x = dir.x * EnemyParams.BlackBird.charge_speed
			if is_on_wall():
				velocity.y = EnemyParams.BlackBird.charge_jump_velocity
		State.BACK_HOP:
			if is_on_floor() and _back_hop_cd <= 0.0:
				_set_state(State.WANDER)
				_wander_timer = 0.2
				_flank_check_timer = EnemyParams.BlackBird.flank_check_interval


# 游走中瞬移判定:在「玩家面朝反方向 × flank_distance」的理想格周围按距离递增(环面
# 取模)搜地板格(EMPTY 且正下方 SOLID),且该格到玩家格 LOS 通 → 可瞬移冲锋。
func _find_flank_cell() -> bool:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	var grid := MazeGenerator.current_grid
	if p == null or grid.is_empty():
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var ts := GameParameters.TILE_SIZE
	var facing := _player_facing()
	var player_cell := MazeGenerator.cell_of(p.global_position, ts, cols, rows)
	var dist_cells := int(EnemyParams.BlackBird.flank_distance / ts)
	var ideal := Vector2i(player_cell.x - facing * dist_cells, player_cell.y)
	var search := EnemyParams.BlackBird.flank_search_cells
	for radius in range(0, search + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue
				var c := Vector2i(posmod(ideal.x + dx, cols), posmod(ideal.y + dy, rows))
				if _is_floor_cell(c) and MazeGenerator.has_line_of_sight(c, player_cell):
					_flank_cell = c
					return true
	return false


func _is_floor_cell(c: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return grid[c.y][c.x] == MazeGenerator.EMPTY and grid[posmod(c.y + 1, grid.size())][c.x] == MazeGenerator.SOLID


func _teleport_to_flank() -> void:
	var ts := GameParameters.TILE_SIZE
	global_position = Vector2(_flank_cell.x * ts + ts * 0.5,
			_flank_cell.y * ts + ts * 0.5 - EnemyParams.BlackBird.teleport_drop)
	velocity = Vector2.ZERO
	_flank_cell = Vector2i(-1, -1)
	_wrap()  # 锚定到玩家最近副本(环面)


func _player_facing() -> int:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("get_facing"):
		return p.get_facing()
	return 1


func _update_facing() -> void:
	if absf(velocity.x) > 5.0:
		_anim.flip_h = velocity.x < 0.0


# 冲锋命中玩家:穿透无敌帧打 6 伤,随后大后跳。
func _on_charge_hit_player() -> void:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit"):
		p.take_hit(global_position, EnemyParams.BlackBird.charge_damage, true)
	_start_back_hop()


func _start_back_hop() -> void:
	_set_state(State.BACK_HOP)
	_anim.play("jump_backward")
	var away := toroidal_dir_to_player()
	velocity = Vector2(-away.x * EnemyParams.BlackBird.back_hop_away, EnemyParams.BlackBird.back_hop_up)
	_back_hop_cd = 0.35


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		is_dead = true
		died.emit()
		_death_timer = EnemyParams.BlackBird.death_flash_time


func _physics_process(delta: float) -> void:
	if is_dead:
		_death_timer -= delta
		if _death_timer <= 0.0:
			queue_free()
			return
		# 白闪闪烁,物理与生前一致(走 super 统一路径)
		modulate = Color(3.0, 3.0, 3.0, 1.0) if int(_death_timer * 20.0) % 2 == 0 else Color(1.0, 1.0, 1.0, 0.35)
		super._physics_process(delta)
		return
	super._physics_process(delta)
```

- [ ] **Step 3: 补全 EnemyBlackBird.tscn**

`Scenes/Enemies/EnemyBlackBird.tscn` 顶部 `[ext_resource ...]` 块(第 3 行后)加脚本引用:

```
[ext_resource type="Script" path="res://scenes/enemies/enemy_black_bird.gd" id="1_bb"]
```

根节点(第 220 行 `[node name="EnemyBlackBird" ...]`)补:

```
scale = Vector2(2.5, 2.5)
collision_layer = 4
collision_mask = 7
script = ExtResource("1_bb")
hp = 30
contact_damage = 0
knockback_strength = 200.0
```

`AnimatedSprite2D` 默认动画 `animation = &"run"` 改成 `&"sleep"`(睡眠常态,脚本 _ready 也强制)。

- [ ] **Step 4: 验证无回归**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | tail -3`
Expected: 末尾 `SMOKE OK`(现有测试不受影响;脚本编译错误会在 import 时报出)。

- [ ] **Step 5: 提交**

```bash
git add Globals/enemyParams.gd Scenes/Enemies/enemy_black_bird.gd Scenes/Enemies/EnemyBlackBird.tscn
git commit -m "feat: BlackBird 敌人(参数/脚本/场景)"
```

---

### Task 2: 注册 + 地图出生点

**Files:**
- Modify: `data/enemies.json`
- Modify: `editor/structure-editor.html`
- Modify: `map/demo.txt`

**Interfaces:**
- Produces: `EnemySpawner.TYPES`(由 `res://data/enemies.json` 加载)含 `black_bird` → EnemyBlackBird.tscn;地图含 3 个 `black_bird` 出生点。
- Later tasks 依赖: Task 3 冒烟测试断言 `EnemySpawner.TYPES.has("black_bird")`。

- [ ] **Step 1: enemies.json 注册**

`data/enemies.json` 的 `"enemies"` 数组加一行:

```json
    { "id": "black_bird", "name": "BlackBird", "scene": "res://scenes/enemies/EnemyBlackBird.tscn", "color": "#8a8f98" },
```

- [ ] **Step 2: 编辑器 HTML 注册**

`editor/structure-editor.html` 的 `window.ENEMY_REGISTRY = [...]`(约 218-232 行)数组里,`fly_bird` 项后加:

```js
  {
    "id": "black_bird",
    "name": "BlackBird",
    "scene": "res://scenes/enemies/EnemyBlackBird.tscn",
    "color": "#8a8f98"
  }
```

- [ ] **Step 3: demo.txt 加出生点**

在 `map/demo.txt` 的注释块末尾(最后一个 `# enemy` 行之后)加 3 行(坐标已验为地板格:EMPTY 且正下方 SOLID):

```
# enemy black_bird 150 35
# enemy black_bird 243 60
# enemy black_bird 239 116
```

- [ ] **Step 4: 验证**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | tail -3`
Expected: `SMOKE OK`(spawner 的 TYPES 测试断言 `size()==2` 会 FAIL——Task 3 一并改,本任务先不管该 FAIL 之外的回归)。

- [ ] **Step 5: 提交**

```bash
git add data/enemies.json editor/structure-editor.html map/demo.txt
git commit -m "feat: BlackBird 注册进编辑器与地图"
```

---

### Task 3: 冒烟测试

**Files:**
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Consumes: Task 1 的 `EnemyBlackBird`/`EnemyParams.BlackBird`、Task 2 的 `EnemySpawner.TYPES["black_bird"]`。
- Produces: 黑鸟全行为覆盖的断言;`SMOKE OK` 全绿。

- [ ] **Step 1: 插入 BlackBird 测试块**

在 `Tests/enemy_logic_smoke.gd` 的 `# ── Task: 地图 spawn 元数据解析 ──`(约 844 行)之前插入:

```gdscript
	# ── Task: BlackBird(绕背瞬移刺客)──
	var bk_grid: Array[Array] = []
	for _y in range(60):
		var row_bk: Array[int] = []
		row_bk.resize(120)
		row_bk.fill(MazeGenerator.EMPTY)
		bk_grid.append(row_bk)
	for _x in range(120):
		bk_grid[58][_x] = MazeGenerator.SOLID  # 地板
	MazeGenerator.current_grid = bk_grid
	var bk_scene: PackedScene = load("res://scenes/enemies/EnemyBlackBird.tscn")
	_check(bk_scene != null, "BlackBird 场景加载")
	var bk = bk_scene.instantiate()
	bk.global_position = Vector2(60, 57 * 32 + 16)  # 地板格(row57, 下方 row58 实心)
	root.add_child(bk)
	await physics_frame
	_check(bk.get_script() == load("res://scenes/enemies/enemy_black_bird.gd"), "BlackBird 实例类型")
	_check(bk.state == 0, "BlackBird 初始休眠")
	_check(bk.hp == 30, "BlackBird hp=30")
	_check(bk.contact_damage == 0, "BlackBird 无接触伤害")
	_check(bk.collision_layer == 4, "BlackBird 占层3")
	_check(is_equal_approx(bk.scale.x, 2.5), "BlackBird scale=2.5")
	# 玩家远处 → 保持睡眠
	var bk_far := StubCombatPlayer.new()
	bk_far.global_position = Vector2(60, 200)
	root.add_child(bk_far)
	for _i in range(20):
		await physics_frame
	_check(bk.state == 0, "黑鸟玩家远处保持睡眠")
	bk_far.free()
	# 玩家接近 → 苏醒 → 游走(验证游走速度,再等瞬移判定)
	var bk_player := StubCombatPlayer.new()
	bk_player.global_position = Vector2(400, 57 * 32 + 16)
	root.add_child(bk_player)
	var reached_wander := false
	var wander_vx := 0.0
	for _i in range(120):
		await physics_frame
		if bk.state == 2:  # WANDER
			reached_wander = true
			wander_vx = bk.velocity.x
			break
	_check(reached_wander, "黑鸟进入游走")
	_check(absf(wander_vx) == EnemyParams.BlackBird.wander_speed, "黑鸟游走速度")
	# 瞬移判定成功 → 起飞 → 落地 → 冲锋命中 6 伤(穿透无敌帧)
	var reached_takeoff := false
	var got_hit := false
	for _i in range(240):
		await physics_frame
		if bk.state == 3:  # TAKE_OFF
			reached_takeoff = true
		if bk_player.hit_log.has(6):
			got_hit = true
			break
	_check(reached_takeoff, "黑鸟进入起飞动作")
	_check(got_hit, "黑鸟冲锋命中玩家 6 伤")
	_check(bk.state == 5, "黑鸟命中后大后跳")  # BACK_HOP
	# 后跳落地 → 回游走
	var wandered_again := false
	for _i in range(240):
		await physics_frame
		if bk.state == 2:
			wandered_again = true
			break
	_check(wandered_again, "黑鸟后跳落地回游走")
	# 玩家远离 → 入睡
	bk_player.global_position = Vector2(60, 3500)
	var slept := false
	for _i in range(240):
		await physics_frame
		if bk.state == 0:
			slept = true
			break
	_check(slept, "黑鸟玩家远离入睡")
	bk_player.free()
	bk.free()
	# 死亡:白闪闪烁后销毁,物理与生前一致
	var bk_dead = bk_scene.instantiate()
	bk_dead.global_position = Vector2(300, 57 * 32 + 16)
	root.add_child(bk_dead)
	await physics_frame
	bk_dead.hurt(99, Vector2.RIGHT)
	_check(bk_dead.is_dead, "黑鸟受击死亡")
	var died := false
	for _i in range(180):
		await physics_frame
		if not is_instance_valid(bk_dead):
			died = true
			break
	_check(died, "黑鸟死亡白闪后销毁")
	# 落点判定反例:理想落点区被整列墙堵死(无地板 + LOS 被挡) → 不瞬移,仍游走
	var bk2_grid: Array[Array] = []
	for _y in range(60):
		var row2_bk: Array[int] = []
		row2_bk.resize(120)
		row2_bk.fill(MazeGenerator.EMPTY)
		bk2_grid.append(row2_bk)
	for _x in range(120):
		bk2_grid[58][_x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = bk2_grid
	var bk2 = bk_scene.instantiate()
	bk2.global_position = Vector2(60 * 32 + 16, 57 * 32 + 16)
	root.add_child(bk2)
	await physics_frame
	var bk2_player := StubCombatPlayer.new()
	bk2_player.global_position = Vector2(60 * 32 + 16, 57 * 32 + 16)
	root.add_child(bk2_player)
	# 玩家面朝右(默认 facing=1),理想落点 = 玩家格 − 12 列 = 列 48;把列 44..52 整列墙堵死
	var wall_c0 := posmod(60 - int(EnemyParams.BlackBird.flank_distance / 32) - 4, 120)
	for _c in range(wall_c0, wall_c0 + 9):
		for _y in range(58):
			bk2_grid[_y][posmod(_c, 120)] = MazeGenerator.SOLID
	MazeGenerator.current_grid = bk2_grid
	var flanked := false
	for _i in range(240):
		await physics_frame
		if bk2.state == 3:  # TAKE_OFF
			flanked = true
			break
	_check(not flanked, "黑鸟背墙不瞬移(仍游走)")
	# 拆墙 → 应能瞬移
	for _c in range(wall_c0, wall_c0 + 9):
		for _y in range(58):
			bk2_grid[_y][posmod(_c, 120)] = MazeGenerator.EMPTY
	MazeGenerator.current_grid = bk2_grid
	var flanked2 := false
	for _i in range(240):
		await physics_frame
		if bk2.state == 3:
			flanked2 = true
			break
	_check(flanked2, "黑鸟拆墙后可瞬移")
	bk2_player.free()
	bk2.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 2: 更新 spawner TYPES 断言**

把 862-865 行的 spawner 断言(当前 `size() == 2`)改为:

```gdscript
	# ── Task: EnemySpawner.TYPES 从 enemies.json 加载 ──
	EnemySpawner.load_types()
	_check(EnemySpawner.TYPES.has("jump_bird") and EnemySpawner.TYPES.has("fly_bird")
			and EnemySpawner.TYPES.has("black_bird") and EnemySpawner.TYPES.size() == 3,
			"EnemySpawner.TYPES 从 enemies.json 加载(含 black_bird)")
```

- [ ] **Step 3: 跑冒烟测试直到 SMOKE OK**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | tail -40`
Expected: 末尾 `SMOKE OK`,黑鸟相关断言全 `ok`。若有 FAIL,按输出修正脚本/测试(常见:瞬移判定时序、冲锋命中窗口、后跳落地判定)。

- [ ] **Step 4: 提交**

```bash
git add Tests/enemy_logic_smoke.gd
git commit -m "test: BlackBird 冒烟测试(游走/瞬移/冲锋/后跳/入睡/死亡)"
```

---

### Task 4: CLAUDE.md + 最终验证

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 敌人列表补 BlackBird**

在 `CLAUDE.md` 敌人章节(约 48 行 `EnemyJumpBird` 之后)加一行:

```
- `EnemyBlackBird`:绕背瞬移刺客(睡眠→随机游走→瞬移到玩家面朝反方向的地板落点→带跳跃冲锋打 6 伤→大后跳→回游走);落点判定 = 地板格 + LOS;死亡白闪后销毁。
```

- [ ] **Step 2: 最终验证**

Run 冒烟:`... --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | tail -3` → `SMOKE OK`
Run 启动:`... --headless --path . --quit-after 90 2>&1 | grep -iE "error|SCRIPT ERROR"` → 无输出。

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 敌人列表补 BlackBird"
```

- [ ] **Step 4: 交用户 playtest**

请用户跑游戏,重点:瞬移落点是否总在玩家背后、冲锋速度/自动跳手感、大后跳幅度、游走节奏、3 个 black_bird 出生点分布。
