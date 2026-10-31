extends SceneTree
# 对局结束后「某个 peer 离开」该怎么办的守卫(2026-11-01 用户报「游戏结束后房间不会关闭」)。
# 守卫对象 = MatchExitRules(纯逻辑:无 autoload / 无 Node ⇒ 本文件能 `-s` 跑)。
# 语义:MATCH_OVER 之后没有重连价值(结算数据已送达、客户端已 _match_ended)⇒ 最后一个参与者一走就该退进程;
#   还有人看结算则继续跑。**未终局**时一律走宽限(60s 重连窗口) —— 那条不能被"退进程"顺手收掉。
# 去掉什么才红:把 `if not match_over` 那条早退删掉(未终局也按 claims 判)→ ①⑤ 红;QUIT 的 `<= 0` 写成 `< 0` ⇒ ③ 红;
#   WAIT 分支删掉(终局后一律 QUIT)⇒ ② 红(一个人退就带走另一个人的结算页)。
# 测不到什么:① server_main._on_peer_left 是否真的按这个分派(源码级里没有断言,靠真链路日志行
#   「对局已结束且全员离开」);② quit(0) 之后大厅多久把房拆掉(那是回收梯,`MATCH_SWEEP_INTERVAL`)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/match_exit_rules_smoke.gd;通过 = MATCH EXIT RULES OK(n 条断言)。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://server/match/match_exit_rules.gd") == null:
		print("MATCH EXIT RULES FAILED: load(match_exit_rules.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 未终局(对局进行中):无论还剩几人 —— 都走宽限,不许退进程
	_chk(MatchExitRules.after_peer_left(false, 1) == MatchExitRules.ACTION_GRACE
			and MatchExitRules.after_peer_left(false, 2) == MatchExitRules.ACTION_GRACE,
			"未终局必须进宽限(1v1/大乱斗/3v3 的重连窗口),实得 %d / %d" % [
				MatchExitRules.after_peer_left(false, 1), MatchExitRules.after_peer_left(false, 2)])

	# ② 已终局但还有人看结算:继续跑(别把另一个人的结算页一起踢掉)
	_chk(MatchExitRules.after_peer_left(true, 1) == MatchExitRules.ACTION_WAIT,
			"★ 终局后还有 1 人在场时必须继续跑(退进程会把他的结算页踢掉),实得 %d"
			% MatchExitRules.after_peer_left(true, 1))

	# ③ 终局后最后一个参与者走了:立刻退进程(交回房与端口)—— 这是本批修的那条
	_chk(MatchExitRules.after_peer_left(true, 0) == MatchExitRules.ACTION_QUIT,
			"★ 终局后全员走光必须立刻退进程(房/端口不再多占 60s),实得 %d"
			% MatchExitRules.after_peer_left(true, 0))

	# ④ 防御:claims_left 为负(重复通知 / 计数口径写错)也按"一个不剩"处理,不许留在 WAIT 里永驻
	_chk(MatchExitRules.after_peer_left(true, -2) == MatchExitRules.ACTION_QUIT,
			"claims_left 为负必须仍判退进程(实得 %d)" % MatchExitRules.after_peer_left(true, -2))

	# ⑤ 未终局且全员走光:仍走宽限(最后一个掉线的人也该有机会回来;收场由宽限到点那条路负责)
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
