class_name WeaponBody
extends Node2D

# 武器模拟：瞄准/俯仰、冷却、装填、开火事件与散射规格。数值由武器场景/注册表覆盖。

@export var tier := 0
@export var full_auto := false
@export var fire_cooldown := 0.2
@export var heavy_aim := false
@export var bullet_speed := 900.0
@export var bullet_range := 600.0
@export var bullet_size := 1.0
@export var bullet_gravity := 0.0
@export var pellet_count := 1
@export var spread_deg := 0.0
@export var damage := 1
@export var impact := 60.0
@export var max_live_projectiles := 0
@export var recoil_push := 0.0
@export var move_penalty := 1.0
@export var jump_penalty := 1.0
@export var penalty_mode := 0
@export var pitch_clamp_deg := 45.0
@export var mag_size := 12
@export var reload_time := 1.2

var type_id := 0
var mag_ammo := 0
var pending_mag := -2
var fire_cd_timer := 0.0
var _mag_ready := false
var _reloading := false
var _reload_t := 0.0
var _aiming := false
var _fire_buffered := false
var _aim_facing := 1
var _current_aim_facing := 1

# 武器由角色持有、枪口由武器持有：生命周期严格包含，直接引用即可。
# 持有者恒为 ActorBody（模拟读写的全部字段都在它身上）；Player 专属的输入查询由场景层自行转换。
var player: ActorBody = null
var _muzzle: Node2D = null
var _authority_owner := false
var _external_held := false
var _external_pressed := false
var _external_released := false
var _external_aim := Vector2.ZERO

func actor() -> ActorBody:
	return player

func bind_owner(value: ActorBody, authority: bool) -> void:
	player = value
	_authority_owner = authority

func bind_muzzle(value: Node2D) -> void:
	_muzzle = value

func external_input(held: bool, pressed: bool, released: bool, direction: Vector2) -> void:
	_external_held = held
	_external_pressed = pressed
	_external_released = released
	_external_aim = direction

func initialize_magazine() -> void:
	mag_ammo = mag_size if pending_mag == -2 else clampi(pending_mag, 0, mag_size)
	pending_mag = -2
	_mag_ready = true

func reset_simulation_state(mag: int, full: int) -> void:
	mag_ammo = mag_size if mag == full else clampi(mag, 0, mag_size)
	pending_mag = -2
	_mag_ready = true
	_reloading = false
	_reload_t = 0.0
	_aiming = false
	_fire_buffered = false
	_aim_facing = 1
	_current_aim_facing = 1

func _sound(value: String) -> void:
	var body := actor()
	if body != null:
		body.step_actions.append({"kind": "sound", "sound": value})

func _muzzle_node() -> Node2D:
	return _muzzle

func start_reload() -> void:
	if not _mag_ready or _reloading or mag_ammo >= mag_size:
		return
	_reloading = true
	_reload_t = reload_time
	_sound("reload")

func reload_progress() -> float:
	return 1.0 - _reload_t / maxf(reload_time, 0.01) if _reloading else -1.0

static func clamp_pitch(direction: Vector2, facing: int, limit: float) -> float:
	var local := Vector2(direction.x * facing, direction.y)
	return clampf(local.angle(), -limit * (PI / 180.0), limit * (PI / 180.0))

static func aim_facing_hint(direction: Vector2) -> int:
	if absf(direction.x) > 0.1:
		return 1 if direction.x > 0.0 else -1
	return 0

func aim() -> Vector2:
	var body := actor()
	if body == null:
		return _external_aim
	var value := body.step_input.aim if body.stepping else _external_aim
	return value if value != Vector2.ZERO else Vector2(body.facing_direction, 0.0)

func apply_aim_pose(angle: float, facing: int) -> void:
	if rotation != angle:
		rotation = angle
	var current := scale
	if current.x != facing:
		current.x = facing
		scale = current

func auto_aim() -> void:
	var direction := aim()
	var facing := int(_aim_facing)
	var hint := aim_facing_hint(direction)
	if hint != 0:
		facing = hint
		_aim_facing = facing
		var body := actor()
		if body != null and not body.is_charge:
			body.facing_direction = facing
	_current_aim_facing = facing
	apply_aim_pose(clamp_pitch(direction, facing, pitch_clamp_deg) * facing, facing)

func clamped_aim() -> Vector2:
	var angle := clamp_pitch(aim(), _current_aim_facing, pitch_clamp_deg)
	var local := Vector2.from_angle(angle)
	return Vector2(local.x * _current_aim_facing, local.y)

func live_projectiles() -> int:
	var body := actor()
	if body == null:
		return 0
	if body.has_prediction_registry():
		return body.count_prediction_projectiles(type_id)
	if not is_inside_tree():
		return 0
	var count := 0
	for node in get_tree().get_nodes_in_group("bullet"):
		var bullet := node as BulletBody
		if bullet == null:
			continue
		if _authority_owner:
			if bullet.get_shooter() == body and bullet.type_id == type_id and not bullet.finished:
				count += 1
		elif bullet.get_source_node() == self:
			count += 1
	return count

