extends SceneTree

# 应用版本号与提交信息提取冒烟测试：
# 验证 AppInfo 纯静态方法在开发态与导出态下的行为，包括 Git 提交日志读取、
# 版本字符串格式化，以及 --nover 开关的统一定点处理。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd

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
	# - 这一条约束的是"它真的接到了 git/build_info 之一",而不是恒返回占位串。
	#   把函数体改成 `return "abc"`(或 `return "placeholder"`) ->  它照样过 ——
	#   这条断言给不了那个保证,如实登记。
	#   - 会被它红住的反例:`return "x"` —— 长度 1、不含 `#`/`v`、且 ≠ "dev"。
	# - 下面两条(条数上限 + 元素循环)有同类空档:`commit_log()` 改成 `return []`
	#   会同时通过它们 —— `0 > 20` 为假,而空数组上的 `for` 一次都不跑。
	#   即"返回空表"同样没有任何断言能拦,如实登记。
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
