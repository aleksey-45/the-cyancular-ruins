extends LobbyPage

# 3v3 团队大厅(**第三个**大厅页,与 1v1 `matchmaking` / 大乱斗 `royale_lobby` 并列):
# 建房(公开/私密+邀请码)/ 公开房间列表点击加入 / **选边等待室**(两队名单 + 未选边档 +
# 选边按钮 + 房主开局)。自建服务器(RoomManager → `--team` worker)。
# 协议走 NetBusExt 的 `team_*` 系列(六条上行 / 两条下行);开局**复用原版 go_match(role,port)**
# 转连 worker —— 那条 RPC 的签名与 1v1/大乱斗完全相同,故不另开协议。
# 视觉项(小地图/轨迹/血条)沿用「多人对战」设置(Settings.pvp_*),此处不重复摆放。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# 连接状态机 / 转连 worker / 按钮工厂都在基类 `LobbyPage` 里 —— 本文件只留 3v3 的差异:
# 版式、建房与等待室两个面板、房间态渲染(选边)、超时梯顺序。
#
# ★ 本页有两条**与大乱斗同款、与 1v1 不同**的纪律,别为"统一"改掉任何一条:
#   ① 超时梯顺序是 `[worker → claim → 大厅 → ack]`(1v1 是 `[worker → join → 大厅 → claim]`);
#   ② `_enter_match_scene` 必须 `call_deferred`(worker 的 match_start 在 NetBus.poll 调用栈内
#      到达,栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误;1v1 是直切)。
#
# ★ 首版** knowingly 不发**的规则项(照实登记,不是漏写):`_player_options()` 返回 `{}` ——
#   房主规则项(禁用武器/回合回血)与**角色色相**一律走默认。要真正接上,得等对局场景
#   (TeamHost 那半消费 player_options)落地后一并评估。
#   ★ 正因如此,建房面板里**没有**「禁用武器网格」与「角色色相行」两个区块(基类提供、
#     另两页都有)—— 原因见 _build_create_panel 里那段说明。

var _code_edit: LineEdit        # 房间号(加入)
var _invite_edit: LineEdit      # 邀请码(私密房加入)
var _team_ack := true        # 建房/加入后是否已收到服务器 team_room_state(8s 无应答兜底用)
var _team_sent_ms := 0

# ── 建房面板控件 ──
var _public_check: CheckButton
var _create_invite_edit: LineEdit

# ── 等待室(选边)──
var _wait_panel: PanelContainer = null
var _create_panel: PanelContainer = null   # 右列创建面板(进等待室时隐藏)
var _wait_title: Label
var _wait_players: VBoxContainer
var _wait_count: Label
var _start_btn: Button
var _pick_a: Button
var _pick_b: Button
var _in_room := false
var _my_room := {}     # 最近一次 team_room_state
var _host := false


