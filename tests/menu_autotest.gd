extends Node

# 菜单流转自动探针(挂 root,穿越 change_scene 存活):
# 模拟 主菜单→(单人面板→开始探索 / 多人 / 设置) 的真实按钮点击流转,
# 验证场景切换、渲染链与暂停层;带窗口运行时把玩家所见截图存到 user://。
# 由 main_menu._ready 在命令行含 --autotest-* 时挂载,平时零开销:
#   -- --autotest-sp     主菜单→单机面板→开始探索→(Esc 暂停/恢复验证)→回主菜单→截图
#   -- --autotest-mp     主菜单→多人匹配页→截图
#   -- --autotest-set    主菜单→设置页→截图
#   -- --autotest-level  直接切 Level0(只验世界加载,不经过菜单流转)

var mode := ""   # sp / mp / set / level / ver(由 main_menu 经 cmdline 参数注入)

func _ready() -> void:
	_run()


func _run() -> void:
	var tree := get_tree()
	await tree.create_timer(1.2).timeout   # 等浮现动画
	if mode == "level":
		tree.change_scene_to_file("res://scenes/Level0.tscn")
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
	# ★ 硬断言(sp):点了「开始探索」必须**真的进了 Level0**。
	# 少了这条,本探针会「假通过」:唯一的硬断言是末尾「回主菜单后 = main_menu.tscn」,
	# 而"从没离开过主菜单"(菜单文案被改 → 找不到按钮 → 一次都没点到)正好满足它。
	_dump_render_chain(tree, cur)
	if mode == "sp" and (cur == null or not cur.scene_file_path.ends_with("Level0.tscn")):
		print("AUTOTEST[sp]: 未进入 Level0(实际 %s)——菜单流转断在按钮文案上?" % [
			cur.scene_file_path if cur != null else "<null>"])
		tree.quit(1)
		return
	if mode == "sp":
		await _verify_pause(tree)
		await _verify_go_menu(tree)
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
	_save_root_png(tree, "user://autotest_sp_pause.png")
	_press_esc()
	await tree.create_timer(0.5).timeout
	print("AUTOTEST: 再Esc后 paused=", tree.paused, "(应为 false)")


# 回主菜单验证(safe_change_scene 路径):开暂停层点「回 到 主 菜 单」,场景应回到 main_menu
func _verify_go_menu(tree: SceneTree) -> void:
	_press_esc()
	await tree.create_timer(0.4).timeout
	_press_by_text(tree.current_scene, "回到主菜单")
	await tree.create_timer(1.5).timeout
	var cur := tree.current_scene
	var ok := cur != null and cur.scene_file_path.ends_with("main_menu.tscn")
	print("AUTOTEST: 回主菜单后场景 = %s %s" % [
		cur.scene_file_path if cur != null else "<null>", "(OK)" if ok else "(失败!应回到 main_menu.tscn)"])
	if not ok:
		tree.quit(1)


# 注入一次 Esc(ui_cancel)
func _press_esc() -> void:
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)


# 截取玩家所见(root 视口)存档;headless 无视口纹理,安全跳过
func _shot(tree: SceneTree, file: String) -> void:
	await tree.process_frame
	await tree.process_frame
	# 只有真的存下去了才报「已存」——headless 跳过时不该声称存了(原实现无条件打印)
	if _save_root_png(tree, "user://" + file):
		print("AUTOTEST: 截图已存 user://" + file)


# 存 root 视口 PNG;返回是否真的写了文件(调用方据此决定要不要报「已存」)。
func _save_root_png(tree: SceneTree, path: String) -> bool:
	# headless(dummy 渲染后端)的 root 视口纹理是空壳:get_image() 会在引擎侧打
	#   ERROR: Parameter "t" is null
	# 污染 CI 的 `grep -ci error` 判读(该判据本要用来抓"场景报错"),故先行跳过。
	# 该分支只在 headless 成立 → 带窗口跑 GUI 的行为完全不受影响。
	if DisplayServer.get_name() == "headless":
		print("AUTOTEST: headless(dummy 后端)无视口纹理,跳过截图 ", path)
		return false
	var tex := tree.root.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		print("AUTOTEST: 取不到视口纹理,跳过截图 ", path)
		return false
	img.save_png(path)
	return true


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
