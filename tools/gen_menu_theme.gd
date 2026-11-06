extends SceneTree


const OUT_THEME := "res://ui/theme/menu_theme.tres"
const OUT_SWITCH_OFF := "res://ui/theme/switch_off.png"
const OUT_SWITCH_ON := "res://ui/theme/switch_on.png"
const FONT_RES := "res://assets/fonts/menu_font.tres"

var _fails: Array[String] = []


func _initialize() -> void:
	var F: GDScript = load("res://ui/factory/ui_factory.gd")
	var font: Font = load(FONT_RES)
	if F == null:
		print("GEN THEME: FAIL(读不到 ui/factory/ui_factory.gd)")
		quit(1)
		return
	if font == null:
		print("GEN THEME: FAIL(读不到 %s)" % FONT_RES)
		quit(1)
		return
	var C: Dictionary = F.get_script_constant_map()

	# ★ 两趟:Theme 要引用两个开关 PNG,而 res:// 下的 PNG 必须先 --import 才 load() 得到(-s 不触发导入)⇒ 第一趟写下 PNG 并以 exit 1 要求「先 --import 再重跑」,第二趟才真的建 Theme。
	# ★ 刻意不做「缺图标也照样存一份」:那会留下一份看着成功、其实少两个图标的 .tres,而「开关画成默认主题的小灰点」这种缺失不会报错。
	if not _switch_icons_ready():
		_export_switch_icons(F)
		print("GEN THEME: 图标已导出 → 请先跑 `--import`,再重跑本工具")
		quit(1)
		return

	var t := Theme.new()
	t.default_font = font

	_label_variants(t, C)
	_button_variants(t, F, C)
	_panel_variants(t, F, C)
	_other_controls(t, F, C)

	var err := ResourceSaver.save(t, OUT_THEME)
	if err != OK:
		print("GEN THEME: FAIL(保存 %s 返回 %d)" % [OUT_THEME, err])
		quit(1)
		return
	_export_switch_icons(F)

	if _fails.is_empty():
		print("GEN THEME: OK(→ %s)" % OUT_THEME)
		quit(0)
	else:
		for f in _fails:
			print("  FAIL " + f)
		print("GEN THEME: FAIL(%d 条)" % _fails.size())
		quit(1)


# 取调色板里的颜色;缺失即记红(不静默用默认值 —— 那会让生成出来的 .tres 悄悄跑偏)。
func _c(C: Dictionary, name: String) -> Color:
	if not C.has(name):
		_fails.append("调色板里没有 `%s`(UiFactory 改名了?本工具要跟着改)" % name)
		return Color.MAGENTA
	return C[name] as Color


func _label_variants(t: Theme, C: Dictionary) -> void:
	t.set_color("font_color", "Label", _c(C, "C_TEXT"))
	t.set_font_size("font_size", "Label", 32)
	t.set_type_variation("H1", "Label")
	t.set_font_size("font_size", "H1", 48)
	t.set_color("font_color", "H1", _c(C, "C_TEXT"))
	t.set_type_variation("Body", "Label")
	t.set_font_size("font_size", "Body", 32)
	t.set_color("font_color", "Body", _c(C, "C_TEXT"))
	t.set_type_variation("Small", "Label")
	t.set_font_size("font_size", "Small", 16)
	t.set_color("font_color", "Small", _c(C, "C_TEXT"))
	t.set_type_variation("HeaderTitle", "Label")
	t.set_font_size("font_size", "HeaderTitle", 32)
	t.set_color("font_color", "HeaderTitle", _c(C, "C_GOLD"))
	t.set_type_variation("Dim", "Label")
	t.set_font_size("font_size", "Dim", 32)
	t.set_color("font_color", "Dim", _c(C, "C_TEXT_DIM"))


func _button_variants(t: Theme, F: GDScript, C: Dictionary) -> void:
	_menu_btn(t, F, C, "BtnPrimary", _c(C, "C_EDGE"), _c(C, "C_TEXT"))
	_menu_btn(t, F, C, "BtnQuiet", _c(C, "C_BORDER_DIM"), _c(C, "C_TEXT_DIM"))
	_menu_btn(t, F, C, "BtnGold", _c(C, "C_GOLD"), _c(C, "C_GOLD"))
	_menu_btn(t, F, C, "BtnAccent", _c(C, "C_ACCENT"), _c(C, "C_TEXT"))
	_legacy_btn(t, F, C, "BtnLegacy", false)
	_legacy_btn(t, F, C, "BtnLegacyQuiet", true)


