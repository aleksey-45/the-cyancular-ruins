extends SceneTree

# 出生池守卫(共享组件 `SpawnPicker`):**出生池与复活池序列里都不准有"落在小连通区"的格**。
# 跑法: timeout 120 "$GODOT" --headless --path . -s res://tests/smoke/spawn_pool_smoke.gd
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
# ③ **正常图的出生池不许变样**:`demo.cyrm` 上 `area_threshold()` 必须**恰好**是 `OPEN_AREA_MIN`,
#    且出生池与"三宽 ∩ 连通区≥20"逐格相等 —— 自适应对小图之外**一行不生效**。
#    (★ 复活池序列**不在此列**:2026-09-19 用户裁定它**对所有图生效** —— "兜底档仍是全部地板格"
#     是"明知在船上的 bug",不是"为不改行为而放过的边界"。)
# ④ **复活池序列**(`respawn_pools()`,三档):每一档都不含孤立单格;逐档放宽;前两档还不含
#    "连通区 < 门槛"的格。★ 三档是**用户裁定的形状**:第 ③ 档只排除孤立单格 —— 因为把兜底档
#    一路收到"连通区 ≥ 门槛"会**新增** `(-1,-1)`(⇒ 摆到地图回卷角落,比"在小间里复活"更糟;
#    实测 4036 布局 ×2 图:只收一档新增 1 个 / 5 个,加第 ③ 档后**新增为 0**)。
# ⑤ **各条路各走一遍**:正例(首档够用)、中间档、负例(真搜一个"首档筛空"的布局,**端到端**
#    跑完整个序列)。★ 负例的搜索是**数据**,不是装饰:本图能筛空首档的布局是**稠密网格**
#    (随机撒点到不了 —— 首档那 122 格散在十来个区里,8 个敌人盖不满)。
# ⑥ **宿主接线(源码级)**:两个宿主的选格**函数体**必须走 `respawn_pools()` 且不再自己拼
#    `floor_cells()` —— 只测 `SpawnPicker` 的话,宿主里那句原样留着**照样全绿**(那正是本病的成因)。
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

