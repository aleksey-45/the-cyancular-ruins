class_name MapEditorMaterials
extends VBoxContainer

signal material_selected(id: int)

var brush: MapBrush

var _buttons: Dictionary[int, Button] = {}

func setup(p_brush: MapBrush) -> void:
	brush = p_brush
	_build()

func _build() -> void:
	add_theme_constant_override("separation", 6)
	var header := HBoxContainer.new()
	add_child(header)
	var label := Label.new()
	label.text = "材质"
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color("#a9dcca"))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)
	var group := ButtonGroup.new()
	_button(header, 0, "空气", group)
	var grid := GridContainer.new()
	grid.columns = 3
	add_child(grid)
	var materials := TileDefs.materials()
	for key in materials:
		var id := int(key)
		var button := _button(grid, id, materials[key].name, group)
		button.icon = ImageTexture.create_from_image(TerrainAtlas.tile_image(48, CyrmMap.tile_value(id)))
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.add_theme_font_size_override("font_size", 16)
		button.custom_minimum_size = Vector2(70, 100)
		button.tooltip_text = button.text
	select_material(brush.material_id)

func select_material(id: int) -> void:
	if _buttons.has(id):
		_buttons[id].button_pressed = true

func buttons() -> Dictionary[int, Button]:
	return _buttons

func _button(parent: Control, id: int, text: String, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.add_theme_color_override("font_color", Color("#d9e3df"))
	button.add_theme_color_override("font_pressed_color", Color("#d0ffe9"))
	button.pressed.connect(func() -> void: material_selected.emit(id))
	parent.add_child(button)
	_buttons[id] = button
	return button
