class_name MapPicker
extends VBoxContainer

# 开始单人游戏和创建联机房间时使用同一个地图选择控件。
# 随机选图卡片排在首位。地图卡片显示缩略图、地图尺寸和出生点信息。
# 玩家改选地图卡片时发出 picked。初始化选中项时只更新界面。

signal picked(path: String)

const CARD_W := 244.0
const THUMB_H := 132.0

var selected: String = ""      # 随机选图在数据中用空路径表示。

var _grid: GridContainer
var _cards: Dictionary = {}
var _box_off: StyleBoxFlat
var _box_on: StyleBoxFlat


func setup(initial: String = "", columns := 2, max_h := 320.0,
		title := "地图(点选;缩略图 = 开局地形简略图)") -> void:
	add_theme_constant_override("separation", 8)
	add_child(UiFactory.header_strip(title, 32))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, max_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = maxi(columns, 1)
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	_box_off = _style_off()
	_box_on = _style_on()

	_add_card("", "随机", "进图时从目录中现挑一份", MapCatalog.random_texture())
	for m in MapCatalog.list_maps():
		var size: Vector2i = m["size"]
		var counts: Vector2i = m["spawn_counts"]
		var sub := "%d×%d 子格 · 出生点 A %d / B %d" % [size.x, size.y, counts.x, counts.y]
		if bool(m["external"]):
			sub += " · 外置"
		_add_card(str(m["path"]), str(m["name"]), sub, m["texture"])
		_cards[m["path"]].tooltip_text = "蓝色为单人出生点，绿色为 A 侧出生点，橙色为 B 侧出生点"

	if not _cards.has(initial):
		_add_card(initial, initial.get_file(), "地图不可用", null)
	select_path(initial, false)


func select_path(path: String, from_click := true) -> void:
	if not _cards.has(path) or (path == selected and from_click):
		return
	var prev: PanelContainer = _cards.get(selected)
	if prev != null:
		prev.add_theme_stylebox_override("panel", _box_off)
	selected = path
	var cur: PanelContainer = _cards.get(path)
	cur.add_theme_stylebox_override("panel", _box_on)
	if from_click:
		Sfx.play("ui")
		picked.emit(path)



func _add_card(path: String, title: String, sub: String, tex: Texture2D) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", _box_off)
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			select_path(path))
	_grid.add_child(card)
	_cards[path] = card

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)

	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(CARD_W - 16.0, THUMB_H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	vb.add_child(tr)

	vb.add_child(UiFactory.label(title, 32))
	var dim := UiFactory.label(sub, 16, UiFactory.C_TEXT_DIM)
	dim.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(dim)


func _style_off() -> StyleBoxFlat:
	var sb := UiFactory.row_box()
	sb.set_content_margin_all(8)
	return sb


func _style_on() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.17, 0.23)
	sb.border_color = UiFactory.C_ACCENT
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	return sb
