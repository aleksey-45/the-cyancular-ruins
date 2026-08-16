# Enemies + Player Combat of CyR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an enemy system with random spawning and the first enemy type **Jump_Bird**, plus player combat (pistol aiming/shooting, bullets, health, knockback, downed/gray/R-restart, health-bar HUD).

**Architecture:** A shared `EnemyBase` (CharacterBody2D) with behavior hooks, one scene+script per enemy type registered in a spawner type table, a bullet projectile (CharacterBody2D + `move_and_collide`), a `PlayerGun` node that aims via mouse pitch and fires bullets, and player HP/downed state. All tunables in the `GameParameters` autoload. Verified with a headless GDScript smoke test plus headless game runs.

**Tech Stack:** Godot 4.4 mono, GDScript, existing autoload `GameParameters`. Headless verification only (no unit-test framework in the project).

## Global Constraints

- Godot 4.4 mono exe: `"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe"`.
- Toroidal world: `MAP_WIDTH = MAP_HEIGHT = 150 * 16 = 2400 px` (from `GameParameters`).
- Enemies and bullets must be children of `WorldViewport` (they render inside the SubViewport).
- Physics layers: walls stay layer 1; **player layer 2, mask 1**; **enemy layer 2, mask 1**; **bullet layer 0, mask 3**; enemy ContactArea `collision_mask = 2` (detects player). This lets enemies pass through the player (contact damage comes from the Area2D, not body collision).
- No input-map changes: shooting = raw `InputEventMouseButton` (left), restart = raw `KEY_R`. Aim pitch from mouse, clamped ±45°, horizontal locked to `facing_direction`.
- All tunables in `Globals/gameParameters.gd` (existing `const` pattern).
- Jump_Bird sprite frames: top row `t0..t3` (row 0), bottom row `b0..b3` (row 1), 48×48 cells in `AssetBundle/Sprites/Jump_Bird.png`. Sleep = `t0 b3 b2 b1`; wake = `b1 b2 b3 t0`; alert = `t0↔t1`; lunge windup = `t1 t2 t3`; dash = `t3`.
- Commit messages follow repo convention (`feat:` / `fix:` / `chore:` / `docs:`).

---

### Task 1: Pre-flight — commit WIP + feature branch + parameters

**Files:**
- Modify: `godot/the-cyancular-ruins/Globals/gameParameters.gd`

**Interfaces:**
- Produces: the `GameParameters` constants used by every later task (exact names listed in Step 3).

- [ ] **Step 1: Commit the pre-existing WIP (natural-movement game feel) on the current branch**

The working tree has uncommitted changes (the earlier "natural movement 方案 A" work) plus untracked enemy/weapon sprites. Commit only the cyc paths so later feature commits stay clean. The untracked sprites (`Jump_Bird.png`, `Bullets.png`, `Weapons.png`, `Player_.png`) are needed by this feature and must be included:

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/AssetBundle/Sprites/Player.png" \
        "godot/the-cyancular-ruins/AssetBundle/Sprites/Jump_Bird.png" \
        "godot/the-cyancular-ruins/AssetBundle/Sprites/Bullets.png" \
        "godot/the-cyancular-ruins/AssetBundle/Sprites/Weapons.png" \
        "godot/the-cyancular-ruins/AssetBundle/Sprites/Player_.png" \
        "godot/the-cyancular-ruins/docs/superpowers/specs/2026-08-13-natural-movement-design.md" \
        "godot/the-cyancular-ruins/Globals/gameParameters.gd" \
        "godot/the-cyancular-ruins/Globals/maze_generator.gd" \
        "godot/the-cyancular-ruins/Scenes/Level0.tscn" \
        "godot/the-cyancular-ruins/Scenes/Player.tscn" \
        "godot/the-cyancular-ruins/Scenes/camera_2d.gd" \
        "godot/the-cyancular-ruins/Scenes/level_0.gd" \
        "godot/the-cyancular-ruins/Scenes/player.gd" \
        "godot/the-cyancular-ruins/Scenes/post_process.gd" \
        "godot/the-cyancular-ruins/Shaders/post_process.gdshader"
git commit -m "chore: commit WIP natural movement game feel + enemy sprites"
```

Expected: commit created; the AllegScore / `.docx` WIP stays uncommitted (untouched). `.import` files are gitignored (`.gitignore:*.import`) and regenerate automatically.
> Note: if you'd rather keep that WIP uncommitted, stop here and tell the implementer — the rest of the plan assumes a clean tree for `Scenes/` and `Globals/`.

- [ ] **Step 2: Create the feature branch**

```bash
cd "E:/Workspace" && git checkout -b feat/enemies-combat
```

Expected: now on `feat/enemies-combat`.

- [ ] **Step 3: Add the parameters to `gameParameters.gd`**

Insert the following block into `Globals/gameParameters.gd` immediately **before** the line `var MAP_WIDTH: int`:

```gdscript
# ── 敌人系统 ──
const enemy_count: int = 12
const enemy_spawn_min_dist: float = 300.0

