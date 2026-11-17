extends SceneTree

const EXPECTED_CHECKS := 6

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var duel := {
		1: {"acs": 120.0, "kills": 15, "deaths": 22},
		2: {"acs": 290.0, "kills": 22, "deaths": 15},
	}
	_chk(ScoreRules.pick_mvp(duel) == 2, "不限队(旧口径·能力保留)时应取 ACS 最高者")
	_chk(ScoreRules.pick_mvp(duel, [1]) == 1, "候选 = [胜者 role] 时必须给胜者 —— 败方 ACS 再高也不能拿 ★")

	var team := {
		1: {"acs": 100.0, "kills": 6, "deaths": 3},
		2: {"acs": 140.0, "kills": 8, "deaths": 4},
		3: {"acs": 170.0, "kills": 9, "deaths": 5},
		4: {"acs": 260.0, "kills": 14, "deaths": 2},
		5: {"acs": 90.0, "kills": 4, "deaths": 6},
		6: {"acs": 80.0, "kills": 3, "deaths": 7},
	}
	_chk(ScoreRules.pick_mvp(team, [1, 2, 3]) == 3, "3v3 候选 = 胜队 role 集合时,只在这三人里挑(全场最高在败队也不行)")
	_chk(ScoreRules.pick_mvp(team) == 4, "不限队时仍是全场 ACS 最高(证明候选参数是唯一开关,不是把规则改成了按队)")

	var tie_a := {
		2: {"acs": 50.0, "kills": 3, "deaths": 1},
		5: {"acs": 50.0, "kills": 3, "deaths": 1},
		1: {"acs": 50.0, "kills": 3, "deaths": 1},
	}
	var tie_b := {
		1: {"acs": 50.0, "kills": 3, "deaths": 1},
		5: {"acs": 50.0, "kills": 3, "deaths": 1},
		2: {"acs": 50.0, "kills": 3, "deaths": 1},
	}
	_chk(ScoreRules.pick_mvp(tie_a) == 1 and ScoreRules.pick_mvp(tie_b) == 1,
			"完全并列 → 取最小 role(1),且与字典插入顺序无关(确定性)")

	var neg := {
		1: {"acs": -120.0, "kills": 2, "deaths": 9},
		2: {"acs": -30.0, "kills": 4, "deaths": 7},
	}
	_chk(ScoreRules.pick_mvp(neg) == 2, "全员负 ACS 时取最高者(-30 > -120),不能返回 0")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MVP CHOICE OK(%d 条断言):胜方候选 · 3v3 胜队候选 · 并列确定性 · 负 ACS" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("MVP CHOICE FAILED: %d 处" % _fails.size())
		quit(1)
