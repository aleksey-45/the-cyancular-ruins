class_name UiFactory
extends RefCounted

# 代码创建的菜单控件采用同一套主题和字体。

const MENU_THEME := preload("res://ui/theme/menu_theme.tres")

static func style_control(c: Control, size: int) -> void:
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_font_override("font", PixelFont.FONT)

static func label(text: String, size: int, color: Color = C_WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	style_control(l, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# 列表用空格补齐短昵称，过长的昵称用省略号截断。长度按字符宽度估算。
static func fit_name(s: String, max_units: int) -> String:
	var units := 0
	var out := ""
	for i in s.length():
		var w := 2 if s.unicode_at(i) > 0x2E80 else 1
		if units + w > max_units:
			out += "…"
			units += 1
			break
		units += w
		out += s[i]
	while units < max_units:
		out += " "
		units += 1
	return out



const C_BG          := Color(0.039, 0.059, 0.094)
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_WHITE       := Color(1, 1, 1)
const C_WARN        := Color(0.950, 0.850, 0.550)

# 直接绘制文字或背景的控件也从菜单主题读取相应颜色。
static var C_TEXT := MENU_THEME.get_color(&"font_color", &"Label")
static var C_TEXT_DIM := MENU_THEME.get_color(&"font_color", &"Dim")
static var C_ACCENT := MENU_THEME.get_color(&"font_color", &"Accent")
static var C_GOLD := MENU_THEME.get_color(&"font_color", &"HeaderTitle")
static var C_MODE_TEAM := MENU_THEME.get_color(&"font_pressed_color", &"TeamFilter")
static var C_MODE_ROYALE := MENU_THEME.get_color(&"font_pressed_color", &"RoyaleFilter")
static var C_SURFACE := (MENU_THEME.get_stylebox(&"panel", &"PanelCarved") as StyleBoxFlat).bg_color

# 用于标记连接中断或正在重连的玩家。
const C_GRACE       := Color(0.72, 0.62, 0.90)

const C_PLATE       := Color(0, 0, 0, 0.1)

const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)


# 延迟低于 60、100、150 毫秒时分别显示绿色、黄色、橙色，其他情况显示红色。
static func ping_color(ms: int) -> Color:
	if ms < 60:
		return Color(0.45, 0.9, 0.45)
	if ms < 100:
		return Color(1.0, 0.85, 0.25)
	if ms < 150:
		return Color(1.0, 0.6, 0.15)
	return Color(1.0, 0.3, 0.3)


const C_SLOT_EMPTY  := Color(0.510, 0.600, 0.624, 0.5)
const C_SLOT_FILLED := Color(0.360, 0.620, 0.920, 0.5)
const C_SLOT_ACTIVE := Color(0.090, 0.300, 0.680, 0.5)

static func panel_box(border := true) -> StyleBoxFlat:
	var box: StyleBoxFlat = MENU_THEME.get_stylebox("panel", "PanelContainer").duplicate()
	if not border:
		box.set_border_width_all(0)
	return box

static func menu_button(text: String, min_size: Vector2, variant: StringName) -> Button:
	var button := Button.new()
	button.theme = MENU_THEME
	button.theme_type_variation = variant
	button.text = text
	button.custom_minimum_size = min_size
	return button

static func header_strip(text: String, size: int = 32, centered := false, color: Variant = null) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme = MENU_THEME
	panel.theme_type_variation = &"HeaderStrip"
	var title := Label.new()
	title.text = text
	title.theme_type_variation = &"HeaderTitle"
	title.add_theme_font_size_override("font_size", size)
	if color != null:
		title.add_theme_color_override("font_color", color)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if centered:
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)
	return panel

static func row_box() -> StyleBoxFlat:
	return MENU_THEME.get_stylebox("panel", "RowPanel").duplicate()

# 预览只改变色相，所有选项使用相同的饱和度和亮度。
static func hue_preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, 0.75, 1.0)

