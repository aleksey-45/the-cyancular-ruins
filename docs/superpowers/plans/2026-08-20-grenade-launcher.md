# 榴弹发射器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增第 5 武器榴弹发射器：抛物线榴弹、碰撞后引信爆炸、AoE 分段衰减 + 遮挡 + 友伤、heavy_aim 抛物线预瞄。

**Architecture:** 一脚本多场景。`BulletBase` 加爆炸 @export 参数（默认值保证现有武器不变），重力上移基类；`Explosion`（Globals/explosion.gd）静态 AoE 判定；`WeaponBase` 加 `bullet_scene`/`bullet_gravity`/`preview_arc`（弧线预瞄，参考）；榴弹与发射器各为一个新 .tscn；爆炸特效为纯视觉占位场景。引信碰撞后才计时、命中敌人立即炸。

**Tech Stack:** Godot 4.7.1 标准版 GDScript。粒子系统在裁剪 profile 里被禁用，爆炸特效禁用 CPUParticles/GPUParticles。

## Global Constraints

- Godot 二进制（不在 PATH）：
  - 编辑器：`D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe`
  - headless console（冒烟/import）：`D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`
- **测试由用户自己运行**（项目记忆约定）：执行者写完测试/实现后**不要自己跑**，把运行命令交给用户执行并回报结果。
- 现有冒烟 `res://tests/enemy_logic_smoke.gd` 必须保持 `SMOKE OK`（回归门禁）。
- 新建含 `class_name` 的 `.gd` 后，必须跑一次 `--headless --import` 注册全局类缓存，否则 `Explosion` 等类名解析失败。
- 手写 `.tscn` 一律不写 uid 属性，靠 `--headless --import` 自动补；ext_resource 用 `path=` 引用（不带 uid）。
- 爆炸/特效禁用粒子节点（profile 裁掉）。
- 新武器槽 = 键盘 `5`，对应输入动作 `"5"`。
- 代码注释用中文，与项目风格一致。
- 设计 spec：`docs/superpowers/specs/2026-08-20-grenade-launcher-design.md`。

---

### Task 1: 爆炸 AoE 判定 `Globals/explosion.gd` + 冒烟测试骨架

**Files:**
- Create: `Globals/explosion.gd`
- Create: `Tests/grenade_smoke.gd`
- Test: `Tests/grenade_smoke.gd`（`-s` 运行）

**Interfaces:**
- Produces: `Explosion.apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float) -> void`（遍历 `enemies` 组与 `player` 组，分段衰减 + LOS 遮挡 + 友伤）
- Produces: `Explosion.make_circle_texture(size: int) -> ImageTexture`（软圆白贴图，供爆炸占位/榴弹占位/预瞄标记复用）
- Produces: `Tests/grenade_smoke.gd`（`extends SceneTree`，成功打印 `GRENADE SMOKE OK` 退出 0）

- [ ] **Step 1: 写 `Globals/explosion.gd`**

```gdscript
class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.35  # 内圈半径比例,内圈内满伤

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float) -> void:
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d := _dist(center, (e as Node2D).global_position)
		if d > radius:
			continue
		if has_grid and not _has_los(center, e as Node2D, grid):
			continue  # 遮挡(硬掩体):0 伤
		var dmg := _falloff(d, radius, max_damage)
		if dmg <= 0:
			continue
		e.hurt(dmg, _outward_dir(center, (e as Node2D).global_position), _falloff(d, radius, max_knockback))
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit") and not (p.has_method("is_downed") and p.is_downed()):
		var d := _dist(center, (p as Node2D).global_position)
		if d <= radius and (not has_grid or _has_los(center, p as Node2D, grid)):
			p.take_hit(center, _falloff(d, radius, max_damage))  # take_hit 按 source 方向推 = 向外冲击波

# 软圆白贴图:占位爆炸/榴弹占位/预瞄爆点标记共用。
static func make_circle_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x - cx, y - cx).length() / cx
			if d <= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, (1.0 - d) * 0.9))
	return ImageTexture.create_from_image(img)

static func _dist(center: Vector2, target: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()

static func _outward_dir(center: Vector2, target: Vector2) -> Vector2:
	var delta := MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return delta.normalized() if not delta.is_zero_approx() else Vector2.RIGHT

static func _has_los(center: Vector2, target: Node2D, grid: Array[Array]) -> bool:
	var ts: int = GameParameters.TILE_SIZE
	var center_cell := MazeGenerator.cell_of(center, ts, grid[0].size(), grid.size())
	var target_cell := MazeGenerator.cell_of(target.global_position, ts, grid[0].size(), grid.size())
	return MazeGenerator.has_line_of_sight(center_cell, target_cell)

static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	return max_val * (1.0 - (d - inner) / (radius - inner))
```

