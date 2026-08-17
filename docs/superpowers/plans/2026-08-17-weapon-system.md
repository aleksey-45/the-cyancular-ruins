# 武器系统重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把硬编码的 PlayerGun 重构为独立武器系统：`WeaponBase`/`BulletBase` 基类 + 轻/中/重三把武器场景，玩家用 1/2/3 切枪，伤害/冲击由枪械管理，敌方子弹以后复用同一 BulletBase。

**Architecture:** `Scenes/Weapons/` 新目录存放 `weapon_base.gd`（每把武器一个 .tscn 实例化它）、`bullet_base.gd`（统一子弹，不含伤害，命中回调 `source.apply_hit`）、`bullet.tscn`（通用子弹场景）、三把武器场景。玩家持有 `WeaponSlot`（Node2D），`_equip_weapon()` 释放旧武器、实例化新武器。所有武器参数为场景 `@export`，不再堆在 `GameParameters`。`EnemyBase.hurt` 增加 `knock_strength` 第三参数。用 headless GDScript 冒烟测试 + headless 游戏启动验证。

**Tech Stack:** Godot 4.4 mono, GDScript, 现有 autoload `GameParameters`、`PostProcess`、`MazeGenerator`。headless 冒烟（无单测框架）。

## Global Constraints

- Godot 4.4 mono console exe：`"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe"`（headless 跑冒烟/游戏启动用；工作目录 `E:/Workspace/godot/the-cyancular-ruins`）。
- 冒烟脚本：`Tests/enemy_logic_smoke.gd`，命令：`... --headless --path . -s res://Tests/enemy_logic_smoke.gd`，成功打印 `SMOKE OK` 退出 0。
- 环面世界：`MAP_WIDTH/MAP_HEIGHT` 由地图文件读出（540×324 格 × 16px = 8640×5184）。实体跨接缝锚定玩家副本（`MazeGenerator.anchor_to_nearest`）；无玩家时 `wrap_to_range` 绝对取模。
- 物理层：墙 layer 1；玩家 layer 2 mask 3；敌人 layer 2 mask 1；子弹 layer 0 mask 3；ContactArea mask 2。
- 武器参数全部放各自场景 `@export`；`GameParameters` 只保留 `aim_pitch_deg`。旧 `bullet_*`/`fire_cooldown`/`recoil_*`/`cam_shake*` 常量删除。
- 新增输入动作 `1`/`2`/`3` 为**空动作占位**（`"events": []`），键位由用户在编辑器 Input Map 映射（规范原文：键位由用户映射）。
- 三把武器精灵区域先全部复用现有手枪区域 `Rect2(2, 1.85493, 17.1001, 12.347)`（占位），`Sprite2D.position`/`Muzzle.position`/`region_rect` 之后在编辑器手动调整。
- 子弹不含伤害：命中敌人回调 `source.apply_hit(target, dir)`，由枪械决定伤害/冲击。切枪后旧武器可能被 `free()`，回调前必须 `is_instance_valid(source)` 守卫。
- 旧 `Scenes/player_gun.gd`、`Scenes/bullet.gd`、`Scenes/Bullet.tscn`（及 `.uid`）被吸收删除。
- 提交信息沿用仓库约定（`feat:` / `fix:` / `chore:` / `docs:`）。

### 三把枪起始数值（手感后续调）

| | `pistol_test`(轻) | `rifle_test`(中) | `m82a1`(重) |
|---|---|---|---|
| 开火 | 半自动 | 全自动 | 激光预瞄单发 |
| full_auto / heavy_aim | false / false | true / false | false / true |
| fire_cooldown | 0.12 | 0.25 | 1.2 |
| bullet_speed | 900 | 1200 | 2400 |
| bullet_range | 600 | 1200 | 3000 |
| bullet_size | 5 | 5 | 6 |
| damage | 1 | 2 | 6 |
| impact | 60 | 150 | 500 |
| recoil_push | 0 | 30 | 160 |
| recoil_kick | 4 | 6 | 10 |
| cam_shake / cam_shake_time | 2 / 0.1 | 3 / 0.12 | 8 / 0.2 |
| move/jump_penalty | 1.0 / 1.0 | 0.75 / 0.75 | 0.55 / 0.55 |
| penalty_mode | NONE(0) | WHILE_FIRING(1) | WHILE_AIM_OR_COOLDOWN(2) |
| laser_length / laser_color | — | — | 800 / (1, 0.2, 0.2, 0.6) |

---

### Task 1: Pre-flight — 提交既有基础重构

**Files:**
- 无改动；只提交当前工作区改动。

