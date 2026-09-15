class_name GridPathfinder
extends RefCounted

# 环面网格的**几何与寻路**:格级/像素级环面距离、副本锚定、格子定位、地板格判定、A* 与 LOS。
# ★ 本类**无会话状态** —— 网格一律由调用方传入(`grid` 参数),会话级的 `current_grid` 在 MazeGenerator。
#   A* 的静态暂存缓冲是本文件自有的可复用 scratch,与地图内容无关。
# ★ 改这里 = 改环面数学/寻路;改 MapFormat = 改磁盘格式。两者不搭界。

# 环面曼哈顿距离(格子级)。cols/rows 由调用方按实际地图传入,
# 不依赖全局常量——地图文件变更后距离计算不会失真。
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


# 像素级环面最短向量:从 a 指向 b(跨接缝取最短)。
static func toroidal_delta_px(a: Vector2, b: Vector2, w: float, h: float) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > w * 0.5:
		dx = -signf(dx) * (w - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > h * 0.5:
		dy = -signf(dy) * (h - absf(dy))
	return Vector2(dx, dy)


# 环面线性插值:沿 a→b 的最短向量按 alpha 取点,再取模回 [0,w)×[0,h)。
# 供 PvP 副本位置插值用——相邻快照在环面上可能跨接缝,直接 lerp 会横穿整幅地图。
static func toroidal_lerp(a: Vector2, b: Vector2, alpha: float, w: float, h: float) -> Vector2:
	return wrap_to_range(a + toroidal_delta_px(a, b, w, h) * alpha, w, h)


# 把 pos 锚定到 anchor 最近的环面副本:返回的位置与 anchor 各轴差 ≤ 半地图。
# 用于让敌人/子弹「跟着主角一起取模」——墙体在 level_0 按 3x3 铺贴,
# 相机在接缝处能看到另一侧副本,实体若仍取模到 [0,MAP) 会渲染到远副本而消失。
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


# 把点取模回 [0,w)×[0,h) 绝对区间(玩家锚点自身用;实体锚定玩家副本见 anchor_to_nearest)。
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


# 深拷贝网格(每行复制 int),用于保存"未破坏"基线 / 每局复位。返回强类型 Array[Array],
# 以便赋回 MazeGenerator.current_grid / Level0._grid_ref 等强类型成员(普通 Array 赋给强类型会运行时报错)。
static func copy_grid(grid: Array) -> Array[Array]:
	var out: Array[Array] = []
	for row in grid:
		var r: Array = []
		for v in row:
			r.append(v)
		out.append(r)
	return out


# 像素坐标 → 环面格子坐标(取模回 [0,cols)×[0,rows))。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# ── 地板格(可站立表面)──
# 基本判据:本格 EMPTY 且**正下方**(y+1,环面)是实心 —— 敌人/玩家要有实心表面托底,否则
# 落地时没有 is_on_floor() 的地面,会坠穿空洞(FlyBird 回家入睡 bug 的根因)。
# ★ 格坐标由本函数统一 posmod 回环面,**调用方不必预先规整**(但仍可自备边界检查)。
# ★ 只做基本判据;额外条件(如"头上要留净空")见下面那个以及调用方自己的包装。
# 2026-09-14 收敛:原先 `enemy_black_bird` 有同名私有版,`royale_host` 里同一谓词抄了三份
# (采集循环 / O(1) 版 / 宽松版),`match_host` 又一份 —— 共 5 处。
static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var x := posmod(cell.x, cols)
	if grid[posmod(cell.y, rows)][x] != MapFormat.EMPTY:
		return false
	return TileDefs.is_blocked(grid[posmod(cell.y + 1, rows)][x])


# 地板格 **+ 头上留一格净空**:避免贴着天花板/嵌进头顶实心(出生点、瞬移落点用)。
# 构建在上面那条之上,不重复基本判据。
static func is_floor_cell_with_headroom(grid: Array, cell: Vector2i) -> bool:
	if not is_floor_cell(grid, cell):
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	return grid[posmod(cell.y - 1, rows)][posmod(cell.x, cols)] == MapFormat.EMPTY


# ── A* 寻路 ──
# 环面 A*(4 邻域):启发式 = 环面曼哈顿距离(可采纳且一致)。预算 max_visit 是弹出
# (展开)节点数上限。目标不可达/预算超限时返回「最近可达格」的路径。
# (取代的 BFS 版在空旷区波前会铺满半径内所有格、预算很快耗尽;A* 靠启发式直奔目标,
#  展开节点少一个量级——这正是玩家站在高平台时鸟"上不去"的根因。)
#
# 性能:g/prev 从 Dictionary(Vector2i 键)换成扁平 PackedInt32Array(线性索引
# y*cols+x),visited 用 g≥0 标记;堆从「Array 装嵌套 Array」换成两条并行
# PackedInt32Array(_heap_f 存 f、_heap_c 存 cell 索引),不打包 → 无溢出风险。
# 静态缓冲区复用、每搜索只 fill 一遍 → 零字典分配、无 GC 压力,同预算下快一个量级。
static var _g_cost: PackedInt32Array = PackedInt32Array()
static var _prev: PackedInt32Array = PackedInt32Array()
static var _heap_f: PackedInt32Array = PackedInt32Array()
static var _heap_c: PackedInt32Array = PackedInt32Array()
static var astar_calls: int = 0  # A* 调用计数(冒烟测试验证路径缓存命中用)

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
		# 惰性删除:该格后来被更优路径更新过,旧堆项作废。
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


# 4 邻域偏移(右/左/下/上)。顺序会影响平局时的路径形态,勿随意调整。
const _DIRS4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


# 展开当前格:对每个邻居做「可走 + 更优」判定,通过则更新 g/prev 并入堆。
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
		# 搜索范围上限:不展开超出 from_cell 半径的节点(鸟的寻路不搜太远)
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


# 隐式二叉堆(小根堆,按 f 排序;两条并行 PackedInt32Array 一起交换)。
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


# 从 prev 扁平链重建格序列(不含起点含终点)。
static func _rebuild_path_flat(start_idx: int, goal_idx: int, cols: int, rows: int) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var idx := goal_idx
	while idx != start_idx:
		path.push_front(Vector2i(idx % cols, idx / cols))
		idx = _prev[idx]
	return path


# 环面网格 LOS:整数 Bresenham 沿直线采样两格之间的格子,途中任一 SOLID 即阻断。
# 不能用「每步双轴各进一」的斜对角走法——|dx|≠|dy| 时会越过目标行/列、采样到线外的格子。
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


# 从候选格里挑 count 个**互相尽量远离**的格(环面距离贪心)。
#
# 洗牌后逐个取,要求与已选点两两环面距离 ≥ clearance;不足则 clearance 逐级 -5 放宽;
# 放宽到头仍不够就直接补任意剩余的格(宁可挤,不可少 —— 调用方按 count 布点,少了会缺)。
#
# ★ 抽自 `RoyaleHost.plan_spawns`(原先那套长在 RoyaleHost 实例上,单机用不了)。
# ★ **内部有 shuffle()**:同一组输入两次调用结果不同。RoyaleHost 原有纪律 ——
#   **不得在广播之后再调一次**(每局的开局散点只能算一次)。
# ★ 宽高传 cols/rows 两个 int 而不是 Vector2:与 toroidal_dist 同款,且不引 GameParameters
#   (autoload),保持本文件可 -s 测。
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
	# 兜底:放宽到头仍不够,补任意剩余的格
	if picked.size() < count:
		for c in pool:
			if picked.size() >= count:
				break
			if not picked.has(c):
				picked.append(c)
	return picked
