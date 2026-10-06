extends SceneTree

# Theme 镜像守卫:`ui/theme/menu_theme.tres` 必须与 **`UiFactory` 现在的产出**逐项相同。
# 纯逻辑、`-s` 可跑、不占端口、**不需要渲染**。
#
# 跑法:  source tests/env.sh && timeout 120 "$GODOT" --headless --path . \
#            -s res://tests/smoke/menu_theme_mirror_smoke.gd
# 判据:  文本 `THEME MIRROR: ALL-OK`(**不看退出码** —— 挂住时一行裁决都不打印)。
#
# ═══ 为什么需要它(它防的是**本批次自己引入的**一个漂移源)═══
# `menu_theme.tres` 是 `tools/gen_menu_theme.gd` **生成**的。改了 `UiFactory` 的样式而忘了重跑
# 生成器 ⇒ Theme 悄悄停在旧值上:菜单里"编辑器拖出来的"与"代码建的"长得不一样,
# **不报错、不红、没人看得见**(而 `.tscn` 迁移的全部价值就是这两者一致)。
#
# ═══ 判据怎么取(★ 这条决定它值不值钱)═══
# **不**在守卫里重写一份 StyleBox 构造 —— 那会与生成器共享同一个错误源(两边一起错 ⇒ 恒绿)。
# 改为:**调用生产函数本身**,再把它挂到控件上的那份 stylebox 读回来:
#   `F.call("style_button", b, "primary")` → `b.get_theme_stylebox("normal")`
# 这样比的是"生产线真正会画出来的那一份",而不是守卫对它的想象。
# ★ 同类先例:`ui_palette_single_source_smoke` ④ 读的是 `.tscn` 原文(结构上取不到 const);
#   本条能取到生产产出,就**必须**取生产产出。
#
# ★★ **覆盖上限(照实登记)**:
#   · 只比**样式**。比不出"某个控件忘了挂 Theme"(那种控件用 Godot 默认样式,根本不经过 .tres);
#     那一档的唯一拦截是逐屏真实渲染取图。
#   · 比的是 `content_margin_*` 的**原始值**(`-1` = 未设、由 border width 回落)。`PanelCarved`
#     内层刻意留 `-1`(见 `skin_menu_panel` 的注释)⇒ 这条比的是"两边都没设",而不是渲染后的边距。
#   · 没比 `font`(Theme 的 `default_font` 是 `menu_font.tres`,与 `PixelFont.shared()` 返回的
#     `FontFile` 是**两个不同资源**,见 Task 2 的设计 §3.4);字号与颜色两半都在比。
#   · 没比 `Button/…/font_*` 之外的控件态(如 `hover_pressed`:它现只被 `scenes/mp_lobby.tscn`
#     的 7 颗模式色按钮用,那几态是**场景内联 SubResource**、带运行时模式色 ⇒ Theme 里刻意
#     没有对应变体,本守卫没有可比对象)。

const THEME_PATH := "res://ui/theme/menu_theme.tres"
const FACTORY_PATH := "res://ui/factory/ui_factory.gd"
# 抽到的检查条数下限:防止"读坏了 / 变体名写错了 ⇒ 一条都没比到 ⇒ 零失败 = 假绿"。
# 今日实测(2026-10-03 建此守卫时):**92** 条。取 60 留健康余量。
const MIN_CHECKS := 60

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	var F: GDScript = load(FACTORY_PATH)
	var t: Theme = load(THEME_PATH)
	if F == null:
		print("THEME MIRROR: FAIL(读不到 %s)" % FACTORY_PATH)
		quit(1)
		return
	if t == null:
		print("THEME MIRROR: FAIL(读不到 %s)" % THEME_PATH)
		quit(1)
		return
	var C: Dictionary = F.get_script_constant_map()

	_buttons(F, t, C)
	_panels(F, t, C)
	_inputs(F, t, C)
	_fonts(t)
	_icons(F, t)
	await _no_class_chain_leak(t)

	if _checks < MIN_CHECKS:
		_fails.append("只比到 %d 条(下限 %d)—— 变体改名 / 读坏了时零失败是假绿" % [_checks, MIN_CHECKS])
	if _fails.is_empty():
		print("THEME MIRROR: ALL-OK(%d 条比对)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  FAIL " + f)
		print("THEME MIRROR: FAIL(%d 条 / 共比 %d)" % [_fails.size(), _checks])
		quit(1)


