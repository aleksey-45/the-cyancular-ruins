extends Control

# 统一联机大厅：集成 1v1、大乱斗与团队对抗三种对战模式的房间浏览、创建、加入与等待逻辑。
# 界面自上而下包含顶栏（玩家昵称）、模式筛选与操作按钮、房间卡片以及底部状态栏。

var _status: Label
var _code_edit: LineEdit
var _requesting := false

var _mode := ""
var _listed_room: Dictionary
var _card: Button
var _empty_card: Label
var _card_mode: Label
var _card_status: Label
var _card_code: Label
var _card_rules: Label
var _card_thumbnail: TextureRect
var _card_thumbnail_fill: ColorRect
var _card_count: Label
var _card_host: Label
var _card_roster: Label
var _filter_btns := {}             # 模式到筛选按钮的映射
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null

var _create_panel: PanelContainer = null
var _create_mask: ColorRect = null
var _create_mode := PvpSession.MODE_PVP
var _create_mode_btns := {}
var _max_slider: HSlider = null
var _time_slider: HSlider = null

var _wait_panel: PanelContainer = null
var _wait_title: Button = null
var _wait_body: VBoxContainer = null
var _wait_count: Label = null
var _wait_hue: Control = null
var _wait_start: Button = null
var _wait_pick_a: Button = null
var _wait_pick_b: Button = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

	_finish_lobby_ready()

	# 处理预选进入的筛选模式
	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)


func _build_ui() -> void:
	# 顶栏昵称输入框
	var name_le: LineEdit = %NameEdit
	name_le.text = PvpSession.player_name
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		NetSession.send_hello())

	# 模式筛选按钮与加入/创建入口
	_filter_btns = {}
	for f in [["", %FilterAll], [PvpSession.MODE_PVP, %FilterPvp],
			[PvpSession.MODE_TEAM, %FilterTeam], [PvpSession.MODE_ROYALE, %FilterRoyale]]:
		var m: String = f[0]
		var b: Button = f[1]
		b.button_pressed = (m == _mode)
		b.pressed.connect(func() -> void: _set_filter(m))
		_filter_btns[m] = b
	_code_edit = %CodeEdit
	_update_code_label("")
	_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	%CreateBtn.pressed.connect(_open_create_dialog)
	%JoinBtn.pressed.connect(_on_join_pressed)

	_build_room_card()
	_status = %StatusLabel
	%BackBtn.pressed.connect(_on_back_pressed)

	# 加入房间面板
	_join_panel = %JoinPanel
	_join_code_edit = %JoinCodeEdit
	_join_panel.visible = false
	%JoinOkBtn.pressed.connect(func() -> void:
		_join_panel.visible = false
		var code := _join_code_edit.text.strip_edges()
		if not code.is_empty():
			_code_edit.text = code
		_join_code(code))
	%JoinCancelBtn.pressed.connect(func() -> void: _join_panel.visible = false)

	# 创建房间弹窗与参数表单
	_create_mask = %CreateMask
	_create_mask.visible = false
	_create_panel = %CreatePanel
	_create_panel.visible = false
	%CreateCloseBtn.pressed.connect(func() -> void: _set_create_visible(false))
	%CreateCancelBtn.pressed.connect(func() -> void: _set_create_visible(false))
	%CreateOkBtn.pressed.connect(_on_create_pressed)

	_create_mode_btns = {PvpSession.MODE_PVP: %CreateModePvp,
			PvpSession.MODE_TEAM: %CreateModeTeam, PvpSession.MODE_ROYALE: %CreateModeRoyale}
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		(_create_mode_btns[m] as Button).pressed.connect(func() -> void: _apply_create_form(m))

	_max_slider = %MaxPlayersSlider
	_max_slider.value_changed.connect(func(v: float) -> void:
		(%MaxPlayersLabel as Label).text = "%d 人" % int(v))

	_time_slider = %MatchTimeSlider
	_time_slider.value = Settings.royale_match_min
	(%MatchTimeLabel as Label).text = "%d 分钟" % int(Settings.royale_match_min)
	_time_slider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		(%MatchTimeLabel as Label).text = "%d 分钟" % int(v))

	%FullHealCheck.button_pressed = Settings.pvp_round_full_heal
	%FullHealCheck.toggled.connect(func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save())

	# 禁用武器网格
	_add_weapon_grid(%WeaponsBlock)

	# 地图选择器
	_add_map_picker(%MapBlock)

	# Beta 模式参数
	%BetaBlock.visible = PvpSession.beta_mode
	_add_time_params(%BetaBlock)

	# 等待室面板初始化
	_wait_panel = %WaitPanel
	_wait_panel.visible = false
	_wait_title = %WaitTitle
	_wait_title.pressed.connect(_copy_room_code)
	_wait_body = %WaitBody
	_wait_count = %WaitCount
	_wait_hue = %WaitHueRow
	_wait_pick_a = %WaitPickABtn
	_wait_pick_b = %WaitPickBBtn
	_wait_start = %WaitStartBtn

	_wait_pick_a.pressed.connect(_on_wait_pick.bind(1))
	_wait_pick_b.pressed.connect(_on_wait_pick.bind(2))
	_wait_start.pressed.connect(_on_wait_start_pressed)
	%WaitLeaveBtn.pressed.connect(_on_wait_leave_pressed)

	var hue_slider: HSlider = %WaitHueSlider
	var hue_chip: ColorRect = %WaitHueChip
	hue_slider.value = Settings.pvp_color_hue
	hue_chip.color = UiFactory.hue_preview_color(Settings.pvp_color_hue)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		hue_chip.color = UiFactory.hue_preview_color(v))


