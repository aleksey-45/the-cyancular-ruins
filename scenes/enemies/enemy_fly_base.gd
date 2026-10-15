class_name EnemyFlyBase
extends EnemyBase

# 飞行敌人基类:网格寻路 + 避障 + 直线兜底 + 站/飞碰撞箱切换,供能飞的敌人复用。
# ★ 寻路方法直接引用 EnemyParams.FlyBird 的参数(hover_altitude / fly_speed / path_max_visit / repath_interval);当前只有 FlyBird 一种飞行敌人,接受该耦合,新增飞行敌人时改成虚 getter。

var _ground_polygon: CollisionPolygon2D = null
var _fly_polygon: CollisionPolygon2D = null
var _fly_box_min: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最小角(已按 scale 换算)
var _fly_box_max: Vector2 = Vector2.ZERO   # 飞行碰撞箱 AABB 最大角(已按 scale 换算)
var _obstacle_boxes: Array[Rect2] = []     # 本次寻路的场上实体碰撞箱(玩家/其他敌人),当矩形障碍
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _path_target: Vector2i = Vector2i(-1, -1)  # 上次寻路目标格;未变且路径还在时跳过重寻(静态战斗砍搜索量)
var _repath_timer: float = 0.0
var _repath_phase: float = 0.0             # 随机错峰,避免 40 只鸟同帧 BFS
var _escape_target: Vector2 = Vector2.INF  # 死区逃逸目标(寻路空路径时水平脱离悬挑)


func _ready() -> void:
	super._ready()
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


func _apply_flight_collision(in_air: bool) -> void:
	if _ground_polygon != null:
		_ground_polygon.disabled = in_air
	if _fly_polygon != null:
		_fly_polygon.disabled = not in_air


func _waypoint_world(cell: Vector2i) -> Vector2:
	var ts := GameParameters.TILE_SIZE
	var p := Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
	p.y -= EnemyParams.FlyBird.hover_altitude
	return MazeGenerator.anchor_to_nearest(p, _player_pos(),
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func _follow_path(delta: float, fallback_target: Vector2 = Vector2.INF) -> void:
	if _path.is_empty():
		if fallback_target != Vector2.INF:
			# 死区逃逸:寻路空路径时朝逃逸目标巡航(先下潜到可走格,窄檐则水平挪出悬挑),别直线撞墙。
			if _escape_target != Vector2.INF:
				_fly_straight_to(_escape_target, delta)
			else:
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


# 死区逃逸目标:寻路空路径时在当前列逐行下探,找第一个鸟所在格可走的行(越贴近地面越开阔,宽天花板/悬挑基本必能脱困);下潜失败(地板级矮檐)退回当前行水平逃逸。
# ★ 目标是可走格的格中心而不是飞行高度:鸟必须真的落进该格 A* 才能起路,用飞行高度中心会让鸟停在格上两行(悬停 40px 约 2.5 格)、重回死区。
func _find_escape_column() -> Vector2:
	var grid := MazeGenerator.current_grid
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


# 鸟能否飞过该格:把飞行碰撞箱的真实 AABB(含 scale)套在该格上方悬停高度处,矩形覆盖任一实心格、或与场上实体碰撞箱(玩家/其他敌人)重叠 ⇒ 不可走。
func _bird_can_pass(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false   # ★ 空网格 = 不可走(**保守**方向)。注意方向与 TileQuery 的兜底相反,
	                   # ★ 空网格 = 不可走(保守方向),与 TileQuery 的兜底正好相反(它空网格返回 false = 没压到东西)⇒ 这条早退不能删。
	var ts := GameParameters.TILE_SIZE
	var ox := cell.x * ts + ts * 0.5
	var oy := cell.y * ts + ts * 0.5 - EnemyParams.FlyBird.hover_altitude
	# 逐格环面判定收在 core/tile_query.gd(实心或水都不可走:鸟不能游);这里刻意用未锚定的原心算矩形,跨接缝由逐格 posmod 兜住。
	if TileQuery.rect_overlaps_solid_or_liquid(
			Rect2(Vector2(ox, oy) + _fly_box_min, _fly_box_max - _fly_box_min), ts):
		return false
	if _obstacle_boxes.size() > 0:
		# 箱体锚到本鸟坐标的环面副本(与 _collect_obstacles 同帧),否则接缝处 wrapped 格坐标与鸟/障碍的 anchored 坐标差一个整图,Rect2 永不相交。
		var bird_center := MazeGenerator.anchor_to_nearest(Vector2(ox, oy), global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var bird_rect := Rect2(bird_center + _fly_box_min, _fly_box_max - _fly_box_min)
		for r in _obstacle_boxes:
			if bird_rect.intersects(r):
				return false
	return true


# 收集本次寻路的场上实体碰撞箱(玩家 + 其他敌人),只收附近(约 600px)的,避免 BFS 每格都和全图几十个实体判重叠。
func _collect_obstacles() -> void:
	_obstacle_boxes.clear()
	# PvP 有两个玩家:两人都当飞行障碍物(寻路别从对方身上/头顶穿)。走帧缓存去 group 分配。
	for p in _players_frame():
		var p2 := p as Node2D
		if p2 != null and _toroidal_dist_to(p2.global_position) <= 600.0:
			_obstacle_boxes.append(_collision_rect_of(p2))
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not (e is Node2D):
			continue
		# ★ 判据取碰撞层而不是 visible:碰撞层为 0 的实体(录制期保留的隐藏尸体已摘掉碰撞层)物理上已经可以穿过,仍当障碍会让飞鸟在空位置上绕路;白闪期仍可见仍实心,照旧算障碍。
		if int((e as CollisionObject2D).collision_layer) == 0:
			continue
		var epos := (e as Node2D).global_position
		if _toroidal_dist_to(epos) <= 600.0:
			_obstacle_boxes.append(_collision_rect_of(e))


# 求一个节点的世界碰撞 AABB:几何取自 CollisionAabb,只并激活的碰撞体(disabled 跳过,否则飞行鸟的站立箱、玩家未用姿态会撑大障碍箱);返回前把中心锚到本鸟坐标的环面副本,与 BFS 候选格同帧。
func _collision_rect_of(n: Node2D) -> Rect2:
	var rect: Rect2
	if CollisionAabb.has_any(n):
		rect = CollisionAabb.world_rect(n)
	else:
		rect = Rect2(n.global_position - Vector2(20, 20), Vector2(40, 40))
	var center := rect.get_center()
	var anchored := MazeGenerator.anchor_to_nearest(center, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return Rect2(anchored - rect.size * 0.5, rect.size)


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	# 可走性按鸟自身碰撞箱 + 场上实体碰撞箱判定(见 _bird_can_pass);目标格不可达时 astar_path_nearest 返回最近可达格的路径,避免空路径后直线硬冲卡墙。
	# 缓存:目标格没变且上次路径没走完 ⇒ 跳过昂贵的 A*;路径走完或目标格变化才重寻(障碍碰撞由 move_and_slide 兜底,不会穿墙)。
	if cell == _path_target and not _path.is_empty():
		return
	_path_target = cell
	_collect_obstacles()
	_path = MazeGenerator.astar_path_nearest(_cell_of(global_position), cell,
			EnemyParams.FlyBird.path_max_visit, _bird_can_pass, EnemyParams.FlyBird.search_radius_cells)
	_path_index = 0
	# 寻路失败(死区)→ 记逃逸目标,先水平挪出悬挑,下次重寻路即可爬升。
	_escape_target = _find_escape_column() if _path.is_empty() else Vector2.INF