# ── 类链泄漏:挂上本 Theme **不许改变** CheckButton 的最小尺寸 ──
#
# ★★ 为什么必须有这一条(2026-10-03 补;Task 1/2 建的 Theme 在这上面**已经错过一次**,
#   而当时的三条守卫**一条都不红**):
#   Godot 的主题查找是**沿类链回退**的 —— 某类型在本 Theme 里查不到条目时会落到它的**父类**。
#   而 `CheckButton : public Button`(`CheckBox` / `OptionButton` 同)。本 Theme 原先设的是
#   **基础类型** `Button/styles/*` ⇒ 任何挂上本 Theme 的场景里,每个 CheckButton 都**静默**
#   穿上了按钮的皮:实测一个空 CheckButton 的最小尺寸从 `(40,22)` 涨到 **`(120,62)`**
#   (= `_btn_box` 的 40/20 内边距 + 40 宽的图标),画面上开关外面多一圈描边,
#   并把它**下面的行整体推走**(设置页左栏实测差 **3.5% 像素**)。
#
# **判据是行为不是源码**:同一个 CheckButton,挂 Theme 与不挂 Theme 的最小尺寸必须**逐位相同**。
# **去掉什么它才会红**:把 `gen_menu_theme.gd` 的 `_button_variants()` 里 `BtnPrimary` 改回
#   `"Button"`(即重新设基础类型)并重跑生成器 ⇒ 两条 `_cmp_size` 当场红。
#   ★ 实测过这条变异(2026-10-03),红的是 `(40,22) vs (120,62)`。
func _no_class_chain_leak(t: Theme) -> void:
	# ① 数据级:本 Theme 的**基础类型** `Button` 上不许有条目(名字直接点出成因)。
	for s in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		if t.has_stylebox(s, "Button"):
			_fails.append("本 Theme 设了基础类型 Button 的 styles/%s —— `CheckButton : public Button` 会沿类链吃到它(见 gen_menu_theme.gd 的 `_button_variants()`)" % s)
		_checks += 1

	# ② 行为级:挂 Theme 前后,同一个 CheckButton 解析出来的样式盒必须同类同内边距。
	var plain := Control.new()
	var themed := Control.new()
	themed.theme = t
	root.add_child(plain)
	root.add_child(themed)
	var a := CheckButton.new()
	var b := CheckButton.new()
	plain.add_child(a)
	themed.add_child(b)
	# ★★ **必须等一帧**:`-s` 模式下主题沿树传播是**帧末**的事,不等就只会读到引擎默认值 ——
	#   那样的守卫会**一动不动地绿**(实测:变异成"设基础 Button"之后它一声没吭)。
	await process_frame
	# ★★ 判据读的是**解析后的样式盒**,不是 `get_combined_minimum_size()`:`-s` 模式下没有帧推进,
	#   最小尺寸是**陈旧值** ⇒ 拿它做判据的守卫会**一动不动地绿**(实测踩过:变异成"设基础
	#   Button"之后,最小尺寸那条断言一声没吭)。
	# ★ 不能复用 `_cmp_sb`:它只认 `StyleBoxFlat`,而引擎默认给 CheckButton 的是
	#   `StyleBoxEmpty` —— 那会**两个方向都红**(假红)。故本处只比**类型 + 四边内边距**:
	#   泄漏的形态正是"类型由 Empty 变成 Flat、内边距由 0 变成 40/20"。
	_leak_cmp(a, b, "normal")
	_leak_cmp(a, b, "focus")
	plain.free()
	themed.free()


# 挂 Theme 前后,同一槽位的样式盒必须**同类同内边距**。
func _leak_cmp(a: CheckButton, b: CheckButton, slot: String) -> void:
	var sa := a.get_theme_stylebox(slot)
	var sb := b.get_theme_stylebox(slot)
	if sa == null or sb == null:
		_fails.append("CheckButton/%s 取不到样式盒(%s / %s)" % [slot, str(sa), str(sb)])
		return
	if sa.get_class() != sb.get_class():
		_fails.append("CheckButton/%s 挂 Theme 前后**类型不同**(%s vs %s)⇒ 它沿类链吃到了别的类型的样式;见 gen_menu_theme.gd 的 `_button_variants()` 注释"
				% [slot, sa.get_class(), sb.get_class()])
		return
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		_cmp_num(sa.get_margin(side), sb.get_margin(side), "CheckButton/%s 内边距" % slot)


