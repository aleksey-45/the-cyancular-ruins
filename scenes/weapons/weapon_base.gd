class_name WeaponBase
extends Node2D

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

@export var bullet_scene: PackedScene = preload("res://scenes/weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长（秒）
# 预瞄射线检测碰撞半径（像素）
const PREVIEW_COLLISION_RADIUS: float = 4.0

# ── 武器参数 ──
# 武器重量级别（轻型/中型/重型），用于背包占用与分类
@export var tier: Tier = Tier.LIGHT
# 武器显示名称
@export var weapon_name: String = "weapon"

# ── 开火机制 ──
# 是否为全自动（按住持续射击；false 为半自动，单次点击单发射击）
@export var full_auto: bool = false
# 射击间隔冷却时间（秒）
@export var fire_cooldown: float = 0.2
# 是否为蓄力/预瞄重武器（按住显示瞄准轨迹，松开时发射）
@export var heavy_aim: bool = false

# ── 子弹参数 ──
# 子弹飞行初速度（像素/秒）
@export var bullet_speed: float = 900.0
# 子弹最大飞行射程（像素）
@export var bullet_range: float = 600.0
# 子弹缩放倍率（缩放精灵与碰撞体）
@export var bullet_size: float = 1.0
# 子弹着色调色（Color.WHITE 为默认材质原色）
@export var bullet_color: Color = Color.WHITE

# ── 霰弹与散射 ──
# 单次射击发射的弹丸数量
@export var pellet_count: int = 1
# 散射半角（度）：每颗弹丸在瞄准方向两侧的随机偏移角度
@export var spread_deg: float = 0.0

# ── 伤害与击退 ──
# 命中造成的生命值伤害
@export var damage: int = 1
# 命中造成的击退力度
@export var impact: float = 60.0

# 同屏存活弹丸数量上限（0 为不限制）
@export var max_live_projectiles: int = 0

# ── 后坐力与镜头 ──
# 开火时推退角色的后坐力度（下蹲时不触发）
@export var recoil_push: float = 0.0
# 枪口上跳位移幅度（像素）
@export var recoil_kick: float = 4.0
# 开火触发镜头抖动幅度
@export var cam_shake: float = 2.0
# 镜头抖动持续时长（秒）
@export var cam_shake_time: float = 0.1

# ── 移速惩罚 ──
# 惩罚生效期间的水平移速倍率（1.0 为不惩罚）
@export var move_penalty: float = 1.0
# 惩罚生效期间的跳跃初速度倍率（1.0 为不惩罚）
@export var jump_penalty: float = 1.0
# 惩罚生效模式：NONE 不生效 / WHILE_FIRING 开火冷却期间 / WHILE_AIM_OR_COOLDOWN 瞄准或冷却期间
@export var penalty_mode: PenaltyMode = PenaltyMode.NONE

# ── 激光瞄准 ──
# 预瞄激光射线长度（像素）
@export var laser_length: float = 600.0
# 激光射线颜色
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)

# ── 瞄准限制 ──
# 武器最大仰角与俯角限制（度）
@export var pitch_clamp_deg: float = 45.0

# ── 弹道与抛物线 ──
# 重力加速度影响倍率（0 为直线弹道）
@export var bullet_gravity: float = 0.0
# 是否显示抛物线弹道预瞄（true 为抛物线弧线，false 为直线激光）
@export var preview_arc: bool = false
# 预瞄抛物线采样时长（秒）
@export var preview_time: float = 0.5

# ── 换弹与弹夹 ──
@export var mag_size: int = 12        # 弹夹容量
@export var reload_time: float = 1.2  # 换弹全程耗时（秒）
var mag_ammo: int = 0                 # 弹夹内残弹
# 待生效残弹哨兵值（-2 表示尚未设置）
const MAG_UNSET := -2
var pending_mag: int = MAG_UNSET
# 弹药状态是否已初始化完成
var _mag_ready := false
var _reloading := false
var _reload_t := 0.0
var _reload_pose := false             # 换弹下压姿势生效中

# 换弹动画参数
const RELOAD_TILT := 0.9                    # 枪口下压最大弧度
const RELOAD_OFFSET := Vector2(-3.0, 7.0)   # 精灵同步下沉偏移量

func is_reloading() -> bool:
	return _reloading

# 换弹进度 0 到 1（未换弹时返回 -1.0，供 HUD 进度条使用）
func reload_progress() -> float:
	return (1.0 - _reload_t / maxf(reload_time, 0.01)) if _reloading else -1.0

func start_reload() -> void:
	if not _mag_ready:
		return
	if _reloading or mag_ammo >= mag_size:
		return
	_reloading = true
	_reload_t = reload_time
	Sfx.play("reload")

