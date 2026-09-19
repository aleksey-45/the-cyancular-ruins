extends SceneTree

# 玩家拆砖入史回归探针(-s 场景级):
#   复现"榴弹炸树叶"路径——时空图激活时 TileDefs.damage_tile → Level0._on_tile_destroyed
#   捕获改前值(wall_layer.get_cell_atlas_coords)→ 帧末合并入账本。曾因误用不存在的
#   TileMapLayer.get_cell 崩溃(2026-09-20 用户榴弹实测报错),此探针钉死该回归。
# 用法:godot --headless --path . -s res://Tests/time_player_ops_probe.gd

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	MazeGenerator.set_map_file("res://map/timetest2.cyrt")
	change_scene_to_file("res://Scenes/Level0.tscn")
	# 等 Level0 入树 + 世界构建(瓦片铺完才有"改前贴图"可读)
	for i in 8:
		await process_frame
	var level: Node = current_scene
	if level == null or level.get("_timeworld") == null:
		print("TIME PLAYER OPS PROBE: FAILED(Level0 未加载)")
		quit(1)
		return
	var tl: TimeWorld = level._timeworld
	var before: int = tl.timeline.size()
	# 找一个子弹可破坏的树叶格,模拟榴弹直击
	var grid: Array = MazeGenerator.current_grid
	var cell := Vector2i(-1, -1)
	for y in grid.size():
		if cell.x >= 0:
			break
		for x in grid[0].size():
			if TileDefs.bullet_destroyable(MazeGenerator.texture_of(grid[y][x])):
				cell = Vector2i(x, y)
				break
	if cell.x < 0:
		print("TIME PLAYER OPS PROBE: FAILED(图里没有可破坏砖)")
		quit(1)
		return
	TileDefs.damage_tile(cell, 999, "bullet")
	# 过两帧:第一帧捕获进 _tl_pending,第二帧 _process 帧末冲账入史
	await process_frame
	await process_frame
	var pending: int = level._tl_pending.size()
	var after: int = tl.timeline.size()
	var ok := pending == 0 and after == before + 1
	var entry: Dictionary = tl.timeline.entries[0] if ok else {}
	var origin_ok := ok and str(entry.get("origin", "")) == TimeTimeline.ORIGIN_PLAYER \
			and str((entry["inv"] as Dictionary).get("op", "")) == "restore_cells"
	print("TIME PLAYER OPS PROBE: ", "OK(拆砖入史/改前值捕获/逆操作restore_cells)"
			if origin_ok else "FAILED(pending=%d before=%d after=%d)" % [pending, before, after])
	quit(0 if origin_ok else 1)