# ── Jump_Bird ──
const jb_hp: int = 3
const jb_knockback: float = 150.0
const jb_hit_flash: float = 0.1
const jb_wake_radius: float = 350.0
const jb_give_up_radius: float = 600.0
const jb_lunge_range: float = 130.0
const jb_lunge_max_dist: float = 140.0
const jb_lunge_speed: float = 900.0
const jb_lunge_windup: float = 0.25
const jb_hop_interval: float = 0.55
const jb_hop_horizontal_speed: float = 220.0
const jb_hop_jump_velocity: float = -620.0
const jb_back_hop_up: float = -520.0
const jb_back_hop_away: float = 320.0

# ── 子弹 ──
const bullet_damage: int = 1
const bullet_speed: float = 1000.0
const bullet_range: float = 700.0
const bullet_radius: float = 5.0

# ── 手枪 ──
const fire_cooldown: float = 0.15
const aim_pitch_deg: float = 45.0
const recoil_kick: float = 4.0
const recoil_time: float = 0.06
const cam_shake: float = 2.0
const cam_shake_time: float = 0.1

# ── 玩家战斗 ──
const player_max_hp: int = 5
const iframes_time: float = 1.0
const player_hit_knockback: float = 380.0
const player_hit_knockback_up: float = 200.0

# ── 接触伤害 ──
const enemy_contact_damage: int = 1
```

- [ ] **Step 4: Verify the autoload still parses (headless run)**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . --quit-after 90
```

Expected: exits cleanly with no `SCRIPT ERROR` in output.

- [ ] **Step 5: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Globals/gameParameters.gd"
git commit -m "feat: add enemy/combat/gun/spawn parameters"
```

---

### Task 2: Pure-logic helpers + smoke harness

**Files:**
- Modify: `godot/the-cyancular-ruins/Globals/maze_generator.gd`
- Create: `godot/the-cyancular-ruins/Scenes/Enemies/enemy_spawner.gd`
- Create: `godot/the-cyancular-ruins/Tests/enemy_logic_smoke.gd`

**Interfaces:**
- Produces: `MazeGenerator.toroidal_delta_px(a, b, w, h) -> Vector2`, `EnemySpawner.sample_spawn_cells(grid, player_cell, count, min_dist_cells) -> Array[Vector2i]`, and the smoke script (appended by later tasks).

- [ ] **Step 1: Add `toroidal_delta_px` to `maze_generator.gd`**

Append this static function inside `MazeGenerator` (e.g., right after `toroidal_dist`):

```gdscript
# 像素级环面最短向量:从 a 指向 b(跨接缝取最短)。
static func toroidal_delta_px(a: Vector2, b: Vector2, w: float, h: float) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > w * 0.5:
		dx = -signf(dx) * (w - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > h * 0.5:
		dy = -signf(dy) * (h - absf(dy))
	return Vector2(dx, dy)
```

- [ ] **Step 2: Create `Scenes/Enemies/enemy_spawner.gd`**

```gdscript
class_name EnemySpawner
extends Node2D

# 类型注册表:加新敌人 = 一个 .tscn + 一行(string 路径,load() 时取)。
const TYPES: Dictionary = {
	"jump_bird": "res://Scenes/Enemies/EnemyJumpBird.tscn",
}

# 在 grid 的空位里随机取 count 个、且距 player_cell 的环面距离 >= min_dist_cells 的格子。
static func sample_spawn_cells(grid: Array[Array], player_cell: Vector2i,
		count: int, min_dist_cells: int) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			if grid[y][x] == MazeGenerator.EMPTY:
				empty.append(Vector2i(x, y))
	var chosen: Array[Vector2i] = []
	# `empty.duplicate()` 返回未类型化 Array,pool[i] 的 `:=` 推导会编译失败;显式标注类型
	var pool: Array[Vector2i] = empty.duplicate()
	var attempts := pool.size() * 4
	while chosen.size() < count and attempts > 0 and not pool.is_empty():
		attempts -= 1
		var i := randi() % pool.size()
		var cand := pool[i]
		if MazeGenerator.toroidal_dist(cand, player_cell) >= min_dist_cells:
			chosen.append(cand)
			pool.remove_at(i)
	return chosen
```

- [ ] **Step 3: Create the smoke harness `Tests/enemy_logic_smoke.gd`**

```gdscript
extends SceneTree

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	# ── Task 2: 纯函数 ──
	_check(MazeGenerator.toroidal_delta_px(Vector2(10, 10), Vector2(10, 10), 2400.0, 2400.0) == Vector2.ZERO, "delta 零")
	_check(MazeGenerator.toroidal_delta_px(Vector2(2380, 10), Vector2(20, 10), 2400.0, 2400.0) == Vector2(40, 0), "delta 环面 +x")
	_check(MazeGenerator.toroidal_delta_px(Vector2(20, 10), Vector2(2380, 10), 2400.0, 2400.0) == Vector2(-40, 0), "delta 环面 -x")
	_check(MazeGenerator.toroidal_delta_px(Vector2(100, 100), Vector2(150, 60), 2400.0, 2400.0) == Vector2(50, -40), "delta 普通")
	var grid: Array[Array] = []
	for y in range(10):
		var row: Array[int] = []
		row.resize(10)
		row.fill(MazeGenerator.EMPTY)
		grid.append(row)
	var cells := EnemySpawner.sample_spawn_cells(grid, Vector2i(0, 0), 5, 3)
	_check(cells.size() == 5, "spawn 取 5 格")
	var all_far := true
	for c in cells:
		if MazeGenerator.toroidal_dist(c, Vector2i(0, 0)) < 3:
			all_far = false
	_check(all_far, "spawn 全部满足最小距离")

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)
```

- [ ] **Step 4: Run the smoke, expect PASS**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: prints `SMOKE OK` and exits 0. If `GameParameters` is reported as undeclared under `-s` (autoload quirk), the smoke is fine to keep — this smoke only uses `MazeGenerator`/`EnemySpawner` statics, so it must pass as written.

- [ ] **Step 5: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Globals/maze_generator.gd" \
        "godot/the-cyancular-ruins/Scenes/Enemies" \
        "godot/the-cyancular-ruins/Tests"
git commit -m "feat: toroidal delta + spawn sampling helpers + smoke harness"
```

