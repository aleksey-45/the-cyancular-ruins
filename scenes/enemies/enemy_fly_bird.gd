class_name EnemyFlyBird
extends EnemyBase

enum Intent { SHOOT, CHARGE }

var intent: Intent = Intent.SHOOT

var _spawn_pos: Vector2 = Vector2.ZERO
var _home_cell: Vector2i = Vector2i.ZERO
var _shoot_timer: float = 0.0
var _hover_anchor: Vector2 = Vector2.ZERO
var _hover_side: float = 1.0
var _strafe_target: Vector2 = Vector2.INF  # Vector2.INF 表示还没有选定投弹后的飞行目标。
var _strafe_timer: float = 0.0

# 视线检测结果最长复用 9 个物理帧。
const SHOT_CLEAR_TTL_FRAMES: int = 9
var _shot_clear_ok := false
var _shot_clear_at_frame := -100000
var _shot_clear_from := Vector2i(-1, -1)
var _shot_clear_to := Vector2i(-1, -1)
# 缓存按玩家所在的瓦片和默认投弹方向区分，避免连续重新选择从哪一侧投弹。
var _side_cache := 1.0
var _side_at_frame := -100000
var _side_player_cell := Vector2i(-1, -1)
var _side_geo := 1.0
var _landing: bool = false


var _fly_box_min: Vector2 = Vector2.ZERO   # 两个角点是飞行包围盒的坐标，已计入敌人缩放。
var _fly_box_max: Vector2 = Vector2.ZERO
var _obstacle_boxes: Array[Rect2] = []
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _path_target: Vector2i = Vector2i(-1, -1)  # 同一目标还有未走完的路径时，继续使用原路径。
var _repath_timer: float = 0.0
var _repath_phase: float = 0.0             # 每只飞鸟使用不同的寻路间隔，分散同一帧中的寻路请求。
var _escape_target: Vector2 = Vector2.INF  # 找不到路径时，飞鸟先尝试飞到这个临时目标绕过障碍。


func _setup() -> void:
	_rewind_fields.append_array([&"intent", &"_shoot_timer", &"_hover_anchor", &"_hover_side", &"_strafe_target",
			&"_strafe_timer", &"_shot_clear_ok", &"_shot_clear_at_frame", &"_shot_clear_from", &"_shot_clear_to",
			&"_side_cache", &"_side_at_frame", &"_side_player_cell", &"_side_geo", &"_landing", &"_path",
			&"_path_index", &"_path_target", &"_repath_timer", &"_escape_target"])
	var bounds := kind.hulls[1].get_rect()
	_fly_box_min = bounds.position * scale
	_fly_box_max = bounds.end * scale
	wake_radius = EnemyParams.FlyBird.wake_radius
	waterproof_max = 10
	_repath_phase = randf() * EnemyParams.FlyBird.repath_interval
	_spawn_pos = position
	_home_cell = terrain.cell(_spawn_pos)

func _move_slide(travel: Vector2) -> void:
	super(travel)
	if state == State.CHARGE and not motion_contacts.is_empty():
		_on_charge_impact()


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_ready(delta, dist, EnemyParams.FlyBird.wake_time):
				_set_state(State.TAKE_OFF)
				motion.emit(&"take_off", 0.0)
				activity = Activity.TAKE_OFF
				stance = 1
				_takeoff_velocity()
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



func _tick_take_off(delta: float) -> void:
	_state_timer += delta
	if _state_timer >= EnemyParams.FlyBird.take_off_time:
		_set_state(State.FLY)
		use_gravity = false
		activity = Activity.FLY
		_schedule_repath()


func _tick_fly(delta: float, dist: float) -> void:
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
		_repath_to(terrain.cell(_shoot_pos()))
	# 沿路径飞行或绕过障碍都不可行时，才直接飞向投弹点。
	_follow_path(delta, _shoot_pos() if _path.is_empty() else Vector2.INF)


