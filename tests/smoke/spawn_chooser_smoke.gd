extends SceneTree

# 出生点「地图数据 → 随机选点」守卫(SpawnChooser + MapFormat 的 `# spawn` / `# teamspawn` 解析)。
# 存在理由:① 解析错一位 ⇒ 选点器拿到不存在的格/重复格;非法坐标用宽松 int() 会静默变 (0,0)。
#   ② 选点必须真随机、必须排除"上一次位置"、尽量守最小间距,候选不足时不崩也不回 (-1,-1)。
#   ③ 1v1 要能从地图列表抽到互不相同且 ≥ SpawnPicker.FAR_CELLS 的一对。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/spawn_chooser_smoke.gd;通过 = "SPAWN CHOOSER OK(n 条断言)"。
# 测不到什么:宿主接线(_duel_spawns / _last_spawn、match_start 与摆位同源)与真实地图数据质量在 tests/probe/map_spawn_data_probe。

const EXPECTED_CHECKS := 15
const FAR := 15   # SpawnPicker.FAR_CELLS 的当前值(1v1 两人最小环面距离)

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# 空载守卫:核心脚本缺失时立刻退出(否则抛错后走不到 quit(),进程永久挂起)。
	if load("res://core/sim/spawn_chooser.gd") == null or load("res://core/sim/map_format.gd") == null:
		print("SPAWN CHOOSER SMOKE: 载入失败(核心脚本缺失)")
		quit(1)
		return
	_parse_checks()
	_chooser_checks()
	_finish()


func _parse_checks() -> void:
	var meta := [
		"# 普通注释",
		"# player 3 4",
		"# player2 5 6",
		"# enemy flybird 7 8",
		"# spawn 10 20",
		"# spawn 12 20",
		"# spawn 10 20",          # 重复行:只留第一次
		"# spawn -1 5",           # 负数:非法
		"# spawn abc 5",          # 非数字:非法(宽松 int() 会静默变 (0,0))
		"# spawn 9",              # 缺列:非法
		"# teamspawn 1 30 40",
		"# teamspawn 1 30 40",    # 重复行
		"# teamspawn 2 90 40",
		"# teamspawn 3 50 50",    # 队号非法
		"# teamspawn 1 bad 1",    # 坐标非法
	]
	var p := MapFormat.parse_spawn_metadata(meta)
	# 去掉什么才红:删掉 player/player2 分支或改成只认新语法 ⇒ 本条红。
	_chk(p.get("player") == Vector2i(3, 4) and p.get("player2") == Vector2i(5, 6),
			"① 旧键 # player / # player2 仍被解析(向后兼容)")
	# 去掉什么才红:删掉 enemy 分支 ⇒ 本条红。
	var enemies: Array = p.get("enemies", [])
	_chk(enemies.size() == 1 and enemies[0]["type"] == "flybird"
			and enemies[0]["cell"] == Vector2i(7, 8),
			"② 旧键 # enemy 仍被解析")
	# 去掉什么才红:spawn 分支的 seen_spawn 去重删掉 ⇒ 出现 3 个(含重复);或忽略非法行时不用 is_valid_int ⇒ (0,0) 混入。
	_chk(p.get("spawns", []) == [Vector2i(10, 20), Vector2i(12, 20)],
			"③ # spawn 多行保序、重复去重、非法坐标(-1 / abc / 缺列)全忽略")
	# 去掉什么才红:teamspawn 不分流(全塞一个列表)或队号不校验 ⇒ 本条红。
	var teams: Dictionary = p.get("teamspawns", {})
	_chk(teams.get(1, []) == [Vector2i(30, 40)] and teams.get(2, []) == [Vector2i(90, 40)],
			"④ # teamspawn 按队号分流、重复去重、队号 3 与非法坐标被忽略")
	# 去掉什么才红:老图(只有 # player)被塞了空的 spawns/teamspawns 键 ⇒ 下游 is_empty 判据被绕开(回退路径不触发)。
	var legacy := MapFormat.parse_spawn_metadata(["# player 1 2"])
	_chk(legacy.get("player") == Vector2i(1, 2) and not legacy.has("spawns")
			and not legacy.has("teamspawns"),
			"⑤ 老地图(无新行)不新增空列表键 ⇒ 回退路径判据 is_empty 仍然成立")


