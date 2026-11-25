class_name LobbyView
extends Control

# 联机大厅视图(设计系统 v2):全部由容器 + UiKit/UiDesign token 构建,无绝对坐标、无手写 StyleBox、无 Color 字面量。
# 版式 = UiKit.page(Margin SP_6 → VBox SP_5)
#   标题(HeaderStrip) / 说明 / 工具栏(Bar:昵称 + 房间号 + 加入 + 创建)
#   / 筛选行(4 个 toggle) / 房间卡片列表(Card → ScrollContainer → LobbyRoomCard,空态覆盖)
#   / 状态条(StatusBar:状态文本 + 返回主菜单)
# 弹层 = 全屏 CenterContainer 居中的面板:
#   建房 = LobbyCreatePanel(自行套 v2 皮,本文件只负责显隐 + 遮罩)、
#   等待室 = LobbyWaitPanel(同上)、加入房间 = 本文件用 UiDesign.skin_menu_panel 自建的小对话框。
# ★ 保留 siri 的 LAN 契约与全部对外 signal(join_requested 带 endpoint)、mount / present_rooms /
#   set_status / select_filter / show_wait / close_create 入口;行为与迁移前等价。

signal nickname_changed(text: String)
signal filter_changed(mode: String)
signal create_requested(mode: String, options: Dictionary)
signal join_requested(code: String, endpoint: Dictionary)
signal room_chosen(code: String, endpoint: Dictionary)
signal copy_requested
signal team_requested(side: int)
signal start_requested
signal exit_room_requested
signal back_requested
signal preference_changed(value: Variant, key: StringName)

# 提供「全部」和三个对战模式筛选项，空字符串代表「全部」。
const FILTERS := [
	["", "全部"],
	[PvpSession.MODE_PVP, "1v1"],
	[PvpSession.MODE_TEAM, "团队对抗"],
	[PvpSession.MODE_ROYALE, "大乱斗"],
]
# 团队/大乱斗筛选的文字色(调色板单一来源 = UiDesign;其余筛选走 Theme 默认色)。
const FILTER_COLORS := {
	PvpSession.MODE_TEAM: UiDesign.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiDesign.C_MODE_ROYALE,
}
# 房间号输入框下限:6 个 H2 字宽(32 × 6 = 192,够放 8 位数字 + 内边距;内容驱动下限)。
const CODE_MIN_UNITS := 6
# 建房弹层的压暗量:0.55 与迁移前一致(颜色取 token,alpha 是本页版式参数,同 match_result)。
const DIM_ALPHA := 0.55
# 加入房间对话框的内容下限宽度:SP_10 × 6 = 480(内容驱动,不写固定 rect)。
const JOIN_MIN_W := UiDesign.SP_10 * 6
# 大厅内容区宽度上限为 1472 像素。在 1920 像素的逻辑视口中居中时，两侧各留 224 像素。
const PAGE_MAX_W := 1472

var _mode := ""
var _filters := {}
var _filters_row: HBoxContainer
var _create: LobbyCreatePanel
var _wait: LobbyWaitPanel
var _join: PanelContainer
var _join_code: LineEdit
var _code: LineEdit
var _browser: Control
var _scroll: ScrollContainer
var _list: VBoxContainer
var _rooms: Array[Dictionary] = []
var _cards: Array[LobbyRoomCard] = []
var _empty: Label
var _status: Label
var _create_button: Button
var _join_button: Button
var _create_mask: ColorRect
var _page_margin: MarginContainer


func mount(nickname: String, prefs: Dictionary) -> void:
	theme = UiDesign.MENU_THEME
	_build_background()
	_build_page(nickname)
	_build_overlays(prefs)


## 用当前发现的房间重建卡片列表;筛选在视图内完成。
func present_rooms(rooms: Array[Dictionary]) -> void:
	_rooms.clear()
	for room in rooms:
		_rooms.append(room.duplicate(true))
	_rebuild()


func select_filter(mode: String) -> void:
	_mode = mode
	for key in _filters:
		(_filters[key] as Button).button_pressed = key == mode
	_rebuild()


func set_status(message: String) -> void:
	_status.text = message


func show_wait(room: Dictionary) -> void:
	var open := not room.is_empty()
	if open:
		_join.hide()
		_create.hide()
		_wait.present(room)
	_wait.visible = open
	for item: Control in [_create_button, _join_button, _filters_row, _browser]:
		item.visible = not open
	_display_code(room.get("code", ""))


## 收起等待室(等价于 show_wait({}));保留独立入口便于外部显式关闭。
func close_wait() -> void:
	show_wait({})


func close_create() -> void:
	_create.hide()


func _build_background() -> void:
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiDesign.C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)


