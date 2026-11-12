class_name SpawnPicker
extends RefCounted

const DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
const NO_CELL := Vector2i(-1, -1)

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

static func far_spawn_from(anchor: Vector2i, floor: Array[Vector2i], size: Vector2i) -> Vector2i:
	var best := NO_CELL
	var best_distance := 0
	for cell in floor:
		var distance := GridPathfinder.toroidal_dist(cell, anchor, size.x, size.y)
		if distance >= 15:
			return cell
		if distance > best_distance:
			best = cell
			best_distance = distance
	return best

## 按净空和地表连通规模依次放宽候选条件。
static func respawn_pools(grid: Array[Array], floor: Array[Vector2i], size: Vector2i) -> Array[Array]:
	var sizes := _region_sizes(floor, size)
	var largest := 0
	for cell in floor:
		largest = maxi(largest, sizes[cell.y * size.x + cell.x])
	var threshold := 20 if largest >= 20 else maxi(1, ceili(largest * 0.5))
	var roomy: Array[Vector2i] = []
	var large: Array[Vector2i] = []
	var linked: Array[Vector2i] = []
	for cell in floor:
		var region := sizes[cell.y * size.x + cell.x]
		if region >= 2:
			linked.append(cell)
		if region >= threshold:
			large.append(cell)
			if _roomy(grid, cell, size):
				roomy.append(cell)
	if roomy.size() >= 8:
		return [roomy, large, linked]
	if large.size() >= 8:
		return [large, linked]
	return [floor]

static func _roomy(grid: Array[Array], cell: Vector2i, size: Vector2i) -> bool:
	for offset: Vector2i in [Vector2i(0, -2), Vector2i.LEFT, Vector2i.RIGHT]:
		var at := cell + offset
		if grid[posmod(at.y, size.y)][posmod(at.x, size.x)] != MapFormat.EMPTY:
			return false
	return true

static func _region_sizes(floor: Array[Vector2i], size: Vector2i) -> PackedInt32Array:
	var sizes := PackedInt32Array()
	sizes.resize(size.x * size.y)
	for cell in floor:
		sizes[cell.y * size.x + cell.x] = -1
	for cell in floor:
		var start := cell.y * size.x + cell.x
		if sizes[start] != -1:
			continue
		var region := [start]
		sizes[start] = 0
		var cursor := 0
		while cursor < region.size():
			var index: int = region[cursor]
			var at := Vector2i(index % size.x, index / size.x)
			cursor += 1
			for offset: Vector2i in DIRECTIONS:
				var x := posmod(at.x + offset.x, size.x)
				var y := posmod(at.y + offset.y, size.y)
				var next := y * size.x + x
				if sizes[next] == -1:
					sizes[next] = 0
					region.append(next)
		for index in region:
			sizes[index] = region.size()
	return sizes
