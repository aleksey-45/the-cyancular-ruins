class_name EnemyFlyBird
extends EnemyFlyBase

enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
enum Intent { SHOOT, CHARGE }

const ENEMY_BULLET_SCENE: PackedScene = preload("res://scenes/enemies/enemy_bullet.tscn")
const WATER_DAMAGE_MULT: float = 1.5

var intent: Intent = Intent.SHOOT

var _spawn_pos: Vector2 = Vector2.ZERO
var _home_cell: Vector2i = Vector2i.ZERO
var _max_hp: int = 20
var _wake_timer: float = -1.0
var _sleep_anim_timer: float = -1.0
var _shoot_timer: float = 0.0
var _hover_anchor: Vector2 = Vector2.ZERO
var _hover_side: float = 1.0
var _strafe_target: Vector2 = Vector2.INF
var _strafe_timer: float = 0.0

# ── LOS/射击侧缓存:砍每帧重复视线扫描 ──
# _shot_clear:同一对(鸟格,玩家格)在 TTL 物理帧内复用上次结果;拆/堵墙、格子移动最迟 ~150ms(@60Hz)反映。用物理帧数而非墙钟门控,headless 快进冒烟里也能按帧失效;SHOOT 判定、进 SHOOT 门槛、低血冲锋前提共用同一缓存(端点相同,复用安全)。
const SHOT_CLEAR_TTL_FRAMES: int = 9
var _shot_clear_ok := false
var _shot_clear_at_frame := -100000
var _shot_clear_from := Vector2i(-1, -1)
var _shot_clear_to := Vector2i(-1, -1)
var _side_cache := 1.0
var _side_at_frame := -100000
var _side_player_cell := Vector2i(-1, -1)
var _side_geo := 1.0
var _landing: bool = false
var _spawn_captured: bool = false


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	_max_hp = hp
	wake_radius = EnemyParams.FlyBird.wake_radius
	waterproof_max = 10
	_repath_phase = randf() * EnemyParams.FlyBird.repath_interval
	_set_state(State.SLEEP)
	_anim.play("sleeping")
	_apply_flight_collision(false)


func _physics_process(delta: float) -> void:
	if not _spawn_captured:
		_spawn_pos = global_position
		_home_cell = _cell_of(global_position)
		_spawn_captured = true
	super._physics_process(delta)
	if state == State.CHARGE and get_slide_collision_count() > 0:
		_on_charge_impact()


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			_tick_sleep(delta, dist)
		State.TAKE_OFF:
			_tick_take_off(delta)
		State.FLY:
			_tick_fly(delta, dist)
		State.SHOOT:
			_tick_shoot(delta, dist)
		State.CHARGE:
			_tick_charge(delta)
		State.RETURN:
			_tick_return(delta, dist)



func _tick_sleep(delta: float, dist: float) -> void:
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


func _tick_take_off(delta: float) -> void:
	_state_timer += delta
	if _state_timer >= EnemyParams.FlyBird.take_off_time:
		_set_state(State.FLY)
		use_gravity = false
		_anim.play("flying")
		_schedule_repath()


func _tick_fly(delta: float, dist: float) -> void:
	_anim.play("flying")
	if _player_home_dist() > EnemyParams.FlyBird.home_range:
		_start_return()
		return
	if dist > EnemyParams.FlyBird.max_chase_distance:
		_start_return()
		return
	_update_charge_intent_if_needed()
	if intent == Intent.CHARGE:
		if _try_charge():
			return
	elif dist <= EnemyParams.FlyBird.shoot_range and _shot_clear() and _near_shoot_pos():
		_start_shoot()
		return
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
		_repath_to(_shoot_cell())
	_follow_path(delta, _shoot_pos() if _path.is_empty() else Vector2.INF)


