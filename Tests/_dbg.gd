extends SceneTree
func _initialize() -> void:
	var path := "res://map/timetest.cyrm"
	print("exists=", FileAccess.file_exists(path))
	MazeGenerator.set_map_file(path)
	var grid := MazeGenerator.load_map_file()
	print("rows=", grid.size())
	var tw: TimeWorld = TimeWorld.parse_for(path)
	print("events=", tw.events.size(), " w0=", tw.w0)
	quit(0)