- [ ] **Step 2: 写 `Tests/grenade_smoke.gd`（先只含 AoE 测试）**

```gdscript
extends SceneTree

# 桩敌人:入 enemies 组,记录 hurt
class StubEnemy:
	extends CharacterBody2D
	var hp: int = 50
	var hits: Array = []
	func _init() -> void:
		add_to_group("enemies")
		collision_layer = 4
		collision_mask = 0
	func hurt(damage: int, _dir: Vector2, _knock: float = 0.0) -> void:
		hp -= damage
		hits.append([damage, _dir, _knock])

# 桩玩家:入 player 组,记录 take_hit
class StubPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
	func take_hit(_source_pos: Vector2, damage: int, _ignore_iframes: bool = false) -> void:
		hit_log.append(damage)
	func is_downed() -> bool:
		return false

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	GameParameters.MAP_WIDTH = 400
	GameParameters.MAP_HEIGHT = 400
	_test_aoe()
	if _failures.is_empty():
		print("GRENADE SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)

func _test_aoe() -> void:
	MazeGenerator.current_grid = []  # 空网格:跳过 LOS
	# 中心满伤
	var e1 := StubEnemy.new()
	e1.global_position = Vector2(200, 200)
	root.add_child(e1)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e1.hp == 50 - 35, "AoE 中心满伤 35")
	e1.free()
	# 边缘(≈radius)→ 0 伤
	var e2 := StubEnemy.new()
	e2.global_position = Vector2(200, 200) + Vector2(127, 0)
	root.add_child(e2)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e2.hp == 50, "AoE 边缘 0 伤")
	e2.free()
	# 中段衰减: d=64, inner=44.8 → 35*(1-(64-44.8)/83.2)=26
	var e3 := StubEnemy.new()
	e3.global_position = Vector2(200, 200) + Vector2(64, 0)
	root.add_child(e3)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e3.hp == 50 - 26, "AoE 中段线性衰减")
	e3.free()
	# 冲击波向外:方向为从爆心指向目标
	var e4 := StubEnemy.new()
	e4.global_position = Vector2(200, 200) + Vector2(0, 60)
	root.add_child(e4)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e4.hits.size() == 1 and e4.hits[0][1].y > 0.0, "冲击波方向向外(+y)")
	e4.free()
	# 友伤:玩家在范围内掉血
	var p := StubPlayer.new()
	p.global_position = Vector2(200, 200) + Vector2(20, 0)
	root.add_child(p)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(p.hit_log.has(35), "玩家友伤满值 35")
	p.free()
	# LOS 遮挡:竖墙把爆心与敌人隔开 → 0 伤;同侧开阔 → 满伤
	var g: Array[Array] = []
	for _y in range(25):
		var row: Array[int] = []
		row.resize(25)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	for y in range(25):
		g[y][12] = MazeGenerator.SOLID
	MazeGenerator.current_grid = g
	var walled := StubEnemy.new()
	walled.global_position = Vector2(18 * 16, 12 * 16)  # 墙(12,*)另一侧
	root.add_child(walled)
	Explosion.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(walled.hp == 50, "墙后敌人 0 伤(LOS 遮挡)")
	walled.free()
	var open := StubEnemy.new()
	open.global_position = Vector2(6 * 16, 12 * 16)
	root.add_child(open)
	Explosion.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(open.hp == 50 - 35, "开阔侧满伤")
	open.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 3: 用户运行冒烟（应失败——`Explosion` 类还不存在）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/grenade_smoke.gd
```
Expected: 报 `Explosion` 解析失败/FAIL（刚建类,先 import 再跑即通过）。

