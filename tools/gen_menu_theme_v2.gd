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
	_kit_variants(theme)
	_flat_editor_variants(theme)
	_other_controls(theme)
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


# Field = Label(表单标签)与 LineEdit(输入框)共用的**唯一** variation(名字全局唯一,见文件头)。
# Label 只吃 font_size;LineEdit 吃输入框样式 + font_size。颜色不写:两者各自从自己的基类继承
# (Label=C_TEXT / LineEdit=C_TEXT);写在这里会把另一边的颜色一起改掉。
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
	# 危险操作:描边/文字用 C_DANGER;hover/pressed 时文字转 C_TEXT(在亮填充上保持可读)。
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

	# ── 内嵌面板与列表行──
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


# ── Kit:契约要求 CheckButton / CheckBox、ScrollBar、TabContainer / HSplit / VSplit、各 Dialog 共用
#    同名 variation。Godot 的 variation 名**全局唯一**(一个名字只能绑一个 base),所以这里只用一条
#    `Kit`(base=Control)承载这些控件各自的主题项:每个控件只会去查它自己用到的 slot 名,互不冲突;
#    仅有 "panel" 被 TabContainer(内容底板)与 AcceptDialog(窗口面板)共用 —— 两者都用同一种面板块,
#    正是"统一皮肤"想要的。Dialog 是 Window 派生(不是 Control),但 variation 链会先走 Kit 再落到
#    AcceptDialog/Window 的原生类型,所以照样命中。
func _kit_variants(t: Theme) -> void:
	t.set_type_variation("Kit", "Control")

	# 开关 / 勾选框:文字与自绘胶囊图标(与旧 CheckButton 基础类型同一套素材)。
	t.set_font_size("font_size", "Kit", Style.T_H2)
	t.set_color("font_color", "Kit", Style.C_TEXT)
	t.set_color("font_hover_color", "Kit", Style.C_ACCENT)
	t.set_color("font_pressed_color", "Kit", Style.C_ACCENT)
	t.set_color("font_focus_color", "Kit", Style.C_TEXT)
	t.set_icon("unchecked", "Kit", SWITCH_OFF)
	t.set_icon("checked", "Kit", SWITCH_ON)

	# 滚动条:轨道暗、滑块按状态上色。
	var sb_pad := Style.SP_1
	t.set_stylebox("scroll", "Kit", Style.flat(Style.C_BTN_FILL_DN, Color.TRANSPARENT, 0, sb_pad, sb_pad))
	t.set_stylebox("scroll_focus", "Kit", Style.flat(Style.C_BTN_FILL_DN, Color.TRANSPARENT, 0, sb_pad, sb_pad))
	t.set_stylebox("grabber", "Kit", Style.flat(Style.C_BORDER_DIM, Color.TRANSPARENT, 0, sb_pad, sb_pad))
	t.set_stylebox("grabber_highlight", "Kit", Style.flat(Style.C_ACCENT, Color.TRANSPARENT, 0, sb_pad, sb_pad))
	t.set_stylebox("grabber_pressed", "Kit", Style.flat(Style.C_ACCENT, Color.TRANSPARENT, 0, sb_pad, sb_pad))

	# TabContainer:内容板 + 标签条 + 五种 tab 态 + 文字色/间距(它会把这些同名项覆盖给内部 TabBar)。
	t.set_stylebox("panel", "Kit",
			Style.flat(Style.C_SURFACE, Style.C_BORDER, Style.BORDER_W, Style.SP_4, Style.SP_4))
	t.set_stylebox("tabbar_background", "Kit",
			Style.flat(Style.C_HEADER, Color.TRANSPARENT, 0, Style.SP_1, Style.SP_1))
	t.set_stylebox("tab_selected", "Kit",
			Style.flat(Style.C_SURFACE, Style.C_ACCENT, Style.BORDER_W, Style.SP_4, Style.SP_2))
	t.set_stylebox("tab_hovered", "Kit",
			Style.flat(Style.C_BTN_FILL_HI, Style.C_BORDER_DIM, Style.BORDER_W_DIM, Style.SP_4, Style.SP_2))
	t.set_stylebox("tab_unselected", "Kit",
			Style.flat(Style.C_HEADER, Style.C_BORDER_DIM, Style.BORDER_W_DIM, Style.SP_4, Style.SP_2))
	t.set_stylebox("tab_disabled", "Kit",
			Style.flat(Style.C_BTN_FILL_DN, Style.C_BORDER_DIM, Style.BORDER_W_DIM, Style.SP_4, Style.SP_2))
	t.set_stylebox("tab_focus", "Kit",
			Style.flat(Style.C_TRANSPARENT, Style.C_ACCENT, Style.BORDER_W_DIM, Style.SP_4, Style.SP_2))
	t.set_color("font_selected_color", "Kit", Style.C_TEXT)
	t.set_color("font_unselected_color", "Kit", Style.C_TEXT_DIM)
	t.set_color("font_hovered_color", "Kit", Style.C_ACCENT)
	t.set_color("font_disabled_color", "Kit", Style.C_TEXT_MUTE)
	t.set_color("drop_mark_color", "Kit", Style.C_ACCENT)
	t.set_constant("side_margin", "Kit", Style.SP_2)
	t.set_constant("tab_separation", "Kit", 0)
	t.set_constant("icon_separation", "Kit", Style.SP_1)
	t.set_constant("outline_size", "Kit", 0)

	# HSplitContainer / VSplitContainer(主题项定义在 SplitContainer 基类上)。
	t.set_stylebox("split_bar_background", "Kit",
			Style.flat(Style.C_BTN_FILL_DN, Style.C_BORDER_DIM, Style.BORDER_W_DIM, Style.SP_1, Style.SP_1))
	t.set_constant("separation", "Kit", Style.SP_2)
	t.set_constant("minimum_grab_thickness", "Kit", Style.SP_3)
	t.set_constant("autohide", "Kit", 0)

	# AcceptDialog / ConfirmationDialog / FileDialog:窗口面板 + 标题行 + 按钮区间距。
	# (内嵌子窗口走 Window 的 embedded_border;独立窗口走 title_*。)
	t.set_stylebox("embedded_border", "Kit",
			Style.flat(Style.C_SURFACE, Style.C_BORDER, Style.BORDER_W, Style.SP_1, Style.SP_1))
	t.set_stylebox("embedded_unfocused_border", "Kit",
			Style.flat(Style.C_SURFACE, Style.C_BORDER_DIM, Style.BORDER_W_DIM, Style.SP_1, Style.SP_1))
	t.set_color("title_color", "Kit", Style.C_TEXT)
	t.set_font_size("title_font_size", "Kit", Style.T_H2)
	t.set_constant("title_height", "Kit", Style.SP_7)
	t.set_constant("close_h_offset", "Kit", Style.SP_2)
	t.set_constant("close_v_offset", "Kit", Style.SP_2)
	t.set_constant("buttons_separation", "Kit", Style.SP_2)
	t.set_constant("buttons_min_width", "Kit", Style.SP_9)
	t.set_constant("buttons_min_height", "Kit", Style.SP_7)


