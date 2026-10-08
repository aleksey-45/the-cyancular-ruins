extends SceneTree

# 断线重连网络协议接口规范检查：
# 源码级静态验证 NetBusExt 中的重连 RPC 注解完整性，确保方法注册与调用语义符合规范。
# 运行方式：
#   timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/reconnect_smoke.gd

const NETBUS := "res://core/net/net_bus.gd"
const NETBUS_EXT := "res://core/net/net_bus_ext.gd"
const SESSION := "res://core/net/pvp_session.gd"
const LOBBY_PAGE := "res://scenes/lobby_page.gd"
const MAIN_MENU := "res://scenes/main_menu.gd"
const PAGE_MP := "res://scenes/mp_lobby.gd"
const GAME_ROYALE := "res://scenes/royale_game.gd"
const GAME_TEAM := "res://scenes/team_game.gd"

# 本次新增的三条:必须在 Ext,不得在 NetBus
const N_EXT_RPCS := ["session_token", "report_token", "reclaim_role"]

# 这三条各自的 @rpc 注解(逐字要求)—— 决定它能不能被路由的那一行。
# - 节点归属正确但注解错误时，冒烟测试仍会产生假阳性通过而遗漏功能缺陷:
#   `report_token` 若写成 `authority`,客户端上行会被直接拒(authority = 只许服务器调),
#   症状是"重连时 token 永远报不上去"且一行错都不打 —— 正是本文件要拦的那类静默 no-op。
#   session_token 反向同理:写成 any_peer = 任何人都能伪造 token 下发。
const N_EXT_RPC_ANN := {
	"session_token": "@rpc(\"authority\", \"reliable\")",
	"report_token": "@rpc(\"any_peer\", \"reliable\")",
	"reclaim_role": "@rpc(\"any_peer\", \"reliable\")",
}

# ── 3v3 团队协议(2026-09-19,B 册 Task 2)──
# 八条 `team_*`:六条上行(any_peer)+ 两条下发(authority)。与重连那三条相同设计规范约束:
# 必须在 NetBusExt、不得在 NetBus(挂错节点 = 静默 no-op)。
const N_TEAM_RPCS := ["team_create", "team_join", "team_pick", "team_leave", "team_start",
		"team_list", "team_rooms", "team_room_state"]

# 注解同样逐字严格校验 —— -  方向写反是静默的:`team_rooms` 若写成 any_peer = 任何客户端都能
# 伪造房间列表;`team_start` 若写成 authority = 客户端的上行被直接拒("房主点了开始没反应")。
const N_TEAM_RPC_ANN := {
	"team_create": "@rpc(\"any_peer\", \"reliable\")",
	"team_join": "@rpc(\"any_peer\", \"reliable\")",
	"team_pick": "@rpc(\"any_peer\", \"reliable\")",
	"team_leave": "@rpc(\"any_peer\", \"reliable\")",
	"team_start": "@rpc(\"any_peer\", \"reliable\")",
	"team_list": "@rpc(\"any_peer\", \"reliable\")",
	"team_rooms": "@rpc(\"authority\", \"reliable\")",
	"team_room_state": "@rpc(\"authority\", \"reliable\")",
}

const N_TEAM_SIGNALS := ["team_create_requested", "team_join_requested", "team_pick_requested",
		"team_leave_requested", "team_start_requested", "team_list_requested",
		"local_team_rooms", "local_team_room_state"]

# ── 回大厅后重连返回对局(阶段 2-B,2026-09-21)──
# 两条:一条上行(客户端 -> 大厅)、一条下发(大厅 -> 客户端)。与上面那些相同设计规范约束:
# 必须在 NetBusExt、不得在 NetBus(挂错节点 = 静默 no-op,而症状只是"重连返回对局永远失败")。
const N_REJOIN_RPCS := ["rejoin_request", "rejoin_denied"]

const N_REJOIN_RPC_ANN := {
	"rejoin_request": "@rpc(\"any_peer\", \"reliable\")",
	"rejoin_denied": "@rpc(\"authority\", \"reliable\")",
}

const N_REJOIN_SIGNALS := ["rejoin_requested", "local_rejoin_denied"]

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 剥掉 `#` 注释与字符串外的空白,只留代码本体 —— 否则注释里提到的方法名会测试漏报
func _code(text: String) -> String:
	var out := ""
	for line in text.split("\n"):
		var i := line.find("#")
		out += (line if i < 0 else line.substr(0, i)) + "\n"
	return out


# 该文件里有没有 `func <name>(` 定义
func _defines(code: String, name: String) -> bool:
	return code.contains("func %s(" % name)


