extends Control
# 匹配场景:建房 / 加入 / 房间列表。
# 连上大厅(默认 120.53.107.140:7777)后,「IP 右侧 刷新」列出全部房间(方块=房间号+人数,
# 未满优先排前、可点击加入;已满置灰不可点)。点入后由大厅配对发 go_match → 转连该局 worker。

var _addr_edit: LineEdit
var _code_edit: LineEdit
var _status: Label
var _list_box: VBoxContainer
var _connected := false
var _connected_addr := ""          # 当前连的是哪个地址(地址框改了要重连)
var _auto_refreshed := false   # 「点了看起来未满却已满」后只自动刷新一次,手动刷新再放开
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
var _connecting_worker := false   # 是否在转连对局 worker(用于超时兜底提示)
var _go_start_ms := 0

func _ready() -> void:
	_addr_edit = _make_line_edit(Vector2(60, 120), "服务器地址", PvpSession.server_address)
	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.position = Vector2(330, 120)
	refresh.size = Vector2(90, 36)
	refresh.pressed.connect(_on_refresh_pressed)
	add_child(refresh)

	var name_le := _make_line_edit(Vector2(60, 60), "昵称(头上显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	_code_edit = _make_line_edit(Vector2(60, 180), "房间号(加入时填)", "")

	_status = Label.new()
	_status.position = Vector2(60, 320)
	_status.size = Vector2(720, 60)
	add_child(_status)

	_make_button(Vector2(60, 240), "建房", _on_create_pressed)
	_make_button(Vector2(260, 240), "加入", _on_join_pressed)
	_make_button(Vector2(60, 400), "返回", func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	var cap := Label.new()
	cap.text = "房间列表(只读展示;加入请在上方填房间号)"
	cap.position = Vector2(60, 460)
	cap.size = Vector2(700, 30)
	add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 500)
	scroll.size = Vector2(640, 560)
	add_child(scroll)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(600, 0)
	scroll.add_child(vb)
	_list_box = vb

	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_server_message.connect(_on_server_message)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)

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
	b.size = Vector2(180, 48)
	b.pressed.connect(fn)
	add_child(b)
	return b

func _on_lobby_connected() -> void:
	if _connecting_worker:
		return   # 转连对局 worker 的连接走 _on_go_match,不在这里接管
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	var act := _pending_action
	if act.is_valid():
		_pending_action = Callable()
		act.call()
	else:
		_status.text = "已连接,点「刷新」查看房间,或 建房"

func _on_lobby_connect_failed() -> void:
	if _connecting_worker:
		return
	_connected = false
	_pending_action = Callable()
	_status.text = "连接服务器失败,请检查地址"

# 把当前昵称上报给大厅(房间列表展示在房玩家)
func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)

# 按当前地址框连大厅;已连同一地址则直接执行。改地址会自动重连(不会连到旧地址)。
func _with_lobby(action: Callable) -> void:
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = "127.0.0.1"
	PvpSession.server_address = addr
	if _connected and _connected_addr == addr:
		action.call()
		return
	_status.text = "正在连接服务器…"
	_connected = false
	_pending_action = action
	NetBus.stop()
	var err := NetBus.start_client(addr)
	if err != OK:
		_status.text = "启动连接失败(%d)" % err
		_pending_action = Callable()

func _on_create_pressed() -> void:
	_with_lobby(func() -> void:
		NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间号后可刷新让对手看到)")

func _on_join_pressed() -> void:
	_join_code(_code_edit.text.strip_edges())

# 加入某房间号(手动输入)
func _join_code(code: String) -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	PvpSession.room_code = code
	_with_lobby(func() -> void:
		_status.text = "加入房间 %s,等待配对…" % code
		NetBus.rpc_id(1, "join_room", code))

func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")

func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		NetBus.rpc_id(1, "list_rooms"))

# 房间列表:未满优先在前,已满置灰不可点
func _on_room_list(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var partial: Array = []
	var full: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		(full if int(r.get("players", 2)) >= 2 else partial).append(r)
	var order: Array = partial + full
	if order.is_empty():
		var empty := Label.new()
		empty.text = "暂无房间 —— 点「建房」开一局吧"
		empty.size = Vector2(600, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个房间"
		return
	for r in order:
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var occ: String = ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   玩家: " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s      %d/2%s" % [code, players, occ]
		btn.custom_minimum_size = Vector2(600, 46)
		# 只读展示:保持正常外观(不置灰),但忽略鼠标 → 点不了
		btn.disabled = false
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.focus_mode = Control.FOCUS_NONE
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(未满优先)" % order.size()

func _on_server_message(t: String) -> void:
	if t == "房间已满":
		# 点了看起来未满、实际已满 → 提示并自动刷新一次
		if not _auto_refreshed:
			_auto_refreshed = true
			_request_list("房间已满 → 已自动刷新")
		else:
			_status.text = "房间已满"
	else:
		_status.text = t

func _on_room_created(code: String) -> void:
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code

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
	_connecting_worker = true
	_go_start_ms = Time.get_ticks_msec()
	var err := NetBus.start_client(PvpSession.server_address, port)
	if err != OK:
		_connecting_worker = false
		_status.text = "连接对局服务器失败(%d)" % err

func _claim_role_worker(role: int) -> void:
	_connecting_worker = false
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)

# 转连 worker 超时兜底:UDP 连不上不会立刻报失败,这里 12 秒给明确提示(别无限卡着)
func _process(_delta: float) -> void:
	if _connecting_worker and Time.get_ticks_msec() - _go_start_ms > 12000:
		_connecting_worker = false
		_status.text = "连接对局服务器超时——请检查:对局端口(7800~7999 UDP)是否放行、服务端是否最新"

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
