extends SceneTree

# 出生点与复活点选取算法冒烟测试：
# 验证 SpawnPicker 在多地图下的主连通区分辨率，保证所有生成的候选出生点与复活点均位于可用空间。
# 运行方式：
#   timeout 120 "$GODOT" --headless --path . -s res://tests/smoke/spawn_pool_smoke.gd

const MAP_NORMAL := "res://maps/demo.cyrm"         # 正常图:最大连通区 35 ≥ OPEN_AREA_MIN

# 调用方那段"离敌人够远"筛选的清空距离(格)。= 两个宿主的 `RESPAWN_CLEARANCE`
# (royale_host.gd / team_host.gd 各一个,值都是 8)—— 本探针只重放那段平凡筛选的形状,
# 故这个数必须与生产同值。-  它由 ⑥ 的源码级断言负责校验(两个文件里都得写 `:= 8`),
# 以免本探针的假设与生产悄悄漂开(那时 ⑤ 的正/负例验的就不是生产那条路了)。
const RESPAWN_CLEARANCE := 8

# ⑤ 里搜"首档空 ∧ 兜底保护档有货"的布局次数(固定种子)。真找到过 = 负例可端到端驱动 -> 那条断言红。
const NEG_SEARCH_TRIALS := 800

# 一局最多几个人(大乱斗 `--roles 1..8`;3v3 是 6)。只用于 ⑦ 那条补足分支可达性防御性校验:
# 补足分支可达 ⟺ 干净池 < 人数,故用上界来判断"今天一定不可达"。
# 注意事项：2026-10-02 降精度:这个上界从生产读(`LobbyRooms.ROYALE_MAX_PLAYERS`,经
#   `_production_max_players()`),不再在探针里写死 8 —— 生产把上限调了而这里还是 8 的话,
#   "不可达"这个结论会静默失真(而它正是这条防御性校验的全部意义)。

var _fail := 0
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  ok   %s" % msg)
	else:
		_fail += 1
		print("  FAIL %s" % msg)


# 生产的人数上限 = `LobbyRooms.ROYALE_MAX_PLAYERS`(大乱斗每房人数的钳位上界;AI 补位也按它取号)。
# - 用源码文本读,不 `load()`:`-s` 阶段 autoload 未注册,load 会连带编译引用了 NetBus 的
#   lobby_rooms.gd —— 那样连本脚本的 `_initialize` 都进不去(见文件头 / team_room_smoke 相同处理逻辑说明)。
# 返回 -1 = 读不到 / 解析失败(调用方必须报红,别把它当 0 用)。
func _production_max_players() -> int:
	var src := ScanUtil.read("res://server/lobby/lobby_rooms.gd")
	if src.is_empty():
		return -1
	var re := RegEx.create_from_string("const\\s+ROYALE_MAX_PLAYERS\\s*:?=\\s*([0-9]+)")
	var m := re.search(ScanUtil.code_only(src))
	return int(m.get_string(1)) if m != null else -1


func _initialize() -> void:
	# ── 空载防御性校验 ──
	for path in [MAP_NORMAL]:
		if not FileAccess.file_exists(path):
			print("SPAWN POOL SMOKE: FAIL(找不到地图 %s)" % path)
			quit(1)
			return
	# - 判定条件走 `SpawnPicker` 的全局类名(静态依赖即可):它的依赖链
	#   (MazeGenerator -> MapFormat / GridPathfinder / TileDefs)一个 autoload 都不碰,
	#   故 `-s` 下编得过(与 `LobbyRooms` 那条链不同,后者静态引用会把 NetBus 拖进来)。
	#   空载防御性校验仍要有:类缓存没刷出来时引用处会编译失败。
	var sp = SpawnPicker
	if sp == null:
		print("SPAWN POOL SMOKE: FAIL(读不到 SpawnPicker)")
		quit(1)
		return

	_run_map(MAP_NORMAL)
	_check_wiring()

	if _fail == 0:
		print("SPAWN POOL SMOKE: ALL-OK(%d 条断言)" % _checks)
		quit(0)
	else:
		print("SPAWN POOL SMOKE: FAIL(%d 条不符)" % _fail)
		quit(1)