# `func <name>(` 上方紧邻的非空行 = 它的注解。
# 注解与 func 之间可能夹空行/注释行(注释行已被 `_code` 打成空行),故向前跳过空行。
# 若这行注解被移除，返回的将是前一行的代码文本 —— 与期望内容不匹配而正确报错（避免产生静默假阳性）。
func _rpc_ann(code: String, name: String) -> String:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("func %s(" % name):
			var j := i - 1
			while j >= 0 and lines[j].strip_edges().is_empty():
				j -= 1
			return lines[j].strip_edges() if j >= 0 else ""
	return ""


# 某个 func 的函数体(到下一个顶层 `func ` 为止;照 ScanUtil.func_body 的形状)
func _func_body(code: String, name: String) -> String:
	var i := code.find("func %s(" % name)
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


func _initialize() -> void:
	var ext := _code(_read(NETBUS_EXT))
	var bus := _code(_read(NETBUS))
	var ses := _code(_read(SESSION))
	_check(not ext.is_empty(), "读不到 %s" % NETBUS_EXT)
	_check(not bus.is_empty(), "读不到 %s" % NETBUS)
	_check(not ses.is_empty(), "读不到 %s" % SESSION)

	for n in N_EXT_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)

	# 三个信号也要在(worker/客户端都靠信号解耦)
	for s in ["local_session_token", "token_reported", "reclaim_requested"]:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)

	# - 注解:节点归属对了还不够 —— 决定 RPC 能不能被路由的就是这一行
	for n in N_EXT_RPC_ANN:
		var ann := _rpc_ann(ext, n)
		_check(ann == N_EXT_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_EXT_RPC_ANN[n], ann])

	# PvpSession 字段:必须 `static var`(本类全是静态)
	for f in ["token", "worker_port", "room_code", "rejoin"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)

	_check(ses.contains("static func can_rejoin()") and ses.contains("static func can_rejoin_to(")
			and ses.contains("static func clear_rejoin()"),
			"PvpSession 缺 can_rejoin() / can_rejoin_to() / clear_rejoin()(行的可点性与回局失败路径都要用)")
	_check_rejoin_lifecycle(ses)

	# ── 3v3 团队协议的八条 `team_*`(B 册 Task 2)──
	# - 双向:只断言"在 NetBusExt 里有"会让"两边各抄一份"照样绿,而那正是静默 no-op 的成因
	#   (先例 `beam_fired`:NetBus / NetBusExt 各一份,接收端挂错节点 = 包到了没人接)。
	for n in N_TEAM_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)

	# 八个信号也要在(大厅/客户端都靠信号解耦)
	for s in N_TEAM_SIGNALS:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)

	# 注解:上行 6 条 any_peer / 下发 2 条 authority(逐字)
	for n in N_TEAM_RPC_ANN:
		var tann := _rpc_ann(ext, n)
		_check(tann == N_TEAM_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_TEAM_RPC_ANN[n], tann])

	# ── 重连返回对局协议的两条(阶段 2-B)──
	for n in N_REJOIN_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)
	for s in N_REJOIN_SIGNALS:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)
	# - 方向写反是静默的:`rejoin_denied` 若写成 any_peer = 任何客户端都能伪造"你的对局结束了";
	#   `rejoin_request` 若写成 authority = 客户端的上行被直接拒("按钮点了没反应")。
	for n in N_REJOIN_RPC_ANN:
		var rann := _rpc_ann(ext, n)
		_check(rann == N_REJOIN_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_REJOIN_RPC_ANN[n], rann])

	# ── 重连返回对局支路的生产接线(阶段 2-B Task 6)──
	# - 为什么这几条必须在这里:重连返回对局那几件生产方式没有任何探针走过 —— `try_rejoin_row` /
	#   `_request_rejoin` / `_on_rejoin_denied` / `_tick_rejoin_timeout` 在今天全仓零调用
	#   (行渲染与行按下是 Task 7,真实网络链路是 Task 8)。于是下面这两种删法一行报错都不会有:
	#     - `_finish_lobby_ready` 里那行 connect 删掉  ->  大厅答的 `rejoin_denied` 没人接  -> 
	#       凭据永不清、那一行永远可点、每次点都是同一句失败;
	#     - mp_lobby 的 `_process` 里那条梯删掉  ->  15s 兜底保护根本不存在,玩家停在一句"正在回到对局…"上。
	#   - 两条都按函数体判:全文件 `contains` 会被别处的同名调用误判通过(本仓的老毛病,
	#     先例 = `team_room_smoke` ⑨②"按函数体判而不是全文件 contains")。
	for p in [LOBBY_PAGE, PAGE_MP]:
		_check(not _read(p).is_empty(), "读不到 %s" % p)
	_check(_func_body(_code(_read(LOBBY_PAGE)), "_finish_lobby_ready").contains(
			"NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)"),
			"★ LobbyPage._finish_lobby_ready() 未接 `local_rejoin_denied` —— 大厅答「回不去」时凭据永不清、那一行永远可点")
	for p in [PAGE_MP]:
		_check(_func_body(_code(_read(p)), "_process").contains("_tick_rejoin_timeout()"),
				"★ %s 的 _process 未接回局超时梯 —— 大厅 15s 没应答时玩家卡在「正在回到对局…」上" % p)

	_check_rejoin_ui_wiring()
	_check_liveness_guards()

	if _fail == 0:
		print("RECONNECT SMOKE OK")
		quit(0)
	else:
		print("RECONNECT SMOKE FAILED: %d" % _fail)
		quit(1)


