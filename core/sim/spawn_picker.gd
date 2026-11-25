class_name SpawnPicker
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const NO_CELL := Vector2i(-1, -1)
const SUPPORT_ROWS := 2
const PREFERRED_DISTANCE := 32  # 子格，512 像素

static func single_spawn(map: Dictionary) -> Vector2i:
	var id := CyrmMap.first_point_id(map, "player")
	if id >= 0: return map.points[id].cell
	TileDefs.load_defs()
	var cells: PackedInt32Array = map.layers[CyrmMap.SCENE]
	for i in cells.size():
		if cells[i] == 0:
			var at := Vector2i(i % map.size.x, i / map.size.x)
			if _first_wall(cells, map.size, _standing_subrect(at)) == null: return at
	return NO_CELL

static func floor_cells(map: Dictionary) -> Array[Vector2i]:
	TileDefs.load_defs()
	var floors: Array[Vector2i] = []
	var cells: PackedInt32Array = map.layers[CyrmMap.SCENE]
	var size: Vector2i = map.size
	for y in size.y:
		var below := ((y + 1) % size.y) * size.x
		var above := posmod(y - 1, size.y) * size.x
		for x in size.x:
			if cells[y * size.x + x] == 0 and cells[above + x] == 0 and TileDefs.is_blocked(CyrmMap.tile_material(cells[below + x])):
				floors.append(Vector2i(x, y))
	return floors

## 打乱顺序后，取第一个距离足够的点。距离都不足时，选最近威胁最远的点。
static func pick(pool: Array, occupied: Array[Vector2i], avoid: Array[Vector2i], size: Vector2i,
		rng: RandomNumberGenerator) -> Vector2i:
	var candidates := pool.duplicate()
	MathUtil.shuffle(candidates, rng)
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

static func respawn_cells(map: Dictionary) -> Dictionary:
	var sides := {1: [], 2: []}
	for point: Dictionary in map.points.values():
		if point.kind == "respawn": sides[point.side].append(point.cell)
	return sides

## 合格出生点能容纳的开局人数。零表示该模式无法开局。
static func player_limit(sides: Dictionary, mode: String, options := {}) -> int:
	var a: int = sides[1].size()
	var b: int = sides[2].size()
	var limit := RoomOptions.capacity(mode, options)
	if mode == WorldSpec.ROYALE:
		return mini(a + b, limit) if a + b >= RoomOptions.MIN_PLAYERS else 0
	var per_side := TeamRules.MAX_TEAM if mode == WorldSpec.TEAM else 1
	return limit if mini(a, b) >= per_side else 0

## 联机共用地图标注的出生点，开局时检查净空、支撑及连通性。
static func validate_multiplayer_spawns(map: Dictionary) -> String:
	TileDefs.load_defs()
	var descriptors: PackedInt32Array = map.layers[CyrmMap.SCENE]
	var dims: Vector2i = map.size
	var occupied := {}
	for point: Dictionary in map.points.values():
		if point.kind != "respawn": continue
		var cell: Vector2i = point.cell
		var problem := spawn_cell_problem(map, cell)
		if problem.is_empty() and occupied.has(cell): problem = "与其他出生点重合"
		if not problem.is_empty():
			return "侧 %d 出生点 (%d, %d) %s" % [point.side, cell.x, cell.y, problem]
		occupied[cell] = point.side
	if occupied.is_empty():
		return "缺少联机出生点"
	var reachable := _clear_region(descriptors, dims, occupied.keys()[0])
	for cell: Vector2i in occupied:
		if reachable[cell.y * dims.x + cell.x] != 2:
			return "侧 %d 出生点 (%d, %d) 不在同一静态空域" % [occupied[cell], cell.x, cell.y]
	return ""

