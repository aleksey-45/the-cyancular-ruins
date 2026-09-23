extends Node

# 回局真链路探针的**观察者**(每端一个,挂在 root 上;换场不会把它带走)。
# 三端各跑一条剧本:
#   c1 = actor:建房 → 开局 → 进 pvp_game → 到 PLAYING → **ESC + 点「回到主菜单」** →
#        **按主菜单上那颗「1 v 1」**(生产入口)→ 在房间列表里点自己那间房那一行 → 回到**原局**。
#        断言四条(见 `_tick_c1` 的相 3):
#          ⓪ 那一行**可点**(`disabled == false`)—— ★ 这是**新入口本身**的断言:前置计划交付的行为是
#             "对局中的房一律 disabled",而回局这一档要在**同一行**上把它翻过来。少了这一条,
#             "次序写反"(先按 in_match 禁用)会以"c1 一直点不动 → 超时"的形式表现,与"回局坏了"分不开。
#          ① 回局后进了 `pvp_game`;
#          ② `PvpSession.role` 与离开前**一致**(大厅把凭据里的 role 发对了);
#          ③ **重新收到服务器广播**(PLAYING 的 `round_state` 计数严格增长)—— 这是"真的回到
#             那一局"的唯一客观证据:离场期间客户端断着、一条广播都收不到。
#        ★ 不拿 instance_id 做断言:路径乙**会重建场景**,节点 ID 必然不同 —— 服务端那具身体
#          确实没销毁,但客户端**观测不到**它,写成断言就是伪断言。服务端身体未销毁由
#          `tests/reconnect_probe` 相①(路径甲,不重建场景)钉住。
#        ★★ **两次进场都走生产入口** = 按主菜单上那颗「1 v 1」(`main_menu.gd` 里
#          `PvpSession.enter_mode(MODE_PVP)` + `change_scene_to_file(matchmaking.tscn)`),
#          再由**生产那条 `change_scene_to_file`** 建出真大厅页 —— 本端只在页 `_ready` **之前**
#          预置"已连着本探针大厅"(`_on_node_added`;生产连的是默认端口 7777,本探针不能碰)。
#        ★★★ 这里**曾经**写着「主菜单那几步只是换场,不承载判据」并用 `_attach_page_in`
#          **直接挂页** —— 那句话是**错的**,而且正好错在承重的那一步:主菜单那三个联机按钮
#          的 `PvpSession.reset()` **就是**抹掉回局凭据的那一步(C1)。于是整条测试链
#          (包括本探针自己的那条"自己那间房那一行必须可点")在**生产里根本回不去的实现**上
#          一直全绿 —— 唯一会红的观测者绕过了唯一会红的那一步。
#          ⇒ **别再绕过主菜单**;要改这条路径,先想清楚"凭据是在哪一拍没的"。
#   c2 = 对手:点列表加入 → 进 pvp_game → **在场上留满一个观察窗**(`C2_OBSERVE`),然后才落盘。
#        ★ brief 把 c2 定位成"这一局还在的见证",但**没有给它任何断言**(进了局就 `_finish`,
#          零条断言也算 OK)。这里补四条**它自己能观测**的:在场并看到 PLAYING / 掉线者的身体
#          每一帧都在权威快照里(身体不销毁)/ 观察窗内一直是 PLAYING 且局号未变(没有重启过一局)
#          / 快照连续。没有这几条,c1 那边"回到的是**同一局**"就没有第二个人作证。
#   c3 = 第三人:**只连大厅**:①列表里看得见这个房(in_match=true)②加入被拒。
#        ★ ② 是用户点名的要求("C 可以看到 A 与 B 的房间,尽管无论在对战还是掉线 C 都不应该进去")
#          —— 服务端的 `join_room` 守卫由这一条在**真链路**上验一次。
#        ★ 它同时是 c1 那一行的**反向对照**:同一行、同一份载荷,c3 手里没有凭据 ⇒ 客户端不该
#          把它变可点(本端断言:那一行 `disabled == true`)。
# 失败时把结果写进 `user://rejoin_probe_<who>.result`(子进程 stdout 父进程看不到)。
#
# ★ 与 team_match_watcher 同款的两条纪律:
#   ① **先置位再入树**:大厅页 `_ready` 会 deferred 跑一次 `_request_list`,只有"已连同地址"
#      那一支会复用现有连接(否则它会 `NetBus.stop()` 并按默认端口 7777 重连 —— 那是**用户自己的
#      服务端**,本探针明确规定不碰)。
#   ② 页挂在**探针场景**下(不是本节点下):换场时它随探针场景一起被 free —— 那正是生产的形状。
#
# ═══ ★ 与 task-8-brief.md 的偏离(逐条;理由都在实现处再写一遍)═══
#   ① **c2 的加入触发条件**:brief 写的是 `_room_code != ""` 才点行,而 `_room_code` 只在
#      `local_room_created` 里赋值 —— 那条信号**只有建房者(c1)收得到**,c2 恒为空串 ⇒
#      c2 **永远不加入** ⇒ 房永远凑不齐两人 ⇒ 整跑在 40s 的 `BOOT_TIMEOUT` 上红。改成"列表里
#      有可点的行就点"。
#   ② **周期刷新列表**(三个角色都要):房间列表是**请求/响应**式的,而挂页时那 1~2 次请求
#      通常落在"房还没建 / 对局还没开"之前,之后**再也不会有列表到达** —— c2 看不到房、c3 看不到
#      `in_match`(它只在 in_match 那一行上才动手,故早刷新不会误入房)。梯节拍沿用
#      `team_match_watcher._tick_lobby_join` 的 1.5s,并且**只在连接活着时发**(绝不让页走到
#      "未连 → 重连默认端口 7777"那一条)。
#   ③ **本端自己维持与大厅(29300)的连接**,页不许自己去连(生产里那一步是"页 `_ready` →
#      `_with_lobby` → `NetBus.start_client(addr)`,端口取**默认 7777**;本探针的大厅在池外
#      29300,照那条走会去连用户的 7777 并且永远连不上)。手法:`_on_node_added` 在页 `_ready`
#      **之前**预置 `_connected/_connected_addr`(**并把 `PvpSession.server_address` 拨回本探针大厅**
#      —— 主菜单按钮里的 `enter_mode()` 会 `reset()` 成云默认,而页的地址框拿它做初值),
#      于是页的 `_request_list` 走**已连快路**;万一还是走了慢路(预置没赶上),`_drive_to_lobby_page`
#      有一条兜底修复(重连 29300 + 把地址框拨回来),两条路都不碰 7777。
#   ④ `_page` 一律用 `is_instance_valid` 判死活(brief 在 `_tick_c2` 里只判 `== null`):
#      换场后 `_page` 是**已释放对象**,对已释放对象取字段会抛
#      `Invalid access … previously freed`(本仓实测踩过,见 team_match_watcher 文件头)。
#   ⑤ `_rec` 的读数**要活到结果文件里**(brief 的 `_finish` 用 WRITE 打开结果文件 → 之前 `_rec`
#      写进去的行全被截掉,读日志的人拿不到任何中间读数)。
#   ⑥ c3 那条"看到了对局中的房"原来是 `_fail(...)` 后紧跟一条**无条件** `_ok(...)` —— 同一件事
#      同时进失败账本和成功账本,输出自相矛盾。改成 if/else。
#   ⑦ 每条判词的断言计数(`_checks` + `MIN_CHECKS_*`):被截断的跑不许打印 OK。

