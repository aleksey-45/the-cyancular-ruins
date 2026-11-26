class_name LobbyCreatePanel
extends PanelContainer

# 联机建房表单，按当前对战模式提交地图、房间设置和规则选项。

signal submitted(mode: String, options: Dictionary, listed_nearby: bool)

signal preference_changed(value: Variant, key: StringName)

const MODES: Array[String] = [WorldSpec.DUEL, WorldSpec.TEAM, WorldSpec.ROYALE]

const DEFAULT_MAX_PLAYERS := 4.0

const PANEL_PAD := Vector2(UiDesign.SP_9, UiDesign.SP_6)
const TITLE_BUTTON := Vector2(UiDesign.SP_10, UiDesign.SP_9 + UiDesign.SP_2)  # 80×72
const COLUMN_GAP := UiDesign.SP_8
const BLOCK_GAP := UiDesign.SP_5
const ROW_GAP := UiDesign.SP_4
const FORM_LABEL_W := UiDesign.T_H2 * 10          # 320:表单标签列
const FORM_VALUE_W := UiDesign.T_H2 * 3 + UiDesign.SP_4   # 112:数值列
const SLIDER_MIN_W := UiDesign.SP_10 * 3          # 240:滑块最小宽
const ROW_MIN_H := UiDesign.SP_8                  # 48:表单行最小高,滑块/开关纵向对齐
const WEAPONS_H := UiDesign.SP_10 + UiDesign.SP_9 # 144:武器网格高度
const MAP_H := UiDesign.SP_10 * 3 + UiDesign.SP_5 # 264:地图网格高度
const TIME_SCROLL_H := UiDesign.SP_10 * 3         # 240:Beta 时间颗粒滚动区高度
const CANCEL_MIN := Vector2(UiDesign.SP_10 * 3 + UiDesign.SP_7, UiDesign.SP_10 + UiDesign.SP_2)
const SUBMIT_MIN := Vector2(UiDesign.SP_10 * 5, UiDesign.SP_10 + UiDesign.SP_2)

var _prefs: Dictionary
var _mode := WorldSpec.DUEL
var _mode_buttons: Dictionary = {}
var _collision := CheckButton.new()
var _listed_nearby := CheckButton.new()
var _full_heal := CheckButton.new()
var _limits: HBoxContainer
var _duration: HBoxContainer
var _heal_row: HBoxContainer
var _max_players: HSlider
var _match_time: HSlider
var _weapons_panel: VBoxContainer
var _weapons: WeaponPicker
var _map := MapPicker.new()


func _init(preferences: Dictionary) -> void:
	_prefs = preferences


func _ready() -> void:
	var body := UiDesign.skin_menu_panel(self, PANEL_PAD)
	var page := VBoxContainer.new()
	page.name = "Page"
	page.add_theme_constant_override("separation", UiDesign.SP_6)
	body.add_child(page)

	page.add_child(_build_title())
	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.add_theme_constant_override("separation", COLUMN_GAP)
	page.add_child(columns)
	columns.add_child(_build_options())
	columns.add_child(_build_gear())
	page.add_child(_build_actions())