func _flat_editor_variants(t: Theme) -> void:
	# 编辑器"去盒子化"档(2026-11-10):工具栏命令、工具列、图层行都改成**透明底 + hover 才出底**;
	# 边框只留给输入/面板/焦点,强调色只给"当前工具/当前图层/焦点"——避免每个控件都是同权重的实心盒子。
	for name in ["FlatButton", "ToolButton"]:
		t.set_type_variation(name, "Button")
		t.set_font_size("font_size", name, Style.T_LABEL)
		t.set_stylebox("normal", name, Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
		t.set_stylebox("hover", name, Style.flat(Style.C_BTN_FILL_HI, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
		t.set_stylebox("pressed", name, Style.flat(Style.C_BTN_FILL_DN, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1))
		t.set_stylebox("focus", name, Style.flat(Style.C_TRANSPARENT, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1))
		t.set_stylebox("disabled", name, Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
		t.set_color("font_color", name, Style.C_TEXT_DIM)
		t.set_color("font_hover_color", name, Style.C_TEXT)
		t.set_color("font_focus_color", name, Style.C_TEXT)
		t.set_color("font_pressed_color", name, Style.C_ACCENT)
		t.set_color("font_disabled_color", name, Style.C_TEXT_MUTE)

	# 当前工具/当前图层:左缘 2px 强调条 + 轻底;不靠整块亮色抢画布。
	var active_left := Style.flat(Style.C_ROW, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1)
	active_left.border_width_left = 2
	active_left.border_color = Style.C_ACCENT
	for name in ["ToolActive", "LayerActive"]:
		t.set_type_variation(name, "Button")
		t.set_font_size("font_size", name, Style.T_LABEL)
		t.set_stylebox("normal", name, active_left)
		t.set_stylebox("hover", name, active_left)
		t.set_stylebox("pressed", name, active_left)
		t.set_stylebox("focus", name, active_left)
		t.set_stylebox("disabled", name, active_left)
		t.set_color("font_color", name, Style.C_ACCENT)
		t.set_color("font_hover_color", name, Style.C_ACCENT)
		t.set_color("font_focus_color", name, Style.C_ACCENT)

	# 普通图层行:只有 hover 才出底,和工具列的 FlatButton 同族。
	t.set_type_variation("LayerRow", "Button")
	t.set_font_size("font_size", "LayerRow", Style.T_LABEL)
	t.set_stylebox("normal", "LayerRow", Style.flat(Style.C_TRANSPARENT, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_stylebox("hover", "LayerRow", Style.flat(Style.C_ROW, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_stylebox("pressed", "LayerRow", Style.flat(Style.C_ROW, Style.C_ACCENT, 1, Style.SP_2, Style.SP_1))
	t.set_stylebox("focus", "LayerRow", Style.flat(Style.C_ROW, Color.TRANSPARENT, 0, Style.SP_2, Style.SP_1))
	t.set_color("font_color", "LayerRow", Style.C_TEXT_DIM)
	t.set_color("font_hover_color", "LayerRow", Style.C_TEXT)


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
	t.set_font_size("font_size", "LineEdit", Style.T_LABEL)
	t.set_color("font_color", "LineEdit", Style.C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Style.C_TEXT_DIM)
	t.set_color("caret_color", "LineEdit", Style.C_ACCENT)

	t.set_font_size("font_size", "CheckButton", Style.T_H2)
	t.set_color("font_color", "CheckButton", Style.C_TEXT)
	t.set_color("font_hover_color", "CheckButton", Style.C_ACCENT)
	t.set_color("font_pressed_color", "CheckButton", Style.C_ACCENT)
	t.set_color("font_focus_color", "CheckButton", Style.C_TEXT)
	t.set_icon("unchecked", "CheckButton", SWITCH_OFF)
	t.set_icon("checked", "CheckButton", SWITCH_ON)

	var track := StyleBoxFlat.new()
	track.bg_color = Style.C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", _row_box(Style.C_ACCENT, Style.C_ACCENT))
	t.set_stylebox("grabber_area_highlight", "HSlider",
			_row_box(Style.C_ACCENT, Style.C_ACCENT))


	# ── 下拉 / 弹出菜单 / 提示 / Tab(2026-11-10)───────────────────────────────
	# 之前只有 Button/LineEdit/CheckButton 有皮肤,OptionButton/PopupMenu/菜单下拉/工具提示/Tab
	# 全部回落到 Godot 默认主题(Noto Sans 字体)⇒ 编辑器与设置页的"字体不统一"就从这里来。
	# 这里只加"基础类型"条目(不是 variation):字体族仍走 Theme.default_font(像素字体链),
	# 字号用 T_LABEL=16,和紧凑工具栏同一档。
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
	t.set_font_size("font_size", "OptionButton", Style.T_LABEL)
	t.set_color("font_color", "OptionButton", Style.C_TEXT)
	t.set_color("font_hover_color", "OptionButton", Style.C_ACCENT)
	t.set_color("font_pressed_color", "OptionButton", Style.C_ACCENT)
	t.set_color("font_focus_color", "OptionButton", Style.C_TEXT)
	t.set_color("font_disabled_color", "OptionButton", Style.C_TEXT_DIM)

	t.set_stylebox("panel", "PopupMenu",
			Style.flat(Style.C_SURFACE, Style.C_BORDER, 1, Style.SP_2, Style.SP_2))
	t.set_stylebox("hover", "PopupMenu",
			Style.flat(Style.C_BTN_FILL_HI, Color.TRANSPARENT, 0, Style.SP_3, Style.SP_2))
	t.set_font_size("font_size", "PopupMenu", Style.T_LABEL)
	t.set_color("font_color", "PopupMenu", Style.C_TEXT)
	t.set_color("font_hover_color", "PopupMenu", Style.C_ACCENT)
	t.set_color("font_disabled_color", "PopupMenu", Style.C_TEXT_DIM)
	t.set_color("font_separator_color", "PopupMenu", Style.C_TEXT_DIM)

	# 为 MenuButton 单独定义主题项，避免 CheckButton 继承普通按钮样式。
	# 菜单栏文字按钮:透明底,hover 才出轻底;不再是"实心盒子排在标题旁边"。
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
	t.set_font_size("font_size", "MenuButton", Style.T_LABEL)
	t.set_color("font_color", "MenuButton", Style.C_TEXT)
	t.set_color("font_hover_color", "MenuButton", Style.C_TEXT)
	t.set_color("font_focus_color", "MenuButton", Style.C_TEXT)

	t.set_stylebox("panel", "TooltipPanel",
			Style.flat(Style.C_BG, Style.C_BORDER, 1, Style.SP_2, Style.SP_1))
	t.set_font_size("font_size", "TooltipLabel", Style.T_LABEL)
	t.set_color("font_color", "TooltipLabel", Style.C_TEXT)

	# TabBar / TabContainer:下划线式(2026-11-10):透明 tab + 选中 2px 青色底线,
	# 不再给每个 tab 套四边框盒子;Tab 区与右栏同底,视觉上像"分段标题"而不是按钮。
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
