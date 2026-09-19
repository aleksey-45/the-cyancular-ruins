class_name SpawnPicker
extends RefCounted

# 出生/复活点的**静态几何池**(2026-09-18 从 RoyaleHost 逐字搬出):地板格 / 同层连通区规模 /
# 开阔优选格。抽出来的理由与 `GridPathfinder.spread_cells` 当初那条一样 —— 大乱斗与 3v3
# 都要用同一套"别出生在走不出去的密封小间"的判据,抄第二份就会改一处漏一处。
# ★ 全部 `static`、且**不引任何 autoload**(只读 `MazeGenerator.current_grid`,它本身是 class_name
#   的 RefCounted)→ 本文件可被 `-s` 测试加载。
# ★ 缓存是**每进程**的(与搬出前同款行为):worker 进程一局一进程,故没有跨局失效问题。

const OPEN_AREA_MIN: int = 20    # 出生可走连通区最小规模(格);密封死角小间远小于此。**绝对**阈值(见自适应)
const PREFER_MIN: int = 8        # 优选格不足此数才回退下一级宽松判据

# ── 小图自适应门槛(2026-09-19)──
# `OPEN_AREA_MIN` 是按"正常大小"的图定的**绝对**阈值,小图上它可以**无人达到**:
# 典型 = PvP 固定图 `factory1v1`(150×100)—— 按 4 邻接算的**最大**地板连通区只有 **13 格**。
# 那时前两档恒空,池子**静默退化成全部地板格**(该图 843 个地板格里 155 个是**孤立单格区**),
# 于是 6 人 3v3 / 8 人大乱斗里会有人一开局就被关在走不出去的小间里 —— 不报错,只在实机看得见。
# 自适应:本图最大连通区 < `OPEN_AREA_MIN` 时,把"开阔"门槛按**本图比例**缩到
# 「最大连通区 × ADAPTIVE_RATIO」—— 保持"优先开阔区"的意图,绝不退成全部地板格。
# ★ 单调性:自适应只会让池子**变窄**(相对"全部地板格"),任何图都不会因此变宽。
# ★ 正常图(最大连通区 ≥ OPEN_AREA_MIN)一行不生效:门槛仍是 OPEN_AREA_MIN,**行为逐字不变**。
# ★ 为什么是"比例"而不是"只取最大那个区":实测该图最大的两个区各 13 格 —— 只取它们
#   会得到 26 格的池子(8 人大乱斗挤进两间小屋);取"≥ 最大值一半"得 130 格 / 14 个区。
const ADAPTIVE_RATIO: float = 0.5

static var _floor_cell_cache: Array = []   # 本局地板格(懒采集;砖被拆不刷新,够用)
static var _prefer_cache: Array = []       # 出生优选格缓存(开阔可走区;见 spawn_candidates)
static var _fallback_cache: Array = []     # 复活兜底池缓存(见 respawn_fallback)
static var _region_cache: Dictionary = {}  # 地板格 Vector2i -> 同层连通区规模


# 清空四张缓存。换图/换局时调用方自己决定要不要清(搬出前的行为是**从不主动清** —— 保持)。
static func reset_cache() -> void:
	_floor_cell_cache = []
	_prefer_cache = []
	_fallback_cache = []
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


# ── 出生/复活点优选(防"出生在走不出去的小房间")──
# 玩家实测:旧判据只要求"脚下有地",密封死角/1 格高夹层的地板格也会入选 →
# 出生在四面墙的小房间出不去。优选格需同时满足:
#   (1) 头顶 ≥2 格净空(站得直、跳得出去);
#   (2) 左右邻格空(出生处 ≥3 格宽,不被墙夹);
#   (3) 所在同层可走连通区规模 ≥ **area_threshold()**(密封 1~2 格死角自动淘汰;
#       该门槛正常图 = OPEN_AREA_MIN,小图按本图比例自适应 —— 见 ADAPTIVE_RATIO)。
# 地板格不足时逐级回退:连通区大但不要求三宽 → 任意地板格(极小图兜底)。
#
# ⚠ 已知边界(本次**未**修):连通区判据是**纯 4 邻接**,不含跳跃/梯子 —— 一级台阶就把两个区
#   断开,故"同区"只是"纯步行可达"的下界近似(实测 factory1v1 上连"三宽"格都有 30/515
#   落在单格区里)。要更准得把跳跃纳入可达性判据,那会同时改掉大乱斗与 3v3 的选格口径,
#   不在本次范围(取舍与代价见报告 §3)。
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


# 本图**最大**地板连通区的规模(格)。空网格 / 未加载 = 0。
static func max_region_size() -> int:
	var mx := 0
	for sz in region_sizes().values():
		mx = maxi(mx, int(sz))
	return mx