# ── 标题行 ─────────────────────────────────────────────────────────────────
func _build_title() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "TitleRow"
	row.add_theme_constant_override("separation", ROW_GAP)
	var title := UiDesign.header_strip("创建房间", UiDesign.T_H1, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var close := UiDesign.ui_button("×", UiDesign.T_H2, TITLE_BUTTON, "quiet")
	close.name = "CloseBtn"
	close.tooltip_text = "关闭(Esc)"
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(hide)
	row.add_child(close)
	return row


# ── 左列:模式 / 开关 / 数值滑块 / Beta 时间颗粒 ─────────────────────────────
func _build_options() -> VBoxContainer:
	var options := VBoxContainer.new()
	options.name = "Options"
	options.add_theme_constant_override("separation", BLOCK_GAP)
	options.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var modes := HBoxContainer.new()
	modes.name = "Modes"
	modes.add_theme_constant_override("separation", ROW_GAP)
	options.add_child(modes)
	var group := ButtonGroup.new()
	for mode: String in MODES:
		var button := UiDesign.ui_button(PvpSession.MODE_NAMES[mode], UiDesign.T_H2, Vector2.ZERO,
				"quiet")
		button.toggle_mode = true
		button.button_group = group
		button.pressed.connect(_choose_mode.bind(mode))
		modes.add_child(button)
		_mode_buttons[mode] = button

	_collision.text = "玩家碰撞"
	_collision.name = "CollisionCheck"
	_collision.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	options.add_child(_collision)

	_listed_nearby.text = "对局域网展示房间卡片"
	_listed_nearby.name = "ListedNearbyCheck"
	_listed_nearby.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_listed_nearby.set_pressed_no_signal(true)
	options.add_child(_listed_nearby)

	_limits = _form_row(options, "LimitsRow")
	_max_players = _slider(_limits, "人数上限:", RoomOptions.ROYALE_PLAYERS, DEFAULT_MAX_PLAYERS,
			" 人")
	_duration = _form_row(options, "DurationRow")
	_match_time = _slider(_duration, "一局限时:", RoomOptions.ROYALE_MINUTES, _prefs["match_min"],
			" 分钟")
	_match_time.value_changed.connect(preference_changed.emit.bind(&"royale_match_min"))

	_heal_row = _form_row(options, "HealRow")
	_full_heal.text = "每回合开始回满血(房主生效)"
	_full_heal.name = "FullHealCheck"
	_full_heal.set_pressed_no_signal(_prefs["full_heal"])
	_full_heal.toggled.connect(preference_changed.emit.bind(&"pvp_round_full_heal"))
	_heal_row.add_child(_full_heal)

	if not _prefs["time"].is_empty():
		options.add_child(UiDesign.label("时间颗粒规则(房主可调,开局生效):", UiDesign.T_H2,
				UiDesign.C_ACCENT))
		# 颗粒参数可纵向滚动，避免在较小窗口中撑高表单。
		var scroll := ScrollContainer.new()
		scroll.name = "TimeScroll"
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.custom_minimum_size = Vector2(0, TIME_SCROLL_H)
		options.add_child(scroll)
		var beta := VBoxContainer.new()
		beta.name = "TimeRules"
		beta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		beta.add_theme_constant_override("separation", UiDesign.SP_3)
		scroll.add_child(beta)
		for field in TimeRules.FIELDS:
			if TimeRules.FIELDS[field][TimeRules.LABEL] != "": _time_slider(beta, field)
	return options


# ── 右列:禁用武器 + 地图 ───────────────────────────────────────────────────
func _build_gear() -> VBoxContainer:
	var gear := VBoxContainer.new()
	gear.name = "Gear"
	gear.add_theme_constant_override("separation", BLOCK_GAP)
	gear.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_weapons_panel = VBoxContainer.new()
	_weapons_panel.name = "Weapons"
	_weapons_panel.add_theme_constant_override("separation", UiDesign.SP_4)
	_weapons_panel.add_child(UiDesign.header_strip("禁用武器(房主生效,开局带进对局):",
			UiDesign.T_H2))
	_weapons = WeaponPicker.new(_disabled_ids(), 2, WEAPONS_H)
	_weapons.name = "WeaponPicker"
	_weapons.selection_changed.connect(func() -> void:
		preference_changed.emit(_weapons.disabled_weapons(), &"pvp_disabled_weapons"))
	_weapons_panel.add_child(_weapons)
	gear.add_child(_weapons_panel)

	_map.name = "MapPicker"
	gear.add_child(_map)
	_map.setup(_prefs["map"], MAP_H, "地图（房主选择）")
	_map.picked.connect(preference_changed.emit.bind(&"mp_map_path"))
	return gear


func _build_actions() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Actions"
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", BLOCK_GAP)
	var cancel := UiDesign.ui_button("取消", UiDesign.T_H2, CANCEL_MIN, "quiet")
	cancel.name = "CancelBtn"
	cancel.pressed.connect(hide)
	row.add_child(cancel)
	var submit := UiDesign.ui_button("创建房间", UiDesign.T_H2, SUBMIT_MIN, "gold")
	submit.name = "SubmitBtn"
	submit.pressed.connect(_submit)
	row.add_child(submit)
	return row


# ── 表单行 ─────────────────────────────────────────────────────────────────
func _form_row(parent: Control, node_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.custom_minimum_size = Vector2(0, ROW_MIN_H)
	row.add_theme_constant_override("separation", ROW_GAP)
	parent.add_child(row)
	return row


func _slider(row: BoxContainer, text: String, bounds: Vector2i, initial: float,
		suffix: String) -> HSlider:
	var label := UiDesign.ui_label(text, "body")
	label.custom_minimum_size.x = FORM_LABEL_W
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = bounds.x
	slider.max_value = bounds.y
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	row.add_child(slider)
	var value := UiDesign.ui_label("%d%s" % [int(slider.value), suffix], "body")
	value.custom_minimum_size.x = FORM_VALUE_W
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	slider.value_changed.connect(func(v: float) -> void: value.text = "%d%s" % [int(v), suffix])
	return slider


func _time_slider(parent: BoxContainer, field: String) -> void:
	var rule: Array = TimeRules.FIELDS[field]
	var units: float = rule[TimeRules.DISPLAY_SCALE]
	var suffix := "%" if units == 100.0 else ""
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_H)
	row.add_theme_constant_override("separation", ROW_GAP)
	parent.add_child(row)
	var label := UiDesign.ui_label(rule[TimeRules.LABEL], "body")
	label.custom_minimum_size.x = FORM_LABEL_W
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = rule[TimeRules.MINIMUM] * units
	slider.max_value = rule[TimeRules.MAXIMUM] * units
	slider.step = rule[TimeRules.STEP]
	slider.value = _prefs["time"][field] * units
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	row.add_child(slider)
	var value := UiDesign.label(str(int(round(_prefs["time"][field] * units))) + suffix,
			UiDesign.T_H2, UiDesign.C_ACCENT)
	value.custom_minimum_size.x = FORM_VALUE_W
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	slider.value_changed.connect(func(v: float) -> void:
		_prefs["time"][field] = v / units
		value.text = str(int(round(v))) + suffix)


func open(mode: String) -> void:
	_collision.set_pressed_no_signal(false)
	_listed_nearby.set_pressed_no_signal(true)
	_choose_mode(mode)
	show()
	_mode_buttons[mode].grab_focus()


func _choose_mode(mode: String) -> void:
	_mode = mode
	# 设置 button_pressed 会通知 ButtonGroup 取消原模式的选中状态。
	for key: String in _mode_buttons:
		(_mode_buttons[key] as Button).button_pressed = key == mode
	var fields: Array = RoomOptions.MODE_FIELDS[mode]
	_limits.visible = fields.has("max_players")
	_duration.visible = fields.has("match_time")
	_heal_row.visible = fields.has("round_full_heal")
	_weapons_panel.visible = fields.has("disabled_weapons")


func _submit() -> void:
	var options := {"map": _map.selected, "player_collision": _collision.button_pressed}
	var selected := {"disabled_weapons": _weapons.disabled_weapons(),
		"max_players": int(_max_players.value), "match_time": int(_match_time.value) * 60,
		"round_full_heal": _full_heal.button_pressed}
	for key in RoomOptions.MODE_FIELDS[_mode]:
		options[key] = selected[key]
	if not _prefs["time"].is_empty():
		options.merge({"beta": true, "time": _prefs["time"]})
	submitted.emit(_mode, options, _listed_nearby.button_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


func _disabled_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: Variant in _prefs["disabled"]:
		ids.append(int(id))
	return ids