# ── 页面骨架 ────────────────────────────────────────────────────────────────

func _build_page(nickname: String) -> void:
	var page := UiKit.page(self)
	_page_margin = page.get_parent() as MarginContainer
	_apply_page_width()
	get_viewport().size_changed.connect(_apply_page_width)
	page.add_child(UiDesign.header_strip("—— 联机大厅 ——", UiDesign.T_H1, true))

	var hint := UiDesign.label("同网段房主的房间会自动出现在下方;也可输入 8 位房间号加入",
			UiDesign.T_SUB, UiDesign.C_TEXT_DIM)
	hint.name = "Hint"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(hint)

	_build_toolbar(page, nickname)
	_build_filters(page)
	_build_browser(page)
	_build_status(page)


func _apply_page_width() -> void:
	if _page_margin == null:
		return
	var side := maxi(int(UiDesign.SP_6), int((get_viewport_rect().size.x - PAGE_MAX_W) * 0.5))
	_page_margin.add_theme_constant_override("margin_left", side)
	_page_margin.add_theme_constant_override("margin_right", side)


func _build_toolbar(page: VBoxContainer, nickname: String) -> void:
	var bar := UiKit.toolbar(page)
	bar.name = "Toolbar"

	var nick_label := UiDesign.ui_label("昵称", "h2")
	nick_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(nick_label)

	var name_edit := UiDesign.ui_field()
	name_edit.name = "NameEdit"
	UiDesign.style_control(name_edit, UiDesign.T_H2)
	name_edit.text = nickname
	name_edit.placeholder_text = "昵称(头上显示)"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(nickname_changed.emit)
	bar.add_child(name_edit)

	var code_label := UiDesign.ui_label("房号", "h2")
	code_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(code_label)

	_code = UiDesign.ui_field()
	_code.name = "CodeEdit"
	UiDesign.style_control(_code, UiDesign.T_H2)
	_code.custom_minimum_size = Vector2(UiDesign.T_H2 * CODE_MIN_UNITS, 0)
	bar.add_child(_code)
	_display_code("")
	_code.text_submitted.connect(_join_clicked.unbind(1))

	_join_button = UiDesign.ui_button("加入房间", UiDesign.T_H2, Vector2.ZERO, "quiet")
	_join_button.name = "JoinBtn"
	_join_button.pressed.connect(_join_clicked)
	bar.add_child(_join_button)

	_create_button = UiDesign.ui_button("＋ 创建房间", UiDesign.T_H2, Vector2.ZERO, "primary")
	_create_button.name = "CreateBtn"
	_create_button.pressed.connect(_open_create)
	bar.add_child(_create_button)


func _build_filters(page: VBoxContainer) -> void:
	_filters_row = HBoxContainer.new()
	_filters_row.name = "Filters"
	_filters_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_filters_row.add_theme_constant_override("separation", UiDesign.SP_3)
	page.add_child(_filters_row)
	var group := ButtonGroup.new()
	for row: Array in FILTERS:
		var mode: String = row[0]
		var button := UiDesign.ui_button(row[1], UiDesign.T_H2, Vector2.ZERO, "quiet")
		button.name = "Filter" + (mode.capitalize() if not mode.is_empty() else "All")
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(UiDesign.SP_10 * 3, UiDesign.SP_9)
		if FILTER_COLORS.has(mode):
			# 模式色 = 调色板 token(选中/悬停也保持模式色,同迁移前 TeamFilter/RoyaleFilter 的语义)。
			button.add_theme_color_override("font_color", FILTER_COLORS[mode])
			button.add_theme_color_override("font_pressed_color", FILTER_COLORS[mode])
			button.add_theme_color_override("font_hover_color", FILTER_COLORS[mode])
		button.pressed.connect(filter_changed.emit.bind(mode))
		_filters[mode] = button
		_filters_row.add_child(button)


func _build_browser(page: VBoxContainer) -> void:
	var body := UiKit.card(page)
	var panel := body.get_parent().get_parent().get_parent() as PanelContainer
	panel.name = "Browser"
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_browser = panel

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.name = "List"
	_list.add_theme_constant_override("separation", UiDesign.SP_3)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	# 首帧(第一次 present_rooms 之前)只有空态:列表先收起,避免空 Scroll 与空态同显。
	_scroll.visible = false

	_empty = UiDesign.ui_label("暂无房间（可输入房码加入）", "dim")
	_empty.name = "Empty"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_empty)


func _build_status(page: VBoxContainer) -> void:
	var row := UiKit.status_bar(page)
	row.name = "StatusRow"

	_status = UiDesign.label("", UiDesign.T_SUB, UiDesign.C_TEXT_DIM)
	_status.name = "Status"
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	row.add_child(_status)

	var back := UiDesign.ui_button("返回主菜单", UiDesign.T_H2, Vector2.ZERO, "quiet")
	back.name = "BackBtn"
	back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(back_requested.emit)
	row.add_child(back)


