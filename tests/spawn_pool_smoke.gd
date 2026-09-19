extends SceneTree

# 出生池守卫(共享组件 `SpawnPicker.spawn_candidates()`):**池子里不准有"落在小连通区"的格**。
# 跑法: timeout 120 "$GODOT" --headless --path . -s res://tests/spawn_pool_smoke.gd
# 通过 = `SPAWN POOL SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# `spawn_candidates()` 的判据分三档:①三宽 + 大连通区 ②大连通区 ③**任意地板格**。
# 而 ② 的"大"是**绝对**阈值 `OPEN_AREA_MIN = 20` —— 小图上它可以**无人达到**:
# PvP 固定图 `factory1v1`(150×100)按 4 邻接算的**最大**地板连通区只有 13 格、而且
# **843 个地板格里没一个**达到 20 ⇒ ①② 恒空,池子**静默退化**成全部地板格,里面有
# **155 个孤立单格区**(走不出去)。后果:6 人 3v3 / 8 人大乱斗开局有人被关在小间里,
# **不报错、不留日志**;而 `SpawnPicker` 是大乱斗与 3v3 **共用**的,两条线一起中招。
# 修法 = 小图自适应门槛(`SpawnPicker.area_threshold()` —— 最大连通区 < OPEN_AREA_MIN 时
# 按 `ADAPTIVE_RATIO` 缩放到本图比例),见该文件 ADAPTIVE_RATIO 上方那一段。
#
# ═══ 本探针钉什么 ═══
# ① **核心不变式**(对两张图):池子里**每一个**格的连通区规模都 ≥ `area_threshold()`;
#    再用独立写的 BFS 复算一遍连通区、按同一门槛算出期望集合,断言 **pool ⊆ 期望**
#    —— 判据不来自被测实现自己(`region_sizes()` 只用来**交叉核对**,[仪器] B)。
# ② **反向/变异**:断言池子是全部地板格的**真子集**(排除数 > 0)。把自适应那档改回
#    `_prefer_cache = floor`(或把 `area_threshold()` 改回恒 `OPEN_AREA_MIN`)→ 这条红。
# ③ **正常图不许变样**:`demo.cyrm` 上 `area_threshold()` 必须**恰好**是 `OPEN_AREA_MIN`,
#    且池子与"三宽 ∩ 连通区≥20"逐格相等 —— 自适应对小图之外**一行不生效**。
#
# ═══ 三个坑(本仓踩过的)═══
# ★ `-s` 阶段 autoload 不存在 ⇒ **不能用 `WorldBuilder.load_grid()`**(它写
#   `GameParameters.MAP_WIDTH`)⇒ 地图自己载:`set_map_file` + `load_map_file` + 赋
#   `current_grid` + **`TileDefs.load_defs()`**。少了最后那一步,`is_blocked` 的缺省判据是
#   "非 0 即墙"(梯子/水都算墙)⇒ 池子与生产**悄悄不同**、且照样全绿 —— 本文件用
#   [仪器] A 把"defs 真加载了"钉住。
# ★ `SpawnPicker` 的三张缓存是**每进程**的 `static var`,换图必须 `reset_cache()`,
#   否则第二张图读到第一张图的地板格池子(静默)。[仪器] C 钉住它真的换过来了。
# ★ 空载守卫:`load()` 失败/地图读不到就 `quit(1)` —— `-s` 里抛错走不到 `quit()` 会**永久挂起**。

const MAP_BUGGY := "res://maps/factory1v1.cyrm"    # 缺陷图:最大连通区 13 < OPEN_AREA_MIN
const MAP_NORMAL := "res://maps/demo.cyrm"         # 正常图:最大连通区 35 ≥ OPEN_AREA_MIN

# 调用方那段"离敌人够远"筛选的清空距离(格)。= 两个宿主的 `RESPAWN_CLEARANCE`
# (royale_host.gd / team_host.gd 各一个,值都是 8)—— 本探针只重放那段**平凡筛选**的形状,
# 故这个数必须与生产同值。★ 它由 ⑥ 的源码级断言钉着(两个文件里都得写 `:= 8`),
# 以免本探针的假设与生产**悄悄漂开**(那时 ⑤ 的正/负例验的就不是生产那条路了)。
const RESPAWN_CLEARANCE := 8

