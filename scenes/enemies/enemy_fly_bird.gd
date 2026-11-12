class_name EnemyFlyBird
extends EnemyBase

enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
enum Intent { SHOOT, CHARGE }

var intent: Intent = Intent.SHOOT

var _spawn_pos: Vector2 = Vector2.ZERO
var _home_cell: Vector2i = Vector2i.ZERO
var _max_hp: int = 20
var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _shoot_timer: float = 0.0
var _hover_anchor: Vector2 = Vector2.ZERO
var _hover_side: float = 1.0
var _strafe_target: Vector2 = Vector2.INF  # 开火后短距随机移动目标;INF=未在移动
var _strafe_timer: float = 0.0             # 短距移动剩余时长

# 视线按端点和物理帧 TTL 缓存；拆墙最多延迟一个 TTL 反映。
const SHOT_CLEAR_TTL_FRAMES: int = 9
var _shot_clear_ok := false
var _shot_clear_at_frame := -100000
var _shot_clear_from := Vector2i(-1, -1)
var _shot_clear_to := Vector2i(-1, -1)
# _shoot_side(斜上射击位所在侧,内部各做一次 LOS):玩家格/几何侧不变且未超 TTL 则复用,
# 避免 _near_shoot_pos 每帧为每只追玩家的鸟白付 1~2 次 Bresenham。
var _side_cache := 1.0
var _side_at_frame := -100000
var _side_player_cell := Vector2i(-1, -1)
var _side_geo := 1.0
var _landing: bool = false           # RETURN 落地阶段
var _spawn_captured: bool = false   # 出生点是否已抓取(等 spawner 设好位置再取,否则是 (0,0))


var _fly_box_min: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最小角(已按 scale 换算)
var _fly_box_max: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最大角(已按 scale 换算)
var _obstacle_boxes: Array[Rect2] = []
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _path_target: Vector2i = Vector2i(-1, -1)  # 上次寻路目标格;未变且路径还在时跳过重寻(静态战斗砍搜索量)
var _repath_timer: float = 0.0
var _repath_phase: float = 0.0             # 随机微小相位差，分散寻路时机
var _escape_target: Vector2 = Vector2.INF  # 避障脱困目标点（寻路无解时脱离狭窄死角）


func _ready() -> void:
	super._ready()
	var hull: CollisionPolygon2D = $CollisionPolygon2D_fly
	var bounds := hull.transform * CollisionWorld.carrier_shape(hull).get_rect()
	_fly_box_min = bounds.position * scale
	_fly_box_max = bounds.end * scale
	# spawner 在 add_child 后才设置位置，出生点延至首帧记录。
	_max_hp = hp
	wake_radius = EnemyParams.FlyBird.wake_radius
	waterproof_max = 10
	_repath_phase = randf() * EnemyParams.FlyBird.repath_interval
	_set_state(State.SLEEP)
	_anim.play("sleeping")
	_apply_flight_collision(false)


func _physics_process(delta: float) -> void:
	# 首帧补抓出生点:spawner 在 _ready 之后才设 global_position。
	if not _spawn_captured:
		_spawn_pos = global_position
		_home_cell = _cell_of(global_position)
		_spawn_captured = true
	# 死亡白闪/销毁由基类统一处理(物理与生前一致走 super 同一套)。
	super._physics_process(delta)
	# 冲撞撞到东西(super 已执行主移动)
	if state == State.CHARGE and not _move_hits.is_empty():
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
		# 目标是斜上射击位(玩家上方),让下方的鸟绕道爬升到能打的位置。
		_repath_to(_cell_of(_shoot_pos()))
	# 空路径才计算直飞目标，避免重复视线查询。
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
		# 开火后的短距随机移动:滑向随机目标,到点或超时结束。
		_strafe_timer -= delta
		_glide_to(_strafe_target, delta)
		if _strafe_timer <= 0.0 or _toroidal_dist_to(_strafe_target) <= EnemyParams.FlyBird.fly_speed * delta:
			_strafe_target = Vector2.INF
	else:
		_glide_to(_hover_anchor, delta)
	if _shoot_timer <= 0.0:
		# 弹道被墙挡:不空射,退 FLY 继续接近玩家找射击位。
		if not _shot_clear():
			_set_state(State.FLY)
			_schedule_repath()
			return
		# 平抛只能下落:鸟在玩家下方时弹道够不到玩家,不空射,继续爬向斜上锚点。
		if global_position.y <= _player_pos().y:
			_fire_parabolic()
		_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
		_start_strafe()


