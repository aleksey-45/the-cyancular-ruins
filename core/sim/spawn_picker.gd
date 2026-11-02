class_name SpawnPicker
extends RefCounted

# 出生/复活点的静态几何池(从 RoyaleHost 逐字搬出):地板格 / 同层连通区规模 / 开阔优选格;大乱斗与 3v3 共用同一套判据。
# ★ 另有「可抵达性」判据(文件末尾 `reachable_spawn_cells` / `filter_reachable`):跳跃感知图的主连通分量 —— 防"复活点落进封闭空间"。
# ★ 全部 static、不引任何 autoload(只读 MazeGenerator.current_grid)⇒ 可被 -s 测试加载;缓存是每进程的(worker 一局一进程)。

const OPEN_AREA_MIN: int = 20    # 出生可走连通区最小规模(格);密封死角小间远小于此。**绝对**阈值(见自适应)
const PREFER_MIN: int = 8        # 优选格不足此数才回退下一级宽松判据

# ── 小图自适应门槛 ── ★ 下面的数字是旧定图 factory1v1 上实测的(该图 2026-10-02 退役、文件已删;现定图 = newfactory.cyrm),别照着量 newfactory。
# 本图最大连通区 < OPEN_AREA_MIN 时把"开阔"门槛缩到「最大连通区 × ADAPTIVE_RATIO」;自适应只会让池子变窄,正常图一行不生效、行为逐字不变。
# ⚠ 已登记:newfactory 最大连通区 48 ≥ 20 ⇒ 生产图集里该分支不会被触发;它曾被 spawn_pool_smoke 的合成网格夹具驱动,而那条已删(2026-10-09)⇒ 今天零守卫(不是死代码,阈值仍是「任何图都可能需要」的保险)。
const ADAPTIVE_RATIO: float = 0.5

static var _floor_cell_cache: Array = []   # 本局地板格(懒采集;砖被拆不刷新,够用)
static var _prefer_cache: Array = []       # 出生优选格缓存(开阔可走区;见 spawn_candidates)
static var _fallback_cache: Array = []     # 复活兜底池缓存(见 respawn_fallback)
static var _last_resort_cache: Array = []  # 复活末档缓存(见 respawn_last_resort)
static var _region_cache: Dictionary = {}  # 地板格 Vector2i -> 同层连通区规模
static var _reach_cache: Dictionary = {}   # Vector2i -> true:主可达区里的地板格(见 reachable_spawn_cells)
static var _reach_main_size := 0
static var _reach_sizes: Array = []        # 各连通分量的节点数(降序;数据作者诊断"为什么点不够"用)


# 清空缓存。换图/换局时调用方自己决定要不要清(搬出前的行为是从不主动清 —— 保持)。
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
	return Vector2i((grid[0] as Array).size(), grid.size())   # (cols, rows)


# 采集地板格(EMPTY + 正下方 SOLID + 头上留空;同 MatchHost._is_floor_cell 判据,静态版)
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


# ── 出生/复活点优选(防"出生在走不出去的小房间"):需同时满足 ① 头顶 ≥2 格净空 ② 左右邻格空(≥3 格宽)
# ③ 同层可走连通区规模 ≥ area_threshold();地板格不足时逐级回退。⚠ 连通区是纯 4 邻接、不含跳跃/梯子 ⇒ 只是步行可达的下界近似。
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


# 某格是否地板格(与 floor_cells 同判据的 O(1) 版本:自身空 + 下方实心 + 上方留空)
static func floor_cells_has(c: Vector2i) -> bool:
	# 判据收在 MazeGenerator(全仓曾有 5 份);本函数与 floor_cells 的采集循环同判据。
	return MazeGenerator.is_floor_cell_with_headroom(MazeGenerator.current_grid, c)


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
	# 左右邻格空:出生处 ≥3 格宽
	if grid[c.y][posmod(c.x - 1, cols)] != MazeGenerator.EMPTY \
			or grid[c.y][posmod(c.x + 1, cols)] != MazeGenerator.EMPTY:
		return false
	return true


# 本图最大地板连通区的规模(格)。空网格 / 未加载 = 0。
static func max_region_size() -> int:
	var mx := 0
	for sz in region_sizes().values():
		mx = maxi(mx, int(sz))
	return mx