# 载图 -> 复算连通区 -> 与 `spawn_candidates()` 对账。
# - 只跑"正常图"这一支了(自适应的那一支已随旧 PvP 图一起休眠,见文件头 MAP_NORMAL 上方)。
func _run_map(path: String) -> void:
	print("")
	print("═══ %s(期望走绝对阈值分支)═══" % path)
	MazeGenerator.set_map_file(path)
	var grid: Array = MazeGenerator.load_map_file()
	if grid.is_empty():
		_check(false, "地图加载成功(空网格 = 后面全无意义)")
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	SpawnPicker.reset_cache()     # - 每进程缓存:换图不重置会静默沿用上一张图的池子
	# - 播种:`_pick` / `_walk` 内部 `shuffle()` 读全局 RNG —— 不播的话输出里那些
	#   "选到 (61, 90)"的读数跨跑不可复现(断言本身不看具体格,但读数就失去了证据价值)。
	#   搜索段自己会 `seed(...)`,完整测试运行仍是确定性的。
	seed(20260919)

	# ── [仪器] A `TileDefs` 真加载了 ──
	# 纹理 11 = 梯子(type=passage)。未加载 defs 时缺省是 wall  ->  梯子被当墙  ->  池子与生产
	# 悄悄不同(而且本探针照样能全部断言通过)。故先严格校验"加载生效"。
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

	# ── [仪器] B 独立 BFS 与生产的连通区定义一致(只作核对,不作判定条件来源)──
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
	# 这是断言区分度的前提：地图最大连通区必须满足 ≥ OPEN_AREA_MIN，否则后续“门槛恰好是 OPEN_AREA_MIN”
	# 断言将退化为恒真断言（而这正是自适应分支预期接管的场景）。
	var thr := SpawnPicker.area_threshold()
	_check(mx >= SpawnPicker.OPEN_AREA_MIN,
			"[仪器] 本图最大连通区 %d ≥ OPEN_AREA_MIN %d" % [mx, SpawnPicker.OPEN_AREA_MIN])
	_check(thr == SpawnPicker.OPEN_AREA_MIN,
			"★ 正常图门槛**恰好**是 OPEN_AREA_MIN(自适应一行不生效;实际 %d)" % thr)

	# ── 期望集合(判定条件来自独立 BFS + `area_threshold()` 的契约)──
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

	# ── ② 反向下界:池子必须是全部地板格的真子集 ──
	# 这条就是变异探针:把 `spawn_candidates()` 的末档写回 `_prefer_cache = floor`
	# (或把 `area_threshold()` 改回恒 `OPEN_AREA_MIN`),池子当场变成全部地板格 -> 红。
	# - 只写"池子 ⊆ 期望"是不够的:全部地板格在 `thr == 1` 时也满足它。
	var excluded := floor.size() - pool.size()
	_check(pool.size() < floor.size() and excluded > 0,
			"★ 池子是全部地板格的真子集(池 %d < 地板 %d;排除了 %d 格)"
			% [pool.size(), floor.size(), excluded])
	_check(pool.size() >= mini(SpawnPicker.PREFER_MIN, expected.size()),
			"池子不小于 PREFER_MIN(否则说明档位回退到了更宽的一档:池 %d,期望集合 %d)"
			% [pool.size(), expected.size()])

	# ── ④ 复活/复位:池序列每一档都不许含孤立单格(同一条病,后两个档位原先就是全部地板格)──
	# 调用方(`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for`)现在读同一份池序列
	# `SpawnPicker.respawn_pools()`;这里就把那份序列整个检查一遍 —— 这就是"每条路都不含孤立格"。
	# - 2026-09-19 起对所有图生效(设计约定:"明知在船上的 bug"不许按动作范围放过),
	#   故本段不再按 `want_adaptive` 分叉:两图跑同一套断言。
	var pools: Array = SpawnPicker.respawn_pools()
	_check(pools.size() == 3, "复活池序列是三档(优选 → 兜底 → 末档;实际 %d 档)" % pools.size())
	if pools.size() == 3:
		# 末档 = 全部地板格去掉孤立单格(它的存在理由:兜底保护档比原样窄一个量级,筛空即 (-1,-1)
		#  ->  摆到地图回卷角落,比"在小间里复活"更糟 —— 见 respawn_fallback 的 注意：)
		var want_last: Array = []
		for c in floor:
			if int(own[c]) >= 2:
				want_last.append(c)
		_check(_same_set(pools[0], pool), "首档就是 `spawn_candidates()` 那一份(不是另抄一遍)")
		_check(_same_set(pools[1], expected.keys()),
				"★ 第 ② 档逐格 == 「连通区 ≥ 门槛 %d」(%d 格)" % [thr, (pools[1] as Array).size()])
		_check(_same_set(pools[2], want_last),
				"★ 第 ③ 档逐格 == 「全部地板格去掉孤立单格」(%d 格)" % (pools[2] as Array).size())
		# 序列按池子大小单调不减("兜底保护"的语义:放宽,不是换一个更窄的集合)
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
		# 前两个档位还要更强:不含任何"连通区 < 门槛"的格(第 ③ 档只保证 ≥2,那是有意的下限)
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

		# ⑦ 补足分支的可达性防御性校验(评审 Minor 2:姐妹分支 = `RoyaleHost.plan_spawns` 的
		# `if picked.size() < n` -> `_floor_cells()`)。-  它仍是全量地板格(同病),但今天不可达:
		# `spread_cells` 恒返回 `min(n, 池大小)` —— -  那条不变量不在本文件,它钉在
		# `tests/smoke/enemy_logic_smoke.gd` 的 `_phase_spread_cells`(「count 超过池子应返回全部」)。
		# 本文件从不调用 `spread_cells`(只调 `SpawnPicker`),故这里只引用它当前提。
		# 于是:补足分支可达 ⟺ 干净池 < 人数。实测池 122(factory1v1)/ 59(demo),人数上限 8  ->  不可达。
		# - 为什么不随意将它也收窄:那个分支恰在"池子极小时"才可达,收窄会让补足补不满  -> 
		#   `out[role] = (-1,-1)`  ->  摆到地图回卷角落 —— 按用户已裁定的偏好((-1,-1) 更糟),
		#   这个分支保持原样才是对的。故这里钉"不可达",而不是改它:哪天这条红,说明池缩到了
		#   人数以下、那个取舍真的来了,该由人来裁(而不是被静默地改掉)。
		# 人数上限从生产读(不再用探针自己的字面量 8);读不到就报红,别让结论无效操作。
		var cap := _production_max_players()
		if cap <= 0:
			_check(false, "★ 读不到生产的人数上限(server/lobby/lobby_rooms.gd 的 ROYALE_MAX_PLAYERS)—— 补足分支可达性断言无从成立")
		else:
			_check(pools[0].size() >= cap,
					("★ 补足分支仍**不可达**:干净池 %d ≥ 人数上限 %d ⇒ `plan_spawns` 里那条 "
					+ "`_floor_cells()` 补足走不到(它一旦可达,孤立单格会被放回开局散点;而收窄它会把 "
					+ "(-1,-1) 放进来 —— 那个取舍要人来裁)") % [(pools[0] as Array).size(), cap])

		# ── ⑤ 各条路各走一遍(正/负)—— 端到端跑调用方那段循环 ──
		# - 池子序列取自生产(`respawn_pools()`);`_walk` 重放的是两个宿主共有的那段
		#   平凡的距离筛选 + 逐档放宽(royale 判所有存活玩家、3v3 判存活敌人)。
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
		# 负例:找一个"首档被筛空"的真布局,然后端到端跑完整个 `respawn_pools()` 循环 ——
		# 断言它确实落到了更后面的档、且那一档带出来的格不含孤立单格。
		# (搜索:先扫规则网格(实测能筛空首档的是稠密的网格布局,随机撒点到不了),再随机兜底保护。)
		var search := _find_blanking_layout(pools, cols, rows)
		var searched: int = int(search["count"])
		var blanking: Array = search["layout"]
		_check(searched > 0, "[仪器] 负例搜索真的跑了(%d 个布局;0 = 下面的结论没有覆盖)" % searched)
		print("  [info] 负例搜索:%d 个布局里「首档筛空」的有 %d 个%s"
				% [searched, int(search["found"]),
					" ⇒ 用真布局端到端驱动" if not blanking.is_empty() else " ⇒ 本图构造不出来,改从第 ② 档起跑"])
		if blanking.is_empty():
			# 搜不到(本图几何不允许:能筛空首档的布局必然把后面几档一起筛空) -> 从第 ② 档起跑,
			# 那正是调用方在首档筛选落空后执行到的分支逻辑。本断言并非形式化的冗余检查:
			# 它带的是"第 ② 档自己也不含孤立单格"这个实质断言;而"搜不到"是个读数(上面那行)。
			# (上一版把它写成 `_check(found == 0)` —— 在那个分支里始终为 true,已按本仓纪律摘掉。)
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
			# - 2026-10-02 按"说不出真实变异就删"删掉了原先那条 `_check(own[wc] != 1, …)`:
			#   它由构造保证(④ 已钉"每档都不含孤立单格"),代码自己的注释也写着"不是区分度断言"。
			#   留下的 `walk` 调用仍要:它证明端到端那条链是通的(下一行的 `tier` 断言要用)。

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