---

### Task 3: EnemyBase — shared enemy pipeline

**Files:**
- Create: `godot/the-cyancular-ruins/Scenes/Enemies/enemy_base.gd`

**Interfaces:**
- Consumes: `GameParameters.gravity0`, `MAP_WIDTH`, `MAP_HEIGHT`, `jb_knockback`; `MazeGenerator.toroidal_delta_px`.
- Produces: `class_name EnemyBase extends CharacterBody2D` with `hurt(damage, knock_dir)`, `toroidal_dist_to_player()`, `toroidal_dir_to_player()`, behavior hooks `_ai(delta)` / `_anim_update()`, ContactArea that calls `player.take_hit(source_pos, damage)` each physics frame while overlapping.

- [ ] **Step 1: Create `Scenes/Enemies/enemy_base.gd`**

```gdscript
class_name EnemyBase
extends CharacterBody2D

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

@export var hp: int = 3
@export var contact_damage: int = 1
@export var knockback_strength: float = 150.0

var is_dead: bool = false
var _hit_flash_time: float = 0.0
var _player_overlapping: bool = false

# ── 行为钩子(子类覆写)──
func _ai(_delta: float) -> void:
	pass

func _anim_update() -> void:
	pass

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2  # 检测玩家(layer 2)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(44, 40)
	shape.shape = rect
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_contact_body_entered)
	area.body_exited.connect(_on_contact_body_exited)

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = true

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = false

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	_ai(delta)
	_anim_update()
	if _player_overlapping:
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
		if _hit_flash_time == 0.0:
			modulate = Color.WHITE
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2) -> void:
	if is_dead:
		return
	hp -= damage
	velocity += knock_dir.normalized() * knockback_strength
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = GameParameters.jb_hit_flash
	if hp <= 0:
		is_dead = true
		queue_free()

func toroidal_dist_to_player() -> float:
	return toroidal_delta_to_player().length()

func toroidal_dir_to_player() -> Vector2:
	return toroidal_delta_to_player().normalized()

func toroidal_delta_to_player() -> Vector2:
	var p := get_tree().get_first_node_in_group("player")
	if p == null:
		return Vector2.INF
	return MazeGenerator.toroidal_delta_px(global_position, (p as Node2D).global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _wrap() -> void:
	if global_position.x >= GameParameters.MAP_WIDTH:
		global_position.x -= GameParameters.MAP_WIDTH
	elif global_position.x < 0.0:
		global_position.x += GameParameters.MAP_WIDTH
	if global_position.y >= GameParameters.MAP_HEIGHT:
		global_position.y -= GameParameters.MAP_HEIGHT
	elif global_position.y < 0.0:
		global_position.y += GameParameters.MAP_HEIGHT
```

- [ ] **Step 2: Extend the smoke to load-check the base (parse guard)**

Insert **before** the `if _failures.is_empty():` block in `Tests/enemy_logic_smoke.gd`:

```gdscript
	# ── Task 3: EnemyBase 加载 ──
	_check(load("res://Scenes/Enemies/enemy_base.gd") != null, "EnemyBase 脚本加载")
```

- [ ] **Step 3: Run the smoke**

Same command as Task 2 Step 4. Expected: `SMOKE OK`, exit 0.

- [ ] **Step 4: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/Enemies" "godot/the-cyancular-ruins/Tests"
git commit -m "feat: EnemyBase with hp/hurt/knockback/contact/toroidal wrap"
```

---

### Task 4: EnemyJumpBird scene + state machine

**Files:**
- Create: `godot/the-cyancular-ruins/Scenes/Enemies/enemy_jump_bird.gd`
- Create: `godot/the-cyancular-ruins/Scenes/Enemies/EnemyJumpBird.tscn`

**Interfaces:**
- Consumes: `EnemyBase`; `GameParameters.jb_*`; `Jump_Bird.png`.
- Produces: `EnemyJumpBird.tscn` (registered by the spawner in Task 5) with `enum State`; instantiating it yields a SLEEP-state enemy in the `enemies` group.

- [ ] **Step 1: Create `Scenes/Enemies/enemy_jump_bird.gd`**

```gdscript
class_name EnemyJumpBird
extends EnemyBase

enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP }

var state: State = State.SLEEP
var _anim: AnimatedSprite2D
var _state_timer: float = 0.0
var _hop_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_traveled: float = 0.0

func _ready() -> void:
	super._ready()
	knockback_strength = GameParameters.jb_knockback
	hp = GameParameters.jb_hp
	contact_damage = GameParameters.enemy_contact_damage
	_anim = $AnimatedSprite2D
	_build_frames()
	_set_state(State.SLEEP)
	_anim.play("sleep")

