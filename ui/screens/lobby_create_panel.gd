class_name LobbyCreatePanel
extends PanelContainer

signal submitted(mode: String, options: Dictionary)

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

signal preference_changed(value: Variant, key: StringName)

var _prefs: Dictionary
var _mode := PvpSession.MODE_PVP
var _buttons := {}
var _collision := CheckButton.new()
var _full_heal := CheckButton.new()
var _limits: BoxContainer
var _duration: BoxContainer
var _max_players: HSlider
var _match_time: HSlider
var _weapons_panel: BoxContainer
var _weapons: WeaponPicker
var _map := MapPicker.new()

func _init(preferences: Dictionary) -> void:
	_prefs = preferences

func _ready() -> void:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 32)
	UiFactory.fill_frame(self, body, Vector2(-1, -1))
	var title_row := UiFactory.box(body, 16, false)
	var title := UiFactory.header_strip("创建房间", 48, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	UiFactory.action(title_row, "×", Vector2(80, 72), &"BtnQuiet", hide)

	var columns := UiFactory.box(body, 48, false)
	var options := UiFactory.box(columns, 28, true)
	options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var modes := UiFactory.box(options, 16, false)
	var group := ButtonGroup.new()
	for row: Array in UiFactory.ROOM_FILTERS.slice(1):
		var button := UiFactory.room_filter(row, group)
		button.pressed.connect(_choose_mode.bind(row[0]))
		modes.add_child(button)
		_buttons[row[0]] = button
	_collision.text = "玩家碰撞"
	_collision.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	options.add_child(_collision)

	_limits = UiFactory.box(options, 16, false)
	_max_players = _slider(_limits, "人数上限:", RoomOptions.ROYALE_PLAYERS, 4.0, " 人")
	_duration = UiFactory.box(options, 16, false)
	_match_time = _slider(_duration, "一局限时:", RoomOptions.ROYALE_MINUTES, _prefs["match_min"], " 分钟")
	_match_time.value_changed.connect(preference_changed.emit.bind(&"royale_match_min"))
	var heal := UiFactory.box(options, 16, false)
	_full_heal.text = "每回合开始回满血(房主生效)"
	_full_heal.set_pressed_no_signal(_prefs["full_heal"])
	_full_heal.toggled.connect(preference_changed.emit.bind(&"pvp_round_full_heal"))
	heal.add_child(_full_heal)
	if not _prefs["time"].is_empty():
		var beta := UiFactory.box(options, 16, true)
		beta.add_child(UiFactory.label("时间颗粒规则(房主可调,开局生效):", 32, UiFactory.C_ACCENT))
		for spec: Array in TIME_FIELDS:
			_time_slider(beta, spec[0], spec[1], spec[2])

	var gear := UiFactory.box(columns, 28, true)
	gear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weapons_panel = UiFactory.box(gear, 16, true)
	_weapons_panel.add_child(UiFactory.header_strip("禁用武器(房主生效,开局带进对局):"))
	_weapons = WeaponPicker.new(_prefs["disabled"], 2, 144)
	_weapons.selection_changed.connect(func() -> void:
		preference_changed.emit(_weapons.disabled_weapons(), &"pvp_disabled_weapons"))
	_weapons_panel.add_child(_weapons)
	UiFactory.box(gear, 16, true).add_child(_map)
	_map.setup(_prefs["map"], 2, 260.0, "地图(房主选;缩略图 = 开局地形简略图)")
	_map.picked.connect(preference_changed.emit.bind(&"mp_map_path"))

	var actions := UiFactory.box(body, 24, false)
	actions.alignment = BoxContainer.ALIGNMENT_END
	UiFactory.action(actions, "取消", Vector2(280, 88), &"BtnQuiet", hide)
	UiFactory.action(actions, "创建房间", Vector2(400, 88), &"BtnGold", _submit)

func open(mode: String) -> void:
	_collision.set_pressed_no_signal(false)
	_choose_mode(mode)
	show()

func _choose_mode(mode: String) -> void:
	_mode = mode
	var fields: Array = RoomOptions.MODE_FIELDS.get(mode, [])
	_limits.visible = fields.has("max_players")
	_duration.visible = fields.has("match_time")
	_full_heal.get_parent().visible = fields.has("round_full_heal")
	_weapons_panel.visible = fields.has("disabled_weapons")
	for key in _buttons:
		_buttons[key].disabled = key == mode

func _submit() -> void:
	var options := {"map": _map.selected, "player_collision": _collision.button_pressed}
	var selected := {"disabled_weapons": _weapons.disabled_weapons(), "max_players": int(_max_players.value),
		"match_time": int(_match_time.value) * 60, "round_full_heal": _full_heal.button_pressed}
	for key in RoomOptions.MODE_FIELDS.get(_mode, []):
		options[key] = selected[key]
	if not _prefs["time"].is_empty():
		options.merge({"beta": true, "time": TimeRules.normalized(_prefs["time"])})
	submitted.emit(_mode, options)

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()

static func _slider(row: BoxContainer, text: String, bounds: Vector2i, initial: float, suffix: String) -> HSlider:
	row.add_child(UiFactory.label(text, 32))
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(300, 30)
	slider.min_value = bounds.x
	slider.max_value = bounds.y
	slider.value = initial
	row.add_child(slider)
	var label := UiFactory.label("%d%s" % [int(slider.value), suffix], 32, UiFactory.C_TEXT)
	row.add_child(label)
	slider.value_changed.connect(func(v: float) -> void: label.text = "%d%s" % [int(v), suffix])
	return slider

func _time_slider(parent: BoxContainer, field: String, title: String, step: float) -> void:
	var row := UiFactory.box(parent, 12, false)
	var units := 100.0 if field == "kill_ratio" else 1.0
	var suffix := "%" if units == 100.0 else ""
	var rule: Array = TimeRules.FIELDS[field]
	var label := UiFactory.label(title, 32)
	label.custom_minimum_size.x = 300
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = rule[TimeRules.MINIMUM] * units
	slider.max_value = rule[TimeRules.MAXIMUM] * units
	slider.step = step
	slider.value = _prefs["time"][field] * units
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(220, 28)
	row.add_child(slider)
	var value := UiFactory.label(str(int(round(_prefs["time"][field] * units))) + suffix, 32, UiFactory.C_ACCENT)
	value.custom_minimum_size.x = 110
	row.add_child(value)
	slider.value_changed.connect(func(v: float) -> void:
		_prefs["time"][field] = v / units
		value.text = str(int(round(v))) + suffix)