func _on_back_pressed() -> void:
	NetSession.close()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# 切换模式筛选并重绘房卡列表
func _set_filter(mode: String) -> void:
	_mode = mode
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)
	_refresh_room_card()


func _on_room(state: Dictionary) -> void:
	PvpSession.room = state
	var code: String = state["code"]
	if state["host_role"] == state["your_role"]:
		var error := "" if Tunnel.on_network(code) else Tunnel.start_host(NetBus.server_port, code)
		_status.text = "房间 %s 已创建" % code
		_status.text += "，把房间号报给对手" if error.is_empty() else "。远程联机不可用，%s" % error
	else:
		_status.text = "已加入房间 %s" % code
	_show_wait_room(state)

const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}

func _build_room_card() -> void:
	_empty_card = UiFactory.label("暂无房间", 32, UiFactory.C_TEXT_DIM)
	%RoomBrowser.add_child(_empty_card)
	_card = Button.new()
	_card.custom_minimum_size = Vector2(420, 520)
	_card.pressed.connect(_open_listed_room)
	%RoomBrowser.add_child(_card)
	var normal := UiFactory.panel_box()
	normal.set_border_width_all(1)
	var highlighted := normal.duplicate() as StyleBoxFlat
	highlighted.border_color = UiFactory.C_ACCENT
	for style in ["normal", "disabled"]:
		_card.add_theme_stylebox_override(style, normal)
	for style in ["hover", "pressed", "focus"]:
		_card.add_theme_stylebox_override(style, highlighted)

	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inside := UiFactory.panel_box(false)
	inside.draw_center = false
	frame.add_theme_stylebox_override("panel", inside)
	_card.add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 12)
	frame.add_child(content)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_mode = UiFactory.label("", 32)
	_card_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_status = UiFactory.label("", 16)
	header.add_child(_card_mode)
	header.add_child(_card_status)
	content.add_child(header)
	_card_code = UiFactory.label("", 48, UiFactory.C_TEXT)
	_card_rules = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	content.add_child(_card_code)
	content.add_child(_card_rules)

	var details := HBoxContainer.new()
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_theme_constant_override("separation", 20)
	content.add_child(details)
	_card_thumbnail_fill = ColorRect.new()
	_card_thumbnail_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_thumbnail_fill.custom_minimum_size = Vector2(120, 120)
	details.add_child(_card_thumbnail_fill)
	_card_thumbnail = TextureRect.new()
	_card_thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_card_thumbnail_fill.add_child(_card_thumbnail)
	_card_thumbnail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_count = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_card_host = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_card_host.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta.add_child(_card_count)
	meta.add_child(_card_host)
	details.add_child(meta)
	_card_roster = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_card_roster.add_theme_constant_override("line_spacing", 4)
	content.add_child(_card_roster)
	_refresh_room_card()

