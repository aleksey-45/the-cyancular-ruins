extends LobbyPage

# 大乱斗大厅(RoyaleServer 分支):建房(公开/私密+邀请码+人数上限)/公开房间列表点击加入/
# 等待室实时成员列表 + 房主开局。自建服务器(RoyaleHost 死斗 worker)。
# 协议走 NetBusExt(royale_* 系列);开局复用原版 go_match(role,port) 转连 worker。
# 视觉项(小地图/轨迹/血条/颜色)沿用「多人对战」设置(Settings.pvp_*),此处不重复摆放。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# 连接状态机 / 转连 worker / 按钮工厂都在基类 `LobbyPage` 里(与 1v1 匹配页共用)——
# 本文件只留大乱斗的差异:版式、建房与等待室两个面板、房间态渲染、超时梯顺序。

const WEAPON_NAMES := {1: "手枪", 2: "步枪", 3: "重狙", 4: "霰弹", 5: "榴弹"}

var _code_edit: LineEdit        # 房间号(加入)
var _invite_edit: LineEdit      # 邀请码(私密房加入)
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
var _in_room := false
var _my_room := {}     # 最近一次 royale_room_state
var _host := false


func _ready() -> void:
	# 根 Control 默认尺寸 0×0:居中面板(PRESET_CENTER)按零尺寸父级计算会飞到屏幕外
	# (自检实测等待室在 (-320,-149));设满矩形锚点让根铺满 1920×1440 视口
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()

	# ── 左列:昵称 / 服务器 / 房间列表 / 邀请码加入 ──
	var name_le := UiFactory.line_edit(self, Vector2(60, 60), Vector2(250, 40), "昵称(排行榜显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	# 大乱斗协议在 NetBusExt(自建服务端才有):原作者云服不支持 → 默认本机,不默认云地址
	_addr_edit = UiFactory.line_edit(self, Vector2(60, 120), Vector2(250, 40), "服务器地址(大乱斗=自建服)", "127.0.0.1")
	var addr_hint := UiFactory.label("大乱斗需自建服务器:点「启动/重启本机服务器」即可本机开服(同目录需有 Cyancular Ruins Server.exe);朋友加入填开服机 IP(异地用 VPN 组网);原作者云服不支持大乱斗", 16, Color(0.75, 0.8, 0.85))
	addr_hint.position = Vector2(60, 160)
	addr_hint.size = Vector2(900, 26)
	add_child(addr_hint)
	var refresh := _page_button("刷新列表", Vector2(330, 114), Vector2(200, 48), _on_refresh_pressed)
	var srv_btn := _page_button("启动/重启本机服务器", Vector2(540, 114), Vector2(200, 48), _on_local_server_pressed)
	srv_btn.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"
	_ip_label = UiFactory.label("", 16, UiFactory.C_ACCENT)
	_ip_label.position = Vector2(1250, 22)   # 页面顶部空带(左列 y160 有提示文字、右列 y60 起是建房面板)
	add_child(_ip_label)
	_ip_label.text = LocalServer.lan_ip_hint()   # 本机(=自建服同机)IP 常驻显示

	var cap := UiFactory.label("公开房间列表(点击直接加入)", 32, UiFactory.C_ACCENT)
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

	_code_edit = UiFactory.line_edit(self, Vector2(60, 812), Vector2(250, 40), "房间号", "")
	_invite_edit = UiFactory.line_edit(self, Vector2(330, 812), Vector2(250, 40), "邀请码(私密房)", "")
	# 「加 入」:所需尺寸走 UiFactory.button 的 min_size(KH 是事后覆写 custom_minimum_size);
	# 显式 size 保留 KH 原尺寸,140×48 是可收缩下限。
	var join_btn := UiFactory.button("加 入", 16, Vector2(140, 48))
	join_btn.position = Vector2(600, 806)
	join_btn.size = Vector2(200, 48)
	join_btn.pressed.connect(_on_join_pressed)
	add_child(join_btn)

	_status = UiFactory.label("", 32, UiFactory.C_TEXT)
	_status.position = Vector2(60, 880)
	_status.size = Vector2(900, 120)
	add_child(_status)

	var back := _page_button("返回主菜单", Vector2(60, 1000), Vector2(200, 48), func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	_build_create_panel()

	# ── 本页专属信号(其余共用信号在 _finish_lobby_ready 里接)──
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state)

	_finish_lobby_ready()


# ── 建房面板(右列)──
func _build_create_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(1000, 60)
	panel.custom_minimum_size = Vector2(620, 0)
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	add_child(panel)
	_create_panel = panel   # 成员引用:进等待室时隐藏、退房恢复
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	vb.add_child(UiFactory.label("—— 创建大乱斗房间 ——", 32, UiFactory.C_ACCENT))

	_public_check = CheckButton.new()
	_public_check.text = "公开房间(不勾选 = 私密,凭邀请码进入)"
	_public_check.button_pressed = true
	UiFactory.style_check(_public_check, 32)
	_public_check.toggled.connect(func(on: bool) -> void:
		_create_invite_edit.visible = not on)
	vb.add_child(_public_check)

	_create_invite_edit = LineEdit.new()
	_create_invite_edit.placeholder_text = "邀请码(留空自动生成)"
	_create_invite_edit.visible = false
	_create_invite_edit.custom_minimum_size = Vector2(0, 40)
	UiFactory.style_control(_create_invite_edit, 16)   # 同 UiFactory.line_edit:显式字号=引擎默认,不靠事后递归补字体
	UiFactory.style_line_edit(_create_invite_edit)
	vb.add_child(_create_invite_edit)

	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 14)
	vb.add_child(mrow)
	mrow.add_child(UiFactory.label("人数上限:", 32))
	_max_slider = HSlider.new()
	_max_slider.min_value = 2
	_max_slider.max_value = 8
	_max_slider.step = 1
	_max_slider.value = 4
	_max_slider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(_max_slider)
	_max_slider.value_changed.connect(func(v: float) -> void:
		_max_label.text = "%d 人" % int(v))
	mrow.add_child(_max_slider)
	_max_label = UiFactory.label("4 人", 32, UiFactory.C_TEXT)
	mrow.add_child(_max_label)

	# 一局限时(分钟):房主可调 1~15 分钟(默认 5);随房主报到 opts 带入 RoyaleHost
	var trow := HBoxContainer.new()
	# 键是 "separation":HBox 只认它,h_separation 是 GridContainer 的键(写在这里会被存下但
	# 永不读取 = 死覆盖)。别照抄下面 wgrid 那两行 —— 那是 GridContainer,键不一样。
	trow.add_theme_constant_override("separation", 12)
	vb.add_child(trow)
	trow.add_child(UiFactory.label("一局限时:", 32))
	var tslider := HSlider.new()
	tslider.min_value = 1.0
	tslider.max_value = 15.0
	tslider.step = 1.0
	tslider.value = Settings.royale_match_min
	tslider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(tslider)
	trow.add_child(tslider)
	var tlabel := UiFactory.label("%d 分钟" % int(Settings.royale_match_min), 32, UiFactory.C_TEXT)
	trow.add_child(tlabel)
	tslider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		tlabel.text = "%d 分钟" % int(v))

	vb.add_child(UiFactory.label("禁用武器(房主生效,开局带进对局):", 32))
	_add_weapon_grid(vb, 10, func(cell: Node, slot: int) -> void:
		# 本页要多记一笔:建房时读 _weapon_checks 的勾选态(1v1 页不留引用,直接读 Settings)
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("slot", slot)
		_weapon_checks.append(cb))

	# 自己角色颜色(色相 0-360):本页即选即存;开局转连 worker 报到时随 player_options 上发,
	# worker 开局广播 peer_hues → 全员按各自 hue 染色(与 1v1 匹配页同一设置项)。
	# 标签另起一行是本页版式(1v1 页把标签放在行内),故传空 label_text 自己在外面加。
	vb.add_child(UiFactory.label("自己角色颜色:", 32))
	_add_hue_row(vb, "", Vector2(300, 30), Vector2(46, 30))

	vb.add_child(UiFactory.label("(小地图/轨迹/血条等其余视觉项沿用「多人对战」设置;\n复活一律满血,一局 5 分钟,击杀最多者胜)", 16, UiFactory.C_TEXT_DIM))

	var create := UiFactory.button("创 建 房 间", 32, Vector2(360, 54))
	create.pressed.connect(_on_create_pressed)
	vb.add_child(create)


