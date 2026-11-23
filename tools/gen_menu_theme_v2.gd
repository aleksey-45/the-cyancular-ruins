extends SceneTree

# 菜单 Theme(Theme 2.0)生成器 —— 生成物:`res://ui/theme/menu_theme_v2.tres`。
#
# ★ 本 Theme **刻意不设基础类型 `Button` 的皮肤**:`CheckButton` / `CheckBox` 都继承 `Button`
#   (`CheckButton → Button → BaseButton`),给基础类型 Button 挂皮会让开关沿类链穿上按钮皮
#   (而 CheckButton 的开关外观是自绘胶囊图标,见 UiDesign.switch_icons)。按钮一律走 **type variation**。
# ★ 颜色只从 `UiDesign` 的 `C_*` 取;字号/间距/圆角只从 `SP_* / T_* / R_* / BORDER_*` token 取 ——
#   本文件里不写颜色字面量,也不写魔法数(旧 variation 的既有数值原样保留,只为不改动未迁移页面的像素)。
# ★ Theme 的 variation 名是**全局唯一**的(名字 → base 只能一条,`set_type_variation` 是覆盖语义、不报错),
#   所以契约里跨控件同名的 `Field` / `Kit` 各只建一条,用 base=Control 承载多个控件的主题项。
# ★ 两趟:Theme 要引用两个开关 PNG,而 res:// 下的 PNG 必须先 `--import` 才 load() 得到(-s 不触发导入)
#   ⇒ 第一趟写下 PNG 并以 exit 1 要求「先 --import 再重跑」,第二趟才真的建 Theme。
# ★ 刻意不做「缺图标也照样存一份」:那会留下一份看着成功、其实少两个图标的 .tres,而「开关画成默认主题
#   的小灰点」这种缺失不会报错。

const OUT_THEME := "res://ui/theme/menu_theme_v2.tres"
const OUT_SWITCH_OFF := "res://ui/theme/switch_off.png"
const OUT_SWITCH_ON := "res://ui/theme/switch_on.png"
const FONT_RES := "res://assets/fonts/menu_font.tres"

var _fails: Array[String] = []


func _initialize() -> void:
	var F: GDScript = load("res://ui/design_v2/ui_design.gd")
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

	if not _switch_icons_ready():
		_export_switch_icons(F)
		print("GEN THEME: 图标已导出 → 请先跑 `--import`,再重跑本工具")
		quit(1)
		return

	var t := Theme.new()
	t.default_font = font

	_label_variants(t, C)
	_field_variants(t, C)
	_button_variants(t, F, C)
	_panel_variants(t, F, C)
	_kit_variants(t, C)
	_flat_editor_variants(t, C)
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
		_fails.append("调色板里没有 `%s`(UiDesign 改名了?本工具要跟着改)" % name)
		return Color.MAGENTA
	return C[name] as Color


# 取数值 token(SP_* / T_* / R_* / BORDER_*);缺失同样记红,不静默填 0。
func _n(C: Dictionary, name: String) -> int:
	if not C.has(name):
		_fails.append("token 里没有 `%s`(UiDesign 改名了?本工具要跟着改)" % name)
		return 0
	return int(C[name])