- [ ] **Step 4: 用户重跑确认通过**

Run: 上面两条命令
Expected: 打印 `GRENADE SMOKE OK`，退出码 0。

- [ ] **Step 5: Commit**

```bash
git add Globals/explosion.gd Globals/explosion.gd.uid Tests/grenade_smoke.gd Tests/grenade_smoke.gd.uid
git commit -m "feat: Explosion AoE 判定(分段衰减+LOS遮挡+友伤) + 冒烟测试"
```

---

### Task 2: `BulletBase` 爆炸支持 + 引信时序

**Files:**
- Modify: `Scenes/Weapons/bullet_base.gd`
- Modify: `Tests/grenade_smoke.gd`（追加 `_test_fuse` / `_test_non_explosive_default` 与调用）

**Interfaces:**
- Consumes: `Explosion.apply_aoe`、`Explosion.make_circle_texture`（Task 1）
- Produces: `BulletBase` 新增 `@export`（`explodes/direct_hit_damage/fuse_time/explosion_radius/explosion_damage/explosion_knockback/explosion_visual`），`_explode()`；`setup()` 后由武器注入 `gravity_factor`（Task 4 用）

- [ ] **Step 1: 改 `bullet_base.gd`**

新增字段（放在 `var source` 之后）：
```gdscript
# ── 爆炸弹(榴弹等) ──
@export var explodes: bool = false        # 是否爆炸弹
@export var direct_hit_damage: int = 10   # 命中敌人的直接伤害
@export var fuse_time: float = 0.5        # 碰撞停驻后延时(秒);命中敌人则立即爆炸
@export var explosion_radius: float = 128.0
@export var explosion_damage: int = 35
@export var explosion_knockback: float = 900.0
@export var explosion_visual: PackedScene = null

var _fuse_active: bool = false   # 撞墙停驻后才开始计时
var _fuse_elapsed: float = 0.0
```

替换 `_physics_process`：
```gdscript
func _physics_process(delta: float) -> void:
	if gravity_factor > 0.0:
		velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
	if explodes and _fuse_active:
		_fuse_elapsed += delta
		if _fuse_elapsed >= fuse_time:
			_explode()
			queue_free()
			return
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if explodes:
			if hit != null and hit.is_in_group("enemies"):
				_direct_hit(hit)
				_explode()
				queue_free()
				return
			# 撞墙停驻,碰撞后才开始引信(不立即爆炸)
			velocity_vec = Vector2.ZERO
			_fuse_active = true
			return
		if hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			source.apply_hit(hit, velocity_vec)
		queue_free()
		return
	if traveled >= max_range:
		if explodes:
			_explode()
		queue_free()
		return
	_wrap()
```

新增两个方法（文件末尾）：
```gdscript
func _direct_hit(hit: Node) -> void:
	if hit.has_method("hurt"):
		var dir := velocity_vec.normalized() if not velocity_vec.is_zero_approx() else Vector2.RIGHT
		hit.hurt(direct_hit_damage, dir)

func _explode() -> void:
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback)
```

- [ ] **Step 2: 在 `grenade_smoke.gd` 追加测试**

在 `_initialize` 里、`_test_aoe()` 之后加两行调用：
```gdscript
	_test_fuse()
	_test_non_explosive_default()
```

在文件顶部桩类区（`StubPlayer` 类之后）追加：
```gdscript
# 桩武器:带真实 apply_hit 方法(has_method 只认方法,不认动态属性)
class StubWeapon:
	extends Node2D
	var damage: int = 5
	func apply_hit(target: Node, _dir: Vector2) -> void:
		if target.has_method("hurt"):
			target.hurt(damage, _dir, 0.0)
```

