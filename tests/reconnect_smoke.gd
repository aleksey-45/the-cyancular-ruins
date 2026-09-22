extends SceneTree

# 重连协议的**源码级**契约冒烟:
#   ① 三条新 RPC + 3v3 的八条 `team_*` 必须住在 NetBusExt,**且 NetBus 里一个都不许有**
#      (放错节点 = 静默 no-op;3v3 那八条见文件末「3v3 团队协议」一节)
#   ② 三者的 **@rpc 注解**必须逐字正确(注解错了 = RPC 静默不通,与放错节点同款静默)
#   ③ PvpSession 的凭据字段在位(重连/回局都要靠它们)
#   ④ ★★ **回局凭据的生死线**(2026-09-22 按 C1 整条重写,**原第 ④ 条是反的**):
#      凭据必须**活过"回主菜单 → 再进大厅页"**(那正是路径乙的意义),只在
#        · 换模式(`enter_mode` 里 `mode` 变了)
#        · 大厅答"回不去了" / 回局超时(`clear_rejoin` 的另外两个调用点)
#        · 玩家进了**另一间**房(`note_room`)
#      时作废。§「凭据的生死线」那一节逐条钉住,连"主菜单那三个按钮走 `enter_mode`"一起。
#   ⑤ `try_rejoin_row` 的两个条件(是我的房 + 凭据还在 + **这一行是对局中**)
#   ⑥ **四条新判活守卫**的常驻源码断言(§6;I3:`tests/rpc_liveness_probe` 的扫描面
#      **不含 `scenes/`**,K 键那两条与 `send_ping` 此前零守卫)
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/reconnect_smoke.gd
# 通过 = `RECONNECT SMOKE OK` 退出 0。
#
# ★★ **原来的第 ④ 条是反的,而且它把 C1 钉在了原地**:它断言 `reset()` **必须**清
#   `room_code` / `rejoin`,理由写的是"下一局会拿着上一局的房号去问这行是不是我的房"。
#   而 `reset()` 正是主菜单那三个联机按钮调的那个函数 ⇒ 玩家从对局回主菜单、再按同一个模式
#   进来时,凭据**正好在那一拍**被抹掉 ⇒ 回局入口在生产里**永远不可达**
#   (自己那间"对局中"的房恒为灰)。整支终审 2026-09-22 定性为 Critical。
#   ⇒ 本文件现在是**反向**断言:`reset()` **不许**碰凭据(见 `_check_rejoin_lifecycle`)。
#   ★ 教训(别再犯):一条"某函数必须清某字段"的断言,要连**那个函数被谁调**一起看 ——
#     这条守卫的错不在断言本身,而在它把一个"进页复位"函数当成了"下车清理"函数。
#
# ═══ 为什么是源码级 ═══
# ★ RPC 放错节点**不会报错**:原 NetBus 与原版服务端逐字节一致是硬纪律,而 NetBusExt 对
#   原版 worker 不存在 → 放错的 RPC 静默丢弃、优雅降级。症状是"重连永远失败"却一行错都不打。
#   同款先例:weapon_spawned/weapon_removed 的 node 归属由 tests/net_ground_probe 双向钉住
#   (**缺了要红、多了也要红**)。这里照抄那条纪律。

const NETBUS := "res://core/net/net_bus.gd"
const NETBUS_EXT := "res://core/net/net_bus_ext.gd"
const SESSION := "res://core/net/pvp_session.gd"
const LOBBY_PAGE := "res://scenes/lobby_page.gd"
const MAIN_MENU := "res://scenes/main_menu.gd"
const PAGE_1V1 := "res://scenes/matchmaking.gd"
const PAGE_ROYALE := "res://scenes/royale_lobby.gd"
const PAGE_TEAM := "res://scenes/team_lobby.gd"
const GAME_ROYALE := "res://scenes/royale_game.gd"
const GAME_TEAM := "res://scenes/team_game.gd"

# 本次新增的三条:必须在 Ext,不得在 NetBus
const N_EXT_RPCS := ["session_token", "report_token", "reclaim_role"]

# 这三条各自的 @rpc 注解(**逐字**要求)—— 决定它能不能被路由的那一行。
# ★ 节点归属对了、注解错了,冒烟照样恒绿而功能坏掉:
#   `report_token` 若写成 `authority`,客户端上行会被直接拒(authority = 只许服务器调),
#   症状是"重连时 token 永远报不上去"且一行错都不打 —— 正是本文件要拦的那类静默 no-op。
#   session_token 反向同理:写成 any_peer = 任何人都能伪造 token 下发。
const N_EXT_RPC_ANN := {
	"session_token": "@rpc(\"authority\", \"reliable\")",
	"report_token": "@rpc(\"any_peer\", \"reliable\")",
	"reclaim_role": "@rpc(\"any_peer\", \"reliable\")",
}

