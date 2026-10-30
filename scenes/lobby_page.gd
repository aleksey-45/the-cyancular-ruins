class_name LobbyPage
extends Control

# 大厅页面共享基类，封装房间列表获取、加入与创建流程、断线重连、EasyTier P2P 隧道配置以及向对局场景的切换。
# 子类负责具体布局、列表项渲染以及布局与房间展示。

const LocalServer := preload("res://core/net/local_server.gd")
const Tunnel := preload("res://core/net/tunnel.gd")

var _status: Label
var _room_code := ""
var _code_edit: LineEdit = null
var _connected := false
var _connected_addr := "127.0.0.1"
var _pending_action: Callable = Callable()
var _lobby_start_ms := 0
var _rejoin_sent_ms := 0


# 初始化大厅通用信号接线与字体设置
func _finish_lobby_ready() -> void:
	Tunnel.ensure_relay_file()
	NetBus.event_received.connect(_on_net_event)
	NetBus.connected_to_server.connect(_on_lobby_connected)
	NetBus.connection_failed.connect(_on_lobby_connect_failed)
	NetBus.protocol_error.connect(_on_protocol_error)
	UiFactory.apply_font_recursive(self)
	if NetBus.can_send_to_server():
		_connected = true
		_push_lobby_name()
		if not PvpSession.room.is_empty():
			_on_room(PvpSession.room)
		else:
			_request_list.call_deferred("正在获取房间列表…")
	else:
		_request_list.call_deferred("正在连接服务器…")

func _on_net_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.MESSAGE: _on_server_message(data)
		NetEvent.Kind.ROOM: _on_room(data)
		NetEvent.Kind.ROOMS: _on_rooms(data)
		NetEvent.Kind.REJOIN_DENIED: _on_rejoin_denied(data)
		NetEvent.Kind.ROOM_CLOSED:
			PvpSession.clear_rejoin()
			PvpSession.room.clear()
			_status.text = data
			_on_room_closed()
		NetEvent.Kind.BASELINE:
			PvpSession.baseline = data
			PvpSession.role = data["role"]
			PvpSession.room_code = data["code"]
			PvpSession.room_mode = data["mode"]
			PvpSession.beta_mode = data["options"].get("beta", false)
			PvpSession.loading_match = true
			_enter_match_scene()
		NetEvent.Kind.TERRAIN, NetEvent.Kind.BULLET_SPAWN, NetEvent.Kind.BULLET_REWIND, NetEvent.Kind.EXPLOSION, NetEvent.Kind.BULLET_FUSE, \
		NetEvent.Kind.BULLET_END, NetEvent.Kind.HIT, NetEvent.Kind.BEAM, NetEvent.Kind.TIME_REWARD:
			if PvpSession.loading_match:
				PvpSession.match_events.append([kind, data])

func _exit_tree() -> void:
	NetBus.event_received.disconnect(_on_net_event)
	NetBus.connected_to_server.disconnect(_on_lobby_connected)
	NetBus.connection_failed.disconnect(_on_lobby_connect_failed)
	NetBus.protocol_error.disconnect(_on_protocol_error)

func _on_protocol_error(message: String) -> void:
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	_status.text = message

func _on_room(_state: Dictionary) -> void:
	pass

func _on_rooms(_rooms: Array) -> void:
	pass

func _on_room_closed() -> void:
	pass

func _add_weapon_grid(parent: Node, h_sep: int, on_cell: Callable = Callable()) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", h_sep)
	wgrid.add_theme_constant_override("v_separation", 6)
	parent.add_child(wgrid)
	for type_id: int in WeaponRegistry.all_ids():
		var type_i := type_id
		var cell := WeaponIcons.make_weapon_check(type_i, Settings.pvp_disabled_weapons.has(type_i),
				32, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(type_i):
					Settings.pvp_disabled_weapons.append(type_i)
				elif not on:
					Settings.pvp_disabled_weapons.erase(type_i)
				Settings.save())
		if on_cell.is_valid():
			on_cell.call(cell, type_i)
		wgrid.add_child(cell)


# 上报当前玩家昵称至大厅
func _push_lobby_name() -> void:
	NetBus.send_event(NetEvent.Kind.HELLO, {"name": PvpSession.player_name, "hue": Settings.pvp_color_hue})

