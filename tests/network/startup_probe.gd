extends Node

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	Level0.pvp_mode = true
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	var timings := {}
	var start := Time.get_ticks_usec()
	var level := load("res://scenes/level_0.tscn").instantiate() as Level0
	timings["instantiate_ms"] = (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	get_tree().root.add_child(level)
	get_tree().current_scene = level
	timings["scene_ready_ms"] = (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	level.reset_destructibles()
	timings["baseline_reset_ms"] = (Time.get_ticks_usec() - start) / 1000.0
	var body := level.get_node("WorldViewport/WallCollision").get_instance_id()
	start = Time.get_ticks_usec()
	await get_tree().process_frame
	await get_tree().process_frame
	timings["deferred_ms"] = (Time.get_ticks_usec() - start) / 1000.0
	timings["collision_replaced"] = body != level.get_node("WorldViewport/WallCollision").get_instance_id()
	timings.merge({"os": OS.get_name(), "arch": Engine.get_architecture_name(),
		"processor": OS.get_processor_name(), "threads": OS.get_processor_count(),
		"godot": Engine.get_version_info()["string"], "display": DisplayServer.get_name(),
		"user_data": OS.get_user_data_dir(), "map_size": [GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT],
		"wall_shapes": level.get_node("WorldViewport/WallCollision").get_child_count(),
		"memory_mb": OS.get_static_memory_usage() / 1048576.0})
	print("STARTUP PROFILE " + JSON.stringify(timings))
	print("STARTUP PROFILE OK actual map, scene, baseline reset, deferred collision")
	get_tree().quit(0)
