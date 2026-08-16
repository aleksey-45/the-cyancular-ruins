class_name EnemySpawner
extends Node2D

# 类型注册表:加新敌人 = 一个 .tscn + 一行(string 路径,load() 时取)。
const TYPES: Dictionary = {
	"jump_bird": "res://Scenes/Enemies/EnemyJumpBird.tscn",
}

# 在 grid 的空位里随机取 count 个、且距 player_cell 的环面距离 >= min_dist_cells 的格子。
static func sample_spawn_cells(grid: Array[Array], player_cell: Vector2i,
		count: int, min_dist_cells: int) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			if grid[y][x] == MazeGenerator.EMPTY:
				empty.append(Vector2i(x, y))
	var chosen: Array[Vector2i] = []
	var pool: Array[Vector2i] = empty.duplicate()
	var attempts := pool.size() * 4
	while chosen.size() < count and attempts > 0 and not pool.is_empty():
		attempts -= 1
		var i := randi() % pool.size()
		var cand := pool[i]
		if MazeGenerator.toroidal_dist(cand, player_cell, grid[0].size(), grid.size()) >= min_dist_cells:
			chosen.append(cand)
			pool.remove_at(i)
	return chosen

# Level0._ready 里调用。敌人加入 WorldViewport 子节点(与墙壁/玩家同空间)。
func spawn_all(grid: Array[Array], player_pos: Vector2) -> void:
	var world := get_parent().get_node("WorldViewport")
	var ts: int = GameParameters.TILE_SIZE
	var min_dist_cells := int(GameParameters.enemy_spawn_min_dist / ts)
	var player_cell := Vector2i(int(player_pos.x / ts), int(player_pos.y / ts))
	var cells := sample_spawn_cells(grid, player_cell,
			GameParameters.enemy_count, min_dist_cells)
	var type_names := TYPES.keys()
	for c in cells:
		var type_name: String = type_names[randi() % type_names.size()]
		var scene: PackedScene = load(TYPES[type_name])
		var e := scene.instantiate()
		world.add_child(e)
		e.global_position = Vector2(c.x * ts + ts / 2.0, c.y * ts + ts / 2.0)
	print("[EnemySpawner] spawned %d enemies" % cells.size())
