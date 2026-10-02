extends LobbyPage

# 大乱斗大厅(RoyaleServer 分支):建房(公开/私密+邀请码+人数上限)/公开房间列表点击加入/
# 等待室实时成员列表 + 房主开局。自建服务器(RoyaleHost 死斗 worker)。
# 协议走 NetBusExt(royale_* 系列);开局复用原版 go_match(role,port) 转连 worker。
# 视觉项(小地图/轨迹/血条/颜色)沿用「1v1」设置(Settings.pvp_*),此处不重复摆放。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# 连接状态机 / 转连 worker / 按钮工厂都在基类 `LobbyPage` 里(与 1v1 匹配页共用)——
# 本文件只留大乱斗的差异:版式、建房与等待室两个面板、房间态渲染、超时梯顺序。

# 本页属于哪个模式 —— 回局凭据要按模式判(`can_rejoin_to(code, MODE)`,三张注册表房号空间共用)。
const MODE := PvpSession.MODE_ROYALE

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

	# 地址默认跟 1v1 页一致(取 `PvpSession.server_address`)。
	# ★ 2026-09-22 用户裁定:云服**同样支持**大乱斗 —— 原先这里硬编码 "127.0.0.1"、理由是
	#   "原作者云服不支持大乱斗",那条判断是错的,已删。
	_addr_edit = UiFactory.line_edit(self, Vector2(60, 120), Vector2(250, 40), "服务器地址", PvpSession.server_address)
	var addr_hint := UiFactory.label("朋友加入请填开服机的 IP(端口 7777);本机开服点「启动/重启本机服务器」(同目录需有 Cyancular Ruins Server.exe)", 16, Color(0.75, 0.8, 0.85))
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

	vb.add_child(UiFactory.label("—— 创建大乱斗房间%s ——" % (" · Beta 时间玩法" if PvpSession.beta_mode else ""), 32, UiFactory.C_ACCENT))
	_build_public_room_row(vb)
	_build_max_players_row(vb)
	_build_match_time_row(vb)

	_add_map_picker(vb)
	_add_time_params(vb)

	vb.add_child(UiFactory.label("禁用武器(房主生效,开局带进对局):", 32))
	_add_weapon_grid(vb, 10, func(cell: Node, type_id: int) -> void:
		# 本页要多记一笔:建房时读 _weapon_checks 的勾选态(1v1 页不留引用,直接读 Settings)
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("type_id", type_id)
		_weapon_checks.append(cb))

	# (自己角色颜色的选色行 D1 已**搬进等待室面板** —— 原先在这里,建房面板一进等待室就
	#  隐藏,于是"房间里没人能改颜色":房主建房后就看不到了,加入者从头到尾没见过。
	#  选色现在对**全员**开放在等待室里,开局 claim 时随 player_options 上发生效。)

	vb.add_child(UiFactory.label("(小地图/轨迹/血条等其余视觉项沿用「1v1」设置;\n复活一律满血,一局 5 分钟,击杀最多者胜)", 16, UiFactory.C_TEXT_DIM))

	var create := UiFactory.button("创 建 房 间", 32, Vector2(360, 54))
	create.pressed.connect(_on_create_pressed)
	vb.add_child(create)


# ── 建房面版的三个设置行(阶段 5.5:原先 _build_create_panel 是 69 净行的"一屏控件清单")──

# 公开/私密开关 + 邀请码输入框(私密时才显示 —— 勾选框直接控制输入框的 visible)。
func _build_public_room_row(vb: VBoxContainer) -> void:
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


func _build_max_players_row(vb: VBoxContainer) -> void:
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
func _build_match_time_row(vb: VBoxContainer) -> void:
	var trow := HBoxContainer.new()
	# 键是 "separation":HBox 只认它,h_separation 是 GridContainer 的键(写在这里会被存下但
	# 永不读取 = 死覆盖)。别照抄禁用武器网格那两行 —— 那个是 GridContainer,键不一样。
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
			disabled.append(int(cb.get_meta("type_id", 0)))
	_with_lobby(func() -> void:
		_status.text = "建房中…"
		_royale_ack = false
		_royale_sent_ms = Time.get_ticks_msec()
		var payload := {
			"is_public": _public_check.button_pressed,
			"invite_code": _create_invite_edit.text.strip_edges(),
			"max_players": int(_max_slider.value),
			"round_full_heal": false,
			"disabled_weapons": disabled,
		}
		payload.merge(_beta_payload())   # Beta 态追加 {"beta":true,"time":{...}};普通态空合入
		NetBusExt.rpc_id(1, "royale_create", payload))

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
		NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode))


