class_name SpawnPicker
extends RefCounted


const OPEN_AREA_MIN: int = 20
const PREFER_MIN: int = 8

const ADAPTIVE_RATIO: float = 0.5

static var _floor_cell_cache: Array = []
static var _prefer_cache: Array = []
static var _fallback_cache: Array = []
static var _last_resort_cache: Array = []
static var _region_cache: Dictionary = {}
static var _reach_cache: Dictionary = {}
static var _reach_main_size := 0
static var _reach_sizes: Array = []


static func reset_cache() -> void:
	_floor_cell_cache = []
	_prefer_cache = []
	_fallback_cache = []
	_last_resort_cache = []
	_region_cache = {}
	_reach_cache = {}
	_reach_main_size = 0
	_reach_sizes = []


static func grid_dims() -> Vector2i:
	var grid := MazeGenerator.current_grid
	return Vector2i((grid[0] as Array).size(), grid.size())


static func floor_cells() -> Array:
	if not _floor_cell_cache.is_empty():
		return _floor_cell_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				_floor_cell_cache.append(c)
	return _floor_cell_cache


static func region_sizes() -> Dictionary:
	if not _region_cache.is_empty():
		return _region_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return {}
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	var seen := {}
	for y in rows:
		for x in cols:
			var start := Vector2i(x, y)
			if seen.has(start) or not floor_cells_has(start):
				continue
			var stack: Array = [start]
			var members: Array = []
			seen[start] = true
			while not stack.is_empty():
				var cur: Vector2i = stack.pop_back()
				members.append(cur)
				for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nb := Vector2i(posmod(cur.x + off.x, cols), posmod(cur.y + off.y, rows))
					if seen.has(nb) or not floor_cells_has(nb):
						continue
					seen[nb] = true
					stack.append(nb)
			var sz := members.size()
			for m in members:
				_region_cache[m] = sz
	return _region_cache


static func floor_cells_has(c: Vector2i) -> bool:
	return MazeGenerator.is_floor_cell_with_headroom(MazeGenerator.current_grid, c)


static func roomy_floor(c: Vector2i) -> bool:
	if not floor_cells_has(c):
		return false
	var grid := MazeGenerator.current_grid
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	if grid[posmod(c.y - 1, rows)][c.x] != MazeGenerator.EMPTY \
			or grid[posmod(c.y - 2, rows)][c.x] != MazeGenerator.EMPTY:
		return false
	if grid[c.y][posmod(c.x - 1, cols)] != MazeGenerator.EMPTY \
			or grid[c.y][posmod(c.x + 1, cols)] != MazeGenerator.EMPTY:
		return false
	return true


static func max_region_size() -> int:
	var mx := 0
	for sz in region_sizes().values():
		mx = maxi(mx, int(sz))
	return mx


static func area_threshold() -> int:
	var mx := max_region_size()
	if mx >= OPEN_AREA_MIN:
		return OPEN_AREA_MIN
	return maxi(ceili(float(mx) * ADAPTIVE_RATIO), 1)


static func spawn_candidates() -> Array:
	if not _prefer_cache.is_empty():
		return _prefer_cache
	var floor: Array = floor_cells()
	var sizes := region_sizes()
	var thr := area_threshold()
	var big: Array = []
	var roomy: Array = []
	for c in floor:
		if int(sizes.get(c, 0)) >= thr:
			big.append(c)
			if roomy_floor(c):
				roomy.append(c)
	if roomy.size() >= PREFER_MIN:
		_prefer_cache = roomy
	elif big.size() >= PREFER_MIN:
		_prefer_cache = big
	else:
		_prefer_cache = floor
	return _prefer_cache


static func respawn_fallback() -> Array:
	if not _fallback_cache.is_empty():
		return _fallback_cache
	var thr := area_threshold()
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= thr:
			_fallback_cache.append(c)
	return _fallback_cache


static func respawn_last_resort() -> Array:
	if not _last_resort_cache.is_empty():
		return _last_resort_cache
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= 2:
			_last_resort_cache.append(c)
	return _last_resort_cache