# 8 帧:上排 t0..t3(行 0),下排 b0..b3(行 1)
func _build_frames() -> void:
	var tex: Texture2D = load("res://AssetBundle/Sprites/Jump_Bird.png")
	var frames := SpriteFrames.new()
	_add_anim(frames, tex, "sleep", [Vector2i(0, 0), Vector2i(3, 1), Vector2i(2, 1), Vector2i(1, 1)], 3.0, true)
	_add_anim(frames, tex, "wake", [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(0, 0)], 8.0, false)
	_add_anim(frames, tex, "alert", [Vector2i(0, 0), Vector2i(1, 0)], 8.0, true)
	_add_anim(frames, tex, "lunge_windup", [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)], 12.0, false)
	_add_anim(frames, tex, "dash", [Vector2i(3, 0)], 8.0, true)
	_anim.sprite_frames = frames

func _add_anim(frames: SpriteFrames, tex: Texture2D, name: String,
		cells: Array[Vector2i], speed: float, loop: bool) -> void:
	frames.add_animation(name)
	frames.set_animation_loop(name, loop)
	frames.set_animation_speed(name, speed)
	for c in cells:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(c.x * 48.0, c.y * 48.0, 48.0, 48.0)
		frames.add_frame(name, at, 1.0)

func _anim_duration(name: String) -> float:
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)

func _set_state(s: State) -> void:
	state = s
	_state_timer = 0.0

func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)

	match state:
		State.SLEEP:
			_anim.play("sleep")
			if dist <= GameParameters.jb_wake_radius:
				_set_state(State.WAKE)
				_anim.play("wake")
				_state_timer = _anim_duration("wake")
		State.WAKE:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_set_state(State.CHASE)
				_hop_timer = 0.2
		State.CHASE:
			_anim.play("alert")
			if dist > GameParameters.jb_give_up_radius:
				_set_state(State.SLEEP)
				_anim.play("sleep")
			elif dist <= GameParameters.jb_lunge_range:
				_set_state(State.LUNGE_WINDUP)
				_lunge_dir = toroidal_dir_to_player()
				_anim.play("lunge_windup")
				_state_timer = _anim_duration("lunge_windup")
			elif is_on_floor():
				_hop_timer -= delta
				if _hop_timer <= 0.0:
					_hop_timer = GameParameters.jb_hop_interval
					var dir := toroidal_dir_to_player()
					velocity = Vector2(dir.x * GameParameters.jb_hop_horizontal_speed,
							GameParameters.jb_hop_jump_velocity)
		State.LUNGE_WINDUP:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_set_state(State.LUNGE_DASH)
				use_gravity = false
				_lunge_traveled = 0.0
				velocity = _lunge_dir * GameParameters.jb_lunge_speed
				_anim.play("dash")
		State.LUNGE_DASH:
			_lunge_traveled += (velocity * delta).length()
			if _lunge_traveled >= GameParameters.jb_lunge_max_dist or is_on_wall():
				_set_state(State.BACK_HOP)
				use_gravity = true
				velocity = Vector2(-_lunge_dir.x * GameParameters.jb_back_hop_away,
						GameParameters.jb_back_hop_up)
				_back_hop_cd = 0.4
				_anim.play("alert")
		State.BACK_HOP:
			if is_on_floor() and _back_hop_cd <= 0.0:
				_set_state(State.CHASE)
				_hop_timer = 0.15
```

- [ ] **Step 2: Create `Scenes/Enemies/EnemyJumpBird.tscn`**

```ini
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://Scenes/Enemies/enemy_jump_bird.gd" id="1_ej"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_body"]
size = Vector2(30, 26)

[node name="EnemyJumpBird" type="CharacterBody2D"]
collision_layer = 2
collision_mask = 1
scale = Vector2(2.5, 2.5)
script = ExtResource("1_ej")

[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="."]

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("RectangleShape2D_body")
```

(The `ContactArea` is created in code by `EnemyBase._ready`.)

- [ ] **Step 3: Extend the smoke — instantiate the enemy**

Insert **before** the `if _failures.is_empty():` block in `Tests/enemy_logic_smoke.gd`:

```gdscript
	# ── Task 4: 敌人实例化 ──
	var scene: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	_check(scene != null, "JumpBird 场景加载")
	var e = scene.instantiate()
	root.add_child(e)
	await physics_frame
	_check(e is EnemyJumpBird, "JumpBird 实例类型")
	_check(e.state == EnemyJumpBird.State.SLEEP, "初始休眠状态")
	_check(e.is_in_group("enemies"), "加入 enemies 组")
```

- [ ] **Step 4: Run the smoke**

Same command as before. Expected: `SMOKE OK`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/Enemies" "godot/the-cyancular-ruins/Tests"
git commit -m "feat: JumpBird enemy with sleep/wake/chase/lunge state machine"
```

---

### Task 5: Wire the spawner into Level0

**Files:**
- Modify: `godot/the-cyancular-ruins/Scenes/Enemies/enemy_spawner.gd` (add `spawn_all`)
- Modify: `godot/the-cyancular-ruins/Scenes/level_0.gd`
- Modify: `godot/the-cyancular-ruins/Scenes/Level0.tscn`