# ── 服务器回复 ──
func _on_royale_rooms(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		var empty := UiFactory.label("暂无公开房间 —— 右侧「创建房间」开一把大乱斗", 32, Color(0.8, 0.85, 0.9))
		empty.custom_minimum_size = Vector2(620, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个公开房间(对局中的照列:自己的房可点(回局),别人的点不动)"
		return
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		# Beta 房与普通房互不可见(独立房间池的客户端侧;服务器侧 join 守卫是第二道)
		if bool(r.get("beta", false)) != PvpSession.beta_mode:
			continue
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var maxp := int(r.get("max_players", 4))
		# ★ 对局中的房**照列**但**点不动**(与 1v1 页同款:可见性与拒绝入房是同一件事的两半;
		#   服务端 `royale_join` / `team_join` 的 in_match 守卫才是那道保证)。
		# ★ 自己那间房是这一档的**唯一例外**(持凭据者点它 = 回局)—— 见紧随其后那一段。
		var in_match := bool(r.get("in_match", false))
		var occ := ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   " + ", ".join(names)
		var btn := UiFactory.button("房间 %s      %s%s" % [code,
				"对局中" if in_match else "%d/%d" % [players, maxp], occ], 32, Vector2(620, 46))
		# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**,这一档**可点**(点了走回局);
		#    不是我的房,才轮到「对局中 ⇒ disabled」那一档(前置计划交付的既有行为)。
		#    反过来写(先按 in_match 禁用)= 回局这一档连点都点不到,而**一行报错都没有**
		#    —— 表现只是"回到大厅后自己那间房是灰的,回不去"。
		var mine := PvpSession.can_rejoin_to(code, MODE)
		btn.disabled = in_match and not mine
		if btn.disabled:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.focus_mode = Control.FOCUS_ALL
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				# 我的房**且对局中** ⇒ `try_rejoin_row` 自己走回局并返回 true;否则走普通加入
				# ★ `in_match` 必须传进去(I2):自己那间**还没开局**的等待室要走普通加入。
				if not try_rejoin_row(code, in_match, MODE):
					_join_room(code, ""))
		_list_box.add_child(btn)
	_status.text = "共 %d 个公开房间(对局中的照列:自己的房可点(回局),别人的点不动)" % rooms.size()

# 房间实时状态 → 等待室面板
func _on_room_state(state: Dictionary) -> void:
	_in_room = true
	_royale_ack = true
	_my_room = state
	# ★ 记下自己这间房的房号(与 1v1 页 `_on_room_created`/`_on_room_joined` 同款):列表里那一行
	#   "是不是我的房"全靠它比(`can_rejoin_to`)。本页建房 / 点列表加入 / 填邀请码三条路
	#   **都只经这一个 handler**,故这一行就是本页唯一的记账点 —— 漏了它,回局入口对本页
	#   整个失效(房号恒空 ⇒ 自己那间房被当"别人的房"禁用),而**一行报错都没有**。
	# ★ 走 `note_room()` 而不是直接赋值:它顺手把**上一间房**的凭据作废(换了房号时)——
	#   等待室每收到一次房间状态都会走一遍本函数,同号时它是 no-op(见 `note_room` 的注释)。
	var code := str(state.get("code", ""))
	PvpSession.note_room(code, MODE)
	var my_role := _my_role_in(state)
	_host = int(state.get("host_role", 0)) == my_role
	if _create_panel != null:
		_create_panel.visible = false   # 进等待室:隐藏右列创建面板(与等待室并存太挤)
	if _wait_panel == null:
		_build_wait_panel()
	_wait_panel.visible = true
	var invite := str(state.get("invite_code", "")) if not bool(state.get("is_public", true)) else ""
	_wait_title.text = "—— 大乱斗房间 %s ——%s" % [code, "  邀请码 %s" % invite if invite != "" else ""]
	for c in _wait_players.get_children():
		c.queue_free()
	var plist: Array = state.get("players", [])
	var shown := 0   # 行序(1..N)——见下面那条注释:不能直接印 role
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var role := int(p.get("role", 0))
		var nm := str(p.get("name", "玩家"))
		var is_me := role == my_role
		var is_host := int(state.get("host_role", 0)) == role
		shown += 1
		# ★ 编号印**行序**,不印 role:role 是「最小空闲号」分配、且**有人退出后不重排**
		#   (这是 --roles 协议的前提,权威 role 稳定才认得出串线),直接印会跳号 ——
		#   3 人房中间那位退出 → 等待室显示 1、3(2026-09-15 用户报)。
		#   编号只是界面序号,与权威 role 脱钩;行序 = rr.players 的加入顺序。
		var row := UiFactory.label("%d. %s%s%s" % [shown, nm, "(我)" if is_me else "", "(房主)" if is_host else ""],
				32, UiFactory.C_TEXT if not is_me else UiFactory.C_ACCENT)
		_wait_players.add_child(row)
	_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [plist.size(), int(state.get("max_players", 4))]
	_start_btn.visible = _host

# 我在这个房间里是几号。★ 服务器按 peer **单独**下发的 `your_role`(见 lobby_rooms 的
# _flush_royale_state)—— 原先按**昵称**在名单里反查,两人同名(默认都叫 Anon)时会命中
# 先出现的那个 → (我)/(房主) 高亮错行、`_host` 判错 → 真房主看不到开局按钮。
func _my_role_in(state: Dictionary) -> int:
	return int(state.get("your_role", 0))

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
	# 自己角色颜色(D1,2026-09-29):等待室全员可改 —— 原先滑条只在建房面板,建房面板一进
	# 等待室就隐藏 ⇒ 房主建完房改不了、加入者全程没见过,"房间里自定义颜色"形同虚设。
	# 值即选即存 Settings.pvp_color_hue;开局转连 worker 时随 player_options 上发
	# → 服务器 _claim_hues 汇总 → match_sync 回包 → 自己(本地直染)与所有副本(他人视角)都按它染色。
	# (协议环路真链路探针实证双向带值,见 tests/royale_probe.gd 的 hues 断言。)
	vb.add_child(UiFactory.label("自己角色颜色(开局生效,所有人可见):", 32))
	_add_hue_row(vb, "", Vector2(320, 30), Vector2(46, 30))
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
	# 0) 回局(路径乙):请求发出后大厅 15s 无应答 —— 早于下面几条梯,因为此刻它们都还没启动
	if _tick_rejoin_timeout():
		return
	# 1) 转连 worker 12s 没连上(worker 死了/端口没放行):**回大厅重连 + 刷新列表**,
	#    不再只留一句提示让玩家干等在等待室里(本页原来没有任何恢复路径)。
	if _tick_worker_connect_timeout():
		return
	# 2) claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来):同样回大厅重连刷新
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	# 建房/加入 8s 无应答(地址不通 / 对端不是同版本的服务器)
	if not _royale_ack and _royale_sent_ms > 0 and Time.get_ticks_msec() - _royale_sent_ms > 8000:
		_royale_sent_ms = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"


# ── 基类钩子(本页实现)────────────────────────────────────────────

# 空地址回退:与 1v1 页同款,取会话里的服务器地址(不再特判本机)
func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


# 已在大乱斗房间中(先退出房间再操作):_with_lobby 在 _in_room 时拒绝一切操作,
# 不清房间态就再也刷不出列表/建不了房。
func _lobby_action_allowed() -> bool:
	if _in_room:
		_status.text = "已在大乱斗房间中(先退出房间再操作)"
		return false
	return true


func _send_list_request() -> void:
	# ★ 带上本端手里的回局凭据(B1 甲案):大厅据此把"本人自己那间**私密房**"也列出来
	#   —— 否则私密房里按 ESC 回主菜单的玩家在列表里找不到那一行,回局入口整个不存在。
	#   没有凭据时它就是 `""`,与从前逐字相同(PvpSession.token 的默认值)。
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)


# 大乱斗多一项 match_time(一局限时),回合回血恒 false(大乱斗规则里没有回合)
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": false,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict() if PvpSession.beta_mode else {},
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
