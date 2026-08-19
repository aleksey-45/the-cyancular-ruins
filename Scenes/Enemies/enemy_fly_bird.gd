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
var _strafe_target: Vector2 = Vector2.INF  # 开火后短距随机移动目标;INF=未在移动
var _strafe_timer: float = 0.0             # 短距移动剩余时长
var _landing: bool = false           # RETURN 落地阶段
var _ground_polygon: CollisionPolygon2D = null
var _fly_polygon: CollisionPolygon2D = null
var _spawn_captured: bool = false   # 出生点是否已抓取(等 spawner 设好位置再取,否则是 (0,0))
var _fly_box_min: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最小角(已按 scale 换算)
var _fly_box_max: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最大角(已按 scale 换算)
var _obstacle_boxes: Array[Rect2] = []     # 本次寻路的场上实体碰撞箱(玩家/其他敌人),当矩形障碍


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	# 出生点不在此抓取:spawner 是 add_child 之后才设位置,_ready 里抓到的是 (0,0),
	# 会害 _player_home_dist()/返程全错(鸟一醒就返程、不追玩家)。改在首帧物理补抓。
	_max_hp = hp
	_ground_polygon = $CollisionPolygon2D
	_fly_polygon = $CollisionPolygon2D_fly
	if _fly_polygon != null:
		var pts := _fly_polygon.polygon
		if pts.size() > 0:
			var mn := pts[0]
			var mx := pts[0]
			for p in pts:
				mn = mn.min(p)
				mx = mx.max(p)
			_fly_box_min = mn * scale
			_fly_box_max = mx * scale
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
	if is_dead:  # 死亡直接销毁(本帧末 queue_free),不再处理物理
		return
	super._physics_process(delta)
	# 冲撞撞到东西(super 已执行 move_and_slide)
	if state == State.CHARGE and get_slide_collision_count() > 0:
		_on_charge_impact()


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
				_repath_to(_shoot_cell())
			# 空路径(BFS 无路/预算超限)时直线飞向射击位,不再原地返程发呆。
			_follow_path(delta, _shoot_pos())
		State.SHOOT:
			_anim.play("flying")
			if _player_home_dist() > EnemyParams.FlyBird.home_range:
				_start_return()
				return
			_update_charge_intent_if_needed()
			if intent == Intent.CHARGE:
				if _try_charge():
					return
				# LOS 被堵:不再原地抛弹,退回 FLY 拉距离找 LOS(对齐 spec §1.4)
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
				if _strafe_timer <= 0.0 or (_strafe_target - global_position).length() <= EnemyParams.FlyBird.fly_speed * delta:
					_strafe_target = Vector2.INF
			else:
				_hover_to_anchor(delta)
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
		State.CHARGE:
			_state_timer += delta
			# 接触区/贴脸距离命中玩家直接结算(弥补 slide 碰撞偶尔穿过的情形)。
			if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
				_on_charge_hit_player()
			elif _state_timer >= EnemyParams.FlyBird.charge_timeout:
				_die_self()
		State.RETURN:
			_anim.play("flying")
			if _landing:
				# 落地阶段:开重力直接下坠,计时到点即入睡,不再等地板接触。
				# (FLOATING 模式下 is_on_floor 恒 false,靠碰撞法线判地面在个别
				#  出生位/接缝处永远等不到,鸟会卡在 RETURN 不睡)
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


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
		_die_self()


# 死亡:直接销毁,不坠落(冲撞自毁与受击死亡同走本方法)。
func _die_self() -> void:
	if is_dead:
		return
	is_dead = true
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


func _follow_path(delta: float, fallback_target: Vector2 = Vector2.INF) -> void:
	if _path.is_empty():
		if fallback_target != Vector2.INF:
			_fly_straight_to(fallback_target, delta)
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


