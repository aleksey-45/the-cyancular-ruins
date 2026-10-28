class_name WeaponBase
extends NativeWeaponBody

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

@export var bullet_scene: PackedScene = preload("res://scenes/weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长（秒）
# 预瞄射线检测碰撞半径（像素）
const PREVIEW_COLLISION_RADIUS: float = 4.0

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

func start_reload() -> void:
	native_start_reload()

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


var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _initial_transform := Transform2D.IDENTITY
var _initial_sprite_transform := Transform2D.IDENTITY
var _needs_presentation_reset := false
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

# 俯仰角限制：根据角色水平朝向折叠计算，并限制在指定角度范围内
static func clamp_pitch(dir: Vector2, facing: int, limit_deg: float = 45.0) -> float:
	return NativeWeaponBody.native_clamp_pitch(dir, facing, limit_deg)

func _ready() -> void:
	_initial_transform = transform
	_initial_sprite_transform = sprite.transform
	native_bind_muzzle(muzzle)
	native_initialize_magazine()
	_base_sprite_pos = sprite.position

func reset_simulation(mag: int) -> void:
	_needs_presentation_reset = true
	transform = _initial_transform
	native_reset_simulation(mag, WeaponInventory.MAG_FULL)

func reset_presentation() -> void:
	_needs_presentation_reset = false
	sprite.transform = _initial_sprite_transform
	_recoil_timer = 0.0
	_reload_pose = false
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

func equip(p: Node2D, inherit_cooldown: float = 0.0) -> void:
	native_bind_owner(p, p is Player and p.authority_world != null)
	# 继承前一把武器的剩余冷却时间，防止通过快速切枪跳过后摇
	fire_cd_timer = maxf(inherit_cooldown, 0.0)
	_fire_buffered = false
	cancel_aim()

# 武器物理逻辑由所属角色的物理帧循环显式驱动，确保回滚模拟的确定性
# 正常推进和重放由原生角色直接调用同一武器核；此入口兼容独立武器调用。
func tick(delta: float) -> void:
	_sync_native_input()
	native_tick_weapon(delta)

func _sync_native_input() -> void:
	if player is NativeActorBody and not player.stepping:
		player.input_epoch = player.input_buffer.epoch
		native_external_input(player.is_attack_pressed(), player.is_attack_just_pressed(),
				player.is_attack_just_released(), _aim_world_dir())

func try_fire() -> void:
	_sync_native_input()
	native_try_fire()

func fire() -> void:
	_sync_native_input()
	native_fire()

func execute_shot(action: Dictionary) -> void:
	_spawn_projectiles(action)
	if player.authority_world != null:
		return
	if _needs_presentation_reset: reset_presentation()
	Sfx.play(shot_sound())
	play_recoil()
	var cam := get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)

func shot_sound() -> String:
	return "shoot_heavy" if heavy_aim else ("shotgun" if pellet_count > 1 else "shoot")

func play_recoil() -> void:
	_recoil_timer = RECOIL_TIME
	sprite.position = _base_sprite_pos - Vector2(recoil_kick, 0.0)

# 命中目标伤害结算
func apply_hit(target: Node, dir: Vector2) -> void:
	if target != null and target.has_method("hurt"):
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
		b.input_seq = action["input_seq"]
		b.input_epoch = action["input_epoch"]
		b.gravity_factor = bullet_gravity
		b.hit_damage = damage
		b.hit_impact = impact
		b.global_position = spec["pos"]
		b.adjudicated_pos = b.global_position
		b.adjudicated = true
		b.apply_damage = not Level0.pvp_mode
		b.set_meta("scene_path", bullet_scene.resource_path)
		if player.authority_world != null:
			player.authority_world.add_projectile(b)
			b.set_physics_process(false)
		else:
			get_viewport().add_child(b)


func _live_projectiles() -> int:
	if player.weapons.projectile_count.is_valid():
		return player.weapons.projectile_count.call(type_id)
	if player.authority_world != null:
		var count := 0
		for bullet: BulletBase in player.authority_world.live_bullets():
			if bullet.shooter == player and bullet.type_id == type_id and not bullet.finished:
				count += 1
		return count
	if not is_inside_tree():
		return 0
	var n := 0
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b) and b.source == self:
			n += 1
	return n


func drive_remote_visual(aim_dir: Vector2, facing: int) -> void:
	if muzzle == null:
		return
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2(float(facing), 0.0)
	_aim_facing = facing
	_current_aim_facing = facing
	_apply_aim_pose(clamp_pitch(aim_dir, facing, pitch_clamp_deg) * float(facing), facing)
	_aiming = false
	_update_laser()


func _clamped_aim_dir() -> Vector2:
	_sync_native_input()
	return native_clamped_aim()

static func aim_facing_hint(dir: Vector2) -> int:
	return NativeWeaponBody.native_aim_facing_hint(dir)

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
	var override: Vector2 = player.get_aim_dir_override()
	if override != Vector2.ZERO:
		return override
	if player.input_is_network():
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
	var origin := player.global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	return player.get_facing()
func _play_sfx(sound: String) -> void:
	if player != null:
		player.step_actions.append({"kind": "sound", "sound": sound})