# ── 3v3 团队协议(2026-09-19,B 册 Task 2)──
# 八条 `team_*`:六条上行(any_peer)+ 两条下发(authority)。与重连那三条**同款纪律**:
# 必须在 NetBusExt、**不得**在 NetBus(挂错节点 = 静默 no-op)。
const N_TEAM_RPCS := ["team_create", "team_join", "team_pick", "team_leave", "team_start",
		"team_list", "team_rooms", "team_room_state"]

# 注解同样逐字钉住 —— ★ 方向写反是**静默**的:`team_rooms` 若写成 any_peer = 任何客户端都能
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

# ── 回大厅后回局(阶段 2-B,2026-09-21)──
# 两条:一条上行(客户端 → 大厅)、一条下发(大厅 → 客户端)。与上面那些**同款纪律**:
# 必须在 NetBusExt、**不得**在 NetBus(挂错节点 = 静默 no-op,而症状只是"回局永远失败")。
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


# 剥掉 `#` 注释与字符串外的空白,只留代码本体 —— 否则注释里提到的方法名会假绿
func _code(text: String) -> String:
	var out := ""
	for line in text.split("\n"):
		var i := line.find("#")
		out += (line if i < 0 else line.substr(0, i)) + "\n"
	return out


# 该文件里有没有 `func <name>(` 定义
func _defines(code: String, name: String) -> bool:
	return code.contains("func %s(" % name)


# `func <name>(` **上方紧邻的非空行** = 它的注解。
# 注解与 func 之间可能夹空行/注释行(注释行已被 `_code` 打成空行),故向前跳过空行。
# 若这行注解被删掉,返回的就是上一行的代码文本 —— 与期望串不等,照样红(不是静默恒绿)。
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

	# ★ 注解:节点归属对了还不够 —— 决定 RPC 能不能被路由的就是这一行
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
	# ★ **双向**:只断言"在 NetBusExt 里有"会让"两边各抄一份"照样绿,而那正是静默 no-op 的成因
	#   (先例 `beam_fired`:NetBus / NetBusExt 各一份,接收端挂错节点 = 包到了没人接)。
	for n in N_TEAM_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)

	# 八个信号也要在(大厅/客户端都靠信号解耦)
	for s in N_TEAM_SIGNALS:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)

	# 注解:上行 6 条 any_peer / 下发 2 条 authority(**逐字**)
	for n in N_TEAM_RPC_ANN:
		var tann := _rpc_ann(ext, n)
		_check(tann == N_TEAM_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_TEAM_RPC_ANN[n], tann])

	# ── 回局协议的两条(阶段 2-B)──
	for n in N_REJOIN_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)
	for s in N_REJOIN_SIGNALS:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)
	# ★ 方向写反是**静默**的:`rejoin_denied` 若写成 any_peer = 任何客户端都能伪造"你的对局结束了";
	#   `rejoin_request` 若写成 authority = 客户端的上行被直接拒("按钮点了没反应")。
	for n in N_REJOIN_RPC_ANN:
		var rann := _rpc_ann(ext, n)
		_check(rann == N_REJOIN_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_REJOIN_RPC_ANN[n], rann])

	# ── 回局支路的**生产接线**(阶段 2-B Task 6)──
	# ★ 为什么这几条必须在这里:回局那几件生产方式**没有任何探针走过** —— `try_rejoin_row` /
	#   `_request_rejoin` / `_on_rejoin_denied` / `_tick_rejoin_timeout` 在今天全仓**零调用**
	#   (行渲染与行按下是 Task 7,真链路是 Task 8)。于是下面这两种删法**一行报错都不会有**:
	#     · `_finish_lobby_ready` 里那行 connect 删掉 ⇒ 大厅答的 `rejoin_denied` 没人接 ⇒
	#       凭据永不清、那一行**永远可点**、每次点都是同一句失败;
	#     · 三页 `_process` 里那条梯删掉 ⇒ 15s 兜底**根本不存在**,玩家停在一句"正在回到对局…"上。
	#   ★ 两条都按**函数体**判:全文件 `contains` 会被别处的同名调用喂绿(本仓的老毛病,
	#     先例 = `team_room_smoke` ⑨②"按函数体判而不是全文件 contains")。
	for p in [LOBBY_PAGE, "res://scenes/matchmaking.gd", "res://scenes/royale_lobby.gd",
			"res://scenes/team_lobby.gd"]:
		_check(not _read(p).is_empty(), "读不到 %s" % p)
	_check(_func_body(_code(_read(LOBBY_PAGE)), "_finish_lobby_ready").contains(
			"NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)"),
			"★ LobbyPage._finish_lobby_ready() 未接 `local_rejoin_denied` —— 大厅答「回不去」时凭据永不清、那一行永远可点")
	for p in [PAGE_1V1, PAGE_ROYALE, PAGE_TEAM]:
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


