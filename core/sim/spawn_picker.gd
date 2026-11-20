class_name SpawnPicker
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const NO_CELL := Vector2i(-1, -1)
const SUPPORT_ROWS := 2
const PREFERRED_DISTANCE := 8  # 瓦片

static func single_spawn(map: Dictionary) -> Vector2i:
	if map["spawns"].has("player"):
		return map["spawns"]["player"]
	var grid: Array[Array] = map["grid"]
	var size: Vector2i = map["size"]
	for y in size.y:
		for x in size.x:
			if grid[y][x] == MapFormat.EMPTY:
				return Vector2i(x, y)
	return NO_CELL

static func floor_cells(grid: Array[Array], size: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in size.y:
		for x in size.x:
			var cell := Vector2i(x, y)
			if GridPathfinder.is_floor_cell_with_headroom(grid, cell):
				cells.append(cell)
	return cells

## 打乱顺序后，取第一个距离足够的点。距离都不足时，选最近威胁最远的点。
static func pick(pool: Array, occupied: Array[Vector2i], avoid: Array[Vector2i], size: Vector2i) -> Vector2i:
	var candidates := pool.duplicate()
	candidates.shuffle()
	var best := NO_CELL
	var best_distance := -1
	for cell: Vector2i in candidates:
		if occupied.has(cell):
			continue
		var distance := PREFERRED_DISTANCE
		for other in avoid:
			distance = mini(distance, GridPathfinder.toroidal_dist(cell, other, size.x, size.y))
		if distance == PREFERRED_DISTANCE:
			return cell
		if distance > best_distance:
			best = cell
			best_distance = distance
	return best

## 联机共用地图标注的出生点，开局时检查净空、支撑及连通性。
static func validate_multiplayer_spawns(info: Dictionary) -> String:
	TileDefs.load_defs()
	var descriptors: PackedInt32Array = info["descriptors"]
	var spawns: Dictionary = info["spawns"]
	var errors: Array = spawns["respawn_errors"]
	if not errors.is_empty():
		return "respawn 元数据格式错误：%s" % errors[0]
	var respawn: Dictionary = spawns["respawn"]
	var dims: Vector2i = info["size"]
	var occupied := {}
	for side: int in [1, 2]:
		for cell: Vector2i in respawn[side]:
			var problem := spawn_cell_problem(descriptors, dims, cell)
			if problem.is_empty() and occupied.has(cell):
				problem = "与其他出生点重合"
			if not problem.is_empty():
				return "侧 %d 出生点 (%d, %d) 不合格：%s" % [side, cell.x, cell.y, problem]
			occupied[cell] = side
	if occupied.is_empty():
		return "缺少联机出生点（# respawn）"
	var reachable := _clear_region(descriptors, dims, occupied.keys()[0])
	for cell: Vector2i in occupied:
		if not reachable.has(cell):
			return "侧 %d 出生点 (%d, %d) 不在同一静态空域" % [occupied[cell], cell.x, cell.y]
	return ""

static func spawn_cell_problem(descriptors: PackedInt32Array, dims: Vector2i, cell: Vector2i) -> String:
	if not Rect2i(Vector2i.ZERO, dims).has_point(cell):
		return "坐标越界（地图 %dx%d）" % [dims.x, dims.y]
	if descriptors.is_empty():
		return "地图缺少 16px 子格数据"
	var size := dims * Terrain.SUB_PER_CELL
	var bounds := _standing_subrect(cell)
	var wall: Variant = _first_wall(descriptors, size, bounds)
	if wall != null:
		return "角色净空被 16px 子格阻挡 (%d, %d)" % [wall.x, wall.y]
	var feet := bounds.end.y
	for y in range(ceili(feet), floori(feet) + SUPPORT_ROWS):
		var support := 0
		for x in range(floori(bounds.position.x), ceili(bounds.end.x)):
			if _wall_at(descriptors, size, x, y):
				support += 1
		if support >= 3:
			return ""
	return "脚下没有支撑"

static func _standing_subrect(cell: Vector2i) -> Rect2:
	var center := (Vector2(cell) + Vector2(0.5, 0.5)) * Terrain.TILE_SIZE
	var hull := CFG.standing_hull
	return Rect2((center + hull.position * CFG.body_scale) / Terrain.SUB_SIZE,
			hull.size * CFG.body_scale / Terrain.SUB_SIZE)

static func _wall_at(descriptors: PackedInt32Array, size: Vector2i, x: int, y: int) -> bool:
	var index := posmod(y, size.y) * size.x + posmod(x, size.x)
	var texture := MapFormatV4.descriptor_texture(descriptors[index])
	return texture != 0 and TileDefs.types[texture] == TileDefs.TYPE_WALL

static func _first_wall(descriptors: PackedInt32Array, size: Vector2i, bounds: Rect2) -> Variant:
	for y in range(floori(bounds.position.y), ceili(bounds.end.y)):
		for x in range(floori(bounds.position.x), ceili(bounds.end.x)):
			if _wall_at(descriptors, size, x, y):
				return Vector2i(x, y)
	return null

## 从出生点沿相邻瓦片搜索，仅经过有完整站立空间的位置。越过地图边缘时继续检查另一侧。
static func _clear_region(descriptors: PackedInt32Array, dims: Vector2i, start: Vector2i) -> Dictionary:
	var size := dims * Terrain.SUB_PER_CELL
	var visited := {start: true}
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		for step: Vector2i in GridPathfinder.DIRECTIONS:
			var next := Vector2i(posmod(cell.x + step.x, dims.x), posmod(cell.y + step.y, dims.y))
			if not visited.has(next) and _first_wall(descriptors, size, _standing_subrect(next)) == null:
				visited[next] = true
				stack.append(next)
	return visited
