class_name WeaponBase
extends WeaponBody

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

@export var bullet_scene: PackedScene = preload("res://scenes/weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长（秒）
# 预瞄射线检测碰撞半径（像素）
const PREVIEW_COLLISION_RADIUS: float = 4.0
# 行走摆动只作用于表现层 sprite，不移动模拟射击原点。
const BOB_SPEED: float = 11.0
const BOB_AMOUNT: float = 1.4
const BOB_FADE: float = 8.0

# 数值模拟字段由原生基类保存；武器场景继续覆盖同名导出属性。
@export var weapon_name: String = "weapon"
@export var bullet_color: Color = Color.WHITE
@export var recoil_kick: float = 4.0
@export var cam_shake: float = 2.0
@export var cam_shake_time: float = 0.1
@export var laser_length: float = 600.0
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)
@export var preview_arc: bool = false
@export var preview_time: float = 0.5
const MAG_UNSET := -2
var _reload_pose := false
const RELOAD_TILT := 0.9
const RELOAD_OFFSET := Vector2(-3.0, 7.0)

## 武器表现每帧只在这里写一次 sprite 位姿：后坐力、装填与行走摆动先合成再落盘。
func present_step(delta: float) -> void:
	if sprite == null:
		return
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
	var offset := _recoil_offset()
	var tilt := 0.0
	if _reloading:
		_reload_pose = true
		var p := clampf(1.0 - _reload_t / maxf(reload_time, 0.01), 0.0, 1.0)
		var k := sin(p * PI)
		var jiggle := sin(p * 34.0) * 1.2 * k
		tilt = RELOAD_TILT * k
		offset += RELOAD_OFFSET * k + Vector2(jiggle, 0.0)
	elif _reload_pose:
		_reload_pose = false
	offset += _update_bob(delta)
	sprite.rotation = tilt
	sprite.position = _base_sprite_pos + offset

func _recoil_offset() -> Vector2:
	if _recoil_timer <= 0.0:
		return Vector2.ZERO
	return Vector2(-1.0, 0.0) * recoil_kick * (_recoil_timer / RECOIL_TIME)

# 着地水平移动时叠加正弦 bob；与后坐力、装填偏移相加，不碰模拟射击原点。
# 远端副本没有 ActorBody 运动状态，保持纯后坐/装填表现，不为 bob 新增网络字段。
func _update_bob(delta: float) -> Vector2:
	var want := 0.0
	if player != null and not player.sim_downed \
			and player._grounded and absf(player.velocity.x) > 20.0 and not player.is_charge:
		want = 1.0
	_bob_level = move_toward(_bob_level, want, delta * BOB_FADE)
	if _bob_level <= 0.001:
		_bob_phase = 0.0
		return Vector2.ZERO
	_bob_phase = fmod(_bob_phase + delta * BOB_SPEED, TAU)
	return Vector2(0.0, sin(_bob_phase) * BOB_AMOUNT * _bob_level)

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle


var _recoil_timer: float = 0.0
var _bob_phase := 0.0
var _bob_level := 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _initial_transform := Transform2D.IDENTITY
var _initial_sprite_transform := Transform2D.IDENTITY
var _needs_presentation_reset := false
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

func _ready() -> void:
	_initial_transform = transform
	_initial_sprite_transform = sprite.transform
	bind_muzzle(muzzle)
	initialize_magazine()
	_base_sprite_pos = sprite.position

func reset_simulation(mag: int) -> void:
	_needs_presentation_reset = true
	transform = _initial_transform
	reset_simulation_state(mag, WeaponInventory.MAG_FULL)

func reset_presentation() -> void:
	_needs_presentation_reset = false
	sprite.transform = _initial_sprite_transform
	_recoil_timer = 0.0
	_reload_pose = false
	_bob_phase = 0.0
	_bob_level = 0.0
	if _laser != null: _laser.visible = false
	if _explosion_marker != null: _explosion_marker.visible = false

# 瞄准辅助只在表现阶段按需创建，模拟与回滚切枪无需初始化显示资源。
func _ensure_aim_visuals() -> void:
	if _laser != null: return
	_laser = Line2D.new()
	_laser.width = 1.0
	_laser.default_color = laser_color
	_laser.visible = false
	add_child(_laser)
	_explosion_marker = Sprite2D.new()
	_explosion_marker.texture = Explosion.make_circle_texture(16)
	_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
	_explosion_marker.visible = false
	add_child(_explosion_marker)

