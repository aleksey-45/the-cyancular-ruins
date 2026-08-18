# FlyBird 敌人实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 FlyBird 飞行敌人(睡眠/起飞/走廊寻路/斜上抛弹/低血冲撞/返程),新增敌方抛物线子弹,并重构碰撞层让敌我子弹命中目标分离。

**Architecture:** FlyBird 为 `EnemyBase` 子类,`_ai(delta)` 状态机(与 EnemyJumpBird 同风格),参数集中于 `EnemyParams.FlyBird`。寻路用 `MazeGenerator.bfs_path`(环面网格 BFS),投弹用新 `EnemyBullet extends BulletBase`(复用 `gravity_factor` 预留字段)。碰撞层:敌人占层 3、玩家层 2、地形层 1,敌我子弹用不同 mask。

**Tech Stack:** Godot 4.4+ GDScript,SceneTree 冒烟测试脚本。

## Global Constraints

- **禁止运行测试**:项目约定测试由用户本人运行(见记忆 `user-runs-tests-themselves`)。实现者绝不执行冒烟测试命令;每个任务完成后,请用户运行并确认。
- 冒烟测试命令(用户执行):
  `"D:\Program Files\Godot_v4.4.1-stable_mono_win64\Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd`
  期望输出含 `SMOKE OK`(任何 `FAIL` 都要反馈并修复后重跑)。
- 代码注释用中文,与现有 `enemy_jump_bird.gd` 风格一致(`EnemyParams.X.xxx` 全名引用,不用别名)。
- 新 `.gd` 文件的 `.uid` 由 Godot 首次打开编辑器时自动生成;`.tscn` 对脚本用**路径引用**(不写 uid),headless 冒烟可立即加载。
- 每任务独立可验证、单独提交。
- 沿用 spec:`docs/superpowers/specs/2026-08-18-flybird-enemy-design.md`。

---

### Task 1: 碰撞层重构(敌人 → 层3)

**Files:**
- Modify: `Scenes/Enemies/EnemyJumpBird.tscn`
- Modify: `Scenes/Player.tscn`
- Modify: `Scenes/Weapons/bullet.tscn`
- Modify: `Tests/enemy_logic_smoke.gd`(注释 + 新增校验段)

**Interfaces:**
- Produces: 敌人占碰撞层 3、玩家占层 2、地形占层 1;玩家子弹 mask=5(层1+层3)、玩家 mask=5;为 Task 3 的敌方子弹 mask=3(层1+层2)铺路。

- [ ] **Step 1: 改 `EnemyJumpBird.tscn` 根节点 `collision_layer`**

`Scenes/Enemies/EnemyJumpBird.tscn` 根节点:

```tscn
[node name="EnemyJumpBird" type="CharacterBody2D"]
scale = Vector2(2.5, 2.5)
collision_layer = 2
collision_mask = 3
```
改为:
```tscn
[node name="EnemyJumpBird" type="CharacterBody2D"]
scale = Vector2(2.5, 2.5)
collision_layer = 3
collision_mask = 3
```

- [ ] **Step 2: 改 `Player.tscn` 根节点 `collision_mask`**

`Scenes/Player.tscn` 根节点:

```tscn
[node name="Player" type="CharacterBody2D" node_paths=PackedStringArray("animator", "weapon_slot")]
collision_layer = 2
collision_mask = 3
```
改为:
```tscn
[node name="Player" type="CharacterBody2D" node_paths=PackedStringArray("animator", "weapon_slot")]
collision_layer = 2
collision_mask = 5
```

- [ ] **Step 3: 改 `bullet.tscn` 根节点 `collision_mask`**

`Scenes/Weapons/bullet.tscn` 根节点:

```tscn
[node name="Bullet" type="CharacterBody2D"]
collision_layer = 0
collision_mask = 3
motion_mode = 1
```
改为:
```tscn
[node name="Bullet" type="CharacterBody2D"]
collision_layer = 0
collision_mask = 5
motion_mode = 1
```

- [ ] **Step 4: 更新冒烟测试过时注释**

`Tests/enemy_logic_smoke.gd` 第 60 行注释 `# 清掉 Task 4 遗留的敌人(在原点,碰撞层2);否则子弹出生即命中并立即消失` 中 `碰撞层2` 改为 `碰撞层3`。

- [ ] **Step 5: 给冒烟测试加 StubCombatPlayer 类 + 层校验段**

在 `Tests/enemy_logic_smoke.gd` 顶部 `class StubPlayer:` 之后、`var _failures` 之前插入:

```gdscript
# 带碰撞体的战斗桩玩家:入 player 组、占层2,记录 take_hit 伤害。
class StubCombatPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(40, 40)
		shape.shape = rect
		add_child(shape)
	func take_hit(_source_pos: Vector2, damage: int) -> void:
		hit_log.append(damage)
	func is_downed() -> bool:
		return false
```

在 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 1: 碰撞层重构(敌人层3, 玩家子弹不打玩家)──
	var jump2: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	var e2 := jump2.instantiate()
	root.add_child(e2)
	_check(e2.collision_layer == 3, "敌人占用层3")
	e2.free()
	var bm := bscene.instantiate()
	_check(bm.collision_mask == 5, "玩家子弹 mask=5(地形+敌人)")
	bm.free()
	var pc2 := player_scene.instantiate()
	root.add_child(pc2)
	await physics_frame
	_check(pc2.collision_mask == 5, "玩家 mask=5(地形+敌人)")
	pc2.free()
	# 玩家子弹穿过玩家身体(不再打自己)
	var combat := StubCombatPlayer.new()
	combat.global_position = Vector2(600, 400)
	root.add_child(combat)
	var pb := bscene.instantiate()
	root.add_child(pb)
	pb.setup(Vector2.RIGHT, 1000.0, 800.0, 1.0, Color.WHITE, null)
	pb.global_position = Vector2(400, 400)
	for i in range(15):
		await physics_frame
		if not is_instance_valid(pb):
			break
	_check(is_instance_valid(pb) and pb.global_position.x > 600.0, "玩家子弹穿过玩家不触发")
	_check(combat.hit_log.is_empty(), "玩家未被自己子弹命中")
	combat.free()