# 一局最多几个人(大乱斗 `--roles 1..8`;3v3 是 6)。只用于 ⑦ 那条**补足分支可达性**守卫:
# 补足分支可达 ⟺ 干净池 < 人数,故用上界来判断"今天一定不可达"。
const MAX_PLAYERS := 8

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
	# ★ 播种:`_pick` / `_walk` 内部 `shuffle()` 读**全局 RNG** —— 不播的话输出里那些
	#   "选到 (61, 90)"的读数**跨跑不可复现**(断言本身不看具体格,但读数就失去了证据价值)。
	#   搜索段自己会 `seed(...)`,整跑仍是确定性的。
	seed(20260919)

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

	# ── ④ 复活/复位:池序列**每一档**都不许含孤立单格(同一条病,后两档原先就是全部地板格)──
	# 调用方(`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for`)现在读**同一份**池序列
	# `SpawnPicker.respawn_pools()`;这里就把那份序列整个检查一遍 —— 这就是"每条路都不含孤立格"。
	# ★ 2026-09-19 起**对所有图生效**(用户裁定:"明知在船上的 bug"不许按动作范围放过),
	#   故本段不再按 `want_adaptive` 分叉:两图跑同一套断言。
	var pools: Array = SpawnPicker.respawn_pools()
	_check(pools.size() == 3, "复活池序列是三档(优选 → 兜底 → 末档;实际 %d 档)" % pools.size())
	if pools.size() == 3:
		# 末档 = 全部地板格去掉孤立单格(它的存在理由:兜底档比原样窄一个量级,筛空即 (-1,-1)
		# ⇒ 摆到地图回卷角落,比"在小间里复活"更糟 —— 见 respawn_fallback 的 ★★)
		var want_last: Array = []
		for c in floor:
			if int(own[c]) >= 2:
				want_last.append(c)
		_check(_same_set(pools[0], pool), "首档就是 `spawn_candidates()` 那一份(不是另抄一遍)")
		_check(_same_set(pools[1], expected.keys()),
				"★ 第 ② 档逐格 == 「连通区 ≥ 门槛 %d」(%d 格)" % [thr, (pools[1] as Array).size()])
		_check(_same_set(pools[2], want_last),
				"★ 第 ③ 档逐格 == 「全部地板格去掉孤立单格」(%d 格)" % (pools[2] as Array).size())
		# 序列按池子大小单调不减("兜底"的语义:放宽,不是换一个更窄的集合)
		var mono: Array = []
		for i in range(pools.size() - 1):
			if not _is_subset(pools[i], pools[i + 1]):
				mono.append("第 %d 档(%d)⊄ 第 %d 档(%d)"
						% [i + 1, (pools[i] as Array).size(), i + 2, (pools[i + 1] as Array).size()])
		_check(mono.is_empty(), "★ 池序列逐档**放宽**(每一档 ⊇ 前一档;问题:%s)" % str(mono))

		var bad: Array = []
		for i in range(pools.size()):
			var pl: Array = pools[i]
			var n_single := 0
			for c in pl:
				if int(own[c]) == 1:
					n_single += 1
			if pl.is_empty() or n_single > 0:
				bad.append("第 %d 档(空=%s / 孤立单格 %d 个)"
						% [i + 1, str(pl.is_empty()), n_single])
		_check(bad.is_empty(),
				"★ 复活池序列的**每一档**都非空、都**不含孤立单格**(问题:%s)" % str(bad))
		# 前两档还要更强:不含任何"连通区 < 门槛"的格(第 ③ 档只保证 ≥2,那是有意的下限)
		var weak: Array = []
		for i in [0, 1]:
			var n := 0
			for c in pools[i]:
				if int(own[c]) < thr:
					n += 1
			if n > 0:
				weak.append("第 %d 档有 %d 个" % [i + 1, n])
		_check(weak.is_empty(),
				"★ 前两档都不含「连通区 < 门槛 %d」的格(问题:%s)" % [thr, str(weak)])

		# ⑦ 补足分支的**可达性守卫**(评审 Minor 2:姐妹分支 = `RoyaleHost.plan_spawns` 的
		# `if picked.size() < n` → `_floor_cells()`)。★ 它**仍是全量地板格**(同病),但今天不可达:
		# `spread_cells` 恒返回 `min(n, 池大小)` —— ★ 那条不变量**不在本文件**,它钉在
		# `tests/smoke/enemy_logic_smoke.gd` 的 `_phase_spread_cells`(「count 超过池子应返回全部」)。
		# 本文件**从不调用 `spread_cells`**(只调 `SpawnPicker`),故这里只引用它当前提。
		# 于是:补足分支可达 ⟺ **干净池 < 人数**。实测池 122(factory1v1)/ 59(demo),人数上限 8 ⇒ 不可达。
		# ★ 为什么**不**顺手把它也收窄:那个分支恰在"池子极小时"才可达,收窄会让补足**补不满** ⇒
		#   `out[role] = (-1,-1)` ⇒ 摆到地图回卷角落 —— 按用户已裁定的偏好((-1,-1) 更糟),
		#   这个分支**保持原样才是对的**。故这里钉"不可达",而不是改它:哪天这条红,说明池缩到了
		#   人数以下、那个取舍真的来了,该由人来裁(而不是被静默地改掉)。
		_check(pools[0].size() >= MAX_PLAYERS,
				("★ 补足分支仍**不可达**:干净池 %d ≥ 人数上限 %d ⇒ `plan_spawns` 里那条 "
				+ "`_floor_cells()` 补足走不到(它一旦可达,孤立单格会被放回开局散点;而收窄它会把 "
				+ "(-1,-1) 放进来 —— 那个取舍要人来裁)") % [(pools[0] as Array).size(), MAX_PLAYERS])

		# ── ⑤ 各条路各走一遍(正/负)—— 端到端跑调用方那段循环 ──
		# ★ 池子序列取自**生产**(`respawn_pools()`);`_walk` 重放的是两个宿主共有的那段
		#   **平凡的距离筛选 + 逐档放宽**(royale 判所有存活玩家、3v3 判存活敌人)。
		var one_far: Array = [Vector2i(0, 0)]
		var pick1 := _pick(pools[0], one_far, cols, rows, RESPAWN_CLEARANCE)
		_check(pick1.x >= 0 and int(own[pick1]) >= thr and int(own[pick1]) != 1,
				"★ 正例 · 首档够用时走首档,且选出来的格**不是孤立单格**(选到 %s,连通区 %d)"
				% [str(pick1), int(own.get(pick1, 0))])
		# 中间档单独走一遍(= 调用方在首档筛空、第 ② 档有货时执行的同一段代码)
		var pick2 := _pick(pools[1], one_far, cols, rows, RESPAWN_CLEARANCE)
		_check(pick2.x >= 0 and int(own[pick2]) >= thr and int(own[pick2]) != 1,
				"★ 中间档 · 落到第 ② 档时选出来的格**也不是孤立单格**(选到 %s,连通区 %d)"
				% [str(pick2), int(own.get(pick2, 0))])
		# 负例:找一个"首档被筛空"的**真布局**,然后端到端跑完整个 `respawn_pools()` 循环 ——
		# 断言它确实落到了更后面的档、且那一档带出来的格不含孤立单格。
		# (搜索:先扫规则网格(实测能筛空首档的是稠密的网格布局,随机撒点到不了),再随机兜底。)
		var search := _find_blanking_layout(pools, cols, rows)
		var searched: int = int(search["count"])
		var blanking: Array = search["layout"]
		_check(searched > 0, "[仪器] 负例搜索真的跑了(%d 个布局;0 = 下面的结论没有覆盖)" % searched)
		print("  [info] 负例搜索:%d 个布局里「首档筛空」的有 %d 个%s"
				% [searched, int(search["found"]),
					" ⇒ 用真布局端到端驱动" if not blanking.is_empty() else " ⇒ 本图构造不出来,改从第 ② 档起跑"])
		if blanking.is_empty():
			# 搜不到(本图几何不允许:能筛空首档的布局必然把后面几档一起筛空)→ 从第 ② 档起跑,
			# 那正是调用方在首档筛空后执行到的**下一段代码**。★ 这条**不是**恒绿装饰:
			# 它带的是"第 ② 档自己也不含孤立单格"这个实质断言;而"搜不到"是个**读数**(上面那行)。
			# (上一版把它写成 `_check(found == 0)` —— 在那个分支里恒真,已按本仓纪律摘掉。)
			var pick3 := _pick(pools[1], one_far, cols, rows, RESPAWN_CLEARANCE)
			_check(pick3.x >= 0 and int(own[pick3]) != 1,
					"★ 负例 · 从第 ② 档起跑,选出的格不含孤立单格(选到 %s,连通区 %d)"
					% [str(pick3), int(own.get(pick3, 0))])
		else:
			var enemies: Array = blanking
			var u1 := _count_usable(pools[0], enemies, cols, rows, RESPAWN_CLEARANCE)
			var walk := _walk(pools, enemies, cols, rows, RESPAWN_CLEARANCE)
			_check(u1 == 0, "[仪器] 该布局确实把首档筛空了(可用 %d)" % u1)
			_check(int(walk["tier"]) >= 1,
					"★ 负例 · 首档筛空后**落到了后面的档**(第 %d 档),不是返回 (-1,-1)"
					% (int(walk["tier"]) + 1))
			# ★★ 这一条**不是区分度断言**(评审 2026-09-19 指出,别把它算进覆盖):它由构造保证 ——
			#   序列里每一档都已被 ④ 钉成"不含孤立单格"(且上面刚断言过逐档放宽),故"选出来的格
			#   不含孤立单格"必然成立。它的价值只是**把端到端那条路的结果落到具体读数上**
			#   (`walk` 真的返回了某一档的格,且那条链是通的)—— 报覆盖时**不计入**。
			var wc: Vector2i = walk["cell"]
			_check(int(own.get(wc, 0)) != 1,
					"[读数·构造保证] 负例落点 %s(连通区 %d)—— 不含孤立单格由 ④ 已保证,这条只作读数"
					% [str(wc), int(own.get(wc, 0))])

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


