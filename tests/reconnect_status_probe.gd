extends Node

# 阶段 3(spec §4 的 3.1/3.2/3.3/3.4)的**常驻守卫**。场景模式(headless 即可)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn
# 判据:末行 `KH RECON-UI PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 它守什么、为什么不能只靠真链路探针 ═══
# 本批四处改动的**接线**全都是"删掉不报错"的那一类:
#   · `server_main._notify_opponent_left()` 少调一次 ⇒ 服务端不发,客户端看不出任何异常;
#   · `pvp_game._on_opponent_left` 少调 `_cancel_reconnect()` ⇒ **只有**在"断开先到"那一半
#     时序里才现形(竞态,真链路探针跑十次未必撞上一次);
#   · `pvp_match_client._subscribe_reconnect()` 少建横幅 ⇒ 三个模式一起静默没有提示;
#   · 三个 `round_state` 生产者漏走 `_send_round_state()` ⇒ `grace` 字段时有时无。
# 真链路探针(`reconnect_probe`)跑一次 ~72s 且要起子进程;本探针 **2 秒内跑完、不起子进程、
# 不占端口**,把上面那些接线变成机械可查的文本断言 + 两条真行为断言。
#
# ★ 断言计数(见 tests/lib/probe_base.gd 文件头:ALL-OK 只证明"没有失败",**不证明"都跑过"**)。
#   本探针是**活的**文件:Task 2 建它,Task 3/4/5 各往里加相 —— **每加一相就必须同步抬高这个数**,
#   判据是"**实跑条数 == EXPECTED_CHECKS** 且 ALL-OK"(不是"我猜的数是几")。
#   本 Task 落地的条数(逐项相加,别凭印象):
#     _check_opponent_left()  : 1(读得到 SRV_MAIN) + a/b/c/d/e 各 1 = **6**
#     _check_cancel_wiring()  : 1(读得到 CLIENT_BASE) + 1(missing 为空) + 9(三个生产者各 3) = **11**
#   ⇒ 合计 **17**(Task 3 把 ②b 从"前瞻"提升为承重,那一圈由 3 条变 9 条)。
const EXPECTED_CHECKS := 17

const SRV_MAIN := "res://server/server_main.gd"
const CLIENT_BASE := "res://scenes/pvp_match_client.gd"
const PVP_GAME := "res://scenes/pvp_game.gd"
const PRODUCERS := ["res://server/match_round.gd", "res://server/royale_host.gd",
		"res://server/team_host.gd"]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _body(p: String, fn: String) -> String:
	return ScanUtil.func_body(_code(p), fn)


func _ready() -> void:
	_check_opponent_left()
	_check_cancel_wiring()
	_finish()


# ── 相①:3.3 —— `opponent_left` 的服务端发送点与客户端收口 ──
func _check_opponent_left() -> void:
	var srv := _code(SRV_MAIN)
	_check(not srv.is_empty(), "读不到 %s" % SRV_MAIN)
	# ①a 发送点存在,且走的是 `NetBus.reply`(定向发送的判活收口)
	_check(srv.contains("NetBus.reply(") and srv.contains("\"opponent_left\""),
			"★ %s 里没有 `NetBus.reply(…, opponent_left)` —— 这条 RPC 会退回「零调用点」"
			% SRV_MAIN)
	# ①b 它被 1v1 收场那一支调用(**不是**只定义不调 —— 那正是本条要修的缺陷形状)
	var exp := _body(SRV_MAIN, "_expire_graces")
	_check(exp.contains("_notify_opponent_left()"),
			"★ `_expire_graces` 里没调 `_notify_opponent_left()` —— 发送点定义了却没人调,"
			+ "幸存者照样干等 60s")
	# ①c 调用必须排在收场**之前**(排在 quit 之后 = 永远发不出去)
	var i_notify := exp.find("_notify_opponent_left()")
	var i_quit := exp.find("get_tree().quit(0)")
	_check(i_notify >= 0 and i_quit >= 0 and i_notify < i_quit,
			"★ 通知必须排在 `get_tree().quit(0)` **之前**(notify=%d quit=%d)"
			% [i_notify, i_quit])
	# ①d 客户端侧:`_on_opponent_left` 里调了 `_cancel_reconnect()`
	var opp := _body(PVP_GAME, "_on_opponent_left")
	_check(opp.contains("_cancel_reconnect()"),
			"★ `pvp_game._on_opponent_left` 没调 `_cancel_reconnect()` —— "
			+ "「断开先到」那一半时序里,重连循环会继续跑满 60s")
	# ①e 反向:那条 `_match_ended` 闸仍在(它挡的是"通知先到"那一半)。
	# ★ 谓词必须咬住**闸自身的形状**,不能只找 `_match_ended` 这个标识符 —— 紧邻下一行的
	#   `_match_ended = true` 是一条**赋值**,单凭它就足以喂饱 `contains("_match_ended")`:
	#   删掉闸(甚至删掉整个 `if …: return` 块)时那种谓词照绿,是一条**读起来像覆盖、
	#   实际不覆盖**的空断言(2026-09-28 复核实测)。
	_check(opp.contains("if _match_ended"),
			"★ `_on_opponent_left` 的 `_match_ended` 闸仍在(通知先到时靠它挡住重连)")


# ── 相②:`_cancel_reconnect` 的行为面(它必须真的把循环停掉)──
func _check_cancel_wiring() -> void:
	var base := _code(CLIENT_BASE)
	_check(not base.is_empty(), "读不到 %s" % CLIENT_BASE)
	# ②a 函数体四件事一件都不能少(少一件 = 循环会从某个入口继续跑)
	var body := _body(CLIENT_BASE, "_cancel_reconnect")
	var missing: Array[String] = []
	for needle in ["_reconnecting = false", "_reconnect_started_ms = 0",
			"_reclaim_sent = false", "_attempt_started_ms = 0"]:
		if not body.contains(needle):
			missing.append(needle)
	_check(missing.is_empty(),
			"`_cancel_reconnect` 少复位了这些量(循环会从某个入口继续跑):%s" % str(missing))
	# ②b(★ Task 3 起是**承重**断言,不再是前瞻):三个 `round_state` 生产者都必须走唯一出口。
	#    漏一个 ⇒ 那个模式的「掉线中」永远不亮,而且**不报错**。
	for p in PRODUCERS:
		var c := _code(p)
		_check(not c.is_empty(), "读不到 %s" % p)
		_check(c.contains("_send_round_state("),
				"★ %s 没走 `_send_round_state(`(那个模式的「掉线中」不会亮)" % p)
		_check(not c.contains("_rpc_all(\"round_state\""),
				"★ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("KH RECON-UI PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("KH RECON-UI PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
