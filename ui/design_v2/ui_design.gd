class_name UiDesign
extends RefCounted


# 设计系统 v2 的间距、字号、圆角和描边常量。界面布局约定见 docs/construction/2026-11-23-ui-full-replacement-plan.md 的「实现约定」。
# 布局间距以像素为单位。
const SP_0 := 0
const SP_1 := 4
const SP_2 := 8
const SP_3 := 12
const SP_4 := 16
const SP_5 := 24
const SP_6 := 32
const SP_7 := 40
const SP_8 := 48
const SP_9 := 64
const SP_10 := 80
# HUD 与视口边缘的统一间距。用锚点与此常量定位 HUD，避免将坐标绑定到固定分辨率。
const MARGIN := 24
# 像素字体优先使用 16 的整数倍字号。其他字号用原尺寸截图检查字形清晰度。
const T_TITLE := 160
const T_HUGE := 128
const T_H1 := 48
const T_H2 := 32
const T_BODY := 16
const T_LABEL := 16
const T_SUB := 28
const T_SMALL := 24
const T_H3 := 40
# 圆角 / 描边
const R_SM := 3
const R_MD := 4
const R_LG := 6
const BORDER_W := 2
const BORDER_W_DIM := 1

# 主题类型变体由 tools/gen_menu_theme_v2.gd 生成。
# 工厂为控件引用同一份主题资源，确保 HUD、加载界面和编辑器中的控件都能解析主题变体。
const MENU_THEME := preload("res://ui/theme/menu_theme_v2.tres")


static func _apply_variation(c: Control, variation: StringName) -> void:
	c.theme = MENU_THEME
	c.theme_type_variation = variation


static func pixel_font() -> Font:
	return PixelFont.FONT


static func style_control(c: Control, size: int) -> void:
	# 允许正整数字号。使用 24、28、40 等非基准字号时，以实际截图检查笔画。
	assert(size > 0, "字号必须为正;收到 %d" % size)
	c.add_theme_font_size_override("font_size", size)
	var pf: Font = pixel_font()
	if pf != null:
		c.add_theme_font_override("font", pf)


static func label(text: String, size: int, color: Color = C_WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	style_control(l, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


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


# UI 调色板。各页面使用这里定义的颜色。
const C_BG          := Color(0.039, 0.059, 0.094)
const C_SURFACE     := Color(0.071, 0.086, 0.118)
const C_ROW         := Color(0.086, 0.094, 0.110)
const C_FIELD       := Color(0.106, 0.118, 0.141)
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)
# 描边与页面背景、按钮填充色的对比度目标均为 3:1。旧值 #3D4A5A 实测分别为 2.13:1 和 1.82:1。
const C_BORDER      := Color(0.361, 0.439, 0.561)
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)
const C_ACCENT      := Color(0.349, 0.851, 0.902)
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_TEXT        := Color(0.878, 0.914, 0.949)
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)
# 默认纯白使用 C_WHITE，带冷色调的正文使用 C_TEXT。切换颜色会改变截图中的文字像素。
const C_WHITE       := Color(1, 1, 1)
const C_WARN        := Color(0.950, 0.850, 0.550)

const C_MODE_TEAM   := Color(0.627, 0.549, 1.0)
const C_MODE_ROYALE := Color(0.910, 0.639, 0.239)

const C_HEADER     := Color("#1B242C")
const C_INNER      := Color("#1E2830")
const C_EDGE       := Color("#46545F")
const C_GOLD       := Color("#E0A94F")
const C_TEXT_MUTE  := Color("#6C7885")

const C_TRANSPARENT := Color(0, 0, 0, 0)

const C_GRACE       := Color(0.72, 0.62, 0.90)

const C_PLATE       := Color(0, 0, 0, 0.1)
# 主菜单背景遮罩色，用于提高菜单文字的对比度。
const C_MENU_DIM    := Color(0, 0, 0, 0.22)
# 当前选中的武器行使用比 C_PLATE 更深的底色。
const C_PLATE_DEEP  := Color(0, 0, 0, 0.28)

const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)

# 对局 HUD 共用延迟阈值配色。
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

