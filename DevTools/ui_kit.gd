class_name DevUIKit
extends RefCounted

# DevTools 本地 UI 控件工厂:像素字体 + 常用控件一行建好。
# 模式抄自 Scenes/main_menu.gd 的 _pixel_label/_style_control/_pixel_button,
# 不 import 场景脚本(避免跨目录耦合)。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"

static var _font: FontFile = null


static func font() -> FontFile:
	if _font == null:
		_font = load(PIXEL_FONT)
		if _font != null:
			_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			_font.hinting = TextServer.HINTING_NONE
			_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return _font


static func label(text: String, size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pf := font()
	if pf != null:
		l.add_theme_font_override("font", pf)
	return l


static func button(text: String, font_size: int, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", font_size)
	var pf := font()
	if pf != null:
		b.add_theme_font_override("font", pf)
	b.pressed.connect(func() -> void: Sfx.play("ui"))
	b.pressed.connect(on_pressed)
	return b


static func toggle(text: String, font_size: int, group: ButtonGroup) -> Button:
	var b := button(text, font_size, func() -> void: pass)
	b.toggle_mode = true
	b.button_group = group
	return b


static func line_edit(placeholder: String, text: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(0, 44)
	var pf := font()
	if pf != null:
		e.add_theme_font_override("font", pf)
		e.add_theme_font_size_override("font_size", 20)
	return e


static func text_edit(placeholder: String, text: String) -> TextEdit:
	var e := TextEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(0, 96)
	e.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	var pf := font()
	if pf != null:
		e.add_theme_font_override("font", pf)
		e.add_theme_font_size_override("font_size", 20)
	return e


static func spin_box(mini: float, maxi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = mini
	s.max_value = maxi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(160, 44)
	var pf := font()
	if pf != null:
		s.add_theme_font_override("font", pf)
		s.add_theme_font_size_override("font_size", 20)
	return s


static func option(options: Array, selected: int) -> OptionButton:
	var o := OptionButton.new()
	for t in options:
		o.add_item(str(t))
	o.selected = clampi(selected, 0, options.size() - 1)
	o.custom_minimum_size = Vector2(180, 44)
	var pf := font()
	if pf != null:
		o.add_theme_font_override("font", pf)
		o.add_theme_font_size_override("font_size", 20)
	return o


static func check(text: String, pressed: bool) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = pressed
	var pf := font()
	if pf != null:
		c.add_theme_font_override("font", pf)
		c.add_theme_font_size_override("font_size", 20)
	return c