func _refresh_room_card() -> void:
	var room := _listed_room
	_card.visible = not room.is_empty() and (_mode.is_empty() or room["mode"] == _mode)
	_empty_card.visible = not _card.visible
	if not _card.visible:
		return
	var mode: String = room["mode"]
	var in_match: bool = room["in_match"]
	_card.disabled = in_match and not PvpSession.can_rejoin_to(room["code"], mode)
	_card.focus_mode = Control.FOCUS_NONE if _card.disabled else Control.FOCUS_ALL
	_card.modulate.a = 0.55 if _card.disabled else 1.0
	_card_mode.text = PvpSession.mode_name(mode, room["beta"])
	_card_mode.add_theme_color_override("font_color", MODE_COLOR[mode])
	_card_status.text = "对局中" if in_match else "等待中"
	_card_status.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM if in_match else UiFactory.C_ACCENT)
	_card_code.text = room["code"]
	_card_rules.text = _card_subtitle(mode, room)
	_card_count.text = "人数 %d / %d" % [room["count"], room["max_players"]]
	_card_host.text = "房主 %s" % room["host_name"]
	var map := MapFormat.load_map(room["map"])
	_card_thumbnail.texture = MapCatalog.texture(map) if not map.is_empty() else null
	_card_thumbnail_fill.color = Color(MODE_COLOR[mode], 0.25) if map.is_empty() else UiFactory.C_SURFACE
	var roster: Array = room["players"]
	var names := PackedStringArray()
	for i in mini(roster.size(), 3):
		var player: Dictionary = roster[i]
		names.append("· %s%s" % [UiFactory.fit_name(player["name"], 14),
				"(房主)" if player["role"] == room["host_role"] else ""])
	if roster.size() > 3:
		names.append("…等 %d 人" % roster.size())
	_card_roster.text = "\n".join(names)

func _open_listed_room() -> void:
	Sfx.play("ui")
	if _listed_room["in_match"]:
		_request_rejoin()
	else:
		_join_code(_listed_room["code"])

func _card_subtitle(mode: String, room: Dictionary) -> String:
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(room["match_time"]) / 60
		return "限时 %d 分" % mins if mins > 0 else "不限时"
	if mode == PvpSession.MODE_TEAM:
		var counts: Dictionary = room["team_counts"]
		return "A%d / B%d / 未选%d" % [counts[1], counts[2], counts[0]]
	return "三局两胜"


func _toggle_join_panel() -> void:
	_join_panel.visible = not _join_panel.visible


func _on_join_pressed() -> void:
	var code := _code_edit.text.strip_edges()
	if not code.is_empty():
		_join_code(code)
	else:
		_toggle_join_panel()


func _join_code(code: String) -> void:
	if not Tunnel.is_valid_room(code):
		_status.text = "房间码是 8 位数字(例 00048213)"
		return
	if not _begin_request("正在连接房间 %s 的网络…" % code):
		return
	_listed_room = {}
	_refresh_room_card()
	_finish_request(await NetSession.join_room(code))

func _open_create_dialog() -> void:
	_create_mode = _mode if _mode != "" else PvpSession.MODE_PVP
	_apply_create_form(_create_mode)
	_set_create_visible(true)