static func cover(parent: Node, control: Control) -> void:
	parent.add_child(control)
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

static func place(parent: Node, control: Control, box: Rect2, anchor := Vector2.ZERO) -> void:
	parent.add_child(control)
	control.anchor_left = anchor.x
	control.anchor_right = anchor.x
	control.anchor_top = anchor.y
	control.anchor_bottom = anchor.y
	control.offset_left = box.position.x
	control.offset_top = box.position.y
	control.offset_right = box.end.x
	control.offset_bottom = box.end.y

static func shade(color: Color, pick_mouse := false) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_STOP if pick_mouse else Control.MOUSE_FILTER_IGNORE
	return rect

static func box(parent: Node, spacing: int, vertical: bool) -> BoxContainer:
	var result: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	result.add_theme_constant_override("separation", spacing)
	parent.add_child(result)
	return result

static func framed(content: Control, padding := Vector2(-1, -1)) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PanelCarved"
	fill_frame(panel, content, padding)
	return panel

static func fill_frame(panel: PanelContainer, content: Control, padding: Vector2) -> void:
	panel.theme = MENU_THEME
	panel.theme_type_variation = &"PanelCarved"
	var body := PanelContainer.new()
	body.theme_type_variation = &"PanelCarvedBody"
	if padding.x >= 0 and padding.y >= 0:
		var style: StyleBoxFlat = MENU_THEME.get_stylebox("panel", "PanelCarvedBody").duplicate()
		style.content_margin_left = padding.x
		style.content_margin_right = padding.x
		style.content_margin_top = padding.y
		style.content_margin_bottom = padding.y
		body.add_theme_stylebox_override("panel", style)
	panel.add_child(body)
	body.add_child(content)

static func plate(color: Color, padding: Vector2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.content_margin_left = padding.x
	style.content_margin_right = padding.x
	style.content_margin_top = padding.y
	style.content_margin_bottom = padding.y
	return style

static func page(root: Control, title: String, spacing: int, pick_mouse := false) -> VBoxContainer:
	root.theme = MENU_THEME
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cover(root, shade(Color(0.07, 0.09, 0.13), pick_mouse))
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 76)
	cover(root, margin)
	var body: VBoxContainer = box(margin, spacing, true)
	body.add_child(header_strip(title, 48, true))
	return body

static func columns(parent: Node) -> HBoxContainer:
	var row: HBoxContainer = box(parent, 32, false)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return row

static func column(row: HBoxContainer, content: VBoxContainer, stretch := 1.0) -> void:
	var panel := framed(content)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = stretch
	row.add_child(panel)

const ROOM_FILTERS := [
	["", "全部", &"RoomFilter"],
	[PvpSession.MODE_PVP, "1v1", &"RoomFilter"],
	[PvpSession.MODE_TEAM, "团队对抗", &"TeamFilter"],
	[PvpSession.MODE_ROYALE, "大乱斗", &"RoyaleFilter"],
]

static func room_filter(row: Array, group: ButtonGroup) -> Button:
	var button := menu_button(row[1], Vector2(220, 72), row[2])
	button.toggle_mode = true
	button.button_group = group
	return button

static func action(parent: Node, caption: String, minimum: Vector2, variant: StringName, pressed: Callable) -> Button:
	var button := menu_button(caption, minimum, variant)
	parent.add_child(button)
	button.pressed.connect(pressed)
	return button

static func dialog(control: Control) -> void:
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.grow_vertical = Control.GROW_DIRECTION_BOTH
	control.hide()

static func centered(parent: Node, content: Control, opacity: float, pick_mouse: bool) -> PanelContainer:
	cover(parent, shade(Color(0, 0, 0, opacity), pick_mouse))
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_STOP if pick_mouse else Control.MOUSE_FILTER_IGNORE
	cover(parent, center)
	var panel := framed(content, Vector2(72, 44))
	center.add_child(panel)
	return panel