func _chooser_checks() -> void:
	var rng := RandomNumberGenerator.new()
	# ⑥ 排除"上一次位置":候选 5 格,上一次 = (0,0);400 次抽样都不能再落在它上面。
	var five: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)]
	rng.seed = 20261101
	var hit_excluded := 0
	var seen := {}
	for i in 400:
		var c := SpawnChooser.pick(five, [Vector2i(0, 0)], rng)
		if c == Vector2i(0, 0):
			hit_excluded += 1
		var c2 := SpawnChooser.pick(five, [], rng)
		seen[c2] = true
	# 去掉什么才红:pick() 里 `exclude.has(c)` 那道过滤删掉 ⇒ 本条红。
	_chk(hit_excluded == 0, "⑥ 排除上一次:400 抽都不落在 exclude 里(实中 %d)" % hit_excluded)
	# ⑦ 随机覆盖:同一批抽样必须能落到全部 5 个格(固定 seed 的确定性断言,不是概率容忍)。
	# 去掉什么才红:pick() 改成恒返回 candidates[0](或去掉 _sample 的随机)⇒ 本条红。
	_chk(seen.size() == 5, "⑦ 随机:400 抽覆盖全部 5 个候选(实测 %d)" % seen.size())
	# ⑧ 最小间距可行时必须满足:(0,0) 是 anchors,只有 (25,0) 离它 ≥ 10。
	var dist_pick := SpawnChooser.pick(
			[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(25, 0)],
			[], rng, 10, [Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:pick() 里 min_dist/anchor 过滤整段删掉 ⇒ 可能返回 (1,0)/(2,0)。
	_chk(dist_pick == Vector2i(25, 0), "⑧ 最小间距可行时只从够远的格里选(实得 %s)" % str(dist_pick))
	# ⑨ 最小间距不可行(所有候选都太近)⇒ 逐级放宽后仍要给出候选,不能回 (-1,-1)。
	var relaxed := SpawnChooser.pick([Vector2i(1, 0), Vector2i(2, 0)], [], rng, 999,
			[Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:删掉"逐级 -RELAX_STEP 放宽"的循环 ⇒ 本条红(返回 (-1,-1))。
	_chk(relaxed.x >= 0 and [Vector2i(1, 0), Vector2i(2, 0)].has(relaxed),
			"⑨ 点不够远时放宽而不是放弃(实得 %s)" % str(relaxed))
	# ⑩ 退化优先级:候选全被 exclude、另一个是 anchors 格 ⇒ 宁可选被排除的格,也不与对手同格。
	var forced := SpawnChooser.pick([Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(1, 0)],
			rng, 0, [Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:把"排除让位"那层退化成"连 anchors 一起放"⇒ 本条红(返回 (0,0),两人同格)。
	_chk(forced == Vector2i(1, 0), "⑩ 候选被排除光时选被排除格、绝不同格(实得 %s)" % str(forced))
	# ⑪ 空候选:消费端约定 (-1,-1)(宿主自己回退地图/旧逻辑)。
	_chk(SpawnChooser.pick([], [], rng) == Vector2i(-1, -1), "⑪ 空候选返回 (-1,-1)")
	# ⑫ 单候选 + 恰好被排除:仍返回它(不崩、不甩墙角)。
	_chk(SpawnChooser.pick([Vector2i(7, 7)], [Vector2i(7, 7)], rng) == Vector2i(7, 7),
			"⑫ 单候选被排除时退化返回该格")
	# ⑬ pick_many:互不相同 + 两两 ≥ min_dist(6 个格间距 10,dims 40×40)。
	var grid_pts: Array = [Vector2i(0, 0), Vector2i(0, 10), Vector2i(0, 20),
			Vector2i(10, 0), Vector2i(10, 10), Vector2i(10, 20)]
	rng.seed = 424242
	var many := SpawnChooser.pick_many(grid_pts, 6, rng, 5, Vector2i(40, 40))
	var distinct_ok := true
	var spacing_ok := true
	for i in range(many.size()):
		for j in range(i + 1, many.size()):
			if many[i] == many[j]:
				distinct_ok = false
			if GridPathfinder.toroidal_dist(many[i], many[j], 40, 40) < 5:
				spacing_ok = false
	# 去掉什么才红:pick_many 不把已选格并进 exclude/anchors ⇒ 出现重复格或间距不达标。
	_chk(many.size() == 6 and distinct_ok and spacing_ok,
			"⑬ pick_many 出 6 个互不相同且两两 ≥5 的格(实测 %d)" % many.size())
	# ⑭ 候选不足:3 个格要 5 个 ⇒ 返回 3 个(不凭空造格、不崩);调用方据此回退其它来源。
	var few := SpawnChooser.pick_many([Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], 5, rng)
	# 去掉什么才红:pick_many 的循环不判 `c.x < 0` ⇒ 死循环 / 把 (-1,-1) 当格子塞进去。
	_chk(few.size() == 3 and not few.has(Vector2i(-1, -1)),
			"⑭ pick_many 候选不足时返回全部可用的(实测 %d)" % few.size())
	# ⑮ 1v1 数据抽样:用 newfactory 的 10 个 # spawn 点(写死在下面,与地图数据同形),32 个种子抽两人都必须 ≥ FAR。
	var map_pts: Array = [Vector2i(52, 90), Vector2i(55, 90), Vector2i(58, 90), Vector2i(62, 90),
			Vector2i(66, 90), Vector2i(83, 90), Vector2i(86, 90), Vector2i(90, 90),
			Vector2i(93, 90), Vector2i(97, 90)]
	var pair_bad := 0
	for s in 32:
		rng.seed = 7000 + s
		var pair := SpawnChooser.pick_many(map_pts, 2, rng, FAR, Vector2i(150, 100))
		if pair.size() < 2 or GridPathfinder.toroidal_dist(pair[0], pair[1], 150, 100) < FAR:
			pair_bad += 1
	# 去掉什么才红:pick_many 把 min_dist 写死成 0 / 地图数据点挤成一簇 ⇒ 本条红。
	_chk(pair_bad == 0, "⑮ 1v1 抽样:32/32 轮两人相距 ≥%d(实得 %d/%d)" % [FAR, 32 - pair_bad, 32])


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("SPAWN CHOOSER OK(%d 条断言):meta 解析 · 排除上一次 · 随机覆盖 · 间距/放宽 · 退化 · 1v1 抽样" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("SPAWN CHOOSER FAILED: %d 处" % _fails.size())
		quit(1)
