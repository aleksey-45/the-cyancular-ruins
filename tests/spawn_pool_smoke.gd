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