# ── 按钮:六个变体 × 五态 StyleBox + 五个字色 ──
func _buttons(F: GDScript, t: Theme, C: Dictionary) -> void:
	# (Theme 变体名, 生产入口, 生产入口的实参)
	var cases := [
		# ★ 主按钮自 2026-10-03 起挂**变体** `BtnPrimary`,不再是基础类型 `Button` ——
		#   理由见 `tools/gen_menu_theme.gd` 的 `_button_variants()` 顶上那段
		#   (设基础 `Button` 会让 `CheckButton : public Button` 沿类链静默穿上按钮的皮)。
		["BtnPrimary", "menu_button", ["m", 32, Vector2(640, 88), "primary"]],
		["BtnQuiet", "menu_button", ["m", 32, Vector2(640, 88), "quiet"]],
		["BtnGold", "menu_button", ["m", 32, Vector2(640, 88), "gold"]],
		["BtnAccent", "menu_button", ["m", 32, Vector2(640, 88), "accent"]],
		["BtnLegacy", "button", ["m", 32, Vector2(420, 64), "primary"]],
		["BtnLegacyQuiet", "button", ["m", 32, Vector2(420, 64), "quiet"]],
	]
	var states := ["normal", "hover", "pressed", "focus", "disabled"]
	var colors := ["font_color", "font_hover_color", "font_focus_color",
			"font_pressed_color", "font_disabled_color"]
	for c in cases:
		var b: Button = F.call(c[1], c[2][0], c[2][1], c[2][2], c[2][3])
		if b == null:
			_fails.append("%s:生产入口 `%s` 没返回 Button" % [c[0], c[1]])
			continue
		for s in states:
			_cmp_sb(t.get_stylebox(s, c[0]), b.get_theme_stylebox(s), "%s/%s" % [c[0], s])
		for k in colors:
			_cmp_col(t.get_color(k, c[0]), b.get_theme_color(k), "%s/%s" % [c[0], k])
		_cmp_size(t.get_font_size("font_size", c[0]), b.get_theme_font_size("font_size"),
				"%s/font_size" % c[0])
	# `RowButton`:`style_row_button()` 是就地覆写(没有返回控件),但同样读得回来。
	var rb := Button.new()
	F.call("style_row_button", rb)
	for s in states:
		_cmp_sb(t.get_stylebox(s, "RowButton"), rb.get_theme_stylebox(s), "RowButton/%s" % s)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_cmp_col(t.get_color(k, "RowButton"), rb.get_theme_color(k), "RowButton/%s" % k)
	# ★ **刻意不比 `RowButton` 的字号**:`style_row_button()` 只覆写样式与字色,**不设字号**
	#   (字号由调用方的 `style_control(b, size)` 给)。拿裸 `Button` 的 `get_theme_font_size()`
	#   去比,量到的是**引擎默认主题**的 16,与 Theme 无关 —— 那是一条"比错了对象"的断言。
	#   Theme 侧的字号来自变体的基类型(`RowButton` base = `Button` = 32),下面钉的是这一点。
	if t.get_type_variation_base("RowButton") != "Button":
		_fails.append("RowButton 的 base_type 不是 Button(实得「%s」)—— 字号不会从 Button 继承"
				% t.get_type_variation_base("RowButton"))
	# `Button` 变体还要比一个"常被顺手忽略"的量:它必须是 `menu_button` 那一档的**字号**。
	_cmp_size(t.get_font_size("font_size", "BtnPrimary"), 32, "BtnPrimary/font_size == 32")