func _tick_shoot(delta: float, dist: float) -> void:
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
		if _strafe_timer <= 0.0 or _toroidal_dist_to(_strafe_target) <= EnemyParams.FlyBird.fly_speed * delta:
			_strafe_target = Vector2.INF
	else:
		_glide_to(_hover_anchor, delta)
	if _shoot_timer <= 0.0:
		# 投弹前重新检查视线。目标被挡住时，返回飞行状态寻找其他位置。
		if not _shot_clear():
			_set_state(State.FLY)
			_schedule_repath()
			return
		# 炸弹抛出后会下落，因此只在飞鸟不低于玩家时投弹。
		if position.y <= player.position.y:
			_fire_parabolic()
		_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
		_start_strafe()


func _tick_charge(delta: float) -> void:
	_state_timer += delta
	if touches_player():
		_hit_charge_player()
		_begin_death()
	elif _state_timer >= EnemyParams.FlyBird.charge_timeout:
		_begin_death()


func _tick_return(delta: float, dist: float) -> void:
	if _landing:
		_state_timer += delta
		if _state_timer >= EnemyParams.FlyBird.landing_time:
			_settle_sleep(EnemyParams.FlyBird.settle_time)
			_set_state(State.SLEEP)
			stance = 0
			_landing = false
	elif _home_reached():
		_start_landing()
	else:
		_repath_timer -= delta
		if _repath_timer <= 0.0:
			_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
			# 玩家离得太远时，仍继续返回出生点，但暂时不重新寻路。
			if dist <= EnemyParams.FlyBird.max_chase_distance:
				_repath_to(_home_cell)
		_follow_path(delta, _spawn_pos)


# 死亡后飞鸟开始下落，正在冲撞时还会失去冲撞速度。
func _on_death() -> void:
	if state == State.CHARGE:
		velocity = Vector2.ZERO
	use_gravity = true



# 先检查玩家靠飞鸟这一侧的上方是否有空位，以及视线是否畅通。
# 该侧不可用时检查另一侧，两侧都找不到合适位置时沿用默认方向。
func _shoot_side() -> float:
	var now := combat.tick
	var pcell := terrain.cell(player.position)
	var geo := _shoot_side_geo()
	if pcell != _side_player_cell or geo != _side_geo or now - _side_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_side_player_cell = pcell
		_side_geo = geo
		_side_at_frame = now
		_side_cache = _shoot_side_compute(geo)
	return _side_cache


func _shoot_side_compute(geo: float) -> float:
	var p := player.position
	for side in [geo, -geo]:
		var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)
		if TileDefs.is_blocked(terrain.value(terrain.cell(pos))):
			continue
		if terrain.line_of_sight(pos, p):
			return side
	return geo


# 水平距离大于 20 像素且飞鸟在玩家左侧时，默认从左侧投弹。其他情况下默认从右侧投弹。
func _shoot_side_geo() -> float:
	var delta := toroidal_delta_to_player()
	return -1.0 if delta.x > 20.0 else 1.0


func _shoot_pos() -> Vector2:
	var p := player.position
	var side := _shoot_side()
	var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	if TileDefs.is_blocked(terrain.value(terrain.cell(pos))):
		pos = p + Vector2(-side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	return pos


func _near_shoot_pos() -> bool:
	return _toroidal_dist_to(_shoot_pos()) <= EnemyParams.FlyBird.shoot_position_radius


func _start_shoot() -> void:
	_set_state(State.SHOOT)
	_hover_side = _shoot_side()
	_update_hover_anchor()
	_shoot_timer = 0.2


func _update_hover_anchor() -> void:
	# 默认在玩家斜上方悬停，原位置被地形占据时移到玩家另一侧。
	var p := player.position
	_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
			-EnemyParams.FlyBird.hover_offset_y)
	if TileDefs.is_blocked(terrain.value(terrain.cell(_hover_anchor))):
		_hover_side = -_hover_side
		_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)