const BTN_BORDER_W := BORDER_W   # 兼容旧引用;新代码用 BORDER_W


# ── HUD 底板工厂 ───────────────────────────────────────────────────────────
# 创建 HUD 底板。默认半透明深底、直角、无描边，调用方指定横向和纵向内边距。
# 击杀计数器可关闭底色，仅保留边距。选中项使用 C_PLATE_DEEP。
static func hud_plate(c: Control, pad_x: int, pad_y: int, draw_center := true,
		fill: Color = C_PLATE) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.draw_center = draw_center
	sb.set_corner_radius_all(0)
	sb.content_margin_left = float(pad_x)
	sb.content_margin_right = float(pad_x)
	sb.content_margin_top = float(pad_y)
	sb.content_margin_bottom = float(pad_y)
	c.add_theme_stylebox_override("panel", sb)


static func _btn_box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(BTN_BORDER_W)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 40.0
	sb.content_margin_right = 40.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


static func panel_box(border: bool = true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_SURFACE
	sb.set_corner_radius_all(0)
	if border:
		sb.border_color = C_BORDER
		sb.set_border_width_all(BTN_BORDER_W)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


static func menu_panel(padding: Vector2 = Vector2(64, 46)) -> PanelContainer:
	var outer := PanelContainer.new()
	skin_menu_panel(outer, padding)
	return outer


static func skin_menu_panel(outer: PanelContainer, padding: Vector2) -> void:
	if outer.get_node_or_null("Body") != null:
		return
	_apply_variation(outer, &"PanelCarved")
	var body := PanelContainer.new()
	body.name = "Body"
	# 优先使用内边距匹配的主题变体。没有对应变体时，复制 PanelCarvedBody 并调整内边距。
	var body_var := _body_variation_for(padding)
	if body_var != &"":
		_apply_variation(body, body_var)
	else:
		body.theme = MENU_THEME
		var isb := (MENU_THEME.get_stylebox("panel", "PanelCarvedBody") as StyleBoxFlat).duplicate() as StyleBoxFlat
		isb.content_margin_left = padding.x
		isb.content_margin_right = padding.x
		isb.content_margin_top = padding.y
		isb.content_margin_bottom = padding.y
		body.add_theme_stylebox_override("panel", isb)
	# 先从原父节点移除 .tscn 中的内容节点，再将它们加入新的 Body 容器。
	for c in outer.get_children():
		outer.remove_child(c)
		body.add_child(c)
	outer.add_child(body)


# 将内边距映射到主题变体，定义对应 tools/gen_menu_theme_v2.gd 的 _panel_variants。
static func _body_variation_for(padding: Vector2) -> StringName:
	if padding == Vector2(64, 46):
		return &"PanelCarvedBody"
	if padding == Vector2(72, 44):
		return &"PanelCarvedBodyInset72"
	return &""


# 将旧接口的样式名映射为兼容主题变体。
const _MENU_BTN_VARIATIONS := {
	"primary": &"BtnPrimary", "quiet": &"BtnQuiet",
	"gold": &"BtnGold", "accent": &"BtnAccent",
	"compact": &"BtnCompact",
}
# 将按钮样式名映射为对应的主题类型变体。
const _UI_BTN_VARIATIONS := {
	"primary": &"Primary", "quiet": &"Quiet", "danger": &"Danger", "icon": &"Icon",
}


static func menu_button(text: String, size: int, min_size: Vector2 = Vector2(640, 88),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	_apply_variation(b, StringName(_MENU_BTN_VARIATIONS.get(variant, "BtnPrimary")))
	return b


# 通用控件构建方法。
static func ui_button(text: String, size: int = T_H2, min_size: Vector2 = Vector2.ZERO,
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	if min_size != Vector2.ZERO:
		b.custom_minimum_size = min_size
	_apply_variation(b, StringName(_UI_BTN_VARIATIONS.get(variant, "Primary")))
	return b


const _LABEL_VARIATIONS := {
	"h1": &"H1", "h2": &"H2", "body": &"Body", "dim": &"Dim", "field": &"Field",
}


static func ui_label(text: String, type_name: String = "body") -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_variation(l, StringName(_LABEL_VARIATIONS.get(type_name.to_lower(), "Body")))
	return l


const _PANEL_VARIATIONS := {
	"card": &"Card", "plain": &"Plain", "bar": &"Bar",
}


static func ui_panel(variant: String = "card") -> PanelContainer:
	var p := PanelContainer.new()
	_apply_variation(p, StringName(_PANEL_VARIATIONS.get(variant, "Card")))
	return p


static func ui_field() -> LineEdit:
	var le := LineEdit.new()
	_apply_variation(le, &"Field")
	return le


static func ui_check() -> CheckButton:
	var cb := CheckButton.new()
	_apply_variation(cb, &"Kit")
	return cb


const HEADER_INSET := 24.0
const HEADER_PAD_Y := 20.0


static func header_strip(text: String, size: int = 32, centered := false) -> PanelContainer:
	var p := PanelContainer.new()
	_apply_variation(p, &"HeaderStrip")
	var l := label(text, size, C_GOLD)
	if centered:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


static func row_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_ROW
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func _row_sb(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := row_box()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2)
	return sb


static func style_row_button(b: Button) -> void:
	_apply_variation(b, &"RowButton")


static func style_slider(s: Slider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", _row_sb(C_ACCENT, C_ACCENT))
	s.add_theme_stylebox_override("grabber_area_highlight", _row_sb(C_ACCENT, C_ACCENT))


static func style_line_edit(le: LineEdit) -> void:
	_apply_variation(le, &"Field")


static func style_button(b: Button, variant: String = "primary") -> void:
	# 旧版按钮使用 BtnLegacy 或 BtnLegacyQuiet 主题变体。
	var v := &"BtnLegacyQuiet" if variant == "quiet" else &"BtnLegacy"
	_apply_variation(b, v)


# 自定义开关图标。开和关都保留完整轨道，通过颜色和滑块位置区分状态。
const SWITCH_W := 40
const SWITCH_H := 22
const SWITCH_TRACK_OFF := Color(0.180, 0.212, 0.259)

static var _sw_icons: Array = []


static func _capsule(img: Image, x0: int, y0: int, x1: int, y1: int, r: float, col: Color) -> void:
	for y in range(y0, y1):
		for x in range(x0, x1):
			var fx := float(x) + 0.5
			var fy := float(y) + 0.5
			var cx := clampf(fx, float(x0) + r, float(x1) - r)
			var cy := clampf(fy, float(y0) + r, float(y1) - r)
			var dx := fx - cx
			var dy := fy - cy
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, col)


static func _make_switch(on: bool) -> ImageTexture:
	var img := Image.create(SWITCH_W, SWITCH_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_capsule(img, 0, 0, SWITCH_W, SWITCH_H, SWITCH_H / 2.0,
			C_ACCENT if on else SWITCH_TRACK_OFF)
	var kr := SWITCH_H / 2.0 - 3.0
	var kx := float(SWITCH_W) - float(SWITCH_H) / 2.0 if on else float(SWITCH_H) / 2.0
	_capsule(img, int(kx - kr), 3, int(kx + kr), SWITCH_H - 3, kr, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)


static func switch_icons() -> Array:
	if _sw_icons.is_empty():
		_sw_icons = [_make_switch(false), _make_switch(true)]
	return _sw_icons


static func style_check(cb: CheckButton, size: int) -> void:
	style_control(cb, size)
	# 开关图标和文字颜色由 Kit 主题变体提供。
	_apply_variation(cb, &"Kit")


static func button(text: String, size: int, min_size: Vector2 = Vector2(420, 64),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	style_button(b, variant)
	return b


static func apply_font_recursive(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer 			or root is GridContainer or root is ScrollContainer):
		var pf: Font = pixel_font()
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		apply_font_recursive(n)


static func line_edit(parent: Node, pos: Vector2, size: Vector2, placeholder: String,
		initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = size
	le.placeholder_text = placeholder
	le.text = initial
	style_control(le, 16)
	style_line_edit(le)
	parent.add_child(le)
	return le