**Interfaces:**
- 前提：当前工作区的 `MazeGenerator.wrap_to_range`、`PostProcess.crop_scale`、`camera_2d.get_base_global_position`、`EnemyBase._apply_hit` 抽取、玩家姿态枚举等是武器系统的依赖，先落一个 chore 提交，后续武器提交保持干净。

- [ ] **Step 1: 基线冒烟确认当前工作区可运行**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`, exit 0（当前已验证通过）。

- [ ] **Step 2: 提交全部工作区改动**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add -A
git commit -m "chore: wrap/crop/camera-base refactors + player pose enum + wall-merge (weapon-system deps)"
```

Expected: 提交创建；后续任务在干净树上进行。

---

### Task 2: WeaponBase + BulletBase + bullet.tscn + 冒烟改造

**Files:**
- Create: `Scenes/Weapons/weapon_base.gd`
- Create: `Scenes/Weapons/bullet_base.gd`
- Create: `Scenes/Weapons/bullet.tscn`
- Modify: `Tests/enemy_logic_smoke.gd`（子弹场景路径 + setup 新签名 + clamp_pitch 改引用 WeaponBase）

**Interfaces:**
- Produces: `class_name WeaponBase extends Node2D`（`clamp_pitch(dir, facing) -> float` 静态方法、`equip(player)`、`fire()`、`apply_hit(target, dir)`、`cancel_aim()`、`get_movement_multiplier() -> Vector2`）；`class_name BulletBase extends CharacterBody2D`（`setup(dir, speed, range, size, color, source)`、`source` 命中回调、`velocity_vec`）。`Scenes/Weapons/bullet.tscn`（layer 0 / mask 3 / `motion_mode = 1`）。

- [ ] **Step 1: 创建 `Scenes/Weapons/weapon_base.gd`**