# 出生判据的"开阔"门槛(格)—— 阈值本体:本图最大连通区 ≥ OPEN_AREA_MIN → OPEN_AREA_MIN;否则 → 最大连通区 × ADAPTIVE_RATIO。
# ★ 下界 1:max_region_size() 为 0(空网格)时不给 0 —— 那会让 >= thr 恒真、池子变全量。
static func area_threshold() -> int:
	var mx := max_region_size()
	if mx >= OPEN_AREA_MIN:
		return OPEN_AREA_MIN
	return maxi(ceili(float(mx) * ADAPTIVE_RATIO), 1)


# 出生候选池(缓存):开阔可走地板格 → 连通区大的地板格 → 任意地板格;前三档的连通区判据都走 area_threshold()。
# ★★ 两个宿主的开局散点都取自本函数返回值 ⇒ 结构上落不到"连通区 < 门槛"的格上(spread_cells 恒返回 min(n, 池大小),补足分支可达 <=> 池 < 人数)。
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


# ── 复活/复位的两档兜底:第 ② 档 = 连通区 ≥ area_threshold(),第 ③ 档 = 连通区 ≥ 2(只排除孤立单格)。
# ★★ 第 ③ 档必存在(支点是结构不是读数):它是第 ② 档的超集、序列逐档放宽 ⇒ 只会减少"整序列筛空"的布局数。
# ⚠ 实测(两图各 4036 布局):只收一档会新增「旧兜底有货 ∧ 新兜底筛空」的布局 factory1v1 1 个 / demo 5 个;加第 ③ 档后 0 个。筛空即返回 (-1,-1) ⇒ 消费端把人摆到 (-32,-32) 角落。
static func respawn_fallback() -> Array:
	if not _fallback_cache.is_empty():
		return _fallback_cache
	var thr := area_threshold()
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= thr:
			_fallback_cache.append(c)
	return _fallback_cache


# 末档(第 ③):全部地板格里排除孤立单格(连通区 == 1);这是"绝不返回 (-1,-1)"的最后一道。
static func respawn_last_resort() -> Array:
	if not _last_resort_cache.is_empty():
		return _last_resort_cache
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= 2:
			_last_resort_cache.append(c)
	return _last_resort_cache


# 复活/复位选格的池子序列:优选 → 兜底 → 末档;两处调用方都读这一份(顺序本身就是判据的一部分,抄两份会一起退化成全量)。
# ★ 序列按池子大小单调不减,且每一档都不含孤立单格;★ 返回新数组,但元素是共享缓存(要原地改先 duplicate())。
static func respawn_pools() -> Array:
	return [spawn_candidates(), respawn_fallback(), respawn_last_resort()]


# 基座附近候选格(环面距离 <= radius):给 3v3 的"队内聚、队间远"用;池子为空时返回全量候选,绝不返回空。
# ★★ 别名纪律:池可能即共享缓存(spawn_candidates() 返回 _prefer_cache 本身)⇒ 统一返回新数组;要原地改先 duplicate()。
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
const FAR_CELLS := 15   # role2 的自动出生点离 role1 至少这么远(格;环面距离)


# 地板格里离 anchor 环面距离 >= FAR_CELLS 的最近一个;全不满足就取最远的那个;网格为空返回 (-1,-1)。
static func far_spawn_from(anchor: Vector2i, grid: Array) -> Vector2i:
	if grid.is_empty():
		return Vector2i(-1, -1)
	TileDefs.load_defs()   # 幂等;worker 建局早于建世界,这里不加载的话 is_blocked 全是默认值
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


# 可抵达性:复活点必须落在"跳跃感知图"的主连通分量里(防落进封闭空间)。
# 节点 = 可站格(地板格 / 攀爬通道格)+ 液体格(可游泳);边 = 走 / 跳落组合 / 爬 / 游泳(近似见 _reach_neighbors)。
# 主可达区 = 节点数最大的分量。近似口径与已知边界见 docs/eng/world.md。
static var _warned_unreachable := false


# 主可达区里的地板格(可作复活点的集合):Vector2i -> true。每张图算一次(缓存)。
static func reachable_spawn_cells() -> Dictionary:
	if not _reach_cache.is_empty():
		return _reach_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return _reach_cache
	TileDefs.load_defs()   # 幂等;worker 建局早于建世界,不加载的话 climb/is_blocked 全是默认值
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


# 各可站格连通分量的规模(降序;诊断"为什么某侧合格点不够"用,不参与运行时选点)。
static func reachable_component_sizes() -> Array:
	reachable_spawn_cells()
	return _reach_sizes.duplicate()


static func is_reachable_spawn(cell: Vector2i) -> bool:
	return reachable_spawn_cells().has(cell)


