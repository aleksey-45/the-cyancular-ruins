class_name MpLobby
extends LobbyPage


var _mode := ""
var _grid: GridContainer = null
var _create_btn: Button = null
var _join_btn: Button = null

var _wait_panel: PanelContainer = null
var _wait_title: HeaderStripPanel = null
var _wait_body: VBoxContainer = null
var _wait_count: Label = null
var _wait_start: Button = null
var _wait_pick_a: Button = null
var _wait_pick_b: Button = null
var _wait_leave: Button = null
var _wait_mode := ""
var _in_room := false

# 建房弹层当前选中的模式(模式切换状态)。★ 弹层本体 / 压暗罩 / 三颗分段按钮的行为在 scenes/mp_lobby/create_panel.gd,
# 它 apply() 时写这里;本页「确定」那条 RPC 分派读同一份(状态只住一处,别在面板里再存一份)。
var _create_mode := PvpSession.MODE_PVP

# 我当前所在那间房的模式(转连时按它选场景)。★★ 它与 PvpSession.room_mode 不是一回事:后者是凭据的模式(供列表里判"这一行是不是我的房"),
# 它在"建了房但 note_room 还没跑到"这一档上是空串 —— 拿它去分派 _enter_match_scene 会把 1v1 的对局静默切进 team_game.tscn(不报错)。别合并成一个字段。
var _current_mode := ""

var _ack := true
var _sent_ms := 0

# 刚发出的加入请求的房号(1v1 的 room_joined 载荷只有 role,拿不到房号,只能靠它暂存)。
# ★★ 漏了给它赋值 = 两条真缺陷:① _current_mode 停在空串 ⇒ _enter_match_scene() 落进 else ⇒ 1v1 的加入者被送进错场景;② note_room() 从不被调用 ⇒ 自己那间房永远是灰的。
var _join_pending := ""

var _probe_multi_join := false
var _multi_left := 0

var _auto_refreshed := false

const AUTO_REFRESH_S := 1.0
var _auto_refresh_t := 0.0

var _rooms: RoomList = null
var _form: OptionsForm = null
var _create_dialog: CreatePanel = null
var _wait: WaitRoom = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state_royale)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state_team)
	NetBusExt.local_pvp_room_state.connect(_on_pvp_room_state)

	_finish_lobby_ready()

	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)



func _build_ui() -> void:
	var name_le: LineEdit = %NameEdit
	name_le.text = PvpSession.player_name
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())
	_addr_edit = %AddrEdit
	_addr_edit.text = PvpSession.server_address
	%RefreshBtn.pressed.connect(_on_refresh_pressed)
	%LocalServerBtn.pressed.connect(_on_local_server_pressed)
	%LocalServerBtn.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"
	_ip_label = %IpLabel
	_ip_label.text = "本机局域网 IP: 检测中…"
	_apply_lan_hint.call_deferred()

	_create_btn = %CreateBtn
	_create_btn.pressed.connect(_open_create_dialog)
	_join_btn = %JoinBtn

	_grid = %CardGrid
	_status = %StatusLabel
	%BackBtn.pressed.connect(_on_back_pressed)

	_rooms = RoomList.new()
	_rooms.setup(self)
	_form = OptionsForm.new()
	_create_dialog = CreatePanel.new()
	_create_dialog.setup(self, _form)
	_wait = WaitRoom.new()
	_wait.setup(self)
	_join_btn.pressed.connect(_rooms.toggle_join_panel)
	_rooms.register(self)
	_form.register(self)
	_create_dialog.register(self)
	_wait.register(self)


func _on_back_pressed() -> void:
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")


func _on_local_server_ready() -> void:
	_auto_refreshed = false


func _apply_lan_hint() -> void:
	if is_instance_valid(_ip_label):
		_ip_label.text = LocalServer.lan_ip_hint()



func _set_filter(mode: String) -> void:
	_mode = mode
	_rooms.set_filter_selected(mode)
	_rooms.redraw()



func _ingest_rooms(mode: String, rooms: Array) -> void:
	var changed := _rooms.ingest(mode, rooms)
	if _join_pending.is_empty():
		_ack = true
		_sent_ms = 0
	if _rooms.all_got() and changed:
		_rooms.redraw()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))



