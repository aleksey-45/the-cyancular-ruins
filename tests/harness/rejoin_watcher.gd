extends Node


const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 60.0
const MENU_TIMEOUT := 25.0
const MENU_BTN_TEXT := "多 人 模 式"
const PLAY_SETTLE := 3.0
const REJOIN_TIMEOUT := 30.0
const RESULT_WAIT := 40.0
const REFRESH_EVERY := 1.5
const C2_OBSERVE := 40.0
const C2_SNAP_GAP_MAX_MS := 1500.0

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
var _playing_seen := false
var _playing_count := 0
var _playing_at_leave := 0
var _role_before := 0
var _joins := 0
var _go_match := 0
var _server_msgs: Array[String] = []
var _room_rows := -1
var _room_code := ""
var _row_seen := false
var _row_disabled := true
var _c3_row_disabled := true
var _c3_row_read := false
var _refresh_t := 0.0
var _obs_started := false
var _start_rpc_t := 0.0
var _obs_t := 0.0
var _obs_round := -1
var _obs_state_bad := false
var _snap_last_ms := 0
var _snap_max_gap := 0.0
var _snap_total := 0
var _snap_with_opp := 0
var _hard_t := 0.0
var hold_alive := false
var _lobby_back_connecting := false
var _menu_clicked := false
var _page_action: Callable = Callable()
var _page_action_done := false
var _hook_hits := 0
var _repairs := 0


