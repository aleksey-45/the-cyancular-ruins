extends Node

const EXPECTED_CHECKS := 25

const SCENE := "res://scenes/info_menu.tscn"
const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048",
	"ofbwyx", "Lycoris Max", "hsk"]
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	["Deepseek", ""],
	["GLM", ""],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]
# 空历史兜底保护文案:同样硬编码复制的生产字面量(`scenes/info_menu.gd` 的 `_fill_version_block`)。
const NO_GIT_NOTE := "(读不到 git 历史:仓库不可用或未安装 git)"

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
	# - 版本号真值必须在打断 PATH 之前取:`AppInfo` 有静态缓存,先取一次之后页面拿到的是
	#   同一份(否则页面会因 git 不可用而显示 "dev",而真值仍是 git 那一份,两边对不上)。
	var ver: String = preload("res://core/config/app_info.gd").version_string()

	var p: Node = (load(SCENE) as PackedScene).instantiate()
	if p == null:
		print("INFO PAGE PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	var host := Node.new()
	add_child(host)

	var saved_path := OS.get_environment("PATH")
	OS.set_environment("PATH", "C:\\definitely\\not\\a\\real\\path")
	_check(preload("res://core/config/app_info.gd").commit_log().is_empty(),
			"前置:打断 PATH 后 commit_log() 确实返回空(否则下面的兜底断言测的不是它)")
	host.add_child(p)
	var texts := _collect_labels(p)
	OS.set_environment("PATH", saved_path)

	# 注意事项：标题必须精确全字匹配（子串包含会导致假阳性：紧邻的「版 本 信 息」本身包含“信 息”，
	#    若删除 48pt 的页面主标题，子串断言仍会命中并误报通过）。
	#   现校验主标题 Label 节点自身：文本内容严格等于「信 息」且字号为 48。
	var title := _find_label_exact(p, "信 息")
	_check(title != null and title.get_theme_font_size("font_size") == 48,
			"整页标题 Label 逐字是「信 息」且字号 48(不是「版 本 信 息」的子串命中)")
	_check(_has(texts, "版 本 信 息"), "有「版 本 信 息」一节")
	_check(_has(texts, "开 发 团 队 / 特 别 感 谢"), "有「开 发 团 队 / 特 别 感 谢」一节")
	_check(_has(texts, "致 谢"), "有「致 谢」一节")
	for who in DEV_TEAM:
		_check(_has_exact(texts, who), "开发团队含「%s」" % who)
	for pair in CREDITS:
		var who := str(pair[0])
		var lic := str(pair[1])
		var want: String = who if lic == "" else "%s　%s" % [who, lic]
		_check(_has_exact(texts, want), "致谢行逐字是「%s」" % want)
	_check(_has_exact(texts, NO_GIT_NOTE),
			"读不到 git 历史时有兜底文案(逐字「%s」)" % NO_GIT_NOTE)
	var back := _find_button(p, "返 回")
	_check(back != null and back.pressed.get_connections().size() == 1,
			"「返 回」按钮存在且恰有 1 个 handler")
	# - 版本号那一行必须来自 AppInfo(不是写死的占位串) —— 拿 AppInfo 的真值去比。
	_check(_has(texts, ver), "版本号那一行是 AppInfo.version_string() 的真值(「%s」)" % ver)
	# - 布局断言必须在真帧之后量:容器排序(NOTIFICATION_SORT_CHILDREN)是下一帧的事,
	#   加进树里就立刻读 size 会全读到 0。故先让两帧跑过再量。
	await get_tree().process_frame
	await get_tree().process_frame
	_check_layout(p)
	host.free()
	_finish()


func _check_layout(root: Node) -> void:
	var scroll := _find_scroll(root)
	var row := _first_label_under(scroll)
	_check(scroll != null and row != null, "左栏找得到 ScrollContainer 与至少一条提交行")
	var row_w := row.custom_minimum_size.x if row != null else -1.0
	var scroll_w := scroll.size.x if scroll != null else -1.0
	_check(row != null and scroll != null and row_w <= scroll_w,
			"钉死行宽 %.0f ≤ 滚动区宽 %.0f" % [row_w, scroll_w])
	var cols := _find_two_col_box(root, scroll)
	var left: Control = cols.get_child(0) if cols != null else null
	var right: Control = cols.get_child(1) if cols != null and cols.get_child_count() >= 2 else null
	_check(left != null and right != null and left.size.x > right.size.x,
			"左栏 %.0f > 右栏 %.0f(设计 §3.10 左 1.25 : 右 1)" % [
					left.size.x if left != null else -1.0,
					right.size.x if right != null else -1.0])


# 找含 `scroll` 的、恰有 2 个直接子节点的 HBoxContainer(= 那两栏)。
func _find_two_col_box(root: Node, scroll: Node) -> Node:
	if root is HBoxContainer and root.get_child_count() == 2 and _subtree_has(root, scroll):
		return root
	for c in root.get_children():
		var r := _find_two_col_box(c, scroll)
		if r != null:
			return r
	return null


func _subtree_has(n: Node, target: Node) -> bool:
	if n == target:
		return true
	for c in n.get_children():
		if _subtree_has(c, target):
			return true
	return false


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


# 找文字逐字等于 `want` 的那个 Label(与 `_has` 的子串命中相对)。
func _find_label_exact(root: Node, want: String) -> Label:
	if root is Label and (root as Label).text.strip_edges() == want:
		return root
	for c in root.get_children():
		var l := _find_label_exact(c, want)
		if l != null:
			return l
	return null


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
