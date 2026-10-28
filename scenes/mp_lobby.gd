extends LobbyPage

# 统一联机大厅：集成 1v1、大乱斗与 3v3 三种对战模式的房间浏览、创建、加入与等待逻辑。
# 界面自上而下包含顶栏（玩家昵称）、模式筛选与操作按钮、房间卡片网格以及底部状态栏。
# 服务端各模式房间注册表通过并发查询在前端合并汇总显示。

const PAGE_MARGIN := 76.0
const CARD_COLUMNS := 4
const CARD_GAP := 24.0

var _mode := ""                    # 当前模式筛选：空串表示全部，否则为 PvpSession.MODE_*
var _rooms_by_mode := {}           # 模式到房间条目列表的映射
var _grid: GridContainer = null
var _filter_btns := {}             # 模式到筛选按钮的映射
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null

var _create_panel: PanelContainer = null
var _create_mask: ColorRect = null
var _form_rows := {}
var _create_mode := PvpSession.MODE_PVP
var _create_mode_btns := {}
var _public_check: CheckButton = null
var _invite_edit: LineEdit = null
var _max_slider: HSlider = null
var _time_slider: HSlider = null
var _weapon_checks: Array[CheckButton] = []

var _wait_panel: PanelContainer = null
var _wait_title: Label = null
var _wait_body: VBoxContainer = null
var _wait_count: Label = null
var _wait_hue: Control = null
var _wait_start: Button = null
var _wait_pick_a: Button = null
var _wait_pick_b: Button = null
var _wait_leave: Button = null
var _wait_mode := ""
var _in_room := false
var _create_btn: Button = null
var _join_btn: Button = null

var _current_mode := ""
var _ack := true
var _sent_ms := 0
var _join_pending := ""


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
		_push_lobby_name())

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
	_update_code_label()
	if _code_edit != null:
		_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	_create_btn = %CreateBtn
	_create_btn.pressed.connect(_open_create_dialog)
	_join_btn = %JoinBtn
	_join_btn.pressed.connect(_on_join_pressed)

	_grid = %CardGrid
	_status = %StatusLabel
	%BackBtn.pressed.connect(_on_back_pressed)

	# 加入房间面板
	_join_panel = %JoinPanel
	_join_code_edit = %JoinCodeEdit
	_join_invite_edit = %JoinInviteEdit
	_join_panel.visible = false
	%JoinOkBtn.pressed.connect(func() -> void:
		_join_panel.visible = false
		var code := _join_code_edit.text.strip_edges()
		if not code.is_empty() and _code_edit != null:
			_code_edit.text = code
		_join_code(code, _mode, _join_invite_edit.text))
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

	_public_check = %PublicCheck
	_invite_edit = %InviteEdit
	_public_check.button_pressed = true
	_invite_edit.visible = false
	_public_check.toggled.connect(func(on: bool) -> void:
		_invite_edit.visible = not on)

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

	_form_rows = {
		"privacy": %PrivacyRow, "max_players": %MaxPlayersRow, "match_time": %MatchTimeRow,
		"full_heal": %FullHealRow, "weapons": %WeaponsBlock, "map": %MapBlock,
		"beta": %BetaBlock,
	}

	# 禁用武器网格
	_add_weapon_grid(%WeaponsBlock, 20, func(cell: Node, type_id: int) -> void:
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("type_id", type_id)
		_weapon_checks.append(cb))

	# 地图选择器
	_add_map_picker(%MapBlock)

	# Beta 模式参数
	%BetaBlock.visible = PvpSession.beta_mode
	_add_time_params(%BetaBlock)

	# 等待室面板初始化
	_wait_panel = %WaitPanel
	_wait_panel.visible = false
	_wait_title = %WaitTitle
	_wait_body = %WaitBody
	_wait_count = %WaitCount
	_wait_hue = %WaitHueRow
	_wait_pick_a = %WaitPickABtn
	_wait_pick_b = %WaitPickBBtn
	_wait_start = %WaitStartBtn
	_wait_leave = %WaitLeaveBtn

	_wait_pick_a.pressed.connect(_on_wait_pick.bind(1))
	_wait_pick_b.pressed.connect(_on_wait_pick.bind(2))
	_wait_start.pressed.connect(_on_wait_start_pressed)
	_wait_leave.pressed.connect(_on_wait_leave_pressed)

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
	_redraw_cards()