func tick_weapon(delta: float) -> void:
	var body := actor()
	if body == null or body.sim_downed:
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	if _reloading:
		_reload_t -= delta
		if _reload_t <= 0.0:
			_reloading = false
			mag_ammo = mag_size
			_sound("switch")
	auto_aim()
	if _fire_buffered and fire_cd_timer == 0.0:
		_fire_buffered = false
		fire()
	var input := body.step_input
	var held := (input.held & ActorInput.BIT_ATTACK) != 0 if body.stepping else _external_held
	var pressed := (input.pressed & ActorInput.BIT_ATTACK) != 0 if body.stepping else _external_pressed
	var released := (input.released & ActorInput.BIT_ATTACK) != 0 if body.stepping else _external_released
	if heavy_aim:
		if pressed:
			_aiming = true
		if released:
			_aiming = false
			try_fire()
		if not held and not pressed:
			_aiming = false
	elif (held or pressed) if full_auto else pressed:
		try_fire()

func try_fire() -> void:
	if fire_cd_timer > 0.0:
		if fire_cooldown > 0.5 and fire_cd_timer <= fire_cooldown * 0.2:
			_fire_buffered = true
		return
	fire()

func fire() -> void:
	var body := actor()
	if body == null or body.sim_downed or _reloading:
		return
	if mag_ammo <= 0:
		if _mag_ready:
			start_reload()
		return
	fire_cd_timer = fire_cooldown
	if max_live_projectiles > 0 and live_projectiles() >= max_live_projectiles:
		return
	auto_aim()
	var muzzle := _muzzle_node()
	if muzzle == null:
		push_error("WeaponBody: 未绑定枪口")
		return
	var origin := body.shot_origin(muzzle)
	var serial := body.shot_serial + 1
	body.shot_serial = serial
	var action := {"kind": "fire", "dir": clamped_aim(), "serial": serial, "pos": origin}
	body.step_actions.append(action)
	mag_ammo = maxi(mag_ammo - 1, 0)
	if mag_ammo == 0:
		start_reload()
	body.apply_recoil(recoil_push)

func get_movement_multiplier() -> Vector2:
	var active := fire_cd_timer > 0.0 if penalty_mode == 1 \
			else (penalty_mode == 2 and (_aiming or fire_cd_timer > 0.0))
	return Vector2(move_penalty, jump_penalty) if active else Vector2(1.0, 1.0)

func projectile_specs(action: Dictionary) -> Array:
	var body := actor()
	if body == null:
		return []
	var rng := RandomNumberGenerator.new()
	var serial := int(action["serial"])
	var role := body.role
	rng.seed = ("%d:%d" % [role, serial]).hash()
	var spread := spread_deg * (PI / 180.0)
	var direction: Vector2 = action["dir"]
	var result: Array = []
	for i in pellet_count:
		var angle := direction.angle() + rng.randf_range(-spread, spread)
		var velocity := Vector2.from_angle(angle) * bullet_speed * body.pvp_haste_mult
		result.append({"id": (role << 48) | (serial << 8) | i, "type_id": type_id,
			"pos": action["pos"], "vel": velocity, "traveled": 0.0,
			"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false})
	return result

# 武器状态挂在玩家状态尾部，槽位顺序与 PlayerStateSchema 后 8 槽一致。
const STATE_BASE := PlayerStateSchema.CHARACTER_SIZE

func append_prediction_state(values: Array) -> void:
	values.append_array(state_values())

func state_values() -> Array:
	return [fire_cd_timer, _aiming, _fire_buffered, _aim_facing,
		_current_aim_facing, mag_ammo, _reloading, _reload_t]

# 空手时武器段仍占同样多的槽，值不参与恢复；槽序与 state_values() 一致。
static func idle_state() -> Array:
	return [0.0, false, false, 1, 1, 0, false, 0.0]

func restore_state_values(values: Array) -> void:
	fire_cd_timer = values[STATE_BASE]
	_aiming = values[STATE_BASE + 1]
	_fire_buffered = values[STATE_BASE + 2]
	_aim_facing = values[STATE_BASE + 3]
	_current_aim_facing = values[STATE_BASE + 4]
	var mag := clampi(int(values[STATE_BASE + 5]), 0, mag_size)
	if is_inside_tree():
		mag_ammo = mag
	else:
		pending_mag = mag
	_reloading = values[STATE_BASE + 6]
	_reload_t = values[STATE_BASE + 7]

func cancel_aim() -> void:
	_aiming = false

func is_previewing() -> bool:
	return _aiming
