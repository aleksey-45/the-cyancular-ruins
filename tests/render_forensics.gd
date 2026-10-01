extends Node

# 渲染取证(窗口模式跑,非 headless —— 要真实画面):
#   godot --path . res://tests/render_forensics.tscn -- --map=newfactory.cyrm
# 加载指定地图的 Level0,2s/5s/8s 各拍一张全屏截图到 user://,供逐帧比对
# "前景时有时无 / 水面发白" 这类纯视觉问题。头less 模式无画面,勿加 --headless。

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
	# 找一格水,把玩家传送过去(相机跟随),拍"泡在水里"的画面
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
