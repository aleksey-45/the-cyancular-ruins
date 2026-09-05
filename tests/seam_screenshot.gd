extends SceneTree
# 接缝可视化: 玩家在右端(W-100),敌人在左端(100)——环面上仅相距 200。
# A = 旧行为: 从 player 组摘掉锚点 → _wrap 回退绝对取模,敌人停远副本(100)→ 屏外消失。
# B = 修复后: 锚点回归 → _wrap 锚定到玩家最近副本(2500)→ 屏内可见。
# 需要真实渲染(非 --headless):  `Godot --path . -s Tests/seam_screenshot.gd`

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

	# 玩家锚点(供 _wrap 读 group)
	var anchor := Node2D.new()
	anchor.global_position = Vector2(W - 100, 200)
	vp.add_child(anchor)

	# 接缝参考线: x=0 与 x=W
	for sx in [0.0, W]:
		var line := ColorRect.new()
		line.size = Vector2(4, 400)
		line.position = Vector2(sx - 2, 0)
		line.color = Color(1, 0.3, 0.3, 0.9)
		vp.add_child(line)

	# 敌人: 物理上在左端副本(100),环面上紧挨玩家
	var scene: PackedScene = load("res://scenes/enemies/EnemyJumpBird.tscn")
	var e = scene.instantiate()
	vp.add_child(e)
	e.global_position = Vector2(100, 200)

	await process_frame
	cam.make_current()          # 入树后再设为当前相机
	cam.global_position = Vector2(W - 100, 200)

	# ── A: 旧行为(无玩家组 → 绝对取模,停在 100,屏外) ──
	anchor.remove_from_group("player")
	await process_frame
	await process_frame
	var img_a := vp.get_texture().get_image()
	img_a.save_png("res://tests/_seam_a_old.png")
	print("A: 无锚点,敌人位置=", e.global_position, " → 应屏外消失")

	# ── B: 修复后(锚点回归 → 锚定玩家最近副本 2500,屏内) ──
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
