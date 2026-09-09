extends Control
# 大乱斗大厅(RoyaleServer 分支):建房(公开/私密+邀请码+人数上限)/公开房间列表点击加入/
# 等待室实时成员列表 + 房主开局。自建服务器(RoyaleHost 死斗 worker)。
# 协议走 NetBusExt(royale_* 系列);开局复用原版 go_match(role,port) 转连 worker。
# 视觉项(小地图/轨迹/血条/颜色)沿用「多人对战」设置(Settings.pvp_*),此处不重复摆放。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"
const WEAPON_NAMES := {1: "手枪", 2: "步枪", 3: "重狙", 4: "霰弹", 5: "榴弹"}

var _addr_edit: LineEdit
var _code_edit: LineEdit        # 房间号(加入)
var _invite_edit: LineEdit      # 邀请码(私密房加入)
var _status: Label
var _list_box: VBoxContainer
var _connected := false
var _connected_addr := ""
var _pending_action: Callable = Callable()
var _lobby_start_ms := 0
var _royale_ack := true       # 建房/加入后是否已收到服务器 royale_room_state
var _royale_sent_ms := 0

# ── 建房面板控件 ──
var _public_check: CheckButton
var _create_invite_edit: LineEdit
var _max_slider: HSlider
var _max_label: Label
var _weapon_checks: Array[CheckButton] = []

# ── 等待室 ──
var _wait_panel: PanelContainer = null
var _create_panel: PanelContainer = null   # 右列创建面板(进等待室时隐藏)
var _wait_title: Label
var _wait_players: VBoxContainer
var _wait_count: Label
var _start_btn: Button
var _ai_fill_btn: Button
var _in_room := false
var _my_room := {}     # 最近一次 royale_room_state
var _host := false

# ── 转连对局 worker(同 matchmaking)──
var _connecting_worker := false
var _go_start_ms := 0
var _pending_go_role := -1
var _pending_go_port := -1


func _ready() -> void:
	# 根 Control 默认尺寸 0×0:居中面板(PRESET_CENTER)按零尺寸父级计算会飞到屏幕外
	# (自检实测等待室在 (-320,-149));设满矩形锚点让根铺满 1920×1440 视口
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.size = get_viewport_rect().size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	move_child(bg, 0)

	# ── 左列:昵称 / 服务器 / 房间列表 / 邀请码加入 ──
	var name_le := _make_line_edit(Vector2(60, 60), "昵称(排行榜显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	# 大乱斗协议在 NetBusExt(自建服务端才有):原作者云服不支持 → 默认本机,不默认云地址
	_addr_edit = _make_line_edit(Vector2(60, 120), "服务器地址(大乱斗=自建服)", "127.0.0.1")
	var addr_hint := _label("大乱斗需自建服务器:开服方双击 start_server.bat,其他人填其 IP;原作者云服(默认地址)不支持大乱斗", 18, Color(0.75, 0.8, 0.85))
	addr_hint.position = Vector2(60, 160)
	addr_hint.size = Vector2(900, 26)
	add_child(addr_hint)
	var refresh := _make_button(Vector2(330, 114), "刷新列表", _on_refresh_pressed)

	var cap := _label("公开房间列表(点击直接加入)", 26, Color(0.55, 0.95, 1.0))
	cap.position = Vector2(60, 186)
	add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 228)
	scroll.size = Vector2(680, 560)
	add_child(scroll)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(640, 0)
	scroll.add_child(vb)
	_list_box = vb

	_code_edit = _make_line_edit(Vector2(60, 812), "房间号", "")
	_invite_edit = _make_line_edit(Vector2(330, 812), "邀请码(私密房)", "")
	var join_btn := _make_button(Vector2(600, 806), "加 入", _on_join_pressed)
	join_btn.custom_minimum_size = Vector2(140, 48)

	_status = _label("", 24, Color(0.95, 0.95, 0.85))
	_status.position = Vector2(60, 880)
	_status.size = Vector2(900, 120)
	add_child(_status)

	var back := _make_button(Vector2(60, 1000), "返回主菜单", func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://Scenes/main_menu.tscn"))

	_build_create_panel()

	# ── 信号 ──
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state)
	NetBus.local_server_message.connect(_on_server_message)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)

	_apply_pixel_font(self)
	_request_list.call_deferred("正在连接服务器获取房间列表…")