```gdscript
class_name WeaponBase
extends Node2D

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

const BULLET_SCENE: PackedScene = preload("res://Scenes/Weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长(秒),旧 recoil_time 内联

@export var tier: Tier = Tier.LIGHT
@export var weapon_name: String = "weapon"
@export var full_auto: bool = false
@export var fire_cooldown: float = 0.2
@export var heavy_aim: bool = false
@export var bullet_speed: float = 900.0
@export var bullet_range: float = 600.0
@export var bullet_size: float = 5.0
@export var bullet_color: Color = Color(1.0, 0.95, 0.6)
@export var damage: int = 1
@export var impact: float = 60.0
@export var recoil_push: float = 0.0
@export var recoil_kick: float = 4.0
@export var cam_shake: float = 2.0
@export var cam_shake_time: float = 0.1
@export var move_penalty: float = 1.0
@export var jump_penalty: float = 1.0
@export var penalty_mode: PenaltyMode = PenaltyMode.NONE
@export var laser_length: float = 500.0
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0

var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _aiming: bool = false
var _laser: Line2D = null

# 俯仰角:把面向折进 dir.x,相对水平线求角并钳制到 ±45°。
static func clamp_pitch(dir: Vector2, facing: int) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(GameParameters.aim_pitch_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	_base_sprite_pos = sprite.position
	_laser = Line2D.new()
	_laser.width = 2.0
	_laser.default_color = laser_color
	_laser.visible = false
	add_child(_laser)

func _player_ok() -> bool:
	return player != null and (not player.has_method("is_downed") or not player.is_downed())

func equip(p: Node2D) -> void:
	player = p
	fire_cd_timer = 0.0
	cancel_aim()

func _process(delta: float) -> void:
	if not _player_ok():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	_auto_aim()
	if heavy_aim:
		_update_laser()
	elif full_auto and Input.is_action_pressed("attack"):
		try_fire()
	_recoil_recover(delta)

func _unhandled_input(event: InputEvent) -> void:
	if not _player_ok():
		return
	if heavy_aim:
		if event.is_action_pressed("attack"):
			_aiming = true
			_update_laser()
		elif event.is_action_released("attack"):
			_aiming = false
			_update_laser()
			try_fire()
		return
	if not full_auto and event.is_action_pressed("attack"):
		try_fire()

func try_fire() -> void:
	if fire_cd_timer > 0.0:
		return
	fire()

func fire() -> void:
	if not _player_ok():
		return
	fire_cd_timer = fire_cooldown
	var dir := _aim_world_dir()
	var b: BulletBase = BULLET_SCENE.instantiate()
	b.setup(dir, bullet_speed, bullet_range, bullet_size, bullet_color, self)
	b.global_position = muzzle.global_position
	get_viewport().add_child(b)
	if player != null and player.has_method("apply_recoil"):
		player.apply_recoil(recoil_push)
	_recoil_timer = RECOIL_TIME
	sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)

# 命中回调:伤害/冲击由枪械管理(BulletBase 不含伤害)。
func apply_hit(target: Node, dir: Vector2) -> void:
	if target != null and target.has_method("hurt"):
		target.hurt(damage, dir, impact)

func cancel_aim() -> void:
	_aiming = false
	if _laser != null:
		_laser.visible = false

func get_movement_multiplier() -> Vector2:
	var active := false
	match penalty_mode:
		PenaltyMode.NONE:
			active = false
		PenaltyMode.WHILE_FIRING:
			active = fire_cd_timer > 0.0
		PenaltyMode.WHILE_AIM_OR_COOLDOWN:
			active = _aiming or fire_cd_timer > 0.0
	if not active:
		return Vector2.ONE
	return Vector2(move_penalty, jump_penalty)

func _auto_aim() -> void:
	var facing: int = get_facing()
	var dir := _aim_world_dir()
	if player != null and player.has_method("set_facing") and absf(dir.x) > 0.1:
		player.set_facing(1 if dir.x > 0.0 else -1)
		facing = get_facing()
	# 朝向镜像(scale.x=-1)会翻转旋转方向。clamp_pitch 已按 facing 折叠 dir.x,
	# 返回值乘 facing 取反:朝左时镜像后的枪口才指向正确的俯仰象限。
	rotation = clamp_pitch(dir, facing) * float(facing)
	scale.x = float(facing)

func _update_laser() -> void:
	if _laser == null or muzzle == null:
		return
	_laser.visible = _aiming
	if _aiming:
		_laser.points = PackedVector2Array([muzzle.position, muzzle.position + Vector2(laser_length, 0.0)])

func _recoil_recover(delta: float) -> void:
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
		sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick * (_recoil_timer / RECOIL_TIME)
		if _recoil_timer == 0.0:
			sprite.position = _base_sprite_pos

# 世界坐标系下从玩家指向鼠标的单位向量(未钳制俯仰)。
func _aim_world_dir() -> Vector2:
	var cam: Camera2D = get_viewport().get_camera_2d()
	var sub: SubViewport = get_viewport()
	if cam == null or sub == null:
		return Vector2(float(get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(get_facing()), 0.0)
	# 窗口鼠标 -> 世界坐标。鼠标用根 Window 的真实坐标(SubViewport 的
	# get_mouse_position 是被 push 进去的窗口坐标,不能直接用)。
	# 相机把屏幕中心映射到 cam.global_position,故 world_mouse =
	# cam.global_position + (鼠标 - 窗口中心) / crop。
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	var crop := PostProcess.crop_scale(win_size, sub.size)
	# 用相机无抖动的基准位置,避免镜头抖动让准星跟着跳
	var cam_center: Vector2 = cam.global_position
	if cam.has_method("get_base_global_position"):
		cam_center = cam.get_base_global_position()
	var world_mouse := cam_center + (mouse - win_size * 0.5) / crop
	var origin := player.global_position if player != null else global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	if player != null and player.has_method("get_facing"):
		return player.get_facing()
	return 1
```

- [ ] **Step 2: 创建 `Scenes/Weapons/bullet_base.gd`**

```gdscript
class_name BulletBase
extends CharacterBody2D

# 子弹只管理物理属性(开火时由武器设置)。不含伤害:命中敌人回调 source.apply_hit。
var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 5.0
var gravity_factor: float = 0.0   # 重力下坠倍率(枪械=0,以后敌方弹药可>0)
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color(1.0, 0.95, 0.6)
var max_range: float = 0.0
var traveled: float = 0.0
var source: Node = null

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	rotation = velocity_vec.angle()

func _ready() -> void:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs != null and cs.shape is CircleShape2D:
		(cs.shape as CircleShape2D).radius = maxf(size, 0.5)
	# 简单发光方块作为子弹贴图(以后可换成 Bullets.png 剪裁)
	var px := int(maxf(size * 2.0, 2.0))
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(bullet_color)
	var sp := Sprite2D.new()
	sp.texture = ImageTexture.create_from_image(img)
	add_child(sp)

func _physics_process(delta: float) -> void:
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		# 切枪后旧武器可能已 free():在途子弹的 source 失效时无害消失。
		if hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			source.apply_hit(hit, velocity_vec)
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()

func _wrap() -> void:
	# 与敌人一致:锚定到离玩家最近的副本(跟着主角取模),接缝附近不消失。
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

> 命名说明：设计文档写的 `gravity_scale` 与 `CharacterBody2D.gravity_scale` 内置属性重名，改用 `gravity_factor`（语义一致）。

- [ ] **Step 3: 创建 `Scenes/Weapons/bullet.tscn`**

```ini
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://Scenes/Weapons/bullet_base.gd" id="1_bl"]

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