static func respawn_pools() -> Array:
	return [spawn_candidates(), respawn_fallback(), respawn_last_resort()]


static func cells_within(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	if center.x < 0 or center.y < 0:
		return spawn_candidates().duplicate()
	var d := grid_dims()
	for c in spawn_candidates():
		if GridPathfinder.toroidal_dist(c, center, d.x, d.y) <= radius:
			out.append(c)
	return out if not out.is_empty() else spawn_candidates().duplicate()


# ── 给"只有一个出生点的图"挑 role2 的出生格(从 MatchBootstrap 搬来):搬家的理由是 MatchBootstrap 静态引用 autoload,在 -s 探针里编译失败 ⇒ 断言被静默跳过而 verdict 照打 OK。
const FAR_CELLS := 15


static func far_spawn_from(anchor: Vector2i, grid: Array) -> Vector2i:
	if grid.is_empty():
		return Vector2i(-1, -1)
	TileDefs.load_defs()
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var best := Vector2i(-1, -1)
	var best_d := -1
	for r in rows:
		var line: Array = grid[r]
		for c in min(cols, line.size()):
			if int(line[c]) != MapFormat.EMPTY:
				continue
			if not TileDefs.is_blocked(int(grid[(r + 1) % rows][c])):
				continue
			var d := MazeGenerator.toroidal_dist(anchor, Vector2i(c, r), cols, rows)
			if d >= FAR_CELLS:
				return Vector2i(c, r)
			if d > best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


static var _warned_unreachable := false


static func reachable_spawn_cells() -> Dictionary:
	if not _reach_cache.is_empty():
		return _reach_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return _reach_cache
	TileDefs.load_defs()
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var ids := PackedInt32Array()
	ids.resize(cols * rows)
	ids.fill(-1)
	var nodes: Array = []
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if _reach_standable(c, cols, rows) or _reach_liquid(c, cols, rows):
				ids[_reach_index(c, cols, rows)] = nodes.size()
				nodes.append(c)
	if nodes.is_empty():
		return _reach_cache
	var comp := PackedInt32Array()
	comp.resize(nodes.size())
	comp.fill(-1)
	var queue := PackedInt32Array()
	var cid := 0
	var best_id := -1
	var best_size := 0
	_reach_sizes = []
	for i in nodes.size():
		if comp[i] >= 0:
			continue
		queue.resize(0)
		queue.append(i)
		comp[i] = cid
		var head := 0
		while head < queue.size():
			var cur := queue[head]
			head += 1
			for nb in _reach_neighbors(nodes[cur], cols, rows):
				var j := ids[_reach_index(nb, cols, rows)]
				if j >= 0 and comp[j] < 0:
					comp[j] = cid
					queue.append(j)
		var size := queue.size()
		_reach_sizes.append(size)
		if size > best_size:
			best_size = size
			best_id = cid
		cid += 1
	_reach_main_size = best_size
	_reach_sizes.sort()
	_reach_sizes.reverse()
	if best_id >= 0:
		for i in nodes.size():
			if comp[i] != best_id:
				continue
			var c: Vector2i = nodes[i]
			if floor_cells_has(c):
				_reach_cache[c] = true
	return _reach_cache


static func main_reachable_size() -> int:
	reachable_spawn_cells()
	return _reach_main_size


static func reachable_component_sizes() -> Array:
	reachable_spawn_cells()
	return _reach_sizes.duplicate()


static func is_reachable_spawn(cell: Vector2i) -> bool:
	return reachable_spawn_cells().has(cell)


# 运行时防御:从地图 `# respawn` 列表里剔掉不可达的点(数据写错 / 地图被改),并 push_warning 一次。
# ★ 返回新数组;不可达点被跳过后,调用方若拿不到点会自动走既有的"缺数据 → 旧几何回退"路径。
static func filter_reachable(points: Array) -> Array:
	if points.is_empty():
		return points
	var reach := reachable_spawn_cells()
	if reach.is_empty():
		if not _warned_unreachable:
			_warned_unreachable = true
			push_warning("SpawnPicker: 可达图不可用(地图未载入),跳过可抵达校验、按原样放行 # respawn")
		return points
	var out: Array = []
	var dropped: Array = []
	for c in points:
		if reach.has(c):
			out.append(c)
		else:
			dropped.append(c)
	if not dropped.is_empty() and not _warned_unreachable:
		_warned_unreachable = true
		push_warning("SpawnPicker: 地图 # respawn 有 %d 个点不可抵达(封闭空间/跳跃不可达),已跳过: %s" % [
				dropped.size(), str(dropped)])
	return out


static func _reach_index(c: Vector2i, cols: int, rows: int) -> int:
	return posmod(c.y, rows) * cols + posmod(c.x, cols)


static func _reach_cell(c: Vector2i, cols: int, rows: int) -> int:
	return int(MazeGenerator.current_grid[posmod(c.y, rows)][posmod(c.x, cols)])


static func _reach_blocked(c: Vector2i, cols: int, rows: int) -> bool:
	return TileDefs.is_blocked(_reach_cell(c, cols, rows))


static func _reach_climbable(c: Vector2i, cols: int, rows: int) -> bool:
	return TileDefs.climb_speed(MazeGenerator.texture_of(_reach_cell(c, cols, rows))) > 0.0


static func _reach_standable(c: Vector2i, cols: int, rows: int) -> bool:
	if _reach_climbable(c, cols, rows):
		return true
	return _reach_cell(c, cols, rows) == 0 and _reach_blocked(c + Vector2i(0, 1), cols, rows) \
			and _reach_cell(c + Vector2i(0, -1), cols, rows) == 0


static func _reach_liquid(c: Vector2i, cols: int, rows: int) -> bool:
	return TileDefs.is_liquid(MazeGenerator.texture_of(_reach_cell(c, cols, rows)))


const REACH_JUMP_RISE := 4
const REACH_JUMP_DX := 6
const REACH_FALL_MAX := 29


static func _reach_neighbors(c: Vector2i, cols: int, rows: int) -> Array:
	var out: Array = []
	if _reach_liquid(c, cols, rows):
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nw: Vector2i = c + off
			if _reach_liquid(nw, cols, rows) or _reach_standable(nw, cols, rows):
				out.append(_reach_wrap(nw, cols, rows))
		return out
	for dx in [-1, 1]:
		var n := Vector2i(c.x + dx, c.y)
		if _reach_standable(n, cols, rows):
			out.append(_reach_wrap(n, cols, rows))
	for off3 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		var nl: Vector2i = c + off3
		if _reach_liquid(nl, cols, rows):
			out.append(_reach_wrap(nl, cols, rows))
	if _reach_climbable(c, cols, rows):
		for dy in [-1, 1]:
			var n2 := Vector2i(c.x, c.y + dy)
			if _reach_standable(n2, cols, rows) or _reach_climbable(n2, cols, rows):
				out.append(_reach_wrap(n2, cols, rows))
	for j in range(0, REACH_JUMP_RISE + 1):
		var apex_y := c.y - j
		var clear := true
		for k in range(1, j + 1):
			if _reach_blocked(Vector2i(c.x, c.y - k), cols, rows):
				clear = false
				break
		if not clear:
			continue
		var dx_lim := 1 if j == 0 else REACH_JUMP_DX
		for dx3 in range(-dx_lim, dx_lim + 1):
			var col_x := c.x + dx3
			var step: int = 1 if dx3 >= 0 else -1
			var xx := c.x
			var ok := true
			while xx != col_x:
				xx += step
				if _reach_blocked(Vector2i(xx, apex_y), cols, rows):
					ok = false
					break
			if not ok:
				continue
			for k2 in range(0, REACH_FALL_MAX):
				var dest := Vector2i(col_x, apex_y + k2)
				if _reach_blocked(dest, cols, rows):
					break
				if _reach_standable(dest, cols, rows):
					out.append(_reach_wrap(dest, cols, rows))
					break
	return out


static func _reach_wrap(c: Vector2i, cols: int, rows: int) -> Vector2i:
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))
