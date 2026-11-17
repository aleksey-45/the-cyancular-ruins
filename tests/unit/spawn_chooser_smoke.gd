extends SceneTree


const EXPECTED_CHECKS := 19
const FAR := 15

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
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
		"# respawn 1 10 20",
		"# respawn 1 -1 5",
		"# respawn 1 abc 5",
		"# respawn 2 9",
		"# respawn 3 50 50",
		"# respawn 2 90 20",
	]
	var p := MapFormat.parse_spawn_metadata(meta)
	_chk(p.get("player") == Vector2i(3, 4) and p.get("player2") == Vector2i(5, 6),
			"① 旧键 # player / # player2 仍被解析(向后兼容)")
	var enemies: Array = p.get("enemies", [])
	_chk(enemies.size() == 1 and enemies[0]["type"] == "flybird"
			and enemies[0]["cell"] == Vector2i(7, 8),
			"② 旧键 # enemy 仍被解析")
	var sides: Dictionary = p.get("respawns", {})
	_chk(sides.get(1, []) == [Vector2i(10, 20), Vector2i(12, 20)]
			and sides.get(2, []) == [Vector2i(90, 20)],
			"③ # respawn 按侧分流、保序、同侧重复去重")
	_chk(sides.get(1, []).size() == 2 and sides.get(2, []).size() == 1
			and not sides.has(3),
			"④ 非法 respawn 行(侧 3 / 负数 / abc / 缺列)全部忽略")
	var legacy := MapFormat.parse_spawn_metadata(["# player 1 2"])
	_chk(legacy.get("player") == Vector2i(1, 2) and not legacy.has("respawns"),
			"⑤ 老地图(无新行)不新增空列表键 ⇒ 回退路径判据仍然成立")


func _side_checks() -> void:
	var dims := Vector2i(12, 6)
	_chk(SpawnChooser.side_of(Vector2i(0, 0), dims) == 1
			and SpawnChooser.side_of(Vector2i(5, 5), dims) == 1
			and SpawnChooser.side_of(Vector2i(6, 0), dims) == 2
			and SpawnChooser.side_of(Vector2i(11, 5), dims) == 2
			and SpawnChooser.side_offset(1, dims) == 0
			and SpawnChooser.side_offset(2, dims) == 6,
			"⑥ 侧 = 左右半区(侧 1 x<cols/2 / 侧 2 x≥cols/2)")
	_chk(SpawnChooser.bucket_of(Vector2i(0, 0), 1, dims) == 0
			and SpawnChooser.bucket_of(Vector2i(5, 0), 1, dims) == 2
			and SpawnChooser.bucket_of(Vector2i(0, 5), 1, dims) == 6
			and SpawnChooser.bucket_of(Vector2i(5, 5), 1, dims) == 8
			and SpawnChooser.bucket_of(Vector2i(6, 0), 2, dims) == 0
			and SpawnChooser.bucket_of(Vector2i(11, 5), 2, dims) == 8,
			"⑦ 半区 3×3 桶划分(0..8;对角桶 0 / 8)")
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
	_chk(hit_excluded == 0, "⑨ 排除上一次:400 抽都不落在 exclude 里(实中 %d)" % hit_excluded)
	_chk(seen.size() == 5, "⑩ 随机:400 抽覆盖全部 5 个候选(实测 %d)" % seen.size())
	var dist_pick := SpawnChooser.pick(
			[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(25, 0)],
			[], rng, 10, [Vector2i(0, 0)], Vector2i(40, 20))
	_chk(dist_pick == Vector2i(25, 0), "⑪ 最小间距可行时只从够远的格里选(实得 %s)" % str(dist_pick))
	var relaxed := SpawnChooser.pick([Vector2i(1, 0), Vector2i(2, 0)], [], rng, 999,
			[Vector2i(0, 0)], Vector2i(40, 20))
	_chk(relaxed.x >= 0 and [Vector2i(1, 0), Vector2i(2, 0)].has(relaxed),
			"⑫ 点不够远时放宽而不是放弃(实得 %s)" % str(relaxed))
	var forced := SpawnChooser.pick([Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(1, 0)],
			rng, 0, [Vector2i(0, 0)], Vector2i(40, 20))
	_chk(forced == Vector2i(1, 0), "⑬ 候选被排除光时选被排除格、绝不同格(实得 %s)" % str(forced))
	_chk(SpawnChooser.pick([], [], rng) == Vector2i(-1, -1), "⑭ 空候选返回 (-1,-1)")
	_chk(SpawnChooser.pick([Vector2i(7, 7)], [Vector2i(7, 7)], rng) == Vector2i(7, 7),
			"⑮ 单候选被排除时退化返回该格")
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
	_chk(many.size() == 6 and distinct_ok and spacing_ok,
			"⑯ pick_many 出 6 个互不相同且两两 ≥5 的格(实测 %d)" % many.size())
	var few := SpawnChooser.pick_many([Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], 5, rng)
	_chk(few.size() == 3 and not few.has(Vector2i(-1, -1)),
			"⑰ pick_many 候选不足时返回全部可用的(实测 %d)" % few.size())
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