const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 60.0      # 从挂页到"进 pvp_game 且到 PLAYING"
const MENU_TIMEOUT := 25.0       # 按下主菜单那颗模式按钮 → 生产路径把大厅页建出来
const MENU_BTN_TEXT := "1 v 1"   # 与 main_menu.gd 的文案逐字一致
const PLAY_SETTLE := 3.0         # PLAYING 后静置(让快照跑起来,身体有个明确的位置读数)
const REJOIN_TIMEOUT := 30.0     # 点了自己那行之后等回到 pvp_game
const RESULT_WAIT := 40.0        # c3 等"一个不会来的 room_joined"的上限
const REFRESH_EVERY := 1.5       # 大厅页列表刷新节拍(见文件头偏离②)
const C2_OBSERVE := 40.0         # c2 的观察窗(PLAYING 之后;覆盖 c1 的离场 + 回局)
const C2_SNAP_GAP_MAX_MS := 1500.0

# 一条**绿**的跑至少要跑到的断言数(只对"否则会打印 OK"的那一跑生效,见 `_finish`)。
#   c1 = 4(行可点 / 进了对局 / role 一致 / 广播恢复)
#   c2 = 4(在场见 PLAYING / 对手身体一直在 / 局没变 / 快照连续)
#   c3 = 3(看得见 / 同一行对第三人仍禁用 / 加入被拒)
const MIN_CHECKS := {"c1": 4, "c2": 4, "c3": 3}

var who := ""
var lobby_port := 29300

var _page: Node = null
var _game: Node = null
var _t := 0.0
var _phase := 0
var _phase_t := 0.0
var _done := false
var _fails: Array[String] = []
var _recs: Array[String] = []
var _checks := 0
var _body_id_before := 0
var _playing_seen := false        # 已收到服务器广播的 PLAYING(state==1)
var _playing_count := 0           # PLAYING 广播的累计条数(回局后必须严格增长)
var _playing_at_leave := 0        # 离场那一刻的计数(回局后拿它比对)
var _role_before := 0             # 离场前的 role(回局后不许变)
var _joins := 0                   # c3:收到 room_joined 的次数
var _go_match := 0                # c3:收到 go_match 的次数
var _server_msgs: Array[String] = []
var _room_rows := -1              # c3:最近一次列表里"对局中"的行数
var _room_code := ""
var _row_seen := false            # c1:自己那间房那一行已经出现在列表里
var _row_disabled := true         # c1:那一行的 `disabled`(新入口的断言:必须是 false)
var _c3_row_disabled := true      # c3:同一行的 `disabled`(反向对照:必须是 true)
var _refresh_t := 0.0
# c2 的观察读数(PLAYING 那一刻清零,窗口结束时统一判定)
var _obs_started := false
var _obs_t := 0.0
var _obs_round := -1
var _obs_state_bad := false
var _snap_last_ms := 0
var _snap_max_gap := 0.0
var _snap_total := 0
var _snap_with_opp := 0
# c2/c3 的兜底计时(等不到该等的东西时要**自己判红**,而不是让裁判只收到 2/3 份结果)
var _hard_t := 0.0
# c2/c3 落盘后**保持在线**(见 _finish:裁判还要继续观察这一局),只有 c1(actor)自己退。
var hold_alive := false
# c1:本端正在连大厅(页不许自己连,见文件头偏离③)。
# ★ **判据一律用 `NetBus.can_send_to_server()`**、不用"曾经连上过"的闩:ESC 回主菜单那条路会
#   `NetBus.stop()`(`PauseMenu.go_menu` 对 PvP 无条件断连),闩会停在 true 而连接已经没了。
var _lobby_back_connecting := false
# c1:主菜单那颗模式按钮按过了吗 / 页一就位要调的那个动作(首次=建房,回局=刷新)
var _menu_clicked := false
var _page_action: Callable = Callable()
var _page_action_done := false
# c1:`_on_node_added` 预置钩子命中了几次(读数:0 = 页是走上树**之后**才被接管的,走了兜底修复)
var _hook_hits := 0
var _repairs := 0


