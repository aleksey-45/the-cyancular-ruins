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
# ★ 本探针是**活的**文件:每加一相加一次这个数(见文件头),判断标准是"实跑 == 期望"。
#   本 Task 加的两相加 **10** 条(`_check_status_banner` 5 条 + `_check_status_call_sites` 5 条)
#   ⇒ 17 + 10 = **27**。
const EXPECTED_CHECKS := 27

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
	_check_status_banner()
	_check_status_call_sites()
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


# ── 相③:横幅的行为面(建得出来、层位对、能显能收)──
# ★ 它**必须真建一个** PvpMatchClient 子类实例:纯源码断言拦不住"`.new()` 出来的 layer 是 1"
#   这一类 —— 而那正是这条横幅最容易踩、且**完全静默**的坑(层位只住在 .tscn 里)。
# ★ 用桩子而不是真 `pvp_game.tscn`:真场景会建整个世界 + 连 NetBus 发 `match_sync`,
#   而本相要验的只是"横幅挂上去了没有、层位对不对"。桩子只提供基类的那一段接线。
class ClientStub extends PvpMatchClient:
	pass


func _check_status_banner() -> void:
	var stub := ClientStub.new()
	add_child(stub)
	# 生产入口:三个子类都是在 `_ready` 里调它的(Task 2 的守卫另有源码断言钉着这一点)。
	stub._subscribe_reconnect()
	var banner := stub.get_node_or_null("StatusBanner") as StatusBanner
	_check(banner != null,
			"★ `_subscribe_reconnect()` 没有把横幅挂上去(三个模式会一起静默没有提示)")
	if banner == null:
		stub.queue_free()
		return
	# ★★ 层位:这是 `.tscn` 里那个 `layer = 140` 的**行为**判据。写成 `.new()`、或者有人
	#   从 .tscn 里删掉那一行,这里当场红 —— 而源码断言一条都照不到(值在 .tscn 里)。
	_check(banner.layer == 140,
			"★ 横幅层位必须是 140(实得 %d);层位只住在 ui/status_banner.tscn 里" % banner.layer)
	# 显 / 收
	stub._set_status("与服务器断线,正在重连…(剩余 42s)")
	_check(banner._panel.visible and banner._label.text.contains("42s"),
			"设了文字就应该可见且文字正确(visible=%s text=%s)"
			% [str(banner._panel.visible), banner._label.text])
	stub._set_status("")
	_check(not banner._panel.visible, "空串必须收起横幅(visible=%s)" % str(banner._panel.visible))
	# ★ 反向:文字为空但面板仍可见 = "永远挂着一块空黑板",是本类最容易出的错
	stub._set_status("正在重连…")
	_check(banner._panel.visible, "非空文字必须重新亮出来(否则收起之后再也回不来)")
	stub.queue_free()


# ── 相④:四个转折点真的驱动了横幅(源码面)──
# 行为面只能验"设了文字会显示",验不了"状态机在四个转折点上真的调了它" ——
# 后者是"删掉不报错"的一类,必须机械钉住。
func _check_status_call_sites() -> void:
	for fn in ["_begin_reconnect", "_on_reconnect_retry_tick", "_on_resumed", "_abort_reconnect",
			"_cancel_reconnect"]:
		var body := _body(CLIENT_BASE, fn)
		_check(body.contains("_set_status("),
				"★ `%s` 没调 `_set_status(`(那个转折点的提示会静默消失)" % fn)


func _finish() -> void:
	# ★★ 判据是 **`!=`** 而不是 `<`,**两个方向都要红**(与 `tests/late_match_probe.gd` 同款):
	#    多跑一条**没登记的**断言同样是闸失守 —— 那说明 `EXPECTED_CHECKS` 已经与实况对不上,
	#    闸对**后加的那些**断言就成了恒绿的摆设(加断言忘抬这个数时,`<` 会**静默放行**)。
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上 —— 要么有断言没跑到,"
				% [_checks, EXPECTED_CHECKS]
				+ "要么有新断言没登记进 EXPECTED_CHECKS(加断言忘抬这个数时,`<` 会静默放行)")
	if _fails.is_empty():
		print("KH RECON-UI PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("KH RECON-UI PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