# worker 端口段文案(提示串用;单一来源 = WorkerLauncher 的常量,勿手写数字——
# 曾写 "7800~7999" 与实际池(7800~8299)不符,照它放行防火墙会漏掉半个池子,自检 D2)
func _worker_port_span() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]


# ── 动作 ──
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
		var empty := UiFactory.label("暂无公开房间 —— 右侧「创建房间」开一把大乱斗", 32, Color(0.8, 0.85, 0.9))
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
		var btn := UiFactory.button("房间 %s      %d/%d%s" % [code, players, maxp, occ], 32, Vector2(620, 46))
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			_join_room(code, ""))
		_list_box.add_child(btn)
	_status.text = "共 %d 个公开房间" % rooms.size()

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
		var row := UiFactory.label("%d. %s%s%s" % [role, nm, "(我)" if is_me else "", "(房主)" if is_host else ""],
				32, UiFactory.C_TEXT if not is_me else UiFactory.C_ACCENT)
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
	_wait_title = UiFactory.label("", 32, UiFactory.C_ACCENT)
	vb.add_child(_wait_title)
	_wait_players = VBoxContainer.new()
	_wait_players.add_theme_constant_override("separation", 8)
	vb.add_child(_wait_players)
	_wait_count = UiFactory.label("", 32, Color(0.8, 0.85, 0.9))
	vb.add_child(_wait_count)
	_start_btn = UiFactory.button("开 始 游 戏", 32, Vector2(360, 56))
	_start_btn.pressed.connect(func() -> void:
		_status.text = "开局中…"
		NetBusExt.rpc_id(1, "royale_start"))
	vb.add_child(_start_btn)
	var leave := UiFactory.button("退出房间", 32, Vector2(360, 48))
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