func _ready() -> void:
	# 根 Control 默认尺寸 0×0:居中面板(PRESET_CENTER)按零尺寸父级计算会飞到屏幕外
	# (自测实测等待室在 (-320,-149));设满矩形锚点让根铺满 1920×1440 视口
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()

	# ── 左列:昵称 / 服务器 / 房间列表 / 房间号+邀请码加入 ──
	var name_le := UiFactory.line_edit(self, Vector2(60, 60), Vector2(250, 40), "昵称(对局内显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	# 3v3 协议在 NetBusExt(自建服务端才有):原作者云服不支持 → 默认本机,不默认云地址
	_addr_edit = UiFactory.line_edit(self, Vector2(60, 120), Vector2(250, 40), "服务器地址(3v3=自建服)", "127.0.0.1")
	var addr_hint := UiFactory.label("3v3 需自建服务器:点「启动/重启本机服务器」即可本机开服(同目录需有 Cyancular Ruins Server.exe);朋友加入填开服机 IP(异地用 VPN 组网);原作者云服不支持 3v3", 16, UiFactory.C_TEXT)
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

	var cap := UiFactory.label("公开 3v3 房间列表(点击直接加入)", 32, UiFactory.C_ACCENT)
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
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state)

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

	vb.add_child(UiFactory.label("—— 创建 3v3 房间 ——", 32, UiFactory.C_ACCENT))
	_build_public_room_row(vb)
	# ★ 没有「人数上限」与「一局限时」两个滑块(大乱斗页有):3v3 里这两个都不是自由度 ——
	#   开局条件就是"两队各 3 人"(房容量恒 TEAM_ROLES),赛制是三局两胜(没有可调的整局时长)。
	#   换行拆成两截:32px 下这行整串约 800px,会顶破 620 宽的面板(与 royale 页的尾注同款处理)。
	#   ★ 两个数引常量而不是写字面量:与 max_players/team_size 两处的缺省值同源,改一处不用改三处。
	vb.add_child(UiFactory.label("%d 人房(每队 %d 人);进房后自己选边\n—— 房主点开始(两队各 %d 人才可开局)" % [
			LobbyRooms.TEAM_ROLES, LobbyRooms.TEAM_SIZE, LobbyRooms.TEAM_SIZE], 32))

	# ★★ 这里**刻意没有**「禁用武器网格」与「角色色相行」两个区块(基类提供、1v1 与大乱斗页都有)。
	#   3v3 **用队色、不用个人色相**(设计 §0 第 12 条:队色覆盖个人色相 —— 个人 hue 在本模式是
	#   无效输入);禁用武器则不在 3v3 的规则表里,`_player_options()` 返回 `{}`,服务端也不会应用它。
	#   ★ 更要紧的是那两个勾选框**写的是 `Settings.pvp_disabled_weapons`** —— 那是 1v1 / 大乱斗的
	#     设置项:在 3v3 页勾一下会**连带改掉另两个模式**。那属于功能缺陷(点了没反应、又污染别人),
	#     不是审美问题,故不留给"UI 重做那份"。
	vb.add_child(UiFactory.label("(本页没有禁用武器与个人角色颜色这两项:\n3v3 用队色、个人色相无效;禁用武器是 1v1/大乱斗的设置项)\n(小地图/轨迹/血条等本机显示项沿用「多人对战」设置;\n房主规则项首版不上发,对局内按默认值)", 16, UiFactory.C_TEXT_DIM))

	var create := UiFactory.button("创 建 房 间", 32, Vector2(360, 54))
	create.pressed.connect(_on_create_pressed)
	vb.add_child(create)


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


# ── 动作 ──
func _on_create_pressed() -> void:
	_with_lobby(func() -> void:
		_status.text = "建房中…"
		_team_ack = false
		_team_sent_ms = Time.get_ticks_msec()
		NetBusExt.rpc_id(1, "team_create", {
			"is_public": _public_check.button_pressed,
			"invite_code": _create_invite_edit.text.strip_edges(),
		}))

func _on_join_pressed() -> void:
	_join_room(_code_edit.text.strip_edges(), _invite_edit.text)

func _join_room(code: String, invite: String) -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_status.text = "加入房间 %s …" % code
		_team_ack = false
		_team_sent_ms = Time.get_ticks_msec()
		NetBusExt.rpc_id(1, "team_join", code, invite))


