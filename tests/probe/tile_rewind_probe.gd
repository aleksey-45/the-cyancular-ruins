extends Node

# 瓦片回溯探针(场景级):破坏瓦片入账 -> 回溯 -> 砖块(网格+渲染)复原。

var _fails: Array[String] = []


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	await _wait_ms(400)
	if Level0.time_field == null or lvl.get("terrain") == null:
		print("TILE REWIND PROBE: FAIL(时间系统未就绪)")
		tree.quit(1)
		return

	# 找一格可被爆炸破坏的砖(树叶/树干)
	var grid: Array = MazeGenerator.current_grid
	var cell := Vector2i(-1, -1)
	for y in grid.size():
		if cell.x >= 0:
			break
		for x in grid[0].size():
			var v: int = grid[y][x]
			if v != 0 and TileDefs.explosion_destroyable(MazeGenerator.texture_of(v)):
				cell = Vector2i(x, y)
				break
	if cell.x < 0:
		print("TILE REWIND PROBE: FAIL(图上没有可破坏砖)")
		tree.quit(1)
		return
	var v0: int = int(MazeGenerator.current_grid[cell.y][cell.x])
	var probe_sub := Vector2i(-1, -1)
	for sy in 4:
		for sx in 4:
			var candidate := cell * 4 + Vector2i(sx, sy)
			if probe_sub.x < 0 and TileDefs.sub_alive(candidate):
				probe_sub = candidate
	var original_hp: int = TileDefs.hp_grid[cell.y][cell.x]
	TileDefs.restore_sub(probe_sub, TileDefs.terrain.get_hp(probe_sub))
	if TileDefs.hp_grid[cell.y][cell.x] != original_hp:
		_fail("恢复相同子格 HP 不得改变格级 HP")

	# ① 录制 1s
	await _wait_ms(1000)
	var ledger: NativeTerrain = lvl.get("terrain")
	var count0: int = ledger.rewind_count()
	var original := TileDefs.capture_terrain_cell(cell)
	TileDefs.damage_tile(cell, 1, "explosion")
	TileDefs.damage_sub(probe_sub, 1, "bullet")
	await _wait_ms(400)
	var partial := TileDefs.capture_terrain_cell(cell)

	# ② 走光束类武器使用的格级入口；所有存活子格都应进入同一账本。
	TileDefs.damage_tile(cell, 9999, "explosion")
	for sy in 4:
		for sx in 4:
			if TileDefs.sub_alive(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)):
				_fail("格级破坏留下存活子格")
	await _wait_ms(30)
	if int(MazeGenerator.current_grid[cell.y][cell.x]) != 0:
		_fail("拆砖未生效(网格值 %d)" % int(MazeGenerator.current_grid[cell.y][cell.x]))
	if ledger.rewind_count() <= count0:
		_fail("拆砖未入账(账本条数 %d→%d)" % [count0, ledger.rewind_count()])

	# ③ 再录 0.8s,然后按住 Shift 回溯 2s
	await _wait_ms(800)
	Input.action_press("rewind")
	var observed_partial := false
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 2000:
		await tree.process_frame
		if TileDefs.capture_terrain_cell(cell) == partial:
			observed_partial = true
	Input.action_release("rewind")
	await _wait_ms(120)
	if not observed_partial:
		_fail("真实回溯过程没有经过破坏前的残血状态")

	# ④ 断言砖块复原(网格 + 渲染层 atlas)
	var v_now: int = int(MazeGenerator.current_grid[cell.y][cell.x])
	if v_now != v0:
		_fail("回溯后网格未复原(现 %d 期望 %d)" % [v_now, v0])
	if TileDefs.capture_terrain_cell(cell) != original:
		_fail("回溯后没有精确恢复损伤前的格级与子格 HP")
	var wall: TileMapLayer = Level0.wall_layer
	if wall != null:
		# cyrm v4:瓦片层是 16px 子格 —— 检查该 64px 格的 16 个子格至少一个有贴图
		var painted := 0
		for sy in 4:
			for sx in 4:
				if wall.get_cell_atlas_coords(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)).x >= 0:
					painted += 1
		if painted == 0:
			_fail("回溯后渲染层该格 16 个子格全空")
	# 合成混纹理格，永久子格不能因邻近可破坏纹理的格级命中而消失。
	var permanent_tex := 0
	for tex in range(1, TileDefs.MAX_TEXTURE + 1):
		if TileDefs.type_id_of(tex) == TileDefs.TYPE_WALL and not TileDefs.explosion_destroyable(tex):
			permanent_tex = tex
			break
	var mixed_grid := MazeGenerator.current_grid.duplicate(true)
	var mixed_subgrid := MazeGenerator.current_subgrid.duplicate(true)
	mixed_subgrid[probe_sub.y][probe_sub.x] = permanent_tex
	TileDefs.load_terrain(mixed_grid, mixed_subgrid)
	TileDefs.damage_tile(cell, 9999, "explosion")
	if not TileDefs.sub_alive(probe_sub) or MazeGenerator.current_grid[cell.y][cell.x] == 0:
		_fail("混纹理格的永久子格被连带摧毁")

	if _fails.is_empty():
		print("TILE REWIND PROBE: OK(残血中间态/完整 HP 历史/网格与渲染复原)")
		tree.quit(0)
	else:
		print("TILE REWIND PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


func _ready() -> void:
	_run.call_deferred()