```

- [ ] **Step 6: 请用户运行冒烟测试并确认通过**(见 Global Constraints),然后提交:

```bash
git add Scenes/Enemies/EnemyJumpBird.tscn Scenes/Player.tscn Scenes/Weapons/bullet.tscn Tests/enemy_logic_smoke.gd
git commit -m "refactor: 碰撞层分离(敌人层3), 玩家/子弹 mask 3→5"
```

---

### Task 2: MazeGenerator 环面 BFS + LOS + current_grid

**Files:**
- Modify: `Globals/maze_generator.gd`
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Produces:
  - `MazeGenerator.current_grid: Array[Array]`(静态变量,`level_0` 赋值;空 = 无路)
  - `MazeGenerator.cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i`(像素→环面格)
  - `MazeGenerator.bfs_path(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 8000) -> Array[Vector2i]`(路径不含起点含终点;无路/超预算返回空)
  - `MazeGenerator.has_line_of_sight(from_cell: Vector2i, to_cell: Vector2i) -> bool`

- [ ] **Step 1: 在 `maze_generator.gd` 追加静态网格与寻路方法**

在 `Globals/maze_generator.gd` 文件末尾(第 107 行 `return grid` 之后)追加:

```gdscript


# 当前关卡网格(level_0._ready 赋值;空网格时寻路一律视为无路)。
static var current_grid: Array[Array] = []


# 像素坐标 → 环面格子坐标(取模回 [0,cols)×[0,rows))。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# 环面 4 邻居 BFS:返回从 from_cell 到 to_cell 的格序列(不含起点,含终点)。
# 只走 EMPTY 格;限量访问 max_visit,超限视为无路。同格/无路返回空数组。
static func bfs_path(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 8000) -> Array[Vector2i]:
	var grid := current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols := grid[0].size()
	if from_cell == to_cell:
		return []
	var visited := {from_cell: true}
	var prev := {}
	var queue: Array[Vector2i] = [from_cell]
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		if visited.size() > max_visit:
			return []
		for n in _neighbors4(cur, cols, rows):
			if visited.has(n) or grid[n.y][n.x] == SOLID:
				continue
			visited[n] = true
			prev[n] = cur
			if n == to_cell:
				return _rebuild_path(prev, from_cell, to_cell)
			queue.append(n)
	return []


static func _neighbors4(c: Vector2i, cols: int, rows: int) -> Array[Vector2i]:
	return [
		Vector2i((c.x + 1) % cols, c.y),
		Vector2i((c.x - 1 + cols) % cols, c.y),
		Vector2i(c.x, (c.y + 1) % rows),
		Vector2i(c.x, (c.y - 1 + rows) % rows),
	]


