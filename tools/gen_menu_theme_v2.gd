extends SceneTree

const Style := preload("res://ui/theme/menu_style.gd")
const FONT := preload("res://assets/fonts/menu_font.tres")
const SWITCH_OFF := preload("res://ui/theme/switch_off.png")
const SWITCH_ON := preload("res://ui/theme/switch_on.png")
const OUT_THEME := "res://ui/theme/menu_theme_v2.tres"


func _initialize() -> void:
	var theme := Theme.new()
	theme.default_font = FONT
	_label_variants(theme)
	_field_variants(theme)
	_button_variants(theme)
	_panel_variants(theme)
	_other_controls(theme)
	_editor_controls(theme)
	var error := ResourceSaver.save(theme, OUT_THEME)
	if error != OK:
		printerr("GEN THEME: " + error_string(error))
	else:
		print("GEN THEME: " + OUT_THEME)
	quit(0 if error == OK else 1)


func _button_box(fill: Color, border: Color) -> StyleBoxFlat:
	return Style.flat(fill, border, Style.BORDER_W, Style.SP_7, 20)


func _row_box(fill: Color, border: Color) -> StyleBoxFlat:
	return Style.flat(fill, border, Style.BORDER_W, Style.SP_4, Style.SP_2)


func _label_variants(t: Theme) -> void:
	t.set_color("font_color", "Label", Style.C_TEXT)
	t.set_font_size("font_size", "Label", Style.T_H2)
	t.set_type_variation("H1", "Label")
	t.set_font_size("font_size", "H1", Style.T_H1)
	t.set_color("font_color", "H1", Style.C_TEXT)
	t.set_type_variation("H2", "Label")
	t.set_font_size("font_size", "H2", Style.T_H2)
	t.set_color("font_color", "H2", Style.C_TEXT)
	t.set_type_variation("Body", "Label")
	t.set_font_size("font_size", "Body", Style.T_H2)
	t.set_color("font_color", "Body", Style.C_TEXT)
	t.set_type_variation("Small", "Label")
	t.set_font_size("font_size", "Small", Style.T_LABEL)
	t.set_color("font_color", "Small", Style.C_TEXT)
	t.set_type_variation("HeaderTitle", "Label")
	t.set_font_size("font_size", "HeaderTitle", Style.T_H2)
	t.set_color("font_color", "HeaderTitle", Style.C_GOLD)
	t.set_type_variation("SmallDim", "Label")
	t.set_font_size("font_size", "SmallDim", Style.T_LABEL)
	t.set_color("font_color", "SmallDim", Style.C_TEXT_MUTE)
	t.set_type_variation("Dim", "Label")
	t.set_font_size("font_size", "Dim", Style.T_H2)
	t.set_color("font_color", "Dim", Style.C_TEXT_DIM)


# Label 和 LineEdit 共用 Field 主题类型变体的字号，各自从控件类型读取正文颜色。
# LineEdit 还会读取输入框样式、插入光标颜色和占位文字颜色。
func _field_variants(t: Theme) -> void:
	t.set_type_variation("Field", "Control")
	t.set_font_size("font_size", "Field", Style.T_LABEL)
	t.set_color("caret_color", "Field", Style.C_ACCENT)
	t.set_color("font_placeholder_color", "Field", Style.C_TEXT_DIM)
	t.set_stylebox("normal", "Field",
			Style.flat(Style.C_FIELD, Style.C_BORDER_DIM, Style.BORDER_W, Style.SP_3, 0))
	t.set_stylebox("focus", "Field",
			Style.flat(Style.C_FIELD, Style.C_ACCENT, Style.BORDER_W, Style.SP_3, 0))


func _button_variants(t: Theme) -> void:
	_menu_btn(t, "Primary", Style.C_EDGE, Style.C_TEXT)
	_menu_btn(t, "Quiet", Style.C_BORDER_DIM, Style.C_TEXT_DIM)
	_menu_btn(t, "BtnGold", Style.C_GOLD, Style.C_GOLD)
	_menu_btn(t, "BtnAccent", Style.C_ACCENT, Style.C_TEXT)
	_danger_btn(t)
	_icon_btn(t)