func _tick_charge(delta: float) -> void:
	_state_timer += delta
	# 接触区/贴脸距离命中玩家直接结算(弥补 slide 碰撞偶尔穿过的情形)。
	if _touching_player() or toroidal_dist_to_player() <= CONTACT_RADIUS:
		_on_charge_hit_player()
	elif _state_timer >= EnemyParams.FlyBird.charge_timeout:
		_begin_death()


func _tick_return(delta: float, dist: float) -> void:
	_anim.play("flying")
	if _landing:
		# FLOATING 模式不提供地面状态，返程落地阶段以计时结束。
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
			# 玩家太远时不启动任何搜索;空路径时直线飞回家(不再漂移)。
			if dist <= EnemyParams.FlyBird.max_chase_distance:
				_repath_to(_home_cell)
		_follow_path(delta, _spawn_pos)


# 死亡瞬间:冲撞中死(含被打死/超时)清冲撞速度,尸体不再续冲。撞墙/撞玩家的死亡已由
# 主移动命中即停抵消速度,归零无副作用;普通受击仍保留击退滑出感。
# 其余死亡保留击退速度 + 开重力,带白闪飞出后消失(不像 JumpBird 清速度定格)。
func _on_death() -> void:
	if state == State.CHARGE:
		velocity = Vector2.ZERO
	use_gravity = true



# 斜上射击位(与 SHOOT 锚点同一逻辑):玩家侧向 + 上方,鸟不穿越玩家头顶。
# 世界坐标与格坐标共用同一侧,保证寻路目标可到、直线保底处理同向。
# 侧向优先取 LOS 通的一侧:几何侧对玩家无视线(被墙挡,如玩家站高平台一侧有墙)时,
# 鸟会一直停在射击位进不了 SHOOT——换另一侧绕过去攻击。两侧都堵才退回几何侧。
# 结果按(玩家格,几何侧)缓存,TTL 物理帧内复用(几何/位置变化最迟 ~150ms 反映)。
func _shoot_side() -> float:
	var now := Engine.get_physics_frames()
	var pcell := _cell_of(_player_pos())
	var geo := _shoot_side_geo()
	if pcell != _side_player_cell or geo != _side_geo or now - _side_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_side_player_cell = pcell
		_side_geo = geo
		_side_at_frame = now
		_side_cache = _shoot_side_compute(geo)
	return _side_cache


func _shoot_side_compute(geo: float) -> float:
	var p := _player_pos()
	for side in [geo, -geo]:
		var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)
		if _cell_is_solid(_cell_of(pos)):
			continue
		if terrain.line_of_sight(pos, p):
			return side
	return geo


# 几何侧:鸟在玩家哪一侧,射击位就放哪一侧(避免穿越玩家头顶)。20px 死区防抖。
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


# 是否已在斜上射击位附近:SHOOT 只应在鸟接近锚点时进入,否则下方/远方的鸟会
# 直线硬插到锚点被墙卡住。未就位时留在 FLY,靠 BFS 绕到玩家上方再进 SHOOT。
func _near_shoot_pos() -> bool:
	return _toroidal_dist_to(_shoot_pos()) <= EnemyParams.FlyBird.shoot_position_radius


func _start_shoot() -> void:
	_set_state(State.SHOOT)
	_hover_side = _shoot_side()
	_update_hover_anchor()
	_shoot_timer = 0.2


func _update_hover_anchor() -> void:
	# 斜上锚点:玩家侧向 + 上向偏移,不在玩家正头顶。
	var p := _player_pos()
	_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
			-EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(_hover_anchor)):
		_hover_side = -_hover_side
		_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)


# 以 fly_speed 向 point 直线滑翔(悬停归位 / 开火后短距随机移动共用)。
func _glide_to(point: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := GridPathfinder.toroidal_delta_px(global_position, point, terrain.map_size)
	if to_target.length() <= spd * delta:
		global_position = point
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


# 开火后短距随机移动:在当前位置 ±strafe_range 内取一个随机点作为滑翔目标。
func _start_strafe() -> void:
	_strafe_target = global_position + Vector2(
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range),
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range))
	_strafe_timer = EnemyParams.FlyBird.strafe_duration


