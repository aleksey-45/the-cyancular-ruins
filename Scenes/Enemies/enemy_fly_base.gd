class_name EnemyFlyBase
extends EnemyBase

# 飞行敌人基类:网格寻路 + 避障 + 直线兜底 + 站/飞碰撞箱切换。
# 这些能力原本都混在 EnemyFlyBird 里,与 FlyBird 的具体行为(射击/冲撞/返程)
# 无关,抽出来供"能飞的敌人"复用。
#
# 注意:寻路方法引用了 EnemyParams.FlyBird 的参数(hover_altitude / fly_speed /
# path_max_visit / repath_interval)。当前项目只有 FlyBird 一种飞行敌人,接受该耦合;
# 若将来新增飞行敌人,可把这些参数改成虚 getter 让子类覆写。

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
	# 站立用 CollisionPolygon2D,空中用 CollisionPolygon2D_fly。
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
			# 死区逃逸:寻路空路径时朝逃逸目标巡航(先下潜到可走格,窄檐则水平挪出悬挑),
			# 别直线撞墙。目标带 y,鸟真正下飞,不再锁死当前高度。
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


# 死区逃逸目标:寻路空路径(A* 无路)时鸟找不到可走的飞行格。先在当前列逐行下探,
# 找第一个「鸟所在格可走」的行 —— 越贴近地面越开阔,宽天花板/悬挑基本必能脱困;
# 下潜失败(如地板级矮檐)退回当前行水平逃逸(与改动前一致)。目标是可走格的格中心
# (不是飞行高度):鸟必须真的落进这个可走格,A* 才能从该格起路;飞行高度中心会让鸟
# 停在格上两行(悬停高度 40px ≈ 2.5 格)、重回死区。
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
			if TileDefs.is_blocked(grid[posmod(gy, rows)][posmod(gx, cols)]):
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
	# 目标格不可达(墙/挤不进/预算超限)时 astar_path_nearest 返回最近可达格的路径,
	# 避免空路径后直线硬冲卡墙。A* 启发式直扑目标,空旷区展开节点远少于 BFS。
	# 缓存:目标格没变、上次路径还没走完 → 跳过昂贵的 A*。玩家静止时射击位/回家路
	# 不变,鸟群不再每 0.5s 反复搜索;路径走完或目标格变化才重寻(障碍碰撞由
	# move_and_slide 兜底,不会穿墙)。
	if cell == _path_target and not _path.is_empty():
		return
	_path_target = cell
	_collect_obstacles()
	_path = MazeGenerator.astar_path_nearest(_cell_of(global_position), cell,
			EnemyParams.FlyBird.path_max_visit, _bird_can_pass)
	_path_index = 0
	# 寻路失败(死区)→ 记逃逸目标,先水平挪出悬挑,下次重寻路即可爬升。
	_escape_target = _find_escape_column() if _path.is_empty() else Vector2.INF