# ── 服务器回复 ──
func _on_team_rooms(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		var empty := UiFactory.label("暂无公开房间 —— 右侧「创建房间」开一把 3v3", 32, UiFactory.C_TEXT)
		empty.custom_minimum_size = Vector2(620, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个公开房间(对局中的照列但不可进)"
		return
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var maxp := int(r.get("max_players", LobbyRooms.TEAM_ROLES))
		# ★ 对局中的房**照列**但**点不动**(与 1v1 页同款:可见性与拒绝入房是同一件事的两半;
		#   服务端 `royale_join` / `team_join` 的 in_match 守卫才是那道保证)。
		var in_match := bool(r.get("in_match", false))
		var occ := ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   " + ", ".join(names)
		var btn := UiFactory.button("房间 %s      %s%s" % [code,
				"对局中" if in_match else "%d/%d" % [players, maxp], occ], 32, Vector2(620, 46))
		btn.disabled = in_match
		if in_match:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				_join_room(code, ""))
		_list_box.add_child(btn)
	_status.text = "共 %d 个公开房间(对局中的照列但不可进)" % rooms.size()


# 等待室:两队名单 + 未选边档 + 选边按钮 + 房主开局按钮。
# ★ 编号印**行序**而不是 role(role 是最小空闲号分配、有人退会留空洞 —— 与 royale 页同一坑)。
func _on_room_state(state: Dictionary) -> void:
	_in_room = true
	_team_ack = true
	_my_room = state
	var my_role := int(state.get("your_role", 0))
	_host = int(state.get("host_role", 0)) == my_role
	if _create_panel != null:
		_create_panel.visible = false
	if _wait_panel == null:
		_build_wait_panel()
	_wait_panel.visible = true
	var code := str(state.get("code", ""))
	var invite := str(state.get("invite_code", "")) if not bool(state.get("is_public", true)) else ""
	_wait_title.text = "—— 3v3 房间 %s ——%s" % [code, "  邀请码 %s" % invite if invite != "" else ""]
	for c in _wait_players.get_children():
		c.queue_free()
	var plist: Array = state.get("players", [])
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", LobbyRooms.TEAM_SIZE))
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		var head := "%s(%d/%d)" % [tag, (buckets[t] as Array).size(), team_size]
		_wait_players.add_child(UiFactory.label("—— %s ——" % head, 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			_wait_players.add_child(UiFactory.label(_row_text(p, my_role, state), 32,
					_row_color(p, my_role)))
	if not (buckets[0] as Array).is_empty():
		_wait_players.add_child(UiFactory.label("—— 未选边 ——", 32, UiFactory.C_TEXT_DIM))
		for p in buckets[0]:
			# ★ 未选边档同样按 _row_color 上色(自己那行**也要高亮**):原先这档一律 C_TEXT,
			#   于是"自己还没选边"时唯一能认出自己的只有那个 `(我)` 标记,那行不亮。
			_wait_players.add_child(UiFactory.label(_row_text(p, my_role, state), 32,
					_row_color(p, my_role)))
	var mine := int(state.get("your_role", 0))
	# ★ 自己那支的按钮**置灰**:既少一次无意义的上行,也让「已在该队时再点该队」那条
	#   `team_pick` 幂等 wart(服务器回"该队已满"、状态不变)不可达。
	_pick_a.visible = _team_of_role(state, mine) != 1
	_pick_b.visible = _team_of_role(state, mine) != 2
	# ★ 分母引常量而不是写 "6"/"3":与 max_players/team_size 两处的缺省值同源 —— 容量只有一个
	#   真值来源(TEAM_ROLES=房容量、TEAM_SIZE=每队人数),写死的话 TEAM_SIZE 一改这行就**撒谎**且不报错。
	_wait_count.text = "%d / %d 人(已选边 %d 人;两队各 %d 人才可开局)" % [
			plist.size(), LobbyRooms.TEAM_ROLES,
			(buckets[1] as Array).size() + (buckets[2] as Array).size(), team_size]
	_start_btn.visible = _host and _both_ready(buckets, team_size)


func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


func _both_ready(buckets: Dictionary, size: int) -> bool:
	return (buckets[1] as Array).size() == size and (buckets[2] as Array).size() == size


func _row_text(p: Dictionary, my_role: int, state: Dictionary) -> String:
	var role := int(p.get("role", 0))
	return "%s%s%s" % [p.get("name", "玩家"), "(我)" if role == my_role else "",
			"(房主)" if role == int(state.get("host_role", 0)) else ""]


# 名单行的配色:自己那行高亮(C_ACCENT),别人 C_TEXT。**两档共用同一个真值来源** ——
# 队内行与「未选边」行都得按它上色(未选边档曾经漏掉 → 自己没选边时那行不亮)。
func _row_color(p: Dictionary, my_role: int) -> Color:
	return UiFactory.C_ACCENT if int(p.get("role", 0)) == my_role else UiFactory.C_TEXT


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
	_wait_count = UiFactory.label("", 32, UiFactory.C_TEXT)
	vb.add_child(_wait_count)
	_pick_a = UiFactory.button("加入 A 队", 32, Vector2(170, 48))
	_pick_a.pressed.connect(func() -> void: NetBusExt.rpc_id(1, "team_pick", 1))
	vb.add_child(_pick_a)
	_pick_b = UiFactory.button("加入 B 队", 32, Vector2(170, 48))
	_pick_b.pressed.connect(func() -> void: NetBusExt.rpc_id(1, "team_pick", 2))
	vb.add_child(_pick_b)
	_start_btn = UiFactory.button("开 始 游 戏", 32, Vector2(360, 56))
	_start_btn.pressed.connect(func() -> void:
		_status.text = "开局中…"
		NetBusExt.rpc_id(1, "team_start"))
	vb.add_child(_start_btn)
	var leave := UiFactory.button("退出房间", 32, Vector2(360, 48))
	leave.pressed.connect(_on_leave_room)
	vb.add_child(leave)
	add_child(_wait_panel)
	# 居中锚点必须在入树之后设置:未入树时父级尺寸为 0,面板会飞到屏幕左上角外(自测实测)
	_wait_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_wait_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wait_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# 「退出房间」**不断开大厅 peer**(与大乱斗同款):服务端据此判空房并走拆除收口归还端口;
# 断开 peer 会走 on_peer_left 那条另一路径,两处都关房 = 同一件事有两个实现。
func _on_leave_room() -> void:
	NetBusExt.rpc_id(1, "team_leave")
	_in_room = false
	_my_room = {}
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true   # 退房恢复创建面板
	_request_list.call_deferred("已退出房间")


# 转连 worker 12s 没连上(worker 死了/端口没放行)→ 回大厅重连 + 刷新列表;
# claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来)同样回大厅。
# ★ 本页的梯顺序是 `[worker → claim → 大厅 → ack]`,与大乱斗页逐字同款;**别重排**
#   (1v1 页是 `[worker → join → 大厅 → claim]` —— 两条顺序不同,合并会静默改行为)。
func _process(_delta: float) -> void:
	# 1) 转连 worker 12s 没连上(worker 死了/端口没放行):**回大厅重连 + 刷新列表**
	if _tick_worker_connect_timeout():
		return
	# 2) claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来):同样回大厅重连刷新
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	# 建房/加入 8s 无应答:NetBusExt 协议在自建服务端才有,原作者云服会静默丢弃
	if not _team_ack and _team_sent_ms > 0 and Time.get_ticks_msec() - _team_sent_ms > 8000:
		_team_sent_ms = 0
		_status.text = "8 秒无响应——该服务器不支持 3v3(需自建最新服务端:开服方双击 start_server.bat),或地址不通"


# ── 基类钩子(本页实现)────────────────────────────────────────────

# 3v3 与大乱斗同:协议只在自建服上有 → 空地址回退本机,不回退云地址
func _lobby_fallback_addr() -> String:
	return "127.0.0.1"


# 已在 3v3 房间中(先退出房间再操作):_with_lobby 在 _in_room 时拒绝一切操作,
# 不清房间态就再也刷不出列表/建不了房。
func _lobby_action_allowed() -> bool:
	if _in_room:
		_status.text = "已在 3v3 房间中(先退出房间再操作)"
		return false
	return true


func _send_list_request() -> void:
	NetBusExt.rpc_id(1, "team_list")


# 3v3 首版不上发房主规则项(禁用武器/回合回血都走默认,角色色相亦然);本机视觉项
# (小地图/轨迹/血条)沿用 Settings(pvp_*),由对局场景自己读,不经服务器。
func _player_options() -> Dictionary:
	return {}


func _go_match_status() -> String:
	return "已配对,正在进入 3v3 对局…"


func _on_worker_connect_failed() -> void:
	_return_to_lobby("连接对局服务器失败,已返回大厅")


func _worker_timeout_msg() -> String:
	return "连接对局服务器超时(端口需放行 UDP)——已返回大厅"


func _claim_timeout_msg() -> String:
	return "等待开局超时(可能有人掉线)——已返回大厅"


# 清房间态是必须的:_with_lobby 在 _in_room 时拒绝一切操作,不清就再也刷不出列表/建不了房。
func _on_return_to_lobby() -> void:
	_in_room = false
	_my_room = {}
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true


# RPC 在 NetBus.poll 调用栈内到达(worker→客户端 match_start);直接在栈内切场景会
# 在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(与大乱斗那条同因;1v1 是直切)。
# 延迟到帧末再切。
func _enter_match_scene() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://scenes/team_game.tscn")
