class_name MapPicker
extends VBoxContainer

# 选图控件(单机开局面板 / 三个联机建房面板**共用**):每个地图一张卡 —— 开局地形简略图 +
# 地图名 + 尺寸 + 联机可用性角标;首项是"随机"(=保留上游行为:进图时从目录里现挑一份)。
#
# ★ 为什么做成控件而不是各页各写一遍:三处 UI(单机/1v1/大乱斗/3v3)要的是同一件事,
#   差在"选中的值往哪存" —— 那由调用方接 `picked` 信号决定,本控件只管选。
# ★ 缩略图来自 `MapCatalog.build_image`(纯 Image,可 `-s` 验内容),这里只负责包纹理与版式。

signal picked(path: String)

const CARD_W := 244.0
const THUMB_H := 132.0

var selected: String = ""      # "" = 随机

var _grid: GridContainer
var _cards: Dictionary = {}    # path → PanelContainer
var _box_off: StyleBoxFlat
var _box_on: StyleBoxFlat


## 建 UI 并做初始选中。columns/max_h 是版式参(联机页比单机页窄)。
func setup(initial: String = "", columns := 2, max_h := 320.0,
		title := "地　图(点选;缩略图 = 开局地形简略图)") -> void:
	add_theme_constant_override("separation", 8)
	# 标题 = 同款标题带(与各页面 / 面板里的区块标题同一个味道)。
	# ★ 原先是一条裸的 `C_ACCENT` Label ⇒ 三处用到它的面板(单人开局/1v1/大乱斗/3v3 建房)
	#   里,别的区块标题都是金色标题带、只有它是青色裸字,一屏里两套标题风格。
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


## 选中某条(重复点自己不再发信号)。from_click 只影响音效/信号(初始化时静默)。
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


# ── 内部 ───────────────────────────────────────────────────────────

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
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素风:禁止线性糊图
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