# ── 面板:默认 `panel_box()`、凿刻两层、标题带、行底 ──
func _panels(F: GDScript, t: Theme, C: Dictionary) -> void:
	_cmp_sb(t.get_stylebox("panel", "PanelContainer"), F.call("panel_box", true),
			"PanelContainer/panel")
	# 凿刻外层 / 内层:`skin_menu_panel()` 就是 `menu_panel()` 的实现,用**就地套皮**那条入口取产出。
	var outer := PanelContainer.new()
	F.call("skin_menu_panel", outer, Vector2(64, 46))
	_cmp_sb(t.get_stylebox("panel", "PanelCarved"), outer.get_theme_stylebox("panel"),
			"PanelCarved/panel")
	var body := outer.get_node_or_null("Body") as PanelContainer
	if body == null:
		_fails.append("PanelCarved:生产入口没建出 `Body`(内层亮线的落点)")
	else:
		_cmp_sb(t.get_stylebox("panel", "PanelCarvedBody"), body.get_theme_stylebox("panel"),
				"PanelCarvedBody/panel")
	# 标题带(生产入口返回 PanelContainer,皮挂在它自己身上)。
	var hs: PanelContainer = F.call("header_strip", "标题", 32)
	_cmp_sb(t.get_stylebox("panel", "HeaderStrip"), hs.get_theme_stylebox("panel"),
			"HeaderStrip/panel")
	# 行底(`row_box()` 是纯 StyleBox 工厂)。
	_cmp_sb(t.get_stylebox("panel", "RowPanel"), F.call("row_box"), "RowPanel/panel")


# ── 输入类控件:LineEdit 两态 + 三色、CheckButton 字色、HSlider 三块 ──
func _inputs(F: GDScript, t: Theme, C: Dictionary) -> void:
	var le := LineEdit.new()
	F.call("style_line_edit", le)
	_cmp_sb(t.get_stylebox("normal", "LineEdit"), le.get_theme_stylebox("normal"),
			"LineEdit/normal")
	_cmp_sb(t.get_stylebox("focus", "LineEdit"), le.get_theme_stylebox("focus"), "LineEdit/focus")
	for k in ["font_color", "font_placeholder_color", "caret_color"]:
		_cmp_col(t.get_color(k, "LineEdit"), le.get_theme_color(k), "LineEdit/%s" % k)
	_cmp_size(t.get_font_size("font_size", "LineEdit"), le.get_theme_font_size("font_size"),
			"LineEdit/font_size")

	var cb := CheckButton.new()
	F.call("style_check", cb, 32)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_cmp_col(t.get_color(k, "CheckButton"), cb.get_theme_color(k), "CheckButton/%s" % k)
	_cmp_size(t.get_font_size("font_size", "CheckButton"), cb.get_theme_font_size("font_size"),
			"CheckButton/font_size")

	var sl := HSlider.new()
	F.call("style_slider", sl)
	for k in ["slider", "grabber_area", "grabber_area_highlight"]:
		_cmp_sb(t.get_stylebox(k, "HSlider"), sl.get_theme_stylebox(k), "HSlider/%s" % k)


# ── 字号三档:必须是 16 的倍数(`kh_l5_probe` 扫 `.tres` 钉的就是这一条,这里再钉一次语义)──
func _fonts(t: Theme) -> void:
	var want := {"H1": 48, "Body": 32, "Small": 16, "HeaderTitle": 32, "Dim": 32}
	for name in want:
		var got := t.get_font_size("font_size", name)
		_cmp_size(got, want[name], "%s/font_size" % name)
		_checks += 1
		if got % 16 != 0:
			_fails.append("%s 的字号 %d 不是 16 的倍数" % [name, got])
		# 变体必须真的挂在一个基类型上,否则 `.tscn` 里指过去是**空变体**(不报错、样式全丢)。
		if t.get_type_variation_base(name) != "Label":
			_fails.append("%s 的 base_type 不是 Label(实得「%s」)—— .tscn 指过去会静默无样式"
					% [name, t.get_type_variation_base(name)])
	if t.get_type_variation_base("BtnQuiet") != "Button":
		_fails.append("BtnQuiet 的 base_type 不是 Button(实得「%s」)"
				% t.get_type_variation_base("BtnQuiet"))


