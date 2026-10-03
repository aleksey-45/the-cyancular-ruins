extends Node

# 菜单系视觉重做的基座守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
# 判据: 文本 `MENU STYLE PROBE: ALL-OK`(不看退出码)。
#
# ★★ 本探针最要紧的不是"新 token 在不在",而是**共享 token 冻结**那几条:
#    改菜单配色最容易顺手改到 `C_ACCENT` / `C_TEXT_DIM`,而它们被**对局内 HUD**读
#    (`ui/hud/hud.gd:16` 击杀色、`royale_hud.gd:17/18` 的「我」那行与「复活中」)——
#    改了不会有任何编译错误,只表现为"打起来之后 HUD 颜色不对",而那时你早忘了。
#    ★ 这四条钉的是**值**,不是名字:把颜色调深一点也会红。
# ★ 断言计数:改本探针必须同步改这个数(见 tests/lib/probe_base.gd 文件头)。
#   **数法** = 5(新 token)+ 4(冻结守卫)+ 1(panel_box 底不透明)+ 3(menu_panel 返回 /
#              外线 / 内线)+ 2(★ 位置:内层真内缩 / 内层宽度 < 外层 −2px)= **15**。
#
# ★ 注:新 token 的期望值统一用 hex 字符串 —— `ui_factory.gd` 里也**必须**写成
#   `Color("#RRGGBB")`,两侧同写法才逐位相等(浮点反算会差 1/255 ⇒ 恒红)。
const EXPECTED_CHECKS := 15

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
	# ── 新增的 5 个 token(菜单专用) ──
	_check(UiFactory.C_HEADER == Color("#1B242C"), "C_HEADER 存在且值正确")
	_check(UiFactory.C_INNER == Color("#1E2830"), "C_INNER 存在且值正确")
	_check(UiFactory.C_EDGE == Color("#46545F"), "C_EDGE 存在且值正确")
	_check(UiFactory.C_GOLD == Color("#E0A94F"), "C_GOLD 存在且值正确")
	_check(UiFactory.C_TEXT_MUTE == Color("#6C7885"), "C_TEXT_MUTE 存在且值正确")

	# ── ★★ 冻结守卫:被 HUD 读的 token 逐位不变 ──
	# 期望值是**本计划开始前**的实测值(不是设计 §3.9.1 那张表 —— 那张表与
	# "HUD 一行不动"自相矛盾,已由用户裁定以 HUD 为准)。
	_check(UiFactory.C_ACCENT == Color(0.349, 0.851, 0.902),
			"★ C_ACCENT 未变(对局内击杀色/「我」那行在用)")
	_check(UiFactory.C_TEXT_DIM == Color(0.510, 0.573, 0.639),
			"★ C_TEXT_DIM 未变(对局内「复活中」在用)")
	_check(UiFactory.C_TEXT == Color(0.878, 0.914, 0.949), "★ C_TEXT 未变")
	_check(UiFactory.C_DANGER == Color(0.900, 0.400, 0.400), "★ C_DANGER 未变(对局内「离开」/延迟条在用)")

	# ── 面板底仍然不透明 ──
	var sb := UiFactory.panel_box()
	_check(sb.bg_color.a == 1.0, "panel_box() 的底仍是不透明")

	# ── 新工厂：菜单面板要有**外描边 + 内亮线**两条线 ──
	# ★ 判据落在"两个 stylebox 的 border 颜色确实不同"上 —— 它比"存在两个节点"
	#   更贴近这条视觉规则本身;把内线改成与外线同色 ⇒ 这条红。
	var mp := UiFactory.menu_panel()
	_check(mp != null and mp is PanelContainer, "menu_panel() 返回 PanelContainer")
	if mp is PanelContainer:
		var outer := (mp as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		var body := (mp as PanelContainer).get_node_or_null("Body")
		_check(outer != null and outer.border_color == UiFactory.C_BORDER,
				"menu_panel() 的外描边是 C_BORDER")
		var inner: StyleBoxFlat = null
		if body is PanelContainer:
			inner = (body as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		_check(inner != null and inner.border_color == UiFactory.C_INNER,
				"menu_panel() 的内亮线是 C_INNER(凿刻感的来源)")

	# ── ★ 位置断言:两条线必须落在**不同的像素环**上 ──
	# ★ 只断言两层 border_color 各自正确是**看不见重合**的:计划初稿把外层 content_margin
	#   显式写成 0.0 时,内层铺满外层整个矩形(`body.rect == (0,0,外层全尺寸)`)、两条 1px
	#   线落在同一环上、内层盖住外层 ⇒ 画面上只剩一条,而上面几条**照样全绿**。
	#   这两条量的是"内层真的被内缩了 1px"(外层不设 content_margin ⇒ 默认 -1 ⇒
	#   `StyleBox::get_margin()` 回落 border width ⇒ `get_offset()==(1,1)`)。
	# ★ 探针是 `extends Node`,要**真入树 + 等一帧**才拿得到 rect。
	add_child(mp)
	await get_tree().process_frame
	var body_n: Control = mp.get_node_or_null("Body") as Control
	_check(body_n != null and body_n.position.x >= 1.0 and body_n.position.y >= 1.0,
			"★ 内亮线**真的内缩**(否则它与外线落在同一像素环上,只看得见一条)")
	_check(body_n != null and body_n.size.x <= (mp as PanelContainer).size.x - 2.0,
			"★ 内层宽度 < 外层 − 两侧各 1px")
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MENU STYLE PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("MENU STYLE PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