static func _rebuild_path(prev: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var cur := goal
	while cur != start:
		path.push_front(cur)
		cur = prev[cur]
	return path


# 环面网格 LOS:按两格最短方向逐格步进,途中任一 SOLID 即阻断。
static func has_line_of_sight(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var grid := current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := grid[0].size()
	var d := _toroidal_step(from_cell, to_cell, cols, rows)
	if d == Vector2i.ZERO:
		return true
	var cur := from_cell
	var steps := maxi(absi(d.x), absi(d.y))
	for i in range(1, steps + 1):
		var nx := posmod(cur.x + signi(d.x), cols) if d.x != 0 else cur.x
		var ny := posmod(cur.y + signi(d.y), rows) if d.y != 0 else cur.y
		cur = Vector2i(nx, ny)
		if grid[cur.y][cur.x] == SOLID:
			return false
		if cur == to_cell:
			break
	return true


static func _toroidal_step(a: Vector2i, b: Vector2i, cols: int, rows: int) -> Vector2i:
	var dx := b.x - a.x
	if dx > cols / 2:
		dx -= cols
	elif dx < -cols / 2:
		dx += cols
	var dy := b.y - a.y
	if dy > rows / 2:
		dy -= rows
	elif dy < -rows / 2:
		dy += rows
	return Vector2i(dx, dy)
```

- [ ] **Step 2: 冒烟测试加 BFS/LOS 校验段**

在 `Tests/enemy_logic_smoke.gd` 的 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 2: MazeGenerator BFS + LOS ──
	var g: Array[Array] = []
	for _y in range(20):
		var row: Array[int] = []
		row.resize(20)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	MazeGenerator.current_grid = g
	var pth := MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(5, 6))
	_check(not pth.is_empty() and pth[-1] == Vector2i(5, 6), "BFS 全通网格有路")
	_check(pth[0] != Vector2i(2, 2), "BFS 路径不含起点")
	_check(MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(2, 2)).is_empty(), "BFS 同格返回空")
	g[4][2] = MazeGenerator.SOLID
	g[4][3] = MazeGenerator.SOLID
	g[4][4] = MazeGenerator.SOLID
	_check(MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(2, 6)).is_empty(), "BFS 墙隔断无路")
	_check(MazeGenerator.bfs_path(Vector2i(2, 6), Vector2i(2, 2)).is_empty(), "BFS 反向也无路")
	_check(MazeGenerator.bfs_path(Vector2i(0, 0), Vector2i(15, 15), 8).is_empty(), "BFS 超预算无路")
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(5, 0)), "LOS 直线通视")
	var g2: Array[Array] = []
	for _y in range(20):
		var row2: Array[int] = []
		row2.resize(20)
		row2.fill(MazeGenerator.EMPTY)
		g2.append(row2)
	for x in range(1, 6):
		g2[2][x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = g2
	_check(not MazeGenerator.has_line_of_sight(Vector2i(0, 2), Vector2i(6, 2)), "LOS 墙阻挡")
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(6, 0)), "LOS 无墙通视")
	MazeGenerator.current_grid = []
```

- [ ] **Step 3: 请用户运行冒烟测试并确认通过**,然后提交:

```bash
git add Globals/maze_generator.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: MazeGenerator 环面 BFS + LOS + current_grid"
```

---

### Task 3: 敌方抛物线子弹(EnemyBullet)

**Files:**
- Create: `Scenes/Enemies/enemy_bullet.gd`
- Create: `Scenes/Enemies/enemy_bullet.tscn`
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Produces: `class_name EnemyBullet extends BulletBase`,方法 `launch(vel: Vector2, rng: float, col: Color, dmg: int, grav: float)`;命中玩家组 → `take_hit(global_position, damage)`,命中地形/超射程消失。
- Consumes: Task 1 的碰撞层(敌人层 3、玩家层 2)。

- [ ] **Step 1: 写 `enemy_bullet.gd`**

创建 `Scenes/Enemies/enemy_bullet.gd`:

```gdscript
class_name EnemyBullet
extends BulletBase

# 敌方投弹:由发射者给定初速向量与重力倍率,重力抛物线飞行,命中玩家造成 damage。
# 场景 collision_mask=3(层1地形+层2玩家),不含层3 → 不撞自己/其他敌人。
var damage: int = 2


# 抛物线初速版 setup:直接设初速向量(平抛/投掷用),bullets 由发射者决定。
func launch(vel: Vector2, rng: float, col: Color, dmg: int, grav: float) -> void:
	velocity_vec = vel
	speed = vel.length()
	max_range = rng
	bullet_color = col
	damage = dmg
	gravity_factor = grav
	rotation = vel.angle()


func _physics_process(delta: float) -> void:
	velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
	rotation = velocity_vec.angle()
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if hit != null and hit.is_in_group("player") and hit.has_method("take_hit"):
			hit.take_hit(global_position, damage)
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()
```

- [ ] **Step 2: 写 `enemy_bullet.tscn`**

创建 `Scenes/Enemies/enemy_bullet.tscn`(镜像 bullet.tscn 结构,脚本换、mask=3):

```tscn
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://Scenes/Enemies/enemy_bullet.gd" id="1_bl"]
[ext_resource type="Texture2D" uid="uid://cbxquhfl3xc11" path="res://AssetBundle/Sprites/Bullets.png" id="2_14wxs"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_8bitv"]
size = Vector2(12, 6)

[node name="EnemyBullet" type="CharacterBody2D"]
collision_layer = 0
collision_mask = 3
motion_mode = 1
script = ExtResource("1_bl")

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("RectangleShape2D_8bitv")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture_filter = 1
texture = ExtResource("2_14wxs")
region_enabled = true
region_rect = Rect2(2, 1, 11, 4)
```

- [ ] **Step 3: 冒烟测试加敌方子弹校验段**

在 `Tests/enemy_logic_smoke.gd` 的 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 3: 敌方抛物线子弹 ──
	var bscene_e: PackedScene = load("res://Scenes/Enemies/enemy_bullet.tscn")
	_check(bscene_e != null, "敌方子弹场景加载")
	var eb := bscene_e.instantiate()
	eb.global_position = Vector2(400, 400)
	root.add_child(eb)
	eb.launch(Vector2(100.0, 0.0), 2000.0, Color(1.0, 0.6, 0.2), 2, 1.0)
	var start_vy: float = eb.velocity_vec.y
	for i in range(10):
		await physics_frame
	_check(eb.velocity_vec.y > start_vy, "敌方子弹受重力下坠")
	_check(is_instance_valid(eb) and eb.traveled > 0.0, "敌方子弹在飞行")
	eb.free()
	# 命中玩家组 → take_hit(damage)
	var combat2 := StubCombatPlayer.new()
	combat2.global_position = Vector2(400, 400)
	root.add_child(combat2)
	var eb2 := bscene_e.instantiate()
	eb2.global_position = Vector2(400, 400)
	root.add_child(eb2)
	eb2.launch(Vector2(300.0, 0.0), 2000.0, Color(1.0, 0.6, 0.2), 2, 1.0)
	for i in range(5):
		await physics_frame
		if not is_instance_valid(eb2):
			break
	_check(not is_instance_valid(eb2), "敌方子弹命中玩家后消失")
	_check(combat2.hit_log.has(2), "敌方子弹命中造成伤害 2")
	combat2.free()
```

- [ ] **Step 4: 请用户运行冒烟测试并确认通过**,然后提交:

```bash
git add Scenes/Enemies/enemy_bullet.gd Scenes/Enemies/enemy_bullet.tscn Tests/enemy_logic_smoke.gd
git commit -m "feat: 敌方抛物线子弹(EnemyBullet extends BulletBase)"
```

---

### Task 4: EnemyBase 接触伤害守卫

**Files:**
- Modify: `Scenes/Enemies/enemy_base.gd`
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Produces: `contact_damage <= 0` 时 `_physics_process` 跳过 `take_hit`(FlyBird 用 contact_damage=0 防零伤消耗玩家 iframe)。

- [ ] **Step 1: 改 `enemy_base.gd` 接触伤害守卫**

`Scenes/Enemies/enemy_base.gd` `_physics_process` 内(第 72-76 行):

```gdscript
	# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
	if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
```
改为:
```gdscript
	# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
	# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
	if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
```

- [ ] **Step 2: 冒烟测试加守卫校验段**

在 `Tests/enemy_logic_smoke.gd` 的 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 4: 接触伤害守卫(contact_damage<=0 不触发)──
	var combat3 := StubCombatPlayer.new()
	combat3.global_position = Vector2(400, 400)
	root.add_child(combat3)
	var ej := jump2.instantiate()
	ej.global_position = Vector2(400, 400)
	root.add_child(ej)
	ej.contact_damage = 0
	for i in range(5):
		await physics_frame
	_check(combat3.hit_log.is_empty(), "contact_damage=0 不触发接触伤害")
	ej.contact_damage = 4
	for i in range(5):
		await physics_frame
	_check(combat3.hit_log.has(4), "contact_damage>0 触发接触伤害")
	ej.free()
	combat3.free()
```

- [ ] **Step 3: 请用户运行冒烟测试并确认通过**,然后提交:

```bash
git add Scenes/Enemies/enemy_base.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: 接触伤害守卫(contact_damage<=0 跳过 take_hit)"
```

---

### Task 5: FlyBird 核心(睡眠/起飞/飞行/射击/死亡) + 场景接线 + 注册

**Files:**
- Create: `Scenes/Enemies/enemy_fly_bird.gd`
- Modify: `Scenes/Enemies/EnemyFlyBird.tscn`
- Modify: `Globals/enemyParams.gd`
- Modify: `Scenes/Enemies/enemy_spawner.gd`
- Modify: `Scenes/level_0.gd`
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Consumes: Task 2 的 `MazeGenerator.current_grid/cell_of/bfs_path`,Task 3 的 `EnemyBullet`,Task 4 的接触守卫。
- Produces: `class_name EnemyFlyBird extends EnemyBase`,`enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }`(CHARGE/RETURN 本任务为占位,Task 6 实现),`state` 变量(SLEEP=0/TAKE_OFF=1/FLY=2/SHOOT=3),`hurt()` 覆写死亡坠落;`EnemyParams.FlyBird` 全部参数。

- [ ] **Step 1: 在 `enemyParams.gd` 追加 `class FlyBird`**

在 `Globals/enemyParams.gd` 的 `class JumpBird` 之后、文件末尾追加:

```gdscript

class FlyBird:
	const wake_radius: float = 1500.0     # 视野半径,屏幕外可见
	const home_range: float = 2200.0      # 玩家距出生点超此值 → 放弃返程
	const hover_altitude: float = 40.0    # 巡航高度(路径格上方 px)
	const hover_offset_x: float = 260.0   # 斜上锚点水平偏移
	const hover_offset_y: float = 240.0   # 斜上锚点垂直偏移(上)
	const fly_speed: float = 280.0        # 飞行移动速度
	const take_off_speed: float = 750.0   # 起飞斜上初速(上跳分量 0.75x)
	const take_off_time: float = 0.5      # 起飞滑翔时长(秒)
	const shoot_range: float = 520.0      # 进入射击距离
	const shoot_reacquire_margin: float = 160.0  # 出射程余量(重接近阈值)
	const shoot_cooldown: float = 1.4     # 抛弹间隔(秒)
	const bullet_damage: int = 2          # 投弹伤害
	const bullet_range: float = 1600.0    # 投弹射程
	const bullet_gravity: float = 1.0     # 投弹重力倍率
	const bullet_color: Color = Color(1.0, 0.6, 0.2, 1.0)  # 橙色投弹
	const bullet_min_speed: float = 260.0 # 平抛初速下限
	const bullet_max_speed: float = 1400.0 # 平抛初速上限
	const bullet_min_drop: float = 30.0   # 落点落差下限
	const charge_hp_fraction: float = 0.25 # 冲撞血量阈值(HP<25%)
	const charge_range: float = 1300.0    # 冲撞触发距离(且需 LOS)
	const charge_speed: float = 950.0     # 冲撞速度
	const charge_timeout: float = 2.5     # 冲撞超时 → 自毁
	const charge_damage: int = 5          # 冲撞撞玩家伤害
	const repath_interval: float = 0.5    # 重寻路间隔(秒)
	const arrival_radius: float = 50.0    # 到路径格/回家判定
```

- [ ] **Step 2: 写 `enemy_fly_bird.gd`(Task 5 范围:睡眠/起飞/飞行/射击/死亡;CHARGE/RETURN 占位)**

创建 `Scenes/Enemies/enemy_fly_bird.gd`:

```gdscript
class_name EnemyFlyBird
extends EnemyBase

enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
enum Intent { SHOOT, CHARGE }

const ENEMY_BULLET_SCENE: PackedScene = preload("res://Scenes/Enemies/enemy_bullet.tscn")

var state: State = State.SLEEP
var intent: Intent = Intent.SHOOT

var _anim: AnimatedSprite2D
var _spawn_pos: Vector2 = Vector2.ZERO
var _home_cell: Vector2i = Vector2i.ZERO
var _max_hp: int = 20
var _state_timer: float = 0.0
var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _shoot_timer: float = 0.0
var _repath_timer: float = 0.0
var _repath_phase: float = 0.0       # 随机错峰,避免 40 只鸟同帧 BFS
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _hover_anchor: Vector2 = Vector2.ZERO
var _hover_side: float = 1.0
var _landing: bool = false           # RETURN 落地阶段
var _ground_polygon: CollisionPolygon2D = null
var _fly_polygon: CollisionPolygon2D = null


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	_spawn_pos = global_position
	_max_hp = hp
	_home_cell = _cell_of(global_position)
	_ground_polygon = $CollisionPolygon2D
	_fly_polygon = $CollisionPolygon2D_fly
	_repath_phase = randf() * EnemyParams.FlyBird.repath_interval
	_set_state(State.SLEEP)
	_anim.play("sleeping")
	_apply_flight_collision(false)


func _physics_process(delta: float) -> void:
	if is_dead:
		_update_death(delta)
		return
	super._physics_process(delta)


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_timer > 0.0:
				_wake_timer -= delta
				if _wake_timer <= 0.0:
					_set_state(State.TAKE_OFF)
					_anim.play("take_off")
					_apply_flight_collision(true)
					_takeoff_velocity()
			elif _sleep_anim_timer > 0.0:
				_sleep_anim_timer -= delta
				if _sleep_anim_timer <= 0.0:
					_anim.play("sleeping")
			else:
				_anim.play("sleeping")
				if dist <= EnemyParams.FlyBird.wake_radius:
					_anim.play("wake_up")
					_wake_timer = _anim_duration("wake_up")
		State.TAKE_OFF:
			_state_timer += delta
			if _state_timer >= EnemyParams.FlyBird.take_off_time:
				_set_state(State.FLY)
				use_gravity = false
				_anim.play("flying")
				_schedule_repath()
		State.FLY:
			_anim.play("flying")
			if dist <= EnemyParams.FlyBird.shoot_range:
				_start_shoot()
				return
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
				_repath_to(_cell_of(_player_pos()))
			_follow_path(delta)
		State.SHOOT:
			_anim.play("flying")
			if dist > EnemyParams.FlyBird.shoot_range + EnemyParams.FlyBird.shoot_reacquire_margin:
				_set_state(State.FLY)
				_schedule_repath()
				return
			_update_hover_anchor()
			_hover_to_anchor(delta)
			_shoot_timer -= delta
			if _shoot_timer <= 0.0:
				_fire_parabolic()
				_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
		State.CHARGE, State.RETURN:
			pass  # Task 6 实现


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
		_die_self()


# 死亡坠落:重力开启,落地后消失(无 dead 动画帧)。
func _die_self() -> void:
	if is_dead:
		return
	is_dead = true
	collision_layer = 0
	use_gravity = true
	_apply_flight_collision(true)


func _update_death(delta: float) -> void:
	velocity.y += GameParameters.gravity0 * delta
	move_and_slide()
	if is_on_floor():
		queue_free()


# ── 内部工具 ──

func _set_state(s: State) -> void:
	state = s
	_state_timer = 0.0


func _apply_flight_collision(in_air: bool) -> void:
	# 站立用 CollisionPolygon2D,空中用 CollisionPolygon2D_fly。
	if _ground_polygon != null:
		_ground_polygon.disabled = in_air
	if _fly_polygon != null:
		_fly_polygon.disabled = not in_air


func _cell_of(pos: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i.ZERO
	return MazeGenerator.cell_of(pos, GameParameters.TILE_SIZE, grid[0].size(), grid.size())


func _cell_is_solid(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return grid[cell.y][cell.x] == MazeGenerator.SOLID


func _player_pos() -> Vector2:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and "velocity" in p:
		return p.velocity
	return Vector2.ZERO


func _player_home_dist() -> float:
	return MazeGenerator.toroidal_delta_px(_player_pos(), _spawn_pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func _toroidal_dist_to(pos: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(global_position, pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func _waypoint_world(cell: Vector2i) -> Vector2:
	var ts := GameParameters.TILE_SIZE
	var p := Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
	p.y -= EnemyParams.FlyBird.hover_altitude
	return MazeGenerator.anchor_to_nearest(p, _player_pos(),
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func _follow_path(delta: float) -> void:
	if _path.is_empty():
		return
	var spd := EnemyParams.FlyBird.fly_speed
	while _path_index < _path.size():
		var target := _waypoint_world(_path[_path_index])
		var to_target := target - global_position
		if to_target.length() <= spd * delta:
			global_position = target
			_path_index += 1
		else:
			velocity = to_target.normalized() * spd
			return
	_path = []


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	_path = MazeGenerator.bfs_path(_cell_of(global_position), cell)
	_path_index = 0


func _start_shoot() -> void:
	_set_state(State.SHOOT)
	_pick_hover_side()
	_update_hover_anchor()
	_shoot_timer = 0.2


func _pick_hover_side() -> void:
	var delta := toroidal_delta_to_player()
	if absf(delta.x) > 20.0:
		_hover_side = -1.0 if delta.x > 0.0 else 1.0
	else:
		_hover_side = 1.0 if randf() < 0.5 else -1.0


func _update_hover_anchor() -> void:
	# 斜上锚点:玩家侧向 + 上向偏移,不在玩家正头顶。
	var p := _player_pos()
	_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
			-EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(_hover_anchor)):
		_hover_side = -_hover_side
		_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)


func _hover_to_anchor(delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := _hover_anchor - global_position
	if to_target.length() <= spd * delta:
		global_position = _hover_anchor
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


func _fire_parabolic() -> void:
	# 平抛:水平初速 + 重力,落点按玩家坐标 + 玩家即时速度预测。
	var dy := global_position.y - _player_pos().y
	dy = maxf(dy, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * dy / GameParameters.gravity0)
	var pred := _player_pos() + _player_velocity() * t
	var dx := pred.x - global_position.x
	if absf(dx) > GameParameters.MAP_WIDTH * 0.5:
		dx = -signf(dx) * (GameParameters.MAP_WIDTH - absf(dx))
	var v0 := clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)
	var b: EnemyBullet = ENEMY_BULLET_SCENE.instantiate()
	b.launch(Vector2(v0, 0.0), EnemyParams.FlyBird.bullet_range,
			EnemyParams.FlyBird.bullet_color, EnemyParams.FlyBird.bullet_damage,
			EnemyParams.FlyBird.bullet_gravity)
	b.global_position = global_position
	get_viewport().add_child(b)


func _takeoff_velocity() -> void:
	var dir := toroidal_dir_to_player()
	var s := EnemyParams.FlyBird.take_off_speed
	velocity = Vector2(dir.x * s, -s * 0.75)
	use_gravity = true


func _update_facing() -> void:
	var vx := velocity.x
	if absf(vx) > 5.0:
		_anim.flip_h = vx < 0.0
	elif state == State.SHOOT:
		var d := toroidal_delta_to_player()
		if absf(d.x) > 0.05:
			_anim.flip_h = d.x < 0.0


func _anim_duration(name: String) -> float:
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)
```

- [ ] **Step 3: 接线 `EnemyFlyBird.tscn`**

修改 `Scenes/Enemies/EnemyFlyBird.tscn`:

**(a)** 首行 `[gd_scene format=3 uid="uid://b332erg3p61ae"]` 改为 `[gd_scene load_steps=22 format=3 uid="uid://b332erg3p61ae"]`。

**(b)** 在 `[ext_resource type="Texture2D" uid="uid://cfdgmkl0cnjbk" path="res://AssetBundle/Sprites/Fly_Bird.png" id="1_jclwe"]` 之后加一行:

```tscn
[ext_resource type="Script" path="res://Scenes/Enemies/enemy_fly_bird.gd" id="2_script"]
```

**(c)** 根节点:

```tscn
[node name="EnemyFlyBird" type="CharacterBody2D" unique_id=1702711534]
```
改为:
```tscn
[node name="EnemyFlyBird" type="CharacterBody2D" unique_id=1702711534]
scale = Vector2(2, 2)
collision_layer = 3
collision_mask = 3
script = ExtResource("2_script")
hp = 20
contact_damage = 0
knockback_strength = 200.0
```

**(d)** AnimatedSprite2D 初始动画改为睡眠,清掉预览残留帧:

```tscn
[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="." unique_id=736759762]
sprite_frames = SubResource("SpriteFrames_0uvy8")
animation = &"flying"
frame = 4
frame_progress = 0.45944694
```
改为:
```tscn
[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="." unique_id=736759762]
sprite_frames = SubResource("SpriteFrames_0uvy8")
animation = &"sleeping"
```

**(e)** 飞行碰撞箱默认禁用(睡眠在地面用站立箱;`_ready` 会再设一次):

```tscn
[node name="CollisionPolygon2D_fly" type="CollisionPolygon2D" parent="." unique_id=283299039]
polygon = PackedVector2Array(4, -13, -22, -16, -17, 0, -16, 13, 5, 13, 23, -3)
```
改为:
```tscn
[node name="CollisionPolygon2D_fly" type="CollisionPolygon2D" parent="." unique_id=283299039]
disabled = true
polygon = PackedVector2Array(4, -13, -22, -16, -17, 0, -16, 13, 5, 13, 23, -3)
```

- [ ] **Step 4: 注册生成器 + level_0 赋值网格**

`Scenes/Enemies/enemy_spawner.gd` 的 `TYPES`:

```gdscript
const TYPES: Dictionary = {
	"jump_bird": "res://Scenes/Enemies/EnemyJumpBird.tscn",
}
```
改为:
```gdscript
const TYPES: Dictionary = {
	"jump_bird": "res://Scenes/Enemies/EnemyJumpBird.tscn",
	"fly_bird": "res://Scenes/Enemies/EnemyFlyBird.tscn",
}
```

`Scenes/level_0.gd` 的 `_ready()`(第 15-18 行,`load_map_file` 之后):

```gdscript
	var grid = MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
```
之后加一行:
```gdscript
	MazeGenerator.current_grid = grid
```

- [ ] **Step 5: 冒烟测试加 FlyBird 核心校验段**

在 `Tests/enemy_logic_smoke.gd` 的 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 5: FlyBird 基础(睡眠/唤醒/起飞/射击/死亡)──
	var fb_grid: Array[Array] = []
	for _y in range(150):
		var row3: Array[int] = []
		row3.resize(300)
		row3.fill(MazeGenerator.EMPTY)
		fb_grid.append(row3)
	MazeGenerator.current_grid = fb_grid
	var fb_scene: PackedScene = load("res://Scenes/Enemies/EnemyFlyBird.tscn")
	_check(fb_scene != null, "FlyBird 场景加载")
	var fb := fb_scene.instantiate()
	fb.global_position = Vector2(488, 1208)
	root.add_child(fb)
	await physics_frame
	_check(fb.get_script() == load("res://Scenes/Enemies/enemy_fly_bird.gd"), "FlyBird 实例类型")
	_check(fb.state == 0, "FlyBird 初始休眠")
	_check(fb.is_in_group("enemies"), "FlyBird 加入 enemies 组")
	_check(fb.get_node_or_null("ContactArea") != null, "FlyBird ContactArea 创建")
	_check(fb.hp == 20, "FlyBird hp=20")
	_check(fb.contact_damage == 0, "FlyBird 无接触伤害")
	_check(fb.collision_layer == 3, "FlyBird 占层3")
	_check(is_equal_approx(fb.scale.x, 2.0), "FlyBird scale=2.0")
	# 玩家远离 → 保持睡眠
	var far_player := StubCombatPlayer.new()
	far_player.global_position = Vector2(2888, 2392)
	root.add_child(far_player)
	for i in range(30):
		await physics_frame
	_check(fb.state == 0, "玩家远处保持睡眠")
	far_player.free()
	# 玩家接近 → 苏醒→起飞→飞行→射击并命中
	var near_player := StubCombatPlayer.new()
	near_player.global_position = Vector2(600, 1208)
	root.add_child(near_player)
	var eb_script := load("res://Scenes/Enemies/enemy_bullet.gd")
	var reached_shoot := false
	var fired := false
	for i in range(240):
		await physics_frame
		if fb.state == 3:
			reached_shoot = true
		if not fired:
			for child in root.get_children():
				if child.get_script() == eb_script:
					fired = true
					break
	_check(reached_shoot, "FlyBird 进入射击状态")
	_check(fired, "FlyBird 发射过投弹")
	_check(near_player.hit_log.has(2), "投弹命中玩家造成 2 伤害")
	# 杀死 → 坠落落地消失
	var floor_b := StaticBody2D.new()
	var fshape_b := CollisionShape2D.new()
	var frect_b := RectangleShape2D.new()
	frect_b.size = Vector2(800, 40)
	fshape_b.shape = frect_b
	fshape_b.position = Vector2(0, -20)
	floor_b.add_child(fshape_b)
	floor_b.position = Vector2(500, 1300)
	floor_b.collision_layer = 1
	floor_b.collision_mask = 0
	root.add_child(floor_b)
	fb.hurt(99, Vector2.RIGHT)
	await physics_frame
	_check(fb.is_dead, "FlyBird 受击死亡")
	var died := false
	for i in range(180):
		await physics_frame
		if not is_instance_valid(fb):
			died = true
			break
	_check(died, "FlyBird 死亡坠落落地后消失")
	floor_b.free()
	near_player.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 6: 请用户运行冒烟测试并确认通过**,然后提交:

```bash
git add Globals/enemyParams.gd Scenes/Enemies/enemy_fly_bird.gd Scenes/Enemies/EnemyFlyBird.tscn Scenes/Enemies/enemy_spawner.gd Scenes/level_0.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: FlyBird 核心状态机(睡眠/起飞/飞行/斜上射击/坠落死亡)"
```

---

### Task 6: FlyBird 冲撞 + 返程

**Files:**
- Modify: `Scenes/Enemies/enemy_fly_bird.gd`
- Modify: `Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Consumes: Task 5 的 FlyBird 脚本骨架、Task 2 的 `has_line_of_sight`。
- Produces: 冲撞(HP<25% + LOS 通 → 高速直线,撞玩家 5 伤/撞墙/超时自毁)与返程(玩家距出生点 > home_range 或 BFS 无路 → 飞回家落地入睡)。

- [ ] **Step 1: 改 `_ai` 的 FLY 分支**

`enemy_fly_bird.gd` 的 FLY 分支:

```gdscript
		State.FLY:
			_anim.play("flying")
			if dist <= EnemyParams.FlyBird.shoot_range:
				_start_shoot()
				return
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
				_repath_to(_cell_of(_player_pos()))
			_follow_path(delta)
```
改为:
```gdscript
		State.FLY:
			_anim.play("flying")
			if _player_home_dist() > EnemyParams.FlyBird.home_range:
				_start_return()
				return
			_update_charge_intent_if_needed()
			if intent == Intent.CHARGE:
				if _try_charge():
					return
			elif dist <= EnemyParams.FlyBird.shoot_range:
				_start_shoot()
				return
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
				_repath_to(_cell_of(_player_pos()))
				if _path.is_empty():
					_start_return()
					return
			_follow_path(delta)
```

- [ ] **Step 2: 改 `_ai` 的 SHOOT 分支**

```gdscript
		State.SHOOT:
			_anim.play("flying")
			if dist > EnemyParams.FlyBird.shoot_range + EnemyParams.FlyBird.shoot_reacquire_margin:
				_set_state(State.FLY)
				_schedule_repath()
				return
			_update_hover_anchor()
			_hover_to_anchor(delta)
			_shoot_timer -= delta
			if _shoot_timer <= 0.0:
				_fire_parabolic()
				_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
```
改为:
```gdscript
		State.SHOOT:
			_anim.play("flying")
			if _player_home_dist() > EnemyParams.FlyBird.home_range:
				_start_return()
				return
			_update_charge_intent_if_needed()
			if intent == Intent.CHARGE:
				if _try_charge():
					return
			elif dist > EnemyParams.FlyBird.shoot_range + EnemyParams.FlyBird.shoot_reacquire_margin:
				_set_state(State.FLY)
				_schedule_repath()
				return
			_update_hover_anchor()
			_hover_to_anchor(delta)
			_shoot_timer -= delta
			if _shoot_timer <= 0.0:
				_fire_parabolic()
				_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
```

- [ ] **Step 3: 把 CHARGE/RETURN 占位分支替换为实现**

```gdscript
		State.CHARGE, State.RETURN:
			pass  # Task 6 实现
```
改为:
```gdscript
		State.CHARGE:
			_state_timer += delta
			if _state_timer >= EnemyParams.FlyBird.charge_timeout:
				_die_self()
		State.RETURN:
			_anim.play("flying")
			if _landing:
				pass
			elif _home_reached():
				_start_landing()
			else:
				_repath_timer -= delta
				if _repath_timer <= 0.0:
					_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
					_repath_to(_home_cell)
				_follow_path(delta)
```

- [ ] **Step 4: 改 `_physics_process`(冲撞撞物 + 落地入睡)**

```gdscript
func _physics_process(delta: float) -> void:
	if is_dead:
		_update_death(delta)
		return
	super._physics_process(delta)
```
改为:
```gdscript
func _physics_process(delta: float) -> void:
	if is_dead:
		_update_death(delta)
		return
	super._physics_process(delta)
	# 冲撞撞到东西(super 已执行 move_and_slide)
	if state == State.CHARGE and get_slide_collision_count() > 0:
		_on_charge_impact()
	elif state == State.RETURN and _landing and is_on_floor():
		# 返程落地 → 入睡(先播 fall_asleep 一次性动画)
		_anim.play("fall_asleep")
		_sleep_anim_timer = _anim_duration("fall_asleep")
		_set_state(State.SLEEP)
		_apply_flight_collision(false)
		_landing = false
```

- [ ] **Step 5: 追加冲撞/返程工具方法**

在 `enemy_fly_bird.gd` 的 `_takeoff_velocity()` 之前插入:

```gdscript
# ── 冲撞与返程 ──

func _update_charge_intent_if_needed() -> void:
	# 血量跌穿 25% 单向切冲撞意图(HP 只减不增)。
	if intent == Intent.SHOOT and hp < _max_hp * EnemyParams.FlyBird.charge_hp_fraction:
		intent = Intent.CHARGE


func _try_charge() -> bool:
	if toroidal_dist_to_player() > EnemyParams.FlyBird.charge_range:
		return false
	if not MazeGenerator.has_line_of_sight(_cell_of(global_position), _cell_of(_player_pos())):
		return false
	_start_charge()
	return true


func _start_charge() -> void:
	_set_state(State.CHARGE)
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	_anim.play("dashing")


func _on_charge_impact() -> void:
	for i in range(get_slide_collision_count()):
		var collider := get_slide_collision(i).get_collider()
		if collider != null and collider.is_in_group("player") and collider.has_method("take_hit"):
			collider.take_hit(global_position, EnemyParams.FlyBird.charge_damage)
			break
	_die_self()


func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	_anim.play("flying")
	_repath_to(_home_cell)


func _home_reached() -> bool:
	return _toroidal_dist_to(_spawn_pos) <= EnemyParams.FlyBird.arrival_radius


func _start_landing() -> void:
	_landing = true
	_path = []
	use_gravity = true
	velocity = Vector2.ZERO
	_apply_flight_collision(false)  # 落地用站立碰撞箱
```

- [ ] **Step 6: 冒烟测试加冲撞/返程校验段**

在 `Tests/enemy_logic_smoke.gd` 的 `_initialize()` 末尾 `if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 6: FlyBird 冲撞 + 返程 ──
	var fb2_grid: Array[Array] = []
	for _y in range(150):
		var row4: Array[int] = []
		row4.resize(300)
		row4.fill(MazeGenerator.EMPTY)
		fb2_grid.append(row4)
	MazeGenerator.current_grid = fb2_grid
	# 冲撞: HP<25% + LOS 通 → 撞玩家 5 伤并自毁
	var fb2 := fb_scene.instantiate()
	fb2.global_position = Vector2(488, 1208)
	root.add_child(fb2)
	await physics_frame
	fb2.hp = 4
	var charge_player := StubCombatPlayer.new()
	charge_player.global_position = Vector2(700, 1208)
	root.add_child(charge_player)
	var entered_charge := false
	for i in range(240):
		await physics_frame
		if fb2.state == 4:
			entered_charge = true
			break
	_check(entered_charge, "FlyBird 低血量进入冲撞")
	for i in range(120):
		await physics_frame
		if not is_instance_valid(fb2):
			break
	_check(charge_player.hit_log.has(5), "冲撞造成 5 伤害")
	_check(not is_instance_valid(fb2) or fb2.is_dead, "冲撞后自毁")
	if is_instance_valid(fb2):
		fb2.free()
	charge_player.free()
	# 冲撞超时: 起冲后移走玩家 → 超时自毁
	var fb3 := fb_scene.instantiate()
	fb3.global_position = Vector2(488, 1208)
	root.add_child(fb3)
	await physics_frame
	fb3.hp = 4
	var timeout_player := StubCombatPlayer.new()
	timeout_player.global_position = Vector2(700, 1208)
	root.add_child(timeout_player)
	var charged := false
	for i in range(240):
		await physics_frame
		if fb3.state == 4:
			charged = true
			break
	_check(charged, "FlyBird 再次进入冲撞")
	timeout_player.global_position = Vector2(2888, 2392)
	var timed_out := false
	for i in range(200):
		await physics_frame
		if fb3.is_dead:
			timed_out = true
			break
	_check(timed_out, "冲撞超时自毁")
	if is_instance_valid(fb3):
		fb3.free()
	timeout_player.free()
	# 返程: 玩家跑出追击范围 → 回家落地入睡
	var floor_r := StaticBody2D.new()
	var fshape_r := CollisionShape2D.new()
	var frect_r := RectangleShape2D.new()
	frect_r.size = Vector2(400, 40)
	fshape_r.shape = frect_r
	fshape_r.position = Vector2(0, -20)
	floor_r.add_child(fshape_r)
	floor_r.position = Vector2(488, 1256)
	floor_r.collision_layer = 1
	floor_r.collision_mask = 0
	root.add_child(floor_r)
	var fb4 := fb_scene.instantiate()
	fb4.global_position = Vector2(488, 1208)
	root.add_child(fb4)
	await physics_frame
	var ret_player := StubCombatPlayer.new()
	ret_player.global_position = Vector2(600, 1208)
	root.add_child(ret_player)
	var engaged := false
	for i in range(240):
		await physics_frame
		if fb4.state == 2 or fb4.state == 3:
			engaged = true
			break
	_check(engaged, "FlyBird 进入战斗状态")
	ret_player.global_position = Vector2(2888, 2392)
	var returned := false
	for i in range(600):
		await physics_frame
		if fb4.state == 0:
			returned = true
			break
	_check(returned, "FlyBird 返程后入睡")
	floor_r.free()
	ret_player.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 7: 请用户运行冒烟测试并确认全部通过**,然后提交:

```bash
git add Scenes/Enemies/enemy_fly_bird.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: FlyBird 冲撞(低血自杀)与返程(回家入睡)"
```

---

## Self-Review

**Spec 覆盖对照:**
- 状态机 6 态:Task 5(SLEEP/TAKE_OFF/FLY/SHOOT/死亡)+ Task 6(CHARGE/RETURN)✓
- 斜上锚点定位:Task 5 `_update_hover_anchor` ✓
- 平抛子弹 + 落点预测:Task 3 + Task 5 `_fire_parabolic` ✓
- 冲撞(5 伤/撞墙/超时自毁):Task 6 ✓
- 返程(玩家出范围 / BFS 无路):Task 6 ✓
- 碰撞层重构:Task 1 ✓
- 死亡坠落落地:Task 5 ✓
- 注册 spawner / level_0 网格:Task 5 ✓
- 冒烟测试覆盖:Task 1-6 ✓
