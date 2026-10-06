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
# ★★ 下面这些数字**全部是旧 PvP 定图 `factory1v1.cyrm` 上实测的**。该图已于 **2026-10-02 退役**
#   (用户裁定,文件已删;现 PvP 定图 = `newfactory.cyrm`)—— 故本段的 `factory1v1` **不是**
#   在指今天的生产图,别照着它去量 newfactory。
#   ★ 顺带登记一个真实后果:**newfactory 的最大地板连通区实测 48 ≥ `OPEN_AREA_MIN`(20)**
#   ⇒ 自适应分支在**今天的生产图集里不会被触发**;它仍由 `spawn_pool_smoke` 的**合成网格**
#   夹具驱动(那张夹具取代了原先拿 factory1v1 当"缺陷图"的用法)。
#   ⇒ 该分支不是死代码(阈值仍是"任何图都可能需要"的保险),但**生产路径已无图能走到它**。
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
static var _last_resort_cache: Array = []  # 复活末档缓存(见 respawn_last_resort)
static var _region_cache: Dictionary = {}  # 地板格 Vector2i -> 同层连通区规模


# 清空五张缓存。换图/换局时调用方自己决定要不要清(搬出前的行为是**从不主动清** —— 保持)。
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
#
# ★★ 这是**开局散点**的结构保证(2026-09-19 评审点名:这才是本修复的真正凭据,比抽样强)——
#   两个宿主的开局散点全都取自本函数的返回值,故**结构上**落不到"连通区 < 门槛"的格上:
#     · `RoyaleHost.plan_spawns`:`picked = spread_cells(spawn_candidates().duplicate(), …)`
#       ⇒ `picked ⊆ spawn_candidates()`;而它那条"补足"分支(`_floor_cells()`)可达 ⟺
#       `picked.size() < n`,而 `spread_cells` **恒返回 `min(n, 池大小)`** ⇒ 该分支可达
#       ⟺ **池 < 人数**(两图池 122 / 59,人数上限 8 ⇒ 死路)。
#     · `TeamHost._plan_team_spawns_once`:基座、`cells_within(base, R)`、`spread_cells(…)`
#       三处来源**都是**本函数(或它的 duplicate)⇒ 同样 ⊆ 池。
#   ⇒ 与随机数无关(不是"抽 300 局没看见")。抽样读数只作旁证:`tests/smoke/spawn_pool_smoke`。
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