（`motion_mode = 1` = floating，子弹不会被地板吸附。）

- [ ] **Step 4: 更新 `Tests/enemy_logic_smoke.gd` 两处**

在文件顶部 `extends SceneTree` 后加 StubPlayer 类（本 Task 先占位，Task 4 用到）：

```gdscript
extends SceneTree

class StubPlayer:
	extends Node2D
	var facing: int = 1
	func get_facing() -> int:
		return facing
	func set_facing(v: int) -> void:
		facing = 1 if v >= 0 else -1
	func is_downed() -> bool:
		return false
	func is_squatting() -> bool:
		return false
	func apply_recoil(_push: float) -> void:
		pass
```

**4a.** 把 `# ── Task 6: 子弹 ──` 段的场景路径与 setup 调用改为新签名（`load("res://Scenes/Bullet.tscn")` → `load("res://Scenes/Weapons/bullet.tscn")`，`b.setup(...)` → 带 size/color/source）：

```gdscript
	# ── Task 6: 子弹 ──
	# 清掉 Task 4 遗留的敌人(在原点,碰撞层2);否则子弹出生即命中并立即消失
	e.free()
	var bscene: PackedScene = load("res://Scenes/Weapons/bullet.tscn")
	_check(bscene != null, "子弹场景加载")
	var b = bscene.instantiate()   # untyped, 不标 BulletBase 避免依赖
	root.add_child(b)
	b.setup(Vector2.RIGHT, 1000.0, 300.0, 5.0, Color(1.0, 0.95, 0.6), null)
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

**4b.** 把 `# ── Task 7: clamp_pitch ──` 段改为引用 `WeaponBase.clamp_pitch`：

```gdscript
	# ── Task 7: clamp_pitch(迁到 WeaponBase)──
	_check(load("res://Scenes/Weapons/weapon_base.gd") != null, "WeaponBase 脚本加载")
	_check(is_equal_approx(WeaponBase.clamp_pitch(Vector2(1, 0), 1), 0.0), "pitch 水平")
	_check(is_equal_approx(WeaponBase.clamp_pitch(Vector2(0, -1), 1), -deg_to_rad(45.0)), "pitch 上钳制")
	_check(is_equal_approx(WeaponBase.clamp_pitch(Vector2(0, 1), 1), deg_to_rad(45.0)), "pitch 下钳制")
	_check(is_equal_approx(WeaponBase.clamp_pitch(Vector2(-1, 0), 1), deg_to_rad(45.0)), "pitch 身后钳制")
	_check(is_equal_approx(WeaponBase.clamp_pitch(Vector2(0, 1), -1), deg_to_rad(45.0)), "pitch 左朝向")
```

- [ ] **Step 5: 运行冒烟**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`, exit 0（旧的 PlayerGun 段已删除，不再加载 player_gun.gd）。

- [ ] **Step 6: Commit**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/Weapons Tests/enemy_logic_smoke.gd Tests/enemy_logic_smoke.gd.uid
git commit -m "feat: WeaponBase/BulletBase + unified bullet scene, smoke updated"
```

（若 Godot 首次导入生成了 `Scenes/Weapons/*.uid`，一并 `git add` 进本提交。）

---

### Task 3: 敌人 hurt 签名扩展（knock_strength）

**Files:**
- Modify: `Scenes/Enemies/enemy_base.gd`
- Modify: `Scenes/Enemies/enemy_jump_bird.gd`

**Interfaces:**
- Produces: `EnemyBase.hurt(damage, knock_dir, knock_strength := 0.0)`；`_apply_hit(damage, knock_dir, knock_strength := 0.0)`，`knock_strength <= 0` 时回落 `knockback_strength`。JumpBird 覆写同步透传。旧两参调用（不传第三参）行为不变。

- [ ] **Step 1: 扩展 `enemy_base.gd` 的 hurt/_apply_hit**

把当前的：

```gdscript
func hurt(damage: int, knock_dir: Vector2) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir)
	if hp <= 0:
		is_dead = true
		queue_free()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
func _apply_hit(damage: int, knock_dir: Vector2) -> void:
	hp -= damage
	velocity += knock_dir.normalized() * knockback_strength
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash
```

替换为：

```gdscript
func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
		is_dead = true
		queue_free()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	velocity += knock_dir.normalized() * ks
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash
```

