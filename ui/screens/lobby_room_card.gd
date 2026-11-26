class_name LobbyRoomCard
extends Button

# 局域网房间卡片。悬停、按下和禁用样式来自 RowButton 主题类型变体。
# 子控件忽略鼠标输入，整张卡片可点击。控制器根据房间发现结果中的服务器地址和端口尝试直连。

signal join_requested(code: String, endpoint: Dictionary)

const CARD_MIN_H := UiDesign.SP_9 + UiDesign.SP_8

var _info: Dictionary = {}
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


func present(info: Dictionary) -> void:
	_info = info.duplicate(true)
	var mode := str(info.get("mode", ""))
	var beta := bool(info.get("beta", false))
	var in_match := bool(info.get("in_match", false))
	_mode.text = PvpSession.mode_name(mode, beta) if PvpSession.MODE_NAMES.has(mode) else mode
	_mode.add_theme_color_override("font_color", _mode_color(mode))
	_beta.visible = beta
	_status.text = "对局中" if in_match else "等待中"
	_status.add_theme_color_override("font_color", UiDesign.C_TEXT_DIM if in_match else UiDesign.C_ACCENT)
	_code.text = str(info.get("code", ""))
	_count.text = "人数 %d / %d" % [int(info.get("players", 0)), int(info.get("max", 0))]
	_fit_height()
	# 延迟按场景树中生效的主题字体重新测量内容。
	_fit_height.call_deferred()


func _on_pressed() -> void:
	if _info.is_empty():
		return
	Sfx.play("ui")
	join_requested.emit(str(_info["code"]), {"ip": str(_info.get("ip", "")), "port": int(_info.get("port", 0))})


# Button 不会按子控件自动调整尺寸。根据内容与内边距设置卡片最小高度。
func _fit_height() -> void:
	var content := _frame.get_combined_minimum_size()
	custom_minimum_size = Vector2(0, maxi(int(content.y), CARD_MIN_H))


static func _mode_color(mode: String) -> Color:
	match mode:
		PvpSession.MODE_TEAM:
			return UiDesign.C_MODE_TEAM
		PvpSession.MODE_ROYALE:
			return UiDesign.C_MODE_ROYALE
		_:
			return UiDesign.C_ACCENT