func _ready() -> void:
	hold_alive = who != "c1"
	if who == "c1":
		get_tree().node_added.connect(_on_node_added)
		_lobby_back_connecting = true
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
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_server_message.connect(func(t: String) -> void:
		_server_msgs.append(t)
		_log("server_message: %s" % t))
	multiplayer.connected_to_server.connect(_on_lobby_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_lobby_back_connecting = false
		_fail("连大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port]))
	NetBus.start_client(LOBBY_ADDR, lobby_port)


func _on_lobby_connected() -> void:
	_lobby_back_connecting = false
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "lobby_name", "BOT%d" % (1 if who == "c1" else (2 if who == "c2" else 3)))
	if who == "c1":
		_enter_main_menu.call_deferred()
		return
	_attach_page.call_deferred()


func _attach_page() -> void:
	_attach_page_in(get_tree().current_scene,
			(on_create if who == "c1" else on_refresh))


func _enter_main_menu() -> void:
	_log("换到主菜单(生产入口从这里开始)")
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


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


func _drive_to_lobby_page(first: bool) -> bool:
	if is_instance_valid(_page):
		return true
	if not NetBus.can_send_to_server():
		_reconnect_lobby("先把大厅接回来再放页进来")
		return false
	var cs := get_tree().current_scene
	if not _menu_clicked:
		if not _is_main_menu(cs):
			return false
		_menu_clicked = true
		_page_action = (on_create if first else on_refresh)
		_page_action_done = false
		_phase_t = 0.0
		return _press_menu_mode_button()
	var p := _current_lobby_page(cs)
	if p == null:
		if _phase_t > MENU_TIMEOUT:
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


func _press_menu_mode_button() -> bool:
	var menu := get_tree().current_scene
	var btn := _find_button_text(menu, MENU_BTN_TEXT)
	if btn == null:
		_fail("c1 ★ 主菜单上找不到「%s」那颗按钮(还没换到主菜单?或菜单改了文案)" % MENU_BTN_TEXT)
		_finish("")
		return false
	_rec("MENU press «%s»" % MENU_BTN_TEXT)
	_log("按主菜单「%s」(生产入口:PvpSession.reset() + change_scene_to_file)" % MENU_BTN_TEXT)
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


var _page_bound := false

func _sync_page() -> void:
	if is_instance_valid(_page) and _page.is_inside_tree():
		return
	_page = null
	if _page_bound:
		_page_bound = false
		_menu_clicked = false


func _attach_page_in(cs: Node, action: Callable) -> void:
	if cs == null or _page != null:
		return
	_page = load("res://scenes/mp_lobby.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	_page.set("_connected", true)
	_page.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(_page)
	_log("真大厅页已挂载(%s)" % cs.name)
	action.call()


func on_create() -> void:
	_page.call("_open_create_dialog")
	_page.call("_on_create_pressed")


func on_refresh() -> void:
	_page.call("_on_refresh_pressed")


func _tick_refresh(delta: float, done: bool) -> void:
	if done or not is_instance_valid(_page) or not NetBus.can_send_to_server():
		return
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_EVERY
	_page.call("_on_refresh_pressed")


# 在房间网格里按房号找那一张房卡(mp_lobby 把房号记在卡的 meta("code") 上,卡本体 text 恒空 —— 旧页那套「按键钮文案找行」在统一页上恒找不到)。
# ★ 找不到时调用方必须立刻 FAIL,不能静默等超时 —— 那种失败与「回局坏了」在输出上长得一样。
func _find_row_button(code: String) -> Button:
	if not is_instance_valid(_page) or code == "":
		return null
	var grid: Node = _page.get("_grid")
	if grid == null:
		return null
	for c in grid.get_children():
		if c is Button and str(c.get_meta("code", "")) == code:
			return c
	return null


func _first_row_button() -> Button:
	if not is_instance_valid(_page):
		return null
	var grid: Node = _page.get("_grid")
	if grid == null:
		return null
	for c in grid.get_children():
		if c is Button and str(c.get_meta("code", "")) != "" and not (c as Button).disabled:
			return c
	return null


func _on_room_list(rooms: Array) -> void:
	_refresh_t = REFRESH_EVERY
	if who == "c1":
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
		var row := _find_row_button(_room_code)
		if row != null:
			_c3_row_disabled = row.disabled
			_c3_row_read = true
		if _phase == 0:
			_phase = 1
			_phase_t = 0.0
			_log("列表里看到对局中的房 %s → 试图加入(应当被拒)" % _room_code)
			_page.call("_join_code", _room_code, "")


func _on_round_state(data: Dictionary) -> void:
	var st := int(data.get("state", -1))
	if st == 1:
		if not _playing_seen and who == "c2":
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
	if who == "c2" and _obs_started:
		_obs_state_bad = true


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
	_refresh_game()
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


func _refresh_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		_game = null
		return
	if cs.get("_local") == null:
		return
	if _game != cs:
		_log("进入对局场景(role=%d)" % PvpSession.role)
	_game = cs


func _is_game(n: Node) -> bool:
	return n is PvpMatchClient


var _c1_sub := 0
func _tick_c1(delta: float) -> void:
	if _phase_t > ENTER_TIMEOUT + MENU_TIMEOUT + REJOIN_TIMEOUT + RESULT_WAIT:
		_finish("c1 超时(阶段 %d)" % _c1_sub)
		return
	_sync_page()
	match _c1_sub:
		0:
			_drive_to_lobby_page(true)
			if _page != null and NetBus.can_send_to_server():
				_start_rpc_t += delta
				if _start_rpc_t >= 1.0:
					_start_rpc_t = 0.0
					NetBusExt.rpc_id(1, "pvp_start")
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
			# ★★ 回到主菜单之后再走一次生产入口(按那颗「多 人 模 式」按钮)—— 这一步就是 C1 的现场:从前本端在这里直接挂页,恰好绕过了「按钮 → PvpSession.reset() → 凭据还在不在」这一问 ⇒ 拿着生产里根本拿不到的凭据全绿(见文件头那条纠正)。
			if _game != null:
				return
			if not _drive_to_lobby_page(false):
				return
			_tick_refresh(delta, _row_seen)
			if not _row_seen:
				if _phase_t > ENTER_TIMEOUT:
					_fail("c1 ★ 回到大厅页后 %.0fs 没在列表里看到自己那间房(%s)" % [ENTER_TIMEOUT, _room_code])
					_finish("")
				return
			var row := _find_row_button(_room_code)
			if row == null:
				# ★ 立刻 FAIL,不静默等超时(那种失败与"回局坏了"长得一样)
				_fail("c1 ★ 列表里没有自己那间房那一行(code=%s)—— 显示方案那一半坏了?" % _room_code)
				_finish("")
				return
			if row.disabled:
				# ★★ 这一条就是新入口本身:同一个房、同一份载荷,别人(见 c3)看到的是 disabled,而手里有凭据的本人必须可点。它有两种成因,判词两个都点名:① 次序写反(先按 in_match 禁用)—— 前三页渲染那一半;
				#   ② 凭据在半路上没了(C1:主菜单那颗按钮把 token/worker_port/room_code 一起清了)⇒ can_rejoin_to 恒 false。★ 这一条正是 C1 的验收断言:把凭据清回 reset() 里,本行立刻红(反证实测过)。
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
				_fail("c1 ★ 点了自己那间房后 %.0fs 没回到对局(进 pvp_game=%s / PLAYING 计数 %d→%d)"
						% [REJOIN_TIMEOUT, str(_game != null), _playing_at_leave, _playing_count])
				_finish("")
				return
			if _game == null:
				return
			if not _playing_seen or _playing_count <= _playing_at_leave:
				return
			_ok("c1 回到对局并进入 pvp_game")
			if int(PvpSession.role) != _role_before:
				_fail("c1 ★ 回局后 role 变了(%d → %d):大厅把凭据里的 role 发错了" %
						[_role_before, int(PvpSession.role)])
			else:
				_ok("c1 ★ 回局后 role 与离开前一致(%d)" % _role_before)
			_ok("c1 ★ 回局后重新收到服务器广播(PLAYING 计数 %d → %d)" % [_playing_at_leave, _playing_count])
			_rec("BACK id_before=%d role=%d plays=%d→%d" % [_body_id_before, _role_before,
					_playing_at_leave, _playing_count])
			_finish("")
			return


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
	# ★ 若页还活着且走了慢路,它的地址框此刻指着别处(云默认 / 用户的大厅)—— 把地址框与 PvpSession.server_address 一起拨回本探针大厅,否则页下一次 _with_lobby 的快路判据(_connected_addr == addr)永远不成立,它会一次次拆掉我们的连接。
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
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	_rec("PAUSE_MENU opened=%d" % (1 if bool(pm.get("_open")) else 0))
	_log("按 ESC 打开暂停菜单(opened=%s)→ 点「回 到 主 菜 单」" % str(bool(pm.get("_open"))))
	pm.call("go_menu")


var _c2_joined := false
func _tick_c2(delta: float) -> void:
	if _game == null:
		if not is_instance_valid(_page):
			if _hard_t > ENTER_TIMEOUT:
				_fail("c2 ★ %.0fs 没能经大厅进入对局(页没挂上/建房没成功?)" % ENTER_TIMEOUT)
				_finish("")
			return
		_tick_refresh(delta, _c2_joined)
		if _c2_joined:
			return
		# ★ 偏离①:任务书这里判的是 _room_code != "",而那条只在「我建的房」上成立(c2 收不到 room_created)⇒ 照任务书写 c2 永远不加入。改成「列表里有可点的行就点」。
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


func _tick_c3(delta: float) -> void:
	_tick_refresh(delta, _phase == 1)
	if _phase == 0:
		if _hard_t > ENTER_TIMEOUT:
			_fail("c3 ★ %.0fs 内没在列表里看到那个对局中的房(实得 %d 行;server_message=%s)"
					% [ENTER_TIMEOUT, _room_rows, str(_server_msgs)])
			_finish("")
		return
	if _phase_t > RESULT_WAIT:
		if _room_rows != 1:
			_fail("c3 ★ 没在列表里看到那个对局中的房(实得 %d 行)" % _room_rows)
		else:
			_ok("c3 ★ 第三人能看到对局中的房(1 行,code=%s)" % _room_code)
		var fresh := _find_row_button(_room_code)
		if fresh != null:
			_c3_row_disabled = fresh.disabled
			_c3_row_read = true
		if not _c3_row_read:
			_fail("c3 ★ 没读到那一行的 `disabled`(按钮没找到)⇒ 这条反向对照**没成立**,不许按默认值空过")
		elif not _c3_row_disabled:
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
	# ★ 偏离⑤:读数进内存,_finish 时连同断言账本一起写进结果文件(任务书的 _rec 直接写文件,而 _finish 用 WRITE 打开同一个文件 ⇒ 之前那些行全被截掉,读日志的人拿不到任何中间读数)。
	_recs.append(line)
	_log("REC " + line)


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if why != "" and _fails.is_empty():
		_fail(why)
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
	if hold_alive:
		print("WATCHER[%s] 结果已落盘,保持在线等裁判收尾" % who)
		return
	get_tree().quit(0 if _fails.is_empty() else 1)