# ──
# §④ 重连返回对局凭据的生死线(2026-09-22,按 C1 重写)
# ──
# 注意事项：reset() 不得清除对局重连凭据：
#    玩家从对局返回主菜单并重新进入大厅时，凭据必须保持有效，确保对战房间仍可点击重连；
#    凭据仅在明确切换房间号或游戏模式（note_room）、或服务端拒绝重连/超时（clear_rejoin）时清理。
func _check_rejoin_lifecycle(ses: String) -> void:
	var reset_body := _func_body(ses, "reset")
	_check(not reset_body.is_empty(), "PvpSession 里找不到 func reset()")
	_check(not (reset_body.contains("token = \"\"") or reset_body.contains("worker_port = 0")
			or reset_body.contains("room_code = \"\"") or reset_body.contains("rejoin = false")),
			"★★ PvpSession.reset() 不得清空回局凭据 —— 必须保留凭据以支持断线重连")
	_check(not reset_body.contains("clear_rejoin()"),
			"★ PvpSession.reset() 调了 clear_rejoin()(同上一款:进页复位 ≠ 下车清理)")
	_check(reset_body.contains("map_path = \"\""),
			"PvpSession.reset() 未清 map_path(换局会漏上一局的地图;进页该复位的仍是它)")

	_check(ses.contains("static var room_mode"),
			"★ PvpSession 缺 static var room_mode —— 它是「该不该因模式切换作废凭据」的判别器:"
			+ "三张注册表的房号共用同一个 4 位空间,不判模式时 1v1 的凭据会让**同号的 3v3 房**看起来像「我的房」")

	# - 凭据模型(2026-10-03,大厅合一):模式记进凭据 —— `note_room(code, mode)` 在
	#   换了房号或换了模式时作废凭据;`can_rejoin_to(code, mode)` 两个都要对上。
	#   原先那套(主菜单三个按钮走 `enter_mode`)随合一整体删除,别再加回来。
	var nr := _func_body(ses, "note_room")
	_check(not nr.is_empty(), "★ PvpSession 缺 note_room()(记房号 + 记模式的唯一入口)")
	# - 四条缺一不可:核心关键点是清凭据那一条 —— 少了它,一个
	#   `if code != room_code or mode != room_mode: pass` 的实现能过另外三条,而"清凭据"全仓只有这里守。
	_check(nr.contains("code != room_code") and nr.contains("mode != room_mode")
			and nr.contains("clear_rejoin()") and nr.contains("room_code = code"),
			"★ note_room() 必须「换了房号**或换了模式** ⇒ **清掉凭据**、再把新房号/模式记上」——"
			+ "漏掉模式那一半 = 同号的另一模式房被当成我的房;漏掉 clear_rejoin() = 承重的「清凭据」"
			+ "行为无人守(`if …: pass` 的实现能过前三条)")
	_check(nr.contains("room_mode = mode"), "★ note_room() 必须把模式记进 room_mode")
	var crt := _func_body(ses, "can_rejoin_to")
	_check(crt.contains("room_code == code") and crt.contains("room_mode == mode"),
			"★ can_rejoin_to() 必须同时比对房号与模式")
	_check(not ses.contains("func enter_mode"), "★ enter_mode() 已删除(合一后没有三个菜单按钮了)")