# 出生判据的"开阔"门槛(格)—— **阈值本体**,三档里凡涉及连通区规模的一律读它:
#   本图最大连通区 ≥ OPEN_AREA_MIN → OPEN_AREA_MIN(绝对阈值;正常图行为逐字不变)
#   否则                          → 最大连通区 × ADAPTIVE_RATIO(小图按本图比例缩放)
# ★ 下界 1:max_region_size() 为 0(空网格)时不给 0 —— 那会让 `>= thr` 恒真、池子变全量。
static func area_threshold() -> int:
	var mx := max_region_size()
	if mx >= OPEN_AREA_MIN:
		return OPEN_AREA_MIN
	return maxi(ceili(float(mx) * ADAPTIVE_RATIO), 1)


# 出生候选池(缓存):开阔可走地板格;不足则回退连通区大的地板格;再不足回退任意地板格。
# ★ 头两档的连通区判据走 `area_threshold()`(正常图 = OPEN_AREA_MIN;小图自适应 ——
#   否则小图上两档恒空、池子静默退化成**全部地板格**,见 ADAPTIVE_RATIO 上方那一段)。
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


# ── 复活/复位的**兜底池**(2026-09-19;首档筛空时的第二档)──
# 两个宿主原本的第二档是 `floor_cells()` = **全部地板格** —— 那与"首档在小图上退化成全量"
# 是**同一个病**,只是晚几十秒发生:干净池子里找不到"离敌人 ≥ RESPAWN_CLEARANCE"的格时,
# 玩家会**在小间里复活**(实测该图 843 个地板格里 155 个是孤立单格区)。
# 判据**复用 `area_threshold()`**(不另立第二套):取「连通区 ≥ 门槛」的全部地板格。
#
# ★★ **只在自适应生效的图上收窄**;正常图上原样返回 `floor_cells()`:
#   本次的目标是"别让小图的两档都退化成全量",正常图的主池本来就是干净的(实测 demo 的主池
#   59 格、全部区规模 ≥26),其兜底档维持既有行为 —— 这叫**动作范围**约束,不是遗漏。
#   (若日后要连正常图的兜底档一起收窄,删掉下面那两行 `if` 即可 —— 判据本来就是同一个。)
# ★ 收窄**不增加**"整池筛空 → 返回 (-1,-1) → 摆到地图回卷角落"的风险:该图实测(k = 5/7/8
#   个敌人,500 次随机布局)两档的**筛空率都是 0/500**,首档平均就有 108~113 格可用;
#   兜底档 130 格 ⊇ 首档 122 格,更不可能先空。
# ★ 返回**共享缓存**(与 `spawn_candidates()` 同一条别名纪律):调用方要在返回值上原地改,
#   先自己 `duplicate()`。
static func respawn_fallback() -> Array:
	if max_region_size() >= OPEN_AREA_MIN:
		return floor_cells()          # 正常图:维持原样(见上面 ★★)
	if not _fallback_cache.is_empty():
		return _fallback_cache
	var thr := area_threshold()
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= thr:
			_fallback_cache.append(c)
	return _fallback_cache


# 复活/复位选格的**池子序列**:先优选(`spawn_candidates()`)→ 再兜底(`respawn_fallback()`)。
# 两处调用方(`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for`)都读**这一份** ——
# 顺序本身就是判据的一部分("先优选、再兜底"),抄成两份迟早改一处漏一处(这就是本次修的那个病:
# 两处各写了一遍 `[_spawn_candidates(), _floor_cells()]`,于是两处**一起**退化成全量)。
# ★ 返回的是**新数组**,但**元素是共享缓存**(见上面两条的别名纪律):要原地改先 `duplicate()`。
static func respawn_pools() -> Array:
	return [spawn_candidates(), respawn_fallback()]


# 基座附近的候选格(环面距离 ≤ radius 格)。给 3v3 的"队内散开"用:
# 先选两个相距 ≥ SPAWN_CLEARANCE 的基座,再在各自附近取 3 个点 —— 这样"队内聚、队间远"。
# ★ 池子为空时返回全量候选(= 放弃"队内聚",但绝不返回空导致调用方少点)。
# ★★ **返回的池可能即共享缓存**(`spawn_candidates()` 返回的就是 `_prefer_cache` 本身):
#   两条回退分支原先直接把它交出去,于是同一个函数**两种别名语义** —— 调用方在返回值上原地
#   `.shuffle()` / `.erase()`,打乱的是**全局优选池**,此后所有读它的地方(`RoyaleHost.plan_spawns`
#   等)拿到的顺序都变了:静默、不报错。现统一成"返回新数组",但**纪律仍适用于本函数的调用方**:
#   要在返回值上原地改,先自己 `duplicate()`。
#   (注:`GridPathfinder.spread_cells` 内部第一件事就是 `pool = cells.duplicate()`,故
#    `cells_within(...)` 的返回值直接喂给它**是安全的**。)
static func cells_within(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	if center.x < 0 or center.y < 0:
		return spawn_candidates().duplicate()
	var d := grid_dims()
	for c in spawn_candidates():
		if GridPathfinder.toroidal_dist(c, center, d.x, d.y) <= radius:
			out.append(c)
	return out if not out.is_empty() else spawn_candidates().duplicate()