func _set_create_visible(v: bool) -> void:
	_create_panel.visible = v
	_create_mask.visible = v


# 根据选择的模式动态展示相关设置项
func _apply_create_form(mode: String) -> void:
	_create_mode = mode
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	%MaxPlayersRow.visible = is_royale
	%MatchTimeRow.visible = is_royale
	%FullHealRow.visible = is_pvp
	%WeaponsBlock.visible = not is_team
	for m in _create_mode_btns:
		(_create_mode_btns[m] as Button).disabled = false
	(_create_mode_btns[mode] as Button).disabled = true


# 构建创建房间的配置载荷
func _create_payload(mode: String) -> Dictionary:
	var d := {"map": Settings.mp_map_path}
	if mode != PvpSession.MODE_TEAM:
		d["disabled_weapons"] = WeaponRegistry.all_ids().filter(
				func(id: int) -> bool: return Settings.pvp_disabled_weapons.has(id))
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = int(_max_slider.value)
		d["match_time"] = int(_time_slider.value) * 60
	elif mode == PvpSession.MODE_PVP:
		d["round_full_heal"] = Settings.pvp_round_full_heal
	return d


# 发送创建房间请求
func _on_create_pressed() -> void:
	var mode := _create_mode
	var payload := _create_payload(mode)
	if WeaponRegistry.enabled_ids(payload.get("disabled_weapons", [])).is_empty():
		_status.text = "请至少启用一种武器"
		return
	if not _begin_request("正在创建房间…"):
		return
	payload.merge(_beta_payload())
	_set_create_visible(false)
	_listed_room = {}
	_refresh_room_card()
	_finish_request(await NetSession.create_room({"mode": mode, "options": payload}))

func _unhandled_input(ev: InputEvent) -> void:
	if not _create_panel.visible:
		return
	if ev.is_action_pressed("ui_cancel"):
		_set_create_visible(false)
		get_viewport().set_input_as_handled()


# 刷新并展示等待室面板
func _show_wait_room(state: Dictionary) -> void:
	_set_create_visible(false)
	_join_panel.visible = false
	_set_wait_room_visible(true)
	var mode: String = state["mode"]
	_wait_title.text = "%s房间 %s" % [PvpSession.mode_name(mode, state["beta"]), state["code"]]

	for c in _wait_body.get_children():
		_wait_body.remove_child(c)
		c.queue_free()

	var my_role := int(state.get("your_role", 0))
	var host_role := int(state.get("host_role", 0))
	var is_host := host_role == my_role
	var plist: Array = state.get("players", [])
	var is_pvp := mode == PvpSession.MODE_PVP
	var is_team := mode == PvpSession.MODE_TEAM

	if is_pvp:
		_fill_flat_roster(plist, my_role, host_role)
		_wait_count.text = "%d / 2 人" % plist.size()
		_wait_count.text += "（由房主开始）" if plist.size() == 2 else "（等待对手加入）"
	elif mode == PvpSession.MODE_ROYALE:
		_fill_flat_roster(plist, my_role, host_role)
		_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [
				plist.size(), int(state.get("max_players", 4))]
	else:
		_fill_team_roster(plist, my_role, host_role)
		_wait_count.text = _team_count_text(state)

	_wait_hue.visible = not is_team
	var my_team := _team_of_role(state, my_role) if is_team else 0
	_wait_pick_a.visible = is_team and my_team != 1
	_wait_pick_b.visible = is_team and my_team != 2
	_wait_start.visible = is_host and state["can_start"]


func _set_wait_room_visible(show: bool) -> void:
	_wait_panel.visible = show
	%CreateBtn.visible = not show
	%JoinBtn.visible = not show
	%RoomBrowser.visible = not show
	for button: Button in _filter_btns.values():
		button.visible = not show
	_update_code_label(PvpSession.room_code if show else "")
	_refresh_room_card()