func _tick_shoot(delta: float, dist: float) -> void:
	_anim.play("flying")
	if _player_home_dist() > EnemyParams.FlyBird.home_range:
		_start_return()
		return
	_update_charge_intent_if_needed()
	if intent == Intent.CHARGE:
		if _try_charge():
			return
		_set_state(State.FLY)
		_schedule_repath()
		return
	elif dist > EnemyParams.FlyBird.shoot_range + EnemyParams.FlyBird.shoot_reacquire_margin:
		_set_state(State.FLY)
		_schedule_repath()
		return
	_update_hover_anchor()
	_shoot_timer -= delta
	if _strafe_target != Vector2.INF:
		_strafe_timer -= delta
		_glide_to(_strafe_target, delta)
		if _strafe_timer <= 0.0 or (_strafe_target - global_position).length() <= EnemyParams.FlyBird.fly_speed * delta:
			_strafe_target = Vector2.INF
	else:
		_hover_to_anchor(delta)
	if _shoot_timer <= 0.0:
		if not _shot_clear():
			_set_state(State.FLY)
			_schedule_repath()
			return
		if global_position.y <= _player_pos().y:
			_fire_parabolic()
		_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
		_start_strafe()


func _tick_charge(delta: float) -> void:
	_state_timer += delta
	if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
		_on_charge_hit_player()
	elif _state_timer >= EnemyParams.FlyBird.charge_timeout:
		_die_self()


func _tick_return(delta: float, dist: float) -> void:
	_anim.play("flying")
	if _landing:
		# 落地阶段:开重力直接下坠,计时到点即入睡,不再等地板接触(FLOATING 模式下 is_on_floor 恒 false,个别出生位/接缝处永远等不到,鸟会卡在 RETURN 不睡)。
		_state_timer += delta
		if _state_timer >= EnemyParams.FlyBird.landing_time:
			_anim.play("fall_asleep")
			_sleep_anim_timer = _anim_duration("fall_asleep")
			_set_state(State.SLEEP)
			_apply_flight_collision(false)
			_landing = false
	elif _home_reached():
		_start_landing()
	else:
		_repath_timer -= delta
		if _repath_timer <= 0.0:
			_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
			if dist <= EnemyParams.FlyBird.max_chase_distance:
				_repath_to(_home_cell)
		_follow_path(delta, _spawn_pos)


func _die_self() -> void:
	_begin_death()


func _on_death() -> void:
	if state == State.CHARGE:
		velocity = Vector2.ZERO
	use_gravity = true



func _shoot_side() -> float:
	var now := Engine.get_physics_frames()
	var pcell := _cell_of(_player_pos())
	var geo := _shoot_side_geo()
	if pcell != _side_player_cell or geo != _side_geo or now - _side_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_side_player_cell = pcell
		_side_geo = geo
		_side_at_frame = now
		_side_cache = _shoot_side_compute()
	return _side_cache


func _shoot_side_compute() -> float:
	var geo := _shoot_side_geo()
	var p := _player_pos()
	for side in [geo, -geo]:
		var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)
		if _cell_is_solid(_cell_of(pos)):
			continue
		if MazeGenerator.has_line_of_sight(_cell_of(pos), _cell_of(p)):
			return side
	return geo


func _shoot_side_geo() -> float:
	var delta := toroidal_delta_to_player()
	return -1.0 if delta.x > 20.0 else 1.0


func _shoot_pos() -> Vector2:
	var p := _player_pos()
	var side := _shoot_side()
	var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(pos)):
		pos = p + Vector2(-side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	return pos


func _shoot_cell() -> Vector2i:
	return _cell_of(_shoot_pos())


func _near_shoot_pos() -> bool:
	return _toroidal_dist_to(_shoot_pos()) <= EnemyParams.FlyBird.shoot_position_radius


func _start_shoot() -> void:
	_set_state(State.SHOOT)
	_pick_hover_side()
	_update_hover_anchor()
	_shoot_timer = 0.2


func _pick_hover_side() -> void:
	_hover_side = _shoot_side()


func _update_hover_anchor() -> void:
	var p := _player_pos()
	_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
			-EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(_hover_anchor)):
		_hover_side = -_hover_side
		_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)


func _hover_to_anchor(delta: float) -> void:
	_glide_to(_hover_anchor, delta)


func _glide_to(point: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := point - global_position
	if to_target.length() <= spd * delta:
		global_position = point
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


func _start_strafe() -> void:
	_strafe_target = global_position + Vector2(
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range),
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range))
	_strafe_timer = EnemyParams.FlyBird.strafe_duration


func _shot_clear() -> bool:
	var from := _cell_of(global_position)
	var to := _cell_of(_player_pos())
	var now := Engine.get_physics_frames()
	if from != _shot_clear_from or to != _shot_clear_to or now - _shot_clear_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_shot_clear_from = from
		_shot_clear_to = to
		_shot_clear_at_frame = now
		_shot_clear_ok = MazeGenerator.has_line_of_sight(from, to)
	return _shot_clear_ok


