extends Node

# 画面渲染与视觉比对探针（需以窗口化渲染模式运行，请勿添加 --headless 参数以保证视口正常渲染）：
#   godot --path . res://tests/probe/render_forensics.tscn --map=newfactory.cyrm
# 加载指定地图的 Level0 场景，分别在 2 秒、5 秒与 8 秒节点捕获完整视口截图并输出至 user:// 目录，
# 用于离线比对前景层图层遮挡、水面着色渲染等视觉表现。

var _map := "demo.cyrm"
var _shots := [120, 300, 480]
var _f := 0
var _si := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			_map = a.substr(6)
	_run.call_deferred()


func _run() -> void:
	MazeGenerator.set_map_file("res://maps/" + _map)
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	get_tree().root.add_child(lvl)
	for i in 30:
		await get_tree().physics_frame
	# 检索水体瓦片坐标并将玩家传送至水域内部（相机自动跟随），采集浸入水体时的视觉渲染画面
	var grid: Array[Array] = MazeGenerator.current_grid
	var water_cells := 0
	var ts := GameParameters.TILE_SIZE
	var pl: Node2D = lvl.get_node_or_null("WorldViewport/Player") as Node2D
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			if Water.is_liquid(MazeGenerator.texture_of(grid[y][x])):
				water_cells += 1
				if water_cells == 1 and pl != null:
					pl.global_position = Vector2(x * ts + ts * 0.5, y * ts + ts * 0.5)
	print("FORENSICS: 水体格 %d,水面瓦片 %d" % [water_cells,
			(lvl.get_node("WorldViewport/WaterLayer") as TileMapLayer).get_used_cells().size()])
	while _si < _shots.size():
		await get_tree().physics_frame
		_f += 1
		if _f >= int(_shots[_si]):
			var img := get_viewport().get_texture().get_image()
			var path := "user://forensics_%s_%d.png" % [_map.get_basename(), int(_shots[_si])]
			img.save_png(path)
			print("FORENSICS: saved %s" % ProjectSettings.globalize_path(path))
			_si += 1
	print("FORENSICS: done")
	get_tree().quit(0)