**Interfaces:**
- Consumes: `sample_spawn_cells`; `EnemyJumpBird.tscn`; `GameParameters.TILE_SIZE`, `enemy_count`, `enemy_spawn_min_dist`.
- Produces: `Level0` spawns the configured number of enemies at start, each in the `enemies` group.

- [ ] **Step 1: Add `spawn_all` to `enemy_spawner.gd`**

Append inside `EnemySpawner` (after `sample_spawn_cells`):

```gdscript
# Level0._ready 里调用。敌人加入 WorldViewport 子节点(与墙壁/玩家同空间)。
func spawn_all(grid: Array[Array], player_pos: Vector2) -> void:
	var world := get_parent().get_node("WorldViewport")
	var ts: int = GameParameters.TILE_SIZE
	var min_dist_cells := int(GameParameters.enemy_spawn_min_dist / ts)
	var player_cell := Vector2i(int(player_pos.x / ts), int(player_pos.y / ts))
	var cells := sample_spawn_cells(grid, player_cell,
			GameParameters.enemy_count, min_dist_cells)
	var type_names := TYPES.keys()
	for c in cells:
		var type_name: String = type_names[randi() % type_names.size()]
		var scene: PackedScene = load(TYPES[type_name])
		var e := scene.instantiate()
		world.add_child(e)
		e.global_position = Vector2(c.x * ts + ts / 2.0, c.y * ts + ts / 2.0)
	print("[EnemySpawner] spawned %d enemies" % cells.size())
```

- [ ] **Step 2: Add the `EnemySpawner` node to `Level0.tscn`**

In `Scenes/Level0.tscn`, change `load_steps=4` to `load_steps=6`, add this ext_resource after the existing three:

```ini
[ext_resource type="Script" path="res://Scenes/Enemies/enemy_spawner.gd" id="4_spn"]
```

And append these nodes at the end of the file:

```ini
[node name="EnemySpawner" type="Node2D" parent="."]
script = ExtResource("4_spn")
```

- [ ] **Step 3: Call the spawner in `level_0.gd`**

After the `_place_player(grid)` line in `_ready()`:

```gdscript
	_place_player(grid)
	$EnemySpawner.spawn_all(grid, $WorldViewport/Player.global_position)
```

- [ ] **Step 4: Verify enemies spawn headlessly**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . --quit-after 90
```

Expected: prints `[EnemySpawner] spawned 12 enemies` (or the current `enemy_count`) and no script errors. Also rerun the smoke (Task 2 command) — still `SMOKE OK`.

- [ ] **Step 5: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/Enemies/enemy_spawner.gd" \
        "godot/the-cyancular-ruins/Scenes/Enemies/enemy_spawner.gd.uid" \
        "godot/the-cyancular-ruins/Scenes/level_0.gd" \
        "godot/the-cyancular-ruins/Scenes/level_0.gd.uid" \
        "godot/the-cyancular-ruins/Scenes/Level0.tscn"
git commit -m "feat: enemy spawner wired into Level0"
```