追加测试方法（直接 `new bullet_base.gd`，不依赖榴弹场景）。**`_make_bullet()` 无类型返回** —— `setup`/`explodes`/`gravity_factor` 都是脚本自定义成员，须动态分派（项目惯例，见 enemy_logic_smoke.gd 注释）：
```gdscript
func _test_fuse() -> void:
	MazeGenerator.current_grid = []
	# ── 基类重力:gravity_factor>0 时 velocity_vec.y 每帧增大(重力上移验证)──
	var bg := _make_bullet()
	bg.set("explodes", false)
	root.add_child(bg)
	bg.global_position = Vector2(100, 100)
	bg.setup(Vector2.RIGHT, 500.0, 2000.0, 1.0, Color.WHITE, null)
	bg.set("gravity_factor", 0.5)
	await physics_frame
	_check(bg.velocity_vec.y > 0.0, "基类重力生效(gravity_factor>0)")
	bg.free()
	# ── 直接命中敌人:10 直接伤 + 立即爆炸(中心 35)──
	var b := _make_bullet()
	root.add_child(b)
	var enemy := StubEnemy.new()
	enemy.global_position = Vector2(300, 200)
	root.add_child(enemy)
	b.global_position = Vector2(200, 200)
	b.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b):
			break
	_check(not is_instance_valid(b), "命中敌人后榴弹销毁")
	_check(enemy.hp == 50 - 10 - 35, "直接命中 = 10 直接 + 35 爆炸")
	enemy.free()
	# ── 撞墙 → 停驻 → 0.5s 后才爆(飞行中不炸)──
	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(20, 300)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = Vector2(300, 200)
	wall.collision_layer = 1
	wall.collision_mask = 0
	root.add_child(wall)
	var far := StubEnemy.new()
	far.global_position = Vector2(200, 400)  # 远离爆点,不受伤
	root.add_child(far)
	var b2 := _make_bullet()
	root.add_child(b2)
	b2.global_position = Vector2(200, 200)
	b2.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	var stopped := false
	for i in range(12):
		await physics_frame
		if b2.global_position.x >= 294.0 and is_instance_valid(b2):
			stopped = true
			break
	_check(stopped and is_instance_valid(b2), "撞墙后停驻且未销毁")
	var exploded := false
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b2):
			exploded = true
			break
	_check(exploded, "撞墙停驻后约 0.5s 爆炸")
	far.free()
	wall.free()

func _test_non_explosive_default() -> void:
	MazeGenerator.current_grid = []
	var b := _make_bullet()
	b.set("explodes", false)
	root.add_child(b)
	var enemy := StubEnemy.new()
	enemy.global_position = Vector2(300, 200)
	root.add_child(enemy)
	b.global_position = Vector2(200, 200)
	var gun := StubWeapon.new()
	root.add_child(gun)
	b.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, gun)
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b):
			break
	_check(enemy.hp == 50 - 5, "非爆炸弹直击走 apply_hit(武器 damage=5)")
	enemy.free()

# 直接 new bullet_base.gd,补碰撞体;返回已设 explodes=true、关特效的子弹。
# 无类型返回:setup/explodes/gravity_factor 都是脚本自定义成员,须动态分派。
func _make_bullet():
	var b = (load("res://scenes/Weapons/bullet_base.gd") as GDScript).new()
	var cshape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 6.0
	cshape.shape = circ
	b.add_child(cshape)
	b.set("explodes", true)
	b.set("explosion_visual", null)
	return b
```

注意：`b.set("explodes", true)` 因实例化的是脚本，@export 变量可用 `set` 写；不能 `b.explodes = true` 直赋是因为无类型变体上动态属性赋值在部分场景会走不通，`set` 最稳。

- [ ] **Step 3: 用户运行冒烟**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/grenade_smoke.gd
```
Expected: `GRENADE SMOKE OK`，退出 0。

- [ ] **Step 4: 用户跑既有冒烟确认回归**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: `SMOKE OK`，退出 0（`explodes=false` 默认路径未变）。

- [ ] **Step 5: Commit**

```bash
git add Scenes/Weapons/bullet_base.gd Tests/grenade_smoke.gd
git commit -m "feat: BulletBase 爆炸支持 — 命中敌人10+立即炸/撞墙停驻后0.5s引信/超射程兜底"
```

---

### Task 3: 爆炸占位特效 `explosion.tscn`

**Files:**
- Create: `Scenes/Weapons/explosion_placeholder.gd`
- Create: `Scenes/Weapons/explosion.tscn`

**Interfaces:**
- Consumes: `Explosion.make_circle_texture`（Task 1）
- Produces: `res://scenes/Weapons/explosion.tscn`（纯视觉自毁，供 `grenade_bullet.tscn` 的 `explosion_visual` 引用）