func _menu_btn(t: Theme, name: String, edge: Color, fg: Color) -> void:
	t.set_type_variation(name, "Button")
	t.set_font_size("font_size", name, Style.T_H2)
	t.set_stylebox("normal", name, _button_box(Style.C_HEADER, edge))
	t.set_stylebox("hover", name, _button_box(Style.C_BTN_FILL_HI, Style.C_ACCENT))
	t.set_stylebox("pressed", name, _button_box(Style.C_BTN_FILL_DN, Style.C_ACCENT))
	t.set_stylebox("focus", name, _button_box(Style.C_HEADER, Style.C_ACCENT))
	t.set_stylebox("disabled", name, _button_box(Style.C_HEADER, Style.C_BORDER_DIM))
	t.set_color("font_color", name, fg)
	t.set_color("font_hover_color", name, Style.C_ACCENT)
	t.set_color("font_focus_color", name, fg)
	t.set_color("font_pressed_color", name, Style.C_ACCENT)
	t.set_color("font_disabled_color", name, Style.C_TEXT_MUTE)


func _danger_btn(t: Theme) -> void:
	# 危险操作常态使用警示色描边。悬停或按下时改用正文颜色，保持亮底上的文字可读。
	t.set_type_variation("Danger", "Button")
	t.set_font_size("font_size", "Danger", Style.T_H2)
	t.set_stylebox("normal", "Danger", _button_box(Style.C_HEADER, Style.C_DANGER))
	t.set_stylebox("hover", "Danger", _button_box(Style.C_BTN_FILL_HI, Style.C_DANGER))
	t.set_stylebox("pressed", "Danger", _button_box(Style.C_BTN_FILL_DN, Style.C_DANGER))
	t.set_stylebox("focus", "Danger", _button_box(Style.C_HEADER, Style.C_DANGER))
	t.set_stylebox("disabled", "Danger", _button_box(Style.C_HEADER, Style.C_BORDER_DIM))
	t.set_color("font_color", "Danger", Style.C_DANGER)
	t.set_color("font_hover_color", "Danger", Style.C_TEXT)
	t.set_color("font_focus_color", "Danger", Style.C_DANGER)
	t.set_color("font_pressed_color", "Danger", Style.C_TEXT)
	t.set_color("font_disabled_color", "Danger", Style.C_TEXT_MUTE)


func _icon_btn(t: Theme) -> void:
	# 选图卡片使用相同的边距，避免切换状态时内容移位。
	var pad := Style.SP_2
	t.set_type_variation("Icon", "Button")
	t.set_font_size("font_size", "Icon", Style.T_H2)
	t.set_stylebox("normal", "Icon", Style.flat(Style.C_SURFACE, Style.C_BORDER, Style.BORDER_W, pad, pad))
	t.set_stylebox("hover", "Icon", Style.flat(Style.C_BTN_FILL_HI, Style.C_ACCENT, Style.BORDER_W, pad, pad))
	t.set_stylebox("pressed", "Icon", Style.flat(Style.C_BTN_FILL_DN, Style.C_ACCENT, Style.BORDER_W, pad, pad))
	t.set_stylebox("focus", "Icon", Style.flat(Style.C_TRANSPARENT, Style.C_ACCENT, Style.BORDER_W_DIM, pad, pad))
	t.set_stylebox("disabled", "Icon", Style.flat(Style.C_TRANSPARENT, Style.C_BORDER_DIM, Style.BORDER_W_DIM, pad, pad))
	t.set_color("font_color", "Icon", Style.C_TEXT)
	t.set_color("font_hover_color", "Icon", Style.C_ACCENT)
	t.set_color("font_focus_color", "Icon", Style.C_TEXT)
	t.set_color("font_pressed_color", "Icon", Style.C_ACCENT)
	t.set_color("font_disabled_color", "Icon", Style.C_TEXT_MUTE)