- [ ] **Step 2: 透传 `enemy_jump_bird.gd` 的 hurt 覆写**

把当前：

```gdscript
func hurt(damage: int, knock_dir: Vector2) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir)
	if hp <= 0:
```

替换为：

```gdscript
func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
```

- [ ] **Step 3: 运行冒烟**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`, exit 0。

- [ ] **Step 4: Commit**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/Enemies/enemy_base.gd Scenes/Enemies/enemy_jump_bird.gd
git commit -m "feat: EnemyBase.hurt accepts knock_strength override"
```

---

### Task 4: 三把武器场景 + 冒烟武器测试

**Files:**
- Create: `Scenes/Weapons/pistol_test.tscn`
- Create: `Scenes/Weapons/rifle_test.tscn`
- Create: `Scenes/Weapons/m82a1.tscn`
- Modify: `Tests/enemy_logic_smoke.gd`（新增武器开火命中测试）

**Interfaces:**
- Consumes: `WeaponBase`、`BulletBase`、`EnemyJumpBird.tscn`；`Weapons.png`（200×200）。
- Produces: 三个 `PackedScene`，各自 `tier`/`weapon_name`/手感参数按 Global Constraints 表；`pistol_test` 默认 `full_auto=false`、`rifle_test` 全自动、`m82a1` 重武器激光预瞄。开火从 `Muzzle` 出子弹命中敌人时扣 `damage`、击退 `impact`。

- [ ] **Step 1: 创建 `Scenes/Weapons/pistol_test.tscn`（轻模板/半自动）**

```ini
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://Scenes/Weapons/weapon_base.gd" id="1_wb"]
[ext_resource type="Texture2D" path="res://AssetBundle/Sprites/Weapons.png" id="2_wpn"]

[node name="PistolTest" type="Node2D"]
script = ExtResource("1_wb")
tier = 0
weapon_name = "Pistol"
full_auto = false
fire_cooldown = 0.12
bullet_speed = 900.0
bullet_range = 600.0
bullet_size = 5.0
damage = 1
impact = 60.0
recoil_push = 0.0
recoil_kick = 4.0
cam_shake = 2.0
cam_shake_time = 0.1
move_penalty = 1.0
jump_penalty = 1.0
penalty_mode = 0

[node name="Sprite2D" type="Sprite2D" parent="."]
position = Vector2(24, 5.6)
texture = ExtResource("2_wpn")
region_enabled = true
region_rect = Rect2(2, 1.85493, 17.1001, 12.347)

[node name="Muzzle" type="Marker2D" parent="."]
position = Vector2(31.6, 2)
```

- [ ] **Step 2: 创建 `Scenes/Weapons/rifle_test.tscn`（中模板/全自动）**

```ini
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://Scenes/Weapons/weapon_base.gd" id="1_wb"]
[ext_resource type="Texture2D" path="res://AssetBundle/Sprites/Weapons.png" id="2_wpn"]

[node name="RifleTest" type="Node2D"]
script = ExtResource("1_wb")
tier = 1
weapon_name = "Rifle"
full_auto = true
fire_cooldown = 0.25
bullet_speed = 1200.0
bullet_range = 1200.0
bullet_size = 5.0
damage = 2
impact = 150.0
recoil_push = 30.0
recoil_kick = 6.0
cam_shake = 3.0
cam_shake_time = 0.12
move_penalty = 0.75
jump_penalty = 0.75
penalty_mode = 1

[node name="Sprite2D" type="Sprite2D" parent="."]
position = Vector2(24, 5.6)
texture = ExtResource("2_wpn")
region_enabled = true
region_rect = Rect2(2, 1.85493, 17.1001, 12.347)

[node name="Muzzle" type="Marker2D" parent="."]
position = Vector2(31.6, 2)
```

- [ ] **Step 3: 创建 `Scenes/Weapons/m82a1.tscn`（重模板/激光预瞄单发）**

```ini
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://Scenes/Weapons/weapon_base.gd" id="1_wb"]
[ext_resource type="Texture2D" path="res://AssetBundle/Sprites/Weapons.png" id="2_wpn"]

[node name="M82A1" type="Node2D"]
script = ExtResource("1_wb")
tier = 2
weapon_name = "M82A1"
full_auto = false
heavy_aim = true
fire_cooldown = 1.2
bullet_speed = 2400.0
bullet_range = 3000.0
bullet_size = 6.0
damage = 6
impact = 500.0
recoil_push = 160.0
recoil_kick = 10.0
cam_shake = 8.0
cam_shake_time = 0.2
move_penalty = 0.55
jump_penalty = 0.55
penalty_mode = 2
laser_length = 800.0
laser_color = Color(1, 0.2, 0.2, 0.6)

[node name="Sprite2D" type="Sprite2D" parent="."]
position = Vector2(24, 5.6)
texture = ExtResource("2_wpn")
region_enabled = true
region_rect = Rect2(2, 1.85493, 17.1001, 12.347)

[node name="Muzzle" type="Marker2D" parent="."]
position = Vector2(31.6, 2)
```

