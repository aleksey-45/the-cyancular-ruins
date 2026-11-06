class_name GridPathfinder
extends RefCounted


static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


static func toroidal_delta_px(a: Vector2, b: Vector2, w: float, h: float) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > w * 0.5:
		dx = -signf(dx) * (w - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > h * 0.5:
		dy = -signf(dy) * (h - absf(dy))
	return Vector2(dx, dy)


static func toroidal_lerp(a: Vector2, b: Vector2, alpha: float, w: float, h: float) -> Vector2:
	return wrap_to_range(a + toroidal_delta_px(a, b, w, h) * alpha, w, h)


static func anchor_to_nearest(pos: Vector2, anchor: Vector2, w: float, h: float) -> Vector2:
	var p := pos
	if p.x - anchor.x > w * 0.5:
		p.x -= w
	elif p.x - anchor.x < -w * 0.5:
		p.x += w
	if p.y - anchor.y > h * 0.5:
		p.y -= h
	elif p.y - anchor.y < -h * 0.5:
		p.y += h
	return p


static func wrap_to_range(pos: Vector2, w: float, h: float) -> Vector2:
	var p := pos
	if p.x >= w:
		p.x -= w
	elif p.x < 0.0:
		p.x += w
	if p.y >= h:
		p.y -= h
	elif p.y < 0.0:
		p.y += h
	return p


static func copy_grid(grid: Array) -> Array[Array]:
	var out: Array[Array] = []
	out.resize(grid.size())
	for y in grid.size():
		out[y] = (grid[y] as Array).duplicate()
	return out


static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var x := posmod(cell.x, cols)
	if grid[posmod(cell.y, rows)][x] != MapFormat.EMPTY:
		return false
	return TileDefs.is_blocked(grid[posmod(cell.y + 1, rows)][x])


static func is_floor_cell_with_headroom(grid: Array, cell: Vector2i) -> bool:
	if not is_floor_cell(grid, cell):
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	return grid[posmod(cell.y - 1, rows)][posmod(cell.x, cols)] == MapFormat.EMPTY


static var _g_cost: PackedInt32Array = PackedInt32Array()
static var _prev: PackedInt32Array = PackedInt32Array()
static var _heap_f: PackedInt32Array = PackedInt32Array()
static var _heap_c: PackedInt32Array = PackedInt32Array()
static var astar_calls: int = 0

static func astar_path_nearest(grid: Array[Array], from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable(), max_search_dist: int = -1) -> Array[Vector2i]:
	astar_calls += 1
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols := grid[0].size()
	if from_cell == to_cell:
		return []
	var n := rows * cols
	if _g_cost.size() < n:
		_g_cost.resize(n)
		_prev.resize(n)
	_g_cost.fill(-1)
	_prev.fill(-1)
	var start_idx := from_cell.y * cols + from_cell.x
	var goal_idx := to_cell.y * cols + to_cell.x
	_g_cost[start_idx] = 0
	_heap_f.clear()
	_heap_c.clear()
	var start_f := toroidal_dist(from_cell, to_cell, cols, rows)
	_astar_heap_push(start_f, start_idx)
	var expanded := 0
	var best_idx := start_idx
	var best_d := start_f
	while _heap_f.size() > 0:
		var pop := _astar_heap_pop()
		var f := pop.x
		var cur_idx := pop.y
		var g_cur: int = _g_cost[cur_idx]
		var cx := cur_idx % cols
		var cy := cur_idx / cols
		if f > g_cur + toroidal_dist(Vector2i(cx, cy), to_cell, cols, rows):
			continue
		expanded += 1
		if expanded > max_visit:
			break
		if cur_idx == goal_idx:
			return _rebuild_path_flat(start_idx, goal_idx, cols, rows)
		var cd := toroidal_dist(Vector2i(cx, cy), to_cell, cols, rows)
		if cd < best_d:
			best_d = cd
			best_idx = cur_idx
		_astar_relax(cx, cy, cols, rows, grid, passable_pred, to_cell, g_cur + 1, cur_idx, from_cell, max_search_dist)
	if best_idx == start_idx:
		return []
	return _rebuild_path_flat(start_idx, best_idx, cols, rows)


const _DIRS4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


static func _astar_relax(cx: int, cy: int, cols: int, rows: int, grid: Array[Array],
		passable_pred: Callable, to_cell: Vector2i, ng: int, cur_idx: int,
		from_cell: Vector2i, max_search_dist: int) -> void:
	for d in _DIRS4:
		var nx: int = cx + d.x
		var ny: int = cy + d.y
		if nx >= cols:
			nx = 0
		elif nx < 0:
			nx = cols - 1
		if ny >= rows:
			ny = 0
		elif ny < 0:
			ny = rows - 1
		if max_search_dist > 0 and toroidal_dist(from_cell, Vector2i(nx, ny), cols, rows) > max_search_dist:
			continue
		if passable_pred.is_valid():
			if not passable_pred.call(Vector2i(nx, ny)):
				continue
		elif TileDefs.is_blocked(grid[ny][nx]):
			continue
		var ni: int = ny * cols + nx
		var old := _g_cost[ni]
		if old >= 0 and old <= ng:
			continue
		_g_cost[ni] = ng
		_prev[ni] = cur_idx
		_astar_heap_push(ng + toroidal_dist(Vector2i(nx, ny), to_cell, cols, rows), ni)


static func _astar_heap_push(f: int, c: int) -> void:
	_heap_f.append(f)
	_heap_c.append(c)
	var i := _heap_f.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if _heap_f[i] < _heap_f[p]:
			var tf := _heap_f[i]
			_heap_f[i] = _heap_f[p]
			_heap_f[p] = tf
			var tc := _heap_c[i]
			_heap_c[i] = _heap_c[p]
			_heap_c[p] = tc
			i = p
		else:
			break


static func _astar_heap_pop() -> Vector2i:
	var top := Vector2i(_heap_f[0], _heap_c[0])
	var last_f: int = _heap_f[_heap_f.size() - 1]
	_heap_f.resize(_heap_f.size() - 1)
	var last_c: int = _heap_c[_heap_c.size() - 1]
	_heap_c.resize(_heap_c.size() - 1)
	if _heap_f.size() > 0:
		_heap_f[0] = last_f
		_heap_c[0] = last_c
		var i := 0
		var m := _heap_f.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var s := i
			if l < m and _heap_f[l] < _heap_f[s]:
				s = l
			if r < m and _heap_f[r] < _heap_f[s]:
				s = r
			if s == i:
				break
			var tf := _heap_f[i]
			_heap_f[i] = _heap_f[s]
			_heap_f[s] = tf
			var tc := _heap_c[i]
			_heap_c[i] = _heap_c[s]
			_heap_c[s] = tc
			i = s
	return top


static func _rebuild_path_flat(start_idx: int, goal_idx: int, cols: int, rows: int) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var idx := goal_idx
	while idx != start_idx:
		path.push_front(Vector2i(idx % cols, idx / cols))
		idx = _prev[idx]
	return path


static func has_line_of_sight(grid: Array[Array], from_cell: Vector2i, to_cell: Vector2i) -> bool:
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := grid[0].size()
	var d := _toroidal_step(from_cell, to_cell, cols, rows)
	if d == Vector2i.ZERO:
		return true
	var x := from_cell.x
	var y := from_cell.y
	var sx := 1 if d.x > 0 else -1
	var sy := 1 if d.y > 0 else -1
	var dx := absi(d.x)
	var dy := absi(d.y)
	var err := dx - dy
	while true:
		if TileDefs.is_blocked(grid[y][x]):
			return false
		if x == to_cell.x and y == to_cell.y:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x = posmod(x + sx, cols)
		if e2 < dx:
			err += dx
			y = posmod(y + sy, rows)
	return true


static func _toroidal_step(a: Vector2i, b: Vector2i, cols: int, rows: int) -> Vector2i:
	var dx := b.x - a.x
	if dx > cols / 2:
		dx -= cols
	elif dx < -cols / 2:
		dx += cols
	var dy := b.y - a.y
	if dy > rows / 2:
		dy -= rows
	elif dy < -rows / 2:
		dy += rows
	return Vector2i(dx, dy)


static func spread_cells(cells: Array, count: int, clearance: int, cols: int, rows: int) -> Array:
	var picked: Array = []
	if count <= 0 or cells.is_empty():
		return picked
	var pool := cells.duplicate()
	pool.shuffle()
	var cl := clearance
	while picked.size() < count and cl >= 0:
		for c in pool:
			if picked.size() >= count:
				break
			if picked.has(c):
				continue
			var ok := true
			for p in picked:
				if toroidal_dist(c, p, cols, rows) < cl:
					ok = false
					break
			if ok:
				picked.append(c)
		cl -= 5
	if picked.size() < count:
		for c in pool:
			if picked.size() >= count:
				break
			if not picked.has(c):
				picked.append(c)
	return picked
