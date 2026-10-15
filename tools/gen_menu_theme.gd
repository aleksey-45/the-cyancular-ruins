extends SceneTree

# 从 UiFactory 的现有取值生成 ui/theme/menu_theme.tres(+ 两个开关图标 PNG)。
# ★ 为什么是「生成」而不是手写:.tres 里的颜色是 float32 的十进制序列化,手抄有两个风险 —— ① 精度(0.105882354 抄成 0.106 就差 1.2e-4,而守卫按值比对、容差 1/65536 ⇒ 当场红);
#   ② 漂移(改了 UiFactory 的值而忘了改 .tres,那种不一致不会报错,只让「编辑器里拖出来的」与「运行时建的」长得不一样)。由工厂自己产出 ⇒ 逐位相同由构造保证,不靠人抄。
# 跑法(改过 UiFactory 的菜单系样式之后必须重跑):"$GODOT" --headless --path . -s res://tools/gen_menu_theme.gd;之后跑一次 --import(让两个 PNG 进导入缓存)。
# ★ 本工具不引 autoload(UiFactory / PixelFont 都不依赖它们),故 -s 可跑。
# ⚠ 原来接着要跑的两条守卫 ui_palette_single_source_smoke 与 menu_style_probe 都已删·2026-10-09 ⇒ 今天只剩逐屏取图兜底。
# ★★ 两个 PNG 的 .import 里 process/fix_alpha_border 必须为 false(已提交在仓里):默认 true 会改写透明像素附近的 RGB —— 图标肉眼无差(那些像素本来就透明),
#   但镜像守卫逐像素比对时实测差 100 个像素。别顺手改回 true;★ 运行工具不会重写 .import,但删掉 .import 重新导入会退回默认 true,那时镜像守卫会红。
# ★ 变体的字号一律 32(与 UiFactory.menu_button / button 的既有调用点一致);需要别的字号的调用方自己去 .tscn 里写 theme_type_variation + 尺寸,不要在这里加档。
# ★★ 覆盖上限(照实登记):只保证「Theme 里能表达的那些样式与工厂逐位相同」;工厂里带运行时参数的入口(menu_panel(padding) / fit_name)在 Theme 里表达不了 ——
#   用到它们的地方只能各自表达(代码,或 .tscn 里的显式节点 / SubResource),没有「外观不变」的机械保证,只有逐屏取图。
# ⚠ Filter 变体刻意一个都没有:模式色是运行时值,由 mp_lobby.tscn 的内联 SubResource 承担;手改那几态时注意 Button 的「选中」画的是 pressed 主题项(不是 normal),只改 normal 画面毫无变化且不报错,那批 SubResource 必须五态都写。

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
	# 每次重跑都重导一次图标:改了胶囊尺寸(SWITCH_W/SWITCH_H)时它必须跟着变。
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


# ── 字号三档(Type Variation)── 三档全是 16 的倍数(零守卫:`kh_l5_probe` 已删·2026-10-09,人眼核对)。
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
	# 次要说明文字(占位/说明),与 C_TEXT_DIM 同款。
	t.set_type_variation("Dim", "Label")
	t.set_font_size("font_size", "Dim", 32)
	t.set_color("font_color", "Dim", _c(C, "C_TEXT_DIM"))


# ── 按钮 ── BtnPrimary = menu_button("primary")(菜单系的新语汇);另四个变体覆盖 menu_button 的其余档;两个 BtnLegacy* 覆盖旧的 style_button() —— 暂停菜单/结算页那一族还在用,迁移期要让它们能落成同一外观。
# ★★ 刻意不设基础类型 Button:Godot 的主题查找沿类链回退,而 CheckButton : public Button —— 曾在基础类型上设 Button/styles/*,于是每个 CheckButton 都静默穿上按钮的皮
#   (实测空 CheckButton 最小尺寸从 (40,22) 涨到 (120,62),设置页左栏实测差 3.5% 像素,而没有任何守卫会红)。⇒ 基础类型留空(CheckButton 落回引擎默认主题),主按钮改挂 BtnPrimary。
#   ★ 两种修法都不行:补 StyleBoxEmpty 会把焦点环一起丢掉(截图里看不见);照抄默认主题的 focus 盒带 Color(1,1,1,0.75),而"Theme 里的颜色必须只来自 UiFactory"这条纪律今天零守卫(`ui_palette_single_source_smoke` 已删·2026-10-09)⇒ 只能人工守。
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
	# ★ 菜单系的禁用字用 C_TEXT_MUTE(更弱一档);旧那族用 C_TEXT_DIM —— 两者不同款,别「统一」。
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


