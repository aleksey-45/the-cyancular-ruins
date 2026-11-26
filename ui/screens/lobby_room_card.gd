class_name LobbyRoomCard
extends Button

signal join_requested(code: String)

const CARD_MIN_H := UiDesign.SP_9 + UiDesign.SP_8

var _frame: MarginContainer
var _row: HBoxContainer
var _mode: Label
var _status: Label
var _beta: Label
var _code: Label
var _count: Label


func _init() -> void:
	UiDesign.style_row_button(self)
	custom_minimum_size = Vector2(0, CARD_MIN_H)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_frame = MarginContainer.new()
	_frame.name = "Frame"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		_frame.add_theme_constant_override("margin_" + side, UiDesign.SP_4)
	for side in ["top", "bottom"]:
		_frame.add_theme_constant_override("margin_" + side, UiDesign.SP_3)
	add_child(_frame)
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_row = HBoxContainer.new()
	_row.name = "Row"
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_theme_constant_override("separation", UiDesign.SP_4)
	_frame.add_child(_row)

	var info := VBoxContainer.new()
	info.name = "Info"
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", UiDesign.SP_1)
	_row.add_child(info)

	var side := VBoxContainer.new()
	side.name = "Side"
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	side.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	side.add_theme_constant_override("separation", UiDesign.SP_1)
	_row.add_child(side)

	var head := HBoxContainer.new()
	head.name = "Head"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", UiDesign.SP_3)
	info.add_child(head)

	_mode = UiDesign.label("", UiDesign.T_H3, UiDesign.C_ACCENT)
	_mode.name = "Mode"
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_mode)
	_beta = UiDesign.label("Beta", UiDesign.T_SUB, UiDesign.C_GOLD)
	_beta.name = "Beta"
	_beta.visible = false
	head.add_child(_beta)

	_code = UiDesign.label("", UiDesign.T_H3, UiDesign.C_TEXT)
	_code.name = "Code"
	info.add_child(_code)

	_status = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_status.name = "Status"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(_status)

	_count = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_count.name = "Count"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(_count)

	pressed.connect(_on_pressed)


func present(info: RoomSummary) -> void:
	var mode := info.mode
	var beta := info.beta
	var in_match := info.in_match
	_mode.text = PvpSession.mode_name(mode, beta)
	_mode.add_theme_color_override("font_color", _mode_color(mode))
	_beta.visible = beta
	_status.text = "对局中" if in_match else "等待中"
	_status.add_theme_color_override("font_color", UiDesign.C_TEXT_DIM if in_match else UiDesign.C_ACCENT)
	_code.text = info.code
	_count.text = "人数 %d / %d" % [info.occupied, info.capacity]
	_fit_height()
	# 延迟按场景树中生效的主题字体重新测量内容。
	_fit_height.call_deferred()


func _on_pressed() -> void:
	Sfx.play("ui")
	join_requested.emit(_code.text)


# Button 不会按子控件自动调整尺寸。根据内容与内边距设置卡片最小高度。
func _fit_height() -> void:
	var content := _frame.get_combined_minimum_size()
	custom_minimum_size = Vector2(0, maxi(int(content.y), CARD_MIN_H))


static func _mode_color(mode: String) -> Color:
	match mode:
		WorldSpec.TEAM:
			return UiDesign.C_MODE_TEAM
		WorldSpec.ROYALE:
			return UiDesign.C_MODE_ROYALE
		_:
			return UiDesign.C_ACCENT
