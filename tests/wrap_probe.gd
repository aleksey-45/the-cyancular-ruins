extends SceneTree
# 验证鸟跟随玩家回绕: 玩家跨接缝后,鸟应落在玩家附近,不跳远。

class FakePlayer:
	extends Node2D
	func _init() -> void:
		add_to_group("player")

func _initialize() -> void:
	print("── wrap_probe 开始 ──")
	var gp: Node = root.get_node("GameParameters")
	var grid = MazeGenerator.load_map_file()
	gp.set("MAP_WIDTH", grid[0].size() * gp.get("TILE_SIZE"))
	gp.set("MAP_HEIGHT", grid.size() * gp.get("TILE_SIZE"))
	var W: float = gp.get("MAP_WIDTH")
	var H: float = gp.get("MAP_HEIGHT")
	print("地图尺寸: ", W, " x ", H)

	var player := FakePlayer.new()
	root.add_child(player)

	var scene: PackedScene = load("res://scenes/enemies/EnemyJumpBird.tscn")
	var e = scene.instantiate()
	root.add_child(e)
	await physics_frame

	# 场景1: 鸟在接缝前(近右端),玩家跨到左端
	player.global_position = Vector2(50, 500)
	e.global_position = Vector2(W - 100, 500)  # 鸟在右端
	await physics_frame
	e.call("_wrap")
	await physics_frame
	var dx1: float = e.global_position.x - player.global_position.x
	print("场景1: 鸟 x=", e.global_position.x, " 玩家 x=", player.global_position.x,
			" 相距=", dx1)
	# 鸟应落在玩家附近(相距 < 半地图)
	var ok1: bool = absf(dx1) < W * 0.5

	# 场景2: 鸟在接缝后(近左端),玩家在右端
	player.global_position = Vector2(W - 50, 500)
	e.global_position = Vector2(100, 500)  # 鸟在左端
	await physics_frame
	e.call("_wrap")
	await physics_frame
	var dx2: float = e.global_position.x - player.global_position.x
	print("场景2: 鸟 x=", e.global_position.x, " 玩家 x=", player.global_position.x,
			" 相距=", dx2)
	var ok2: bool = absf(dx2) < W * 0.5

	print("场景1 跟随=", ok1, " 场景2 跟随=", ok2)
	if ok1 and ok2:
		print("WRAP-OK: 鸟跟随玩家回绕,不再跳远副本")
	else:
		print("WRAP-FAIL")
	quit(0)