# ── 建房面板(右列)──
func _build_create_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(1000, 60)
	panel.custom_minimum_size = Vector2(620, 0)
	add_child(panel)
	_create_panel = panel   # 成员引用:进等待室时隐藏、退房恢复
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	vb.add_child(_label("—— 创建大乱斗房间 ——", 34, Color(0.55, 0.95, 1.0)))

	_public_check = CheckButton.new()
	_public_check.text = "公开房间(不勾选 = 私密,凭邀请码进入)"
	_public_check.button_pressed = true
	_public_check.add_theme_font_size_override("font_size", 24)
	_public_check.toggled.connect(func(on: bool) -> void:
		_create_invite_edit.visible = not on)
	vb.add_child(_public_check)

	_create_invite_edit = LineEdit.new()
	_create_invite_edit.placeholder_text = "邀请码(留空自动生成)"
	_create_invite_edit.visible = false
	_create_invite_edit.custom_minimum_size = Vector2(0, 40)
	vb.add_child(_create_invite_edit)

	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 14)
	vb.add_child(mrow)
	mrow.add_child(_label("人数上限:", 24))
	_max_slider = HSlider.new()
	_max_slider.min_value = 2
	_max_slider.max_value = 8
	_max_slider.step = 1
	_max_slider.value = 4
	_max_slider.custom_minimum_size = Vector2(300, 30)
	_max_slider.value_changed.connect(func(v: float) -> void:
		_max_label.text = "%d 人" % int(v))
	mrow.add_child(_max_slider)
	_max_label = _label("4 人", 24, Color(0.95, 0.95, 0.85))
	mrow.add_child(_max_label)

	vb.add_child(_label("禁用武器(房主生效,开局带进对局):", 24))
	# 2 列网格 + 定尺寸剪影(横排会溢出屏幕)
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", 10)
	wgrid.add_theme_constant_override("v_separation", 6)
	vb.add_child(wgrid)
	for slot: int in [1, 2, 3, 4, 5]:   # 显式 int:循环变量来自字面量数组,var slot_i := slot 推断不出类型会整文件解析失败 → 大乱斗大厅蓝屏
		var slot_i := slot
		var cell := WeaponComponent.make_weapon_check(slot_i, Settings.pvp_disabled_weapons.has(slot_i),
				22, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(slot_i):
					Settings.pvp_disabled_weapons.append(slot_i)
				elif not on:
					Settings.pvp_disabled_weapons.erase(slot_i)
				Settings.save())
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("slot", slot_i)
		_weapon_checks.append(cb)
		wgrid.add_child(cell)

	vb.add_child(_label("(小地图/轨迹/血条/颜色等视觉项沿用「多人对战」设置;\n复活一律满血,一局 5 分钟,击杀最多者胜)", 20, Color(0.7, 0.75, 0.8)))

	var create := Button.new()
	create.text = "创 建 房 间"
	create.custom_minimum_size = Vector2(360, 54)
	create.add_theme_font_size_override("font_size", 28)
	create.pressed.connect(_on_create_pressed)
	vb.add_child(create)


# ── 通用小控件 ──
func _label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l

func _make_line_edit(pos: Vector2, placeholder: String, initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = Vector2(250, 40)
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

func _apply_pixel_font(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer \
			or root is ScrollContainer):
		var pf: FontFile = load(PIXEL_FONT)
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		_apply_pixel_font(n)


# ── 大厅连接(同 matchmaking 的 _with_lobby 模式)──
func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)

func _with_lobby(action: Callable) -> void:
	if _in_room:
		_status.text = "已在大乱斗房间中(先退出房间再操作)"
		return
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = "127.0.0.1"   # 大乱斗需自建服:空地址回退本机,不回退云地址
		_addr_edit.text = addr
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
	else:
		_lobby_start_ms = Time.get_ticks_msec()