func _on_lobby_connected() -> void:
	_lobby_start_ms = 0
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	var act := _pending_action
	if act.is_valid():
		_pending_action = Callable()
		act.call()
	else:
		_request_list("已连接,正在获取房间列表…")

func _on_lobby_connect_failed() -> void:
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	_status.text = "未检测到本地服务器——请创建房间或输入 8 位房间号加入"


# 确保连接到大厅后执行指定动作
func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	if _connected and NetBus.can_send_to_server():
		_push_lobby_name()
		action.call()
		return
	_status.text = "正在连接本地大厅…"
	_connected = false
	_pending_action = action
	_on_lobby_reconnect()
	NetBus.stop()
	var port := PvpSession.server_port
	var err := NetBus.start_client("127.0.0.1", port)
	if err != OK:
		_status.text = "启动连接失败(%d)" % err
		_pending_action = Callable()
	else:
		_lobby_start_ms = Time.get_ticks_msec()


# 请求刷新房间列表
func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		_send_list_request())

func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t

func try_rejoin_row(code: String, in_match: bool, mode: String) -> bool:
	if not PvpSession.can_rejoin_to(code, mode):
		return false
	if not in_match:
		return false
	_request_rejoin()
	return true

func _request_rejoin() -> void:
	if not PvpSession.can_rejoin():
		_status.text = "回局凭据已失效,请重新建房/加入"
		return
	if not NetBus.can_send_to_server():
		_request_list("与大厅的连接已断开——正在重连并刷新房间列表…")
		return
	_rejoin_sent_ms = Time.get_ticks_msec()
	_status.text = "正在回到对局…"
	NetBus.send_event(NetEvent.Kind.REJOIN, {"code": PvpSession.room_code, "token": PvpSession.token})


# 服务端拒绝回局请求时清除凭据并刷新列表
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	_request_list("已刷新房间列表")


# 回局请求超时处理
func _tick_rejoin_timeout() -> bool:
	if _rejoin_sent_ms > 0 \
			and Time.get_ticks_msec() - _rejoin_sent_ms > 15000:
		_rejoin_sent_ms = 0
		PvpSession.clear_rejoin()
		_status.text = "回局请求无响应——已放弃,请重新建房/加入"
		return true
	return false

func _return_to_lobby(msg: String) -> void:
	NetBus.send_event(NetEvent.Kind.LEAVE)
	PvpSession.room.clear()
	PvpSession.clear_rejoin()
	_on_return_to_lobby()
	_status.text = msg
	_request_list("正在刷新房间列表…")

func _tick_lobby_connect_timeout() -> void:
	if _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "未检测到本地服务器——请创建房间或输入 8 位房间号加入"


# 角色认领超时检测

func _ensure_own_server() -> bool:
	NetSession.close()
	_status.text = "正在启动本机专属服务器…"
	PvpSession.server_address = "127.0.0.1"
	var port: int = await LocalServer.launch_and_connect()
	if port <= 0:
		_status.text = "启动本机服务器失败，请检查日志"
		return false
	PvpSession.server_port = port
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	_update_code_label()
	return true


# 按房间码加入游戏
func _join_with_code(code: String, action: Callable) -> void:
	if code.is_empty():
		_status.text = "请填房间码"
		return
	if not Tunnel.is_valid_room(code):
		_status.text = "房间码是 8 位数字(例 00048213)"
		return
	if Tunnel.on_network(code) and NetBus.can_send_to_server():
		_push_lobby_name()
		action.call()
		return
	if not Tunnel.available():
		_status.text = Tunnel.missing_hint()
		return
	if not Tunnel.has_initial_peers():
		_status.text = ("远程联机需要一个初始节点(中继):把共享节点地址按行写进 %s,"
				% Tunnel.relay_file()
				+ "房主与客机填同一份。")
		return
	if Tunnel.is_running() or not Tunnel.current_code().is_empty():
		NetSession.close()
		_connected = false
		_status.text = "正在切换到房间 %s 所在的网络…" % code
	else:
		_status.text = "正在连接房间 %s 的网络…" % code
	var got: Dictionary = await Tunnel.start_client(code)
	if got.is_empty():
		_status.text = ("找不到房间 %s —— 可能是:房主已关房、码敲错了、"
				+ "或两端的初始节点填的不是同一个") % code
		return
	PvpSession.server_address = "127.0.0.1"
	var fwd := Tunnel.forward_port()
	PvpSession.server_port = fwd if fwd > 0 else int(got.get("port", 0))
	_status.text = "已找到房主(%s),正在加入…" % str(got.get("host_ip", ""))
	_with_lobby(action)

