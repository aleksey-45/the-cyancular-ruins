class_name UiDesign
extends "res://ui/theme/menu_style.gd"

# 主题类型变体由 tools/gen_menu_theme_v2.gd 生成。
# 工厂为控件引用同一份主题资源，确保 HUD、加载界面和编辑器中的控件都能解析主题变体。
const MENU_THEME := preload("res://ui/theme/menu_theme_v2.tres")


static func _apply_variation(c: Control, variation: StringName) -> void:
	c.theme = MENU_THEME
	c.theme_type_variation = variation


static func pixel_font() -> Font:
	return PixelFont.FONT


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


static func hud_plate(c: Control, pad_x: int, pad_y: int, draw_center := true,
		fill: Color = C_PLATE) -> void:
	var sb := flat(fill, Color.TRANSPARENT, 0, pad_x, pad_y)
	sb.draw_center = draw_center
	c.add_theme_stylebox_override("panel", sb)


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


const _BUTTON_VARIATIONS := {
	"primary": &"Primary", "quiet": &"Quiet", "danger": &"Danger", "icon": &"Icon",
	"gold": &"BtnGold", "accent": &"BtnAccent",
}


static func ui_button(text: String, size: int = T_H2, min_size: Vector2 = Vector2.ZERO,
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	_apply_variation(b, _BUTTON_VARIATIONS[variant])
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


static func header_strip(text: String, size: int = 32, centered := false) -> PanelContainer:
	var p := PanelContainer.new()
	_apply_variation(p, &"HeaderStrip")
	var l := label(text, size, C_GOLD)
	if centered:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


static func style_row_button(b: Button) -> void:
	_apply_variation(b, &"RowButton")
