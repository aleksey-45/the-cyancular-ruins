class_name UiFactory
extends RefCounted


# ── 设计系统 tokens(单一来源 = 本文件;页面只许引用,不许写字面量 —— 契约 .tmp/ui-system-contract.md §2)──
# 间距档(像素;布局度量,8 的倍数)
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
# HUD 屏边距:**离屏幕边**的统一距离(与 SP_5 同值但语义不同 —— SP_* 是控件间距)。HUD 例外用
# anchors + 本 token 表达,页面禁止再用 `1920.0 - …` / `1440.0 - …` 从逻辑分辨率反推坐标
# (契约 .tmp/ui-system-contract.md §5 / docs/eng/ui-design-system.md §5)。
const MARGIN := 24
# 字号档(像素字体只在 16 的倍数下锐利;新增档位必须同步 style_control 的 assert)
const T_TITLE := 160
const T_HUGE := 128
const T_H1 := 48
const T_H2 := 32
const T_BODY := 16
const T_LABEL := 16
# 圆角 / 描边
const R_SM := 3
const R_MD := 4
const R_LG := 6
const BORDER_W := 2
const BORDER_W_DIM := 1

# Theme 2.0(type variations 全由 tools/gen_menu_theme.gd 生成;本文件只引用,不手工造样式)。
# ★ 为什么把 Theme 挂在工厂控件自己身上:控件可能被加进**没挂 menu_theme 的树**(HUD / 载入屏 /
#   服务端 GUI / 编辑器),只设 variation 在那种树里会退回 Godot 默认主题(灰皮)。挂的是**同一份**
#   资源(单一真相源不变),variation 在任何调用树里都能解析;挂在已挂主题的树上也无害。
const MENU_THEME := preload("res://ui/theme/menu_theme.tres")


static func _apply_variation(c: Control, variation: StringName) -> void:
	c.theme = MENU_THEME
	c.theme_type_variation = variation


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
# 主菜单实时光影背景上的压暗层(可读性;不是 HUD 底板,单独一个 token)。
const C_MENU_DIM    := Color(0, 0, 0, 0.22)
# HUD 里「选中的武器行」底板:比通用 C_PLATE 深一档(原先 hud.gd 在调用点写 Color(0,0,0,0.28));
# 颜色定义只许住在本文件 —— 页面引用本 token,不许写字面量。
const C_PLATE_DEEP  := Color(0, 0, 0, 0.28)

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

const BTN_BORDER_W := BORDER_W   # 兼容旧引用;新代码用 BORDER_W


# ── HUD 底板工厂 ───────────────────────────────────────────────────────────
# HUD 元素一律垫半透明深底板(唯一颜色语义 = C_PLATE 黑 0.1;例外见 docs/eng/ui.md「HUD」)。
# 本函数是**唯一**一处 HUD 底板 `StyleBoxFlat` 的构造点:页面不再手写 `StyleBoxFlat.new()` /
# `add_theme_stylebox_override`(契约 §4)。语义与迁移前逐处复制完全一致:直角、无描边、
# content margin 由调用方给像素档(同一调用方的 x/y 对称)。
#   · draw_center=false:不画底色(右上角击杀计数器:只留 content margin 撑出留白)。
#   · fill:默认 C_PLATE;选中态用 C_PLATE_DEEP,不垫底用 C_TRANSPARENT。
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
	# 内衬 = 透明底 + C_INNER 亮线;padding 是**布局参数**不是样式 —— 能对上 Theme 现成档位的直接取变体,
	# 对不上的从 Theme 的 PanelCarvedBody 复制一份、只改 content_margin(颜色/描边仍只有主题一份真相源)。
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
	# 把外层已有的子节点搬进 Body(就地套皮的调用方:骨架来自 .tscn);★ 必须先 remove_child 再 add_child —— 同帧直接 add 会因已有父节点而静默换父失败。
	for c in outer.get_children():
		outer.remove_child(c)
		body.add_child(c)
	outer.add_child(body)


# Theme 里已有的「抠槽内衬」档位(与 tools/gen_menu_theme.gd 的 _panel_variants 对应);其它 padding 走复制档。
static func _body_variation_for(padding: Vector2) -> StringName:
	if padding == Vector2(64, 46):
		return &"PanelCarvedBody"
	if padding == Vector2(72, 44):
		return &"PanelCarvedBodyInset72"
	return &""


# 旧 API 的 variant 名 → Theme 里的旧 variation(样式值没变,只是从逐控件 override 换成主题)。
const _MENU_BTN_VARIATIONS := {
	"primary": &"BtnPrimary", "quiet": &"BtnQuiet",
	"gold": &"BtnGold", "accent": &"BtnAccent",
}
# 新 API 的 variant 名 → Theme 2.0 的 Button variation(契约 §3)。
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


# ── 组件化薄 API(契约 §4;新页面只用这些 + tokens,不再自己拼 StyleBox / 设字号)──
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
	# 旧 API 的两种皮 = Theme 里的 BtnLegacy / BtnLegacyQuiet(与改造前逐字段等值:填充 C_BTN_FILL、
# 描边 C_BORDER / C_BORDER_DIM;menu_button 那套 C_HEADER 填充的是 BtnPrimary 家族)。
	var v := &"BtnLegacyQuiet" if variant == "quiet" else &"BtnLegacy"
	_apply_variation(b, v)


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
	# 图标(自绘胶囊开关)与文字色都在 Theme 的 Kit variation 里;不再逐控件挂 override。
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