func _on_lobby_connected() -> void:
	if _connecting_worker:
		return
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
	if _connecting_worker:
		return
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	_status.text = "连接服务器失败,请检查地址"

func _process(_delta: float) -> void:
	if _connecting_worker and Time.get_ticks_msec() - _go_start_ms > 12000:
		_connecting_worker = false
		_status.text = "连接对局服务器超时——请检查对局端口(7800~7999 UDP)是否放行"
	if not _connecting_worker and _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "连接大厅超时——请检查地址/网络(UDP 7777)"
	# 建房/加入 8s 无应答:NetBusExt 协议在自建服务端才有,原作者云服会静默丢弃
	if not _royale_ack and _royale_sent_ms > 0 and Time.get_ticks_msec() - _royale_sent_ms > 8000:
		_royale_sent_ms = 0
		_status.text = "8 秒无响应——该服务器不支持大乱斗(需自建最新服务端:开服方双击 start_server.bat),或地址不通"


# ── 动作 ──
func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		NetBusExt.rpc_id(1, "royale_list"))

func _on_refresh_pressed() -> void:
	_request_list("刷新房间列表…")

func _on_create_pressed() -> void:
	var disabled: Array = []
	for cb in _weapon_checks:
		if cb.button_pressed:
			disabled.append(int(cb.get_meta("slot", 0)))
	_with_lobby(func() -> void:
		_status.text = "建房中…"
		_royale_ack = false
		_royale_sent_ms = Time.get_ticks_msec()
		NetBusExt.rpc_id(1, "royale_create", {
			"is_public": _public_check.button_pressed,
			"invite_code": _create_invite_edit.text.strip_edges(),
			"max_players": int(_max_slider.value),
			"round_full_heal": false,
			"disabled_weapons": disabled,
		}))

func _on_join_pressed() -> void:
	_join_room(_code_edit.text.strip_edges(), _invite_edit.text)

func _join_room(code: String, invite: String) -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_status.text = "加入房间 %s …" % code
		_royale_ack = false
		_royale_sent_ms = Time.get_ticks_msec()
		NetBusExt.rpc_id(1, "royale_join", code, invite))