# ══════════════════════════════════════════════════════════════════════════════
# §④ 回局凭据的**生死线**(2026-09-22,按 C1 重写)
# ══════════════════════════════════════════════════════════════════════════════
# ★★ 本节的立场与原第 ④ 条**相反**:原断言要求 `reset()` 清凭据,而 `reset()` 正是主菜单那三个
#    联机按钮调的那个函数 ⇒ 玩家从对局回主菜单、再按同一个模式进来时凭据正好在那一拍被抹掉
#    ⇒ 回局入口在生产里**不可达**(C1)。现在钉的是:
#      · `reset()` **不许**碰凭据(进页复位 ≠ 下车清理);
#      · 凭据只在**换模式**(`enter_mode` 的 `mode` 判别)、大厅拒绝/超时(`clear_rejoin`
#        另外两个调用点)、以及**换了一间房**(`note_room`)时作废。
# ★ 全部按**函数体**判(全文件 `contains` 会被别处同名调用喂绿 —— 本仓老毛病)。
func _check_rejoin_lifecycle(ses: String) -> void:
	var reset_body := _func_body(ses, "reset")
	_check(not reset_body.is_empty(), "PvpSession 里找不到 func reset()")
	_check(not (reset_body.contains("token = \"\"") or reset_body.contains("worker_port = 0")
			or reset_body.contains("room_code = \"\"") or reset_body.contains("rejoin = false")),
			"★★ PvpSession.reset() 又清起回局凭据了 —— 主菜单那三个联机按钮每按一次就调它一次,"
			+ "清了就是「回到对局后自己那间房是灰的、回不去」(C1:整条路径乙在生产里不可达)")
	_check(not reset_body.contains("clear_rejoin()"),
			"★ PvpSession.reset() 调了 clear_rejoin()(同上一款:进页复位 ≠ 下车清理)")
	_check(reset_body.contains("map_path = \"\""),
			"PvpSession.reset() 未清 map_path(换局会漏上一局的地图;进页该复位的仍是它)")

	_check(ses.contains("static var mode"),
			"★ PvpSession 缺 static var mode —— 它是「该不该因模式切换作废凭据」的判别器:"
			+ "三张注册表的房号共用同一个 4 位空间,不判模式时 1v1 的凭据会让**同号的 3v3 房**看起来像「我的房」")
	var em := _func_body(ses, "enter_mode")
	_check(not em.is_empty(), "★ PvpSession 缺 enter_mode()(主菜单那三个模式按钮的唯一入口)")
	_check(em.contains("if mode != m:") and em.contains("clear_rejoin()"),
			"★ enter_mode() 必须**只在换模式时**作废凭据 —— 少了 `if mode != m:` 那一问 = 同模式重进也清,"
			+ "C1 当场复发(而症状只是「自己那间房是灰的」)")
	_check(em.contains("reset()"), "★ enter_mode() 未走 reset()(role/spawn/map_path 就没人复位了)")

	var nr := _func_body(ses, "note_room")
	_check(not nr.is_empty(), "★ PvpSession 缺 note_room()(三页记房号的唯一入口)")
	_check(nr.contains("clear_rejoin()") and nr.contains("room_code = code"),
			"★ note_room() 必须「换了房号 ⇒ 清掉上一间的凭据,再把新房号记上」(漏了清 ="
			+ "上一局的 token 配着这一间的房号,点那一行只会收到一句与眼前这间房无关的拒绝)")