func _water_boosted_damage(base: int) -> int:
	var p := _nearest_player() as Node2D
	if p != null and Water.sample_body(p, false).in_water:
		return roundi(base * WATER_DAMAGE_MULT)
	return base


func _fire_parabolic() -> void:
	var v0 := _bullet_v0()
	var b: EnemyBullet = ENEMY_BULLET_SCENE.instantiate()
	b.launch(Vector2(v0, 0.0), EnemyParams.FlyBird.bullet_range,
			EnemyParams.FlyBird.bullet_damage, EnemyParams.FlyBird.bullet_gravity,
			EnemyParams.FlyBird.bullet_size)
	b.water_mult = WATER_DAMAGE_MULT
	b.set_meta("scene_path", ENEMY_BULLET_SCENE.resource_path)
	b.global_position = global_position
	get_viewport().add_child(b)
	velocity += Vector2(-signf(v0) * EnemyParams.FlyBird.shoot_recoil, 0.0)


func _bullet_v0() -> float:
	var drop := maxf(_player_pos().y - global_position.y, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
	var pred := _player_pos() + _player_velocity() * t
	var dx := pred.x - global_position.x
	if absf(dx) > GameParameters.MAP_WIDTH * 0.5:
		dx = -signf(dx) * (GameParameters.MAP_WIDTH - absf(dx))
	return clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)



func _update_charge_intent_if_needed() -> void:
	if intent == Intent.SHOOT and hp < _max_hp * EnemyParams.FlyBird.charge_hp_fraction:
		intent = Intent.CHARGE


func _try_charge() -> bool:
	if toroidal_dist_to_player() > EnemyParams.FlyBird.charge_range:
		return false
	if not _shot_clear():
		return false
	_start_charge()
	return true


func _start_charge() -> void:
	_set_state(State.CHARGE)
	use_gravity = false
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	_anim.play("dashing")


func _on_charge_impact() -> void:
	if is_dead:
		return
	for i in range(get_slide_collision_count()):
		var collider := get_slide_collision(i).get_collider()
		if collider != null and collider.is_in_group("player") and collider.has_method("take_hit"):
			collider.take_hit(global_position, _water_boosted_damage(EnemyParams.FlyBird.charge_damage), true)
			_apply_charge_impact(collider)
			break
	_die_self()


func _on_charge_hit_player() -> void:
	if is_dead:
		return
	var p := _nearest_player()
	if p != null and p.has_method("take_hit"):
		p.take_hit(global_position, _water_boosted_damage(EnemyParams.FlyBird.charge_damage), true)
		_apply_charge_impact(p)
	_die_self()


func _apply_charge_impact(p: Node) -> void:
	_smash_player(p, EnemyParams.FlyBird.charge_impact, EnemyParams.FlyBird.charge_impact_up)



func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	_anim.play("flying")
	if toroidal_dist_to_player() <= EnemyParams.FlyBird.max_chase_distance:
		_repath_to(_home_cell)
	else:
		_path = []


func _home_reached() -> bool:
	return _toroidal_dist_to(_spawn_pos) <= EnemyParams.FlyBird.arrival_radius


func _start_landing() -> void:
	_landing = true
	_path = []
	use_gravity = true
	velocity = Vector2.ZERO
	_state_timer = 0.0
	_apply_flight_collision(false)


func _player_home_dist() -> float:
	return MazeGenerator.toroidal_delta_px(_player_pos(), _spawn_pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func _takeoff_velocity() -> void:
	var dir := toroidal_dir_to_player()
	var s := EnemyParams.FlyBird.take_off_speed
	velocity = Vector2(dir.x * s, -s * 0.75)
	use_gravity = true


func _update_facing() -> void:
	if state == State.SHOOT:
		var v0 := _bullet_v0()
		if v0 != 0.0:
			_set_facing(v0 < 0.0)
	else:
		var vx := velocity.x
		if absf(vx) > 5.0:
			_set_facing(vx < 0.0)


func _is_asleep() -> bool:
	return state == State.SLEEP


func _on_state_entered(s: int) -> void:
	match s:
		State.TAKE_OFF:
			squash.impulse(SquashStretch.Impulse.TAKE_OFF)
		State.CHARGE:
			squash.impulse(SquashStretch.Impulse.CHARGE)