# 换弹姿态：每帧在 _recoil_recover 之后调用（换弹压枪优先级高于后坐复位）
func _update_reload_pose() -> void:
	if sprite == null:
		return
	if _reloading:
		_reload_pose = true
		var p := clampf(1.0 - _reload_t / maxf(reload_time, 0.01), 0.0, 1.0)
		var k := sin(p * PI)
		var jiggle := sin(p * 34.0) * 1.2 * k
		sprite.rotation = RELOAD_TILT * k
		sprite.position = _base_sprite_pos + RELOAD_OFFSET * k + Vector2(jiggle, 0.0)
	elif _reload_pose:
		_reload_pose = false
		sprite.rotation = 0.0
		sprite.position = _base_sprite_pos

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0

var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _aiming: bool = false
var _fire_buffered: bool = false
var _aim_facing: int = 1          # 上次记录的有效水平瞄准朝向
var _current_aim_facing: int = 1  # 本帧实际生效的水平瞄准朝向
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

# 俯仰角限制：根据角色水平朝向折叠计算，并限制在指定角度范围内
static func clamp_pitch(dir: Vector2, facing: int, limit_deg: float = 45.0) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(limit_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	mag_ammo = mag_size
	if pending_mag != MAG_UNSET:
		mag_ammo = clampi(pending_mag, 0, mag_size)
		pending_mag = MAG_UNSET
	_mag_ready = true
	_base_sprite_pos = sprite.position
	_laser = Line2D.new()
	_laser.width = 1.0
	_laser.default_color = laser_color
	_laser.visible = false
	call_deferred("add_child", _laser)
	_explosion_marker = Sprite2D.new()
	_explosion_marker.texture = Explosion.make_circle_texture(16)
	_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
	_explosion_marker.visible = false
	call_deferred("add_child", _explosion_marker)

func _player_ok() -> bool:
	return player != null and (not player.has_method("is_downed") or not player.is_downed())

# 攻击输入查询：优先读取角色节点的注入输入，若不存在则回退至原生 Input
func _attack_pressed() -> bool:
	if player != null and player.has_method("is_attack_pressed"):
		return player.is_attack_pressed()
	return Input.is_action_pressed("attack")

func _attack_just_pressed() -> bool:
	if player != null and player.has_method("is_attack_just_pressed"):
		return player.is_attack_just_pressed()
	return Input.is_action_just_pressed("attack")

func _attack_just_released() -> bool:
	if player != null and player.has_method("is_attack_just_released"):
		return player.is_attack_just_released()
	return Input.is_action_just_released("attack")

func equip(p: Node2D, inherit_cooldown: float = 0.0) -> void:
	player = p
	# 继承前一把武器的剩余冷却时间，防止通过快速切枪跳过后摇
	fire_cd_timer = maxf(inherit_cooldown, 0.0)
	_fire_buffered = false
	cancel_aim()

# 武器物理逻辑由所属角色的物理帧循环显式驱动，确保回滚模拟的确定性
func tick(delta: float) -> void:
	if not _player_ok():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	# 换弹倒计时
	if _reloading:
		_reload_t -= delta
		if _reload_t <= 0.0:
			_reloading = false
			mag_ammo = mag_size
			Sfx.play("switch")
	_auto_aim()
	if _fire_buffered and fire_cd_timer == 0.0:
		_fire_buffered = false
		fire()
	if heavy_aim:
		if _attack_just_pressed():
			_aiming = true
		if _attack_just_released():
			_aiming = false
			_update_laser()
			try_fire()
		_update_laser()
	elif full_auto:
		if _attack_pressed():
			try_fire()
	else:
		if _attack_just_pressed():
			try_fire()
	_recoil_recover(delta)
	_update_reload_pose()

func try_fire() -> void:
	if fire_cd_timer > 0.0:
		if fire_cooldown > 0.5 and fire_cd_timer <= fire_cooldown * 0.2:
			_fire_buffered = true
		return
	fire()

func fire() -> void:
	if not _player_ok():
		return
	if _reloading:
		return
	if mag_ammo <= 0:
		if _mag_ready:
			start_reload()
		return
	fire_cd_timer = fire_cooldown
	if max_live_projectiles > 0 and _live_projectiles() >= max_live_projectiles:
		return
	_auto_aim()
	var base_dir := _clamped_aim_dir()
	_spawn_projectiles(base_dir)
	Sfx.play("shoot_heavy" if heavy_aim else ("shotgun" if pellet_count > 1 else "shoot"))
	mag_ammo = maxi(mag_ammo - 1, 0)
	if mag_ammo == 0:
		start_reload()
	if player != null and player.has_method("apply_recoil"):
		player.apply_recoil(recoil_push)
	_recoil_timer = RECOIL_TIME
	sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)

# 命中目标伤害结算
func apply_hit(target: Node, dir: Vector2) -> void:
	if target != null and target.has_method("hurt"):
		target.hurt(damage, dir, impact)