# 通用 StyleBoxFlat:颜色/宽度/间距一律来自 token,不写颜色字面量。
func _flat(C: Dictionary, bg: String, border: String, border_w: int,
		pad_h: int, pad_v: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _c(C, bg)
	if border_w > 0 and border != "":
		sb.border_color = _c(C, border)
		sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = float(pad_h)
	sb.content_margin_right = float(pad_h)
	sb.content_margin_top = float(pad_v)
	sb.content_margin_bottom = float(pad_v)
	return sb


func _label_variants(t: Theme, C: Dictionary) -> void:
	t.set_color("font_color", "Label", _c(C, "C_TEXT"))
	t.set_font_size("font_size", "Label", _n(C, "T_H2"))
	t.set_type_variation("H1", "Label")
	t.set_font_size("font_size", "H1", _n(C, "T_H1"))
	t.set_color("font_color", "H1", _c(C, "C_TEXT"))
	t.set_type_variation("H2", "Label")
	t.set_font_size("font_size", "H2", _n(C, "T_H2"))
	t.set_color("font_color", "H2", _c(C, "C_TEXT"))
	t.set_type_variation("Body", "Label")
	t.set_font_size("font_size", "Body", _n(C, "T_H2"))
	t.set_color("font_color", "Body", _c(C, "C_TEXT"))
	t.set_type_variation("Small", "Label")
	t.set_font_size("font_size", "Small", _n(C, "T_LABEL"))
	t.set_color("font_color", "Small", _c(C, "C_TEXT"))
	t.set_type_variation("HeaderTitle", "Label")
	t.set_font_size("font_size", "HeaderTitle", _n(C, "T_H2"))
	t.set_color("font_color", "HeaderTitle", _c(C, "C_GOLD"))
	t.set_type_variation("SmallDim", "Label")
	t.set_font_size("font_size", "SmallDim", _n(C, "T_LABEL"))
	t.set_color("font_color", "SmallDim", _c(C, "C_TEXT_MUTE"))
	t.set_type_variation("Dim", "Label")
	t.set_font_size("font_size", "Dim", _n(C, "T_H2"))
	t.set_color("font_color", "Dim", _c(C, "C_TEXT_DIM"))


# Field = Label(表单标签)与 LineEdit(输入框)共用的**唯一** variation(名字全局唯一,见文件头)。
# Label 只吃 font_size;LineEdit 吃输入框样式 + font_size。颜色不写:两者各自从自己的基类继承
# (Label=C_TEXT / LineEdit=C_TEXT);写在这里会把另一边的颜色一起改掉。
func _field_variants(t: Theme, C: Dictionary) -> void:
	t.set_type_variation("Field", "Control")
	t.set_font_size("font_size", "Field", _n(C, "T_LABEL"))
	t.set_color("caret_color", "Field", _c(C, "C_ACCENT"))
	t.set_color("font_placeholder_color", "Field", _c(C, "C_TEXT_DIM"))
	t.set_stylebox("normal", "Field",
			_flat(C, "C_FIELD", "C_BORDER_DIM", _n(C, "BORDER_W"), _n(C, "SP_3"), 0))
	t.set_stylebox("focus", "Field",
			_flat(C, "C_FIELD", "C_ACCENT", _n(C, "BORDER_W"), _n(C, "SP_3"), 0))


func _button_variants(t: Theme, F: GDScript, C: Dictionary) -> void:
	# ── Theme 2.0 的四档(契约 §3)──
	_menu_btn(t, F, C, "Primary", _c(C, "C_EDGE"), _c(C, "C_TEXT"))
	_menu_btn(t, F, C, "Quiet", _c(C, "C_BORDER_DIM"), _c(C, "C_TEXT_DIM"))
	_danger_btn(t, F, C)
	_icon_btn(t, C)
	# 紧凑档(2026-11-10):编辑器的高密度工具栏/图层行/工具列用,16 号字 + 8/4 内边距,
	# 比 _btn_box 的 40/20 内容边距矮 ~24px;只影响显式用 "compact" 的控件。
	_compact_btn(t, C)
	# ── 旧 variation(未迁移的 .tscn 还在用;数值保持原样)──
	_menu_btn(t, F, C, "BtnPrimary", _c(C, "C_EDGE"), _c(C, "C_TEXT"))
	_menu_btn(t, F, C, "BtnQuiet", _c(C, "C_BORDER_DIM"), _c(C, "C_TEXT_DIM"))
	_menu_btn(t, F, C, "BtnGold", _c(C, "C_GOLD"), _c(C, "C_GOLD"))
	_menu_btn(t, F, C, "BtnAccent", _c(C, "C_ACCENT"), _c(C, "C_TEXT"))
	_legacy_btn(t, F, C, "BtnLegacy", false)
	_legacy_btn(t, F, C, "BtnLegacyQuiet", true)


func _menu_btn(t: Theme, F: GDScript, C: Dictionary, name: String, edge: Color, fg: Color) -> void:
	t.set_type_variation(name, "Button")
	t.set_font_size("font_size", name, _n(C, "T_H2"))
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


func _compact_btn(t: Theme, C: Dictionary) -> void:
	t.set_type_variation("BtnCompact", "Button")
	t.set_font_size("font_size", "BtnCompact", _n(C, "T_LABEL"))
	t.set_stylebox("normal", "BtnCompact",
			_flat(C, "C_HEADER", "C_BORDER_DIM", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("hover", "BtnCompact",
			_flat(C, "C_BTN_FILL_HI", "C_BORDER", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("pressed", "BtnCompact",
			_flat(C, "C_BTN_FILL_DN", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("focus", "BtnCompact",
			_flat(C, "C_HEADER", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("disabled", "BtnCompact",
			_flat(C, "C_HEADER", "C_BORDER_DIM", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_color("font_color", "BtnCompact", _c(C, "C_TEXT_DIM"))
	t.set_color("font_hover_color", "BtnCompact", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "BtnCompact", _c(C, "C_TEXT"))
	t.set_color("font_pressed_color", "BtnCompact", _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", "BtnCompact", _c(C, "C_TEXT_MUTE"))


func _danger_btn(t: Theme, F: GDScript, C: Dictionary) -> void:
	# 危险操作:描边/文字用 C_DANGER;hover/pressed 时文字转 C_TEXT(在亮填充上保持可读)。
	t.set_type_variation("Danger", "Button")
	t.set_font_size("font_size", "Danger", _n(C, "T_H2"))
	t.set_stylebox("normal", "Danger", F.call("_btn_box", _c(C, "C_HEADER"), _c(C, "C_DANGER")))
	t.set_stylebox("hover", "Danger", F.call("_btn_box", _c(C, "C_BTN_FILL_HI"), _c(C, "C_DANGER")))
	t.set_stylebox("pressed", "Danger", F.call("_btn_box", _c(C, "C_BTN_FILL_DN"), _c(C, "C_DANGER")))
	t.set_stylebox("focus", "Danger", F.call("_btn_box", _c(C, "C_HEADER"), _c(C, "C_DANGER")))
	t.set_stylebox("disabled", "Danger", F.call("_btn_box", _c(C, "C_HEADER"), _c(C, "C_BORDER_DIM")))
	t.set_color("font_color", "Danger", _c(C, "C_DANGER"))
	t.set_color("font_hover_color", "Danger", _c(C, "C_TEXT"))
	t.set_color("font_focus_color", "Danger", _c(C, "C_DANGER"))
	t.set_color("font_pressed_color", "Danger", _c(C, "C_TEXT"))
	t.set_color("font_disabled_color", "Danger", _c(C, "C_TEXT_MUTE"))


func _icon_btn(t: Theme, C: Dictionary) -> void:
	# 图标按钮:常态透明无框、hover 才亮;内容边距 SP_2(尺寸由图标 + 内容驱动的调用方给)。
	var pad := _n(C, "SP_2")
	t.set_type_variation("Icon", "Button")
	t.set_font_size("font_size", "Icon", _n(C, "T_H2"))
	t.set_stylebox("normal", "Icon", _flat(C, "C_TRANSPARENT", "", 0, pad, pad))
	t.set_stylebox("hover", "Icon", _flat(C, "C_BTN_FILL_HI", "C_ACCENT", _n(C, "BORDER_W"), pad, pad))
	t.set_stylebox("pressed", "Icon", _flat(C, "C_BTN_FILL_DN", "C_ACCENT", _n(C, "BORDER_W"), pad, pad))
	t.set_stylebox("focus", "Icon", _flat(C, "C_TRANSPARENT", "C_ACCENT", _n(C, "BORDER_W_DIM"), pad, pad))
	t.set_stylebox("disabled", "Icon", _flat(C, "C_TRANSPARENT", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), pad, pad))
	t.set_color("font_color", "Icon", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "Icon", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "Icon", _c(C, "C_TEXT"))
	t.set_color("font_pressed_color", "Icon", _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", "Icon", _c(C, "C_TEXT_MUTE"))


func _legacy_btn(t: Theme, F: GDScript, C: Dictionary, name: String, dim: bool) -> void:
	t.set_type_variation(name, "Button")
	t.set_font_size("font_size", name, _n(C, "T_H2"))
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
	# ── Theme 2.0 的三档(契约 §3)──
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card",
			_flat(C, "C_SURFACE", "C_BORDER", _n(C, "BORDER_W"), _n(C, "SP_5"), _n(C, "SP_4")))
	t.set_type_variation("Plain", "PanelContainer")
	t.set_stylebox("panel", "Plain",
			_flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_4"), _n(C, "SP_4")))
	t.set_type_variation("Bar", "PanelContainer")
	t.set_stylebox("panel", "Bar",
			_flat(C, "C_HEADER", "C_BORDER", _n(C, "BORDER_W_DIM"), _n(C, "SP_4"), _n(C, "SP_2")))

	# ── 旧 variation(未迁移的 .tscn 还在用;数值保持原样)──
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
	t.set_font_size("font_size", "RowButton", _n(C, "T_H2"))
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


# ── Kit:契约要求 CheckButton / CheckBox、ScrollBar、TabContainer / HSplit / VSplit、各 Dialog 共用
#    同名 variation。Godot 的 variation 名**全局唯一**(一个名字只能绑一个 base),所以这里只用一条
#    `Kit`(base=Control)承载这些控件各自的主题项:每个控件只会去查它自己用到的 slot 名,互不冲突;
#    仅有 "panel" 被 TabContainer(内容底板)与 AcceptDialog(窗口面板)共用 —— 两者都用同一种面板块,
#    正是"统一皮肤"想要的。Dialog 是 Window 派生(不是 Control),但 variation 链会先走 Kit 再落到
#    AcceptDialog/Window 的原生类型,所以照样命中。
func _kit_variants(t: Theme, C: Dictionary) -> void:
	t.set_type_variation("Kit", "Control")

	# 开关 / 勾选框:文字与自绘胶囊图标(与旧 CheckButton 基础类型同一套素材)。
	t.set_font_size("font_size", "Kit", _n(C, "T_H2"))
	t.set_color("font_color", "Kit", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "Kit", _c(C, "C_ACCENT"))
	t.set_color("font_pressed_color", "Kit", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "Kit", _c(C, "C_TEXT"))
	var off: Texture2D = load(OUT_SWITCH_OFF)
	var on: Texture2D = load(OUT_SWITCH_ON)
	if off == null or on == null:
		_fails.append("读不到开关图标 %s / %s —— 先跑本工具导出 PNG,再 --import,然后重跑"
				% [OUT_SWITCH_OFF, OUT_SWITCH_ON])
	else:
		t.set_icon("unchecked", "Kit", off)
		t.set_icon("checked", "Kit", on)

	# 滚动条:轨道暗、滑块按状态上色。
	var sb_pad := _n(C, "SP_1")
	t.set_stylebox("scroll", "Kit", _flat(C, "C_BTN_FILL_DN", "", 0, sb_pad, sb_pad))
	t.set_stylebox("scroll_focus", "Kit", _flat(C, "C_BTN_FILL_DN", "", 0, sb_pad, sb_pad))
	t.set_stylebox("grabber", "Kit", _flat(C, "C_BORDER_DIM", "", 0, sb_pad, sb_pad))
	t.set_stylebox("grabber_highlight", "Kit", _flat(C, "C_ACCENT", "", 0, sb_pad, sb_pad))
	t.set_stylebox("grabber_pressed", "Kit", _flat(C, "C_ACCENT", "", 0, sb_pad, sb_pad))

	# TabContainer:内容板 + 标签条 + 五种 tab 态 + 文字色/间距(它会把这些同名项覆盖给内部 TabBar)。
	t.set_stylebox("panel", "Kit",
			_flat(C, "C_SURFACE", "C_BORDER", _n(C, "BORDER_W"), _n(C, "SP_4"), _n(C, "SP_4")))
	t.set_stylebox("tabbar_background", "Kit",
			_flat(C, "C_HEADER", "", 0, _n(C, "SP_1"), _n(C, "SP_1")))
	t.set_stylebox("tab_selected", "Kit",
			_flat(C, "C_SURFACE", "C_ACCENT", _n(C, "BORDER_W"), _n(C, "SP_4"), _n(C, "SP_2")))
	t.set_stylebox("tab_hovered", "Kit",
			_flat(C, "C_BTN_FILL_HI", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), _n(C, "SP_4"), _n(C, "SP_2")))
	t.set_stylebox("tab_unselected", "Kit",
			_flat(C, "C_HEADER", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), _n(C, "SP_4"), _n(C, "SP_2")))
	t.set_stylebox("tab_disabled", "Kit",
			_flat(C, "C_BTN_FILL_DN", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), _n(C, "SP_4"), _n(C, "SP_2")))
	t.set_stylebox("tab_focus", "Kit",
			_flat(C, "C_TRANSPARENT", "C_ACCENT", _n(C, "BORDER_W_DIM"), _n(C, "SP_4"), _n(C, "SP_2")))
	t.set_color("font_selected_color", "Kit", _c(C, "C_TEXT"))
	t.set_color("font_unselected_color", "Kit", _c(C, "C_TEXT_DIM"))
	t.set_color("font_hovered_color", "Kit", _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", "Kit", _c(C, "C_TEXT_MUTE"))
	t.set_color("drop_mark_color", "Kit", _c(C, "C_ACCENT"))
	t.set_constant("side_margin", "Kit", _n(C, "SP_2"))
	t.set_constant("tab_separation", "Kit", 0)
	t.set_constant("icon_separation", "Kit", _n(C, "SP_1"))
	t.set_constant("outline_size", "Kit", 0)

	# HSplitContainer / VSplitContainer(主题项定义在 SplitContainer 基类上)。
	t.set_stylebox("split_bar_background", "Kit",
			_flat(C, "C_BTN_FILL_DN", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), _n(C, "SP_1"), _n(C, "SP_1")))
	t.set_constant("separation", "Kit", _n(C, "SP_2"))
	t.set_constant("minimum_grab_thickness", "Kit", _n(C, "SP_3"))
	t.set_constant("autohide", "Kit", 0)

	# AcceptDialog / ConfirmationDialog / FileDialog:窗口面板 + 标题行 + 按钮区间距。
	# (内嵌子窗口走 Window 的 embedded_border;独立窗口走 title_*。)
	t.set_stylebox("embedded_border", "Kit",
			_flat(C, "C_SURFACE", "C_BORDER", _n(C, "BORDER_W"), _n(C, "SP_1"), _n(C, "SP_1")))
	t.set_stylebox("embedded_unfocused_border", "Kit",
			_flat(C, "C_SURFACE", "C_BORDER_DIM", _n(C, "BORDER_W_DIM"), _n(C, "SP_1"), _n(C, "SP_1")))
	t.set_color("title_color", "Kit", _c(C, "C_TEXT"))
	t.set_font_size("title_font_size", "Kit", _n(C, "T_H2"))
	t.set_constant("title_height", "Kit", _n(C, "SP_7"))
	t.set_constant("close_h_offset", "Kit", _n(C, "SP_2"))
	t.set_constant("close_v_offset", "Kit", _n(C, "SP_2"))
	t.set_constant("buttons_separation", "Kit", _n(C, "SP_2"))
	t.set_constant("buttons_min_width", "Kit", _n(C, "SP_9"))
	t.set_constant("buttons_min_height", "Kit", _n(C, "SP_7"))


func _flat_editor_variants(t: Theme, C: Dictionary) -> void:
	# 编辑器"去盒子化"档(2026-11-10):工具栏命令、工具列、图层行都改成**透明底 + hover 才出底**;
	# 边框只留给输入/面板/焦点,强调色只给"当前工具/当前图层/焦点"——避免每个控件都是同权重的实心盒子。
	for name in ["FlatButton", "ToolButton"]:
		t.set_type_variation(name, "Button")
		t.set_font_size("font_size", name, _n(C, "T_LABEL"))
		t.set_stylebox("normal", name, _flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
		t.set_stylebox("hover", name, _flat(C, "C_BTN_FILL_HI", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
		t.set_stylebox("pressed", name, _flat(C, "C_BTN_FILL_DN", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
		t.set_stylebox("focus", name, _flat(C, "C_TRANSPARENT", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
		t.set_stylebox("disabled", name, _flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
		t.set_color("font_color", name, _c(C, "C_TEXT_DIM"))
		t.set_color("font_hover_color", name, _c(C, "C_TEXT"))
		t.set_color("font_focus_color", name, _c(C, "C_TEXT"))
		t.set_color("font_pressed_color", name, _c(C, "C_ACCENT"))
		t.set_color("font_disabled_color", name, _c(C, "C_TEXT_MUTE"))

	# 当前工具/当前图层:左缘 2px 强调条 + 轻底;不靠整块亮色抢画布。
	var active_left := _flat(C, "C_ROW", "", 0, _n(C, "SP_2"), _n(C, "SP_1"))
	active_left.border_width_left = 2
	active_left.border_color = _c(C, "C_ACCENT")
	for name in ["ToolActive", "LayerActive"]:
		t.set_type_variation(name, "Button")
		t.set_font_size("font_size", name, _n(C, "T_LABEL"))
		t.set_stylebox("normal", name, active_left)
		t.set_stylebox("hover", name, active_left)
		t.set_stylebox("pressed", name, active_left)
		t.set_stylebox("focus", name, active_left)
		t.set_stylebox("disabled", name, active_left)
		t.set_color("font_color", name, _c(C, "C_ACCENT"))
		t.set_color("font_hover_color", name, _c(C, "C_ACCENT"))
		t.set_color("font_focus_color", name, _c(C, "C_ACCENT"))

	# 普通图层行:只有 hover 才出底,和工具列的 FlatButton 同族。
	t.set_type_variation("LayerRow", "Button")
	t.set_font_size("font_size", "LayerRow", _n(C, "T_LABEL"))
	t.set_stylebox("normal", "LayerRow", _flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("hover", "LayerRow", _flat(C, "C_ROW", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("pressed", "LayerRow", _flat(C, "C_ROW", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("focus", "LayerRow", _flat(C, "C_ROW", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_color("font_color", "LayerRow", _c(C, "C_TEXT_DIM"))
	t.set_color("font_hover_color", "LayerRow", _c(C, "C_TEXT"))


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
	t.set_font_size("font_size", "LineEdit", _n(C, "T_LABEL"))
	t.set_color("font_color", "LineEdit", _c(C, "C_TEXT"))
	t.set_color("font_placeholder_color", "LineEdit", _c(C, "C_TEXT_DIM"))
	t.set_color("caret_color", "LineEdit", _c(C, "C_ACCENT"))

	t.set_font_size("font_size", "CheckButton", _n(C, "T_H2"))
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


	# ── 下拉 / 弹出菜单 / 提示 / Tab(2026-11-10)───────────────────────────────
	# 之前只有 Button/LineEdit/CheckButton 有皮肤,OptionButton/PopupMenu/菜单下拉/工具提示/Tab
	# 全部回落到 Godot 默认主题(Noto Sans 字体)⇒ 编辑器与设置页的"字体不统一"就从这里来。
	# 这里只加"基础类型"条目(不是 variation):字体族仍走 Theme.default_font(像素字体链),
	# 字号用 T_LABEL=16,和紧凑工具栏同一档。
	var ob := _flat(C, "C_FIELD", "C_BORDER_DIM", 1, _n(C, "SP_3"), _n(C, "SP_2"))
	t.set_stylebox("normal", "OptionButton", ob)
	var ob_hi := _flat(C, "C_BTN_FILL_HI", "C_BORDER", 1, _n(C, "SP_3"), _n(C, "SP_2"))
	t.set_stylebox("hover", "OptionButton", ob_hi)
	t.set_stylebox("pressed", "OptionButton", ob_hi)
	var ob_focus := ob.duplicate() as StyleBoxFlat
	ob_focus.border_color = _c(C, "C_ACCENT")
	t.set_stylebox("focus", "OptionButton", ob_focus)
	t.set_stylebox("disabled", "OptionButton",
			_flat(C, "C_BTN_FILL_DN", "C_BORDER_DIM", 1, _n(C, "SP_3"), _n(C, "SP_2")))
	t.set_font_size("font_size", "OptionButton", _n(C, "T_LABEL"))
	t.set_color("font_color", "OptionButton", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "OptionButton", _c(C, "C_ACCENT"))
	t.set_color("font_pressed_color", "OptionButton", _c(C, "C_ACCENT"))
	t.set_color("font_focus_color", "OptionButton", _c(C, "C_TEXT"))
	t.set_color("font_disabled_color", "OptionButton", _c(C, "C_TEXT_DIM"))

	t.set_stylebox("panel", "PopupMenu",
			_flat(C, "C_SURFACE", "C_BORDER", 1, _n(C, "SP_2"), _n(C, "SP_2")))
	t.set_stylebox("hover", "PopupMenu",
			_flat(C, "C_BTN_FILL_HI", "", 0, _n(C, "SP_3"), _n(C, "SP_2")))
	t.set_font_size("font_size", "PopupMenu", _n(C, "T_LABEL"))
	t.set_color("font_color", "PopupMenu", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "PopupMenu", _c(C, "C_ACCENT"))
	t.set_color("font_disabled_color", "PopupMenu", _c(C, "C_TEXT_DIM"))
	t.set_color("font_separator_color", "PopupMenu", _c(C, "C_TEXT_DIM"))

	# MenuButton 是 Button 的子类;仍不设基础 Button(避免 CheckButton 穿衣),只给 MenuButton。
	# 菜单栏文字按钮:透明底,hover 才出轻底;不再是"实心盒子排在标题旁边"。
	t.set_stylebox("normal", "MenuButton",
			_flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("hover", "MenuButton",
			_flat(C, "C_BTN_FILL_HI", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("pressed", "MenuButton",
			_flat(C, "C_BTN_FILL_DN", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("focus", "MenuButton",
			_flat(C, "C_TRANSPARENT", "C_ACCENT", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_stylebox("disabled", "MenuButton",
			_flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_font_size("font_size", "MenuButton", _n(C, "T_LABEL"))
	t.set_color("font_color", "MenuButton", _c(C, "C_TEXT"))
	t.set_color("font_hover_color", "MenuButton", _c(C, "C_TEXT"))
	t.set_color("font_focus_color", "MenuButton", _c(C, "C_TEXT"))

	t.set_stylebox("panel", "TooltipPanel",
			_flat(C, "C_BG", "C_BORDER", 1, _n(C, "SP_2"), _n(C, "SP_1")))
	t.set_font_size("font_size", "TooltipLabel", _n(C, "T_LABEL"))
	t.set_color("font_color", "TooltipLabel", _c(C, "C_TEXT"))

	# TabBar / TabContainer:下划线式(2026-11-10):透明 tab + 选中 2px 青色底线,
	# 不再给每个 tab 套四边框盒子;Tab 区与右栏同底,视觉上像"分段标题"而不是按钮。
	t.set_font_size("font_size", "TabBar", _n(C, "T_LABEL"))
	t.set_color("font_selected_color", "TabBar", _c(C, "C_TEXT"))
	t.set_color("font_unselected_color", "TabBar", _c(C, "C_TEXT_DIM"))
	t.set_color("font_hovered_color", "TabBar", _c(C, "C_TEXT"))
	t.set_color("font_disabled_color", "TabBar", _c(C, "C_TEXT_MUTE"))
	var tab_on := _flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_3"), _n(C, "SP_2"))
	tab_on.border_width_bottom = 2
	tab_on.border_color = _c(C, "C_ACCENT")
	var tab_off := _flat(C, "C_TRANSPARENT", "", 0, _n(C, "SP_3"), _n(C, "SP_2"))
	tab_off.border_width_bottom = 2
	tab_off.border_color = _c(C, "C_TRANSPARENT")
	t.set_stylebox("tab_selected", "TabBar", tab_on)
	t.set_stylebox("tab_unselected", "TabBar", tab_off)
	t.set_stylebox("tab_hovered", "TabBar", tab_off)
	t.set_stylebox("tab_hovered_pressed", "TabBar", tab_off)
	t.set_stylebox("panel", "TabContainer", _flat(C, "C_SURFACE", "", 0, 0, 0))


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