func _on_wait_pick(team: int) -> void:
	NetBus.send_event(NetEvent.Kind.PICK_TEAM, team)

func _on_wait_start_pressed() -> void:
	NetBus.send_event(NetEvent.Kind.START)

func _on_wait_leave_pressed() -> void:
	NetBus.send_event(NetEvent.Kind.LEAVE)
	_close_wait_room("已退出房间")

func _copy_room_code() -> void:
	var code := PvpSession.room_code
	DisplayServer.clipboard_set(code)
	_status.text = "已复制房间号：%s" % code

func _fill_flat_roster(plist: Array, my_role: int, host_role: int) -> void:
	var shown := 0
	for p: Dictionary in plist:
		shown += 1
		_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


func _fill_team_roster(plist: Array, my_role: int, host_role: int) -> void:
	var buckets := {1: [], 2: []}
	for p: Dictionary in plist:
		var t := int(p["team"])
		(buckets[t] as Array).append(p)
	var shown := 0
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		_wait_body.add_child(UiFactory.label("—— %s(%d/%d) ——" % [
				tag, (buckets[t] as Array).size(), TeamRules.MAX_TEAM], 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			shown += 1
			_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role: int = p["role"]
	var l := UiFactory.label("%d. %s%s%s" % [n, p["name"],
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	return l


func _team_of_role(state: Dictionary, role: int) -> int:
	for p: Dictionary in state["players"]:
		if p["role"] == role:
			return int(p["team"])
	return 0


func _team_count_text(state: Dictionary) -> String:
	var counts: Dictionary = state["team_counts"]
	return "A %d/%d、B %d/%d，共 %d/%d" % [
			counts[1], TeamRules.MAX_TEAM, counts[2], TeamRules.MAX_TEAM,
			state["count"], TeamRules.MAX_TOTAL]


func _begin_request(message: String) -> bool:
	if _requesting or _wait_panel.visible:
		return false
	_requesting = true
	_status.text = message
	return true

func _finish_request(message: String) -> void:
	_requesting = false
	if is_inside_tree() and not message.is_empty():
		_status.text = message

func _list_rooms() -> void:
	var error := await NetSession.list_rooms()
	if is_inside_tree() and not _requesting and not error.is_empty():
		_status.text = error

func _close_wait_room(message: String) -> void:
	PvpSession.room = {}
	_listed_room = {}
	_set_wait_room_visible(false)
	_status.text = message
	_list_rooms()

func _finish_lobby_ready() -> void:
	Tunnel.ensure_relay_file()
	NetBus.event_received.connect(_on_net_event)
	NetBus.protocol_error.connect(_on_connection_error)
	NetBus.server_disconnected.connect(_on_connection_error.bind("与房间的连接已断开"))
	UiFactory.apply_font_recursive(self)
	if NetBus.can_send_to_server() and not PvpSession.room.is_empty() and not PvpSession.room["in_match"]:
		NetSession.send_hello()
		_on_room(PvpSession.room)
	else:
		_list_rooms.call_deferred()

func _on_net_event(_peer: int, kind: int, data: Variant) -> void:
	if kind in NetEvent.MATCH_EVENTS:
		if PvpSession.loading_match:
			PvpSession.match_events.append([kind, data])
		return
	match kind:
		NetEvent.Kind.MESSAGE: _status.text = data
		NetEvent.Kind.ROOM: _on_room(data)
		NetEvent.Kind.ROOM_LIST:
			_listed_room = data
			_refresh_room_card()
		NetEvent.Kind.REJOIN_DENIED:
			PvpSession.clear_rejoin()
			_refresh_room_card()
			_status.text = "无法回到对局：%s" % data
			_list_rooms()
		NetEvent.Kind.ROOM_CLOSED: _close_wait_room(data)
		NetEvent.Kind.BASELINE:
			var map := MapFormat.parse_map(data["map"], "房间 %s" % data["code"])
			if map.is_empty():
				_status.text = "对局地图无法读取"
				return
			PvpSession.begin_match(data, map)
			Level0.safe_change_scene(get_tree(), "res://scenes/pvp_game.tscn")

func _exit_tree() -> void:
	NetBus.event_received.disconnect(_on_net_event)
	NetBus.protocol_error.disconnect(_on_connection_error)
	NetBus.server_disconnected.disconnect(_on_connection_error.bind("与房间的连接已断开"))

func _on_connection_error(message: String) -> void:
	_listed_room = {}
	_set_wait_room_visible(false)
	_status.text = message

const WEAPON_GRID_HEIGHT := 144.0

func _add_weapon_grid(parent: Node) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", 20)
	wgrid.add_theme_constant_override("v_separation", 6)
	parent.add_child(UiFactory.scroll_list(wgrid, WEAPON_GRID_HEIGHT))
	for type_id: int in WeaponRegistry.all_ids():
		var cell := WeaponIcons.make_weapon_check(type_id, Settings.pvp_disabled_weapons.has(type_id),
				32, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(type_id):
					Settings.pvp_disabled_weapons.append(type_id)
				elif not on:
					Settings.pvp_disabled_weapons = Settings.pvp_disabled_weapons.filter(
							func(id: int) -> bool: return id != type_id)
				Settings.save())
		wgrid.add_child(cell)


func _request_rejoin() -> void:
	if not _begin_request("正在回到对局…"):
		return
	_finish_request(NetSession.room_error(await NetSession.rejoin_room()))

func _update_code_label(code: String) -> void:
	_code_edit.text = code
	_code_edit.editable = code.is_empty()
	_code_edit.placeholder_text = "房间号" if code.is_empty() else "你的房间号(报给对手)"


var time_rules := TimeRules.normalized()

func _add_time_params(vb: VBoxContainer) -> void:
	if not PvpSession.beta_mode:
		return
	vb.add_child(UiFactory.label("时间颗粒规则(房主可调,开局生效):", 32, UiFactory.C_ACCENT))
	for slider in [
		["initial", "初始颗粒", 50.0],
		["cap", "颗粒上限", 100.0],
		["rewind_burn", "回溯燃烧/秒", 5.0],
		["haste_burn", "加速燃烧/秒", 5.0],
		["window", "短时额度", 10.0],
		["regen", "回复/秒", 5.0],
		["kill_ratio", "击杀获取", 5.0],
		["block_gain", "拆砖获取/子格", 1.0],
		["damage_gain", "伤害获取/点", 1.0],
	]:
		_trow(vb, slider[0], slider[1], slider[2])


func _trow(vb: VBoxContainer, field: String, text: String, step: float) -> void:
	var as_percent := field == "kill_ratio"
	var units := 100.0 if as_percent else 1.0
	var range_spec: Array = TimeRules.FIELDS[field]
	var initial: float = time_rules[field] * units
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UiFactory.label(text, 32)
	l.custom_minimum_size = Vector2(300, 0)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = range_spec[TimeRules.MINIMUM] * units
	sl.max_value = range_spec[TimeRules.MAXIMUM] * units
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
		time_rules[field] = v / units
		val.text = _fmt_param(v, as_percent))
	vb.add_child(row)

static func _fmt_param(v: float, as_percent: bool) -> String:
	return ("%d%%" % int(round(v))) if as_percent else str(int(round(v)))

func _beta_payload() -> Dictionary:
	if not PvpSession.beta_mode:
		return {}
	return {"beta": true, "time": TimeRules.normalized(time_rules)}

func _add_map_picker(vb: VBoxContainer) -> void:
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.mp_map_path, 2, 260.0, "地图(房主选;缩略图 = 开局地形简略图)")
	Settings.mp_map_path = picker.selected
	picker.picked.connect(func(p: String) -> void:
		Settings.mp_map_path = p
		Settings.save())