func _panel_variants(t: Theme) -> void:
	# UI v2 的通用面板样式。
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card",
			Style.flat(Style.C_SURFACE, Style.C_BORDER, Style.BORDER_W, Style.SP_5, Style.SP_4))
	t.set_type_variation("Plain", "PanelContainer")
	t.set_stylebox("panel", "Plain",
			Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_4, Style.SP_4))
	t.set_type_variation("Bar", "PanelContainer")
	t.set_stylebox("panel", "Bar",
			Style.flat(Style.C_HEADER, Style.C_BORDER, Style.BORDER_W_DIM, Style.SP_4, Style.SP_2))

	t.set_stylebox("panel", "PanelContainer", Style.panel_box())

	t.set_type_variation("PanelCarved", "PanelContainer")
	var outer := StyleBoxFlat.new()
	outer.bg_color = Style.C_SURFACE
	outer.border_color = Style.C_BORDER
	outer.set_border_width_all(1)
	outer.set_corner_radius_all(0)
	t.set_stylebox("panel", "PanelCarved", outer)

	t.set_type_variation("PanelCarvedBody", "PanelContainer")
	t.set_stylebox("panel", "PanelCarvedBody", _carved_body(Vector2(64, 46)))

	t.set_type_variation("PanelCarvedBodyInset72", "PanelContainer")
	t.set_stylebox("panel", "PanelCarvedBodyInset72", _carved_body(Vector2(72, 44)))

	t.set_type_variation("HeaderStrip", "PanelContainer")
	var hs := StyleBoxFlat.new()
	hs.bg_color = Style.C_HEADER
	hs.set_corner_radius_all(0)
	hs.border_width_left = 0
	hs.border_width_right = 0
	hs.border_width_top = 0
	hs.border_width_bottom = 1
	hs.border_color = Style.C_BORDER
	hs.content_margin_left = 24.0
	hs.content_margin_right = 24.0
	hs.content_margin_top = 20.0
	hs.content_margin_bottom = 20.0
	t.set_stylebox("panel", "HeaderStrip", hs)

	t.set_type_variation("RowPanel", "PanelContainer")
	t.set_stylebox("panel", "RowPanel", Style.flat(Style.C_ROW, Color.TRANSPARENT, 0, Style.SP_4, Style.SP_2))

	t.set_type_variation("RowButton", "Button")
	t.set_font_size("font_size", "RowButton", Style.T_H2)
	t.set_stylebox("normal", "RowButton", _row_box(Style.C_ROW, Style.C_ROW))
	t.set_stylebox("hover", "RowButton", _row_box(Style.C_BTN_FILL_HI, Style.C_ACCENT))
	t.set_stylebox("pressed", "RowButton", _row_box(Style.C_BTN_FILL_DN, Style.C_ACCENT))
	t.set_stylebox("focus", "RowButton", _row_box(Style.C_ROW, Style.C_ROW))
	t.set_stylebox("disabled", "RowButton", _row_box(Style.C_ROW, Style.C_ROW))
	t.set_color("font_color", "RowButton", Style.C_TEXT)
	t.set_color("font_hover_color", "RowButton", Style.C_ACCENT)
	t.set_color("font_pressed_color", "RowButton", Style.C_ACCENT)
	t.set_color("font_focus_color", "RowButton", Style.C_TEXT)


func _carved_body(pad: Vector2) -> StyleBoxFlat:
	var body := StyleBoxFlat.new()
	body.bg_color = Style.C_TRANSPARENT
	body.border_color = Style.C_INNER
	body.set_border_width_all(1)
	body.set_corner_radius_all(0)
	body.content_margin_left = pad.x
	body.content_margin_right = pad.x
	body.content_margin_top = pad.y
	body.content_margin_bottom = pad.y
	return body


