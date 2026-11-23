class_name LobbyCreatePanel
extends PanelContainer

# 大厅建房表单(UI 设计系统 v2):整块面板**容器化**,零绝对坐标、零手写 StyleBox/Color 字面量。
#
# ── 结构 ─────────────────────────────────────────────────────────────────────
#   UiDesign.skin_menu_panel(self, SP_9×SP_6) = 凿刻外框(PanelCarved) + 内衬 Body
#     └─ VBox(SP_6)
#         ├─ 标题行:HBox → header_strip(创建房间,T_H1,居中,expand) + ×(Quiet)
#         ├─ 两列 HBox(SP_8):左 = 模式/碰撞/LAN/人数/限时/回血/Beta 时间颗粒;右 = 禁用武器 + 地图
#         └─ 操作行 HBox(SP_5,右对齐):取消(Quiet) / 创建房间(Gold)
#   皮肤全部来自 UiDesign / Theme 2.0 variation(BtnPrimary/BtnQuiet/BtnGold/HeaderStrip…);
#   滑块用 Theme 的 HSlider 条目;开关用 UiDesign.ui_check()(Kit variation);字号/间距只用 T_* / SP_* token。
#
# ── 契约(与迁移前逐项等价;lobby_view 只依赖这些)──────────────────────────────
#   · LobbyCreatePanel.new(preferences: Dictionary) —— preferences 键:hue / match_min / full_heal /
#     disabled / map / time(由 scenes/mp_lobby.gd::_form_values 提供)。
#   · open(mode: String):重置玩家碰撞为关、LAN 展示为开,切到 mode,显示面板。
#   · signal submitted(mode, options):options 恒含 map / player_collision / lan_public;按
#     RoomOptions.MODE_FIELDS 追加 disabled_weapons / max_players / match_time(秒) / round_full_heal;
#     Beta 模式再并入 beta=true + 归一化后的 time。
#   · signal preference_changed(value, key):royale_match_min / pvp_round_full_heal /
#     pvp_disabled_weapons / mp_map_path(Beta 时间颗粒与旧实现一样只进 options,不写设置)。
#   · Esc 关闭面板(_unhandled_input),与旧实现一致。
#   · 不自带固定 rect:尺寸由内容驱动,调用方把它放进居中容器即可(当前由 lobby_view 负责)。
#
# ★ MapPicker / WeaponPicker 仍是 siri 旧组件(UI-5 范围),本文件不改它们,只把实例放进 v2 面板 ——
#   与已迁移的 SpLaunchPanel 采用同一处理方式。

signal submitted(mode: String, options: Dictionary)

signal preference_changed(value: Variant, key: StringName)

const TIME_FIELDS := [
	["initial", "初始颗粒", 50.0],
	["cap", "颗粒上限", 100.0],
	["rewind_burn", "回溯燃烧/秒", 5.0],
	["haste_burn", "加速燃烧/秒", 5.0],
	["window", "短时额度", 10.0],
	["regen", "回复/秒", 5.0],
	["kill_ratio", "击杀获取", 5.0],
	["block_gain", "拆砖获取/子格", 1.0],
	["damage_gain", "伤害获取/点", 1.0],
]

# 建房可选模式(顺序 = 旧 UiFactory.ROOM_FILTERS.slice(1));显示名统一取 PvpSession.MODE_NAMES。
const MODES: Array[String] = [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]

# 人数滑块的初始值(迁移前固定 4 人,是表单默认值不是布局尺寸)。
const DEFAULT_MAX_PLAYERS := 4.0