# 转连 worker 12s 没连上(worker 死了/端口没放行)→ 回大厅重连 + 刷新列表;
# claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来)同样回大厅。
# ★ 本页的梯顺序是 [worker → claim → 大厅 → ack],与基类注释里登记的一致;**别重排**。
func _process(_delta: float) -> void:
	# 1) 转连 worker 12s 没连上(worker 死了/端口没放行):**回大厅重连 + 刷新列表**,
	#    不再只留一句提示让玩家干等在等待室里(本页原来没有任何恢复路径)。
	if _tick_worker_connect_timeout():
		return
	# 2) claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来):同样回大厅重连刷新
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	# 建房/加入 8s 无应答:NetBusExt 协议在自建服务端才有,原作者云服会静默丢弃
	if not _royale_ack and _royale_sent_ms > 0 and Time.get_ticks_msec() - _royale_sent_ms > 8000:
		_royale_sent_ms = 0
		_status.text = "8 秒无响应——该服务器不支持大乱斗(需自建最新服务端:开服方双击 start_server.bat),或地址不通"


# ── 基类钩子(本页实现)────────────────────────────────────────────

# 大乱斗需自建服:空地址回退本机,不回退云地址
func _lobby_fallback_addr() -> String:
	return "127.0.0.1"


# 已在大乱斗房间中(先退出房间再操作):_with_lobby 在 _in_room 时拒绝一切操作,
# 不清房间态就再也刷不出列表/建不了房。
func _lobby_action_allowed() -> bool:
	if _in_room:
		_status.text = "已在大乱斗房间中(先退出房间再操作)"
		return false
	return true


func _send_list_request() -> void:
	NetBusExt.rpc_id(1, "royale_list")


# 大乱斗多一项 match_time(一局限时),回合回血恒 false(大乱斗规则里没有回合)
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": false,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
	}


func _go_match_status() -> String:
	return "开局!连接对局服务器……"


func _on_worker_connect_failed() -> void:
	_status.text = "连接对局服务器失败,请返回重试"


func _worker_timeout_msg() -> String:
	return "对局服务器无响应——请确认对局端口(%s UDP)已放行;已返回大厅并刷新" % _worker_port_span()


func _claim_timeout_msg() -> String:
	return "对局服务器无响应(对局可能已结束)——已返回大厅并刷新,请重试"


# 清房间态是必须的:_with_lobby 在 _in_room 时拒绝一切操作,不清就再也刷不出列表/建不了房。
func _on_return_to_lobby() -> void:
	_in_room = false
	_my_room = {}
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true


# RPC 在 NetBus.poll 调用栈内到达(worker→客户端 match_start);直接在栈内切场景会
# 在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(与 go_match 同款,曾实测)。
# 延迟到帧末再切;改版后大乱斗建房→加入→开局→进图全链路须重测。
func _enter_match_scene() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://scenes/royale_game.tscn")
