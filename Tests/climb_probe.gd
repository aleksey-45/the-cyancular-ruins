extends SceneTree

# 攀爬诊断:把真实玩家放到 demo 地图的梯子上,模拟按上,追踪它停在哪、能否到顶。
# 用法:godot --headless --path . -s res://Tests/climb_probe.gd

func _initialize() -> void:
	TileDefs.load_defs()
	var grid: Array[Array] = MazeGenerator.load_map_file()
	MazeGenerator.current_grid = grid

	# 真实墙体碰撞(验证 78px 宽碰撞箱爬 64px 梯子会不会卡墙)
	var host := Node2D.new()
	host.name = "PerfHost"
	root.add_child(host)
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), host, "WallCollision")
	CollisionBuilder.build_destructible_chunks(CollisionBuilder.build_sub(grid, true), host)
	CollisionBuilder.build_climb_ledges(grid, host)

	var player_scene: PackedScene = load("res://Scenes/Player/Player.tscn")
	var p = player_scene.instantiate()
	root.add_child(p)

	# 场景:r5-r8 的梯子在 c80(贴墙 c76-79)。玩家放 r8 c80(梯子底部)。
	p.global_position = Vector2(80 * 64 + 32, 8 * 64 + 32)
	await physics_frame
	print("[climb] 起点 y=", p.global_position.y, " cell=",
			MazeGenerator.cell_of(p.global_position, 64, 125, 75))
	Input.action_press("up")
	var prev_y: float = p.global_position.y
	for i in range(90):
		await physics_frame
		var y: float = p.global_position.y
		if absf(y - prev_y) < 0.01 and i > 3:
			# 卡住:连续几帧不动
			var stuck_frames := 0
			for j in range(10):
				await physics_frame
				if absf(p.global_position.y - y) < 0.01:
					stuck_frames += 1
			print("[climb] 卡住 @ frame %d y=%.1f(脚距顶 %dpx) latched=%s cell=%s" % [
				i, y, int(y + 57 - 5 * 64), p.get("_latched"),
				MazeGenerator.cell_of(p.global_position, 64, 125, 75)])
			break
		prev_y = y
		if i % 10 == 0:
			print("[climb] frame %d y=%.1f latched=%s on_floor=%s" % [i, y, p.get("_latched"), p.is_on_floor()])
	Input.action_release("up")
	print("[climb] 结束 y=%.1f cell=%s" % [p.global_position.y,
			MazeGenerator.cell_of(p.global_position, 64, 125, 75)])
	p.free()
	quit(0)
