extends SceneTree

# 破坏机制诊断:隔离验证 tile_defs.json 加载 + damage_tile 逻辑(无需完整游戏)。
# 用法:godot --headless --path . -s res://Tests/tile_destroy_probe.gd

func _init() -> void:
	TileDefs.load_defs()
	print("[probe] bullet_destroyable(15) = ", TileDefs.bullet_destroyable(15))
	print("[probe] explosion_destroyable(15) = ", TileDefs.explosion_destroyable(15))
	print("[probe] hp_of(15) = ", TileDefs.hp_of(15))
	print("[probe] type_of(15) = ", TileDefs.type_of(15))
	print("[probe] climb_speed(11) = ", TileDefs.climb_speed(11))
	print("[probe] explosion_destroyable(19) = ", TileDefs.explosion_destroyable(19))
	print("[probe] hp_of(19) = ", TileDefs.hp_of(19))
	print("[probe] hp_of(15) = ", TileDefs.hp_of(15))
	print("[probe] 319/16 = ", 319 / 16)

	var grid: Array[Array] = []
	for r in range(4):
		var row: Array[int] = []
		for c in range(4):
			row.append(0)
		grid.append(row)
	grid[1][1] = MazeGenerator.pack(15, 15)  # 树叶-1 全砖
	grid[1][2] = MazeGenerator.pack(19, 15)  # 树干竖 全砖
	MazeGenerator.current_grid = grid
	TileDefs.init_hp(grid)

	var destroyed := TileDefs.damage_tile(Vector2i(1, 1), 10, "bullet")
	print("[probe] 树叶打10伤后破坏? ", destroyed, "  grid=", grid[1][1])
	destroyed = TileDefs.damage_tile(Vector2i(1, 1), 10, "bullet")
	print("[probe] 树叶再打10伤后破坏? ", destroyed, "  grid=", grid[1][1])
	print("[probe] hp_grid[1][2] = ", TileDefs.hp_grid[1][2])
	destroyed = TileDefs.damage_tile(Vector2i(2, 1), 10, "bullet")
	print("[probe] 树干被子弹打10? ", destroyed, "  grid=", grid[1][2], "  hp=", TileDefs.hp_grid[1][2])
	destroyed = TileDefs.damage_tile(Vector2i(2, 1), 80, "explosion")
	print("[probe] 树干被爆炸打80? ", destroyed, "  grid=", grid[1][2], "  hp=", TileDefs.hp_grid[1][2])

	quit(0)