(If the `.uid` files don't exist yet, Godot will generate them on the first import; `git add` the directory if the file list looks different.)

---

### Task 6: Bullet projectile

**Files:**
- Create: `godot/the-cyancular-ruins/Scenes/bullet.gd`
- Create: `godot/the-cyancular-ruins/Scenes/Bullet.tscn`

**Interfaces:**
- Consumes: `GameParameters.bullet_*`; groups `enemies` (from `EnemyBase`).
- Produces: `class_name Bullet extends CharacterBody2D` with `setup(dir: Vector2, speed: float, range: float, damage: int)`; hits enemies via `hurt()`, despawns on wall / range; wraps on the torus.

- [ ] **Step 1: Create `Scenes/bullet.gd`**

```gdscript
class_name Bullet
extends CharacterBody2D

var velocity_vec: Vector2 = Vector2.ZERO
var damage: int = 1
var max_range: float = 700.0
var traveled: float = 0.0

func setup(dir: Vector2, speed: float, range: float, dmg: int) -> void:
	velocity_vec = dir.normalized() * speed
	max_range = range
	damage = dmg
	rotation = velocity_vec.angle()

func _ready() -> void:
	# 简单发光方块作为子弹贴图(以后可换成 Bullets.png 剪裁)
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.95, 0.6))
	var sp := Sprite2D.new()
	sp.texture = ImageTexture.create_from_image(img)
	add_child(sp)

func _physics_process(delta: float) -> void:
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if hit.is_in_group("enemies") and hit.has_method("hurt"):
			hit.hurt(damage, velocity_vec)
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()

func _wrap() -> void:
	if global_position.x >= GameParameters.MAP_WIDTH:
		global_position.x -= GameParameters.MAP_WIDTH
	elif global_position.x < 0.0:
		global_position.x += GameParameters.MAP_WIDTH
	if global_position.y >= GameParameters.MAP_HEIGHT:
		global_position.y -= GameParameters.MAP_HEIGHT
	elif global_position.y < 0.0:
		global_position.y += GameParameters.MAP_HEIGHT
```

- [ ] **Step 2: Create `Scenes/Bullet.tscn`**

```ini
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://Scenes/bullet.gd" id="1_bl"]

[sub_resource type="CircleShape2D" id="CircleShape2D_bullet"]
radius = 5.0

[node name="Bullet" type="CharacterBody2D"]
collision_layer = 0
collision_mask = 3
motion_mode = 1
script = ExtResource("1_bl")

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("CircleShape2D_bullet")
```

(`motion_mode = 1` = floating, so the bullet never snaps to floors.)

- [ ] **Step 3: Extend the smoke — bullet movement + range despawn**

Insert **before** the `if _failures.is_empty():` block:

```gdscript
	# ── Task 6: 子弹 ──
	var bscene: PackedScene = load("res://Scenes/Bullet.tscn")
	_check(bscene != null, "子弹场景加载")
	var b: Bullet = bscene.instantiate()
	root.add_child(b)
	b.setup(Vector2.RIGHT, 1000.0, 300.0, 1)
	await physics_frame
	_check(b.global_position.x > 0.0, "子弹移动")
	var freed := false
	for i in range(40):
		await physics_frame
		if not is_instance_valid(b):
			freed = true
			break
	_check(freed, "子弹超射程消失")
```

- [ ] **Step 4: Run the smoke**

Same command. Expected: `SMOKE OK`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/bullet.gd" \
        "godot/the-cyancular-ruins/Scenes/bullet.gd.uid" \
        "godot/the-cyancular-ruins/Scenes/Bullet.tscn" \
        "godot/the-cyancular-ruins/Tests"
git commit -m "feat: bullet projectile with range/wall-hit/toroidal wrap"
```

---

### Task 7: Player pistol — aiming, shooting, recoil + camera shake

**Files:**
- Create: `godot/the-cyancular-ruins/Scenes/player_gun.gd`
- Modify: `godot/the-cyancular-ruins/Scenes/Player.tscn`
- Modify: `godot/the-cyancular-ruins/Scenes/camera_2d.gd`

**Interfaces:**
- Consumes: `Bullet` scene; `GameParameters.fire_cooldown`, `aim_pitch_deg`, `recoil_*`, `cam_shake*`, `bullet_*`.
- Produces: `class_name PlayerGun extends Node2D` with `static clamp_pitch(dir, facing) -> float`; player method `get_facing() -> int` (added in Task 8) and `is_downed() -> bool` (Task 8) — the gun guards on them defensively via `has_method`.

- [ ] **Step 1: Create `Scenes/player_gun.gd`**

```gdscript
class_name PlayerGun
extends Node2D

const BULLET_SCENE: PackedScene = preload("res://Scenes/Bullet.tscn")

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0
var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO

# 俯仰角:把面向折进 dir.x,相对水平线求角并钳制到 ±45°。
static func clamp_pitch(dir: Vector2, facing: int) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(GameParameters.aim_pitch_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	player = get_parent() as Node2D
	_base_sprite_pos = sprite.position

func _process(delta: float) -> void:
	if player != null and player.has_method("is_downed") and player.is_downed():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	var facing: int = 1
	if player != null and player.has_method("get_facing"):
		facing = player.get_facing()
	rotation = _aim_angle()
	scale.x = float(facing)
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
		sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * GameParameters.recoil_kick * (_recoil_timer / GameParameters.recoil_time)
		if _recoil_timer == 0.0:
			sprite.position = _base_sprite_pos

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		fire()

func fire() -> void:
	if fire_cd_timer > 0.0:
		return
	fire_cd_timer = GameParameters.fire_cooldown
	var dir := (global_transform * Vector2(1.0, 0.0)).normalized()
	var b: Bullet = BULLET_SCENE.instantiate()
	b.setup(dir, GameParameters.bullet_speed, GameParameters.bullet_range, GameParameters.bullet_damage)
	b.global_position = muzzle.global_position
	get_parent().get_parent().add_child(b)  # 加入 WorldViewport
	_recoil_timer = GameParameters.recoil_time
	sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * GameParameters.recoil_kick
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(GameParameters.cam_shake, GameParameters.cam_shake_time)

func _aim_angle() -> float:
	var facing: int = 1
	if player != null and player.has_method("get_facing"):
		facing = player.get_facing()
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam == null:
		return 0.0
	var sub: SubViewport = get_viewport()
	var win: Viewport = sub.get_parent_viewport()
	if win == null:
		return 0.0
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	var crop := Vector2(win_size.x / sub.size.x, win_size.y / sub.size.y)
	var world_mouse := cam.global_position + (mouse - win_size * 0.5) / crop
	var dir := world_mouse - (get_parent() as Node2D).global_position
	return clamp_pitch(dir, facing)
```

- [ ] **Step 2: Modify `Player.tscn`**

Change `load_steps=17` to `load_steps=19`. Add these ext_resources after the existing two:

```ini
[ext_resource type="Script" path="res://Scenes/player_gun.gd" id="3_gun"]
[ext_resource type="Texture2D" path="res://AssetBundle/Sprites/Weapons.png" id="4_wpn"]
```

Add `collision_layer = 2` to the `[node name="Player" type="CharacterBody2D"]` block (keeps `collision_mask` default 1 → collides with walls, not enemies):

```ini
[node name="Player" type="CharacterBody2D" node_paths=PackedStringArray("animator")]
scale = Vector2(2.5, 2.5)
collision_layer = 2
script = ExtResource("1_kyqiw")
animator = NodePath("AnimatedSprite2D")
```

Append the gun subtree at the end of the file:

```ini
[node name="Gun" type="Node2D" parent="Player"]
script = ExtResource("3_gun")

[node name="Sprite2D" type="Sprite2D" parent="Player/Gun"]
position = Vector2(12, -6)
texture = ExtResource("4_wpn")
region_enabled = true
region_rect = Rect2(2, 1, 46, 16)

[node name="Muzzle" type="Marker2D" parent="Player/Gun"]
position = Vector2(28, -6)
```

- [ ] **Step 3: Add camera shake to `camera_2d.gd`**

Add these vars near the top of the class:

```gdscript
var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0

func shake(amount: float, duration: float) -> void:
	_shake_amt = amount
	_shake_time = duration
	_shake_dur = duration
```

Replace the end of `_process` (after the two `global_position` lines) with:

```gdscript
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * (_shake_time / maxf(_shake_dur, 0.0001))
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt
```

- [ ] **Step 4: Extend the smoke — `clamp_pitch`**

Insert **before** the `if _failures.is_empty():` block:

```gdscript
	# ── Task 7: clamp_pitch ──
	_check(is_equal_approx(PlayerGun.clamp_pitch(Vector2(1, 0), 1), 0.0), "pitch 水平")
	_check(is_equal_approx(PlayerGun.clamp_pitch(Vector2(0, -1), 1), -deg_to_rad(45.0)), "pitch 上钳制")
	_check(is_equal_approx(PlayerGun.clamp_pitch(Vector2(0, 1), 1), deg_to_rad(45.0)), "pitch 下钳制")
	_check(is_equal_approx(PlayerGun.clamp_pitch(Vector2(-1, 0), 1), deg_to_rad(45.0)), "pitch 身后钳制")
	_check(is_equal_approx(PlayerGun.clamp_pitch(Vector2(0, 1), -1), deg_to_rad(45.0)), "pitch 左朝向")
```

- [ ] **Step 5: Run smoke + headless game run**

Smoke (Task 2 command): `SMOKE OK`.
Headless game run (Task 5 Step 4 command): no script errors; `spawned 12 enemies` still prints.

- [ ] **Step 6: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/player_gun.gd" \
        "godot/the-cyancular-ruins/Scenes/player_gun.gd.uid" \
        "godot/the-cyancular-ruins/Scenes/Player.tscn" \
        "godot/the-cyancular-ruins/Scenes/camera_2d.gd" \
        "godot/the-cyancular-ruins/Tests"
git commit -m "feat: player pistol aiming/shooting + camera shake"
```

---

### Task 8: Player HP, downed state, HUD, gray post-process, R-restart

**Files:**
- Modify: `godot/the-cyancular-ruins/Scenes/player.gd`
- Create: `godot/the-cyancular-ruins/Scenes/hud.gd`
- Modify: `godot/the-cyancular-ruins/Scenes/Level0.tscn`
- Modify: `godot/the-cyancular-ruins/Scenes/post_process.gd`
- Modify: `godot/the-cyancular-ruins/Shaders/post_process.gdshader`

**Interfaces:**
- Consumes: `EnemyBase` contact (`take_hit(source_pos, damage)`); `GameParameters.player_max_hp`, `iframes_time`, `player_hit_knockback*`, `enemy_contact_damage`.
- Produces: player methods `take_hit(source_pos, damage)`, `get_facing() -> int`, `is_downed() -> bool`, signal `hp_changed(current, max)`; HUD consumes that signal; post-process `set_downed(bool)`.

- [ ] **Step 1: Add HP / downed state to `player.gd`**

Add fields and the signal near the other `var` declarations (e.g., after `var charge_timer: float = 0.0`):

```gdscript
# ── 战斗 ──
var max_hp: int = GameParameters.player_max_hp
var hp: int = GameParameters.player_max_hp
var iframes: float = 0.0
var downed: bool = false

signal hp_changed(current: int, max: int)
```

At the end of `_ready()` (after the collision-shape setup), emit the initial HUD value:

```gdscript
	hp_changed.emit(hp, max_hp)
```

Guard the top of `_physics_process` — insert immediately after `func _physics_process(delta: float) -> void:` and its blank line:

```gdscript
	if downed:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	iframes = maxf(iframes - delta, 0.0)
	# 无敌帧闪烁
	if iframes > 0.0:
		modulate.a = 0.4 if int(iframes * 10) % 2 == 0 else 1.0
	else:
		modulate.a = 1.0
```

Append these methods to the class (after `_physics_process`):

```gdscript
func take_hit(source_pos: Vector2, damage: int) -> void:
	if downed or iframes > 0.0:
		return
	hp -= damage
	iframes = GameParameters.iframes_time
	var away := (global_position - source_pos).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(facing_direction), 0.0)
	velocity.x = away.x * GameParameters.player_hit_knockback
	velocity.y = away.y * GameParameters.player_hit_knockback - GameParameters.player_hit_knockback_up
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

func get_facing() -> int:
	return facing_direction

func is_downed() -> bool:
	return downed

func _downed() -> void:
	downed = true
	velocity = Vector2.ZERO
	rotation = -PI / 2.0 * float(facing_direction)
	if animator != null:
		animator.stop()
	var pp := get_tree().get_first_node_in_group("post_process")
	if pp != null and pp.has_method("set_downed"):
		pp.set_downed(true)

func _unhandled_input(event: InputEvent) -> void:
	if downed and event is InputEventKey and event.pressed and event.keycode == KEY_R:
		get_tree().reload_current_scene()
```

- [ ] **Step 2: Create `Scenes/hud.gd`**

```gdscript
class_name HUD
extends CanvasLayer

const BAR_W: int = 220
const BAR_H: int = 18
const MARGIN: int = 24

var _fill: ColorRect

func _ready() -> void:
	layer = 129  # 在 post-process(128)之上,不受桶形/CRT/变灰影响
	var bg := ColorRect.new()
	bg.position = Vector2(MARGIN, MARGIN)
	bg.size = Vector2(BAR_W, BAR_H)
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	add_child(bg)
	_fill = ColorRect.new()
	_fill.position = Vector2(MARGIN + 2, MARGIN + 2)
	_fill.size = Vector2(BAR_W - 4, BAR_H - 4)
	_fill.color = Color(0.35, 0.85, 0.35)
	add_child(_fill)
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_signal("hp_changed"):
		p.hp_changed.connect(_on_hp)
		_on_hp(p.hp, p.max_hp)

func _on_hp(cur: int, max_hp: int) -> void:
	var ratio := float(cur) / float(max(1, max_hp))
	_fill.size.x = (BAR_W - 4) * ratio
	_fill.color = Color(0.85, 0.25, 0.2) if ratio < 0.3 else Color(0.35, 0.85, 0.35)
```

- [ ] **Step 3: Add the HUD node to `Level0.tscn`**

Change `load_steps=6` to `load_steps=7`, add this ext_resource (after `id="4_spn"`):

```ini
[ext_resource type="Script" path="res://Scenes/hud.gd" id="5_hud"]
```

Append the node:

```ini
[node name="HUD" type="CanvasLayer" parent="."]
script = ExtResource("5_hud")
```

- [ ] **Step 4: Add gray-screen support to the post-process**

In `Shaders/post_process.gdshader`, add the uniform after `crop_scale`:

```gdshader
uniform float desat : hint_range(0.0, 1.0) = 0.0;
```

And replace the final line `COLOR = texture(screen_tex, uv);` with:

```gdshader
	COLOR = texture(screen_tex, uv);
	if (desat > 0.0) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(COLOR.rgb, vec3(g), desat);
	}
```

In `Scenes/post_process.gd`:

- In `_ready()`, add `add_to_group("post_process")` as the first line.
- Append the method:

```gdscript
func set_downed(v: bool) -> void:
	if _mat:
		_mat.set_shader_parameter("desat", 1.0 if v else 0.0)
```

- [ ] **Step 5: Verify (headless game run)**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . --quit-after 90
```

Expected: no script errors; `spawned 12 enemies` still prints. Also rerun the smoke — `SMOKE OK`.

- [ ] **Step 6: Commit**

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Scenes/player.gd" \
        "godot/the-cyancular-ruins/Scenes/hud.gd" \
        "godot/the-cyancular-ruins/Scenes/hud.gd.uid" \
        "godot/the-cyancular-ruins/Scenes/Level0.tscn" \
        "godot/the-cyancular-ruins/Scenes/post_process.gd" \
        "godot/the-cyancular-ruins/Shaders/post_process.gdshader"
git commit -m "feat: player hp/downed state + hud + gray post-process"
```

---

### Task 9: Integration — manual verification + parameter polish

**Files:**
- Tweak: `godot/the-cyancular-ruins/Globals/gameParameters.gd` (if playtest shows a value needs tuning)

**Interfaces:**
- No new interfaces. Confirms the whole loop works end to end.

- [ ] **Step 1: Final headless sanity**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64.exe" --headless --path . --quit-after 90
```

Expected: `SMOKE OK` + `spawned 12 enemies` + no script errors.

- [ ] **Step 2: Manual playtest (user runs the Godot editor)**

Open the project in Godot and play `Level0`. Verify the spec checklist:

- 12 enemies spawn at random empty cells, none within ~300px of the player.
- Sleep → (walk near) wake animation → flashing idle → jump chase → lunge (windup `t1 t2 t3` + capped dash) → always a back-hop → re-evaluate.
- Walking far away makes the enemy give up and return to sleep.
- Shoot: bullet from the muzzle at the mouse pitch (clamped ±45°), kills in 3 hits (white flash + knockback + `queue_free`), despawns on walls / at range.
- Take contact damage: i-frames + blink + knockback + health bar drops; low-HP bar turns red.
- At 0 HP: player rotates 90° backward, screen goes gray, controls freeze; press R → level restarts.
- Enemies and bullets wrap across the torus seam; HUD bar unaffected by barrel/CRT/gray.
- Gun recoil kick + small camera shake on fire; firing never affects movement speed.

- [ ] **Step 3: Tune parameters if needed**

Edit `Globals/gameParameters.gd` values (counts, radii, speeds, knockbacks) based on feel. Commit:

```bash
cd "E:/Workspace"
git add "godot/the-cyancular-ruins/Globals/gameParameters.gd"
git commit -m "feat: tune enemy/combat parameters after playtest"
```

(If no tuning was needed, skip this commit.)
