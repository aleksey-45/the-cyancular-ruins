extends SceneTree

# 菜单 UI 主题一致性校验：
# 验证导出的 ui/theme/menu_theme.tres 主题资源与 UiFactory 工厂方法动态生成的样式保持逐项对齐。
# 运行方式：
#   source tests/env.sh && timeout 120 "$GODOT" --headless --path . -s res://tests/smoke/menu_theme_mirror_smoke.gd

const THEME_PATH := "res://ui/theme/menu_theme.tres"
const FACTORY_PATH := "res://ui/factory/ui_factory.gd"
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


func _no_class_chain_leak(t: Theme) -> void:
	# ① 数据级：Theme 基础类型 Button 上不应直接挂载样式，避免子类 CheckButton 异常继承
	for s in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		if t.has_stylebox(s, "Button"):
			_fails.append("本 Theme 设置了基础类型 Button 的 styles/%s，CheckButton 会沿类链继承该样式" % s)
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
	# 等待一帧让主题沿场景树完成传播，比对 CheckButton 样式盒类型与内边距
	await process_frame
	_leak_cmp(a, b, "normal")
	_leak_cmp(a, b, "focus")
	plain.free()
	themed.free()


# 挂 Theme 前后,同一槽位的样式盒必须同类同内边距。
func _leak_cmp(a: CheckButton, b: CheckButton, slot: String) -> void:
	var sa := a.get_theme_stylebox(slot)
	var sb := b.get_theme_stylebox(slot)
	if sa == null or sb == null:
		_fails.append("CheckButton/%s 取不到样式盒(%s / %s)" % [slot, str(sa), str(sb)])
		return
	if sa.get_class() != sb.get_class():
		_fails.append("CheckButton/%s 挂载 Theme 前后类型不一致(%s vs %s)"
				% [slot, sa.get_class(), sb.get_class()])
		return
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		_cmp_num(sa.get_margin(side), sb.get_margin(side), "CheckButton/%s 内边距" % slot)


# ── 按钮:六个变体 × 五态 StyleBox + 五个字色 ──
func _buttons(F: GDScript, t: Theme, C: Dictionary) -> void:
	# (Theme 变体名, 生产入口, 生产入口的实参)
	var cases := [
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
			_fails.append("%s: 生产入口 %s 未返回 Button" % [c[0], c[1]])
			continue
		for s in states:
			_cmp_sb(t.get_stylebox(s, c[0]), b.get_theme_stylebox(s), "%s/%s" % [c[0], s])
		for k in colors:
			_cmp_col(t.get_color(k, c[0]), b.get_theme_color(k), "%s/%s" % [c[0], k])
		_cmp_size(t.get_font_size("font_size", c[0]), b.get_theme_font_size("font_size"),
				"%s/font_size" % c[0])
	# RowButton：验证 style_row_button 覆写的样式与字色
	var rb := Button.new()
	F.call("style_row_button", rb)
	for s in states:
		_cmp_sb(t.get_stylebox(s, "RowButton"), rb.get_theme_stylebox(s), "RowButton/%s" % s)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_cmp_col(t.get_color(k, "RowButton"), rb.get_theme_color(k), "RowButton/%s" % k)
	# 验证 RowButton 变体基类型为 Button
	if t.get_type_variation_base("RowButton") != "Button":
		_fails.append("RowButton 的 base_type 不是 Button(实得「%s」)—— 字号不会从 Button 继承"
				% t.get_type_variation_base("RowButton"))
	# 验证 Button 变体字号
	_cmp_size(t.get_font_size("font_size", "BtnPrimary"), 32, "BtnPrimary/font_size == 32")


# 面板样式校验：默认面板、双层面板、标题带与行背景
func _panels(F: GDScript, t: Theme, C: Dictionary) -> void:
	_cmp_sb(t.get_stylebox("panel", "PanelContainer"), F.call("panel_box", true),
			"PanelContainer/panel")
	# 验证双层面板内外层样式
	var outer := PanelContainer.new()
	F.call("skin_menu_panel", outer, Vector2(64, 46))
	_cmp_sb(t.get_stylebox("panel", "PanelCarved"), outer.get_theme_stylebox("panel"),
			"PanelCarved/panel")
	var body := outer.get_node_or_null("Body") as PanelContainer
	if body == null:
		_fails.append("PanelCarved: 生产入口未建出 Body 节点")
	else:
		_cmp_sb(t.get_stylebox("panel", "PanelCarvedBody"), body.get_theme_stylebox("panel"),
				"PanelCarvedBody/panel")
	# 标题带样式
	var hs: PanelContainer = F.call("header_strip", "标题", 32)
	_cmp_sb(t.get_stylebox("panel", "HeaderStrip"), hs.get_theme_stylebox("panel"),
			"HeaderStrip/panel")
	# 行背景样式
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


# 字号分级校验：必须为 16 的整数倍
func _fonts(t: Theme) -> void:
	var want := {"H1": 48, "Body": 32, "Small": 16, "HeaderTitle": 32, "Dim": 32}
	for name in want:
		var got := t.get_font_size("font_size", name)
		_cmp_size(got, want[name], "%s/font_size" % name)
		_checks += 1
		if got % 16 != 0:
			_fails.append("%s 的字号 %d 不是 16 的倍数" % [name, got])
		# 变体必须关联有效基类型
		if t.get_type_variation_base(name) != "Label":
			_fails.append("%s 的 base_type 不是 Label(实得「%s」)—— .tscn 指过去会静默无样式"
					% [name, t.get_type_variation_base(name)])
	if t.get_type_variation_base("BtnQuiet") != "Button":
		_fails.append("BtnQuiet 的 base_type 不是 Button(实得「%s」)"
				% t.get_type_variation_base("BtnQuiet"))


# 开关图标校验：与 _make_switch 生成的像素保持一致
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
			_fails.append("switch_icons()[%d] 为 null" % i)
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
			_fails.append("CheckButton/%s 有 %d 个像素与 _make_switch() 不一致"
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
	_cmp_border_col(x.border_color, y.border_color, tag + ".border_color")
	for side in ["left", "top", "right", "bottom"]:
		_cmp_num(x.get("border_width_" + side), y.get("border_width_" + side),
				"%s.border_width_%s" % [tag, side])
		_cmp_num(x.get("content_margin_" + side), y.get("content_margin_" + side),
				"%s.content_margin_%s" % [tag, side])
	# 圆角四角属性校验：corner_radius_<corner>
	for corner in ["top_left", "top_right", "bottom_right", "bottom_left"]:
		_cmp_num(x.get("corner_radius_" + corner), y.get("corner_radius_" + corner),
				"%s.corner_radius_%s" % [tag, corner])


func _cmp_border_col(a: Color, b: Color, tag: String) -> void:
	_checks += 1
	if not a.is_equal_approx(b):
		_fails.append("%s:边框色不同(Theme=%s 生产=%s)" % [tag, str(a), str(b)])


func _cmp_col(a: Color, b: Color, tag: String, count: bool = true) -> void:
	if count:
		_checks += 1
	if not a.is_equal_approx(b):
		_fails.append("%s:颜色不同(Theme=%s 生产=%s)" % [tag, str(a), str(b)])


# 浮点数值比较
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