# 运行时防御:从地图 `# respawn` 列表里剔掉不可达的点(数据写错 / 地图被改),并 push_warning **一次**。
# ★ 返回新数组;不可达点被跳过后,调用方若拿不到点会自动走既有的"缺数据 → 旧几何回退"路径。
static func filter_reachable(points: Array) -> Array:
	if points.is_empty():
		return points
	var reach := reachable_spawn_cells()
	# ★★ 可达图不可用(地图还没载进 MazeGenerator / 没有可站格)时**按原样放行**:
	#   "无法校验"不能被当成"全都不可达" —— 否则调用方会静默掉进旧回退路径(实测:1v1 建局早于载图时,
	#   9/9 个点全被丢掉,出生点退回旧的两点老数据)。
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


# 可站:攀爬通道格,或地板格(本格空 + 正下方挡路 + 头顶空)。与 team_match_watcher 的 `_standable` 同判据。
static func _reach_standable(c: Vector2i, cols: int, rows: int) -> bool:
	if _reach_climbable(c, cols, rows):
		return true
	return _reach_cell(c, cols, rows) == 0 and _reach_blocked(c + Vector2i(0, 1), cols, rows) \
			and _reach_cell(c + Vector2i(0, -1), cols, rows) == 0


# 液体格(水;`TileDefs.is_liquid`):玩家能游,故算"可通行的节点",但**不算**可站格(复活点从不放水里)。
static func _reach_liquid(c: Vector2i, cols: int, rows: int) -> bool:
	return TileDefs.is_liquid(MazeGenerator.texture_of(_reach_cell(c, cols, rows)))


# 跳落组合(近似):升到顶点行 → 水平移动 → 直落到第一个可站格。
# 常数依据:jump_velocity 1000 / gravity0 1600 ⇒ 最高 312px ≈ 4.88 格(保守取 4);空中横移取经验值 6 格。
const REACH_JUMP_RISE := 4
const REACH_JUMP_DX := 6
const REACH_FALL_MAX := 29


static func _reach_neighbors(c: Vector2i, cols: int, rows: int) -> Array:
	var out: Array = []
	# 水中:4 向游(液体之间 / 游到相邻可站格=出水;出水再上浮由"游到水面踏上台"近似覆盖)。
	if _reach_liquid(c, cols, rows):
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nw: Vector2i = c + off
			if _reach_liquid(nw, cols, rows) or _reach_standable(nw, cols, rows):
				out.append(_reach_wrap(nw, cols, rows))
		return out
	for dx in [-1, 1]:                                   # 走(同层左右)
		var n := Vector2i(c.x + dx, c.y)
		if _reach_standable(n, cols, rows):
			out.append(_reach_wrap(n, cols, rows))
	# 落水/走进水里:岸边可入水
	for off3 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		var nl: Vector2i = c + off3
		if _reach_liquid(nl, cols, rows):
			out.append(_reach_wrap(nl, cols, rows))
	if _reach_climbable(c, cols, rows):                  # 爬(梯 / 链上下)
		for dy in [-1, 1]:
			var n2 := Vector2i(c.x, c.y + dy)
			if _reach_standable(n2, cols, rows) or _reach_climbable(n2, cols, rows):
				out.append(_reach_wrap(n2, cols, rows))
	# 跳 / 落组合:升到顶点行(0..RISE 格)→ 在该行水平移动(±DX)→ 直落到第一个可站格。
	for j in range(0, REACH_JUMP_RISE + 1):
		var apex_y := c.y - j
		var clear := true
		for k in range(1, j + 1):                        # 起跳侧竖直净空
			if _reach_blocked(Vector2i(c.x, c.y - k), cols, rows):
				clear = false
				break
		if not clear:
			continue
		var dx_lim := 1 if j == 0 else REACH_JUMP_DX    # 不升高的那档只算"走出边缘"(不做 6 格平地漂移)
		for dx3 in range(-dx_lim, dx_lim + 1):
			var col_x := c.x + dx3
			var step: int = 1 if dx3 >= 0 else -1
			var xx := c.x
			var ok := true
			while xx != col_x:                           # 顶点行水平路径净空
				xx += step
				if _reach_blocked(Vector2i(xx, apex_y), cols, rows):
					ok = false
					break
			if not ok:
				continue
			for k2 in range(0, REACH_FALL_MAX):          # 从顶点行直落到第一个可站格
				var dest := Vector2i(col_x, apex_y + k2)
				if _reach_blocked(dest, cols, rows):
					break
				if _reach_standable(dest, cols, rows):
					out.append(_reach_wrap(dest, cols, rows))
					break
	return out


static func _reach_wrap(c: Vector2i, cols: int, rows: int) -> Vector2i:
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))