- [ ] **Step 1: 写 `explosion_placeholder.gd`**

```gdscript
extends Node2D

# 占位爆炸特效:软圆白贴图放大淡出自毁。不含伤害逻辑(伤害在子弹侧)。
# 用户手绘 FX_Explosion.png 六帧到货后,把本节点换成 AnimatedSprite2D + SpriteFrames,自毁逻辑保留。
func _ready() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = Explosion.make_circle_texture(64)
	sprite.z_index = 5
	add_child(sprite)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sprite, "scale", Vector2(1.6, 1.6), 0.35).from(Vector2(0.4, 0.4))
	tw.tween_property(sprite, "modulate:a", 0.0, 0.35)
	tw.set_parallel(false)
	tw.tween_callback(queue_free)
```

- [ ] **Step 2: 写 `explosion.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scenes/Weapons/explosion_placeholder.gd" id="1_pl"]

[node name="Explosion" type="Node2D"]
script = ExtResource("1_pl")
```

- [ ] **Step 3: 用户跑 import + 冒烟（确认类注册、无解析错）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/grenade_smoke.gd
```
Expected: `GRENADE SMOKE OK`，无报错。

- [ ] **Step 4: Commit**

```bash
git add Scenes/Weapons/explosion_placeholder.gd Scenes/Weapons/explosion_placeholder.gd.uid Scenes/Weapons/explosion.tscn
git commit -m "feat: 爆炸占位特效(程序化软圆放大淡出,自毁;待手绘帧替换)"
```

---

### Task 4: `WeaponBase` 弹道预览 + `bullet_scene` 化

**Files:**
- Modify: `Scenes/Weapons/weapon_base.gd`

**Interfaces:**
- Consumes: `Explosion.make_circle_texture`、`MazeGenerator.cell_of`/`current_grid`/`SOLID`、`GameParameters.gravity0/TILE_SIZE`
- Produces: `bullet_scene`（@export PackedScene，默认 bullet.tscn）、`bullet_gravity`、`preview_arc`、`preview_time`；`fire()` 注入 `gravity_factor`

- [ ] **Step 1: 改常量与字段**

把 `const BULLET_SCENE: PackedScene = preload("res://scenes/Weapons/bullet.tscn")` 改为：
```gdscript
@export var bullet_scene: PackedScene = preload("res://scenes/Weapons/bullet.tscn")
```

在武器参数区新增：
```gdscript
# ── 弹道/预览(榴弹等抛体用)──
# 重力下坠倍率,发射时注入子弹(0=直线)
@export var bullet_gravity: float = 0.0
# true=重武器预瞄画抛物线弧线(取代直线激光);false=原直线激光
@export var preview_arc: bool = false
# 预瞄参考时长(秒),仅供画弧;真实爆炸时机由子弹 fuse_time 决定,预瞄只是参考
@export var preview_time: float = 0.5
```

新增成员（`var player: Node2D` 附近）：
```gdscript
var _explosion_marker: Sprite2D = null
```

- [ ] **Step 2: `_ready` 创建爆点标记**

在 `_ready()` 里、`add_child(_laser)` 之后追加：
```gdscript
	_explosion_marker = Sprite2D.new()
	_explosion_marker.texture = Explosion.make_circle_texture(16)
	_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
	_explosion_marker.visible = false
	add_child(_explosion_marker)
```

- [ ] **Step 3: `fire()` 注入重力**

`fire()` 循环内、`b.setup(...)` 之后加一行：
```gdscript
		b.gravity_factor = bullet_gravity
```

- [ ] **Step 4: 替换 `_update_laser()` + 新增弧线采样**

替换整个 `_update_laser()`：
```gdscript
func _update_laser() -> void:
	if _laser == null or muzzle == null:
		return
	_laser.visible = _aiming
	if not _aiming:
		_update_explosion_marker(false)
		return
	if preview_arc:
		_laser.points = _sample_arc_points()
		_update_explosion_marker(true)
	else:
		_laser.points = PackedVector2Array([muzzle.position, muzzle.position + Vector2(laser_length, 0.0)])
		_update_explosion_marker(false)
