extends Node

# UI 布局探针(阶段 2):设计系统 v1 迁移后的全页面契约。
# 每页 6 条:
#   ① 场景可加载 ② 可实例化 ③ 根(或 CanvasLayer 下第一个 Control)拿到 1920×1440 逻辑尺寸
#   ④ 根节点有子节点 ⑤ 关键节点/API 在 ⑥ 可见 Control 的 global_rect 都在逻辑屏幕内(容差 1.5，
#      ScrollContainer 的内容区不查——它本来就会被裁)。
# ★ 判据看判词;去掉什么它会红:删页面关键按钮 ⇒ ⑤;把布局写出 1920×1440 外 ⇒ ⑥;
#   页面 _ready 抛错/根类型变化 ⇒ ③④;场景路径写错 ⇒ ①。
# ★ ScrollContainer 内部不查溢出(内容高于视口是正常的);其它容器/锚点布局都查。

const EXPECTED_CHECKS := 54
const LOGICAL := Vector2(1920, 1440)
const TOL := 1.5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame

	await _screen("main_menu", "res://scenes/main_menu.tscn", func(inst: Node) -> bool:
		return inst.get_node_or_null("%StartBtn") != null)
	await _screen("settings_menu", "res://scenes/settings_menu.tscn", func(inst: Node) -> bool:
		return inst.get_node_or_null("%BackBtn") != null)
	await _screen("info_menu", "res://scenes/info_menu.tscn", func(inst: Node) -> bool:
		return inst.get_node_or_null("%BackBtn") != null)
	await _screen("beta_menu", "res://scenes/beta_menu.tscn", func(inst: Node) -> bool:
		return inst.get_node_or_null("%CardsRow") != null)
	await _screen("mp_lobby", "res://scenes/mp_lobby.tscn", func(inst: Node) -> bool:
		return inst.get_node_or_null("%NameEdit") != null)
	await _screen("editor_root", "res://scenes/editor/editor_root.tscn", func(inst: Node) -> bool:
		return inst.has_method("get_editor_canvas") and inst.call("get_editor_canvas") != null)
	await _screen("pause_menu", "res://ui/screens/pause_menu.tscn", func(inst: Node) -> bool:
		return inst.has_signal("toggled"))
	await _screen("match_result", "res://ui/screens/match_result.tscn", func(inst: Node) -> bool:
		return inst.has_method("show_result"))
	# 单机开局面板是**有意的空骨架**(内容由 main_menu._fill_sp_panel 填),不要求有子节点。
	await _screen("sp_launch_panel", "res://ui/screens/sp_launch_panel.tscn", func(inst: Node) -> bool:
		return inst is PanelContainer, false)

	_finish()


func _screen(name: String, path: String, extra: Callable, require_children: bool = true) -> void:
	var scene: PackedScene = load(path)
	_chk(scene != null, "① load(%s) 为 null" % path)
	if scene == null:
		return
	var inst: Node = scene.instantiate()
	_chk(inst != null, "② instantiate(%s) 为 null" % path)
	if inst == null:
		return
	add_child(inst)
	var root := _root_control(inst)
	if inst is Control:
		var c := inst as Control
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
		c.size = LOGICAL
	await get_tree().process_frame
	await get_tree().process_frame
	if root == null:
		_chk(false, "③ %s 找不到 Control 根" % name)
	else:
		_chk(root.size == LOGICAL, "③ %s 根 Control 尺寸不是 1920×1440(实得 %s)" % [name, str(root.size)])
	if require_children:
		_chk(inst.get_child_count() > 0, "④ %s 根节点没有子节点" % name)
	else:
		# 空骨架页:内容必须由调用方(main_menu._fill_sp_panel)填 ⇒ 场景里硬编码子节点就是回归。
		_chk(inst.get_child_count() == 0, "④ %s 空骨架页不应有硬编码子节点" % name)
	_chk(extra.is_valid() and bool(extra.call(inst)), "⑤ %s 关键节点/API 缺失" % name)
	if root != null:
		var bad := PackedStringArray()
		_walk_overflow(root, false, bad)
		_chk(bad.is_empty(), "⑥ %s 有 %d 个 Control 溢出逻辑屏幕(首个:%s)" %
				[name, bad.size(), bad[0] if not bad.is_empty() else ""])
	else:
		_chk(false, "⑥ %s 无根 Control 可查" % name)
	inst.queue_free()
	await get_tree().process_frame


func _root_control(inst: Node) -> Control:
	if inst is Control:
		return inst as Control
	for child in inst.get_children():
		if child is Control:
			return child as Control
	return null


func _walk_overflow(node: Node, inside_scroll: bool, bad: PackedStringArray) -> void:
	for child in node.get_children():
		var next_in := inside_scroll or child is ScrollContainer
		if child is Control and not inside_scroll:
			var c := child as Control
			if c.is_visible_in_tree():
				var r: Rect2 = c.get_global_rect()
				if r.position.x < -TOL or r.position.y < -TOL \
						or r.end.x > LOGICAL.x + TOL or r.end.y > LOGICAL.y + TOL:
					bad.append("%s(%.0f,%.0f,%.0f×%.0f)" % [c.name, r.position.x, r.position.y, r.size.x, r.size.y])
		_walk_overflow(child, next_in, bad)


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
	print("UI LAYOUT PROBE: ALL-OK(%d 条断言):%d 页 · 逻辑尺寸 · 关键节点 · 无溢出" % [_checks, 9])
	get_tree().quit(0)