func _editor_controls(t: Theme) -> void:
	var well := Style.flat(Style.C_FIELD, Style.C_BORDER_DIM, 1, Style.SP_2, Style.SP_1)
	var hover := Style.flat(Style.C_BTN_FILL_HI, Style.C_BORDER, 1, Style.SP_2, Style.SP_1)
	var active := Style.flat(Style.C_ROW, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1)
	var focus := active.duplicate() as StyleBoxFlat
	focus.draw_center = false
	t.set_type_variation("ToolButton", "Button")
	t.set_font_size("font_size", "ToolButton", Style.T_SMALL)
	t.set_color("font_color", "ToolButton", Style.C_TEXT)
	t.set_color("font_pressed_color", "ToolButton", Style.C_ACCENT)
	t.set_stylebox("normal", "ToolButton", well)
	t.set_stylebox("hover", "ToolButton", hover)
	t.set_stylebox("pressed", "ToolButton", active)
	t.set_stylebox("hover_pressed", "ToolButton", active)
	t.set_stylebox("focus", "ToolButton", focus)
	t.set_type_variation("ToolPrimary", "ToolButton")
	t.set_color("font_color", "ToolPrimary", Style.C_GOLD)

	t.set_stylebox("panel", "ItemList", well)
	t.set_stylebox("selected", "ItemList", active)
	t.set_stylebox("selected_focus", "ItemList", active)
	t.set_stylebox("normal", "TextEdit", well)
	t.set_stylebox("focus", "TextEdit", focus)
	for kind in ["ItemList", "TextEdit", "FoldableContainer"]:
		t.set_color("font_color", kind, Style.C_TEXT)
		t.set_font_size("font_size", kind, Style.T_SMALL)
	for state in ["title_panel", "title_collapsed_panel"]:
		t.set_stylebox(state, "FoldableContainer", well)
	for state in ["title_hover_panel", "title_collapsed_hover_panel"]:
		t.set_stylebox(state, "FoldableContainer", hover)

	var border := Style.flat(Style.C_HEADER, Style.C_BORDER, 1, Style.SP_2, Style.SP_2)
	border.expand_margin_top = Style.SP_7
	t.set_stylebox("embedded_border", "Window", border)
	t.set_stylebox("embedded_unfocused_border", "Window", border)
	t.set_constant("title_height", "Window", Style.SP_7)
	t.set_font_size("title_font_size", "Window", Style.T_SMALL)
	t.set_color("title_color", "Window", Style.C_GOLD)
	t.set_stylebox("panel", "AcceptDialog", t.get_stylebox("panel", "Card"))
	t.set_constant("buttons_min_width", "AcceptDialog", Style.SP_9 + Style.SP_6)


