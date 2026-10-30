extends SceneTree
# MVP 归属守卫(`ScoreRules.pick_mvp`;2026-10-30 用户裁定「全场最佳必须出自胜方」)。
# 存在理由(逐条对应真实缺陷):
#   ① 用户实机报「明明赢了,全场最佳却是对面」—— 旧实现 `mvp_role()` 在**全 roster** 里挑 ACS 最高者,
#      与胜负完全脱钩:1v1 里赢家若"赢的局 5-4、输的局 0-5",败方的 kills 更多、deaths 更少 ⇒ ACS 反而更高
#      ⇒ ★ 落在败方。现在候选集由调用方给(1v1 = [胜者 role]、3v3 = 胜队 role 集)。
#   ② 并列/平局规则的确定性:ACS → 击杀多 → 阵亡少 → role 号升序;同一份数据两次给同一答案。
#   ③ 旧实现 `best_acs := -1.0` 在**全员负 ACS** 时返回 0(= 结算页没有 ★)—— 死亡惩罚足以把 kscore 压成负。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/mvp_choice_smoke.gd;通过 = "MVP CHOICE OK(n 条断言)"。

const EXPECTED_CHECKS := 6

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ── ① 1v1 夹具:败方(2 号)ACS 更高 ──
	# 这种数据是可达的:赢家赢的局 5-4、输的局 0-5 ⇒ 败方 kills 更多、deaths 更少。
	var duel := {
		1: {"acs": 120.0, "kills": 15, "deaths": 22},
		2: {"acs": 290.0, "kills": 22, "deaths": 15},
	}
	# 去掉什么才红:① 删掉 candidates 过滤(退回全 roster)⇒ 第 2 条红;② 把 pick_mvp 的候选回落改成恒全表 ⇒ 第 2 条红。
	_chk(ScoreRules.pick_mvp(duel) == 2, "不限队(旧口径·能力保留)时应取 ACS 最高者")
	_chk(ScoreRules.pick_mvp(duel, [1]) == 1, "候选 = [胜者 role] 时必须给胜者 —— 败方 ACS 再高也不能拿 ★")

	# ── ② 3v3 夹具:2 队赢,1 队里 ACS 最高的是 3 号;全场 ACS 最高的是败队 4 号 ──
	var team := {
		1: {"acs": 100.0, "kills": 6, "deaths": 3},
		2: {"acs": 140.0, "kills": 8, "deaths": 4},
		3: {"acs": 170.0, "kills": 9, "deaths": 5},
		4: {"acs": 260.0, "kills": 14, "deaths": 2},
		5: {"acs": 90.0, "kills": 4, "deaths": 6},
		6: {"acs": 80.0, "kills": 3, "deaths": 7},
	}
	# 去掉什么才红:把 team_host 的候选集从 `_roles_of_team(胜队)` 改回空表 ⇒ 这条红(会选 4 号)。
	_chk(ScoreRules.pick_mvp(team, [1, 2, 3]) == 3, "3v3 候选 = 胜队 role 集合时,只在这三人里挑(全场最高在败队也不行)")
	_chk(ScoreRules.pick_mvp(team) == 4, "不限队时仍是全场 ACS 最高(证明候选参数是唯一开关,不是把规则改成了按队)")

	# ── ③ 并列规则 + 确定性:ACS 全并列 → 击杀多者 → 阵亡少者 → role 升序 ──
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
	# 去掉什么才红:删 pool.sort() 或把"完全并列取最小 role"改成迭代顺序 ⇒ 两次答案不同/不是 1。
	_chk(ScoreRules.pick_mvp(tie_a) == 1 and ScoreRules.pick_mvp(tie_b) == 1,
			"完全并列 → 取最小 role(1),且与字典插入顺序无关(确定性)")

	# ── ④ 全员负 ACS:仍要给出 MVP(旧实现返回 0 = 没有 ★)──
	var neg := {
		1: {"acs": -120.0, "kills": 2, "deaths": 9},
		2: {"acs": -30.0, "kills": 4, "deaths": 7},
	}
	# 去掉什么才红:把 `first` 首收逻辑改回 `best_acs := -1.0` ⇒ 这条红(返回 0)。
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