# ── 面板 ── 默认 PanelContainer = panel_box()(不透明 C_SURFACE + 2px C_BORDER + 28/20);PanelCarved / PanelCarvedBody = menu_panel() 的两层(外:1px C_BORDER、不设 content_margin;内:透明底 + 1px C_INNER + 64/46)。
# ★ 内层那条「不设 content_margin」是承重的:留默认 -1 时 StyleBox::get_margin() 回落成 border width ⇒ 子节点内缩 1px、两条线落在不同像素环上;显式写 0 会让内层铺满外层、两条线重合、画面上只剩一条(零守卫:menu_style_probe 已删·2026-10-09)。
# ★ PanelCarvedBody 的 64/46 只是 menu_panel() 的默认 padding —— 传了别的值的调用方在 .tscn 里表达不了,仍走代码(见文件头「覆盖上限」)。
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
	var body := StyleBoxFlat.new()
	body.bg_color = _c(C, "C_TRANSPARENT")
	body.border_color = _c(C, "C_INNER")
	body.set_border_width_all(1)
	body.set_corner_radius_all(0)
	body.content_margin_left = 64.0
	body.content_margin_right = 64.0
	body.content_margin_top = 46.0
	body.content_margin_bottom = 46.0
	t.set_stylebox("panel", "PanelCarvedBody", body)

	# 标题带:header_strip() 的形状(只有下边一条线)。
	t.set_type_variation("HeaderStrip", "PanelContainer")
	var hs := StyleBoxFlat.new()
	hs.bg_color = _c(C, "C_HEADER")
	hs.set_corner_radius_all(0)
	hs.border_width_left = 0
	hs.border_width_right = 0
	hs.border_width_top = 0
	hs.border_width_bottom = 1
	hs.border_color = _c(C, "C_BORDER")
	# ★ 与 UiFactory.header_strip() 逐值一致(那边把左内边距 40 → 0):改一处必须改两处 —— 原守卫 `menu_theme_mirror_smoke` 已删·2026-10-09,零守卫。
	hs.content_margin_left = 0.0
	hs.content_margin_right = 40.0
	hs.content_margin_top = 20.0
	hs.content_margin_bottom = 20.0
	t.set_stylebox("panel", "HeaderStrip", hs)

	# 列表行底(row_box():无边框)与整行可点按钮(style_row_button():悬停才浮描边)。
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


# ── 输入框 / 开关 / 滑条 ──
func _other_controls(t: Theme, F: GDScript, C: Dictionary) -> void:
	# LineEdit:style_line_edit() 的两态 + 三个颜色。字号 16(与它的既有调用点一致)。
	var le := StyleBoxFlat.new()
	le.bg_color = _c(C, "C_FIELD")
	le.border_color = _c(C, "C_BORDER_DIM")
	le.set_border_width_all(2)
	le.set_corner_radius_all(0)
	le.content_margin_left = 10.0
	le.content_margin_right = 10.0
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate() as StyleBoxFlat
	lef.border_color = _c(C, "C_ACCENT")
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_font_size("font_size", "LineEdit", 16)
	t.set_color("font_color", "LineEdit", _c(C, "C_TEXT"))
	t.set_color("font_placeholder_color", "LineEdit", _c(C, "C_TEXT_DIM"))
	t.set_color("caret_color", "LineEdit", _c(C, "C_ACCENT"))

	# CheckButton:style_check() 的四个字色 + 自绘胶囊图标(由 _make_switch 导出的 PNG)。★ 这里刻意一个样式盒都不设 —— 理由见 _button_variants() 顶上那段。
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

	# HSlider:style_slider() 的轨道 + 已填充段(两者同款,见那个函数)。
	var track := StyleBoxFlat.new()
	track.bg_color = _c(C, "C_BORDER_DIM")
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", F.call("_row_sb", _c(C, "C_ACCENT"), _c(C, "C_ACCENT")))
	t.set_stylebox("grabber_area_highlight", "HSlider",
			F.call("_row_sb", _c(C, "C_ACCENT"), _c(C, "C_ACCENT")))


# 两个 PNG 是否已经导入过(能 load() 到)。第一趟必然为假 —— 那时它们还不存在。
func _switch_icons_ready() -> bool:
	return load(OUT_SWITCH_OFF) != null and load(OUT_SWITCH_ON) != null


# 把 UiFactory._make_switch() 程序化画的胶囊落盘成 PNG —— Theme 引用不到运行时生成的 ImageTexture,只能引用文件。★ 改了胶囊尺寸(SWITCH_W/SWITCH_H)要重跑本工具。
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
