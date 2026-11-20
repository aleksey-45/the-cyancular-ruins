class_name LobbyRoomCard
extends Button

# 大厅里的一张局域网房间卡片。信息来自广播包(LanDiscovery.rooms),
# 点击后带着房主地址端点交给控制器直连加入。

signal join_requested(code: String, endpoint: Dictionary)

var _info: Dictionary = {}
var _mode: Label
var _status: Label
var _beta: Label
var _code: Label
var _count: Label

func _init() -> void:
	custom_minimum_size = Vector2(0, 168)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var normal := UiFactory.panel_box()
	normal.set_border_width_all(1)
	var highlighted := normal.duplicate() as StyleBoxFlat
	highlighted.border_color = UiFactory.C_ACCENT
	for style in ["normal", "disabled"]:
		add_theme_stylebox_override(style, normal)
	for style in ["hover", "pressed", "focus"]:
		add_theme_stylebox_override(style, highlighted)

	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inside := UiFactory.panel_box(false)
	inside.draw_center = false
	frame.add_theme_stylebox_override("panel", inside)
	add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 8)
	frame.add_child(content)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 16)
	content.add_child(header)
	_mode = UiFactory.label("", 40, UiFactory.C_ACCENT)
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_beta = UiFactory.label("Beta", 28, UiFactory.C_GOLD)
	_status = UiFactory.label("", 28, UiFactory.C_TEXT_DIM)
	header.add_child(_mode)
	header.add_child(_beta)
	header.add_child(_status)

	var details := HBoxContainer.new()
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_theme_constant_override("separation", 16)
	content.add_child(details)
	_code = UiFactory.label("", 40, UiFactory.C_TEXT)
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	details.add_child(_code)
	details.add_child(_count)

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
	_status.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM if in_match else UiFactory.C_ACCENT)
	_code.text = str(info.get("code", ""))
	_count.text = "人数 %d / %d" % [int(info.get("players", 0)), int(info.get("max", 0))]


func _on_pressed() -> void:
	if _info.is_empty():
		return
	Sfx.play("ui")
	join_requested.emit(str(_info["code"]), {"ip": str(_info.get("ip", "")), "port": int(_info.get("port", 0))})


static func _mode_color(mode: String) -> Color:
	match mode:
		PvpSession.MODE_TEAM:
			return UiFactory.C_MODE_TEAM
		PvpSession.MODE_ROYALE:
			return UiFactory.C_MODE_ROYALE
		_:
			return UiFactory.C_ACCENT