> 三把枪 sprite/muzzle 偏移与 region 均为占位，之后在编辑器手动调整（精灵区域任意裁切即可，用户手动调）。

- [ ] **Step 4: 冒烟新增「武器开火命中敌人」段**

在 `Tests/enemy_logic_smoke.gd` 的 `# ── Task 9: 地图尺寸读取 ──` 段之后、`if _failures.is_empty():` 之前插入：

```gdscript
	# ── Task: 武器场景参数 + 开火命中 ──
	var stub := StubPlayer.new()
	root.add_child(stub)
	stub.global_position = Vector2(400, 400)
	var pistol: PackedScene = load("res://Scenes/Weapons/pistol_test.tscn")
	var rifle: PackedScene = load("res://Scenes/Weapons/rifle_test.tscn")
	var sniper: PackedScene = load("res://Scenes/Weapons/m82a1.tscn")
	_check(pistol != null and rifle != null and sniper != null, "三把武器场景加载")
	var w = pistol.instantiate()
	stub.add_child(w)
	w.equip(stub)
	_check(w is WeaponBase, "武器继承 WeaponBase")
	_check(w.weapon_name == "Pistol", "手枪参数")
	var e_scene: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	var e = e_scene.instantiate()
	root.add_child(e)
	e.global_position = Vector2(520, 400)
	var hp_before: int = e.hp
	w.fire()
	for i in range(30):
		await physics_frame
		if not is_instance_valid(e):
			break
	_check(e.hp == hp_before - w.damage, "子弹命中扣血")
	_check(e.velocity.length() > 0.0, "子弹命中击退")
	e.free()
	stub.free()
```

（`w` 未标类型以便动态取 `weapon_name`/`damage`；无玩家在 `player` 组时 `_aim_world_dir` 回退水平右向，敌人保持 SLEEP 不动，子弹向右命中。）

- [ ] **Step 5: 运行冒烟**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`, exit 0（含「子弹命中扣血」「子弹命中击退」两条 ok）。

- [ ] **Step 6: Commit**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/Weapons Tests/enemy_logic_smoke.gd Tests/enemy_logic_smoke.gd.uid
git commit -m "feat: pistol/rifle/m82a1 weapon scenes + fire-hit smoke test"
```

---

### Task 5: 玩家集成（WeaponSlot / 切枪 / 移速惩罚 / 后坐力 / 输入 / GameParameters 清理）

**Files:**
- Modify: `Scenes/player.gd`
- Modify: `Scenes/Player.tscn`
- Modify: `project.godot`
- Modify: `Globals/gameParameters.gd`
- Modify: `Tests/enemy_logic_smoke.gd`（新增玩家装备/切枪测试）

**Interfaces:**
- Consumes: `WeaponBase`（`get_movement_multiplier`/`equip`/`cancel_aim`）；`pistol_test.tscn`。
- Produces: 玩家字段 `@export weapon_slot: Node2D`、`_weapon: WeaponBase`、`WEAPONS` 注册表、`_equip_weapon(scene_path)`、`apply_recoil(push)`、`is_squatting() -> bool`、`_movement_multiplier() -> Vector2`；`Player.tscn` 含空 `WeaponSlot` 节点；输入动作 `1`/`2`/`3`（空占位）；`GameParameters` 删 `bullet_*`/`fire_cooldown`/`recoil_*`/`cam_shake*` 仅留 `aim_pitch_deg`。

- [ ] **Step 1: 修改 `Scenes/player.gd`**

**1a.** 在 `var downed: bool = false` 之后插入：

```gdscript
@export var weapon_slot: Node2D

# 武器注册表:动作名 -> 场景路径(与 project.godot 输入动作 1/2/3 对应)。
const WEAPONS: Dictionary = {
	"1": "res://Scenes/Weapons/pistol_test.tscn",
	"2": "res://Scenes/Weapons/rifle_test.tscn",
	"3": "res://Scenes/Weapons/m82a1.tscn",
}

var _weapon: WeaponBase = null
```

**1b.** `_ready()` 末尾（`hp_changed.emit(hp, max_hp)` 之后）追加默认装备：

