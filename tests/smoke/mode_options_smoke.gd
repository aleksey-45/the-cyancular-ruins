extends SceneTree

# ModeOptions 守卫:选项按模式取键(修 X5:藏了控件却仍上发)。
# 通过 = MODE OPTIONS OK(n 条断言);判据 grep 文本。
# ★ 去掉什么才会红:把 `ModeDefs.OPTION_KEYS` 里 3v3 加回 disabled_weapons ⇒ ② 红;
#   把 beta/time 条件删掉 ⇒ ④ 红;未知模式改成"发全量" ⇒ ⑤ 红。
# ⚠ -s 脚本套外层 timeout。

const EXPECTED_CHECKS := 7

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _snapshot(beta: bool = false) -> Dictionary:
	return {
		"hue": 0.25, "round_full_heal": true, "disabled_weapons": [2, 4],
		"match_time": 300, "map": "res://maps/newfactory.cyrm",
		"time": {"grain": 1}, "beta": beta,
	}


func _initialize() -> void:
	var snap := _snapshot()

	# ① 1v1:回合回血 + 禁用武器 + map,不含 match_time / time(非 beta)
	var pvp := ModeOptions.build(ModeDefs.MODE_PVP, snap)
	_chk(pvp.has("hue") and pvp.has("round_full_heal") and pvp.has("disabled_weapons") and pvp.has("map")
			and not pvp.has("match_time") and not pvp.has("time"),
			"1v1 应含 hue/round_full_heal/disabled_weapons/map,不含 match_time/time")

	# ② 3v3:只剩 hue/map(X5 回归点:禁用武器/回血不得上发)
	var team := ModeOptions.build(ModeDefs.MODE_TEAM, snap)
	_chk(team.keys() == ["hue", "map"], "3v3 只应上发 hue/map(实得 %s)" % str(team.keys()))

	# ③ 大乱斗:禁用武器 + match_time + map,不含回合回血
	var roy := ModeOptions.build(ModeDefs.MODE_ROYALE, snap)
	_chk(roy.has("disabled_weapons") and roy.has("match_time") and roy.has("map")
			and not roy.has("round_full_heal") and not roy.has("time"),
			"大乱斗应含 disabled_weapons/match_time/map,不含 round_full_heal/time")

	# ④ Beta:非 1v1 才带 time;1v1 绝不带
	var beta_snap := _snapshot(true)
	var beta_team := ModeOptions.build(ModeDefs.MODE_TEAM, beta_snap)
	var beta_pvp := ModeOptions.build(ModeDefs.MODE_PVP, beta_snap)
	_chk(bool(beta_team.get("time", {}).get("grain", 0)) == true and not beta_pvp.has("time"),
			"Beta 下 team 应带 time、1v1 不得带")

	# ⑤ 未知模式:退回最小键,不许发全量
	var unknown := ModeOptions.build("duel", snap)
	_chk(unknown.keys() == ["hue", "map"], "未知模式只应发 hue/map(实得 %s)" % str(unknown.keys()))

	# ⑥ snapshot 缺键时不臆造(值只来自 snapshot)
	var partial := {"hue": 0.5}
	var partial_out := ModeOptions.build(ModeDefs.MODE_ROYALE, partial)
	_chk(partial_out.keys() == ["hue"], "snapshot 缺键时不得补默认值(实得 %s)" % str(partial_out.keys()))

	# ⑦ 纯函数:两次调用互不共享(返回值改一份不影响另一份)
	var a := ModeOptions.build(ModeDefs.MODE_PVP, snap)
	a["hue"] = 0.99
	var b := ModeOptions.build(ModeDefs.MODE_PVP, snap)
	_chk(float(b["hue"]) == 0.25, "build 返回的字典不得与内部/上次结果共享引用")

	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MODE OPTIONS OK(%d 条断言)" % _checks)
	else:
		for f in _fails:
			print("  FAIL %s" % f)
		print("MODE OPTIONS FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
