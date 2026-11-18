class_name LobbyRoomCard
extends Button

var _mode: Label
var _status: Label
var _code: Label
var _rules: Label
var _thumbnail: TextureRect
var _thumbnail_fill: ColorRect
var _count: Label
var _host: Label
var _roster: Label

func _init() -> void:
	custom_minimum_size = Vector2(420, 520)
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
	content.add_theme_constant_override("separation", 12)
	frame.add_child(content)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode = UiFactory.label("", 32)
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status = UiFactory.label("", 16)
	header.add_child(_mode)
	header.add_child(_status)
	content.add_child(header)
	_code = UiFactory.label("", 48, UiFactory.C_TEXT)
	_rules = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	content.add_child(_code)
	content.add_child(_rules)

	var details := HBoxContainer.new()
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_theme_constant_override("separation", 20)
	content.add_child(details)
	_thumbnail_fill = ColorRect.new()
	_thumbnail_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumbnail_fill.custom_minimum_size = Vector2(120, 120)
	details.add_child(_thumbnail_fill)
	_thumbnail = TextureRect.new()
	_thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumbnail_fill.add_child(_thumbnail)
	_thumbnail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_host = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_host.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta.add_child(_count)
	meta.add_child(_host)
	details.add_child(meta)
	_roster = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_roster.add_theme_constant_override("line_spacing", 4)
	content.add_child(_roster)

func present(room: Dictionary) -> void:
	var can_open: bool = room["can_open"]
	var color: Color = room["mode_color"]
	var in_match: bool = room["in_match"]
	disabled = not can_open
	focus_mode = Control.FOCUS_ALL if can_open else Control.FOCUS_NONE
	modulate.a = 1.0 if can_open else 0.55
	_mode.text = room["title"]
	_mode.add_theme_color_override("font_color", color)
	_status.text = "对局中" if in_match else "等待中"
	_status.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM if in_match else UiFactory.C_ACCENT)
	_code.text = room["code"]
	_rules.text = room["rules"]
	_count.text = room["count"]
	_host.text = room["host"]
	_thumbnail.texture = room["thumbnail"]
	_thumbnail_fill.color = Color(color, 0.25) if _thumbnail.texture == null else UiFactory.C_SURFACE
	_roster.text = room["roster"]
