extends SceneTree

# 角色梯子攀爬逻辑探针：
# 在实际地图梯子处生成玩家实体并模拟向上移动输入，验证角色移动轨迹、卡墙检测及是否能正常登顶。
# 运行方式："$GODOT" --headless --path . -s res://tests/probe/climb_probe.gd

func _initialize() -> void:
	TileDefs.load_defs()
	var grid: Array[Array] = MazeGenerator.load_map_file()
	MazeGenerator.current_grid = grid

	# 构建真实墙体碰撞（验证 78px 宽角色碰撞盒攀爬 64px 梯子时是否存在阻挡或卡顿）
	var host := Node2D.new()
	host.name = "PerfHost"
	root.add_child(host)
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), host, "WallCollision")
	CollisionBuilder.build_destructible_chunks(CollisionBuilder.build_sub(grid, true), host)
	CollisionBuilder.build_climb_ledges(grid, host)

	var player_scene: PackedScene = load("res://scenes/player/player.tscn")
	var p = player_scene.instantiate()
	root.add_child(p)

	# 测试场景：第 5 至 8 行梯子位于第 80 列（相邻第 76 至 79 列为墙体）。将玩家置于梯子底部（第 8 行第 80 列）。
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
			# 检测角色停滞：若连续多帧坐标无位移则判定为停滞
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
