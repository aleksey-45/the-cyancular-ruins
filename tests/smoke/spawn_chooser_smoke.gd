extends SceneTree

# 出生/复活点「按阵营半区的地图数据 → 随机选点」守卫(SpawnChooser + MapFormat 的 `# respawn <1|2>` 解析)。
# 存在理由:① 解析错一位 ⇒ 选点器拿到不存在的格/重复格;非法坐标用宽松 int() 会静默变 (0,0)。
#   ② 侧判定错 ⇒ 1v1/对抗的人会出生到对面半区(用户明确要求"各占半区");桶划分错 ⇒ "均匀散布"校验形同虚设。
#   ③ 选点必须真随机、必须排除"上一次位置"、尽量守最小间距,候选不足时不崩也不回 (-1,-1)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/spawn_chooser_smoke.gd;通过 = "SPAWN CHOOSER OK(n 条断言)"。
# 测不到什么:宿主接线(1v1/对抗各自取侧、复活同侧、换边互换)与真实地图数据质量在 tests/probe/map_spawn_data_probe。

const EXPECTED_CHECKS := 19
const FAR := 15   # SpawnPicker.FAR_CELLS 的当前值(1v1 两人最小环面距离;软约束)

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
	_side_checks()
	_chooser_checks()
	_finish()