# 汇总各模式服务端下发的房间数据
func _on_rooms(rooms: Array) -> void:
	_rooms_by_mode = {"pvp": [], "team": [], "royale": []}
	for room: Dictionary in rooms:
		_rooms_by_mode[room["mode"]].append(room)
	_ack = true
	_sent_ms = 0
	_redraw_cards()

func _on_room(state: Dictionary) -> void:
	PvpSession.note_room(state["code"], state["mode"])
	PvpSession.role = state["your_role"]
	PvpSession.token = state["token"]
	PvpSession.room = state
	_current_mode = state["mode"]
	_room_code = state["code"]
	_update_code_label()
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	var is_host: bool = state["host_role"] == state["your_role"]
	if is_host and not Tunnel.on_network(_room_code) and Tunnel.available():
		Tunnel.start_host(PvpSession.server_port, _room_code)
	_set_room_entered_status(_room_code, is_host)
	_show_wait_room(state, _current_mode)

func _redraw_cards() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		var rows: Array = _rooms_by_mode.get(mode, []).duplicate()
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_full := int(a.get("count", 0)) >= int(a.get("max_players", 2))
			var b_full := int(b.get("count", 0)) >= int(b.get("max_players", 2))
			return not a_full and b_full)
		for r in rows:
			total += 1
			if _mode != "" and mode != _mode:
				continue
			_grid.add_child(_make_card(r))
			shown += 1
	if shown == 0:
		var empty := UiFactory.label("暂无房间 —— 点「＋ 创建房间」开一局吧", 32, UiFactory.C_TEXT_DIM)
		_grid.add_child(empty)
	_status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]


const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "3 v 3",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}


# 创建单张房间卡片按钮
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	_style_card(btn)
	btn.custom_minimum_size = Vector2(_card_width(), 440)
	btn.size = Vector2(_card_width(), 440)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""

	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 1.0
	frame.offset_top = 1.0
	frame.offset_right = -1.0
	frame.offset_bottom = -1.0
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)
	fsb.border_color = UiFactory.C_INNER
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(0)
	fsb.content_margin_left = 26.0
	fsb.content_margin_right = 26.0
	fsb.content_margin_top = 20.0
	fsb.content_margin_bottom = 20.0
	frame.add_theme_stylebox_override("panel", fsb)
	btn.add_child(frame)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 12)
	frame.add_child(col)

	col.add_child(_card_header(mode, r))
	col.add_child(_card_body(r))

	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			_current_mode = mode
			if not try_rejoin_row(code, in_match, mode):
				_join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


# 创建卡片顶部信息条
func _card_header(mode: String, r: Dictionary) -> Control:
	var strip := PanelContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = UiFactory.C_BORDER
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	strip.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	strip.add_child(row)

	var name_l := UiFactory.label(str(MODE_LABEL[mode]), 32, MODE_COLOR[mode])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)

	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var badge := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	var badge_col := UiFactory.C_TEXT_DIM if in_match 			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	var badge_l := UiFactory.label(badge, 16, badge_col)
	badge_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(badge_l)
	return strip