# ⑤ 里搜"首档空 ∧ 兜底档有货"的布局次数(固定种子)。真找到过 = 负例可端到端驱动 → 那条断言红。
const NEG_SEARCH_TRIALS := 800

var _fail := 0
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  ok   %s" % msg)
	else:
		_fail += 1
		print("  FAIL %s" % msg)


func _initialize() -> void:
	# ── 空载守卫 ──
	for path in [MAP_BUGGY, MAP_NORMAL]:
		if not FileAccess.file_exists(path):
			print("SPAWN POOL SMOKE: FAIL(找不到地图 %s)" % path)
			quit(1)
			return
	# ★ 判据走 `SpawnPicker` 的**全局类名**(静态依赖即可):它的依赖链
	#   (MazeGenerator → MapFormat / GridPathfinder / TileDefs)**一个 autoload 都不碰**,
	#   故 `-s` 下编得过(与 `LobbyRooms` 那条链不同,后者静态引用会把 NetBus 拖进来)。
	#   空载守卫仍要有:类缓存没刷出来时引用处会编译失败。
	var sp = SpawnPicker
	if sp == null:
		print("SPAWN POOL SMOKE: FAIL(读不到 SpawnPicker)")
		quit(1)
		return

	_run_map(MAP_BUGGY, true)
	_run_map(MAP_NORMAL, false)
	_check_wiring()

	if _fail == 0:
		print("SPAWN POOL SMOKE: ALL-OK(%d 条断言)" % _checks)
		quit(0)
	else:
		print("SPAWN POOL SMOKE: FAIL(%d 条不符)" % _fail)
		quit(1)


