extends SceneTree

const EXPECTED_CHECKS := 13

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _counts(teams: Dictionary) -> Dictionary:
	return TeamRules.team_counts(teams)


func _initialize() -> void:
	if load("res://core/mp/team_rules.gd") == null or load("res://server/lobby/room_types.gd") == null:
		print("TEAM RULES SMOKE: 加载 team_rules.gd / room_types.gd 失败")
		quit(1)
		return

	var k2 := TeamRules.kills_to_win({1: 1, 2: 1})
	var k6 := TeamRules.kills_to_win({1: 3, 2: 3})
	var k10 := TeamRules.kills_to_win({1: 5, 2: 5})
	_chk(k2 == 5 and k6 == 9 and k10 == 13,
			"目标锚点:2 人应 5 / 6 人应 9 / 10 人应 13,实得 %d / %d / %d" % [k2, k6, k10])

	var prev := 0
	var bad := ""
	for total in range(2, 11):
		var a := total / 2
		var t := TeamRules.kills_to_win({1: a, 2: total - a})
		if t < TeamRules.KILLS_MIN or t > TeamRules.KILLS_MAX:
			bad = "总人数 %d 得到 %d,越界 [%d,%d]" % [total, t, TeamRules.KILLS_MIN, TeamRules.KILLS_MAX]
			break
		if prev != 0 and t < prev:
			bad = "总人数 %d 的目标 %d < 上一档 %d(应单调不减)" % [total, t, prev]
			break
		prev = t
	_chk(bad == "", "目标在 2..10 人区间单调且不越界" + ("" if bad == "" else ":" + bad))

	var t33 := {1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 2}
	var r33 := TeamRules.subsidy(t33)
	_chk(int(r33["kills_target"]) == 9 and int(r33["score_bonus"]) == 0
			and int(r33["hp_bonus"]) == 0 and is_equal_approx(float(r33["damage_mult"]), 1.0)
			and int(r33["diff"]) == 0 and int(r33["smaller_team"]) == 0,
			"★ 6 人 3v3 恒等:应 目标 9 / 比分 0 / 血量 0 / 伤害 1.0,实得 %s" % str(r33))

	var even_bad := ""
	for n in range(1, 6):
		var teams := {}
		for i in range(n):
			teams[i + 1] = 1
			teams[i + 1 + n] = 2
		var rr := TeamRules.subsidy(teams)
		if int(rr["diff"]) != 0 or int(rr["smaller_team"]) != 0 or int(rr["score_bonus"]) != 0 \
				or int(rr["hp_bonus"]) != 0 or not is_equal_approx(float(rr["damage_mult"]), 1.0):
			even_bad = "%d v %d 不是恒等: %s" % [n, n, str(rr)]
			break
	_chk(even_bad == "", "所有 n v n 势均局三处补贴恒等" + ("" if even_bad == "" else ":" + even_bad))

	var sb2 := TeamRules.score_bonus({1: 3, 2: 1})
	var sb8 := TeamRules.score_bonus({1: 9, 2: 1})
	var cap_bad := ""
	for a in range(1, 6):
		for b in range(1, 6):
			var c := {1: a, 2: b}
			var target := TeamRules.kills_to_win(c)
			var bonus := TeamRules.score_bonus(c)
			if bonus >= target:
				cap_bad = "%dv%d:补贴 %d ≥ 目标 %d(会开局即胜)" % [a, b, bonus, target]
				break
		if cap_bad != "":
			break
	_chk(sb2 == 2 and sb8 == 8 and cap_bad == "",
			"比分补贴 = 人数差且恒 < 目标(3v1 应 2 / 9v1 应 8,实得 %d / %d)" % [sb2, sb8]
			+ ("" if cap_bad == "" else "; " + cap_bad))

	var hp1 := TeamRules.hp_bonus_hp({1: 2, 2: 1})
	var hp2 := TeamRules.hp_bonus_hp({1: 3, 2: 1})
	var hp_cap := TeamRules.hp_bonus_hp({1: 9, 2: 1})
	var hp_want := roundi(float(PlayerParams.player_max_hp) * 0.1)
	_chk(hp1 == hp_want and hp2 == hp_want * 2
			and hp_cap == roundi(float(PlayerParams.player_max_hp) * float(TeamRules.HP_CAP_PERMILLE) / 1000.0),
			"血量补贴:差 1 应 +%d、差 2 应 +%d、差 8 封顶 +%d,实得 %d / %d / %d"
			% [hp_want, hp_want * 2,
			roundi(float(PlayerParams.player_max_hp) * float(TeamRules.HP_CAP_PERMILLE) / 1000.0),
			hp1, hp2, hp_cap])

	var dm := [
		TeamRules.damage_mult({1: 3, 2: 2}),
		TeamRules.damage_mult({1: 3, 2: 1}),
		TeamRules.damage_mult({1: 4, 2: 1}),
		TeamRules.damage_mult({1: 5, 2: 2}),
		TeamRules.damage_mult({1: 9, 2: 1}),
	]
	_chk(is_equal_approx(dm[0], 1.0) and is_equal_approx(dm[1], 1.0)
			and is_equal_approx(dm[2], 1.1) and is_equal_approx(dm[3], 1.1)
			and is_equal_approx(dm[4], 1.3),
			"伤害倍率:差 0~2 恒 1.0、差 3 = 1.1、差 8 封顶 1.3,实得 %s" % str(dm))

	var cts := TeamRules.team_counts({1: 1, 2: 2, 3: 0, 4: 1})
	_chk(int(cts[1]) == 2 and int(cts[2]) == 1 and TeamRules.total_players(cts) == 3
			and TeamRules.head_diff(cts) == 1,
			"team_counts 只认队 1/2(表外队号不计):实得 %s" % str(cts))

	var ready_1v1 := RoomTypes.team_ready({1: [1], 2: [2]})
	var ready_2v1 := RoomTypes.team_ready({1: [1, 2], 2: [3]})
	var ready_empty := RoomTypes.team_ready({1: [1, 2], 2: []})
	var ready_none := RoomTypes.team_ready({})
	_chk(ready_1v1 and ready_2v1 and not ready_empty and not ready_none,
			"开局闸门:1+1 可开 / 2+1 可开 / 2+0 不可开 / 空不可开,实得 %s %s %s %s"
			% [ready_1v1, ready_2v1, ready_empty, ready_none])

	var room: RoomTypes.Room = RoomTypes.Room.new()
	room.player_role = {10: 1, 11: 2, 12: 3, 13: 4}
	room.team_of = {1: 1, 2: 1}
	var filled := RoomTypes.team_autofill(room)
	var filled_counts := TeamRules.team_counts(filled)
	_chk(filled.size() == 4 and int(filled[1]) == 1 and int(filled[2]) == 1
			and int(filled_counts[2]) == 2,
			"未选边自动补位:两人都补进空着的 B 队且已选边者不动,实得 %s" % str(filled))

	var room2: RoomTypes.Room = RoomTypes.Room.new()
	room2.player_role = {10: 1, 11: 2, 12: 3}
	var filled2 := RoomTypes.team_autofill(room2)
	var counts2 := TeamRules.team_counts(filled2)
	_chk(int(counts2[1]) + int(counts2[2]) == 3
			and int(counts2[1]) <= ModeDefs.TEAM_SIZE and int(counts2[2]) <= ModeDefs.TEAM_SIZE
			and absi(int(counts2[1]) - int(counts2[2])) <= 1,
			"补位:全未选边时两队人数差 ≤ 1 且不超每队上限 %d,实得 %s" % [ModeDefs.TEAM_SIZE, str(counts2)])

	var can5 := RoomTypes.team_can_join({1: [], 2: []}, 1)
	var can_full := RoomTypes.team_can_join({1: [1, 2, 3, 4, 5], 2: []}, 1)
	_chk(can5 and not can_full and ModeDefs.TEAM_SIZE == 5 and ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT == 10,
			"容量:每队上限 %d、总 %d(满队不可再加入),实得 can5=%s canFull=%s"
			% [ModeDefs.TEAM_SIZE, ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT, can5, can_full])

	_chk(ModeDefs.MODE_TEAM == "team" and ModeDefs.label(ModeDefs.MODE_TEAM) == "对抗",
			"mode id 仍是 \"team\"、显示名是「对抗」(实得 id=%s label=%s)"
			% [ModeDefs.MODE_TEAM, ModeDefs.label(ModeDefs.MODE_TEAM)])

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("TEAM RULES SMOKE OK(%d 条断言):目标锚点/单调上界 · 6 人 3v3 恒等 · 比分补贴上限 · 血量封顶 · 伤害阈值 · 开局闸门 · 未选边补位 · 容量" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TEAM RULES SMOKE FAILED: %d 处" % _fails.size())
		quit(1)