# 发射弹丸
func _spawn_projectiles(base_dir: Vector2) -> void:
	var spread := deg_to_rad(spread_deg)
	for i in range(pellet_count):
		var b: BulletBase = bullet_scene.instantiate()
		var hm := float(player.get("pvp_haste_mult")) if player != null and player is Node 				and "pvp_haste_mult" in player else 1.0
		var ang := base_dir.angle() + randf_range(-spread, spread)
		b.setup(Vector2.from_angle(ang), bullet_speed * hm, bullet_range, bullet_size, bullet_color, self)
		b.shooter = player
		b.gravity_factor = bullet_gravity
		b.hit_damage = damage
		b.hit_impact = impact
		b.global_position = muzzle.global_position
		b.apply_damage = not Level0.pvp_mode
		b.set_meta("scene_path", bullet_scene.resource_path)
		get_viewport().add_child(b)

# 统计本武器当前存活的弹丸数
func _live_projectiles() -> int:
	if not is_inside_tree():
		return 0
	var n := 0
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b) and b.source == self:
			n += 1
	return n

func cancel_aim() -> void:
	_aiming = false
	if _laser != null:
		_laser.visible = false

# 当前是否处于蓄力/预瞄状态
func is_previewing() -> bool:
	return _aiming

# 多人模式下根据权威数据驱动远端副本武器外观（仅显示朝向与枪口角度）
func drive_remote_visual(aim_dir: Vector2, facing: int) -> void:
	if _laser == null or muzzle == null:
		return
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2(float(facing), 0.0)
	_aim_facing = facing
	_current_aim_facing = facing
	rotation = clamp_pitch(aim_dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)
	_aiming = false
	_update_laser()

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

# 获取钳制后的出弹单位方向向量
func _clamped_aim_dir() -> Vector2:
	var facing := _current_aim_facing
	var pitch := clamp_pitch(_aim_world_dir(), facing, pitch_clamp_deg)
	var local := Vector2.from_angle(pitch)
	return Vector2(local.x * float(facing), local.y)

func _auto_aim() -> void:
	var dir := _aim_world_dir()
	var facing := _aim_facing
	if absf(dir.x) > 0.1:
		facing = 1 if dir.x > 0.0 else -1
		_aim_facing = facing
	if player != null and player.has_method("set_facing") and absf(dir.x) > 0.1:
		player.set_facing(facing)
		var charging := false
		if player.has_method("is_charging"):
			charging = bool(player.is_charging())
		if not charging:
			facing = get_facing()
	_current_aim_facing = facing
	rotation = clamp_pitch(dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)

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

# 预瞄抛物线采样计算
func _sample_arc_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := muzzle.global_position
	var start := p
	var v := _clamped_aim_dir() * bullet_speed
	var g := bullet_gravity * GameParameters.gravity0
	var dt := 1.0 / 60.0
	var t := 0.0
	var escape := _disk_overlaps_solid(start)
	pts.append(to_local(p))
	while t < preview_time:
		v.y += g * dt
		if Water.is_in_water(p):
			v *= Water.bullet_drag_factor(true, GameParameters.water_bullet_drag, dt)
		p += v * dt
		t += dt
		if escape and p.distance_to(start) < GameParameters.TILE_SIZE:
			continue
		if _disk_overlaps_solid(p):
			break
		if p.distance_to(start) >= bullet_range:
			break
		pts.append(to_local(p))
	return pts

# 检测指定坐标圆形区域是否与实体地形碰撞
func _disk_overlaps_solid(center: Vector2) -> bool:
	var r := PREVIEW_COLLISION_RADIUS * bullet_size
	return TileQuery.rect_overlaps_solid(
			Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), GameParameters.TILE_SIZE)

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]

func _recoil_recover(delta: float) -> void:
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
		sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick * (_recoil_timer / RECOIL_TIME)
		if _recoil_timer == 0.0:
			sprite.position = _base_sprite_pos

# 获取当前瞄准方向（世界坐标系）
func get_current_aim_dir() -> Vector2:
	return _aim_world_dir()

# 计算世界坐标系下从武器指向鼠标的单位向量
func _aim_world_dir() -> Vector2:
	if player != null and player.has_method("get_aim_dir_override"):
		var override: Vector2 = player.get_aim_dir_override()
		if override != Vector2.ZERO:
			return override
		if player.has_method("input_is_network") and player.input_is_network():
			return Vector2(float(get_facing()), 0.0)
	var sub: Viewport = get_viewport()
	if sub == null:
		return Vector2(float(get_facing()), 0.0)
	var cam: Camera2D = sub.get_camera_2d()
	if cam == null:
		return Vector2(float(get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(get_facing()), 0.0)
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	var cam_center: Vector2 = cam.global_position
	if cam.has_method("get_base_global_position"):
		cam_center = cam.get_base_global_position()
	var world_mouse := cam_center + (mouse - win_size * 0.5) / cam.zoom
	var origin := player.global_position if player != null else global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	if player != null and player.has_method("get_facing"):
		return player.get_facing()
	return 1