# 载图 → 复算连通区 → 与 `spawn_candidates()` 对账。
# want_adaptive = 本图是否**应当**走自适应分支(小图 true / 正常图 false)。
func _run_map(path: String, want_adaptive: bool) -> void:
	print("")
	print("═══ %s(期望走%s分支)═══" % [path, "自适应" if want_adaptive else "绝对阈值"])
	MazeGenerator.set_map_file(path)
	var grid: Array = MazeGenerator.load_map_file()
	if grid.is_empty():
		_check(false, "地图加载成功(空网格 = 后面全无意义)")
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	SpawnPicker.reset_cache()     # ★ 每进程缓存:换图不重置会静默沿用上一张图的池子

	# ── [仪器] A `TileDefs` 真加载了 ──
	# 纹理 11 = 梯子(type=passage)。未加载 defs 时缺省是 wall ⇒ 梯子被当墙 ⇒ 池子与生产
	# **悄悄不同**(而且本探针照样能全绿)。故先钉住"加载生效"。
	_check(TileDefs.type_id_of(11) == TileDefs.TYPE_PASSAGE,
			"[仪器] TileDefs.load_defs() 真生效(纹理 11 是通道;未加载时缺省判 wall)")

	var rows: int = grid.size()
	var cols: int = (grid[0] as Array).size()
	# ── 独立复算:地板格 + 4 邻接环面连通区(不调 `SpawnPicker.region_sizes()`)──
	var floor: Array = []
	for y in range(rows):
		for x in range(cols):
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				floor.append(c)
	var own := _bfs_regions(floor, cols, rows)

	# ── [仪器] B 独立 BFS 与生产的连通区定义一致(只作核对,不作判据来源)──
	var prod := SpawnPicker.region_sizes()
	var mism := 0
	for c in floor:
		if int(own.get(c, -1)) != int(prod.get(c, -1)):
			mism += 1
	_check(mism == 0, "[仪器] 独立 BFS 与 SpawnPicker.region_sizes() 逐格一致(不符 %d)" % mism)
	_check(SpawnPicker.floor_cells().size() == floor.size(),
			"[仪器] 地板格数与独立扫描一致(%d vs %d)" % [SpawnPicker.floor_cells().size(), floor.size()])

	var mx := 0
	for c in floor:
		mx = maxi(mx, int(own[c]))
	_check(SpawnPicker.max_region_size() == mx,
			"[仪器] 最大连通区规模 = 独立复算值(%d vs %d)" % [SpawnPicker.max_region_size(), mx])

	# ── [仪器] C 缓存真的换过来了(否则第二张图读的是第一张的池子)──
	_check(SpawnPicker.floor_cells().size() == floor.size(),
			"[仪器] reset_cache() 后池子的地板格是本图的(%d)" % floor.size())

	# ── [仪器] D 本图确实落在期望的那一支 ──
	# 这是**区分度**的前提:`want_adaptive` 为真时,旧判据(绝对阈值)下前两档必须恒空 ——
	# 否则本图照不到这次修的东西(断言会变成恒真的摆设)。
	var thr := SpawnPicker.area_threshold()
	var old_big := 0
	for c in floor:
		if int(own[c]) >= SpawnPicker.OPEN_AREA_MIN:
			old_big += 1
	if want_adaptive:
		_check(mx < SpawnPicker.OPEN_AREA_MIN,
				"[仪器] 本图最大连通区 %d < OPEN_AREA_MIN %d(缺了这个前提,下面全是空断言)"
				% [mx, SpawnPicker.OPEN_AREA_MIN])
		_check(old_big < SpawnPicker.PREFER_MIN,
				"[仪器] 旧判据下第 ② 档只有 %d 格(< PREFER_MIN %d)⇒ 池子**必然**退化成全部地板格"
				% [old_big, SpawnPicker.PREFER_MIN])
		_check(thr == maxi(ceili(float(mx) * SpawnPicker.ADAPTIVE_RATIO), 1),
				"自适应门槛 = ceil(最大连通区 %d × %.2f) = %d" % [mx, SpawnPicker.ADAPTIVE_RATIO, thr])
	else:
		_check(mx >= SpawnPicker.OPEN_AREA_MIN,
				"[仪器] 本图最大连通区 %d ≥ OPEN_AREA_MIN %d" % [mx, SpawnPicker.OPEN_AREA_MIN])
		_check(thr == SpawnPicker.OPEN_AREA_MIN,
				"★ 正常图门槛**恰好**是 OPEN_AREA_MIN(自适应一行不生效;实际 %d)" % thr)

	# ── 期望集合(判据来自独立 BFS + `area_threshold()` 的**契约**)──
	var expected := {}
	for c in floor:
		if int(own[c]) >= thr:
			expected[c] = true

	var pool: Array = SpawnPicker.spawn_candidates()
	_check(not pool.is_empty(), "池子非空(%d 格)" % pool.size())

	# ── ① 核心不变式:池子里没有"落在小连通区"的格 ──
	var below: Array = []
	var min_sz := 1 << 30
	var outside := 0
	for c in pool:
		var sz := int(own.get(c, 0))
		min_sz = mini(min_sz, sz)
		if sz < thr:
			below.append("%s(连通区 %d)" % [str(c), sz])
		if not expected.has(c):
			outside += 1
	_check(below.is_empty(),
			"★ 池子里没有落在「连通区 < 门槛 %d」的格(违反 %d 个;池内最小连通区 %d;前几个:%s)"
			% [thr, below.size(), min_sz, str(below.slice(0, 5))])
	_check(outside == 0,
			"★ 池子 ⊆ 独立复算的期望集合(区规模 ≥ %d;越界 %d 个)" % [thr, outside])
	# 单格区是"绝对走不出去"的下限读数,单独点一次名(它正是本缺陷的病征)
	var singles := 0
	for c in pool:
		if int(own[c]) == 1:
			singles += 1
	_check(singles == 0, "★ 池子里没有孤立单格区的格(实际 %d 个)" % singles)

	# ── ② 反向下界:池子必须是全部地板格的**真子集** ──
	# 这条就是**变异探针**:把 `spawn_candidates()` 的末档写回 `_prefer_cache = floor`
	# (或把 `area_threshold()` 改回恒 `OPEN_AREA_MIN`),池子当场变成全部地板格 → 红。
	# ★ 只写"池子 ⊆ 期望"是不够的:全部地板格在 `thr == 1` 时**也**满足它。
	var excluded := floor.size() - pool.size()
	_check(pool.size() < floor.size() and excluded > 0,
			"★ 池子是全部地板格的真子集(池 %d < 地板 %d;排除了 %d 格)"
			% [pool.size(), floor.size(), excluded])
	_check(pool.size() >= mini(SpawnPicker.PREFER_MIN, expected.size()),
			"池子不小于 PREFER_MIN(否则说明档位回退到了更宽的一档:池 %d,期望集合 %d)"
			% [pool.size(), expected.size()])

	# ── ④ 复活/复位的**兜底档**:同一条病(第二档原先 = 全部地板格),同样不许含孤立格 ──
	# 调用方(`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for`)现在读**同一份**池序列
	# `SpawnPicker.respawn_pools()`;这里就把那份序列整个检查一遍 —— 这就是"两条路都不含孤立格"。
	var pools: Array = SpawnPicker.respawn_pools()
	_check(pools.size() == 2, "复活池序列是两档(优选 → 兜底;实际 %d 档)" % pools.size())
	if pools.size() == 2:
		_check(_same_set(pools[0], pool),
				"首档就是 `spawn_candidates()` 那一份(不是另抄一遍)")
		if want_adaptive:
			_check(_same_set(pools[1], expected.keys()),
					"★ 兜底档逐格 == 期望集合(连通区 ≥ %d;%d 格)"
					% [thr, (pools[1] as Array).size()])
			_check(_is_subset(pools[0], pools[1]),
					"★ 兜底档 ⊇ 首档(兜底不该比优选还窄;首档 %d / 兜底 %d)"
					% [(pools[0] as Array).size(), (pools[1] as Array).size()])
		else:
			# ★ 动作范围:本次**不**动正常图的兜底档(它的主池本来就是干净的),逐格锁住。
			_check(_same_set(pools[1], floor),
					"★ 兜底档在本图**维持原样**(== 全部地板格 %d 格;本次只收窄自适应生效的图)"
					% floor.size())
			# [读数] 本图兜底档**没有被收窄**的代价,当场量出来(不是"大概没事"):
			# 稠密布局能把首档筛空、而兜底档还剩货 ⇒ 正常图上"复活落进小间"这条路**是可达的**,
			# 我们只是**按动作范围约束**没动它。若哪天要连正常图一起收窄,把 `respawn_fallback`
			# 里那两行 `if` 删掉,这条读数会跟着变 —— 那时改它,别删它。
			var dense: Array = []
			for gy in range(0, rows, RESPAWN_CLEARANCE):
				for gx in range(0, cols, RESPAWN_CLEARANCE):
					dense.append(Vector2i(gx, gy))
			var u1 := _count_usable(pools[0], dense, cols, rows, RESPAWN_CLEARANCE)
			var u2 := _count_usable(pools[1], dense, cols, rows, RESPAWN_CLEARANCE)
			var n_single_fb := 0
			for c in pools[1]:
				if int(own[c]) == 1:
					n_single_fb += 1
			print("  [info] 本图(正常图)兜底档**未收窄**:%d 格里仍有 %d 个孤立单格;"
					% [(pools[1] as Array).size(), n_single_fb])
			print("  [info] 稠密布局(%d 个敌人,间距 %d 格):首档可用 %d / 兜底档可用 %d"
					% [dense.size(), RESPAWN_CLEARANCE, u1, u2])
			_check(u1 == 0 and u2 > 0,
					("★ [读数] 正常图上「首档筛空 → 落到兜底档」这条路**是可达的**(稠密布局下首档可用 0、"
					+ "兜底档可用 %d),而我们按**动作范围**约束没收窄它(那 %d 格里含孤立单格)—— "
					+ "这是有意选择,不是遗漏;收窄与否见 respawn_fallback 的 ★★") % [u2, n_single_fb])
		if want_adaptive:
			var bad: Array = []
			for i in range(pools.size()):
				var pl: Array = pools[i]
				var n_below := 0
				var n_single := 0
				for c in pl:
					if int(own[c]) < thr:
						n_below += 1
					if int(own[c]) == 1:
						n_single += 1
				if pl.is_empty() or n_below > 0 or n_single > 0:
					bad.append("第 %d 档(空=%s / 连通区<门槛 %d 个 / 孤立单格 %d 个)"
							% [i + 1, str(pl.is_empty()), n_below, n_single])
			_check(bad.is_empty(),
					"★ 复活池序列的**每一档**都非空、都不含孤立单格(问题:%s)" % str(bad))

			# ── ⑤ 两条路各走一遍(正/负)—— 只重放调用方那段**平凡的距离筛选** ──
			# ★ 池子序列取自**生产**(`respawn_pools()`);这段筛选是两个宿主共有的形状
			#   (royale 判所有存活玩家、3v3 判存活敌人),这里为看清"这一局走哪一档"而重放一遍。
			var one_far: Array = [Vector2i(0, 0)]
			var pick1 := _pick(pools[0], one_far, cols, rows, RESPAWN_CLEARANCE)
			_check(pick1.x >= 0 and int(own[pick1]) >= thr and int(own[pick1]) != 1,
					"★ 正例 · 首档够用时走首档,且选出来的格**不是孤立单格**(选到 %s,连通区 %d)"
					% [str(pick1), int(own.get(pick1, 0))])
			# 负例:首档被筛空 → 落到第二档。
			# ★★ **实测这个场景在本图构造不出来** —— 8 个"只在兜底档里"的格与首档的格交织在
			#   同一批连通区里,能筛空首档的布局必然把兜底档一起筛空。故这里**直接从第二档起跑**
			#   (= 调用方在第一档筛空后落到第二档时执行的**同一段代码**),断言它带出来的也干净;
			#   并且当场搜一遍"首档空 ∧ 兜底档有货"的布局,把"构造不出来"本身变成一条读数。
			var pick2 := _pick(pools[1], one_far, cols, rows, RESPAWN_CLEARANCE)
			_check(pick2.x >= 0 and int(own[pick2]) >= thr and int(own[pick2]) != 1,
					"★ 负例 · 落到兜底档时选出来的格**也不是孤立单格**(选到 %s,连通区 %d)"
					% [str(pick2), int(own.get(pick2, 0))])
			# 搜索:随机撒 8 个敌人(生产最多 8 人),找"首档空 ∧ 兜底档有货"。找到了 = 负例可端到端驱动,
			# 那时 ⑤ 的负例就该改成真布局(本断言会红,提醒你换)。
			var found := 0
			for t in range(NEG_SEARCH_TRIALS):
				seed(90210 + t)
				var enemies: Array = []
				for i in range(8):
					enemies.append(Vector2i(randi() % cols, randi() % rows))
				if not _has_usable(pools[0], enemies, cols, rows, RESPAWN_CLEARANCE) \
						and _has_usable(pools[1], enemies, cols, rows, RESPAWN_CLEARANCE):
					found += 1
			_check(found == 0,
					("★ 负例**不可构造**(本图几何):%d 次随机布局(每次 8 个敌人)里「首档空 ∧ 兜底档有货」"
					+ "出现 %d 次 ⇒ 兜底档在本图**够不到**,这才是它必须被结构性地断言、而不是靠布局驱动的原因"
					+ "(真出现了这条红 = 该把 ⑤ 的负例改成真布局)") % [NEG_SEARCH_TRIALS, found])

	if not want_adaptive:
		# ── ③ 正常图逐格锁行为:池子 == 「三宽 ∩ 连通区 ≥ OPEN_AREA_MIN」──
		var want: Array = []
		for c in floor:
			if int(own[c]) >= SpawnPicker.OPEN_AREA_MIN and SpawnPicker.roomy_floor(c):
				want.append(c)
		_check(_same_set(pool, want),
				"★ 正常图的池子逐格不变(期望 %d 格 / 实际 %d)" % [want.size(), pool.size()])

	print("  [info] 地板 %d 格 / 连通区最广 %d 格 / 门槛 %d / 池子 %d 格(排除 %d)"
			% [floor.size(), mx, thr, pool.size(), excluded])


