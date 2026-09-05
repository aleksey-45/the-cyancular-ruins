extends Node

# 菜单流转自动探针(挂 root,穿越 change_scene 存活):
# 模拟 主菜单→(单人面板→开始探索 / 多人 / 设置) 的真实按钮点击流转,
# 验证场景切换、渲染链与暂停层;带窗口运行时把玩家所见截图存到 user://。
# 由 main_menu._ready 在命令行含 --autotest-* 时挂载,平时零开销:
#   -- --autotest-sp     主菜单→单机面板→开始探索→(Esc 暂停/恢复验证)→截图
#   -- --autotest-mp     主菜单→多人匹配页→截图
#   -- --autotest-set    主菜单→设置页→截图
#   -- --autotest-level  直接切 Level0(隔离菜单演示残留)

var mode := ""   # sp / mp / set / level(由 main_menu 经 cmdline 参数注入)

func _ready() -> void:
	_run()


func _run() -> void:
	var tree := get_tree()
	await tree.create_timer(1.2).timeout   # 等浮现动画
	if mode == "level":
		tree.change_scene_to_file("res://Scenes/Level0.tscn")
	elif mode == "sp":
		_press_by_text(tree.current_scene, "单 人 模 式")
		await tree.create_timer(0.4).timeout
		_press_by_text(tree.current_scene, "开 始 探 索")
	elif mode == "mp":
		_press_by_text(tree.current_scene, "多 人 对 战")
	elif mode == "set":
		_press_by_text(tree.current_scene, "设 置")
	elif mode == "ver":
		_press_by_text(tree.current_scene, "版 本 信 息")
	await tree.create_timer(1.5).timeout
	var cur := tree.current_scene
	print("AUTOTEST[%s]: 当前场景 = %s" % [mode, cur.scene_file_path if cur != null else "<null>"])
	_dump_render_chain(tree, cur)
	if mode == "sp":
		await _verify_pause(tree)
	await _shot(tree, "autotest_%s.png" % mode)
	print("AUTOTEST[%s]: DONE" % mode)
	tree.quit(0)


# 渲染链诊断:WorldViewport 尺寸/子节点、PostProcess、WallLayer 单元数
func _dump_render_chain(tree: SceneTree, cur: Node) -> void:
	if cur != null and cur.get_node_or_null("WorldViewport") != null:
		var wv: SubViewport = cur.get_node("WorldViewport")
		print("AUTOTEST: WorldViewport size=", wv.size, " update_mode=", wv.render_target_update_mode)
		for c in wv.get_children():
			print("  world child: ", c.name, " [", c.get_class(), "]")
		var wl: TileMapLayer = wv.get_node_or_null("WallLayer")
		print("AUTOTEST: WallLayer used_cells=", wl.get_used_cells().size() if wl != null else "null")
	var pp := tree.get_first_node_in_group("post_process")
	print("AUTOTEST: post_process=", pp)


# 暂停层验证:注入 Esc → 树应暂停;再 Esc → 恢复
func _verify_pause(tree: SceneTree) -> void:
	_press_esc()
	await tree.create_timer(0.5).timeout
	print("AUTOTEST: Esc后 paused=", tree.paused, "(应为 true)")
	await tree.process_frame
	await tree.process_frame
	tree.root.get_texture().get_image().save_png("user://autotest_sp_pause.png")
	_press_esc()
	await tree.create_timer(0.5).timeout
	print("AUTOTEST: 再Esc后 paused=", tree.paused, "(应为 false)")


# 注入一次 Esc(ui_cancel)
func _press_esc() -> void:
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)


# 截取玩家所见(root 视口)存档
func _shot(tree: SceneTree, file: String) -> void:
	await tree.process_frame
	await tree.process_frame
	tree.root.get_texture().get_image().save_png("user://" + file)
	print("AUTOTEST: 截图已存 user://" + file)


# 按文字前缀找按钮并触发(去空格匹配;浮现动画不阻塞 pressed)
func _press_by_text(n: Node, prefix: String) -> void:
	if n == null or not is_instance_valid(n):
		return
	for c in n.get_children():
		if c is Button and str((c as Button).text).replace(" ", "").begins_with(prefix.replace(" ", "")):
			print("AUTOTEST: 点击 \"%s\"" % (c as Button).text)
			(c as Button).pressed.emit()
			return
		_press_by_text(c, prefix)
