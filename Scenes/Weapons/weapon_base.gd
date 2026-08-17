class_name WeaponBase
extends Node2D

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

const BULLET_SCENE: PackedScene = preload("res://Scenes/Weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长(秒),旧 recoil_time 内联

# ── 武器参数(说明见各参数上方注释)──
# 模板分类(轻/中/重),仅作信息/分组用
@export var tier: Tier = Tier.LIGHT
# 显示名,切枪/识别用
@export var weapon_name: String = "weapon"

# ── 开火 ──
# true=全自动(按住连发);false=半自动(按一下打一发)
@export var full_auto: bool = false
# 两次射击最小间隔(秒),越小射速越快
@export var fire_cooldown: float = 0.2
# true=重武器:按住左键进入激光预瞄,松开才发射
@export var heavy_aim: bool = false

# ── 子弹 ──
# 子弹速度(px/s),越大弹道越直、越难闪避
@export var bullet_speed: float = 900.0
# 子弹射程(px),超过即消失
@export var bullet_range: float = 600.0
# 子弹放大倍数(1.0=场景原始大小;缩放贴图与碰撞体)
@export var bullet_size: float = 1.0
# 子弹贴图染色(白色=原样显示 Bullets.png 贴图;想改子弹颜色就设这里)
@export var bullet_color: Color = Color.WHITE

# ── 伤害 ──
# 命中敌人扣除的 HP
@export var damage: int = 1
# 命中击退力度(>0 会覆盖敌人自身 knockback_strength)
@export var impact: float = 60.0

# ── 后坐/镜头 ──
# 开火把玩家向后推的力度(蹲下时不推)
@export var recoil_push: float = 0.0
# 枪口上跳幅度(枪精灵位移,纯视觉)
@export var recoil_kick: float = 4.0
# 开火镜头抖动幅度
@export var cam_shake: float = 2.0
# 镜头抖动时长(秒)
@export var cam_shake_time: float = 0.1

# ── 移动惩罚 ──
# 惩罚生效期间的水平移速倍率(1.0=不减,0.55=只剩 55%)
@export var move_penalty: float = 1.0
# 惩罚生效期间的跳跃初速倍率(1.0=不减)
@export var jump_penalty: float = 1.0
# 惩罚生效时机:NONE 永不 / WHILE_FIRING 开火后冷却中 / WHILE_AIM_OR_COOLDOWN 预瞄或冷却中
@export var penalty_mode: PenaltyMode = PenaltyMode.NONE

# ── 激光(heavy_aim 用)──
# 预瞄激光线长度(px)
@export var laser_length: float = 600.0
# 激光颜色
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)

# ── 瞄准 ──
# 本枪仰角钳制角(枪口/激光/出弹方向共用)
@export var pitch_clamp_deg: float = 45.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0

var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _aiming: bool = false
var _laser: Line2D = null

# 俯仰角:把面向折进 dir.x,相对水平线求角并钳制到 ±45°。
static func clamp_pitch(dir: Vector2, facing: int, limit_deg: float = 45.0) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(limit_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	_base_sprite_pos = sprite.position
	_laser = Line2D.new()
	_laser.width = 1.0  # 细激光(经玩家 2.5x 缩放渲染约 2.5px)
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
	var dir := _clamped_aim_dir()
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

# 与枪口相同的出弹方向:经过 ±45° 仰角钳制后的世界单位向量(fire 出弹用)。
# local.x 按 facing 折叠,还原到世界坐标时再乘回 facing,与 _auto_aim 的旋转一致。
func _clamped_aim_dir() -> Vector2:
	var facing := get_facing()
	var pitch := clamp_pitch(_aim_world_dir(), facing, pitch_clamp_deg)
	var local := Vector2.from_angle(pitch)
	return Vector2(local.x * float(facing), local.y)

func _auto_aim() -> void:
	var facing: int = get_facing()
	var dir := _aim_world_dir()
	if player != null and player.has_method("set_facing") and absf(dir.x) > 0.1:
		player.set_facing(1 if dir.x > 0.0 else -1)
		facing = get_facing()
	# 朝向镜像(scale.x=-1)会翻转旋转方向。clamp_pitch 已按 facing 折叠 dir.x,
	# 返回值乘 facing 取反:朝左时镜像后的枪口才指向正确的俯仰象限。
	rotation = clamp_pitch(dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)

func _update_laser() -> void:
	if _laser == null or muzzle == null:
		return
	_laser.visible = _aiming
	if _aiming:
		# 激光继承枪口的钳制旋转:仰角限制与枪口一致,且与出弹方向(同样钳制)对齐。
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
	# 用基类 Viewport 而非 SubViewport:冒烟测试把武器挂到 SceneTree 根(Window),
	# 若标 SubViewport 会在运行时类型检查失败(Window≠SubViewport),函数被中断返回零方向。
	var sub: Viewport = get_viewport()
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