```

新增（`_update_laser` 之后）：
```gdscript
# 预瞄抛物线:与 fire 同源(v0=钳制瞄准方向*speed, g=bullet_gravity*gravity0),
# 1/60s 采样到 preview_time,途中遇 SOLID 格截断(榴弹撞墙停驻处 = 爆炸点)。
func _sample_arc_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := muzzle.global_position
	var v := _clamped_aim_dir() * bullet_speed
	var g := bullet_gravity * GameParameters.gravity0
	var dt := 1.0 / 60.0
	var t := 0.0
	pts.append(to_local(p))
	while t < preview_time:
		v.y += g * dt
		p += v * dt
		t += dt
		if _cell_solid_at(p):
			break
		pts.append(to_local(p))
	return pts

func _cell_solid_at(world_pos: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var cell := MazeGenerator.cell_of(world_pos, GameParameters.TILE_SIZE, grid[0].size(), grid.size())
	return grid[cell.y][cell.x] == MazeGenerator.SOLID

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]
```

- [ ] **Step 5: 用户跑既有冒烟确认回归（默认直线武器路径不变）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: `SMOKE OK`，退出 0。

- [ ] **Step 6: Commit**

```bash
git add Scenes/Weapons/weapon_base.gd
git commit -m "feat: WeaponBase — bullet_scene 参数化 + 抛物线预瞄弧线/爆点标记(参考)"
```

---

### Task 5: 榴弹与发射器场景

**Files:**
- Create: `Scenes/Weapons/grenade_visual_placeholder.gd`
- Create: `Scenes/Weapons/grenade_bullet.tscn`
- Create: `Scenes/Weapons/grenade_launcher.tscn`

**Interfaces:**
- Consumes: `bullet_base.gd`（Task 2）、`explosion.tscn`（Task 3）、`weapon_base.gd`（Task 4）
- Produces: `res://scenes/Weapons/grenade_bullet.tscn`、`res://scenes/Weapons/grenade_launcher.tscn`（供 Task 6 注册到 `player.gd`）

- [ ] **Step 1: 写占位圆点脚本 + `grenade_bullet.tscn`**

先写 `Scenes/Weapons/grenade_visual_placeholder.gd`（榴弹占位视觉，用户后画替换）：
```gdscript
extends Sprite2D
func _ready() -> void:
	if texture == null:
		texture = Explosion.make_circle_texture(16)
```

`grenade_bullet.tscn`（Sprite2D 挂占位脚本；子节点 `_ready` 先于父节点，先出纹理再被 bullet_base 上 modulate）：
```
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scenes/Weapons/bullet_base.gd" id="1_bl"]
[ext_resource type="PackedScene" path="res://scenes/Weapons/explosion.tscn" id="2_fx"]
[ext_resource type="Script" path="res://scenes/Weapons/grenade_visual_placeholder.gd" id="3_vis"]

[sub_resource type="CircleShape2D" id="CircleShape2D_g"]
radius = 6.0

[node name="GrenadeBullet" type="CharacterBody2D"]
collision_layer = 0
collision_mask = 5
motion_mode = 1
script = ExtResource("1_bl")
explodes = true
direct_hit_damage = 10
fuse_time = 0.5
explosion_radius = 128.0
explosion_damage = 35
explosion_knockback = 900.0
explosion_visual = ExtResource("2_fx")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture_filter = 1
script = ExtResource("3_vis")

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("CircleShape2D_g")
```

- [ ] **Step 2: 写 `grenade_launcher.tscn`**

```
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scenes/Weapons/weapon_base.gd" id="1_wb"]
[ext_resource type="PackedScene" path="res://scenes/Weapons/grenade_bullet.tscn" id="2_gb"]
[ext_resource type="Texture2D" path="res://AssetBundle/Sprites/Weapons.png" id="3_wpn"]

[node name="GrenadeLauncher" type="Node2D"]
position = Vector2(6, 3)
script = ExtResource("1_wb")
tier = 2
weapon_name = "Grenade Launcher"
fire_cooldown = 1.4
heavy_aim = true
preview_arc = true
bullet_scene = ExtResource("2_gb")
bullet_speed = 1500.0
bullet_range = 2000.0
bullet_gravity = 0.3
damage = 10
recoil_push = 900.0
recoil_kick = 10.0
cam_shake = 8.0
cam_shake_time = 0.2
move_penalty = 0.5
jump_penalty = 0.6
penalty_mode = 2
pitch_clamp_deg = 80.0

[node name="Sprite2D" type="Sprite2D" parent="."]
position = Vector2(18, 6)
texture_filter = 1
texture = ExtResource("3_wpn")
region_enabled = true
region_rect = Rect2(108, 2, 55, 20)

[node name="Muzzle" type="Marker2D" parent="."]
position = Vector2(48, 2)
```