# 两表是否同一集合(元素唯一,与顺序无关)。
func _same_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var sa: Array = a.duplicate()
	var sb: Array = b.duplicate()
	sa.sort()
	sb.sort()
	return sa == sb


# a ⊆ b(元素唯一)。
func _is_subset(a: Array, b: Array) -> bool:
	var hay := {}
	for c in b:
		hay[c] = true
	for c in a:
		if not hay.has(c):
			return false
	return true


# 重放调用方那段"离每个敌人都 ≥ clear 格(环面曼哈顿)"的筛选:池子洗牌后取第一个满足的格。
# 找不到返回 (-1,-1)(= 生产的哨兵值)。
func _pick(pool: Array, enemies: Array, cols: int, rows: int, clear: int) -> Vector2i:
	var cells: Array = pool.duplicate()
	cells.shuffle()
	for c in cells:
		var ok := true
		for e in enemies:
			if GridPathfinder.toroidal_dist(c, e, cols, rows) < clear:
				ok = false
				break
		if ok:
			return c
	return Vector2i(-1, -1)


# 该池子里**有没有**满足"离每个敌人都 ≥ clear 格"的格(找到即返回 —— 搜索里跑几千次,要早退)。
func _has_usable(pool: Array, enemies: Array, cols: int, rows: int, clear: int) -> bool:
	for c in pool:
		var ok := true
		for e in enemies:
			if GridPathfinder.toroidal_dist(c, e, cols, rows) < clear:
				ok = false
				break
		if ok:
			return true
	return false


