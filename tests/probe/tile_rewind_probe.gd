extends Node

# 瓦片回溯探针(场景级):破坏瓦片入账 → 回溯 → 砖块(网格+渲染)复原。
# 用法:godot --headless --path . res://tests/probe/tile_rewind_probe.tscn

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
	if Level0.time_field == null or lvl.get("_tile_ledger") == null:
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
	var v0: int = int(grid[cell.y][cell.x])

	# ① 录制 1s
	await _wait_ms(1000)
	var ledger = lvl.get("_tile_ledger")
	var count0: int = ledger.count()

	# ② 拆掉它(cyrm v4:破坏按 **16px 子格**算 —— 把该格 16 个子格逐一拆掉;
	#    每个子格死亡都走 on_sub_destroyed → 账本捕获;全部死光时格级网格才清零)
	for sy in 4:
		for sx in 4:
			TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 9999, "explosion")
	await _wait_ms(30)
	if int(grid[cell.y][cell.x]) != 0:
		_fail("拆砖未生效(网格值 %d)" % int(grid[cell.y][cell.x]))
	if ledger.count() <= count0:
		_fail("拆砖未入账(账本条数 %d→%d)" % [count0, ledger.count()])

	# ③ 再录 0.8s,然后按住 Shift 回溯 2s
	await _wait_ms(800)
	Input.action_press("rewind")
	await _wait_ms(2000)
	Input.action_release("rewind")
	await _wait_ms(120)

	# ④ 断言砖块复原(网格 + 渲染层 atlas)
	var v_now: int = int(grid[cell.y][cell.x])
	if v_now != v0:
		_fail("回溯后网格未复原(现 %d 期望 %d)" % [v_now, v0])
	var wall: TileMapLayer = Level0.wall_layer
	if wall != null:
		# cyrm v4:瓦片层是 **16px 子格** —— 检查该 64px 格的 16 个子格至少一个有贴图
		var painted := 0
		for sy in 4:
			for sx in 4:
				if wall.get_cell_atlas_coords(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)).x >= 0:
					painted += 1
		if painted == 0:
			_fail("回溯后渲染层该格 16 个子格全空")

	if _fails.is_empty():
		print("TILE REWIND PROBE: OK(拆砖入账/回溯网格复原/渲染复原)")
		tree.quit(0)
	else:
		print("TILE REWIND PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


func _ready() -> void:
	_run.call_deferred()