func _ready() -> void:
	hold_alive = who != "c1"
	if who == "c1":
		# ★ 生产入口那条路要靠这个钩子(理由见 `_on_node_added` / 文件头偏离③)
		get_tree().node_added.connect(_on_node_added)
		_lobby_back_connecting = true   # 下面的 start_client 正在连,别让重连路径插一脚
	NetBus.local_room_created.connect(func(code: String) -> void:
		_room_code = code
		_log("建房成功:%s" % code))
	NetBus.local_room_joined.connect(func(_role: int) -> void:
		_joins += 1
		_log("收到 room_joined(第 %d 次)" % _joins))
	NetBus.local_go_match.connect(func(_role: int, port: int) -> void:
		_go_match += 1
		_log("收到 go_match(第 %d 次,port=%d)" % [_go_match, port]))
	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_round_state.connect(_on_round_state)
	# c2 的"这一局还在"读数(见文件头 c2 那一段)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_server_message.connect(func(t: String) -> void:
		_server_msgs.append(t)
		_log("server_message: %s" % t))
	multiplayer.connected_to_server.connect(_on_lobby_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_lobby_back_connecting = false   # 放开重连路径(否则 `_reconnect_lobby` 永远早退)
		_fail("连大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port]))
	NetBus.start_client(LOBBY_ADDR, lobby_port)


func _on_lobby_connected() -> void:
	_lobby_back_connecting = false
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "lobby_name", "BOT%d" % (1 if who == "c1" else (2 if who == "c2" else 3)))
	if who == "c1":
		# ★ c1 **不直接挂页**:走生产入口(主菜单那颗模式按钮)—— 理由见文件头。
		_enter_main_menu.call_deferred()
		return
	_attach_page.call_deferred()


func _attach_page() -> void:
	_attach_page_in(get_tree().current_scene,
			(on_create if who == "c1" else on_refresh))


# ── c1:生产入口那两步(与 main_menu.gd 那颗「1 v 1」按钮逐字同路)──
# 换到主菜单。★ 生产里玩家从对局退出来就落在这里(`Level0.safe_change_scene` →
# `scenes/main_menu.tscn`),本端第一次进场也照这条路走(而不是把页挂进探针场景)。
func _enter_main_menu() -> void:
	_log("换到主菜单(生产入口从这里开始)")
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# 大厅页入树时(生产那条 `change_scene_to_file` 建出来的)**在它 `_ready` 之前**把两件事摆好:
#   ① `PvpSession.server_address = LOBBY_ADDR` —— 页的地址框拿它做初值,而主菜单按钮里的
#      `enter_mode()` 会 `reset()` 成云默认;
#   ② `_connected` / `_connected_addr` —— 让页的 `_request_list` 走"已连大厅"的**快路**。
# ★★ 为什么必须是 `node_added`:`_connected` 是页自己的私有变量、新建时恒 false,而页 `_ready`
#    末尾就把 `_request_list` 排进 deferred ⇒ 晚一拍(下一帧)再补就来不及了:页已经走了慢路
#    (`NetBus.stop()` 拆掉本端与 29300 的连接 + `start_client(addr)` **按默认端口 7777** 去连
#    用户自己的服务端)。`node_added` 早于 `_ready`,所以这两个值在这里设是**生效的**。
func _on_node_added(n: Node) -> void:
	if not (n is LobbyPage) or not n.has_method("_on_room_list"):
		return
	_hook_hits += 1
	PvpSession.server_address = LOBBY_ADDR
	var preset := not bool(n.get("_connected"))
	if preset:
		n.set("_connected", true)
		n.set("_connected_addr", LOBBY_ADDR)
	_rec("HOOK page#%d 预置已连=%s" % [_hook_hits, str(preset)])
	_log("大厅页入树(生产路径)→ 预置『已连着 %s:%d』=%s" % [LOBBY_ADDR, lobby_port, str(preset)])


# 把玩家带到**一份真的、已连上大厅的**大厅页前 —— 两次进场(开局前 / 回局前)共用,且
# **两次都走生产入口**。返回 true = `_page` 已就位且大厅连接可用。
# ★ 它**不实例化也不 add_child 页面**:页由主菜单那颗按钮里的 `change_scene_to_file` 建出来
#   (`get_tree().current_scene`),本端只是等它出现。
func _drive_to_lobby_page(first: bool) -> bool:
	if is_instance_valid(_page):
		return true
	if not NetBus.can_send_to_server():
		# ★ 必须先连上再让页入树:页的 `_with_lobby` 快路判据里有 `can_send_to_server()`,
		#   不成立时它会 `NetBus.stop()` + 按**默认端口 7777** 去连(用户自己的服务端)。
		_reconnect_lobby("先把大厅接回来再放页进来")
		return false
	var cs := get_tree().current_scene
	if not _menu_clicked:
		if not _is_main_menu(cs):
			return false       # 换场还没落到主菜单(第一次由 _on_lobby_connected 触发)
		_menu_clicked = true
		_page_action = (on_create if first else on_refresh)
		_page_action_done = false
		_phase_t = 0.0
		return _press_menu_mode_button()
	var p := _current_lobby_page(cs)
	if p == null:
		if _phase_t > MENU_TIMEOUT:
			# ★ 判词把**现场**一起带上("卡在哪一步"只能靠它 —— 本探针的失败读数只有 `_dump()`
			#   的**尾部 20 行**,别指望从别处反推)。
			_fail("c1 ★ 按下主菜单「%s」后 %.0fs 没等到大厅页(生产那条 change_scene 没落地?)"
					% [MENU_BTN_TEXT, MENU_TIMEOUT]
					+ ";现场:阶段 %d / 当前场景 %s / 页 %s / 连大厅=%s / 按过按钮=%s"
					% [_c1_sub, _script_path(cs), str(is_instance_valid(_page)),
						str(NetBus.can_send_to_server()), str(_menu_clicked)])
			_finish("")
		return false
	_page = p
	_page_bound = true
	_rec("PAGE 生产路径(hook=%d 重连=%d 已连=%s)" %
			[_hook_hits, _repairs, str(NetBus.can_send_to_server())])
	if not _page_action_done and _page_action.is_valid() and NetBus.can_send_to_server():
		_page_action_done = true
		_page_action.call()
	return true


# 按主菜单上那颗「1 v 1」(真按钮回调 = `enter_mode` + `change_scene_to_file`)。
# ★ 文案与 `main_menu.gd` 里逐字一致;找不到即判红(与"回局坏了"分得开)。
func _press_menu_mode_button() -> bool:
	var menu := get_tree().current_scene
	var btn := _find_button_text(menu, MENU_BTN_TEXT)
	if btn == null:
		_fail("c1 ★ 主菜单上找不到「%s」那颗按钮(还没换到主菜单?或菜单改了文案)" % MENU_BTN_TEXT)
		_finish("")
		return false
	_rec("MENU press «%s»" % MENU_BTN_TEXT)
	_log("按主菜单「%s」(生产入口:PvpSession.enter_mode + change_scene_to_file)" % MENU_BTN_TEXT)
	btn.pressed.emit()
	return true


func _find_button_text(root: Node, text: String) -> Button:
	if root == null:
		return null
	if root is Button and (root as Button).text.strip_edges() == text:
		return root
	for c in root.get_children():
		var b := _find_button_text(c, text)
		if b != null:
			return b
	return null


func _is_main_menu(n: Node) -> bool:
	return _script_path(n).ends_with("scenes/main_menu.gd")


func _current_lobby_page(n: Node) -> Node:
	# 三页共用基类;`_on_room_list` 只 1v1 页有(本探针的大厅是 1v1 那条路)
	if n is LobbyPage and n.has_method("_on_room_list"):
		return n
	return null


func _script_path(n: Node) -> String:
	if n == null:
		return ""
	var s: Variant = n.get_script()
	if s == null or not (s is Script):
		return ""
	return str((s as Script).resource_path)


# 把 `_page` 与换场对齐:页随旧场景一起被 free 掉之后,下一次进场要重新按按钮(生产入口)。
# ★ 只有"**曾经绑过、又被换场带走**"才复位 `_menu_clicked`;页还**没建出来**时不能复位 ——
#   否则每帧都会再按一次按钮(而按钮里是 `change_scene_to_file`)。
# ★★ "曾经绑过"必须用**自己的布尔** `_page_bound`,**不能**写 `_page != null` ——
#   实测(Godot 4.7.1;复现 = 三行:`var n := Node.new(); get_root().add_child(n); n.free()`
#   之后 `print(n != null)` 打的是 **false**):
#   **已释放对象的引用与 `null` 比较是 `true`**(`freed != null` → false、`freed == null` → true),
#   所以 `_page != null` 在页被换场带走之后**恒为 false** ⇒ `had` 恒 false ⇒ `_menu_clicked`
#   永不复位 ⇒ 回局那一相**永远按不下第二次按钮**,症状是"按下主菜单按钮后 25s 没等到大厅页"
#   (2026-09-22 实测踩到,读了三条读数才定位)。判"页还在不在"只有 `is_instance_valid()`。
var _page_bound := false

func _sync_page() -> void:
	if is_instance_valid(_page) and _page.is_inside_tree():
		return
	_page = null
	if _page_bound:
		_page_bound = false
		_menu_clicked = false   # 页是被换场带走的 ⇒ 下一次进场要重新按按钮(生产入口)


# 把一份**真**大厅页挂进当前场景(首次进场与 c1 回局前各一次,同一份实现)。
# ★ 三行"先置位再入树"(缺一不可):
#   ① `PvpSession.server_address = LOBBY_ADDR` —— `matchmaking.gd` 的地址框**默认值取的就是它**
#      (`ui_factory.line_edit(..., PvpSession.server_address)`),而 `_with_lobby` 的快路判据是
#      `_connected_addr == _addr_edit.text` ⇒ 不拨它,页 `_ready` 那次 deferred `_request_list`
#      会判"地址变了"→ `NetBus.stop()` + 按**默认端口 7777** 重连:本进程与探针大厅(29300)的
#      连接当场拆掉,而本探针明确规定不碰 7777(症状是"c1 从这一刻起什么都收不到")。
#   ② 同一行对**转连 worker** 也是必需的:`_do_go_match` 用 `PvpSession.server_address` 连 worker,
#      而 worker 就在 127.0.0.1 —— 不拨它,c1/c2 会去连**云地址**上的 29350(必失败)。
#   ③ `_connected` / `_connected_addr`:让页走"已连"的快路(本进程已经连上大厅了)。
func _attach_page_in(cs: Node, action: Callable) -> void:
	if cs == null or _page != null:
		return
	_page = load("res://scenes/matchmaking.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	_page.set("_connected", true)
	_page.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(_page)
	_log("真大厅页已挂载(%s)" % cs.name)
	action.call()


func on_create() -> void:
	_page.call("_on_create_pressed")


func on_refresh() -> void:
	_page.call("_on_refresh_pressed")


# 周期性点一次「刷新列表」(**真按钮回调**)。★ 见文件头偏离②:列表是请求/响应式的,挂页那
# 1~2 次请求常常落在"房还没建 / 对局还没开"之前;不补这一梯,c2 与 c3 会永远停在空列表上
# (brief 里没有这条梯)。
# ★ `can_send_to_server()` 那道闸不是可选的:页的 `_with_lobby` 在**未连**时会落到
#   `NetBus.start_client(addr)`(**默认端口 7777**)—— 那是用户自己的服务端,本探针不碰。
func _tick_refresh(delta: float, done: bool) -> void:
	if done or not is_instance_valid(_page) or not NetBus.can_send_to_server():
		return
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_EVERY
	_page.call("_on_refresh_pressed")


# 在房间列表里按**房号**找那一行(三页的按钮文案都是 `"房间 %s …" % code`,逐字对应)。
# ★ 找不到时调用方必须**立刻 FAIL**,不能静默等超时 —— 那种失败与"回局坏了"在输出上长得一样。
func _find_row_button(code: String) -> Button:
	if not is_instance_valid(_page) or _page.get("_list_box") == null or code == "":
		return null
	for c in _page.get("_list_box").get_children():
		if c is Button and (c as Button).text.begins_with("房间 %s" % code):
			return c
	return null


# 列表里第一个**可点的**行(房号未知时的退路;c2 用 —— 大厅是本进程起的,只有 c1 那一间房)。
func _first_row_button() -> Button:
	if not is_instance_valid(_page) or _page.get("_list_box") == null:
		return null
	for c in _page.get("_list_box").get_children():
		if c is Button and not (c as Button).disabled:
			return c
	return null


func _on_room_list(rooms: Array) -> void:
	# ★ 刷新梯的节拍**在收到列表这一拍重置**:下一拍再问是"这份是新的吗",不是"到点了吗"。
	_refresh_t = REFRESH_EVERY
	if who == "c1":
		# ★ c1 读的是那一行的**可点性**:手里的凭据就是"这一行是我的"的证明 ⇒ 必须可点。
		#   它只能在这里取 —— `disabled` 是客户端**渲染出来的 Button** 上的状态,载荷里没有这个字段。
		var mine := _find_row_button(_room_code)
		if mine != null:
			_row_seen = true
			_row_disabled = mine.disabled
			_rec("ROW code=%s disabled=%s" % [_room_code, str(_row_disabled)])
		return
	if who != "c3":
		return
	var in_match := 0
	for r in rooms:
		if typeof(r) == TYPE_DICTIONARY and bool(r.get("in_match", false)):
			in_match += 1
			_room_code = str(r.get("code", ""))
			_rec("ROW code=%s in_match=1 names=%s" % [_room_code, str(r.get("names", []))])
	_room_rows = in_match
	if in_match == 1:
		# ★ c3 读的是同一行的**另一半**:它**没有**凭据 ⇒ 必须不可点(`try_rejoin_row` 会返回 false
		#   走普通加入)。c1 与 c3 这两条合起来才说明"可点性"是**按人**判的,而不是"一律可点"。
		var row := _find_row_button(_room_code)
		if row != null:
			_c3_row_disabled = row.disabled
		if _phase == 0:
			# 看见了 → 立刻试图进去(必须被拒)
			_phase = 1
			_phase_t = 0.0
			_log("列表里看到对局中的房 %s → 试图加入(应当被拒)" % _room_code)
			_page.call("_join_code", _room_code)


# 服务器广播的回合状态。★ PLAYING 的判据取**服务器广播的 round_state**(state==1),不是本地
# `_round_locked` 的默认值 —— 后者在第一条 round_state 到达**之前**就是 false,照它判会在刚进
# 场景那一帧就"以为"开打了(`team_match_watcher` 用的是同一个读数)。
func _on_round_state(data: Dictionary) -> void:
	var st := int(data.get("state", -1))
	if st == 1:
		if not _playing_seen and who == "c2":
			# c2 的观察窗从**它自己**看到的第一条 PLAYING 起算(之前的窗口含建场景那一大段)
			_obs_started = true
			_obs_round = int(data.get("round", 0))
			_obs_t = 0.0
			_snap_last_ms = 0
			_snap_max_gap = 0.0
			_snap_total = 0
			_snap_with_opp = 0
		_playing_seen = true
		_playing_count += 1
		return
	# 非 PLAYING 的广播:观察窗内出现任何一条(换局 COUNTDOWN / 本局收场)**就是**"这一局变了"
	# (换局与收局都先广播 COUNTDOWN/ROUND_OVER,故判据只在这一条上)。
	if who == "c2" and _obs_started:
		_obs_state_bad = true


# c2 的"这一局还在"读数:权威快照的频率 + 掉线者的身体还在不在。
func _on_snapshot_world(world: Dictionary) -> void:
	if who != "c2" or not _obs_started:
		return
	var now := Time.get_ticks_msec()
	if _snap_last_ms > 0:
		_snap_max_gap = maxf(_snap_max_gap, float(now - _snap_last_ms) / 1000.0)
	_snap_last_ms = now
	_snap_total += 1
	var ps: Dictionary = world.get("players", {})
	if ps.has(str(3 - int(PvpSession.role))):
		_snap_with_opp += 1


func _physics_process(delta: float) -> void:
	if _done:
		return
	_refresh_game()          # ★ 每帧重认对局场景(离场再进 = 一具**全新**的节点树)
	_t += delta
	_phase_t += delta
	_hard_t += delta
	match who:
		"c1":
			_tick_c1(delta)
		"c2":
			_tick_c2(delta)
		"c3":
			_tick_c3(delta)


# 每帧重认对局场景。★ **绝不能缓存**:本端的剧本里游戏场景会连换三次
# (大厅 → pvp_game → 主菜单 → pvp_game),旧那具早被 `safe_change_scene` 退役掉,
# 对着已释放实例取字段会报 `Invalid access to property or key … on a base object of type
# 'previously freed'`。`_game` 为 null 表示"此刻不在对局里"(大厅页 / 主菜单 / 换场中间)。
func _refresh_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		_game = null
		return
	if cs.get("_local") == null:
		return     # 场景 `_ready` 还没跑完(局部玩家未就位)
	if _game != cs:
		_log("进入对局场景(role=%d)" % PvpSession.role)
	_game = cs


# 与 team_match_watcher._is_game 同款:按**脚本类型**认(名字会随场景改,类型不会)
func _is_game(n: Node) -> bool:
	return n is PvpMatchClient


# ── c1(actor)──
var _c1_sub := 0      # 0 建房/等开局 1 打一会 2 已按 ESC 回主菜单 3 已点自己那间房那一行
func _tick_c1(delta: float) -> void:
	# ★ 只看**总预算**,不看 `_page` 的死活:相 2 里本端**故意**要经历"页被换场带走 → 再走一次
	#   生产入口",把 `not is_instance_valid(_page)` 写进这条守卫会让相 2 永远进不去(总超时兜底)。
	#   各相自己的界(等列表 / 等回局)写在各自的 `_phase_t` 判据里。
	if _phase_t > ENTER_TIMEOUT + MENU_TIMEOUT + REJOIN_TIMEOUT + RESULT_WAIT:
		_finish("c1 超时(阶段 %d)" % _c1_sub)
		return
	_sync_page()
	match _c1_sub:
		0:
			# 进对局前那一份大厅页也**走生产入口**(理由见文件头:两次进场同一条路)。
			# ★ 页那一路**不是**推进条件:本相唯一的推进条件是"真进了对局场景"。
			#   把"页还不存在"也当成"不能推进"会让本相卡死 —— 页在进对局那一刻被换场带走,
			#   此后 `_drive_to_lobby_page(true)` 恒返回 false ⇒ ESC 那一步**永远不发生**
			#   (2026-09-22 实测踩到,与 `_sync_page` 那个 null 语义的坑同时发作)。
			_drive_to_lobby_page(true)
			if _game != null:
				_c1_sub = 1
				_phase_t = 0.0
				_rec("PHASE 0→1 进对局场景")
			return
		1:
			if _game != null and _playing_seen and _phase_t > PLAY_SETTLE:
				_body_id_before = int(_game.get("_local").get_instance_id())
				_playing_at_leave = _playing_count
				_role_before = int(PvpSession.role)
				_log("PLAYING 就位(role=%d,PLAYING 计数=%d);按 ESC 回主菜单" % [_role_before, _playing_at_leave])
				_rec("LEAVE role=%d plays=%d id=%d" % [_role_before, _playing_at_leave, _body_id_before])
				_esc_and_menu()
				_c1_sub = 2
				_phase_t = 0.0
			return
		2:
			# ★★ 回到主菜单之后**再走一次生产入口**(按那颗「1 v 1」按钮)—— 这一步就是 C1 的
			#    现场:从前本端在这里**直接挂页**,恰好绕过了"按钮 → `enter_mode` → 凭据还在不在"
			#    这一问 ⇒ 拿着生产里根本拿不到的凭据全绿(见文件头那条纠正)。
			if _game != null:
				return                    # 还在对局场景里(换场还没发生)
			if not _drive_to_lobby_page(false):
				return
			_tick_refresh(delta, _row_seen)
			if not _row_seen:
				if _phase_t > ENTER_TIMEOUT:
					_fail("c1 ★ 回到大厅页后 %.0fs 没在列表里看到自己那间房(%s)" % [ENTER_TIMEOUT, _room_code])
					_finish("")
				return                    # 列表还没到
			var row := _find_row_button(_room_code)
			if row == null:
				# ★ 立刻 FAIL,不静默等超时(那种失败与"回局坏了"长得一样)
				_fail("c1 ★ 列表里没有自己那间房那一行(code=%s)—— 显示方案那一半坏了?" % _room_code)
				_finish("")
				return
			if row.disabled:
				# ★★ 这一条就是**新入口本身**:同一个房、同一份载荷,别人(见 c3)看到的是
				#    disabled,而**手里有凭据的本人**必须可点。它有两种成因,判词两个都点名:
				#      ① 次序写反(先按 in_match 禁用)—— 前三页渲染那一半;
				#      ② **凭据在半路上没了**(C1:主菜单那颗按钮把 `token/worker_port/room_code`
				#         一起清了)⇒ `can_rejoin_to` 恒 false。★ 这一条正是 C1 的验收断言:
				#         把凭据清回 `reset()` 里,本行立刻红(反证实测过)。
				_fail("c1 ★ 自己那间对局中的房那一行是 disabled —— 回局入口不存在"
						+ "(凭据还在吗?token=%s port=%d code=%s;或次序写反?)"
						% ["有" if PvpSession.token != "" else "**空**", PvpSession.worker_port,
							PvpSession.room_code])
			else:
				_ok("c1 ★ 自己那间对局中的房那一行**可点**(disabled=false)")
			_log("找到自己那间房那一行 → 点它")
			row.pressed.emit()
			_c1_sub = 3
			_phase_t = 0.0
			return
		3:
			if _phase_t > REJOIN_TIMEOUT:
				# ★ 自己判红(不靠总超时):判词要点明**卡在哪一步**,否则与"回局坏了"分不开。
				_fail("c1 ★ 点了自己那间房后 %.0fs 没回到对局(进 pvp_game=%s / PLAYING 计数 %d→%d)"
						% [REJOIN_TIMEOUT, str(_game != null), _playing_at_leave, _playing_count])
				_finish("")
				return
			if _game == null:
				return
			if not _playing_seen or _playing_count <= _playing_at_leave:
				return    # 还没重新收到服务器的广播
			_ok("c1 回到对局并进入 pvp_game")
			if int(PvpSession.role) != _role_before:
				_fail("c1 ★ 回局后 role 变了(%d → %d):大厅把凭据里的 role 发错了" %
						[_role_before, int(PvpSession.role)])
			else:
				_ok("c1 ★ 回局后 role 与离开前一致(%d)" % _role_before)
			# ★ 这一条才是"真的回到那一局"的证据:离场期间**没有任何** round_state 到达
			#   (客户端断着),回来之后又开始收 —— 计数必须**严格增长**。
			_ok("c1 ★ 回局后重新收到服务器广播(PLAYING 计数 %d → %d)" % [_playing_at_leave, _playing_count])
			_rec("BACK id_before=%d role=%d plays=%d→%d" % [_body_id_before, _role_before,
					_playing_at_leave, _playing_count])
			_finish("")
			return


# 把大厅连接接回**本探针的大厅**(偏离③:页自己的重连路径永远按默认端口 7777 走,
# 那是用户自己的服务端,本探针不碰)。★ **可重入**:开局前要接一次;而回主菜单后若页还是
# 走了慢路(它 `NetBus.stop()` + 按默认端口重连),还要再接一次 —— 故这里**不设一次性闸**。
# ★ 判据是**当下的连接**(`can_send_to_server()`),不是 `_lobby_back` 那个"曾经连上过"的闩:
#   ESC 回主菜单那条路会 `NetBus.stop()`(`PauseMenu.go_menu` 对 PvP 无条件断连 —— 那正是
#   worker 把身体送进宽限期的方式),而 `_lobby_back` 还停在 true。
func _reconnect_lobby(tag: String) -> void:
	if NetBus.can_send_to_server():
		return
	if _lobby_back_connecting:
		return
	_lobby_back_connecting = true
	_repairs += 1
	NetBus.stop()
	var err := NetBus.start_client(LOBBY_ADDR, lobby_port)
	if err != OK:
		_lobby_back_connecting = false
		_fail("c1 ★ %s:start_client(%s:%d) 失败 err=%d" % [tag, LOBBY_ADDR, lobby_port, err])
		_finish("")
		return
	multiplayer.connection_failed.connect(func() -> void:
		_lobby_back_connecting = false
		_fail("c1 ★ %s:连大厅失败(%s:%d)" % [tag, LOBBY_ADDR, lobby_port])
		_finish(""), CONNECT_ONE_SHOT)
	multiplayer.connected_to_server.connect(func() -> void:
		_lobby_back_connecting = false
		if NetBus.can_send_to_server():
			NetBus.rpc_id(1, "lobby_name", "BOT1")
		_log("%s:已重新连上大厅(%s:%d)" % [tag, LOBBY_ADDR, lobby_port]),
			CONNECT_ONE_SHOT)
	# ★ 若页还活着且走了慢路,它的地址框此刻指着**别处**(云默认 / 用户的大厅)——
	#   把地址框与 `PvpSession.server_address` 一起拨回本探针大厅,否则页下一次 `_with_lobby`
	#   的快路判据(`_connected_addr == addr`)**永远不成立**,它会一次次拆掉我们的连接。
	if is_instance_valid(_page):
		PvpSession.server_address = LOBBY_ADDR
		var box: Node = _page.get("_addr_edit")
		if box is LineEdit:
			(box as LineEdit).text = LOBBY_ADDR
		_page.set("_connected", true)
		_page.set("_connected_addr", LOBBY_ADDR)


func _esc_and_menu() -> void:
	var pm: Node = null
	for c in _game.get_children():
		if c is PauseMenu:
			pm = c
			break
	if pm == null:
		_fail("对局场景里没找到 PauseMenu")
		_finish("")
		return
	# 真 ESC(理由见 team_match_watcher._esc_leave:keycode 与 physical_keycode 都要给)
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	_rec("PAUSE_MENU opened=%d" % (1 if bool(pm.get("_open")) else 0))
	_log("按 ESC 打开暂停菜单(opened=%s)→ 点「回 到 主 菜 单」" % str(bool(pm.get("_open"))))
	pm.call("go_menu")


# ── c2(对手:这一局还在的见证)──
var _c2_joined := false
func _tick_c2(delta: float) -> void:
	if _game == null:
		# ── 还在大厅:等列表里出现那间房 → 点它(真按钮回调,与真人加入逐字同一条路)──
		if not is_instance_valid(_page):
			if _hard_t > ENTER_TIMEOUT:
				_fail("c2 ★ %.0fs 没能经大厅进入对局(页没挂上/建房没成功?)" % ENTER_TIMEOUT)
				_finish("")
			return
		_tick_refresh(delta, _c2_joined)
		if _c2_joined:
			return
		# ★ 偏离①:brief 这里判的是 `_room_code != ""`,而那条只在"我建的房"上成立(c2 收不到
		#   `room_created`)⇒ 照 brief 写 c2 永远不加入。改成"列表里有可点的行就点"。
		var row := _first_row_button()
		if row == null:
			if _hard_t > ENTER_TIMEOUT:
				_fail("c2 ★ %.0fs 没在房间列表里看到可加入的房(c1 没建成?)" % ENTER_TIMEOUT)
				_finish("")
			return
		_c2_joined = true
		_rec("JOIN row=%s" % row.text)
		_log("点房间列表第一行加入(真按钮回调):%s" % row.text)
		row.pressed.emit()
		return
	# ── 已在场:留满一个观察窗再落盘(见文件头 c2 那一段)──
	if not _obs_started:
		if _hard_t > ENTER_TIMEOUT + 20.0:
			_fail("c2 ★ 进了对局但 %.0fs 内没收到 PLAYING 广播" % (ENTER_TIMEOUT + 20.0))
			_finish("")
		return
	_obs_t += delta
	if _obs_t < C2_OBSERVE:
		return
	_ok("c2 ★ 在场并看到 PLAYING(这一局的见证端)")
	if _snap_total > 0 and _snap_with_opp == _snap_total:
		_ok("c2 ★ 观察窗内掉线者的身体每一帧都在权威快照里(%d/%d 帧,role %d 从未被销毁)"
				% [_snap_with_opp, _snap_total, 3 - int(PvpSession.role)])
	else:
		_fail("c2 ★ 掉线者的身体在权威快照里缺席过(%d/%d 帧有它)—— 身体被销毁了?"
				% [_snap_with_opp, _snap_total])
	if _obs_state_bad:
		_fail("c2 ★ 观察窗内对局离开过 PLAYING 或换了局 —— 回局前后**不是同一局**(也可能只是有人阵亡)")
	else:
		_ok("c2 ★ 观察窗内一直是 PLAYING 且局号未变(%d)—— 这一局从头到尾没重启过" % _obs_round)
	if _snap_max_gap > C2_SNAP_GAP_MAX_MS:
		_fail("c2 ★ 观察窗内权威快照间隔 %.0fms > %.0fms(服务器停过?)"
				% [_snap_max_gap, C2_SNAP_GAP_MAX_MS])
	else:
		_ok("c2 ★ 观察窗内权威快照连续(最大间隔 %.0fms,共 %d 帧)" % [_snap_max_gap, _snap_total])
	_rec("OBS plays=%d snaps=%d with_opp=%d maxgap=%.0fms round=%d state_bad=%s" % [
			_playing_count, _snap_total, _snap_with_opp, _snap_max_gap, _obs_round,
			str(_obs_state_bad)])
	_finish("")


# ── c3(第三人)──
func _tick_c3(delta: float) -> void:
	_tick_refresh(delta, _phase == 1)
	if _phase == 0:
		# ★ 兜底:等不到"对局中"那一行时**自己判红**并落盘 —— 否则裁判只会收到 2/3 份结果,
		#   读起来像"探针坏了",而真正的问题是"c3 什么都没看到"。
		if _hard_t > ENTER_TIMEOUT:
			_fail("c3 ★ %.0fs 内没在列表里看到那个对局中的房(实得 %d 行;server_message=%s)"
					% [ENTER_TIMEOUT, _room_rows, str(_server_msgs)])
			_finish("")
		return
	if _phase_t > RESULT_WAIT:
		# 等够了:这才是 c3 的结论时刻
		if _room_rows != 1:
			_fail("c3 ★ 没在列表里看到那个对局中的房(实得 %d 行)" % _room_rows)
		else:
			_ok("c3 ★ 第三人能看到对局中的房(1 行,code=%s)" % _room_code)
		# ★ 反向对照(c1 那条断言的另一半):同一行、同一份载荷,手里**没有凭据**的人看到的
		#   必须是"点不动"。两条合起来才说明可点性是**按人**判的,而不是"那一刻所有人都能进"。
		if not _c3_row_disabled:
			_fail("c3 ★ 那一行对**没有凭据的第三人**也是可点的 —— 可点性不是按人判的")
		else:
			_ok("c3 ★ 同一行对第三人仍是 disabled(按人判:凭据在他的手里,不在我手里)")
		var joins_before := _joins
		var go_before := _go_match
		var refused := false
		for m in _server_msgs:
			if m.contains("无法加入") or m.contains("对局已进行中") or m.contains("房间不存在"):
				refused = true
		if joins_before != 0 or go_before != 0 or not refused:
			_fail("c3 ★ 加入被拒这条没成立(room_joined=%d 次 / go_match=%d 次 / 拒绝提示=%s)"
					% [joins_before, go_before, str(_server_msgs)])
		else:
			_ok("c3 ★ 加入被拒(无 room_joined / 无 go_match / 有拒绝提示)")
		_rec("REFUSE joins=%d go=%d msgs=%s" % [joins_before, go_before, str(_server_msgs)])
		_finish("")


# ── 结果与日志 ──
func _log(s: String) -> void:
	print("WATCHER[%s] t=%.1f %s" % [who, _t, s])


func _ok(msg: String) -> void:
	_checks += 1
	print("WATCHER[%s] OK " % who + msg)
	_rec("OK " + msg)


func _fail(msg: String) -> void:
	_checks += 1
	_fails.append(msg)
	print("WATCHER[%s] FAIL " % who + msg)


func _rec(line: String) -> void:
	# ★ 偏离⑤:读数进内存,`_finish` 时**连同断言账本一起**写进结果文件。
	#   (brief 的 `_rec` 直接写文件,而 `_finish` 用 WRITE 打开同一个文件 → 之前那些行全被截掉,
	#    读日志的人拿不到任何中间读数。)
	_recs.append(line)
	_log("REC " + line)


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if why != "" and _fails.is_empty():
		_fail(why)
	# ★★ 计数守卫(只对"否则会打印 OK"的那一跑生效):本探针是回局这条路**唯一的**观测者,
	#   一段被截断的跑(阶段梯没走到、客户端早退、`--quit-after` 到期)不许读成通过。
	var min_checks := int(MIN_CHECKS.get(who, 1))
	if _fails.is_empty() and _checks < min_checks:
		_fail("只跑了 %d 条断言(期望 ≥ %d)—— 有阶段没跑到,这个 OK 不算数" % [_checks, min_checks])
	var head := "OK" if _fails.is_empty() else "FAIL(%d)" % _fails.size()
	var f := FileAccess.open("user://rejoin_probe_%s.result" % who, FileAccess.WRITE)
	if f != null:
		f.store_line(head)
		for e in _recs:
			f.store_line("REC " + e)
		for e in _fails:
			f.store_line("  - %s" % e)
		f.close()
	# ★★ **c2 / c3 落盘后不退出**(`hold_alive`):它们的结果只是"我这边的读数",而**对局必须继续
	#   活着** —— c2 是对手,它一退,worker 就把 role 2 送进宽限期(相② 的前提"这一局还在"就
	#   变了味);c3 虽然不在局里,留着也不花任何代价。真正的收尾是**裁判按 PID 杀**
	#   (`_kill_children`),子进程另有一条 `--quit-after` 兜底。
	#   c1 是 actor:它的剧本跑完就该退,退出不改变任何结论。
	if hold_alive:
		print("WATCHER[%s] 结果已落盘,保持在线等裁判收尾" % who)
		return
	get_tree().quit(0 if _fails.is_empty() else 1)