# 该池子里有几个满足"离每个敌人都 ≥ clear 格"的格(读数用,不判成败)。
func _count_usable(pool: Array, enemies: Array, cols: int, rows: int, clear: int) -> int:
	var n := 0
	for c in pool:
		var ok := true
		for e in enemies:
			if GridPathfinder.toroidal_dist(c, e, cols, rows) < clear:
				ok = false
				break
		if ok:
			n += 1
	return n


# ── ⑥ 源码级:两个宿主的复活选格**真的接了**这条池序列 ──
# 承重的理由:池序列收在 `SpawnPicker` 里,但"接上没接上"是两处**调用点**的事 ——
# 只测 `SpawnPicker` 的话,宿主里那句 `[_spawn_candidates(), _floor_cells()]` 原样留着也照样全绿
# (那正是本次修的那个病:两处各抄一遍、一起退化成全量)。故按**函数体**扫,不是按整文件
# (`royale_host.gd` 的 `plan_spawns` 里**另有**一处合法的 `_floor_cells()` 用途)。
func _check_wiring() -> void:
	print("")
	print("═══ ⑥ 宿主接线(源码级)═══")
	var cases := [
		{"file": "res://server/royale_host.gd", "fn": "_spawn_cell", "want": "_respawn_pools()"},
		{"file": "res://server/team_host.gd", "fn": "_respawn_cell_for", "want": "respawn_pools()"},
	]
	for cs in cases:
		var src := ScanUtil.read(String(cs["file"]))
		if src.is_empty():
			_check(false, "读得到 %s(读不到 = 下面两条恒真)" % cs["file"])
			continue
		var body := ScanUtil.func_body(ScanUtil.code_only(src), String(cs["fn"]))
		_check(not body.is_empty(),
				"[仪器] 取到 %s 的 `%s` 函数体(%d 字符;空 = 下面两条恒真)"
				% [cs["file"], cs["fn"], body.length()])
		_check(body.contains(String(cs["want"])),
				"★ %s 的 `%s` 走生产那份池序列(`%s`)" % [cs["file"], cs["fn"], cs["want"]])
		# 反向:函数体里**不得**再出现第二档的地板格来源(留着它 = 本修复形同没接)
		var dirty := body.contains("_floor_cells()") or body.contains("SpawnPicker.floor_cells()")
		_check(not dirty,
				"★ %s 的 `%s` **不再**自己拼兜底档(把 `floor_cells()` 写回这个函数体 = 池子又退化成全量)"
				% [cs["file"], cs["fn"]])
	# 探针自己的 `RESPAWN_CLEARANCE` 必须与两个宿主同值(不同值 → ⑤ 的正/负例验的是另一条路)
	var both := "%s\n%s" % [ScanUtil.read("res://server/royale_host.gd"),
			ScanUtil.read("res://server/team_host.gd")]
	_check(both.contains("const RESPAWN_CLEARANCE := %d" % RESPAWN_CLEARANCE),
			"★ 两个宿主的 RESPAWN_CLEARANCE 与探针同值(= %d;漂了的话 ⑤ 的正/负例就不是生产那条路)"
			% RESPAWN_CLEARANCE)


# 独立的 4 邻接**环面** BFS(与生产同语义,但独立写一遍 —— 探针的判据不取自被测实现)。
func _bfs_regions(floor: Array, cols: int, rows: int) -> Dictionary:
	var is_f := {}
	for c in floor:
		is_f[c] = true
	var seen := {}
	var out := {}
	for c in floor:
		if seen.has(c):
			continue
		var stack: Array = [c]
		var members: Array = []
		seen[c] = true
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			members.append(cur)
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nb := Vector2i(posmod(cur.x + off.x, cols), posmod(cur.y + off.y, rows))
				if seen.has(nb) or not is_f.has(nb):
					continue
				seen[nb] = true
				stack.append(nb)
		for m in members:
			out[m] = members.size()
	return out