# 基类钩子:不是一条统一 RPC —— 三条并发、各自到达,合并后重绘(刷新延迟由最慢那份决定);token 仍要带,大厅据此把持凭据本人自己那间私密房也列出来。
# ★ silent = 静默轮询(见 AUTO_REFRESH_S):不清表、不复位计数 —— 清表会让房卡在每次轮询时闪一下空。
func _send_list_request(silent: bool = false) -> void:
	if not silent:
		_rooms.reset_got()
		_rooms.clear_rooms()
	NetBus.rpc_id(1, "list_rooms")
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
	NetBusExt.rpc_id(1, "team_list", PvpSession.token)



func _on_room_created(code: String) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(code, _current_mode)
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code
	_wait.show(_wait.pvp_wait_state(code, 1, 1, 1), PvpSession.MODE_PVP)


# 服务端答"加进去了"。★ 房号从 _join_pending 取(room_joined 载荷只有 role)—— 这里同时是唯一记 1v1 加入房号的地方:
# 失败的加入不得留下 room_code,否则 can_rejoin_to(我自己的房) 恒 false,自己那间房永远是灰的。
func _on_room_joined(role: int) -> void:
	_current_mode = PvpSession.MODE_PVP
	var code := _join_pending
	if not _join_pending.is_empty():
		PvpSession.note_room(_join_pending, _current_mode)
		_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	_status.text = "已加入,等待开战……"
	if not code.is_empty():
		_wait.show(_wait.pvp_wait_state(code, role, 0, 2), PvpSession.MODE_PVP)


func _on_pvp_room_state(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_wait.show(state, PvpSession.MODE_PVP)


func _on_room_state_royale(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_ROYALE
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图。★ 只有房主该发 —— 非房主发会被服务端静默拒(不报错,所以必须自己判,否则每个加入者都会白发一次)。
	# ★ 判据用服务器下发的 host_role / your_role 两条(它们按 peer 单独下发,不是按昵称反查 —— 两人同名时会命中先出现的那个,本仓踩过)。
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "已进入大乱斗房间 %s,等待开局…" % code
	_wait.show(state, PvpSession.MODE_ROYALE)


func _on_room_state_team(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_TEAM
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "已进入对抗房间 %s,等待选边/开局…" % code
	_wait.show(state, PvpSession.MODE_TEAM)


func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_ack = true
	_sent_ms = 0
	if _swallow_absent(t):
		_claim_multi_reply()
		if not _probe_multi_join and not _join_pending.is_empty():
			_settle_multi_fail(t)
		return
	if t == "房间已满" or t == "房间不存在":
		_join_pending = ""
		if not _auto_refreshed:
			_auto_refreshed = true
			_request_list.call_deferred("%s → 已自动刷新列表" % t)
		else:
			_status.text = t
	elif t.begins_with("配对已取消"):
		_join_pending = ""
		_request_list.call_deferred("配对已取消(对手离开)——已刷新列表,请重选")
	else:
		_status.text = t


func _swallow_absent(t: String) -> bool:
	return _probe_multi_join and (t == "房间不存在" or t == "房间已满")


func _settle_multi_fail(t: String) -> void:
	_join_pending = ""
	if not _auto_refreshed:
		_auto_refreshed = true
		_request_list.call_deferred("%s → 已自动刷新列表" % t)
	else:
		_status.text = t


func _claim_multi_reply() -> void:
	if not _probe_multi_join:
		return
	_multi_left -= 1
	if _multi_left <= 0:
		_probe_multi_join = false



func _join_code(code: String, mode: String, invite: String = "") -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		# ★★ 三件事一件都不能少,否则 1v1 的加入者会被送进错场景(见字段声明处那段):① 暂存房号(1v1 的 room_joined 载荷只有 role,拿不到房号);
		# ② 模式未知时三张表都问一次;③ invite 必须真的传下去(私密房的唯一途径)。
		_join_pending = code
		if mode != "":
			_current_mode = mode
		_probe_multi_join = mode == ""
		_multi_left = 3 if _probe_multi_join else 0
		_status.text = "加入房间 %s,等待配对…" % code
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_PVP:
			NetBus.rpc_id(1, "join_room", code)
		else:
			NetBus.rpc_id(1, "join_room", code)
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode))


func _open_create_dialog() -> void:
	_create_dialog.open()


func _on_create_pressed() -> void:
	_create_dialog.set_visible(false)
	var mode := _create_mode
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		var payload := _create_dialog.build_payload(mode)
		payload.merge(_beta_payload())
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_create", payload)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_create", payload)
		else:
			NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间号后可叫对方刷新列表点进来)")