# ── §⑤ 三页的接线(回局入口 + I2 的第二个条件)──
func _check_rejoin_ui_wiring() -> void:
	var mm := _code(_read(MAIN_MENU))
	_check(not mm.is_empty(), "读不到 %s" % MAIN_MENU)
	var buttons := _func_body(mm, "_build_menu_buttons")
	# 三个按钮**各按各的模式**进页 —— 少一个/写错模式 = 换模式时凭据不清(串模式)
	for pair in [["PvpSession.MODE_PVP", "res://scenes/matchmaking.tscn"],
			["PvpSession.MODE_TEAM", "res://scenes/team_lobby.tscn"],
			["PvpSession.MODE_ROYALE", "res://scenes/royale_lobby.tscn"]]:
		_check(buttons.contains("PvpSession.enter_mode(%s)" % pair[0])
				and buttons.contains(pair[1]),
				"★ 主菜单缺「enter_mode(%s) → %s」那一支(模式判别器就断了)" % [pair[0], pair[1]])
	_check(not buttons.contains("PvpSession.reset()"),
			"★★ 主菜单又出现裸的 PvpSession.reset() —— 它就是 C1:进页时不复位凭据,"
			+ "从对局回主菜单再按同一模式时凭据被抹掉,自己那间房恒为灰")

	var lp := _code(_read(LOBBY_PAGE))
	var try_body := _func_body(lp, "try_rejoin_row")
	# ★★ 判据写 `if not in_match`,**不写 `in_match`**:参数名本身就在函数签名行里,而签名行属于
	#    `_func_body` 的返回 ⇒ 只判名字的话,把整个守卫删掉照样绿(变异实测踩到,本仓
	#    "守卫的变异让它自己全绿"那一类)。断的必须是**那一问**。
	_check(try_body.contains("can_rejoin_to(code)") and try_body.contains("if not in_match"),
			"★ LobbyPage.try_rejoin_row() 少了 in_match 那一问(I2):自己那间**还没开局**的房会走回局,"
			+ "而大厅侧没有它的凭据 ⇒ 玩家看到一句与眼前这间房无关的「凭据失效」,普通加入还不发生")
	for pair in [[PAGE_1V1, "_on_room_list", "1v1"], [PAGE_ROYALE, "_on_royale_rooms", "大乱斗"],
			[PAGE_TEAM, "_on_team_rooms", "3v3"]]:
		var body := _func_body(_code(_read(pair[0])), pair[1])
		_check(body.contains("try_rejoin_row(code, in_match)"),
				"★ %s 的 %s 调 try_rejoin_row 时没把 in_match 传进去(I2)" % [pair[2], pair[1]])
		_check(body.contains("can_rejoin_to(code)"),
				"★ %s 的 %s 不再问「这一行是不是我的房」(回局入口那一半没了)" % [pair[2], pair[1]])
	# 三页记房号**统一**走 note_room(别再各自写 `PvpSession.room_code = …`)
	for pair in [[PAGE_1V1, "_on_room_created"], [PAGE_1V1, "_on_room_joined"],
			[PAGE_ROYALE, "_on_room_state"], [PAGE_TEAM, "_on_room_state"]]:
		var t := _func_body(_code(_read(pair[0])), pair[1])
		_check(t.contains("PvpSession.note_room("),
				"★ %s 的 %s 未走 PvpSession.note_room()(记房号 + 作废上一间凭据的唯一入口)"
				% [pair[0].get_file(), pair[1]])
	_check(_func_body(_code(_read(PAGE_1V1)), "_join_code").contains("_join_code_pending"),
			"★ 1v1 的 _join_code 未把房号**暂存**到 _join_code_pending(I1):写在发 RPC 之前的话,"
			+ "一次失败的加入会把 room_code 留成**别人的**那间房,自己那间房这一行此后永远是灰的")


# ── §⑥ 判活守卫的常驻源码断言(I3)──
# ★ 为什么必须在这里:`tests/rpc_liveness_probe` 的扫描面是 `server/` + `core/net/`,
#   **`scenes/` 不在里面**(那个文件头照实登记了)。于是客户端这四条判活的守卫
#   —— K 键 ×2(royale/3v3 的自杀脱困)与 `send_ping` —— **一条常驻守卫都没有**:
#   删掉判活不会让任何测试变红,而它要防的是那条 `Unable to send packet on channel 0, max channels: 0`
#   (往 ENet 已拆掉的 peer 发定向可靠包)。与上面的回局接线断言同一形状:按**函数体**判。
func _check_liveness_guards() -> void:
	var ping_body := _func_body(_code(_read(NETBUS)), "send_ping")
	_check(ping_body.contains("can_send_to_server()"),
			"★ NetBus.send_ping() 丢了判活 —— 它是每 0.5s 一次的周期发送,离场那几帧必报 channel 0")
	for pair in [[GAME_ROYALE, "royale_game"], [GAME_TEAM, "team_game"]]:
		var body := _func_body(_code(_read(pair[0])), "_unhandled_input")
		_check(body.contains("NetBus.can_send_to_server()") and body.contains("suicide_request"),
				"★ %s 的 K 键自杀(_unhandled_input)丢了判活 —— 定向可靠包发往已拆掉的 peer" % pair[1])