```gdscript
	_equip_weapon(WEAPONS["1"])
```

**1c.** `_physics_process`：在 iframes 闪烁块之后（`modulate.a = 1.0` 之后）加：

```gdscript
	var mult := _movement_multiplier()
```

把跳跃行 `velocity.y = jump_velocity` 改为：

```gdscript
			velocity.y = jump_velocity * mult.y
```

把水平速度行 `var target_velocity_x = horizontal_input * move_speed` 改为：

```gdscript
			var target_velocity_x = horizontal_input * move_speed * mult.x
```

**1d.** 在 `is_downed()` 方法之后、`_downed()` 之前插入：

```gdscript
func _equip_weapon(scene_path: String) -> void:
	if _weapon != null:
		_weapon.queue_free()
	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("weapon scene not found: " + scene_path)
		return
	_weapon = scene.instantiate() as WeaponBase
	weapon_slot.add_child(_weapon)
	_weapon.equip(self)

func _movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

func apply_recoil(push: float) -> void:
	if is_squat:
		return
	velocity.x -= facing_direction * push

func is_squatting() -> bool:
	return is_squat
```

**1e.** `_downed()` 开头（`downed = true` 之后）加：

```gdscript
	if _weapon != null:
		_weapon.cancel_aim()
```

**1f.** `_unhandled_input` 整体替换为：

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if downed:
		if event.is_action_pressed("R"):
			get_tree().reload_current_scene()
		return
	for slot in ["1", "2", "3"]:
		if event.is_action_pressed(slot):
			_equip_weapon(WEAPONS[slot])
			return
```

- [ ] **Step 2: 修改 `Scenes/Player.tscn`**

**2a.** 头部 `load_steps=18` → `load_steps=16`。

**2b.** 删除两行 ext_resource：

```ini
[ext_resource type="Script" uid="uid://cj2jpf4pseeuq" path="res://Scenes/player_gun.gd" id="3_gun"]
[ext_resource type="Texture2D" uid="uid://cfbhunkx3526n" path="res://AssetBundle/Sprites/Weapons.png" id="4_wpn"]
```

**2c.** Player 节点头改为（`node_paths` 加 `weapon_slot`，新增属性）：

```ini
[node name="Player" type="CharacterBody2D" node_paths=PackedStringArray("animator", "weapon_slot")]
scale = Vector2(2.5, 2.5)
collision_layer = 2
collision_mask = 3
script = ExtResource("1_kyqiw")
animator = NodePath("AnimatedSprite2D")
weapon_slot = NodePath("WeaponSlot")
```

**2d.** 删除文件末尾三个节点块：

```ini
[node name="Gun" type="Node2D" parent="."]
script = ExtResource("3_gun")

[node name="Sprite2D" type="Sprite2D" parent="Gun"]
position = Vector2(24, 5.6)
texture = ExtResource("4_wpn")
region_enabled = true
region_rect = Rect2(2, 1.85493, 17.1001, 12.347)

[node name="Muzzle" type="Marker2D" parent="Gun"]
position = Vector2(31.6, 2)
```

并在文件末尾追加：

```ini
[node name="WeaponSlot" type="Node2D" parent="."]
```

- [ ] **Step 3: `project.godot` 加输入动作占位**

在 `R={...}` 块之后、`[rendering]` 之前插入：

```ini
1={
"deadzone": 0.2,
"events": []
}
2={
"deadzone": 0.2,
"events": []
}
3={
"deadzone": 0.2,
"events": []
}
```

> ⚠ 空动作占位：键位由用户在编辑器 Input Map 给 `1`/`2`/`3` 绑定物理键（或本计划 Task 7 手动 playtest 时绑定），否则实机按 1/2/3 不会切枪。

- [ ] **Step 4: 清理 `Globals/gameParameters.gd`**

把当前「── 子弹 ──」和「── 手枪 ──」两个区块：

```gdscript
# ── 子弹 ──
const bullet_damage: int = 1
const bullet_speed: float = 1500.0
const bullet_range: float = 1200.0
const bullet_radius: float = 5.0

