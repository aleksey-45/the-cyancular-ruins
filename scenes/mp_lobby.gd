extends Node

var _requesting := false
var _waiting := false
var _view := LobbyView.new()

func _ready() -> void:
	UiDesign.cover(self, _view)
	_view.mount(PvpSession.player_name, _form_values())
	_view.nickname_changed.connect(_name_changed)
	_view.filter_changed.connect(_view.select_filter)
	_view.create_requested.connect(_create_room)
	_view.join_requested.connect(_join_room)
	_view.copy_requested.connect(_copy_room_code)
	_view.team_requested.connect(NetSession.pick_team)
	_view.start_requested.connect(NetSession.start_match)
	_view.exit_room_requested.connect(NetSession.leave_room)
	_view.back_requested.connect(_back)
	_view.preference_changed.connect(Settings.store)
	_view.select_filter(PvpSession.entry_mode)
	NetSession.nearby_changed.connect(_view.present_rooms)
	NetSession.room_changed.connect(_show_room)
	NetSession.notice.connect(_view.set_status)
	NetSession.room_closed.connect(_browse)
	NetSession.connection_lost.connect(_connection_lost)
	NetSession.match_baseline.connect(_begin_match)
	if NetSession.connected():
		_show_room(NetSession.room)
	else:
		_browse("")
		if NetSession.can_rejoin(): _request("正在重连到房间…", NetSession.rejoin_room)

static func _form_values() -> Dictionary:
	return {"hue": Settings.pvp_color_hue, "match_min": Settings.royale_match_min,
		"full_heal": Settings.pvp_round_full_heal, "disabled": Settings.pvp_disabled_weapons,
		"map": Settings.mp_map_path, "time": TimeRules.normalized() if PvpSession.beta_mode else {}}

func _name_changed(text: String) -> void:
	var name := text.strip_edges()
	PvpSession.player_name = "Anon" if name.is_empty() else name

func _back() -> void:
	NetSession.close()
	SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _join_room(code: String) -> void:
	_request("正在加入房间 %s…" % code, NetSession.join_room.bind(code))

func _create_room(mode: String, rules: Dictionary, listed_nearby: bool) -> void:
	if WeaponRegistry.enabled_ids(rules.get("disabled_weapons", [])).is_empty():
		_view.set_status("请至少启用一种武器")
		return
	_view.close_create()
	_request("正在创建房间…", NetSession.create_room.bind(mode, rules, listed_nearby))

func _request(message: String, send: Callable) -> void:
	if _requesting or _waiting: return
	_requesting = true
	_view.set_status(message)
	var error: String = await send.call()
	_requesting = false
	if is_inside_tree() and not error.is_empty(): _view.set_status(error)

func _show_room(room: Dictionary) -> void:
	if not _waiting:
		var host: bool = room.your_role == room.host_role
		_view.set_status(("房间 %s 已创建，把房间号报给对手" if host else "已加入房间 %s") % room.code)
	_waiting = true
	_view.show_wait(LobbyProjection.waiting(room))

func _copy_room_code() -> void:
	DisplayServer.clipboard_set(NetSession.room.code)
	_view.set_status("已复制房间号：%s" % NetSession.room.code)

func _begin_match(data: Dictionary) -> void:
	var map := CyrmMap.from_bytes(data.map)
	if map.is_empty():
		_view.set_status("对局地图无法读取")
		return
	PvpSession.begin_match(data, map)
	# 地图解析完成后先显示加载界面，再实例化联机场景。切换期间由 NetSession 暂存对局消息。
	SceneTransition.change_with_builder(get_tree(), func() -> Node:
		var packed := load("res://scenes/pvp_game.tscn") as PackedScene
		return packed.instantiate() if packed != null else null, "正在进入对局…")

func _connection_lost() -> void:
	_browse("与房间的连接已断开")
	if NetSession.can_rejoin(): _request("正在重连到房间…", NetSession.rejoin_room)

func _browse(message: String) -> void:
	_waiting = false
	_view.show_wait({})
	_view.present_rooms([])
	_view.set_status(message)
	NetSession.set_browsing(true)

func _exit_tree() -> void:
	NetSession.set_browsing(false)
