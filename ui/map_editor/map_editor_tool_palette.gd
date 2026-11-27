class_name MapEditorToolPalette
extends VBoxContainer

signal tool_selected(id: String)

var shortcuts: Dictionary[int, Callable] = {}

var _buttons: Dictionary[String, Button] = {}

func setup(definitions: Dictionary, active: String) -> void:
	add_theme_constant_override("separation", UiDesign.SP_2)
	UiKit.label(self, "绘制工具", UiDesign.C_ACCENT)
	var group := ButtonGroup.new()
	var grid := GridContainer.new()
	grid.columns = 3
	add_child(grid)
	for id: String in definitions:
		var definition: Dictionary = definitions[id]
		var select := tool_selected.emit.bind(id)
		var button := UiKit.button(grid, definition.label, select)
		button.toggle_mode = true
		button.button_group = group
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_buttons[id] = button
		var key: Key = definition.key
		if id == "point":
			button.tooltip_text = "在右侧选择点位类型，勾选连续放置后单击画布"
		else:
			button.tooltip_text = button.text + (" " + OS.get_keycode_string(key) if key != KEY_NONE else "")
		if key != KEY_NONE:
			shortcuts[key] = select
	select_tool(active)

func select_tool(id: String) -> void:
	_buttons[id].button_pressed = true

func tooltip(id: String) -> String:
	return _buttons[id].tooltip_text
