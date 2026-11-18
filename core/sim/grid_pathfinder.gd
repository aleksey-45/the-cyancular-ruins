class_name GridPathfinder
extends RefCounted

# 环形空间几何、地面检测与 A* 寻路。
# 纯静态工具类，无内部状态，网格与尺寸参数由调用方传入。

# 四邻域的顺序决定等长路径的选取。
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

# 计算网格坐标在环形地图上的曼哈顿距离（以网格单元为单位）。
# cols 与 rows 参数由调用方根据实际地图尺寸传入，不依赖全局常量。
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


# 计算环形空间内的像素级最短位移向量：从 a 指向 b（考虑跨边界的最短路径）。
static func toroidal_delta_px(a: Vector2, b: Vector2, size: Vector2) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > size.x * 0.5:
		dx = -signf(dx) * (size.x - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > size.y * 0.5:
		dy = -signf(dy) * (size.y - absf(dy))
	return Vector2(dx, dy)


# 将 pos 映射到距离 anchor 最近的可视镜像副本位置，使各轴差值不超过半个地图跨度。
static func anchor_to_nearest(pos: Vector2, anchor: Vector2, size: Vector2) -> Vector2:
	return anchor + toroidal_delta_px(anchor, pos, size)


# 整图平移的索引范围。只保留与地图及其接缝带相交的副本，零偏移是原位。
static func seam_copy_range(bounds: Rect2, period: Vector2, reach: Vector2) -> Rect2i:
	var first := -Vector2i(((bounds.end + reach - period) / period).ceil())
	var last := Vector2i(((reach - bounds.position) / period).ceil())
	return Rect2i(first, last - first + Vector2i.ONE)


# 将位置坐标规范化到 [0, w) × [0, h) 的世界逻辑区间内。
static func wrap_to_range(pos: Vector2, size: Vector2) -> Vector2:
	var p := pos
	if p.x >= size.x or p.x < 0.0:
		p.x = fposmod(p.x, size.x)
	if p.y >= size.y or p.y < 0.0:
		p.y = fposmod(p.y, size.y)
	return p


# 像素坐标 → 环面格子坐标(取模回 [0,cols)×[0,rows))。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# 判定标准：当前格为空气且正下方（y+1，环面回绕）为实心瓦片，确保实体具有稳固托底表面。
# 坐标内部自动通过 posmod 进行环面归一化。
static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var x := posmod(cell.x, cols)
	if grid[posmod(cell.y, rows)][x] != MapFormat.EMPTY:
		return false
	return TileDefs.is_blocked(grid[posmod(cell.y + 1, rows)][x])


# 地面站立判定（包含头顶净空）：要求当前格为站立格且上方（y-1）为空气，防范嵌墙。
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

# 小根堆的每项保存 (优先级, 格子编号)，相同优先级保留原有的父子顺序。
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

# 从候选瓦片集合中贪心选取 count 个互相保持最大间距的点集（基于环面距离）。
# 优先满足两两间距 >= clearance，若候选不足则逐步放宽间距限制。
# 内部包含随机打乱逻辑，开局规划完成后应保存结果，避免二次调用导致不同步。
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
