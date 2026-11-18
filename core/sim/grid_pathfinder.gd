class_name GridPathfinder
extends RefCounted

# 距离、活动范围和 A* 寻路都把地图的左右边缘、上下边缘视为相连。

# 相邻瓦片始终按相同顺序加入候选列表，确保同等优先级的路径能稳定复现。
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

# 两个瓦片之间的曼哈顿距离，横向和纵向分别取较短的路线。
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


# 取得 a 指向 b 的最短位移。若从地图另一侧到达更近，则用跨边缘的位移。
static func toroidal_delta_px(a: Vector2, b: Vector2, size: Vector2) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > size.x * 0.5:
		dx = -signf(dx) * (size.x - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > size.y * 0.5:
		dy = -signf(dy) * (size.y - absf(dy))
	return Vector2(dx, dy)


# 返回离 anchor 最近的对应位置。必要时将 pos 按地图宽度或高度平移。
static func anchor_to_nearest(pos: Vector2, anchor: Vector2, size: Vector2) -> Vector2:
	return anchor + toroidal_delta_px(anchor, pos, size)


# 计算地图两侧哪些平移位置需要放置同一份地形，以补齐边缘附近的碰撞和绘制范围。
# 返回结果是偏移的取值范围，横向每单位为一个地图宽度，纵向每单位为一个地图高度。(0, 0) 表示不平移。
static func seam_copy_range(bounds: Rect2, period: Vector2, reach: Vector2) -> Rect2i:
	var first := -Vector2i(((bounds.end + reach - period) / period).ceil())
	var last := Vector2i(((reach - bounds.position) / period).ceil())
	return Rect2i(first, last - first + Vector2i.ONE)


# 把越界坐标换回地图另一侧的对应位置，结果总在 [0, width) × [0, height) 内。
static func wrap_to_range(pos: Vector2, size: Vector2) -> Vector2:
	var p := pos
	if p.x >= size.x or p.x < 0.0:
		p.x = fposmod(p.x, size.x)
	if p.y >= size.y or p.y < 0.0:
		p.y = fposmod(p.y, size.y)
	return p


# 把世界坐标换算成瓦片索引，并将越界位置对应到地图另一侧。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# 可站立的位置须是空瓦片，正下方一格有可承托角色的地形。计算时把地图上下两侧视为相连。
static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var x := posmod(cell.x, cols)
	if grid[posmod(cell.y, rows)][x] != MapFormat.EMPTY:
		return false
	return TileDefs.is_blocked(grid[posmod(cell.y + 1, rows)][x])


# 为头部多留一格空间，用于挑选需要完整站立空间的位置。
static func is_floor_cell_with_headroom(grid: Array, cell: Vector2i) -> bool:
	if not is_floor_cell(grid, cell):
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	return grid[posmod(cell.y - 1, rows)][posmod(cell.x, cols)] == MapFormat.EMPTY


static func astar_path_nearest(grid: Array[Array], start: Vector2i, goal: Vector2i, max_visit := 4000,
		can_pass := Callable(), radius := -1) -> Array[Vector2i]:
	if grid.is_empty():
		return []
	if not can_pass.is_valid():
		can_pass = func(at: Vector2i) -> bool: return not TileDefs.is_blocked(grid[at.y][at.x])
	return find_path(Vector2i(grid[0].size(), grid.size()), start, goal, can_pass, max_visit, radius)

static func find_path(size: Vector2i, start: Vector2i, goal: Vector2i, can_pass: Callable,
		max_visit := 4000, radius := -1) -> Array[Vector2i]:
	if start == goal:
		return []
	var cost := PackedInt32Array()
	cost.resize(size.x * size.y)
	cost.fill(-1)
	var parent := PackedInt32Array()
	parent.resize(cost.size())
	var origin := start.y * size.x + start.x
	cost[origin] = 0
	var nearest := origin
	var best := toroidal_dist(start, goal, size.x, size.y)
	var frontier: Array[Vector2i] = [Vector2i(best, origin)]
	while not frontier.is_empty() and max_visit > 0:
		var entry := _pop(frontier)
		var index := entry.y
		var at := Vector2i(index % size.x, index / size.x)
		var distance := toroidal_dist(at, goal, size.x, size.y)
		if entry.x > cost[index] + distance:
			continue
		max_visit -= 1
		if distance < best:
			best = distance
			nearest = index
		if at == goal:
			break
		var next_cost := cost[index] + 1
		for step: Vector2i in DIRECTIONS:
			var next := Vector2i(posmod(at.x + step.x, size.x), posmod(at.y + step.y, size.y))
			if radius > 0 and toroidal_dist(start, next, size.x, size.y) > radius:
				continue
			var neighbor := next.y * size.x + next.x
			if not can_pass.call(next) or (cost[neighbor] >= 0 and cost[neighbor] <= next_cost):
				continue
			cost[neighbor] = next_cost
			parent[neighbor] = index
			_push(frontier, Vector2i(next_cost + toroidal_dist(next, goal, size.x, size.y), neighbor))
	var path: Array[Vector2i] = []
	while nearest != origin:
		path.append(Vector2i(nearest % size.x, nearest / size.x))
		nearest = parent[nearest]
	path.reverse()
	return path

# 最小堆以 Vector2i.x 作为优先级，y 保存瓦片索引。
static func _push(heap: Array[Vector2i], entry: Vector2i) -> void:
	var i := heap.size()
	heap.append(entry)
	while i > 0:
		var parent := (i - 1) / 2
		if heap[parent].x <= entry.x:
			break
		heap[i] = heap[parent]
		i = parent
	heap[i] = entry

static func _pop(heap: Array[Vector2i]) -> Vector2i:
	var first := heap[0]
	var last: Vector2i = heap.pop_back()
	if heap.is_empty():
		return first
	var i := 0
	while i * 2 + 1 < heap.size():
		var child := i * 2 + 1
		if child + 1 < heap.size() and heap[child + 1].x < heap[child].x:
			child += 1
		if heap[child].x >= last.x:
			break
		heap[i] = heap[child]
		i = child
	heap[i] = last
	return first

# 先随机排列候选瓦片，再挑选相互至少间隔 clearance 格的位置。
# 达到初始间距的位置不够时，逐步缩小最小间距。
static func spread_cells(cells: Array[Vector2i], count: int, clearance: int, cols: int, rows: int) -> Array[Vector2i]:
	var picked: Array[Vector2i] = []
	count = mini(count, cells.size())
	var pool := cells.duplicate()
	pool.shuffle()
	var cl := clearance
	while picked.size() < count:
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
		cl = maxi(0, cl - 5)
	return picked
