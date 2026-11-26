class_name MapPicker
extends VBoxContainer

signal picked(path: String)

const CARD_SIZE := Vector2(244, 240)

var selected := ""
var _grid := GridContainer.new()
var _choices := ButtonGroup.new()


func setup(initial: String, max_height: float, title := "地图") -> void:
	selected = initial
	add_theme_constant_override("separation", UiDesign.SP_2)
	add_child(UiDesign.header_strip(title))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = max_height
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)

	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", UiDesign.SP_3)
	_grid.add_theme_constant_override("v_separation", UiDesign.SP_2)
	scroll.add_child(_grid)

	_add_card("", "随机", "从地图目录随机选择", MapCatalog.random_texture())
	for map in MapCatalog.list_maps():
		var size: Vector2i = map["size"]
		var counts: Vector2i = map["spawn_counts"]
		var details := "%d×%d 子格 · 出生点 A %d / B %d" % [size.x, size.y, counts.x, counts.y]
		if map["external"]:
			details += " · 外置"
		var card := _add_card(map["path"], map["name"], details, map["texture"])
		card.tooltip_text = "蓝色为单人出生点，绿色为 A 侧出生点，橙色为 B 侧出生点"

	if _choices.get_pressed_button() == null:
		_add_card(initial, initial.get_file(), "地图不可用", null)


func _add_card(path: String, title: String, details: String, texture: Texture2D) -> Button:
	var card := UiDesign.ui_button(title + "\n" + details, UiDesign.T_SMALL, CARD_SIZE, "icon")
	card.toggle_mode = true
	card.button_group = _choices
	card.button_pressed = path == selected
	card.icon = texture
	card.expand_icon = true
	card.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	card.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.pressed.connect(func() -> void:
		if path != selected:
			selected = path
			Sfx.play("ui")
			picked.emit(path))
	_grid.add_child(card)
	return card