# 布局 token 组合(内容驱动的下限/间距,不是绝对坐标)。
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
var _mode := PvpSession.MODE_PVP
var _mode_buttons: Dictionary = {}
var _collision := UiDesign.ui_check()
var _lan_public := UiDesign.ui_check()
var _full_heal := UiDesign.ui_check()
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
	UiDesign.skin_menu_panel(self, PANEL_PAD)
	var body := get_node("Body") as Container
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
	var close := UiDesign.menu_button("×", UiDesign.T_H2, TITLE_BUTTON, "quiet")
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
		var button := UiDesign.menu_button(PvpSession.MODE_NAMES[mode], UiDesign.T_H2, Vector2.ZERO,
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

	_lan_public.text = "对局域网展示房间卡片"
	_lan_public.name = "LanPublicCheck"
	_lan_public.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_lan_public.set_pressed_no_signal(true)
	options.add_child(_lan_public)

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
		# 10 项颗粒参数在窄窗口下会顶高面板:限高 + 纵向滚动,横滚关闭,滚动条用 Kit 皮肤。
		var scroll := ScrollContainer.new()
		scroll.name = "TimeScroll"
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.custom_minimum_size = Vector2(0, TIME_SCROLL_H)
		scroll.get_v_scroll_bar().theme_type_variation = &"Kit"
		options.add_child(scroll)
		var beta := VBoxContainer.new()
		beta.name = "TimeRules"
		beta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		beta.add_theme_constant_override("separation", UiDesign.SP_3)
		scroll.add_child(beta)
		for spec: Array in TIME_FIELDS:
			_time_slider(beta, spec[0], spec[1], spec[2])
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
	_map.setup(_prefs["map"], 2, MAP_H, "地图(房主选;缩略图 = 开局地形简略图)")
	_map.picked.connect(preference_changed.emit.bind(&"mp_map_path"))
	return gear


func _build_actions() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Actions"
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", BLOCK_GAP)
	var cancel := UiDesign.menu_button("取消", UiDesign.T_H2, CANCEL_MIN, "quiet")
	cancel.name = "CancelBtn"
	cancel.pressed.connect(hide)
	row.add_child(cancel)
	var submit := UiDesign.menu_button("创建房间", UiDesign.T_H2, SUBMIT_MIN, "gold")
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


# 一行 = 定宽标签 + 滑块(吃满剩余宽) + 定宽数值;返回滑块。
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


func _time_slider(parent: BoxContainer, field: String, title: String, step: float) -> void:
	# 与旧实现同口径:kill_ratio 用百分比显示,其余按原始单位。
	var units := 100.0 if field == "kill_ratio" else 1.0
	var suffix := "%" if units == 100.0 else ""
	var rule: Array = TimeRules.FIELDS[field]
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_H)
	row.add_theme_constant_override("separation", ROW_GAP)
	parent.add_child(row)
	var label := UiDesign.ui_label(title, "body")
	label.custom_minimum_size.x = FORM_LABEL_W
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = rule[TimeRules.MINIMUM] * units
	slider.max_value = rule[TimeRules.MAXIMUM] * units
	slider.step = step
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


# ── 行为(与迁移前逐项等价)────────────────────────────────────────────────────
func open(mode: String) -> void:
	_collision.set_pressed_no_signal(false)
	_lan_public.set_pressed_no_signal(true)
	_choose_mode(mode)
	show()


func _choose_mode(mode: String) -> void:
	_mode = mode
	# 用 button_pressed(而非 set_pressed_no_signal)同步选中:no_signal 不会通知 ButtonGroup,
	# 连续 open()/切模式会让旧模式也保持高亮(两个模式同时亮)。
	for key: String in _mode_buttons:
		(_mode_buttons[key] as Button).button_pressed = key == mode
	var fields: Array = RoomOptions.MODE_FIELDS.get(mode, [])
	_limits.visible = fields.has("max_players")
	_duration.visible = fields.has("match_time")
	_heal_row.visible = fields.has("round_full_heal")
	_weapons_panel.visible = fields.has("disabled_weapons")


func _submit() -> void:
	var options := {"map": _map.selected, "player_collision": _collision.button_pressed,
			"lan_public": _lan_public.button_pressed}
	var selected := {"disabled_weapons": _weapons.disabled_weapons(),
		"max_players": int(_max_players.value), "match_time": int(_match_time.value) * 60,
		"round_full_heal": _full_heal.button_pressed}
	for key in RoomOptions.MODE_FIELDS.get(_mode, []):
		options[key] = selected[key]
	if not _prefs["time"].is_empty():
		options.merge({"beta": true, "time": TimeRules.normalized(_prefs["time"])})
	submitted.emit(_mode, options)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


# 设置里的禁用武器是 Array[int];显式收窄,避免把无类型 Array 传给 WeaponPicker 的 typed 参数。
func _disabled_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: Variant in _prefs["disabled"]:
		ids.append(int(id))
	return ids