# 找一个"把首档筛空、而后面至少还有一档有货"的布局 —— 用来端到端驱动负例。
# 先扫规则网格(实测能把首档筛空的是稠密网格布局:随机撒点到不了 —— 随机撒点到不了
# 是因为首档那 122 格散在十来个区里,8 个敌人盖不满),再随机兜底保护。
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


# 端到端重放调用方的循环:逐档放宽,返回第一个满足"离每个敌人都 ≥ clear 格"的格与该档序号。
# 全空 -> {"cell": (-1,-1), "tier": -1}(= 生产里那个哨兵值,消费端会把人摆到地图回卷角落)。
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


# 该池子里有没有满足"离每个敌人都 ≥ clear 格"的格(找到即返回 —— 搜索里跑几千次,要提前返回)。
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


# ── ⑥ 源码级:两个宿主的复活选格真的接了这条池序列 ──
# 核心设计的关键考量:池序列收在 `SpawnPicker` 里,但"接上没接上"是两处调用点的事 ——
# 只测 `SpawnPicker` 的话,宿主里那句 `[_spawn_candidates(), _floor_cells()]` 原样留着也照样全部断言通过
# (那正是本次修的那个病:两处各抄一遍、一起退化成全量)。故按函数体扫,不是按整文件
# (`royale_host.gd` 的 `plan_spawns` 里另有一处合法的 `_floor_cells()` 用途)。
func _check_wiring() -> void:
	print("")
	print("═══ ⑥ 宿主接线(源码级)═══")
	# 注意事项：三条 case 里那条 `_respawn_pools` 是评审抓到的单步时序偏差:royale 的池来源是
	#   `_spawn_cell` -> `_respawn_pools()`(转发)。只钉 `_spawn_cell` 的话,把
	#   `_respawn_pools` 那一行改回 `SpawnPicker.floor_cells()`  ->  病原样复活、61 条断言全部断言通过
	#   (⑥ 存在的全部理由就是堵这个,却在它自己明确提示的位置上留了一跳;team 侧是直接命中、没这跳)。
	#   `ScanUtil.func_body(code, "_respawn_pools")` 取的是 `static func _respawn_pools(` 那个体,
	#   不会被 `func _spawn_cell(` 误命中。
	var cases := [
		{"file": "res://server/hosts/royale_host.gd", "fn": "_spawn_cell", "want": "_respawn_pools()"},
		{"file": "res://server/hosts/team_host.gd", "fn": "_respawn_cell_for", "want": "respawn_pools()"},
	]
	# - `_respawn_pools` 那一条不能用 `ScanUtil.func_body`:它按 `"\nfunc "` 找边界,
	#   而不认 `static func`  ->  一个 `static func` 的"函数体"会把后面所有 static func
	#   一起吞进来(`_respawn_pools` 之后就是 `plan_spawns`,那里面有一处合法的 `_floor_cells()`
	#    ->  反向断言可能发生误报）。因此此处截取定长字符窗口（转发函数仅两行，设置 300 字符足够完整覆盖函数体）。
	#   (tool 的这条限制没有改 —— 改它会连带收紧别的探针的读数,不在本次范围。)
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
		# 反向:函数体里不得再出现第二档的地板格来源(留着它 = 本修复形同没接)
		var dirty := body.contains("_floor_cells()") or body.contains("SpawnPicker.floor_cells()")
		_check(not dirty,
				"★ %s 的 `%s` **不再**自己拼兜底档(把 `floor_cells()` 写回这个函数体 = 池子又退化成全量)"
				% [cs["file"], cs["fn"]])
	# ⑦ 的防御性校验不能悬空:它断言的是"`plan_spawns` 的补足分支走不到",而那条分支就在
	# `RoyaleHost.plan_spawns` 里 —— 分支若被移除则防御校验将退化为恒真判断（假阳性漏洞）。故需严格校验接口调用与生效状态。
	var ps_body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/hosts/royale_host.gd")), "plan_spawns")
	_check(not ps_body.is_empty(),
			"[仪器] 取到 `RoyaleHost.plan_spawns` 函数体(%d 字符;空 = 下面那条恒真)" % ps_body.length())
	_check(ps_body.contains("picked.size() < n") and ps_body.contains("_floor_cells()"),
			"★ ⑦ 守的那条**补足分支**确实还在 `plan_spawns` 里(它被删 = ⑦ 那条成了空断言;"
			+ "它仍在 = ⑦ 的'不可达'读数是关于真代码的)")

	# 探针自己的 `RESPAWN_CLEARANCE` 必须与每个宿主同值(不同值 -> ⑤ 的正/负例验的是另一条路)。
	# - 逐文件各查一次:上一版扫的是两文件拼接串(`both.contains(...)`),于是任一文件有它
	#   就绿,而措辞写的是"两个宿主与探针同值" —— 断言名与覆盖面不符(评审 重要 2)。
	for f in ["res://server/hosts/royale_host.gd", "res://server/hosts/team_host.gd"]:
		var fsrc := ScanUtil.read(f)
		_check(not fsrc.is_empty(), "[仪器] 读得到 %s(读不到 = 下面那条恒真)" % f)
		_check(fsrc.contains("const RESPAWN_CLEARANCE := %d" % RESPAWN_CLEARANCE),
				"★ %s 的 RESPAWN_CLEARANCE 与探针同值(= %d;漂了的话 ⑤ 的正/负例就不是生产那条路)"
				% [f, RESPAWN_CLEARANCE])


# 独立的 4 邻接环面 BFS(与生产同语义,但独立写一遍 —— 探针的判定条件不取自被测实现)。
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