# ── 弹层(建房 / 等待室 / 加入)──────────────────────────────────────────────

func _build_overlays(prefs: Dictionary) -> void:
	_create_mask = ColorRect.new()
	_create_mask.name = "CreateDim"
	_create_mask.color = UiDesign.C_BG
	_create_mask.modulate.a = DIM_ALPHA
	_create_mask.mouse_filter = Control.MOUSE_FILTER_STOP
	_create_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_mask.hide()
	add_child(_create_mask)

	var create_center := _overlay_center("CreateLayer")
	_create = LobbyCreatePanel.new(prefs)
	create_center.add_child(_create)
	_create.hide()
	_create.visibility_changed.connect(func() -> void: _create_mask.visible = _create.visible)
	_create.submitted.connect(create_requested.emit)
	_create.preference_changed.connect(preference_changed.emit)

	var wait_center := _overlay_center("WaitLayer")
	_wait = LobbyWaitPanel.new(prefs["hue"])
	wait_center.add_child(_wait)
	_wait.hide()
	_wait.copy_requested.connect(copy_requested.emit)
	_wait.team_requested.connect(team_requested.emit)
	_wait.start_requested.connect(start_requested.emit)
	_wait.exit_requested.connect(exit_room_requested.emit)
	_wait.hue_changed.connect(preference_changed.emit.bind(&"pvp_color_hue"))

	_build_join()


# 全屏 CenterContainer 居中摆放面板，鼠标输入由面板处理。
func _overlay_center(layer_name: String) -> CenterContainer:
	var center := CenterContainer.new()
	center.name = layer_name
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	return center


# 手输房号加入的小对话框(迁移前用 UiFactory.framed + 固定 rect;现在 PanelCarved + CenterContainer)。
func _build_join() -> void:
	_join = PanelContainer.new()
	_join.name = "JoinDialog"
	UiDesign.skin_menu_panel(_join, Vector2(UiDesign.SP_9, UiDesign.SP_7))
	var body := _join.get_node("Body") as PanelContainer
	var box := VBoxContainer.new()
	box.name = "Content"
	box.custom_minimum_size.x = JOIN_MIN_W
	box.add_theme_constant_override("separation", UiDesign.SP_4)
	body.add_child(box)

	var title := UiDesign.label("加入房间", UiDesign.T_H2, UiDesign.C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(title)

	_join_code = UiDesign.ui_field()
	_join_code.name = "JoinCodeEdit"
	UiDesign.style_control(_join_code, UiDesign.T_H2)
	_join_code.placeholder_text = "房间号"
	box.add_child(_join_code)

	var buttons := HBoxContainer.new()
	buttons.name = "Actions"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", UiDesign.SP_3)
	box.add_child(buttons)

	var cancel := UiDesign.ui_button("取消", UiDesign.T_H2, Vector2.ZERO, "quiet")
	cancel.pressed.connect(_join.hide)
	buttons.add_child(cancel)
	var ok := UiDesign.ui_button("加入", UiDesign.T_H2, Vector2.ZERO, "primary")
	ok.pressed.connect(_join_submitted)
	buttons.add_child(ok)

	_join.hide()
	_overlay_center("JoinLayer").add_child(_join)


func _join_submitted() -> void:
	_join.hide()
	var value := _join_code.text.strip_edges()
	if not value.is_empty():
		_code.text = value
	join_requested.emit(value, {})


# ── 列表 / 输入 ─────────────────────────────────────────────────────────────

func _rebuild() -> void:
	if _list == null:
		return
	for card in _cards:
		_list.remove_child(card)
		card.queue_free()
	_cards.clear()
	for room in _rooms:
		if not _mode.is_empty() and str(room.get("mode", "")) != _mode:
			continue
		var card := LobbyRoomCard.new()
		_list.add_child(card)
		card.present(room)
		card.join_requested.connect(join_requested.emit)
		_cards.append(card)
	_empty.visible = _cards.is_empty()
	_scroll.visible = not _cards.is_empty()


func _display_code(code: String) -> void:
	_code.text = code
	_code.editable = code.is_empty()
	_code.placeholder_text = "房间号" if code.is_empty() else "你的房间号(报给对手)"


func _open_create() -> void:
	_create.open(PvpSession.MODE_PVP if _mode.is_empty() else _mode)


func _join_clicked() -> void:
	var code := _code.text.strip_edges()
	if code.is_empty():
		_join.visible = not _join.visible
	else:
		join_requested.emit(code, {})