# ── 服务器回复 ──
func _on_royale_rooms(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		var empty := _label("暂无公开房间 —— 右侧「创建房间」开一把大乱斗", 24, Color(0.8, 0.85, 0.9))
		empty.custom_minimum_size = Vector2(620, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个公开房间"
		return
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var maxp := int(r.get("max_players", 4))
		var occ := ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s      %d/%d%s" % [code, players, maxp, occ]
		btn.custom_minimum_size = Vector2(620, 46)
		btn.add_theme_font_size_override("font_size", 24)
		var pf: FontFile = load(PIXEL_FONT)
		if pf != null:
			btn.add_theme_font_override("font", pf)
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			_join_room(code, ""))
		_list_box.add_child(btn)
	_status.text = "共 %d 个公开房间" % rooms.size()

func _on_server_message(t: String) -> void:
	_status.text = t

# 房间实时状态 → 等待室面板
func _on_room_state(state: Dictionary) -> void:
	_in_room = true
	_royale_ack = true
	_my_room = state
	var my_role := _my_role_in(state)
	_host = int(state.get("host_role", 0)) == my_role
	if _create_panel != null:
		_create_panel.visible = false   # 进等待室:隐藏右列创建面板(与等待室并存太挤)
	if _wait_panel == null:
		_build_wait_panel()
	_wait_panel.visible = true
	if _ai_fill_btn != null:
		_ai_fill_btn.visible = _host and not bool(state.get("in_match", false))
	var code := str(state.get("code", ""))
	var invite := str(state.get("invite_code", "")) if not bool(state.get("is_public", true)) else ""
	_wait_title.text = "—— 大乱斗房间 %s ——%s" % [code, "  邀请码 %s" % invite if invite != "" else ""]
	for c in _wait_players.get_children():
		c.queue_free()
	var plist: Array = state.get("players", [])
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var role := int(p.get("role", 0))
		var nm := str(p.get("name", "玩家"))
		var is_me := role == my_role
		var is_host := int(state.get("host_role", 0)) == role
		var row := _label("%d. %s%s%s" % [role, nm, "(我)" if is_me else "", "(房主)" if is_host else ""],
				26, Color(0.9, 0.95, 1.0) if not is_me else Color(0.55, 0.95, 1.0))
		_wait_players.add_child(row)
	_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [plist.size(), int(state.get("max_players", 4))]
	_start_btn.visible = _host

func _my_role_in(state: Dictionary) -> int:
	var plist: Array = state.get("players", [])
	for p in plist:
		if typeof(p) == TYPE_DICTIONARY and str(p.get("name", "")) == PvpSession.player_name:
			return int(p.get("role", 0))
	return 0

func _build_wait_panel() -> void:
	_wait_panel = PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(640, 0)
	_wait_panel.add_child(vb)
	_wait_title = _label("", 36, Color(0.55, 0.95, 1.0))
	vb.add_child(_wait_title)
	_wait_players = VBoxContainer.new()
	_wait_players.add_theme_constant_override("separation", 8)
	vb.add_child(_wait_players)
	_wait_count = _label("", 24, Color(0.8, 0.85, 0.9))
	vb.add_child(_wait_count)
	_start_btn = Button.new()
	_start_btn.text = "开 始 游 戏"
	_start_btn.custom_minimum_size = Vector2(360, 56)
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.pressed.connect(func() -> void:
		_status.text = "开局中…"
		NetBusExt.rpc_id(1, "royale_start"))
	vb.add_child(_start_btn)
	# AI 补位开局(实验性):真人不足时用电脑玩家补满上限(仅自建服务端支持)
	_ai_fill_btn = Button.new()
	_ai_fill_btn.text = "AI 补位开局(实验性)"
	_ai_fill_btn.custom_minimum_size = Vector2(360, 48)
	_ai_fill_btn.add_theme_font_size_override("font_size", 26)
	_ai_fill_btn.pressed.connect(func() -> void:
		_status.text = "AI 补位开局中…"
		NetBusExt.rpc_id(1, "royale_start_ai"))
	vb.add_child(_ai_fill_btn)
	var leave := Button.new()
	leave.text = "退出房间"
	leave.custom_minimum_size = Vector2(360, 48)
	leave.add_theme_font_size_override("font_size", 26)
	leave.pressed.connect(_on_leave_room)
	vb.add_child(leave)
	add_child(_wait_panel)
	# 居中锚点必须在入树之后设置:未入树时父级尺寸为 0,面板会飞到屏幕左上角外(自检实测)
	_wait_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_wait_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wait_panel.grow_vertical = Control.GROW_DIRECTION_BOTH

func _on_leave_room() -> void:
	NetBusExt.rpc_id(1, "royale_leave")
	_in_room = false
	_my_room = {}
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true   # 退房恢复创建面板
	_request_list.call_deferred("已退出房间")


# ── 开局转连 worker(同 matchmaking:go_match 延迟到帧末处理,防 poll 栈内断连段错误)──
func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	_pending_go_port = port
	_status.text = "开局!连接对局服务器……"
	_do_go_match.call_deferred()

func _do_go_match() -> void:
	if _pending_go_role < 0:
		return
	var role := _pending_go_role
	var port := _pending_go_port
	_pending_go_role = -1
	_pending_go_port = -1
	PvpSession.role = role
	PvpSession.royale = true
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
	NetBusExt.rpc_id(1, "player_options", {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": false,
		"disabled_weapons": Settings.pvp_disabled_weapons,
	})

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	# RPC 在 NetBus.poll 调用栈内到达(worker→客户端 match_start);直接在栈内切场景会
	# 在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(与 go_match 同款,曾实测)。
	# 延迟到帧末再切;改版后大乱斗建房→加入→开局→进图全链路须重测。
	get_tree().call_deferred("change_scene_to_file", "res://Scenes/royale_game.tscn")