func _other_controls(t: Theme) -> void:
	var le := StyleBoxFlat.new()
	le.bg_color = Style.C_FIELD
	le.border_color = Style.C_BORDER_DIM
	le.set_border_width_all(2)
	le.set_corner_radius_all(0)
	le.content_margin_left = 16.0
	le.content_margin_right = 16.0
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate() as StyleBoxFlat
	lef.border_color = Style.C_ACCENT
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_font_size("font_size", "LineEdit", Style.T_SMALL)
	t.set_color("font_color", "LineEdit", Style.C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Style.C_TEXT_DIM)
	t.set_color("caret_color", "LineEdit", Style.C_ACCENT)

	for kind in ["CheckButton", "CheckBox"]:
		t.set_font_size("font_size", kind, Style.T_H2 if kind == "CheckButton" else Style.T_SMALL)
		t.set_color("font_color", kind, Style.C_TEXT)
		t.set_color("font_hover_color", kind, Style.C_ACCENT)
		t.set_color("font_pressed_color", kind, Style.C_ACCENT)
		t.set_color("font_focus_color", kind, Style.C_TEXT)
		t.set_icon("unchecked", kind, SWITCH_OFF)
		t.set_icon("checked", kind, SWITCH_ON)

	var pad := Style.SP_1
	var scroll := Style.flat(Style.C_BTN_FILL_DN, Color.TRANSPARENT, 0, pad, pad)
	var grabber := Style.flat(Style.C_ACCENT, Color.TRANSPARENT, 0, pad, pad)
	t.set_stylebox("scroll", "ScrollBar", scroll)
	t.set_stylebox("scroll_focus", "ScrollBar", scroll)
	t.set_stylebox("grabber", "ScrollBar", Style.flat(Style.C_BORDER_DIM, Color.TRANSPARENT, 0, pad, pad))
	t.set_stylebox("grabber_highlight", "ScrollBar", grabber)
	t.set_stylebox("grabber_pressed", "ScrollBar", grabber)

	var track := StyleBoxFlat.new()
	track.bg_color = Style.C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", _row_box(Style.C_ACCENT, Style.C_ACCENT))
	t.set_stylebox("grabber_area_highlight", "HSlider",
			_row_box(Style.C_ACCENT, Style.C_ACCENT))


	# 下拉框、弹出菜单、工具提示和选项卡的主题项直接定义在各自的控件类型中。
	# 字体沿用 Theme.default_font，字号与紧凑工具栏一致。
	var ob := Style.flat(Style.C_FIELD, Style.C_BORDER_DIM, 1, Style.SP_3, Style.SP_2)
	t.set_stylebox("normal", "OptionButton", ob)
	var ob_hi := Style.flat(Style.C_BTN_FILL_HI, Style.C_BORDER, 1, Style.SP_3, Style.SP_2)
	t.set_stylebox("hover", "OptionButton", ob_hi)
	t.set_stylebox("pressed", "OptionButton", ob_hi)
	var ob_focus := ob.duplicate() as StyleBoxFlat
	ob_focus.border_color = Style.C_ACCENT
	t.set_stylebox("focus", "OptionButton", ob_focus)
	t.set_stylebox("disabled", "OptionButton",
			Style.flat(Style.C_BTN_FILL_DN, Style.C_BORDER_DIM, 1, Style.SP_3, Style.SP_2))
	t.set_font_size("font_size", "OptionButton", Style.T_SMALL)
	t.set_color("font_color", "OptionButton", Style.C_TEXT)
	t.set_color("font_hover_color", "OptionButton", Style.C_ACCENT)
	t.set_color("font_pressed_color", "OptionButton", Style.C_ACCENT)
	t.set_color("font_focus_color", "OptionButton", Style.C_TEXT)
	t.set_color("font_disabled_color", "OptionButton", Style.C_TEXT_DIM)

	t.set_stylebox("panel", "PopupMenu",
			Style.flat(Style.C_SURFACE, Style.C_BORDER, 1, Style.SP_2, Style.SP_2))
	t.set_stylebox("hover", "PopupMenu",
			Style.flat(Style.C_BTN_FILL_HI, Color.TRANSPARENT, 0, Style.SP_3, Style.SP_2))
	t.set_font_size("font_size", "PopupMenu", Style.T_SMALL)
	t.set_color("font_color", "PopupMenu", Style.C_TEXT)
	t.set_color("font_hover_color", "PopupMenu", Style.C_ACCENT)
	t.set_color("font_disabled_color", "PopupMenu", Style.C_TEXT_DIM)
	t.set_color("font_separator_color", "PopupMenu", Style.C_TEXT_DIM)

	# 菜单栏按钮单独定义状态样式，默认透明，悬停时显示底色。
	t.set_stylebox("normal", "MenuButton",
			Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_stylebox("hover", "MenuButton",
			Style.flat(Style.C_BTN_FILL_HI, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_stylebox("pressed", "MenuButton",
			Style.flat(Style.C_BTN_FILL_DN, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1))
	t.set_stylebox("focus", "MenuButton",
			Style.flat(Style.C_TRANSPARENT, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1))
	t.set_stylebox("disabled", "MenuButton",
			Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_font_size("font_size", "MenuButton", Style.T_SMALL)
	t.set_color("font_color", "MenuButton", Style.C_TEXT)
	t.set_color("font_hover_color", "MenuButton", Style.C_TEXT)
	t.set_color("font_focus_color", "MenuButton", Style.C_TEXT)

	t.set_stylebox("panel", "TooltipPanel",
			Style.flat(Style.C_BG, Style.C_BORDER, 1, Style.SP_2, Style.SP_1))
	t.set_font_size("font_size", "TooltipLabel", Style.T_LABEL)
	t.set_color("font_color", "TooltipLabel", Style.C_TEXT)

	# 选项卡使用透明底，选中状态用 2 像素强调色底线标记。
	t.set_font_size("font_size", "TabBar", Style.T_LABEL)
	t.set_color("font_selected_color", "TabBar", Style.C_TEXT)
	t.set_color("font_unselected_color", "TabBar", Style.C_TEXT_DIM)
	t.set_color("font_hovered_color", "TabBar", Style.C_TEXT)
	t.set_color("font_disabled_color", "TabBar", Style.C_TEXT_MUTE)
	var tab_on := Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_3, Style.SP_2)
	tab_on.border_width_bottom = 2
	tab_on.border_color = Style.C_ACCENT
	var tab_off := Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_3, Style.SP_2)
	tab_off.border_width_bottom = 2
	tab_off.border_color = Style.C_TRANSPARENT
	t.set_stylebox("tab_selected", "TabBar", tab_on)
	t.set_stylebox("tab_unselected", "TabBar", tab_off)
	t.set_stylebox("tab_hovered", "TabBar", tab_off)
	t.set_stylebox("tab_hovered_pressed", "TabBar", tab_off)
	t.set_stylebox("panel", "TabContainer", Style.flat(Style.C_SURFACE, Color.TRANSPARENT, 0, 0, 0))
