extends Control
# 匹配场景:建房 / 输入房间号加入(大厅 7777)。配对完成后大厅发 go_match(role, port),
# 客户端断大厅连接 → 转连该局独立的 worker 进程并 claim_role,等 worker 的 match_start 进对局。

var _addr_edit: LineEdit
var _code_edit: LineEdit
var _status: Label

func _ready() -> void:
	_addr_edit = _make_line_edit(Vector2(60, 120), "服务器地址", PvpSession.server_address)
	_code_edit = _make_line_edit(Vector2(60, 180), "房间号(加入时填)", "")
	var name_le := _make_line_edit(Vector2(60, 60), "昵称(头上显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "玩家")
	_status = Label.new()
	_status.position = Vector2(60, 320)
	_status.size = Vector2(700, 40)
	add_child(_status)

	_make_button(Vector2(60, 240), "建房", _on_create_pressed)
	_make_button(Vector2(280, 240), "加入", _on_join_pressed)
	_make_button(Vector2(60, 400), "返回", func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_server_message.connect(func(t: String) -> void: _status.text = t)
	_status.text = "输入服务器地址,选 建房 或 加入"

func _make_line_edit(pos: Vector2, placeholder: String, initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = Vector2(240, 36)
	le.placeholder_text = placeholder
	le.text = initial
	add_child(le)
	return le

func _make_button(pos: Vector2, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(200, 48)
	b.pressed.connect(fn)
	add_child(b)
	return b

func _on_create_pressed() -> void:
	PvpSession.server_address = _addr_edit.text.strip_edges() if _addr_edit.text != "" else PvpSession.server_address
	_status.text = "连接服务器……"
	multiplayer.connected_to_server.connect(func() -> void: NetBus.rpc_id(1, "create_room"), CONNECT_ONE_SHOT)
	NetBus.start_client(PvpSession.server_address)

func _on_join_pressed() -> void:
	var code := _code_edit.text.strip_edges()
	if code.is_empty():
		_status.text = "请填房间号"
		return
	PvpSession.room_code = code
	PvpSession.server_address = _addr_edit.text.strip_edges() if _addr_edit.text != "" else PvpSession.server_address
	_status.text = "连接服务器……"
	multiplayer.connected_to_server.connect(func() -> void: NetBus.rpc_id(1, "join_room", code), CONNECT_ONE_SHOT)
	NetBus.start_client(PvpSession.server_address)

func _on_room_created(code: String) -> void:
	_status.text = "房间号 %s —— 把房间号发给对手,等待开战" % code

func _on_room_joined(role: int) -> void:
	_status.text = "已加入,等待开战……"

# 大厅配对完成:断开大厅 → 转连对局 worker,并 claim 大厅分配的角色。
func _on_go_match(role: int, port: int) -> void:
	PvpSession.role = role
	_status.text = "配对成功,连接对局服务器……"
	multiplayer.connected_to_server.connect(_claim_role_worker.bind(role), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_status.text = "连接对局服务器失败,请返回重试", CONNECT_ONE_SHOT)
	NetBus.stop()
	var err := NetBus.start_client(PvpSession.server_address, port)
	if err != OK:
		_status.text = "连接对局服务器失败(%d)" % err

func _claim_role_worker(role: int) -> void:
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
