extends SceneTree

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	if load("res://server/match/match_exit_rules.gd") == null:
		print("MATCH EXIT RULES FAILED: load(match_exit_rules.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	_chk(MatchExitRules.after_peer_left(false, 1) == MatchExitRules.ACTION_GRACE
			and MatchExitRules.after_peer_left(false, 2) == MatchExitRules.ACTION_GRACE,
			"未终局必须进宽限(1v1/大乱斗/3v3 的重连窗口),实得 %d / %d" % [
				MatchExitRules.after_peer_left(false, 1), MatchExitRules.after_peer_left(false, 2)])

	_chk(MatchExitRules.after_peer_left(true, 1) == MatchExitRules.ACTION_WAIT,
			"★ 终局后还有 1 人在场时必须继续跑(退进程会把他的结算页踢掉),实得 %d"
			% MatchExitRules.after_peer_left(true, 1))

	_chk(MatchExitRules.after_peer_left(true, 0) == MatchExitRules.ACTION_QUIT,
			"★ 终局后全员走光必须立刻退进程(房/端口不再多占 60s),实得 %d"
			% MatchExitRules.after_peer_left(true, 0))

	_chk(MatchExitRules.after_peer_left(true, -2) == MatchExitRules.ACTION_QUIT,
			"claims_left 为负必须仍判退进程(实得 %d)" % MatchExitRules.after_peer_left(true, -2))

	_chk(MatchExitRules.after_peer_left(false, 0) == MatchExitRules.ACTION_GRACE,
			"未终局全员掉线仍必须进宽限(实得 %d)" % MatchExitRules.after_peer_left(false, 0))

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MATCH EXIT RULES OK(%d 条断言):未终局走宽限 · 终局有人继续跑 · 终局走光立刻退 · 负计数 · 未终局走光走宽限"
				% _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("MATCH EXIT RULES FAILED: %d 处" % _fails.size())
		quit(1)