# ── 手枪 ──
const fire_cooldown: float = 0.15
const aim_pitch_deg: float = 45.0
const recoil_kick: float = 4.0
const recoil_time: float = 0.06
const cam_shake: float = 2.0
const cam_shake_time: float = 0.1
```

整体替换为：

```gdscript
# ── 武器瞄准(其余武器参数归各武器场景 @export)──
const aim_pitch_deg: float = 45.0
```

- [ ] **Step 5: 冒烟新增「玩家装备/切枪」段**

在 Step 4 的武器测试段之后、`if _failures.is_empty():` 之前插入：

```gdscript
	# ── Task: 玩家装备/切枪 ──
	var player_scene: PackedScene = load("res://Scenes/Player.tscn")
	_check(player_scene != null, "Player 场景加载")
	var p = player_scene.instantiate()
	root.add_child(p)
	await physics_frame
	_check(p._weapon != null, "默认装备手枪")
	if p._weapon != null:
		_check(p._weapon.weapon_name == "Pistol", "默认武器是手枪")
		p._equip_weapon("res://Scenes/Weapons/rifle_test.tscn")
		await physics_frame
		_check(p._weapon.weapon_name == "Rifle", "切枪到步枪")
	p.free()
```

（`p` 未标类型以便动态访问 `_weapon`/调用 `_equip_weapon`。）

- [ ] **Step 6: 运行冒烟 + headless 游戏启动**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 冒烟 `SMOKE OK`；游戏启动无 `SCRIPT ERROR`（`spawned N enemies` 仍打印）。

- [ ] **Step 7: Commit**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/player.gd Scenes/Player.tscn project.godot Globals/gameParameters.gd Tests/enemy_logic_smoke.gd Tests/enemy_logic_smoke.gd.uid
git commit -m "feat: player weapon slot + equip/switch + recoil/move-penalty hooks; GameParameters cleanup"
```

---

### Task 6: 删除旧枪械/子弹文件

**Files:**
- Delete: `Scenes/player_gun.gd`, `Scenes/player_gun.gd.uid`, `Scenes/bullet.gd`, `Scenes/bullet.gd.uid`, `Scenes/Bullet.tscn`

**Interfaces:**
- 前提：Task 2 后冒烟不再引用 `player_gun.gd`/`Bullet.tscn`；Task 5 后 `Player.tscn` 不再引用 `player_gun.gd`。

- [ ] **Step 1: 删除旧文件**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git rm Scenes/player_gun.gd Scenes/player_gun.gd.uid Scenes/bullet.gd Scenes/bullet.gd.uid Scenes/Bullet.tscn
```

- [ ] **Step 2: 验证（冒烟 + 游戏启动）**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 冒烟 `SMOKE OK`（不含 PlayerGun 段）；游戏无脚本错误。

- [ ] **Step 3: Commit**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git commit -m "refactor: remove legacy player_gun/bullet files (absorbed into Weapons/)"
```

---

### Task 7: 集成验证 + 手动 playtest

**Files:**
- Tweak（如需要）: `Globals/gameParameters.gd` / 武器场景参数 / 精灵区域

**Interfaces:**
- 无新接口。确认整条链路端到端可用。

- [ ] **Step 1: 最终 headless 复检**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
"D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
timeout 90 "D:/Program Files/Godot_v4.4.1-stable_mono_win64/Godot_v4.4.1-stable_mono_win64_console.exe" --headless --path . --quit-after 90
```

Expected: `SMOKE OK` + `spawned N enemies` + 无脚本错误。

- [ ] **Step 2: 手动 playtest（用户在 Godot 编辑器跑 `Level0`）**

先在编辑器 **Input Map** 给动作 `1`/`2`/`3` 绑定物理键 1/2/3（空占位需手动映射）。按设计文档「测试与验证」清单核对：

- 默认持手枪（半自动），鼠标瞄准 ±45° 俯仰正常，开火无移速惩罚。
- 按 `2` → 步枪（全自动按住连发），开火期间移速降到 0.75；松开后恢复。
- 按 `3` → M82A1（按住左键显示激光预瞄，松开发射单发），瞄准+冷却期间移速 0.55；切回 `1` 时激光消失（`cancel_aim`）。
- 每把枪子弹命中敌人：扣 `damage`、按 `impact` 击退、白闪、死亡动画/消失；切枪瞬间在途子弹无害消失不报错（`is_instance_valid(source)` 守卫）。
- 倒地（HP 归零）：激光取消、射击停止；按 R 重开。
- 子弹跨环面接缝不消失（锚定玩家副本）；HUD 血条不受 barrel/CRT/变灰影响。
- 三把枪的精灵区域/枪口位置在编辑器手动调整（`Scenes/Weapons/*.tscn` 的 `Sprite2D`/`Muzzle`/`region_rect`）。

- [ ] **Step 3: 按手感调参（如需）**

改各武器 `.tscn` 的 `@export` 数值或 `Globals/gameParameters.gd` 的 `aim_pitch_deg`，然后：

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add -A
git commit -m "feat: tune weapon params after playtest"
```

（若无需调参，跳过本提交。）