func _update_code_label() -> void:
	if _code_edit == null:
		return
	if _room_code.is_empty():
		_code_edit.text = ""
		_code_edit.editable = true
		_code_edit.placeholder_text = "房间号"
	else:
		_code_edit.text = _room_code
		_code_edit.editable = false
		_code_edit.placeholder_text = "你的房间号(报给对手)"


# 进房成功状态提示
func _set_room_entered_status(code: String, is_host: bool) -> void:
	if not is_host:
		_status.text = "已加入房间 %s" % code
		return
	var no_relay := Tunnel.no_relay_hint()
	_status.text = ("房间 %s 已创建 —— 把房间号报给对手" % code) if no_relay.is_empty() \
			else ("房间 %s 已创建;%s" % [code, no_relay])

func _send_list_request() -> void:
	push_error("LobbyPage: 子类必须覆写 _send_list_request()")

func _player_options() -> Dictionary:
	push_error("LobbyPage: 子类必须覆写 _player_options()")
	return {}


var time_rules := TimeRules.new()

func _add_time_params(vb: VBoxContainer) -> void:
	if not PvpSession.beta_mode:
		return
	vb.add_child(UiFactory.label("时间颗粒规则(房主可调,开局生效):", 32, UiFactory.C_ACCENT))
	_trow(vb, "初始颗粒", 1000.0, "initial", TimeRules.R_INITIAL, 50.0, false)
	_trow(vb, "颗粒上限", 1800.0, "cap", TimeRules.R_CAP, 100.0, false)
	_trow(vb, "回溯燃烧/秒", 150.0, "rewind_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "加速燃烧/秒", 70.0, "haste_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "短时额度", 250.0, "window", TimeRules.R_WINDOW, 10.0, false)
	_trow(vb, "回复/秒", 50.0, "regen", TimeRules.R_REGEN, 5.0, false)
	_trow(vb, "击杀获取 %", 50.0, "kill_ratio", Vector2(0.0, 100.0), 5.0, true)
	_trow(vb, "拆砖获取/子格", 10.0, "block_gain", TimeRules.R_BLOCK, 1.0, false)
	_trow(vb, "伤害获取/点", 4.0, "damage_gain", TimeRules.R_DAMAGE, 1.0, false)

func _trow(vb: VBoxContainer, text: String, initial: float, field: String,
		rng: Vector2, step: float, as_percent: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UiFactory.label(text, 32)
	l.custom_minimum_size = Vector2(300, 0)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = rng.x
	sl.max_value = rng.y
	sl.step = step
	sl.value = initial
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(220, 28)
	UiFactory.style_slider(sl)
	row.add_child(sl)
	var val := UiFactory.label(_fmt_param(initial, as_percent), 32, UiFactory.C_ACCENT)
	val.custom_minimum_size = Vector2(110, 0)
	row.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		time_rules.set(field, v / 100.0 if as_percent else v)
		val.text = _fmt_param(v, as_percent))
	vb.add_child(row)

static func _fmt_param(v: float, as_percent: bool) -> String:
	return ("%d%%" % int(round(v))) if as_percent else str(int(round(v)))

func _beta_payload() -> Dictionary:
	if not PvpSession.beta_mode:
		return {}
	time_rules.clamp_self()
	return {"beta": true, "time": time_rules.to_dict()}

func _add_map_picker(vb: VBoxContainer) -> void:
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.mp_map_path, 2, 260.0, "地　图(房主选;缩略图 = 开局地形简略图)")
	Settings.mp_map_path = picker.selected
	picker.picked.connect(func(p: String) -> void:
		Settings.mp_map_path = p
		Settings.save())

func _enter_match_scene() -> void:
	push_error("LobbyPage: 子类必须覆写 _enter_match_scene()")

func _lobby_action_allowed() -> bool:
	return true

func _on_lobby_reconnect() -> void:
	pass

func _on_return_to_lobby() -> void:
	pass
