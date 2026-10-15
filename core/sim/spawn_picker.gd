class_name SpawnPicker
extends RefCounted

# 出生/复活点的静态几何池(从 RoyaleHost 逐字搬出):地板格 / 同层连通区规模 / 开阔优选格;大乱斗与 3v3 共用同一套判据。
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


# 清空五张缓存。换图/换局时调用方自己决定要不要清(搬出前的行为是从不主动清 —— 保持)。
static func reset_cache() -> void:
	_floor_cell_cache = []
	_prefer_cache = []
	_fallback_cache = []
	_last_resort_cache = []
	_region_cache = {}


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
	for y in range(rows):
		for x in range(cols):
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