func _unhandled_input(ev: InputEvent) -> void:
	if not _create_dialog.is_open():
		return
	if ev.is_action_pressed("ui_cancel"):
		_create_dialog.set_visible(false)
		get_viewport().set_input_as_handled()


func _on_wait_pick(team: int) -> void:
	NetBusExt.rpc_id(1, "team_pick", team)


func _on_wait_start_pressed() -> void:
	_status.text = "开局中…"
	if _wait_mode == PvpSession.MODE_PVP:
		NetBusExt.rpc_id(1, "pvp_start")
	elif _wait_mode == PvpSession.MODE_ROYALE:
		NetBusExt.rpc_id(1, "royale_start")
	elif _wait_mode == PvpSession.MODE_TEAM:
		NetBusExt.rpc_id(1, "team_start")


func _on_wait_leave_pressed() -> void:
	if _wait_mode == PvpSession.MODE_ROYALE:
		NetBusExt.rpc_id(1, "royale_leave")
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	elif _wait_mode == PvpSession.MODE_TEAM:
		NetBusExt.rpc_id(1, "team_leave")
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	else:
		_return_to_lobby("已退出房间")



func _enter_match_scene() -> void:
	if _current_mode == PvpSession.MODE_PVP:
		get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
	elif _current_mode == PvpSession.MODE_ROYALE:
		get_tree().change_scene_to_file.call_deferred("res://scenes/royale_game.tscn")
	elif _current_mode == PvpSession.MODE_TEAM:
		get_tree().change_scene_to_file.call_deferred("res://scenes/team_game.tscn")
	else:
		var msg := "mp_lobby: match_start 到了但 _current_mode 是「%s」—— 建房/加入/回局三条路里有一条没记模式。**不切场景**(切错的场景比留在原地更难查)。"
		push_error(msg % _current_mode)


func _process(delta: float) -> void:
	if _tick_rejoin_timeout():
		return
	if _tick_worker_connect_timeout():
		return
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	if not _ack and _sent_ms > 0 and Time.get_ticks_msec() - _sent_ms > 8000:
		_sent_ms = 0
		_probe_multi_join = false
		_multi_left = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"
	_tick_auto_refresh(delta)


# 静默轮询:只在本页"闲着"时发(已连上 / 没有待应答的建房·加入 / 不在房里 / 不在转连途中)。
# ★ 判据含 _ack:_ack == false 时有一条建房/加入在等应答,插一轮列房只会搅乱那条状态机;不在这里做重连,故判 `NetBus.can_send_to_server()` 而不是 `_connected`(后者不随对端断开更新)。
func _tick_auto_refresh(delta: float) -> void:
	if not _connected or not _ack or _in_room or _connecting_worker:
		return
	if not NetBus.can_send_to_server():
		return
	_auto_refresh_t += delta
	if _auto_refresh_t < AUTO_REFRESH_S:
		return
	_auto_refresh_t = 0.0
	_send_list_request(true)



func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


func _lobby_action_allowed() -> bool:
	if _in_room:
		if _current_mode == PvpSession.MODE_ROYALE:
			_status.text = "已在大乱斗房间中(先退出房间再操作)"
		elif _current_mode == PvpSession.MODE_TEAM:
			_status.text = "已在对抗房间中(先退出房间再操作)"
		else:
			_status.text = "已在 1v1 房间中(先退出房间再操作)"
		return false
	return true


# 三个模式的权威规则项都上发,worker 各取自己认得的键(server_main._on_player_options 与 MatchBootstrap 都按 role1 那份生效);不认得的键被静默忽略。
func _player_options() -> Dictionary:
	return _create_dialog.player_options(_current_mode, {
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict(),
		"beta": PvpSession.beta_mode,
	})


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"


func _on_worker_connect_failed() -> void:
	if _connecting_worker:
		_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")


func _worker_timeout_msg() -> String:
	return "对局服务器无响应——请确认对局端口(%s UDP)已放行、两端为同一版本;已返回大厅并刷新" % _worker_port_span()


func _worker_port_span() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]


func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间"


func _on_go_match_extra() -> void:
	_sent_ms = 0


func _on_return_to_lobby() -> void:
	_sent_ms = 0
	_probe_multi_join = false
	_wait.hide()


func _on_lobby_reconnect() -> void:
	_rooms.clear_rooms()
	_rooms.redraw()
