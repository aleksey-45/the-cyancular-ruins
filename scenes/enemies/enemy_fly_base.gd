class_name EnemyFlyBase
extends EnemyBase



var _ground_polygon: CollisionPolygon2D = null
var _fly_polygon: CollisionPolygon2D = null
var _fly_box_min: Vector2 = Vector2.ZERO
var _fly_box_max: Vector2 = Vector2.ZERO
var _obstacle_boxes: Array[Rect2] = []
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _path_target: Vector2i = Vector2i(-1, -1)
var _repath_timer: float = 0.0
var _repath_phase: float = 0.0
var _escape_target: Vector2 = Vector2.INF


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


func _fly_straight_to(target: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := MazeGenerator.toroidal_delta_px(global_position, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if to_target.length() <= spd * delta:
		global_position = target
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


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


func _bird_can_pass(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var ts := GameParameters.TILE_SIZE
	var ox := cell.x * ts + ts * 0.5
	var oy := cell.y * ts + ts * 0.5 - EnemyParams.FlyBird.hover_altitude
	if TileQuery.rect_overlaps_solid_or_liquid(
			Rect2(Vector2(ox, oy) + _fly_box_min, _fly_box_max - _fly_box_min), ts):
		return false
	if _obstacle_boxes.size() > 0:
		var bird_center := MazeGenerator.anchor_to_nearest(Vector2(ox, oy), global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var bird_rect := Rect2(bird_center + _fly_box_min, _fly_box_max - _fly_box_min)
		for r in _obstacle_boxes:
			if bird_rect.intersects(r):
				return false
	return true


func _collect_obstacles() -> void:
	_obstacle_boxes.clear()
	for p in _players_frame():
		var p2 := p as Node2D
		if p2 != null and _toroidal_dist_to(p2.global_position) <= 600.0:
			_obstacle_boxes.append(_collision_rect_of(p2))
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not (e is Node2D):
			continue
		if int((e as CollisionObject2D).collision_layer) == 0:
			continue
		var epos := (e as Node2D).global_position
		if _toroidal_dist_to(epos) <= 600.0:
			_obstacle_boxes.append(_collision_rect_of(e))


func _collision_rect_of(n: Node2D) -> Rect2:
	var rect := HitShape.rect_of(n)
	var center := rect.get_center()
	var anchored := MazeGenerator.anchor_to_nearest(center, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return Rect2(anchored - rect.size * 0.5, rect.size)


func _schedule_repath() -> void:
	_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase


func _repath_to(cell: Vector2i) -> void:
	if cell == _path_target and not _path.is_empty():
		return
	_path_target = cell
	_collect_obstacles()
	_path = MazeGenerator.astar_path_nearest(_cell_of(global_position), cell,
			EnemyParams.FlyBird.path_max_visit, _bird_can_pass, EnemyParams.FlyBird.search_radius_cells)
	_path_index = 0
	_escape_target = _find_escape_column() if _path.is_empty() else Vector2.INF