发射器 Sprite2D 复用 `Weapons.png` 步枪区域 `Rect2(108, 2, 55, 20)` 作占位（S686 同款做法），用户后画发射器贴图时替换 region/texture。

- [ ] **Step 3: 用户跑 import 确认两场景解析无错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```
Expected: 无解析/加载错误。

- [ ] **Step 4: Commit**

```bash
git add Scenes/Weapons/grenade_visual_placeholder.gd Scenes/Weapons/grenade_visual_placeholder.gd.uid Scenes/Weapons/grenade_bullet.tscn Scenes/Weapons/grenade_launcher.tscn
git commit -m "feat: 榴弹/榴弹发射器场景(爆炸参数/抛物线弹道/预瞄配置/占位视觉)"
```

---

### Task 6: 第 5 槽接入

**Files:**
- Modify: `project.godot`（`[input]` 加 `"5"`）
- Modify: `Scenes/Player/player.gd`（`WEAPONS` 加 `"5"`、切枪循环加 `"5"`）

- [ ] **Step 1: `project.godot` `[input]` 追加动作 `"5"`**

在现有 `4={...}` 块之后追加（键盘 5，physical_keycode=53）：
```
5={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":53,"key_label":0,"unicode":53,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 2: `player.gd` 注册 + 切枪循环**

`WEAPONS` 字典加一行：
```gdscript
	"4": "res://scenes/Weapons/s686.tscn",
	"5": "res://scenes/Weapons/grenade_launcher.tscn",
```

`_unhandled_input` 切枪循环：
```gdscript
	for slot in ["1", "2", "3", "4", "5"]:
```

- [ ] **Step 3: 用户跑既有冒烟确认无回归**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: `SMOKE OK`。

- [ ] **Step 4: Commit**

```bash
git add project.godot Scenes/Player/player.gd
git commit -m "feat: 第5武器槽接入榴弹发射器(输入动作 5)"
```

---

### Task 7: 收尾验证 + CLAUDE.md 同步

**Files:**
- Modify: `CLAUDE.md`
- Test: 全量冒烟 + playtest（用户执行）

- [ ] **Step 1: 用户跑两个冒烟**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/grenade_smoke.gd
```
Expected: 各自 `SMOKE OK` / `GRENADE SMOKE OK`，退出 0。

- [ ] **Step 2: 用户 playtest（spec §9 清单）**

1. 按 5 切枪 → 按住左键看抛物线弧线 + 末端爆点标记 → 松开发射
2. 榴弹沿弧线下坠，命中敌人 → 10 + 立即爆炸（总 45）
3. 撞墙/落地 → 停驻 0.5s 后才炸（飞行中不炸）
4. 墙后敌人不受伤（LOS 遮挡）；范围内玩家掉血被推（友伤 + 冲击波）
5. 爆炸占位白圆放大淡出（自毁）；榴弹/发射器占位视觉可用
6. 其他武器（1-4）行为不变

- [ ] **Step 3: 更新 `CLAUDE.md`**（大改动后同步，记忆约定）

在「武器与子弹」小节更新：
- 武器列表加：`grenade_launcher.tscn`（第 5 槽，重武器，抛物线预瞄弧线）
- 子弹列表加：`grenade_bullet.tscn`（爆炸弹：命中 10+立即炸 / 撞墙停驻后 0.5s 引信，AoE 分段+LOS 遮挡+友伤）
- 新增一行：爆炸判定在 `Globals/explosion.gd`（`Explosion.apply_aoe`），特效 `explosion.tscn` 占位待手绘帧

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 同步榴弹发射器(第5槽/爆炸弹/Explosion 判定)"
```
