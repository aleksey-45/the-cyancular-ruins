extends Node

# UI 布局探针(阶段 1):页面能实例化、根是 Control 且拿到 1920×1440 逻辑尺寸、关键节点在。
# ★ 迁移后本探针会继续加「不溢出父容器 / 关键文本不被裁 / 编辑器 Split+Tab 结构」等断言;
#   现阶段只钉最小契约,防止迁移第一步就把页面实例化弄挂。
# 去掉什么它才会红:
#   ① 页面脚本 _ready 抛错 ⇒ 实例化后无子节点/关键节点缺失;
#   ② 根节点不再是 Control ⇒ 尺寸断言红;
#   ③ 逻辑分辨率约定被改(页面必须能在 1920×1440 下布局)⇒ 尺寸断言红;
#   ④ 编辑器公开 API 丢了 ⇒ get_editor_canvas 断言红。

const EXPECTED_CHECKS := 15
const LOGICAL := Vector2(1920, 1440)

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame

	await _screen("main_menu", "res://scenes/main_menu.tscn", func(inst: Control) -> void:
		_chk(inst.get_node_or_null("%StartBtn") != null, "main_menu 缺 %StartBtn"))
	await _screen("settings_menu", "res://scenes/settings_menu.tscn", func(inst: Control) -> void:
		_chk(inst.get_child_count() > 0, "settings_menu 根节点无子节点"))
	await _screen("editor_root", "res://scenes/editor/editor_root.tscn", func(inst: Control) -> void:
		_chk(inst.has_method("get_editor_canvas") and inst.call("get_editor_canvas") != null,
				"editor_root: get_editor_canvas() 为空"))

	_finish()


func _screen(name: String, path: String, extra: Callable) -> void:
	var scene: PackedScene = load(path)
	_chk(scene != null, "① load(%s) 为 null" % path)
	if scene == null:
		return
	var inst: Node = scene.instantiate()
	_chk(inst != null, "① instantiate(%s) 为 null" % path)
	if inst == null:
		return
	add_child(inst)
	if inst is Control:
		var c := inst as Control
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
		c.size = LOGICAL
	await get_tree().process_frame
	await get_tree().process_frame
	_chk(inst is Control and (inst as Control).size == LOGICAL,
			"② %s 根不是 Control 或尺寸不是 1920×1440(实得 %s)" % [name, str(inst.size)])
	_chk(inst.get_child_count() > 0, "③ %s 根节点没有子节点" % name)
	if extra.is_valid():
		extra.call(inst)
	inst.queue_free()
	await get_tree().process_frame


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		print("UI LAYOUT PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("UI LAYOUT PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("UI LAYOUT PROBE: ALL-OK(%d 条断言)" % _checks)
	get_tree().quit(0)