func equip(p: ActorBody, inherit_cooldown: float = 0.0) -> void:
	bind_owner(p, p is Player and p.authority_world != null)
	# 继承前一把武器的剩余冷却时间，防止通过快速切枪跳过后摇
	fire_cd_timer = maxf(inherit_cooldown, 0.0)
	_fire_buffered = false
	cancel_aim()

# 绘制瞄准预览时读取当前输入；模拟步进使用原生角色已准备的输入。
func _sync_input() -> void:
	# 输入桥接是 Player（本地输入源持有者）专属；其余持有者不做本地输入合并。
	if player == null or player.stepping:
		return
	var p := player as Player
	if p == null:
		return
	external_input(p.is_attack_pressed(), p.is_attack_just_pressed(),
			p.is_attack_just_released(), _aim_world_dir())

func execute_shot(action: Dictionary) -> void:
	_spawn_projectiles(action)
	if player.authority_world != null:
		return
	if _needs_presentation_reset: reset_presentation()
	Sfx.play(shot_sound())
	play_recoil()
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		cam.shake(cam_shake, cam_shake_time)

func shot_sound() -> String:
	return "shoot_heavy" if heavy_aim else ("shotgun" if pellet_count > 1 else "shoot")

func play_recoil() -> void:
	_recoil_timer = RECOIL_TIME

# 命中目标伤害结算
func apply_hit(target: Node, dir: Vector2) -> void:
	target.hurt(damage, dir, impact)

# 发射弹丸
func _spawn_projectiles(action: Dictionary) -> void:
	for spec: Dictionary in projectile_specs(action):
		var b: BulletBase = bullet_scene.instantiate()
		b.setup(spec["vel"].normalized(), spec["vel"].length(), bullet_range, bullet_size, bullet_color, self)
		b.shooter = player
		b.authority_world = player.authority_world
		b.entity_id = spec["id"]
		b.type_id = type_id
		b.gravity_factor = bullet_gravity
		b.hit_damage = damage
		b.hit_impact = impact
		b.global_position = spec["pos"]
		b.adjudicated_pos = b.global_position
		b.adjudicated = true
		b.apply_damage = player.authority_world != null or not Level0.pvp_mode
		b.set_meta("scene_path", bullet_scene.resource_path)
		if player.authority_world != null:
			player.authority_world.add_projectile(b)
			b.set_physics_process(false)
		else:
			get_viewport().add_child(b)
		b.bind_actor_layers(player)

func drive_remote_visual(aim_dir: Vector2, facing: int) -> void:
	if muzzle == null:
		return
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2(float(facing), 0.0)
	_aim_facing = facing
	_current_aim_facing = facing
	apply_aim_pose(WeaponBody.clamp_pitch(aim_dir, facing, pitch_clamp_deg) * float(facing), facing)
	_aiming = false
	_update_laser()

func _clamped_aim_dir() -> Vector2:
	_sync_input()
	return clamped_aim()

func _update_laser() -> void:
	if muzzle == null:
		return
	if not _aiming:
		if _laser != null: _laser.visible = false
		_update_explosion_marker(false)
		return
	_ensure_aim_visuals()
	_laser.visible = true
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
	return TileDefs.terrain.rect_overlaps(
			Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), GameParameters.TILE_SIZE, false)

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]

# 获取当前瞄准方向（世界坐标系）
func get_current_aim_dir() -> Vector2:
	return _aim_world_dir()

# 计算世界坐标系下从武器指向鼠标的单位向量
func _aim_world_dir() -> Vector2:
	# 鼠标瞄准是本地 Player 的能力；其余持有者退回面朝方向。
	var p := player as Player
	if p == null:
		return Vector2(float(get_facing()), 0.0)
	var override: Vector2 = p.get_aim_dir_override()
	if override != Vector2.ZERO:
		return override
	if p.input_is_network():
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
	var cam_center: Vector2 = cam.get_base_global_position()
	var world_mouse := cam_center + (mouse - win_size * 0.5) / cam.zoom
	var origin := p.global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	return player.facing_direction if player != null else 1