# ── 开关图标:PNG 必须与 `_make_switch()` **逐像素**相同 ──
# ★ 这一条防的是"改了胶囊尺寸/配色,重跑了生成器但**忘了 `--import`**":那时 `.tres` 里引用
#   的还是**上一版**导入的贴图,而 Theme 本身看不出任何异常。
func _icons(F: GDScript, t: Theme) -> void:
	var live: Array = F.call("switch_icons")
	var names := ["unchecked", "checked"]
	for i in 2:
		var from_theme: Texture2D = t.get_icon(names[i], "CheckButton")
		if from_theme == null:
			_fails.append("CheckButton/%s 在 Theme 里没有图标(会退回 Godot 默认的小灰点)" % names[i])
			continue
		var live_tex: ImageTexture = live[i]
		if live_tex == null:
			_fails.append("`switch_icons()[%d]` 为 null" % i)
			continue
		var a := from_theme.get_image()
		var b := live_tex.get_image()
		if a == null or b == null:
			_fails.append("CheckButton/%s 取不到 Image(无法比对)" % names[i])
			continue
		_checks += 1
		if a.get_size() != b.get_size():
			_fails.append("CheckButton/%s 尺寸不同:Theme=%s 生产=%s" % [names[i], a.get_size(), b.get_size()])
			continue
		var diff := 0
		for y in a.get_height():
			for x in a.get_width():
				if a.get_pixel(x, y) != b.get_pixel(x, y):
					diff += 1
		if diff > 0:
			_fails.append("CheckButton/%s 有 %d 个像素与 `_make_switch()` 不同(改了胶囊忘了重跑生成器/--import?)"
					% [names[i], diff])


# ── 比较原语 ──
func _cmp_sb(a: StyleBox, b: StyleBox, tag: String) -> void:
	_checks += 1
	if a == null or b == null:
		_fails.append("%s:一侧为 null(Theme=%s 生产=%s)" % [tag, str(a), str(b)])
		return
	if a.get_class() != b.get_class():
		_fails.append("%s:类型不同(Theme=%s 生产=%s)" % [tag, a.get_class(), b.get_class()])
		return
	if not (a is StyleBoxFlat):
		_fails.append("%s:不是 StyleBoxFlat(本守卫只认这一种)" % tag)
		return
	var x := a as StyleBoxFlat
	var y := b as StyleBoxFlat
	_cmp_col(x.bg_color, y.bg_color, tag + ".bg_color", false)
	_cmp_col(x.border_color, y.border_color, tag + ".border_color", false)
	for side in ["left", "top", "right", "bottom"]:
		_cmp_num(x.get("border_width_" + side), y.get("border_width_" + side),
				"%s.border_width_%s" % [tag, side])
		_cmp_num(x.get("content_margin_" + side), y.get("content_margin_" + side),
				"%s.content_margin_%s" % [tag, side])
	# ★ 圆角四角的属性名是 `corner_radius_<纵>_<横>`(`corner_radius_top_left`),
	#   **不是** `corner_radius_left` —— 写错时 `get()` 返回 null(本守卫会把 null 判红,
	#   故这条笔误当场现形,而不是静默漏比四个角)。
	for corner in ["top_left", "top_right", "bottom_right", "bottom_left"]:
		_cmp_num(x.get("corner_radius_" + corner), y.get("corner_radius_" + corner),
				"%s.corner_radius_%s" % [tag, corner])


func _cmp_col(a: Color, b: Color, tag: String, count: bool = true) -> void:
	if count:
		_checks += 1
	if not a.is_equal_approx(b):
		_fails.append("%s:颜色不同(Theme=%s 生产=%s)" % [tag, str(a), str(b)])


# ★ 两个参数是 Variant(`StyleBoxFlat` 的 border_width_* 是 int、content_margin_* 是 float),
#   故**先赋给 float 变量**再比 —— 直接在 `float(a)` 里转 Variant 会在 `-s` 下报
#   "Nonexistent 'float' constructor"。非数值(null / 形状变了)一律判红,不静默当 0。
func _cmp_num(a, b, tag: String) -> void:
	_checks += 1
	if not (a is float or a is int) or not (b is float or b is int):
		_fails.append("%s:一侧不是数值(Theme=%s 生产=%s)" % [tag, str(a), str(b)])
		return
	var fa: float = a
	var fb: float = b
	if not is_equal_approx(fa, fb):
		_fails.append("%s:%s vs %s" % [tag, str(a), str(b)])


func _cmp_size(a: int, b: int, tag: String) -> void:
	_checks += 1
	if a != b:
		_fails.append("%s:%d vs %d" % [tag, a, b])
