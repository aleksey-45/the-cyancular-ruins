class_name MapEditorLayers
extends VBoxContainer

signal layer_selected(index: int)

const LAYERS := ["前景", "场景", "后景", "背景 1 · 近", "背景 2", "背景 3", "背景 4 · 远"]

var session: MapEditSession
var canvas: MapEditCanvas

var _buttons: Array[Button] = []

func setup(p_session: MapEditSession, p_canvas: MapEditCanvas) -> void:
	session = p_session
	canvas = p_canvas
	_build()

func _build() -> void:
	add_theme_constant_override("separation", UiDesign.SP_2)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", UiDesign.SP_3)
	add_child(grid)
	for heading in ["图层", "可见", "锁定"]:
		UiKit.label(grid, heading, UiDesign.C_ACCENT).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var group := ButtonGroup.new()
	for i in LAYERS.size():
		var name_button := UiKit.button(grid, LAYERS[i], layer_selected.emit.bind(i))
		name_button.toggle_mode = true
		name_button.button_group = group
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_button.button_pressed = i == session.layer
		_buttons.append(name_button)
		for property in ["visible", "locked"]:
			var check := CheckBox.new()
			check.button_pressed = property == "visible"
			check.tooltip_text = ("显示" if property == "visible" else "锁定") + LAYERS[i]
			check.accessibility_name = check.tooltip_text
			check.custom_minimum_size = Vector2(40, 34)
			check.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			check.toggled.connect(set_flag.bind(i, property))
			grid.add_child(check)

func select_layer(index: int) -> void:
	_buttons[index].button_pressed = true

func buttons() -> Array[Button]:
	return _buttons

func set_flag(value: bool, index: int, property: String) -> void:
	if property == "visible":
		canvas.planes[index].visible = value
	else:
		session.locked[index] = value
		canvas.cancel()
