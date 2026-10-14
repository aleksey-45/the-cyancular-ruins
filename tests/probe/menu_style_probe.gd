extends Node

# 菜单视觉规范自动化探针
# 验证标准：输出 "MENU STYLE PROBE: ALL-OK"

const EXPECTED_CHECKS := 20

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	# 阶段 1：新增菜单主题色常量
	_check(UiFactory.C_HEADER == Color("#1B242C"), "C_HEADER 存在且值正确")
	_check(UiFactory.C_INNER == Color("#1E2830"), "C_INNER 存在且值正确")
	_check(UiFactory.C_EDGE == Color("#46545F"), "C_EDGE 存在且值正确")
	_check(UiFactory.C_GOLD == Color("#E0A94F"), "C_GOLD 存在且值正确")
	_check(UiFactory.C_TEXT_MUTE == Color("#6C7885"), "C_TEXT_MUTE 存在且值正确")

	# 阶段 2：共享颜色常量回归验证，确保局内 HUD 颜色不受影响
	_check(UiFactory.C_ACCENT == Color(0.349, 0.851, 0.902), "C_ACCENT 保持不变")
	_check(UiFactory.C_TEXT_DIM == Color(0.510, 0.573, 0.639), "C_TEXT_DIM 保持不变")
	_check(UiFactory.C_TEXT == Color(0.878, 0.914, 0.949), "C_TEXT 保持不变")
	_check(UiFactory.C_DANGER == Color(0.900, 0.400, 0.400), "C_DANGER 保持不变")

	# 阶段 3：面板基础样式
	var sb := UiFactory.panel_box()
	_check(sb.bg_color.a == 1.0, "panel_box() 背景保持不透明")

	var mp := UiFactory.menu_panel()
	_check(mp != null and mp is PanelContainer, "menu_panel() 返回 PanelContainer")
	if mp is PanelContainer:
		var outer := (mp as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		var body := (mp as PanelContainer).get_node_or_null("Body")
		_check(outer != null and outer.border_color == UiFactory.C_BORDER,
				"menu_panel() 外边框颜色为 C_BORDER")
		var inner: StyleBoxFlat = null
		if body is PanelContainer:
			inner = (body as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		_check(inner != null and inner.border_color == UiFactory.C_INNER,
				"menu_panel() 内亮线颜色为 C_INNER")

	# 阶段 4：菜单按钮样式
	var mb := UiFactory.menu_button("测试", 32, Vector2(200, 48))
	var bn := mb.get_theme_stylebox("normal") as StyleBoxFlat
	var bh := mb.get_theme_stylebox("hover") as StyleBoxFlat
	_check(bn != null and bn.border_color == UiFactory.C_EDGE, "menu_button() 默认边框为 C_EDGE")
	_check(bh != null and bh.border_color == UiFactory.C_ACCENT, "menu_button() 悬停边框切换为 C_ACCENT")
	_check(bn != null and bn.bg_color == UiFactory.C_HEADER, "menu_button() 背景填充为 C_HEADER")

	# 阶段 5：标题带样式
	var strip := UiFactory.header_strip("测 试", 32)
	var ssb := (strip as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	_check(ssb != null and ssb.bg_color == UiFactory.C_HEADER, "header_strip() 背景色为 C_HEADER")
	_check(ssb != null and ssb.border_width_bottom == 1 and ssb.border_color == UiFactory.C_BORDER,
			"header_strip() 仅保留底边一条 C_BORDER 边框线")

	# 阶段 6：布局内缩与边距判定
	add_child(mp)
	await get_tree().process_frame
	var body_n: Control = mp.get_node_or_null("Body") as Control
	_check(body_n != null and body_n.position.x >= 1.0 and body_n.position.y >= 1.0,
			"内层 Body 节点发生有效内缩")
	_check(body_n != null and body_n.size.x <= (mp as PanelContainer).size.x - 2.0,
			"内层宽度小于外层总宽度")
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("实际执行断言数 %d 低于预期 %d" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MENU STYLE PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("MENU STYLE PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