static func spawn_cell_problem(map: Dictionary, cell: Vector2i) -> String:
	TileDefs.load_defs()
	var dims: Vector2i = map.size
	var descriptors: PackedInt32Array = map.layers[CyrmMap.SCENE]
	if not Rect2i(Vector2i.ZERO, dims).has_point(cell):
		return "坐标越界（地图 %dx%d）" % [dims.x, dims.y]
	if descriptors.is_empty():
		return "地图缺少 16px 子格数据"
	var bounds := _standing_subrect(cell)
	var wall: Variant = _first_wall(descriptors, dims, bounds)
	if wall != null:
		return "角色净空被 16px 子格阻挡 (%d, %d)" % [wall.x, wall.y]
	var feet := bounds.end.y
	for y in range(ceili(feet), floori(feet) + SUPPORT_ROWS):
		var support := 0
		for x in range(floori(bounds.position.x), ceili(bounds.end.x)):
			if _wall_at(descriptors, dims, x, y):
				support += 1
		if support >= 3:
			return ""
	return "脚下没有支撑"

static func _standing_subrect(cell: Vector2i) -> Rect2:
	var center := CyrmMap.world_position(cell)
	var hull := CFG.standing_hull
	return Rect2((center + hull.position * CFG.body_scale) / Terrain.SUB_SIZE,
			hull.size * CFG.body_scale / Terrain.SUB_SIZE)

static func _wall_at(descriptors: PackedInt32Array, size: Vector2i, x: int, y: int) -> bool:
	var index := posmod(y, size.y) * size.x + posmod(x, size.x)
	var texture := CyrmMap.tile_material(descriptors[index])
	return texture != 0 and TileDefs.types[texture] == TileDefs.TYPE_WALL

static func _first_wall(descriptors: PackedInt32Array, size: Vector2i, bounds: Rect2) -> Variant:
	for y in range(floori(bounds.position.y), ceili(bounds.end.y)):
		for x in range(floori(bounds.position.x), ceili(bounds.end.x)):
			if _wall_at(descriptors, size, x, y):
				return Vector2i(x, y)
	return null

## 横向和纵向各滑动一次角色包围盒，为这次连通性检查标出能容纳角色的子格。
static func _clear_region(cells: PackedInt32Array, size: Vector2i, start: Vector2i) -> PackedByteArray:
	var hull := _standing_subrect(Vector2i.ZERO)
	var first := Vector2i(hull.position.floor())
	var end := Vector2i(hull.end.ceil())
	var walls := PackedByteArray()
	walls.resize(cells.size())
	for i in cells.size():
		walls[i] = int(TileDefs.is_blocked(CyrmMap.tile_material(cells[i])))
	var horizontal := PackedByteArray()
	horizontal.resize(cells.size())
	for y in size.y:
		var row := y * size.x
		var count := 0
		for dx in range(first.x, end.x): count += walls[row + posmod(dx, size.x)]
		for x in size.x:
			horizontal[row + x] = int(count > 0)
			count += walls[row + posmod(x + end.x, size.x)] - walls[row + posmod(x + first.x, size.x)]
	var clear := PackedByteArray()
	clear.resize(cells.size())
	for x in size.x:
		var count := 0
		for dy in range(first.y, end.y): count += horizontal[posmod(dy, size.y) * size.x + x]
		for y in size.y:
			clear[y * size.x + x] = int(count == 0)
			count += horizontal[posmod(y + end.y, size.y) * size.x + x] - horizontal[posmod(y + first.y, size.y) * size.x + x]
	var queue := PackedInt32Array([start.y * size.x + start.x])
	clear[queue[0]] = 2
	var cursor := 0
	while cursor < queue.size():
		var i := queue[cursor]
		cursor += 1
		var x := i % size.x
		var y := i / size.x
		for step: Vector2i in GridPathfinder.DIRECTIONS:
			var next := posmod(y + step.y, size.y) * size.x + posmod(x + step.x, size.x)
			if clear[next] == 1:
				clear[next] = 2
				queue.append(next)
	return clear
