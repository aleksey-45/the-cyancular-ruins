extends Node

# 时空地图端到端探针:加载 timetest.cyrm(含时间线)→ 快进世界钟 → 断言
#  ① 时间线解析(w0/事件数);② T-15 坍塌:桥区网格变实心+渲染层铺砖;
#  ③ T-10 炸开:密室墙变空气。打印 TIME MAP PROBE: OK/FAIL。

func _ready() -> void:
	_run()

func _run() -> void:
	var tree := get_tree()
	await tree.process_frame   # _ready 期间 parent 忙,等一帧再挂子节点
	RunOptions.map_file = "timetest.cyrm"
	var lvl: Node = load("res://Scenes/Level0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 12:
		await tree.process_frame
	var fails: Array[String] = []

	var tw = lvl.get("_timeworld")
	if tw == null:
		fails.append("timeworld 未创建(时间线未解析)")
		print("TIME MAP PROBE: FAIL " + "; ".join(fails))
		tree.quit(1)
		return
	if absf(float(tw.w0) - 25.0) > 0.01:
		fails.append("w0=%s 期望 25" % str(tw.w0))
	if tw.events.size() != 2:
		fails.append("事件数 %d 期望 2" % tw.events.size())

	var solid: int = MazeGenerator.SOLID
	var empty: int = MazeGenerator.EMPTY
	var grid: Array = lvl.get("_grid_ref")

	# T-15 前:桥区应为空
	if grid[25][30] != empty:
		fails.append("开局时桥区(x30,y25)应為空气")
	# 快进 12s(w 25→13,跨越 15)→ 坍塌
	lvl._tick_world(12.0)
	if grid[25][30] != solid:
		fails.append("坍塌后桥区(x30,y25)未变实心")
	var wl: TileMapLayer = lvl.get("wall_layer")
	if wl == null or wl.get_cell_source_id(Vector2i(30, 25)) == -1:
		fails.append("坍塌瓦片未铺渲染层(中央副本)")
	# 快进 12s(w 13→1,跨越 10)→ 密室炸开
	lvl._tick_world(12.0)
	if grid[25][46] != empty:
		fails.append("炸开后密室墙(x46,y25)未变空气")
	if wl.get_cell_source_id(Vector2i(46, 25)) != -1:
		fails.append("炸开后密室墙瓦片未清除")

	if fails.is_empty():
		print("TIME MAP PROBE: OK(解析/坍塌/炸开/渲染)")
		tree.quit(0)
	else:
		for f in fails:
			push_error("TIME MAP PROBE FAIL: " + f)
		print("TIME MAP PROBE: FAIL")
		tree.quit(1)