# ── 复活/复位的**两档兜底**(2026-09-19)──
# 两个宿主原本的兜底档是 `floor_cells()` = **全部地板格** —— 那与"首档在小图上退化成全量"
# 是**同一个病**,只是晚几十秒发生:干净池子里找不到"离敌人 ≥ RESPAWN_CLEARANCE"的格时,
# 玩家会**在小间里复活**(实测 factory1v1 的 843 个地板格里 155 个、demo 的 670 里 104 个
# 是孤立单格区)。故兜底不再是一档,而是**两级**(判据都长在同一条轴 `region_sizes()` 上):
#   第 ② 档 `respawn_fallback()`    = 连通区 ≥ `area_threshold()`(与首档同一门槛,只是不要求"三宽")
#   第 ③ 档 `respawn_last_resort()` = 连通区 ≥ 2(**只**排除孤立单格 —— 用户裁定的下限)
#
# ★★ 第 ③ 档为什么必须存在 —— **支点是结构,不是读数**:
#   ④ 第 ③ 档是第 ② 档的**超集**(`{连通区 ≥ 2} ⊇ {连通区 ≥ 门槛}`,只要门槛 ≥ 2;
#     本两图门槛 = 7 / 20)。序列**逐档放宽** ⇒ 多一档**只会减少**"整序列筛空"的布局数:
#     对任何布局,"走到某档有货"的集合只会变大,不可能变小。
#     ⇒ **有第 ③ 档一定不比没有它差**,与任何抽样无关。
#   ⑤ 为什么要比"只收一档"更好(而不是"不收"):只收到"≥ 门槛"时兜底档窄一个量级
#     (factory1v1 843→130、demo 670→61);筛空即返回 `(-1,-1)`,而消费端 `_respawn_player`
#     会照算 `spawn.x * ts` ⇒ **把人摆到 (-32,-32) 的地图回卷角落** —— 那比"在小间里复活"更糟
#     (用户裁定 2026-09-19:"后者更糟")。第 ③ 档几乎和收窄前的 `floor_cells()` 一样宽
#     (843→688 / 670→566),把这条新增风险压掉。
# ★ 实测(两图各 **4036** 个布局:规则网格 3~20 格 × 相位 0/1 = **36 个**(有区分度样本)+
#   随机撒点 4000 个(**已证到不了该事件**:2/4/6/8/12/16 个敌人 × 500 次 × 两种落点,
#   两图两档筛空率全 0/500 ⇒ 那 4000 个对本事件**无区分度**,只作背景),与**收窄前**的
#   `floor_cells()` 逐布局对账):
#     · 只收一档(两级方案)会**新增**「旧兜底有货 ∧ 新兜底筛空」的布局:factory1v1 **1** 个、
#       demo **5** 个(全部出自那 36 个规则网格);
#     · 加上第 ③ 档后,**在已扫布局族上未新增**:实测"第 ③ 档筛空而收窄前的兜底档还有货"的
#       布局 **0 个**。
#   ★ 口径:`(-1,-1)` 面与收窄前相同是**已扫布局族上的实测结论**,不是对"所有可能的敌人布局"
#     的证明(结构化布局的空间远大于我扫的等间距网格族)。而上面 ④ 那条**与读数无关**。
#   ★ 退化情形(登记):本图最大连通区 ≤ 2 时门槛会塌到 1,那时第 ② 档 == 全部地板格、
#     第 ③ 档反而**更窄**(超集关系反转)—— 这种图是病态图,`tests/smoke/spawn_pool_smoke` 的
#     "逐档放宽"断言会当场红。
# ★ 两级都**不含孤立单格**(第 ③ 档是 `≥ 2`),故"兜底档不含孤立单格"对所有图成立。
# ★ 自适应生效的图上第 ② 档 == 「连通区 ≥ 门槛(7)」;正常图上它 = 「连通区 ≥ 20」。
#   两图都是**收窄**(相对 `floor_cells()`),任何图都不会因此变宽。
# ★ 返回**共享缓存**(与 `spawn_candidates()` 同一条别名纪律):调用方要在返回值上原地改,
#   先自己 `duplicate()`。
static func respawn_fallback() -> Array:
	if not _fallback_cache.is_empty():
		return _fallback_cache
	var thr := area_threshold()
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= thr:
			_fallback_cache.append(c)
	return _fallback_cache


# 末档(第 ③):全部地板格里**排除孤立单格**(连通区 == 1)的那些。
# 这是"绝不返回 (-1,-1)"的最后一道:它几乎和收窄前的 `floor_cells()` 一样宽
# (factory1v1 843→688、demo 670→566),只把那批**绝对走不出去**的格拿掉。
static func respawn_last_resort() -> Array:
	if not _last_resort_cache.is_empty():
		return _last_resort_cache
	var sizes := region_sizes()
	for c in floor_cells():
		if int(sizes.get(c, 0)) >= 2:
			_last_resort_cache.append(c)
	return _last_resort_cache


# 复活/复位选格的**池子序列**:优选(`spawn_candidates()`)→ 兜底 → 末档。
# 两处调用方(`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for`)都读**这一份** ——
# 顺序本身就是判据的一部分("先优选、再兜底、最后放宽"),抄成两份迟早改一处漏一处
# (这就是本次修的那个病:两处各写了一遍 `[_spawn_candidates(), _floor_cells()]`,于是
#  两处**一起**退化成全量)。★ 序列**按池子大小单调不减**,且**每一档都不含孤立单格**。
# ★ 返回的是**新数组**,但**元素是共享缓存**(见上面两条的别名纪律):要原地改先 `duplicate()`。
static func respawn_pools() -> Array:
	return [spawn_candidates(), respawn_fallback(), respawn_last_resort()]


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


# ── 给"只有一个出生点的图"挑 role2 的出生格(2026-10-02 从 MatchBootstrap 搬来)──
# ★ 搬家的理由是**可测性**不是整洁:`MatchBootstrap` 静态引用 autoload(`GameParameters`/`NetBus`),
#   在 `-s` 探针里**编译失败** ⇒ `map_catalog_probe` 那几条断言被**静默跳过**而 verdict 照打 OK。
#   本文件自述"不引任何 autoload、可被 `-s` 测试加载",正是这类选格逻辑的家。
const FAR_CELLS := 15   # role2 的自动出生点离 role1 至少这么远(格;环面距离)


## 地板格(空 + 正下方实心)里离 `anchor` **环面距离 ≥ FAR_CELLS** 的最近一个;
## 全不满足就取最远的那个;网格为空返回 (-1,-1)(调用方那套兜底照旧)。
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