# 弹道无遮挡:鸟与玩家格子之间无墙(平抛子弹会被地形挡住)。
# 结果按(鸟格,玩家格)缓存 SHOT_CLEAR_TTL_FRAMES,墙被拆/堵或任一方换格(超时保底处理)才重算。
func _shot_clear() -> bool:
	var from := _cell_of(global_position)
	var to := _cell_of(_player_pos())
	var now := Engine.get_physics_frames()
	if from != _shot_clear_from or to != _shot_clear_to or now - _shot_clear_at_frame > SHOT_CLEAR_TTL_FRAMES:
		_shot_clear_from = from
		_shot_clear_to = to
		_shot_clear_at_frame = now
		_shot_clear_ok = terrain.line_of_sight(global_position, _player_pos())
	return _shot_clear_ok


func _fire_parabolic() -> void:
	# 平抛:水平初速 + 重力,落点按玩家坐标 + 玩家即时速度预测。
	var v0 := _bullet_v0()
	combat_rules.spawn_enemy_projectile(CombatProfiles.BIRD_BOMB_TYPE, self, Vector2(v0, 0.0))
	# 开火后座:沿发射反方向轻推鸟(v0 符号即发射方向)。
	velocity += Vector2(-signf(v0) * EnemyParams.FlyBird.shoot_recoil, 0.0)


# 平抛水平初速(含玩家即时速度预测):开火与朝向共用,符号即弹道水平方向。
# 落差 = 玩家.y − 鸟.y(玩家在鸟下方为正);玩家高于鸟时夹到下限,弹道偏近属预期。
func _bullet_v0() -> float:
	var drop := maxf(_player_pos().y - global_position.y, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
	var pred := _player_pos() + _player_velocity() * t
	var dx := GridPathfinder.toroidal_delta_px(global_position, pred, terrain.map_size).x
	return clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)



func _update_charge_intent_if_needed() -> void:
	# 血量跌穿 25% 单向切冲撞意图(HP 只减不增)。
	if intent == Intent.SHOOT and hp < _max_hp * EnemyParams.FlyBird.charge_hp_fraction:
		intent = Intent.CHARGE


func _try_charge() -> bool:
	if toroidal_dist_to_player() > EnemyParams.FlyBird.charge_range:
		return false
	# LOS 端点与 _shot_clear 相同(鸟格→玩家格),复用缓存,不重复全图扫描。
	if not _shot_clear():
		return false
	_start_charge()
	return true


func _start_charge() -> void:
	_set_state(State.CHARGE)
	use_gravity = false  # 冲撞为水平直线,不吃重力
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	_anim.play("dashing")


func _on_charge_impact() -> void:
	if is_dead:  # 本帧若已由接触判定自毁,避免二次结算
		return
	for hit: Dictionary in _move_hits:
		var collider: Node = null if int(hit["id"]) == 0 else instance_from_id(int(hit["id"]))
		if collider is Player:
			_hit_charge_player(collider)
			break
	_begin_death()


func _on_charge_hit_player() -> void:
	if is_dead:
		return
	var p := _nearest_player()
	if p != null:
		_hit_charge_player(p)
	_begin_death()


func _hit_charge_player(player: Player) -> void:
	if combat_rules.resolve_hit(self, player, CombatProfiles.FLY_CHARGE,
			global_position, EnemyParams.FlyBird.charge_damage, -1.0):
		_smash_player(player, EnemyParams.FlyBird.charge_impact, EnemyParams.FlyBird.charge_impact_up)


func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	_anim.play("flying")
	# 玩家太远时不启动任何搜索,清空路径交给 RETURN 的直线保底处理飞回家。
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
	_state_timer = 0.0  # 落地计时从零起,到 landing_time 直接入睡
	_apply_flight_collision(false)  # 落地用站立碰撞箱


func _player_home_dist() -> float:
	return GridPathfinder.toroidal_delta_px(_player_pos(), _spawn_pos, terrain.map_size).length()


func _takeoff_velocity() -> void:
	var dir := toroidal_dir_to_player()
	var s := EnemyParams.FlyBird.take_off_speed
	velocity = Vector2(dir.x * s, -s * 0.75)
	use_gravity = true


func _update_facing() -> void:
	if state == State.SHOOT:
		# 射击时朝向弹道水平方向(含玩家速度预测,可能与正对玩家略有差异)。
		# v0 为 0(玩家近正上方)时不翻转,保持上一帧朝向防抖。
		var v0 := _bullet_v0()
		if v0 != 0.0:
			_set_facing(v0 < 0.0)
	else:
		var vx := velocity.x
		if absf(vx) > 5.0:
			_set_facing(vx < 0.0)