func _style_card(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _card_box(UiFactory.C_BORDER))
	b.add_theme_stylebox_override("hover", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("pressed", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("focus", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("disabled", _card_box(UiFactory.C_BORDER))


func _card_box(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_SURFACE
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	return sb


# 创建卡片主体内容
func _card_body(r: Dictionary) -> Control:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)

	box.add_child(UiFactory.label(str(r.get("code", "")), 48, UiFactory.C_TEXT))
	box.add_child(UiFactory.label(_card_subtitle(mode, r), 32, UiFactory.C_TEXT_DIM))

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_theme_constant_override("separation", 20)
	mid.add_child(_card_map_thumb(mode, str(r.get("map", ""))))
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("count", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host_name", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get(1, 0)), int(tc.get(2, 0)), int(tc.get(0, 0))]
	return "%s · 三局两胜" % pub


func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture = MapCatalog.texture(map_path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.add_child(tex)
	else:
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = MODE_COLOR[mode]
		fill.color.a = 0.25
		frame.add_child(fill)
	return frame


func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				16, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 16, UiFactory.C_TEXT_DIM))
	return box


# 发送并发房间查询请求
func _send_list_request() -> void:
	NetBus.send_event(NetEvent.Kind.LIST, {"token": PvpSession.token, "beta": PvpSession.beta_mode})









func _on_server_message(text: String) -> void:
	_ack = true
	_sent_ms = 0
	_join_pending = ""
	_status.text = text

func _toggle_join_panel() -> void:
	_join_panel.visible = not _join_panel.visible


func _on_join_pressed() -> void:
	var code := _code_edit.text.strip_edges() if _code_edit != null else ""
	if not code.is_empty():
		_join_code(code, _mode)
	else:
		_toggle_join_panel()


# 根据房间号与模式发起加入请求
func _join_code(code: String, _mode_hint: String, invite: String = "") -> void:
	_join_with_code(code, func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		_join_pending = code
		NetBus.send_event(NetEvent.Kind.JOIN, {"code": code, "invite": invite, "beta": PvpSession.beta_mode}))

func _open_create_dialog() -> void:
	_create_mode = _mode if _mode != "" else PvpSession.MODE_PVP
	_apply_create_form(_create_mode)
	_set_create_visible(true)


func _set_create_visible(v: bool) -> void:
	_create_panel.visible = v
	_create_mask.visible = v


# 收集当前勾选的禁用武器列表
func _checked_weapons() -> Array:
	var out: Array = []
	for cb in _weapon_checks:
		if cb.button_pressed:
			out.append(int(cb.get_meta("type_id", 0)))
	return out


# 根据选择的模式动态展示相关设置项
func _apply_create_form(mode: String) -> void:
	_create_mode = mode
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	_form_rows["max_players"].visible = is_royale
	_form_rows["match_time"].visible = is_royale
	_form_rows["full_heal"].visible = is_pvp
	_form_rows["weapons"].visible = not is_team
	_form_rows["privacy"].visible = not is_pvp
	for m in _create_mode_btns:
		(_create_mode_btns[m] as Button).disabled = false
	(_create_mode_btns[mode] as Button).disabled = true


# 构建创建房间的配置载荷
func _create_payload(mode: String) -> Dictionary:
	var d := {
		"is_public": _public_check.button_pressed,
		"invite_code": _invite_edit.text.strip_edges(),
		"map": Settings.mp_map_path,
	}
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = int(_max_slider.value)
		d["match_time"] = int(_time_slider.value) * 60
		d["round_full_heal"] = false
		d["disabled_weapons"] = _checked_weapons()
	elif mode == PvpSession.MODE_PVP:
		d["disabled_weapons"] = _checked_weapons()
	return d


# 发送创建房间请求
func _on_create_pressed() -> void:
	_set_create_visible(false)
	if not await _ensure_own_server():
		return
	var payload := _create_payload(_create_mode)
	payload["round_full_heal"] = Settings.pvp_round_full_heal
	payload.merge(_beta_payload())
	NetBus.send_event(NetEvent.Kind.CREATE, {"mode": _create_mode, "options": payload})
	_status.text = "正在建房…"

func _unhandled_input(ev: InputEvent) -> void:
	if not _create_panel.visible:
		return
	if ev.is_action_pressed("ui_cancel"):
		_set_create_visible(false)
		get_viewport().set_input_as_handled()


# 刷新并展示等待室面板
func _show_wait_room(state: Dictionary, mode: String) -> void:
	_wait_mode = mode
	_set_create_visible(false)
	_wait_panel.visible = true
	_in_room = true
	_create_btn.visible = false
	_join_btn.visible = false
	_join_panel.visible = false
	_wait_title.text = _wait_title_text(state, mode)

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
		_fill_team_roster(state, plist, my_role, host_role)
		_wait_count.text = _team_count_text(state, plist)

	_wait_hue.visible = not is_team
	var my_team := _team_of_role(state, my_role) if is_team else 0
	_wait_pick_a.visible = is_team and my_team != 1
	_wait_pick_b.visible = is_team and my_team != 2
	if is_pvp:
		_wait_start.visible = is_host and plist.size() == 2
	elif mode == PvpSession.MODE_ROYALE:
		_wait_start.visible = is_host
	else:
		_wait_start.visible = is_host and _both_teams_full(
				state, int(state.get("team_size", 3)))


# 隐藏等待室面板并恢复入口按钮
func _hide_wait_room() -> void:
	_wait_panel.visible = false
	_in_room = false
	_create_btn.visible = true
	_join_btn.visible = true


func _on_wait_pick(team: int) -> void:
	NetBus.send_event(NetEvent.Kind.PICK_TEAM, team)

func _on_wait_start_pressed() -> void:
	NetBus.send_event(NetEvent.Kind.START, 0)

func _on_wait_leave_pressed() -> void:
	_return_to_lobby("已退出房间")

func _wait_title_text(state: Dictionary, mode: String) -> String:
	var code := str(state.get("code", ""))
	var invite := ""
	if not bool(state.get("is_public", true)):
		invite = "  邀请码 %s" % str(state.get("invite_code", ""))
	return "—— %s房间 %s ——%s" % [str(MODE_LABEL.get(mode, mode)), code, invite]


func _fill_flat_roster(plist: Array, my_role: int, host_role: int) -> void:
	var shown := 0
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		shown += 1
		_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


func _fill_team_roster(state: Dictionary, plist: Array, my_role: int, host_role: int) -> void:
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", 3))
	var shown := 0
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		_wait_body.add_child(UiFactory.label("—— %s(%d/%d) ——" % [
				tag, (buckets[t] as Array).size(), team_size], 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			shown += 1
			_wait_body.add_child(_roster_row(shown, p, my_role, host_role))
	if not (buckets[0] as Array).is_empty():
		_wait_body.add_child(UiFactory.label("—— 未选边 ——", 32, UiFactory.C_TEXT_DIM))
		for p in buckets[0]:
			shown += 1
			_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role := int(p.get("role", 0))
	var l := UiFactory.label("%d. %s%s%s" % [n, str(p.get("name", "玩家")),
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	l.set_meta("roster_row", true)
	return l


func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


func _both_teams_full(state: Dictionary, size: int) -> bool:
	var counts := {1: 0, 2: 0}
	for p in state.get("players", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if counts.has(t):
			counts[t] += 1
	return counts[1] == size and counts[2] == size


func _team_count_text(state: Dictionary, plist: Array) -> String:
	var picked := 0
	for p in plist:
		if typeof(p) == TYPE_DICTIONARY and int(p.get("team", 0)) != 0:
			picked += 1
	return "%d / %d 人(已选边 %d 人;两队各 %d 人才可开局)" % [
			plist.size(), 6, picked,
			int(state.get("team_size", 3))]




func _enter_match_scene() -> void:
	Level0.safe_change_scene(get_tree(), "res://scenes/pvp_game.tscn")

func _process(_delta: float) -> void:
	if _tick_rejoin_timeout():
		return
	_tick_lobby_connect_timeout()
	if not _ack and _sent_ms > 0 and Time.get_ticks_msec() - _sent_ms > 8000:
		_sent_ms = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"


# 房间状态操作门控
func _lobby_action_allowed() -> bool:
	if _in_room:
		if _current_mode == PvpSession.MODE_ROYALE:
			_status.text = "已在大乱斗房间中(先退出房间再操作)"
		elif _current_mode == PvpSession.MODE_TEAM:
			_status.text = "已在 3v3 房间中(先退出房间再操作)"
		else:
			_status.text = "已在 1v1 房间中(先退出房间再操作)"
		return false
	return true


# 收集玩家开局配置选项
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict() if (PvpSession.beta_mode
				and _current_mode != PvpSession.MODE_PVP) else {},
	}








func _on_return_to_lobby() -> void:
	_sent_ms = 0
	_room_code = ""
	_update_code_label()
	_hide_wait_room()

func _on_room_closed() -> void:
	_on_return_to_lobby()
	_send_list_request()


func _on_lobby_reconnect() -> void:
	_rooms_by_mode.clear()
	_room_code = ""
	_update_code_label()
	_redraw_cards()
