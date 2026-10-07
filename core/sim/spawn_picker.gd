class_name SpawnPicker
extends RefCounted

# 出生与复活点静态几何候选池。
# 负责在地图中筛选平整地面、开阔连通区域作为玩家出生和复活候选位置，避免出生在狭小封闭死角中。
# 提供全局静态方法，不依赖 autoload 单例，便于独立运行测试。

const OPEN_AREA_MIN: int = 20    # 开阔连通区最小规模（瓦片格数），低于此阈值被视为封闭小隔间
const PREFER_MIN: int = 8        # 优选格数量门限，低于此数量时自动回退至次级候选策略

# 小地图自适应门槛：
# 当地图整体连通区域较小时，动态将门槛调整为最大连通区乘以该比例，保留相对最开阔的区域。
const ADAPTIVE_RATIO: float = 0.5

static var _floor_cell_cache: Array = []   # 地表格缓存
static var _prefer_cache: Array = []       # 优选出生格缓存
static var _fallback_cache: Array = []     # 次级保底候选缓存
static var _last_resort_cache: Array = []  # 最低保底候选缓存
static var _region_cache: Dictionary = {}  # 地表格 Vector2i 到连通区规模的映射

# 清空内部缓存。地图切换或重新初始化时调用。
static func reset_cache() -> void:
	_floor_cell_cache = []
	_prefer_cache = []
	_fallback_cache = []
	_last_resort_cache = []
	_region_cache = {}


static func grid_dims() -> Vector2i:
	var grid := MazeGenerator.current_grid
	return Vector2i((grid[0] as Array).size(), grid.size())   # (cols, rows)


# 扫描地图收集所有平整地表格（自身为空、下方为阻挡且头顶留有站立空间）。
static func floor_cells() -> Array:
	if not _floor_cell_cache.is_empty():
		return _floor_cell_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	for y in range(rows):
		for x in range(cols):
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				_floor_cell_cache.append(c)
	return _floor_cell_cache


# 出生与复活候选格筛选：
# 避免玩家出生在密闭死角或狭窄夹层中。优选格需同时满足：
# 1. 头顶留有至少 2 格净空（满足起跳与站立高度）；
# 2. 左右两侧留空（横向宽度至少 3 格，避免两侧贴墙）；
# 3. 所在同层可走连通区域规模达到阈值 area_threshold()，自动淘汰封闭死角。
#
# 连通区域判据基于四邻接步进，作为纯平地行走可达性的下界估计。
static func region_sizes() -> Dictionary:
	if not _region_cache.is_empty():
		return _region_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return {}
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	var seen := {}
	for y in range(rows):
		for x in range(cols):
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


# 判定指定瓦片是否为有效平整地表格。
static func floor_cells_has(c: Vector2i) -> bool:
	return MazeGenerator.is_floor_cell_with_headroom(MazeGenerator.current_grid, c)


# 判定指定地表格是否具备开阔净空（头顶留空至少 2 格，左右至少 1 格）。
static func roomy_floor(c: Vector2i) -> bool:
	if not floor_cells_has(c):
		return false
	var grid := MazeGenerator.current_grid
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	# 头顶两格净空
	if grid[posmod(c.y - 1, rows)][c.x] != MazeGenerator.EMPTY \
			or grid[posmod(c.y - 2, rows)][c.x] != MazeGenerator.EMPTY:
		return false
	# 左右邻格空：出生处至少 3 格宽
	if grid[c.y][posmod(c.x - 1, cols)] != MazeGenerator.EMPTY \
			or grid[c.y][posmod(c.x + 1, cols)] != MazeGenerator.EMPTY:
		return false
	return true


# 获取当前地图最大地表连通区域的格数规模。空网格时返回 0。
static func max_region_size() -> int:
	var mx := 0
	for sz in region_sizes().values():
		mx = maxi(mx, int(sz))
	return mx


# 计算开阔区域的门槛规模：
# 当最大连通区达到标准门槛时采用绝对值 OPEN_AREA_MIN；
# 当小地图最大连通区不足时，按比例自适应下调，避免候选池彻底退化。
static func area_threshold() -> int:
	var mx := max_region_size()
	if mx >= OPEN_AREA_MIN:
		return OPEN_AREA_MIN
	return maxi(ceili(float(mx) * ADAPTIVE_RATIO), 1)


# 获取出生点候选格列表：
# 优先返回同时满足开阔净空与连通规模的优选格；
# 数量不足时放宽净空限制，返回达到连通规模的地表格；
# 再次不足时回退至常规地表格。
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


# 次级保底复活候选池：
# 筛选连通区域规模大于等于自适应阈值的地表格。
static func respawn_fallback() -> Array:
	if not _fallback_cache.is_empty():
		return _fallback_cache
	var thr := area_threshold()
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= thr:
			_fallback_cache.append(c)
	return _fallback_cache


# 最低保底复活候选池：
# 遍历地表格并排除连通规模为 1 的绝对孤立单格。
static func respawn_last_resort() -> Array:
	if not _last_resort_cache.is_empty():
		return _last_resort_cache
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= 2:
			_last_resort_cache.append(c)
	return _last_resort_cache


# 获取复活点候选池分级序列：
# 依次包含优选池、次级保底池与最低保底池。
# 各调用端统一按此优先级逐级放宽判定条件，防止直接回退至全量地表导致死角出生。
static func respawn_pools() -> Array:
	return [spawn_candidates(), respawn_fallback(), respawn_last_resort()]


# 获取指定中心点环面半径范围内的候选格。
# 适用于团队模式按小队聚集散布出生点。
# 若指定范围内无候选格，则返回完整优选池副本。
static func cells_within(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	if center.x < 0 or center.y < 0:
		return spawn_candidates().duplicate()
	var d := grid_dims()
	for c in spawn_candidates():
		if GridPathfinder.toroidal_dist(c, center, d.x, d.y) <= radius:
			out.append(c)
	return out if not out.is_empty() else spawn_candidates().duplicate()


# 单出生点地图的第二角色出生点最小环面距离（格）。
const FAR_CELLS := 15


# 在平整地表格中查找与基准点保持足够环面距离的候选位置。
# 若无完全满足距离要求的瓦片，则取环面距离最大的地表格。
static func far_spawn_from(anchor: Vector2i, grid: Array) -> Vector2i:
	if grid.is_empty():
		return Vector2i(-1, -1)
	TileDefs.load_defs()   # 确保瓦片定义已初始化，避免阻挡判定读取默认值
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
