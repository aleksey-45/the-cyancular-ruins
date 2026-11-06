class_name UiFactory
extends RefCounted



static func pixel_font() -> FontFile:
	return PixelFont.shared()


static func style_control(c: Control, size: int) -> void:
	assert(size % 16 == 0, "字号必须是 16 的倍数(本项目像素字体只在 16/32/48… 下像素锐利);收到 %d" % size)
	c.add_theme_font_size_override("font_size", size)
	var pf: FontFile = pixel_font()
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


# ── 调色板(全项目 UI 配色的唯一来源:颜色只在这里定义,其余文件一律引用,不许再写 Color 字面量)──
const C_BG          := Color(0.039, 0.059, 0.094)
const C_SURFACE     := Color(0.071, 0.086, 0.118)
const C_ROW         := Color(0.086, 0.094, 0.110)
const C_FIELD       := Color(0.106, 0.118, 0.141)
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)
# 描边亮度标定目标(实测,不是拍脑袋):对页面底 ≥3:1、对按钮填充 ≥3:1 —— 第一版 #3D4A5A 只到 2.13:1 / 1.82:1,偏暗故上调。
const C_BORDER      := Color(0.361, 0.439, 0.561)
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)
const C_ACCENT      := Color(0.349, 0.851, 0.902)
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_TEXT        := Color(0.878, 0.914, 0.949)
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)
# ★★ C_WHITE 不是 C_TEXT(C_TEXT 略带蓝,单通道差 0.122):别把走默认色的调用点统一成 C_TEXT —— 深底上肉眼几乎看不出,但迁移的判据是逐像素(设置页键位表那一列动作名,实测差 9220 个像素)。
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

const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)

# 延迟阈值配色的单一来源:两个对局 HUD(pvp_hud / royale_hud)的 _on_ping 都调它 —— 原先只有 1v1 按阈值上色,同一个数字在两种模式里长得不一样。
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

const BTN_BORDER_W := 2


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
	var osb := StyleBoxFlat.new()
	osb.bg_color = C_SURFACE
	osb.border_color = C_BORDER
	osb.set_border_width_all(1)
	osb.set_corner_radius_all(0)
	outer.add_theme_stylebox_override("panel", osb)

	var body := PanelContainer.new()
	body.name = "Body"
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0, 0, 0)
	isb.border_color = C_INNER
	isb.set_border_width_all(1)
	isb.set_corner_radius_all(0)
	isb.content_margin_left = padding.x
	isb.content_margin_right = padding.x
	isb.content_margin_top = padding.y
	isb.content_margin_bottom = padding.y
	body.add_theme_stylebox_override("panel", isb)
	# 把外层已有的子节点搬进 Body(就地套皮的调用方:骨架来自 .tscn);★ 必须先 remove_child 再 add_child —— 同帧直接 add 会因已有父节点而静默换父失败。
	for c in outer.get_children():
		outer.remove_child(c)
		body.add_child(c)
	outer.add_child(body)


static func menu_button(text: String, size: int, min_size: Vector2 = Vector2(640, 88),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	var edge := C_EDGE
	var fg := C_TEXT
	if variant == "quiet":
		edge = C_BORDER_DIM
		fg = C_TEXT_DIM
	elif variant == "gold":
		edge = C_GOLD
		fg = C_GOLD
	elif variant == "accent":
		edge = C_ACCENT
		fg = C_TEXT
	b.add_theme_stylebox_override("normal", _btn_box(C_HEADER, edge))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _btn_box(C_HEADER, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_HEADER, C_BORDER_DIM))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_MUTE)
	return b


const HEADER_INSET := 24.0
const HEADER_PAD_Y := 20.0


static func header_strip(text: String, size: int = 32, centered := false) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = C_BORDER
	sb.content_margin_left = HEADER_INSET
	sb.content_margin_right = HEADER_INSET
	sb.content_margin_top = HEADER_PAD_Y
	sb.content_margin_bottom = HEADER_PAD_Y
	p.add_theme_stylebox_override("panel", sb)
	var l := label(text, size, C_GOLD)
	if centered:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


# menu_filter_button 已删(全仓零调用):选中态由 scenes/mp_lobby.tscn 的内联 SubResource 承担;为何 Theme 里没有 Filter 变体见 tools/gen_menu_theme.gd 开头的覆盖上限注。


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
	b.add_theme_stylebox_override("normal", _row_sb(C_ROW, C_ROW))
	b.add_theme_stylebox_override("hover", _row_sb(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _row_sb(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _row_sb(C_ROW, C_ROW))
	b.add_theme_stylebox_override("disabled", _row_sb(C_ROW, C_ROW))
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", C_TEXT)


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
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_FIELD
	sb.border_color = C_BORDER_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	le.add_theme_stylebox_override("normal", sb)
	var focus := sb.duplicate() as StyleBoxFlat
	focus.border_color = C_ACCENT
	le.add_theme_stylebox_override("focus", focus)
	le.add_theme_color_override("font_color", C_TEXT)
	le.add_theme_color_override("font_placeholder_color", C_TEXT_DIM)
	le.add_theme_color_override("caret_color", C_ACCENT)


static func style_button(b: Button, variant: String = "primary") -> void:
	var dim := variant == "quiet"
	var base := C_BORDER_DIM if dim else C_BORDER
	b.add_theme_stylebox_override("normal", _btn_box(C_BTN_FILL, base))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _btn_box(C_BTN_FILL, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_BTN_FILL, C_BORDER_DIM))
	var fg := C_TEXT_DIM if dim else C_TEXT
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_DIM)


# ── 开关图形:Godot 默认主题的 CheckButton 开 = 一条浅灰药丸,关 = 一个小灰点、轨道不可见(状态一变连形状都变了);自绘一对图标,开/关都是完整胶囊轨道,只有颜色与滑块位置不同 ──
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
	cb.add_theme_color_override("font_color", C_TEXT)
	cb.add_theme_color_override("font_hover_color", C_ACCENT)
	cb.add_theme_color_override("font_pressed_color", C_ACCENT)
	cb.add_theme_color_override("font_focus_color", C_TEXT)
	var ic := switch_icons()
	cb.add_theme_icon_override("unchecked", ic[0])
	cb.add_theme_icon_override("checked", ic[1])


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
		var pf: FontFile = pixel_font()
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
