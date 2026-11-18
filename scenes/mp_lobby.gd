extends Node

var _requesting := false
var _waiting := false
var _filter := ""
var _listed_room: Dictionary
var _view := LobbyView.new()

func _ready() -> void:
	UiFactory.cover(self, _view)
	_view.mount(PvpSession.player_name, _form_values())
	_view.nickname_changed.connect(_name_changed)
	_view.filter_changed.connect(_set_filter)
	_view.create_requested.connect(_create_room)
	_view.join_requested.connect(_join_room)
	_view.room_chosen.connect(_open_listing)
	_view.copy_requested.connect(_copy_room_code)
	_view.team_requested.connect(func(side: int) -> void: NetBus.send_event(NetEvent.Kind.PICK_TEAM, side))
	_view.start_requested.connect(NetBus.send_event.bind(NetEvent.Kind.START))
	_view.exit_room_requested.connect(_exit_room)
	_view.back_requested.connect(_back)
	_view.preference_changed.connect(Settings.store)
	_set_filter(PvpSession.entry_mode)

	Tunnel.ensure_relay_file()
	NetBus.event_received.connect(_on_net_event)
	NetBus.protocol_error.connect(_on_connection_error)
	NetBus.server_disconnected.connect(_on_connection_error.bind("与房间的连接已断开"))
	if NetBus.can_send_to_server() and not PvpSession.room.is_empty() and not PvpSession.room["in_match"]:
		NetSession.send_hello()
		_show_room()
	else:
		_list_rooms.call_deferred()

static func _form_values() -> Dictionary:
	var bounds := {}
	var time := TimeRules.normalized() if PvpSession.beta_mode else {}
	for field in time:
		var rule: Array = TimeRules.FIELDS[field]
		bounds[field] = Vector2(rule[TimeRules.MINIMUM], rule[TimeRules.MAXIMUM])
	return {"hue": Settings.pvp_color_hue, "match_min": Settings.royale_match_min,
		"full_heal": Settings.pvp_round_full_heal, "disabled": Settings.pvp_disabled_weapons,
		"map": Settings.mp_map_path, "time": time, "bounds": bounds}

func _name_changed(text: String) -> void:
	var name := text.strip_edges()
	PvpSession.player_name = "Anon" if name.is_empty() else name
	NetSession.send_hello()

func _back() -> void:
	NetSession.close()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _set_filter(mode: String) -> void:
	_filter = mode
	_view.select_filter(mode)
	_refresh_listing()

func _refresh_listing() -> void:
	var room := _listed_room
	if room.is_empty() or (not _filter.is_empty() and room["mode"] != _filter):
		_view.show_listing({})
	else:
		_view.show_listing(LobbyProjection.card(room, not room["in_match"] or PvpSession.can_rejoin_to(room["code"], room["mode"])))

func _open_listing() -> void:
	if _listed_room["in_match"]:
		_request("正在回到对局…", func() -> String:
			return NetSession.room_error(await NetSession.rejoin_room()), false)
	else:
		_join_room(_listed_room["code"])

func _join_room(code: String) -> void:
	if not Tunnel.is_valid_room(code):
		_view.set_status("房间码是 8 位数字(例 00048213)")
		return
	_request("正在连接房间 %s 的网络…" % code, NetSession.join_room.bind(code), true)

func _create_room(mode: String, fields: Dictionary) -> void:
	var options := {"map": fields["map"], "player_collision": fields["player_collision"]}
	if mode != PvpSession.MODE_TEAM:
		options["disabled_weapons"] = fields["disabled_weapons"]
	if WeaponRegistry.enabled_ids(options.get("disabled_weapons", [])).is_empty():
		_view.set_status("请至少启用一种武器")
		return
	match mode:
		PvpSession.MODE_ROYALE:
			options["max_players"] = fields["max_players"]
			options["match_time"] = fields["match_min"] * 60
		PvpSession.MODE_PVP:
			options["round_full_heal"] = fields["round_full_heal"]
	if PvpSession.beta_mode:
		options["beta"] = true
		options["time"] = TimeRules.normalized(fields["time"])
	_request("正在创建房间…", func() -> String:
		_view.close_create()
		return await NetSession.create_room({"mode": mode, "options": options}), true)

func _request(message: String, send: Callable, clear_listing: bool) -> void:
	if _requesting or _waiting:
		return
	_requesting = true
	_view.set_status(message)
	if clear_listing:
		_listed_room = {}
		_refresh_listing()
	var error: String = await send.call()
	_requesting = false
	if is_inside_tree() and not error.is_empty():
		_view.set_status(error)

func _list_rooms() -> void:
	var error := await NetSession.list_rooms()
	if is_inside_tree() and not _requesting and not error.is_empty():
		_view.set_status(error)

func _show_room() -> void:
	var room := PvpSession.room
	var code: String = room["code"]
	if room["host_role"] == room["your_role"]:
		var error := "" if Tunnel.on_network(code) else Tunnel.start_host(NetBus.server_port, code)
		var status := "房间 %s 已创建" % code
		status += "，把房间号报给对手" if error.is_empty() else "。远程联机不可用，%s" % error
		_view.set_status(status)
	else:
		_view.set_status("已加入房间 %s" % code)
	_waiting = true
	_view.show_wait(LobbyProjection.waiting(room))

func _copy_room_code() -> void:
	var code := PvpSession.room_code
	DisplayServer.clipboard_set(code)
	_view.set_status("已复制房间号：%s" % code)

func _exit_room() -> void:
	NetBus.send_event(NetEvent.Kind.LEAVE)
	PvpSession.room = {}
	_close_room("已退出房间")

func _close_room(message: String) -> void:
	_on_connection_error(message)
	_list_rooms()

func _on_net_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.MESSAGE: _view.set_status(data)
		NetEvent.Kind.ROOM: _show_room()
		NetEvent.Kind.ROOM_LIST:
			_listed_room = data
			_refresh_listing()
		NetEvent.Kind.REJOIN_DENIED:
			_refresh_listing()
			_view.set_status("无法回到对局：%s" % data)
			_list_rooms()
		NetEvent.Kind.ROOM_CLOSED: _close_room(data)
		NetEvent.Kind.BASELINE:
			var map := MapFormat.parse_map(data["map"], "房间 %s" % data["code"])
			if map.is_empty():
				_view.set_status("对局地图无法读取")
				return
			PvpSession.begin_match(data, map)
			SceneTransition.change(get_tree(), "res://scenes/pvp_game.tscn")

func _exit_tree() -> void:
	NetBus.event_received.disconnect(_on_net_event)
	NetBus.protocol_error.disconnect(_on_connection_error)
	NetBus.server_disconnected.disconnect(_on_connection_error.bind("与房间的连接已断开"))

func _on_connection_error(message: String) -> void:
	_listed_room = {}
	_waiting = false
	_view.show_wait({})
	_refresh_listing()
	_view.set_status(message)