# 找一个"把首档筛空、而后面至少还有一档有货"的布局 —— 用来**端到端**驱动负例。
# 先扫规则网格(实测能把首档筛空的是**稠密网格**布局:随机撒点到不了 —— 随机撒点到不了
# 是因为首档那 122 格散在十来个区里,8 个敌人盖不满),再随机兜底。
# 返回 {"layout": Array(空 = 没找到), "count": 搜过几个, "found": 命中几个}。
func _find_blanking_layout(pools: Array, cols: int, rows: int) -> Dictionary:
	var cands: Array = []
	for spacing in range(3, 21):
		for phase in [0, 1]:
			var e: Array = []
			for y in range(phase, rows, spacing):
				for x in range(phase, cols, spacing):
					e.append(Vector2i(x, y))
			if e.size() >= 4:
				cands.append(e)
	for k in [8, 16, 24]:
		for t in range(NEG_SEARCH_TRIALS / 3):
			seed(90210 + t * 13 + k)
			var e: Array = []
			for i in range(k):
				e.append(Vector2i(randi() % cols, randi() % rows))
			cands.append(e)
	var found := 0
	var hit: Array = []
	for e in cands:
		if _has_usable(pools[0], e, cols, rows, RESPAWN_CLEARANCE):
			continue
		found += 1
		var later := false
		for i in range(1, pools.size()):
			if _has_usable(pools[i], e, cols, rows, RESPAWN_CLEARANCE):
				later = true
				break
		if later:
			hit = e
			break
	return {"layout": hit, "count": cands.size(), "found": found}