func _parse_checks() -> void:
	var meta := [
		"# 普通注释",
		"# player 3 4",
		"# player2 5 6",
		"# enemy flybird 7 8",
		"# respawn 1 10 20",
		"# respawn 2 90 20",
		"# respawn 1 12 20",
		"# respawn 1 10 20",       # 同侧重复行:只留第一次
		"# respawn 1 -1 5",        # 负数:非法
		"# respawn 1 abc 5",       # 非数字:非法(宽松 int() 会静默变 (0,0))
		"# respawn 2 9",           # 缺列:非法
		"# respawn 3 50 50",       # 侧号非法
		"# respawn 2 90 20",       # 同侧重复(第二次出现)
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
	# 去掉什么才红:respawn 不分流(全塞一个列表)或过去重 ⇒ 本条红(侧 1 会出现重复的 (10,20))。
	var sides: Dictionary = p.get("respawns", {})
	_chk(sides.get(1, []) == [Vector2i(10, 20), Vector2i(12, 20)]
			and sides.get(2, []) == [Vector2i(90, 20)],
			"③ # respawn 按侧分流、保序、同侧重复去重")
	# 去掉什么才红:不校验侧号 1/2 / 坐标用宽松 int() ⇒ 侧 3 或 (0,0) 混进列表 ⇒ 本条红。
	_chk(sides.get(1, []).size() == 2 and sides.get(2, []).size() == 1
			and not sides.has(3),
			"④ 非法 respawn 行(侧 3 / 负数 / abc / 缺列)全部忽略")
	# 去掉什么才红:老图(只有 # player)被塞了空的 respawns 键 ⇒ 下游 is_empty 判据被绕开(回退路径不触发)。
	var legacy := MapFormat.parse_spawn_metadata(["# player 1 2"])
	_chk(legacy.get("player") == Vector2i(1, 2) and not legacy.has("respawns"),
			"⑤ 老地图(无新行)不新增空列表键 ⇒ 回退路径判据仍然成立")


func _side_checks() -> void:
	var dims := Vector2i(12, 6)
	# ⑥ 侧判定:侧 1 = 左半 x<cols/2、侧 2 = 右半。去掉什么才红:side_of 的边界写成 <= 或换成 y 轴 ⇒ 本条红。
	_chk(SpawnChooser.side_of(Vector2i(0, 0), dims) == 1
			and SpawnChooser.side_of(Vector2i(5, 5), dims) == 1
			and SpawnChooser.side_of(Vector2i(6, 0), dims) == 2
			and SpawnChooser.side_of(Vector2i(11, 5), dims) == 2
			and SpawnChooser.side_offset(1, dims) == 0
			and SpawnChooser.side_offset(2, dims) == 6,
			"⑥ 侧 = 左右半区(侧 1 x<cols/2 / 侧 2 x≥cols/2)")
	# ⑦ 3×3 桶:列以半区宽、行以整幅高;对角桶 = 0 / 8。去掉什么才红:bucket_of 的列/行用错范围 ⇒ 本条红。
	_chk(SpawnChooser.bucket_of(Vector2i(0, 0), 1, dims) == 0
			and SpawnChooser.bucket_of(Vector2i(5, 0), 1, dims) == 2
			and SpawnChooser.bucket_of(Vector2i(0, 5), 1, dims) == 6
			and SpawnChooser.bucket_of(Vector2i(5, 5), 1, dims) == 8
			and SpawnChooser.bucket_of(Vector2i(6, 0), 2, dims) == 0
			and SpawnChooser.bucket_of(Vector2i(11, 5), 2, dims) == 8,
			"⑦ 半区 3×3 桶划分(0..8;对角桶 0 / 8)")
	# ⑧ 大乱斗并集:两侧列表拼一起后两侧都有点(宿主用并集当候选);去掉并集拼接(只取一侧)⇒ 本条红。
	var union: Array = []
	union.append_array([Vector2i(1, 1), Vector2i(4, 4)])
	union.append_array([Vector2i(8, 1), Vector2i(10, 4)])
	var has_left := false
	var has_right := false
	for c in union:
		if SpawnChooser.side_of(c, dims) == 1:
			has_left = true
		else:
			has_right = true
	_chk(has_left and has_right, "⑧ 大乱斗候选 = 两侧并集(左右都有点)")


func _chooser_checks() -> void:
	var rng := RandomNumberGenerator.new()
	# ⑨ 排除"上一次位置":候选 5 格,上一次 = (0,0);400 次抽样都不能再落在它上面。
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
	_chk(hit_excluded == 0, "⑨ 排除上一次:400 抽都不落在 exclude 里(实中 %d)" % hit_excluded)
	# ⑩ 随机覆盖:同一批抽样必须能落到全部 5 个格(固定 seed 的确定性断言,不是概率容忍)。
	# 去掉什么才红:pick() 改成恒返回 candidates[0] ⇒ 本条红。
	_chk(seen.size() == 5, "⑩ 随机:400 抽覆盖全部 5 个候选(实测 %d)" % seen.size())
	# ⑪ 最小间距可行时必须满足:(0,0) 是 anchors,只有 (25,0) 离它 ≥ 10。
	var dist_pick := SpawnChooser.pick(
			[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(25, 0)],
			[], rng, 10, [Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:pick() 里 min_dist/anchor 过滤整段删掉 ⇒ 可能返回 (1,0)/(2,0)。
	_chk(dist_pick == Vector2i(25, 0), "⑪ 最小间距可行时只从够远的格里选(实得 %s)" % str(dist_pick))
	# ⑫ 最小间距不可行(所有候选都太近)⇒ 逐级放宽后仍要给出候选,不能回 (-1,-1)。
	var relaxed := SpawnChooser.pick([Vector2i(1, 0), Vector2i(2, 0)], [], rng, 999,
			[Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:删掉"逐级 -RELAX_STEP 放宽"的循环 ⇒ 本条红(返回 (-1,-1))。
	_chk(relaxed.x >= 0 and [Vector2i(1, 0), Vector2i(2, 0)].has(relaxed),
			"⑫ 点不够远时放宽而不是放弃(实得 %s)" % str(relaxed))
	# ⑬ 退化优先级:候选全被 exclude、另一个是 anchors 格 ⇒ 宁可选被排除的格,也不与对手同格。
	var forced := SpawnChooser.pick([Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(1, 0)],
			rng, 0, [Vector2i(0, 0)], Vector2i(40, 20))
	# 去掉什么才红:把"排除让位"那层退化成"连 anchors 一起放"⇒ 本条红(返回 (0,0),两人同格)。
	_chk(forced == Vector2i(1, 0), "⑬ 候选被排除光时选被排除格、绝不同格(实得 %s)" % str(forced))
	# ⑭ 空候选:消费端约定 (-1,-1)(宿主自己回退地图/旧逻辑)。
	_chk(SpawnChooser.pick([], [], rng) == Vector2i(-1, -1), "⑭ 空候选返回 (-1,-1)")
	# ⑮ 单候选 + 恰好被排除:仍返回它(不崩、不甩墙角)。
	_chk(SpawnChooser.pick([Vector2i(7, 7)], [Vector2i(7, 7)], rng) == Vector2i(7, 7),
			"⑮ 单候选被排除时退化返回该格")
	# ⑯ pick_many:互不相同 + 两两 ≥ min_dist(6 个格间距 10,dims 40×40)。
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
			"⑯ pick_many 出 6 个互不相同且两两 ≥5 的格(实测 %d)" % many.size())
	# ⑰ 候选不足:3 个格要 5 个 ⇒ 返回 3 个(不凭空造格、不崩);调用方据此回退其它来源。
	var few := SpawnChooser.pick_many([Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], 5, rng)
	# 去掉什么才红:pick_many 的循环不判 `c.x < 0` ⇒ 死循环 / 把 (-1,-1) 当格子塞进去。
	_chk(few.size() == 3 and not few.has(Vector2i(-1, -1)),
			"⑰ pick_many 候选不足时返回全部可用的(实测 %d)" % few.size())
	# ⑱ / ⑲ 1v1 按侧:role1 只在侧 1 列表里、role2 只在侧 2 列表里;两人尽量 ≥ FAR;复活仍在同侧且不与上一次同格。
	var dims := Vector2i(40, 10)
	var left: Array = [Vector2i(2, 2), Vector2i(6, 6), Vector2i(12, 3), Vector2i(17, 8), Vector2i(19, 5)]
	var right: Array = [Vector2i(21, 2), Vector2i(25, 6), Vector2i(31, 3), Vector2i(36, 8), Vector2i(39, 5)]
	var side_bad := 0
	var far_bad := 0
	var respawn_bad := 0
	for s in 32:
		rng.seed = 5000 + s
		var c1 := SpawnChooser.pick(left, [], rng)
		var c2 := SpawnChooser.pick(right, [c1], rng, FAR, [c1], dims)
		if SpawnChooser.side_of(c1, dims) != 1 or SpawnChooser.side_of(c2, dims) != 2:
			side_bad += 1
		if c1 == c2 or GridPathfinder.toroidal_dist(c1, c2, dims.x, dims.y) < FAR:
			far_bad += 1
		var again := SpawnChooser.pick(left, [c1], rng)
		if again == c1 or SpawnChooser.side_of(again, dims) != 1:
			respawn_bad += 1
	# 去掉什么才红:1v1 取侧逻辑写成"全图列表"/复活不排除上一次 ⇒ 本条红。
	_chk(side_bad == 0, "⑱ 1v1 两人各在自己半区(32 轮,越侧 %d 次)" % side_bad)
	_chk(far_bad == 0 and respawn_bad == 0,
			"⑲ 1v1 两人互不相同且 ≥FAR(%d 次不达标)、复活同侧且不与上一次同格(%d 次不达标)"
			% [far_bad, respawn_bad])


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("SPAWN CHOOSER OK(%d 条断言):按侧解析 · 半区/桶 · 排除上一次 · 随机覆盖 · 间距/放宽 · 退化 · 1v1 按侧" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("SPAWN CHOOSER FAILED: %d 处" % _fails.size())
		quit(1)
