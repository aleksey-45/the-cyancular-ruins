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
#   = 17
# ★ 注意这是**运行时**条数:静态 `grep -c '^\s*_check('` 只会数到 9(循环里的 9 条看不见),
#   故别拿 grep 的数来对这里 —— 它俩本来就对不上。
const EXPECTED_CHECKS := 17

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
	host.free()
	_finish()


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
