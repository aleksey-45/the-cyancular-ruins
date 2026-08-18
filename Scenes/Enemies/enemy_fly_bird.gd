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
	# 落差 = 玩家.y − 鸟.y(玩家在鸟下方为正)。玩家高于鸟时夹到下限,弹道偏近属预期。
	var drop := _player_pos().y - global_position.y
	drop = maxf(drop, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
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
