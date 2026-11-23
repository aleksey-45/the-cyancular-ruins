class_name MapPicker
extends VBoxContainer

# 单人开局 / 联机建房共用的地图选择控件(UI-5a:迁到设计系统 v2)。
#
# 结构(全部由容器驱动,无绝对坐标):
#   self(VBox,SP_2)
#   ├─ UiDesign.header_strip(title,T_H2)                      皮肤 = Theme 的 HeaderStrip
#   └─ ScrollContainer(限高 max_h,横向滚动关闭,滚动条 Kit 皮)
#      └─ GridContainer(columns 列)
#         └─ 地图卡片 × N
#
# 卡片 = UiDesign.ui_panel("card")(Theme 2.0 的 Card 皮肤) + 两层:
#   · State:Button —— 选中底板。一个不接输入的 toggle 按钮:选中时用 Theme 的 Icon.pressed
#     皮肤(强调色描边 + 深底)在内容下面画一圈高亮框,未选时 transparent normal,完全隐形。
#     这样"当前地图"只由 Theme 2.0 的两个既有状态表达,本文件不造任何 StyleBox;
#     mouse_filter = IGNORE,点击统一交给卡片面板的 gui_input(整张卡片含内边距都可点)。
#   · Content:MarginContainer(SP_2)→ VBox(SP_1)→ 缩略图 / 标题 / 说明。
#   选中项的标题颜色切到 C_ACCENT,与高亮框一起标示"当前地图"。
#
# 保留迁移前的对外契约:setup(…) / selected / picked / select_path;随机卡片(空路径)排首位;
# 地图缩略图、滚动、初始地图不在目录时的"地图不可用"空态都保留。玩家改选地图卡片时发出 picked;
# 初始化选中项时只更新界面,不发信号、不播音效。
# ★ 样式只引用 Theme 2.0 / UiDesign token:本文件不 new StyleBox、不写 Color 字面量、不设绝对坐标。

signal picked(path: String)

# 卡片尺寸是布局度量(不是绝对坐标):用 token 组合,保持迁移前观感(244×132 的缩略图区)。
const CARD_W := UiDesign.SP_10 * 3 + UiDesign.SP_1              # 244
const THUMB_H := UiDesign.SP_10 + UiDesign.SP_8 + UiDesign.SP_1 # 132
const CARD_INSET := UiDesign.SP_2                              # 选中底板与内容之间留出的可见边

var selected: String = ""      # 随机选图在数据中用空路径表示。

var _grid: GridContainer
var _cards: Dictionary = {}    # path → {panel: PanelContainer, state: Button, title: Label}


func setup(initial: String = "", columns := 2, max_h := 320.0,
		title := "地图(点选;缩略图 = 开局地形简略图)") -> void:
	add_theme_constant_override("separation", UiDesign.SP_2)
	add_child(UiDesign.header_strip(title, UiDesign.T_H2))

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.custom_minimum_size = Vector2(0, max_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.get_v_scroll_bar().theme_type_variation = &"Kit"
	add_child(scroll)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = maxi(columns, 1)
	_grid.add_theme_constant_override("h_separation", UiDesign.SP_3)
	_grid.add_theme_constant_override("v_separation", UiDesign.SP_2)
	scroll.add_child(_grid)

	_add_card("", "随机", "进图时从目录中现挑一份", MapCatalog.random_texture())
	for m in MapCatalog.list_maps():
		var size: Vector2i = m["size"]
		var counts: Vector2i = m["spawn_counts"]
		var sub := "%d×%d 子格 · 出生点 A %d / B %d" % [size.x, size.y, counts.x, counts.y]
		if bool(m["external"]):
			sub += " · 外置"
		var card := _add_card(str(m["path"]), str(m["name"]), sub, m["texture"])
		card.tooltip_text = "蓝色为单人出生点，绿色为 A 侧出生点，橙色为 B 侧出生点"

	# 空态:初始地图已不在目录里(被删 / 外部图未随包)时仍要能显示"当前选项",
	# 只是没有缩略图和尺寸信息 —— 与迁移前一致。
	if not _cards.has(initial):
		_add_card(initial, initial.get_file(), "地图不可用", null)
	select_path(initial, false)


## 选中某条(重复点自己不再发信号)。from_click 只影响音效/信号(初始化时静默)。
func select_path(path: String, from_click := true) -> void:
	if not _cards.has(path) or (path == selected and from_click):
		return
	if _cards.has(selected):
		_set_current(_cards[selected], false)
	selected = path
	_set_current(_cards[path], true)
	if from_click:
		Sfx.play("ui")
		picked.emit(path)


# 当前项的视觉 = Theme 的 Icon.pressed(强调色描边 + 深底);标题色用 token,不写字面量。
func _set_current(entry: Dictionary, on: bool) -> void:
	var state := entry["state"] as Button
	state.set_pressed_no_signal(on)
	(entry["title"] as Label).add_theme_color_override("font_color",
			UiDesign.C_ACCENT if on else UiDesign.C_WHITE)


func _add_card(path: String, title: String, sub: String, tex: Texture2D) -> PanelContainer:
	var card := UiDesign.ui_panel("card")
	card.name = "Card"
	card.custom_minimum_size = Vector2(CARD_W, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			select_path(path))
	_grid.add_child(card)

	# 选中底板:画在内容下面,不接输入(所以卡片任意位置点击都落到 card.gui_input)。
	# 只用 Theme 的 Icon 皮肤:normal = 透明(未选不占视觉),pressed = 强调色描边 + 深底。
	var state := Button.new()
	state.name = "State"
	state.theme = UiDesign.MENU_THEME
	state.theme_type_variation = &"Icon"
	state.toggle_mode = true
	state.focus_mode = Control.FOCUS_NONE
	state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(state)

	var content := MarginContainer.new()
	content.name = "Content"
	for side in ["left", "right", "top", "bottom"]:
		content.add_theme_constant_override("margin_" + side, CARD_INSET)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(content)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", UiDesign.SP_1)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(rows)

	var thumb := TextureRect.new()
	thumb.name = "Thumb"
	thumb.texture = tex
	thumb.custom_minimum_size = Vector2(0, THUMB_H)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	thumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(thumb)

	var title_label := UiDesign.label(title, UiDesign.T_H2)
	title_label.name = "Title"
	rows.add_child(title_label)
	var dim := UiDesign.label(sub, UiDesign.T_SMALL, UiDesign.C_TEXT_DIM)
	dim.name = "Sub"
	dim.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(dim)

	_cards[path] = {"panel": card, "state": state, "title": title_label}
	return card