# BFS 无路/预算超限时的直线兜底:向目标点直线飞行(鸟飞越低墙,直线基本可行)。
func _fly_straight_to(target: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := MazeGenerator.toroidal_delta_px(global_position, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if to_target.length() <= spd * delta:
		global_position = target
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


# 鸟能否飞过该格:用鸟飞行碰撞箱的真实 AABB(_fly_box_min/_fly_box_max,含 scale)套在
# 该格上方悬停高度处,矩形覆盖的任一实心格 → 不可走;再与场上实体碰撞箱(玩家/其他
# 敌人,已收集进 _obstacle_boxes)当矩形判重叠 → 不可走。这样 BFS 只规划鸟挤得过、
# 且不穿场上有实体的路。
func _bird_can_pass(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := grid[0].size()
	var ts := GameParameters.TILE_SIZE
	# 鸟原心 = 格中心 − hover_altitude(悬停上移);箱体世界范围 = 原心 + AABB。
	var ox := cell.x * ts + ts * 0.5
	var oy := cell.y * ts + ts * 0.5 - EnemyParams.FlyBird.hover_altitude
	var x0 := floori((ox + _fly_box_min.x) / ts)
	var x1 := floori((ox + _fly_box_max.x) / ts)
	var y0 := floori((oy + _fly_box_min.y) / ts)
	var y1 := floori((oy + _fly_box_max.y) / ts)
	for gy in range(y0, y1 + 1):
		for gx in range(x0, x1 + 1):
			if grid[posmod(gy, rows)][posmod(gx, cols)] == MazeGenerator.SOLID:
				return false
	if _obstacle_boxes.size() > 0:
		# 箱体锚到本鸟坐标的环面副本(与 _collect_obstacles 同帧),否则地图接缝处
		# wrapped 格坐标与鸟/障碍的 anchored 坐标差一个整图,Rect2 永不相交。
		var bird_center := MazeGenerator.anchor_to_nearest(Vector2(ox, oy), global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var bird_rect := Rect2(bird_center + _fly_box_min, _fly_box_max - _fly_box_min)
		for r in _obstacle_boxes:
			if bird_rect.intersects(r):
				return false
	return true


# 收集本次寻路的场上实体碰撞箱(玩家 + 其他敌人),只收附近(≈600px)的,避免 BFS
# 每格都和全图几十个实体判重叠。
func _collect_obstacles() -> void:
	_obstacle_boxes.clear()
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if p != null and _toroidal_dist_to(p.global_position) <= 600.0:
		_obstacle_boxes.append(_collision_rect_of(p))
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not (e is Node2D):
			continue
		var epos := (e as Node2D).global_position
		if _toroidal_dist_to(epos) <= 600.0:
			_obstacle_boxes.append(_collision_rect_of(e))


# 求一个节点的世界碰撞 AABB(遍历 CollisionShape2D/CollisionPolygon2D 子节点)。
# 只并**激活**的碰撞体:disabled 跳过——飞行鸟的站立箱、玩家未用姿态的多边形运行时
# 都被禁用,合并它们会把障碍箱撑得比实际碰撞体大一圈(旧实现全并,详见问题三)。
# 返回前把矩形中心锚到本鸟坐标的环面副本,与 BFS 候选格同帧(见 _bird_can_pass)。
func _collision_rect_of(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		# CollisionPolygon2D 继承自 CollisionShape2D,先判多边形,否则走 shape 分支被跳过。
		if not (child is CollisionShape2D):
			continue
		if (child as CollisionShape2D).disabled:
			continue
		if child is CollisionPolygon2D:
			var cp := child as CollisionPolygon2D
			var pts := cp.polygon
			if pts.size() == 0:
				continue
			var mn := cp.to_global(pts[0])
			var mx := mn
			for pt in pts:
				var w := cp.to_global(pt)
				mn = mn.min(w)
				mx = mx.max(w)
			var r := Rect2(mn, mx - mn)
			rect = r if not has else rect.merge(r)
			has = true
		else:
			var cs := child as CollisionShape2D
			var shape := cs.shape
			if shape == null:
				continue
			var r: Rect2
			if shape is RectangleShape2D:
				var size := (shape as RectangleShape2D).size * cs.global_scale
				r = Rect2(cs.global_position - size * 0.5, size)
			elif shape is CircleShape2D:
				var rad := (shape as CircleShape2D).radius * maxf(cs.global_scale.x, cs.global_scale.y)
				r = Rect2(cs.global_position - Vector2(rad, rad), Vector2(rad, rad) * 2.0)
			else:
				continue
			rect = r if not has else rect.merge(r)
			has = true
	if not has:
		rect = Rect2(n.global_position - Vector2(20, 20), Vector2(40, 40))
	var center := rect.get_center()
	var anchored := MazeGenerator.anchor_to_nearest(center, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return Rect2(anchored - rect.size * 0.5, rect.size)


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	# 按鸟自身碰撞箱能否通过 + 场上实体碰撞箱是否挡路判定可走性(见 _bird_can_pass)。
	# 目标格不可达(墙/挤不进/预算超限)时 bfs_path_nearest 返回最近可达格的路径,
	# 避免空路径后直线硬冲卡墙。
	_collect_obstacles()
	_path = MazeGenerator.bfs_path_nearest(_cell_of(global_position), cell, 4000, _bird_can_pass)
	_path_index = 0


# 斜上射击位(与 SHOOT 锚点同一逻辑):玩家侧向 + 上方,鸟不穿越玩家头顶。
# 该侧被墙挡时换另一侧;世界坐标与格坐标共用同一侧,保证 BFS 目标可到、直线兜底同向。
func _shoot_side() -> float:
	var delta := toroidal_delta_to_player()
	return -1.0 if delta.x > 0.0 else 1.0


func _shoot_pos() -> Vector2:
	var p := _player_pos()
	var side := _shoot_side()
	var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(pos)):
		pos = p + Vector2(-side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	return pos


func _shoot_cell() -> Vector2i:
	return _cell_of(_shoot_pos())


# 是否已在斜上射击位附近:SHOOT 只应在鸟接近锚点时进入,否则下方/远方的鸟会
# 直线硬插到锚点被墙卡住。未就位时留在 FLY,靠 BFS 绕到玩家上方再进 SHOOT。
func _near_shoot_pos() -> bool:
	return _toroidal_dist_to(_shoot_pos()) <= EnemyParams.FlyBird.shoot_position_radius


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
	_glide_to(_hover_anchor, delta)


# 以 fly_speed 向 point 直线滑翔(悬停归位 / 开火后短距随机移动共用)。
func _glide_to(point: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := point - global_position
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
func _shot_clear() -> bool:
	return MazeGenerator.has_line_of_sight(_cell_of(global_position), _cell_of(_player_pos()))


func _fire_parabolic() -> void:
	# 平抛:水平初速 + 重力,落点按玩家坐标 + 玩家即时速度预测。
	var v0 := _bullet_v0()
	var b: EnemyBullet = ENEMY_BULLET_SCENE.instantiate()
	b.launch(Vector2(v0, 0.0), EnemyParams.FlyBird.bullet_range,
			EnemyParams.FlyBird.bullet_damage, EnemyParams.FlyBird.bullet_gravity,
			EnemyParams.FlyBird.bullet_size)
	b.global_position = global_position
	get_viewport().add_child(b)
	# 开火后座:沿发射反方向轻推鸟(v0 符号即发射方向)。
	velocity += Vector2(-signf(v0) * EnemyParams.FlyBird.shoot_recoil, 0.0)


# 平抛水平初速(含玩家即时速度预测):开火与朝向共用,符号即弹道水平方向。
# 落差 = 玩家.y − 鸟.y(玩家在鸟下方为正);玩家高于鸟时夹到下限,弹道偏近属预期。
func _bullet_v0() -> float:
	var drop := maxf(_player_pos().y - global_position.y, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
	var pred := _player_pos() + _player_velocity() * t
	var dx := pred.x - global_position.x
	if absf(dx) > GameParameters.MAP_WIDTH * 0.5:
		dx = -signf(dx) * (GameParameters.MAP_WIDTH - absf(dx))
	return clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)


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
	use_gravity = false  # 冲撞为水平直线,不吃重力
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	_anim.play("dashing")


func _on_charge_impact() -> void:
	if is_dead:  # 本帧若已由接触判定自毁,避免二次结算
		return
	for i in range(get_slide_collision_count()):
		var collider := get_slide_collision(i).get_collider()
		if collider != null and collider.is_in_group("player") and collider.has_method("take_hit"):
			# 冲撞穿透无敌帧,命中必掉血(自杀攻击的威慑)
			collider.take_hit(global_position, EnemyParams.FlyBird.charge_damage, true)
			_apply_charge_impact(collider)
			break
	_die_self()


# 冲撞接触命中玩家:接触区/距离判定触发,伤害 + 自毁。
func _on_charge_hit_player() -> void:
	if is_dead:
		return
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit"):
		# 冲撞穿透无敌帧,命中必掉血(自杀攻击的威慑)
		p.take_hit(global_position, EnemyParams.FlyBird.charge_damage, true)
		_apply_charge_impact(p)
	_die_self()


# 冲撞冲击力:沿远离鸟的方向猛推玩家(覆盖 take_hit 的普通击退,冲撞更狠)。
func _apply_charge_impact(p: Node) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * EnemyParams.FlyBird.charge_impact
	p2.velocity.y -= EnemyParams.FlyBird.charge_impact_up


func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	_anim.play("flying")
	# 玩家太远时不启动任何搜索,清空路径交给 RETURN 的直线兜底飞回家。
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
			_anim.flip_h = v0 < 0.0
	else:
		var vx := velocity.x
		if absf(vx) > 5.0:
			_anim.flip_h = vx < 0.0


func _anim_duration(name: String) -> float:
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)
