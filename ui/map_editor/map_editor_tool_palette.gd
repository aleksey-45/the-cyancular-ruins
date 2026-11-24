class_name MapEditorToolPalette
extends VBoxContainer

signal tool_selected(id: String)

var shortcuts: Dictionary[int, Callable] = {}

var _buttons: Dictionary[String, Button] = {}
var _definitions: Dictionary

func setup(definitions: Dictionary, active: String) -> void:
	_definitions = definitions
	_build(active)

func _build(active: String) -> void:
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "绘制工具"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#a9dcca"))
	add_child(title)
	var group := ButtonGroup.new()
	var grid := GridContainer.new()
	grid.columns = 3
	add_child(grid)
	for id: String in _definitions:
		var definition: Dictionary = _definitions[id]
		var button := Button.new()
		button.text = definition.label
		button.toggle_mode = true
		button.button_group = group
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_color_override("font_color", Color("#d9e3df"))
		button.add_theme_color_override("font_pressed_color", Color("#d0ffe9"))
		button.pressed.connect(func() -> void: tool_selected.emit(id))
		grid.add_child(button)
		_buttons[id] = button
		var key: Key = definition.key
		if id == "point":
			button.tooltip_text = "点位：右侧选择出生点/敌人类型，勾选放置点位后单击画布"
		else:
			button.tooltip_text = button.text + (" " + OS.get_keycode_string(key) if key != KEY_NONE else "")
		if key != KEY_NONE:
			shortcuts[key] = func() -> void: tool_selected.emit(id)
	select_tool(active)

func select_tool(id: String) -> void:
	if _buttons.has(id):
		_buttons[id].button_pressed = true

func tooltip(id: String) -> String:
	return _buttons[id].tooltip_text if _buttons.has(id) else ""