# 显式声明睡眠态，不依赖枚举次序。
func _is_asleep() -> bool:
	return state == State.SLEEP


# 状态进入 → 形变事件。enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
func _on_state_entered(s: int) -> void:
	match s:
		State.TAKE_OFF:
			squash.impulse(SquashStretch.Impulse.TAKE_OFF)
		State.CHARGE:
			squash.impulse(SquashStretch.Impulse.CHARGE)


func _apply_flight_collision(in_air: bool) -> void:
	# 站立用 CollisionPolygon2D,空中用 CollisionPolygon2D_fly。
	_active_stance = 1 if in_air else 0
	_sync_collision()


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
		var to_target := GridPathfinder.toroidal_delta_px(global_position, target, terrain.map_size)
		if to_target.length() <= spd * delta:
			global_position = target
			_path_index += 1
		else:
			velocity = to_target.normalized() * spd
			return
	_path = []


func _find_escape_column() -> Vector2:
	var grid: Array[Array] = terrain.get_grid_snapshot()
	if grid.is_empty():
		return global_position
	var cols := grid[0].size()
	var rows := grid.size()
	var bc := _cell_of(global_position)
	var ts := GameParameters.TILE_SIZE
	for drop in range(1, EnemyParams.FlyBird.escape_max_descent + 1):
		var row := posmod(bc.y + drop, rows)
		for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
			for side in [-1, 1]:
				var cell := Vector2i(posmod(bc.x + side * dist, cols), row)
				if _bird_can_pass(cell):
					return Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)
	for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
		for side in [-1, 1]:
			var cell := Vector2i(posmod(bc.x + side * dist, cols), bc.y)
			if _bird_can_pass(cell):
				return Vector2(cell.x * ts + ts * 0.5, global_position.y)
	return global_position


# 飞行碰撞箱贴在悬停路径点上，与地形和最近的环面障碍副本比较。
func _bird_can_pass(cell: Vector2i) -> bool:
	if terrain.empty():
		return false
	var center := _waypoint_world(cell)
	var bounds := Rect2(center + _fly_box_min, _fly_box_max - _fly_box_min)
	if terrain.rect_overlaps(bounds, GameParameters.TILE_SIZE, true):
		return false
	var anchored := GridPathfinder.anchor_to_nearest(center, global_position, terrain.map_size)
	bounds.position = anchored + _fly_box_min
	for obstacle in _obstacle_boxes:
		if bounds.intersects(obstacle):
			return false
	return true


func _collect_obstacles() -> void:
	_obstacle_boxes.clear()
	for player: Player in _players_frame():
		if _toroidal_dist_to(player.global_position) <= 600.0:
			_obstacle_boxes.append(_anchored_obstacle(player.collision_rect()))
	for enemy: EnemyBase in get_tree().get_nodes_in_group("enemies"):
		if enemy != self and enemy.get_viewport() == get_viewport() and enemy.collision_layer != 0 \
				and _toroidal_dist_to(enemy.global_position) <= 600.0:
			_obstacle_boxes.append(_anchored_obstacle(enemy.collision_rect()))


func _anchored_obstacle(rect: Rect2) -> Rect2:
	var anchored := GridPathfinder.anchor_to_nearest(rect.get_center(), global_position, terrain.map_size)
	return Rect2(anchored - rect.size * 0.5, rect.size)


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	# 按鸟自身碰撞箱能否通过 + 场上实体碰撞箱是否挡路判定可走性(见 _bird_can_pass)。
	# 目标格不可达(墙/挤不进/预算超限)时 astar_path_nearest 返回最近可达格的路径,
	# 避免空路径后直线硬冲卡墙。A* 启发式直扑目标,空旷区展开节点远少于 BFS。
	# 目标格变化或路径耗尽时重新寻路，移动碰撞由基类 _move_slide 处理。
	if cell == _path_target and not _path.is_empty():
		return
	_path_target = cell
	_collect_obstacles()
	_path = GridPathfinder.astar_path_nearest(terrain.get_grid_snapshot(), _cell_of(global_position), cell,
			EnemyParams.FlyBird.path_max_visit, _bird_can_pass, EnemyParams.FlyBird.search_radius_cells)
	_path_index = 0
	# 寻路未找到可行路径时计算脱困目标点，先水平或向下绕出障碍
	_escape_target = _find_escape_column() if _path.is_empty() else Vector2.INF