# 飞鸟以固定速度靠近目标。本帧可以到达时，直接设置节点坐标，避免越过目标。
func _glide_to(point: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := GridPathfinder.toroidal_delta_px(position, point, terrain.map_size)
	if to_target.length() <= spd * delta:
		position = point
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


func _start_strafe() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = (combat.tick << 32) | slot
	_strafe_target = position + Vector2(
			rng.randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range),
			rng.randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range))
	_strafe_timer = EnemyParams.FlyBird.strafe_duration


# 只有与上次检测处在同一对瓦片而且缓存未到期，才继续使用上次的视线结果。
func _shot_clear() -> bool:
	var from := terrain.cell(position)
	var to := terrain.cell(player.position)
	var now := combat.tick
	if from != _shot_clear_from or to != _shot_clear_to or now - _shot_clear_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_shot_clear_from = from
		_shot_clear_to = to
		_shot_clear_at_frame = now
		_shot_clear_ok = terrain.line_of_sight(position, player.position)
	return _shot_clear_ok


func _fire_parabolic() -> void:
	# 投弹时只设置水平初速度，垂直速度由重力计算。
	var v0 := _bullet_v0()
	combat.spawn_enemy_projectile(CombatProfiles.BIRD_BOMB_TYPE, self, Vector2(v0, 0.0))
	# 后坐力让飞鸟在水平方向向弹丸的反方向移动。
	velocity += Vector2(-signf(v0) * EnemyParams.FlyBird.shoot_recoil, 0.0)


# 用高度差估算弹丸落到玩家的高度需要多久，再预测那时的玩家位置。
# 算出的弹丸水平速度同时决定飞鸟的朝向。
func _bullet_v0() -> float:
	var drop := maxf(player.position.y - position.y, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
	var pred := player.position + player.velocity * t
	var dx := GridPathfinder.toroidal_delta_px(position, pred, terrain.map_size).x
	return clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)



func _update_charge_intent_if_needed() -> void:
	# 生命值降到上限的四分之一以下时，飞鸟转为寻找冲撞机会。
	if intent == Intent.SHOOT and hp < kind.hp * EnemyParams.FlyBird.charge_hp_fraction:
		intent = Intent.CHARGE


func _try_charge() -> bool:
	if toroidal_dist_to_player() > EnemyParams.FlyBird.charge_range:
		return false
	# 发动冲撞前也检查视线，避免向被地形挡住的玩家冲撞。
	if not _shot_clear():
		return false
	_start_charge()
	return true


func _start_charge() -> void:
	_set_state(State.CHARGE)
	motion.emit(&"charge", 0.0)
	use_gravity = false  # 冲撞期间不受重力影响，因此可以沿指定方向直线飞行。
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	activity = Activity.CHARGE


func _on_charge_impact() -> void:
	if is_dead:
		return
	for hit: Array in motion_contacts:
		if hit[Contact.COLLIDER_ID] == player.get_instance_id():
			_hit_charge_player()
			break
	_begin_death()


func _hit_charge_player() -> void:
	if combat.resolve_hit(self, player, CombatProfiles.FLY_CHARGE,
			position, EnemyParams.FlyBird.charge_damage, -1.0):
		_smash_player(EnemyParams.FlyBird.charge_impact, EnemyParams.FlyBird.charge_impact_up)


func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	activity = Activity.FLY
	# 返回出生点前，若玩家仍在追击距离内就重新寻路，否则只清空原路径。
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
	stance = 0


func _player_home_dist() -> float:
	return GridPathfinder.toroidal_delta_px(player.position, _spawn_pos, terrain.map_size).length()


func _takeoff_velocity() -> void:
	var dir := toroidal_dir_to_player()
	var s := EnemyParams.FlyBird.take_off_speed
	velocity = Vector2(dir.x * s, -s * 0.75)
	use_gravity = true


