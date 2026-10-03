extends Node

# 「信 息」整页的常驻守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
# 判据: 文本 `INFO PAGE PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:这一页的内容(名单/致谢/版本)是**人手抄进去的**,而抄错一个字
#   没有任何东西会红 —— 它只表现为"页面上少一个人"或"致谢写错了名"。
#   本探针把那三块内容**逐字**钉住。
# ★ 断言计数:改本探针必须同步改这个数(见 tests/lib/probe_base.gd 文件头)。
#   数法(逐行数 `_check(...)` 的**运行时**实参个数,循环里的也算):
#     4 个分节标题(信 息 / 版 本 信 息 / 开 发 团 队 / 致 谢)
#   + 4 个人名(DEV_TEAM 逐条一条)
#   + 5 条致谢(CREDITS 逐条一条)
#   + 2 个许可证(MIT / SIL OFL 1.1)
#   + 1 个「返 回」按钮
#   + 1 条版本号真值比对
#   + 3 条布局(找到滚动区+提交行 / 钉死行宽 ≤ 滚动区宽 / 左栏比右栏宽)
#   = 20
# ★ 注意这是**运行时**条数:静态 `grep -c '^\s*_check('` 只会数到 9(循环里的 9 条看不见),
#   故别拿 grep 的数来对这里 —— 它俩本来就对不上。
const EXPECTED_CHECKS := 20

const SCENE := "res://scenes/info_menu.tscn"
const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048"]
const CREDITS := ["Godot Engine", "GNU Unifont", "Less Perfect DOS VGA",
		"Thomas Stearns Eliot", "Jorge Luis Borges"]

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
	var p: Node = (load(SCENE) as PackedScene).instantiate()
	if p == null:
		print("INFO PAGE PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	var host := Node.new()
	add_child(host)
	host.add_child(p)
	var texts := _collect_labels(p)
	_check(_has(texts, "信 息"), "标题是「信 息」")
	_check(_has(texts, "版 本 信 息"), "有「版 本 信 息」一节")
	_check(_has(texts, "开 发 团 队"), "有「开 发 团 队」一节")
	_check(_has(texts, "致 谢"), "有「致 谢」一节")
	for who in DEV_TEAM:
		_check(_has_exact(texts, who), "开发团队含「%s」" % who)
	for c in CREDITS:
		_check(_has(texts, c), "致谢含「%s」" % c)
	_check(_has(texts, "MIT"), "Godot 的许可证标了 MIT")
	_check(_has(texts, "SIL OFL 1.1"), "Unifont 的许可证标了 SIL OFL 1.1")
	var back := _find_button(p, "返 回")
	_check(back != null and back.pressed.get_connections().size() == 1,
			"「返 回」按钮存在且恰有 1 个 handler")
	# ★ 版本号那一行必须来自 AppInfo(不是写死的占位串) —— 拿 AppInfo 的真值去比。
	var ver := preload("res://core/config/app_info.gd").version_string()
	_check(_has(texts, ver), "版本号那一行是 AppInfo.version_string() 的真值(「%s」)" % ver)
	# ★ 布局断言必须在**真帧之后**量:容器排序(NOTIFICATION_SORT_CHILDREN)是下一帧的事,
	#   加进树里就立刻读 size 会全读到 0。故先让两帧跑过再量。
	await get_tree().process_frame
	await get_tree().process_frame
	_check_layout(p)
	host.free()
	_finish()


# ── 布局断言(必须在真帧之后量)────────────────────────────────────────
# ★ 为什么这三条必须有(它们是 2026-10-03 那次排版修复的**常驻护栏**):
#   ① 「钉死行宽」若大于左栏可见内宽,ScrollContainer 会出**横向滚动条**,而
#      `OVERRUN_TRIM_ELLIPSIS` 的省略号落在**可视区之外** —— 比不钉行宽更糟
#      (既滚动又看不见截断提示)。写死一个数字挡不住它(实测 `ROW_W = 900` 曾
#      大于左栏内宽 829),故拿**测量值**比:行的钉死宽度 ≤ 它的滚动区宽度。
#   ② 设计 §3.10 要的是左 1.25 : 右 1,而 `ScrollContainer` 的最小尺寸**不向上传播**
#      子节点宽度 ⇒ 单靠 `ROW_W` 撑不宽(实测会塌成 1:1 = 885/885),必须靠
#      `size_flags_stretch_ratio` 并**量出来**。
func _check_layout(root: Node) -> void:
	var scroll := _find_scroll(root)
	var row := _first_label_under(scroll)
	_check(scroll != null and row != null, "左栏找得到 ScrollContainer 与至少一条提交行")
	var row_w := row.custom_minimum_size.x if row != null else -1.0
	var scroll_w := scroll.size.x if scroll != null else -1.0
	_check(row != null and scroll != null and row_w <= scroll_w,
			"钉死行宽 %.0f ≤ 滚动区宽 %.0f" % [row_w, scroll_w])
	var left: Control = scroll.get_parent().get_parent() if scroll != null else null
	var cols: Node = left.get_parent() if left != null else null
	var right: Control = cols.get_child(1) if cols != null and cols.get_child_count() >= 2 else null
	_check(left != null and right != null and left.size.x > right.size.x,
			"左栏 %.0f > 右栏 %.0f(设计 §3.10 左 1.25 : 右 1)" % [
					left.size.x if left != null else -1.0,
					right.size.x if right != null else -1.0])


func _find_scroll(root: Node) -> ScrollContainer:
	if root == null:
		return null
	if root is ScrollContainer:
		return root
	for c in root.get_children():
		var s := _find_scroll(c)
		if s != null:
			return s
	return null


func _first_label_under(root: Node) -> Label:
	if root == null:
		return null
	for c in root.get_children():
		if c is Label:
			return c
		var l := _first_label_under(c)
		if l != null:
			return l
	return null


func _collect_labels(root: Node, out: Array = []) -> Array:
	if root is Label:
		out.append((root as Label).text)
	for c in root.get_children():
		_collect_labels(c, out)
	return out


func _has(texts: Array, needle: String) -> bool:
	for t in texts:
		if str(t).contains(needle):
			return true
	return false


func _has_exact(texts: Array, want: String) -> bool:
	for t in texts:
		if str(t).strip_edges() == want:
			return true
	return false


func _find_button(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text == text:
		return root
	for c in root.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("INFO PAGE PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("INFO PAGE PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
