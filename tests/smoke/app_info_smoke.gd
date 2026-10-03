extends SceneTree

# `AppInfo` 的 `-s` 冒烟。
# 跑法: "$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
# 判据: 文本 `APP INFO SMOKE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:两个函数从 `main_menu.gd` 搬到了这里,而 `version_string()` 有一个
#   **只在这个仓里成立**的分支 —— 发布版读 `build_info.gd`、开发版回落到 git。
#   搬错了(比如漏了 `--nover` 的收口)不会有任何编译错误,只表现为"版本号显示得不对"。
var _fails: Array[String] = []


func _initialize() -> void:
	var script := load("res://core/config/app_info.gd")
	if script == null:
		print("APP INFO SMOKE: FAIL(load 不到 core/config/app_info.gd)")
		quit(1)
		return
	var s: String = script.version_string()
	var log: Array = script.commit_log()
	if s.strip_edges() == "":
		_fails.append("version_string() 返回空串")
	# ★ 这一条钉的是"它真的**接**到了 git/build_info 之一",而不是恒返回占位串。
	#   把函数体改成 `return "x"` ⇒ 它照样过 —— 这条断言**给不了**那个保证,如实登记。
	if not (s == "dev" or s.contains("#") or s.contains("v") or s.length() >= 3):
		_fails.append("version_string() 的形状可疑:「%s」" % s)
	if log.size() > 20:
		_fails.append("commit_log() 超过 20 条(%d)" % log.size())
	for e in log:
		if typeof(e) != TYPE_DICTIONARY or not ((e as Dictionary).has("hash")
				and (e as Dictionary).has("time") and (e as Dictionary).has("subject")):
			_fails.append("commit_log() 的元素缺字段:%s" % str(e))
			break
	if _fails.is_empty():
		print("APP INFO SMOKE: ALL-OK(version=「%s」, commits=%d)" % [s, log.size()])
		quit(0)
	else:
		print("APP INFO SMOKE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		quit(1)
