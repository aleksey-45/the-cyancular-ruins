extends SceneTree
# 环面地图接缝渲染可视化测试：
# 玩家位于地图右端（W-100），敌人物理位置位于左端（100），环面拓扑最短距离仅为 200px。
# 对比两种处理模式：
#   A（未启用锚定）：缺失玩家组锚点时回退至绝对坐标取模，敌人保留在左侧（100），处于视口范围外；
#   B（启用就近锚定）：通过 GridPathfinder.anchor_to_nearest 锚定至相对玩家最近的环面副本位置（2500），视口内正常可见。
# 运行方式（需启用图形渲染，非无头模式）：
#   "$GODOT" --path . -s res://tests/scripts/seam_screenshot.gd

func _initialize() -> void:
	var autoload := root.get_node("GameParameters")
	var W := 2400.0
	var H := 1600.0
	autoload.set("MAP_WIDTH", W)
	autoload.set("MAP_HEIGHT", H)

	var vp := SubViewport.new()
	vp.size = Vector2i(800, 400)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var cam := Camera2D.new()
	vp.add_child(cam)

	# 玩家位置锚点（供 _wrap 逻辑检索 player 分组）
	var anchor := Node2D.new()
	anchor.global_position = Vector2(W - 100, 200)
	vp.add_child(anchor)

	# 绘制地图接缝参考线（x=0 与 x=W）
	for sx in [0.0, W]:
		var line := ColorRect.new()
		line.size = Vector2(4, 400)
		line.position = Vector2(sx - 2, 0)
		line.color = Color(1, 0.3, 0.3, 0.9)
		vp.add_child(line)

	# 敌人物理坐标位于左端（100），环面拓扑距离紧邻玩家
	var scene: PackedScene = load("res://scenes/enemies/enemy_jump_bird.tscn")
	var e = scene.instantiate()
	vp.add_child(e)
	e.global_position = Vector2(100, 200)

	await process_frame
	cam.make_current()          # 挂载至场景树后激活为主摄像机
	cam.global_position = Vector2(W - 100, 200)

	# ── 测试阶段 A：移除锚点，验证回退至绝对取模坐标（视口外） ──
	anchor.remove_from_group("player")
	await process_frame
	await process_frame
	var img_a := vp.get_texture().get_image()
	img_a.save_png("res://tests/_seam_a_old.png")
	print("A: 无锚点,敌人位置=", e.global_position, " → 应屏外消失")

	# ── 测试阶段 B：恢复锚点，验证实体平滑锚定至最近渲染副本（视口内可见） ──
	anchor.add_to_group("player")
	await process_frame
	await process_frame
	var img_b := vp.get_texture().get_image()
	img_b.save_png("res://tests/_seam_b_fixed.png")
	print("B: 有锚点,敌人位置=", e.global_position, " → 应屏内(W 右侧副本)")

	anchor.add_to_group("player")
	print("敌人到玩家(环面)距离=", MazeGenerator.toroidal_delta_px(
			e.global_position, anchor.global_position, W, H))
	quit()
