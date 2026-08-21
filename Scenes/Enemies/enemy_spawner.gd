class_name EnemySpawner
extends Node2D

# 每生成一个敌人发射一次(HUD 等接上去监听 enemy.died 做击杀计数)
signal enemy_spawned(enemy: Node)

# 敌人注册表(id → scene)。唯一来源 editor/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}

# 从 res://editor/enemies.json 加载注册表;缺文件/格式错 → push_error,表保持空。
static func load_types() -> void:
	TYPES = {}
	var json_text := FileAccess.get_file_as_string("res://editor/enemies.json")
	if json_text.is_empty():
		push_error("EnemySpawner: 读不到 res://editor/enemies.json")
		return
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("enemies", []) is Array):
		push_error("EnemySpawner: enemies.json 格式非法")
		return
	for e in parsed["enemies"]:
		if typeof(e) == TYPE_DICTIONARY and e.has("id") and e.has("scene"):
			TYPES[str(e["id"])] = str(e["scene"])

# 在 grid 里随机取 count 个「地板格」、且距 player_cell 的环面距离 >= min_dist_cells。
# 地板格 = EMPTY 且正下方(y+1,环面取模)是 SOLID:敌人站立/落地有实心表面托底,
# 否则返程落地时没有 is_on_floor() 的地面,会坠穿空洞(见 FlyBird 回家入睡 bug)。
static func sample_spawn_cells(grid: Array[Array], player_cell: Vector2i,
		count: int, min_dist_cells: int) -> Array[Vector2i]:
	var rows := grid.size()
	var cols := grid[0].size()
	var floor_cells: Array[Vector2i] = []
	for y in range(rows):
		for x in range(cols):
			if grid[y][x] == MazeGenerator.EMPTY and grid[posmod(y + 1, rows)][x] == MazeGenerator.SOLID:
				floor_cells.append(Vector2i(x, y))
	var chosen: Array[Vector2i] = []
	var pool: Array[Vector2i] = floor_cells.duplicate()
	var attempts := pool.size() * 4
	while chosen.size() < count and attempts > 0 and not pool.is_empty():
		attempts -= 1
		var i := randi() % pool.size()
		var cand := pool[i]
		if MazeGenerator.toroidal_dist(cand, player_cell, cols, rows) >= min_dist_cells:
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
		enemy_spawned.emit(e)
	print("[EnemySpawner] spawned %d enemies" % cells.size())