# 端到端重放调用方的循环:**逐档放宽**,返回第一个满足"离每个敌人都 ≥ clear 格"的格与该档序号。
# 全空 → {"cell": (-1,-1), "tier": -1}(= 生产里那个哨兵值,消费端会把人摆到地图回卷角落)。
func _walk(pools: Array, enemies: Array, cols: int, rows: int, clear: int) -> Dictionary:
	for i in range(pools.size()):
		var cells: Array = (pools[i] as Array).duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for e in enemies:
				if GridPathfinder.toroidal_dist(c, e, cols, rows) < clear:
					ok = false
					break
			if ok:
				return {"cell": c, "tier": i}
	return {"cell": Vector2i(-1, -1), "tier": -1}


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
	# ★★ 三条 case 里那条 `_respawn_pools` 是**评审抓到的差一跳**:royale 的池来源是
	#   `_spawn_cell` → `_respawn_pools()`(转发)。只钉 `_spawn_cell` 的话,把
	#   `_respawn_pools` 那一行改回 `SpawnPicker.floor_cells()` ⇒ **病原样复活、61 条断言全绿**
	#   (⑥ 存在的全部理由就是堵这个,却在它自己点名的位置上留了一跳;team 侧是直接命中、没这跳)。
	#   `ScanUtil.func_body(code, "_respawn_pools")` 取的是 `static func _respawn_pools(` 那个体,
	#   不会被 `func _spawn_cell(` 误命中。
	var cases := [
		{"file": "res://server/hosts/royale_host.gd", "fn": "_spawn_cell", "want": "_respawn_pools()"},
		{"file": "res://server/hosts/team_host.gd", "fn": "_respawn_cell_for", "want": "respawn_pools()"},
	]
	# ★ `_respawn_pools` 那一条**不能用 `ScanUtil.func_body`**:它按 `"\nfunc "` 找边界,
	#   而**不认 `static func`** ⇒ 一个 `static func` 的"函数体"会把**后面所有 static func**
	#   一起吞进来(`_respawn_pools` 之后就是 `plan_spawns`,那里面有一处**合法**的 `_floor_cells()`
	#   ⇒ 反向断言会假红)。故这一条走**定长窗口**(该转发函数只有两行,窗口给足 300 字符)。
	#   (tool 的这条限制**没有改** —— 改它会连带收紧别的探针的读数,不在本次范围。)
	var rh_src := ScanUtil.code_only(ScanUtil.read("res://server/hosts/royale_host.gd"))
	var fi := rh_src.find("static func _respawn_pools(")
	var fwin := rh_src.substr(fi, 300) if fi >= 0 else ""
	_check(not fwin.is_empty(),
			"[仪器] 取到 `static func _respawn_pools(`(找不到 = 下面两条恒真)")
	_check(fwin.contains("SpawnPicker.respawn_pools()"),
			"★ royale 的**转发函数** `_respawn_pools` 自己就是走 `SpawnPicker.respawn_pools()`"
			+ "(只钉 `_spawn_cell` 会漏:把这一行改回拼 `SpawnPicker.floor_cells()` ⇒ 病原样复活)")
	_check(not fwin.contains("floor_cells()"),
			"★ 该转发函数体里**不得**出现 `floor_cells()`(写回去 = 兜底又退化成全量)")
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
	# ⑦ 的守卫**不能悬空**:它断言的是"`plan_spawns` 的补足分支走不到",而那条分支就在
	# `RoyaleHost.plan_spawns` 里 —— 分支被删了的话那条守卫就恒真了(恒绿形状)。故钉它在位。
	var ps_body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/hosts/royale_host.gd")), "plan_spawns")
	_check(not ps_body.is_empty(),
			"[仪器] 取到 `RoyaleHost.plan_spawns` 函数体(%d 字符;空 = 下面那条恒真)" % ps_body.length())
	_check(ps_body.contains("picked.size() < n") and ps_body.contains("_floor_cells()"),
			"★ ⑦ 守的那条**补足分支**确实还在 `plan_spawns` 里(它被删 = ⑦ 那条成了空断言;"
			+ "它仍在 = ⑦ 的'不可达'读数是关于真代码的)")

	# 探针自己的 `RESPAWN_CLEARANCE` 必须与**每个**宿主同值(不同值 → ⑤ 的正/负例验的是另一条路)。
	# ★ 逐文件各查一次:上一版扫的是**两文件拼接串**(`both.contains(...)`),于是**任一**文件有它
	#   就绿,而措辞写的是"两个宿主与探针同值" —— 断言名与覆盖面不符(评审 重要 2)。
	for f in ["res://server/hosts/royale_host.gd", "res://server/hosts/team_host.gd"]:
		var fsrc := ScanUtil.read(f)
		_check(not fsrc.is_empty(), "[仪器] 读得到 %s(读不到 = 下面那条恒真)" % f)
		_check(fsrc.contains("const RESPAWN_CLEARANCE := %d" % RESPAWN_CLEARANCE),
				"★ %s 的 RESPAWN_CLEARANCE 与探针同值(= %d;漂了的话 ⑤ 的正/负例就不是生产那条路)"
				% [f, RESPAWN_CLEARANCE])


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