# ── §⑤ mp_lobby 的接线(重连返回对局入口 + I2 的第二个条件)──
func _check_rejoin_ui_wiring() -> void:
	var mm := _code(_read(MAIN_MENU))
	_check(not mm.is_empty(), "读不到 %s" % MAIN_MENU)
	# 主菜单的联机入口(2026-10-03 三合一后只剩一颗「多 人 模 式」)必须走 reset()
	# (每次进页复位 role/spawn/地址),而 reset() 不得碰凭据 —— 那四行 2026-09-22 删掉的
	# 纪律原样成立。
	# - 判定条件限定在 `_wire_menu` 函数体内：若仅全局检索文件文本，
	#   即使按钮回调中遗漏 reset() 调用也可能因其他位置的调用而导致测试假阳性。
	var btns := _func_body(mm, "_wire_menu")
	_check(btns.count("PvpSession.reset()") >= 1, "★ 主菜单联机入口未走 PvpSession.reset()")
	_check(not mm.contains("PvpSession.enter_mode("), "★ 主菜单仍在调已删除的 enter_mode()")

	var lp := _code(_read(LOBBY_PAGE))
	var try_body := _func_body(lp, "try_rejoin_row")
	# 注意事项：判定条件精确匹配 `if not in_match`：避免仅匹配参数名而因签名行命中导致断言假阳性。
	_check(try_body.contains("can_rejoin_to(code, mode)") and try_body.contains("if not in_match"),
			"★ LobbyPage.try_rejoin_row() 少了 in_match 那一问(I2):自己那间**还没开局**的房会走回局,"
			+ "而大厅侧没有它的凭据 ⇒ 玩家看到一句与眼前这间房无关的「凭据失效」,普通加入还不发生")
	# mp_lobby 把三条列房应答都汇进 `_ingest_rooms` -> `_redraw_cards` -> `_make_card`,
	# 「重连返回对局那一行」的两问(是不是我的房 / 把 in_match 传进去)收在 `_make_card` 一处。
	var card := _func_body(_code(_read(PAGE_MP)), "_make_card")
	_check(not card.is_empty(), "读不到 mp_lobby 的 _make_card 函数体(回局入口两条断言无从成立)")
	_check(card.contains("try_rejoin_row(code, in_match, mode)"),
			"★ mp_lobby 的 _make_card 调 try_rejoin_row 时没把 in_match 传进去(I2)")
	_check(card.contains("can_rejoin_to(code, mode)"),
			"★ mp_lobby 的 _make_card 不再问「这一行是不是我的房」(回局入口那一半没了)")
	# 记房号统一走 note_room(别再自己写 `PvpSession.room_code = …`)
	for fn in ["_on_room_created", "_on_room_joined", "_on_room_state_royale", "_on_room_state_team"]:
		var t := _func_body(_code(_read(PAGE_MP)), fn)
		_check(t.contains("PvpSession.note_room("),
				"★ mp_lobby 的 %s 未走 PvpSession.note_room()(记房号 + 作废上一间凭据的唯一入口)" % fn)
	_check(_func_body(_code(_read(PAGE_MP)), "_join_code").contains("_join_pending"),
			"★ mp_lobby 的 _join_code 未把房号**暂存**到 _join_pending(I1):写在发 RPC 之前的话,"
			+ "一次失败的加入会把 room_code 留成**别人的**那间房,自己那间房这一行此后永远是灰的")


# ── §⑥ 存活检测防御性校验的常驻源码断言(I3)──
# - 为什么必须在这里:`tests/probe/rpc_liveness_probe` 的扫描面是 `server/` + `core/net/`,
#   `scenes/` 不在里面(那个文件头照实登记了)。于是客户端这四条存活检测的防御性校验
#   —— K 键 ×2(royale/3v3 的自杀脱困)与 `send_ping` —— 一条自动化测试探针都没有:
#   删掉存活检测不会让任何测试变红,而它要防的是那条 `Unable to send packet on channel 0, max channels: 0`
#   (往 ENet 已拆掉的 peer 发定向可靠包)。与上面的重连返回对局接线断言同一形状:按函数体判。
func _check_liveness_guards() -> void:
	var ping_body := _func_body(_code(_read(NETBUS)), "send_ping")
	_check(ping_body.contains("can_send_to_server()"),
			"★ NetBus.send_ping() 丢了判活 —— 它是每 0.5s 一次的周期发送,离场那几帧必报 channel 0")
	for pair in [[GAME_ROYALE, "royale_game"], [GAME_TEAM, "team_game"]]:
		var body := _func_body(_code(_read(pair[0])), "_unhandled_input")
		_check(body.contains("NetBus.can_send_to_server()") and body.contains("suicide_request"),
				"★ %s 的 K 键自杀(_unhandled_input)丢了判活 —— 定向可靠包发往已拆掉的 peer" % pair[1])