func _menu_btn(t: Theme, F: GDScript, C: Dictionary, name: String, edge: Color, fg: Color) -> void:
	t.set_type_variation(name, "Button")
	t.set_font_size("font_size", name, 32)
	t.set_stylebox("normal", name, F.call("_btn_box", _c(C, "C_HEADER"), edge))
	t.set_stylebox("hover", name, F.call("_btn_box", _c(C, "C_BTN_FILL_HI"), _c(C, "C_ACCENT")))
	t.set_stylebox("pressed", name, F.call("_btn_box", _c(C, "C_BTN_FILL_DN"), _c(C, "C_ACCENT")))
	t.set_stylebox("focus", name, F.call("_btn_box", _c(C, "C_HEADER"), _c(C, "C_ACCENT")))
	t.set_stylebox("disabled", name, F.call("_btn_box", _c(C, "C_HEADER"), _c(C, "C_BORDER_DIM")))
	t.set_color("font_color", name, fg)
	t.set_color("font_hover_color", name, _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", name, fg)
	t.set_color("font_pressed_color", name, _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", name, _c(C, "C_TEXT_MUTE"))


func _legacy_btn(t: Theme, F: GDScript, C: Dictionary, name: String, dim: bool) -> void:
	t.set_type_variation(name, "Button")
	t.set_font_size("font_size", name, 32)
	var base := _c(C, "C_BORDER_DIM") if dim else _c(C, "C_BORDER")
	t.set_stylebox("normal", name, F.call("_btn_box", _c(C, "C_BTN_FILL"), base))
	t.set_stylebox("hover", name, F.call("_btn_box", _c(C, "C_BTN_FILL_HI"), _c(C, "C_ACCENT")))
	t.set_stylebox("pressed", name, F.call("_btn_box", _c(C, "C_BTN_FILL_DN"), _c(C, "C_ACCENT")))
	t.set_stylebox("focus", name, F.call("_btn_box", _c(C, "C_BTN_FILL"), _c(C, "C_ACCENT")))
	t.set_stylebox("disabled", name, F.call("_btn_box", _c(C, "C_BTN_FILL"), _c(C, "C_BORDER_DIM")))
	var fg := _c(C, "C_TEXT_DIM") if dim else _c(C, "C_TEXT")
	t.set_color("font_color", name, fg)
	t.set_color("font_hover_color", name, _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", name, fg)
	t.set_color("font_pressed_color", name, _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", name, _c(C, "C_TEXT_DIM"))


func _panel_variants(t: Theme, F: GDScript, C: Dictionary) -> void:
	t.set_stylebox("panel", "PanelContainer", F.call("panel_box", true))

	t.set_type_variation("PanelCarved", "PanelContainer")
	var outer := StyleBoxFlat.new()
	outer.bg_color = _c(C, "C_SURFACE")
	outer.border_color = _c(C, "C_BORDER")
	outer.set_border_width_all(1)
	outer.set_corner_radius_all(0)
	t.set_stylebox("panel", "PanelCarved", outer)

	t.set_type_variation("PanelCarvedBody", "PanelContainer")
	t.set_stylebox("panel", "PanelCarvedBody", _carved_body(C, Vector2(64, 46)))

	t.set_type_variation("PanelCarvedBodyInset72", "PanelContainer")
	t.set_stylebox("panel", "PanelCarvedBodyInset72", _carved_body(C, Vector2(72, 44)))

	t.set_type_variation("HeaderStrip", "PanelContainer")
	var hs := StyleBoxFlat.new()
	hs.bg_color = _c(C, "C_HEADER")
	hs.set_corner_radius_all(0)
	hs.border_width_left = 0
	hs.border_width_right = 0
	hs.border_width_top = 0
	hs.border_width_bottom = 1
	hs.border_color = _c(C, "C_BORDER")
	hs.content_margin_left = 24.0
	hs.content_margin_right = 24.0
	hs.content_margin_top = 20.0
	hs.content_margin_bottom = 20.0
	t.set_stylebox("panel", "HeaderStrip", hs)

	t.set_type_variation("RowPanel", "PanelContainer")
	t.set_stylebox("panel", "RowPanel", F.call("row_box"))

	t.set_type_variation("RowButton", "Button")
	t.set_font_size("font_size", "RowButton", 32)
	t.set_stylebox("normal", "RowButton", F.call("_row_sb", _c(C, "C_ROW"), _c(C, "C_ROW")))
	t.set_stylebox("hover", "RowButton", F.call("_row_sb", _c(C, "C_BTN_FILL_HI"), _c(C, "C_ACCENT")))
	t.set_stylebox("pressed", "RowButton", F.call("_row_sb", _c(C, "C_BTN_FILL_DN"), _c(C, "C_ACCENT")))
	t.set_stylebox("focus", "RowButton", F.call("_row_sb", _c(C, "C_ROW"), _c(C, "C_ROW")))
	t.set_stylebox("disabled", "RowButton", F.call("_row_sb", _c(C, "C_ROW"), _c(C, "C_ROW")))
	t.set_color("font_color", "RowButton", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "RowButton", _c(C, "C_ACCENT"))
	t.set_color("font_pressed_color", "RowButton", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "RowButton", _c(C, "C_TEXT"))


func _carved_body(C: Dictionary, pad: Vector2) -> StyleBoxFlat:
	var body := StyleBoxFlat.new()
	body.bg_color = _c(C, "C_TRANSPARENT")
	body.border_color = _c(C, "C_INNER")
	body.set_border_width_all(1)
	body.set_corner_radius_all(0)
	body.content_margin_left = pad.x
	body.content_margin_right = pad.x
	body.content_margin_top = pad.y
	body.content_margin_bottom = pad.y
	return body


func _other_controls(t: Theme, F: GDScript, C: Dictionary) -> void:
	var le := StyleBoxFlat.new()
	le.bg_color = _c(C, "C_FIELD")
	le.border_color = _c(C, "C_BORDER_DIM")
	le.set_border_width_all(2)
	le.set_corner_radius_all(0)
	le.content_margin_left = 16.0
	le.content_margin_right = 16.0
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate() as StyleBoxFlat
	lef.border_color = _c(C, "C_ACCENT")
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_font_size("font_size", "LineEdit", 16)
	t.set_color("font_color", "LineEdit", _c(C, "C_TEXT"))
	t.set_color("font_placeholder_color", "LineEdit", _c(C, "C_TEXT_DIM"))
	t.set_color("caret_color", "LineEdit", _c(C, "C_ACCENT"))

	t.set_font_size("font_size", "CheckButton", 32)
	t.set_color("font_color", "CheckButton", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "CheckButton", _c(C, "C_ACCENT"))
	t.set_color("font_pressed_color", "CheckButton", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "CheckButton", _c(C, "C_TEXT"))
	var off: Texture2D = load(OUT_SWITCH_OFF)
	var on: Texture2D = load(OUT_SWITCH_ON)
	if off == null or on == null:
		_fails.append("读不到开关图标 %s / %s —— 先跑本工具导出 PNG,再 --import,然后重跑"
				% [OUT_SWITCH_OFF, OUT_SWITCH_ON])
	else:
		t.set_icon("unchecked", "CheckButton", off)
		t.set_icon("checked", "CheckButton", on)

	var track := StyleBoxFlat.new()
	track.bg_color = _c(C, "C_BORDER_DIM")
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", F.call("_row_sb", _c(C, "C_ACCENT"), _c(C, "C_ACCENT")))
	t.set_stylebox("grabber_area_highlight", "HSlider",
			F.call("_row_sb", _c(C, "C_ACCENT"), _c(C, "C_ACCENT")))


func _switch_icons_ready() -> bool:
	return load(OUT_SWITCH_OFF) != null and load(OUT_SWITCH_ON) != null


func _export_switch_icons(F: GDScript) -> void:
	var icons: Array = F.call("switch_icons")
	if icons.size() != 2:
		_fails.append("`switch_icons()` 没返回两个图标(实得 %d)" % icons.size())
		return
	var paths := [OUT_SWITCH_OFF, OUT_SWITCH_ON]
	for i in 2:
		var tex: ImageTexture = icons[i]
		var img: Image = tex.get_image() if tex != null else null
		if img == null:
			_fails.append("`switch_icons()[%d]` 取不到 Image" % i)
			continue
		var err := img.save_png(paths[i])
		if err != OK:
			_fails.append("保存 %s 返回 %d" % [paths[i], err])