func _update_facing() -> void:
	if state == State.SHOOT:
		# 以弹丸的水平速度选择朝向。弹丸没有水平速度时不转向。
		var v0 := _bullet_v0()
		if v0 != 0.0:
			_set_facing(v0 < 0.0)
	else:
		var vx := velocity.x
		if absf(vx) > 5.0:
			_set_facing(vx < 0.0)


func _waypoint_world(cell: Vector2i) -> Vector2:
	var center := (Vector2(cell) + Vector2(0.5, 0.5)) * GameParameters.TILE_SIZE
	return center - Vector2(0.0, EnemyParams.FlyBird.hover_altitude)


func _follow_path(delta: float, fallback_target: Vector2 = Vector2.INF) -> void:
	if _path.is_empty():
		if fallback_target != Vector2.INF:
			_glide_to(_escape_target if _escape_target != Vector2.INF else fallback_target, delta)
		return
	var spd := EnemyParams.FlyBird.fly_speed
	while _path_index < _path.size():
		var target := _waypoint_world(_path[_path_index])
		var to_target := GridPathfinder.toroidal_delta_px(position, target, terrain.map_size)
		if to_target.length() <= spd * delta:
			position = target
			_path_index += 1
		else:
			velocity = to_target.normalized() * spd
			return
	_path = []


func _find_escape_column() -> Vector2:
	if terrain.empty():
		return position
	var cols := terrain.columns
	var rows := terrain.rows
	var bc := terrain.cell(position)
	for drop in range(1, EnemyParams.FlyBird.escape_max_descent + 1):
		var row := posmod(bc.y + drop, rows)
		for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
			for side in [-1, 1]:
				var cell := Vector2i(posmod(bc.x + side * dist, cols), row)
				if _bird_can_pass(cell):
					return terrain.cell_center(cell)
	for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
		for side in [-1, 1]:
			var cell := Vector2i(posmod(bc.x + side * dist, cols), bc.y)
			if _bird_can_pass(cell):
				return Vector2(terrain.cell_center(cell).x, position.y)
	return position


# 以飞行时的包围盒判断路径点是否有足够空间。地形、水和附近角色都可能挡住飞鸟。
func _bird_can_pass(cell: Vector2i) -> bool:
	if terrain.empty():
		return false
	var center := _waypoint_world(cell)
	var bounds := Rect2(center + _fly_box_min, _fly_box_max - _fly_box_min)
	if terrain.rect_overlaps(bounds, GameParameters.TILE_SIZE, true):
		return false
	var anchored := GridPathfinder.anchor_to_nearest(center, position, terrain.map_size)
	bounds.position = anchored + _fly_box_min
	for obstacle in _obstacle_boxes:
		if bounds.intersects(obstacle):
			return false
	return true


func _collect_obstacles() -> void:
	_obstacle_boxes.clear()
	if toroidal_dist_to_player() <= 600.0:
		_obstacle_boxes.append(_anchored_obstacle(player.collision_rect()))
	for enemy: EnemyBase in combat.enemies:
		if enemy != self and enemy.active \
				and _toroidal_dist_to(enemy.position) <= 600.0:
			_obstacle_boxes.append(_anchored_obstacle(enemy.collision_rect()))


func _anchored_obstacle(rect: Rect2) -> Rect2:
	var anchored := GridPathfinder.anchor_to_nearest(rect.get_center(), position, terrain.map_size)
	return Rect2(anchored - rect.size * 0.5, rect.size)


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	# 搜索未到达目标时，A* 仍可能返回一条通往最接近目标的可达瓦片的路径。
	if cell == _path_target and not _path.is_empty():
		return
	_path_target = cell
	_collect_obstacles()
	_path = GridPathfinder.find_path(Vector2i(terrain.columns, terrain.rows), terrain.cell(position), cell,
			_bird_can_pass, EnemyParams.FlyBird.path_max_visit, EnemyParams.FlyBird.search_radius_cells)
	_path_index = 0
	# 若未找到任何路径，尝试选取侧方或下方的临时绕行点。
	_escape_target = _find_escape_column() if _path.is_empty() else Vector2.INF
