class_name MapPicker
extends VBoxContainer

# 地图选择器控件：为单人开局与联机建房面板提供统一的地图选择卡片列表。
# 展示地图名称、尺寸规格、出生点属性与地形缩略图；首项支持随机选图。
# 选中后发出 picked 信号通知调用方。

signal picked(path: String)

const CARD_W := 244.0
const THUMB_H := 132.0

var selected: String = ""      # 空串表示随机

var _grid: GridContainer
var _cards: Dictionary = {}    # 路径到卡片容器节点的映射
var _box_off: StyleBoxFlat
var _box_on: StyleBoxFlat


# 初始化地图选择卡片网格
func setup(initial: String = "", columns := 2, max_h := 320.0,
		title := "地　图(点选;缩略图 = 开局地形简略图)") -> void:
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

	_add_card("", "随　机", "进图时从目录中现挑一份", MapCatalog.random_texture())
	var maps := MapCatalog.list_maps()
	var names: Array[String] = []
	for m in maps:
		names.append(str(m["path"]))
		var size: Vector2i = m["size"]
		var sub := "%d×%d 格" % [size.x, size.y]
		sub += "· 双出生点" if bool(m["pvp"]) else "· 单人图(联机出生点自动分配)"
		if bool(m["external"]):
			sub += "· 外置"
		_add_card(str(m["path"]), str(m["name"]), sub, MapCatalog.texture(str(m["path"])))

	if initial != "" and names.has(initial):
		select_path(initial, false)
	else:
		select_path("", false)


# 选中指定地图路径
func select_path(path: String, from_click := true) -> void:
	if not _cards.has(path) or path == selected:
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


# ── 内部方法 ──

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
