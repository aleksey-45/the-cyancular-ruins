class_name EnemySpawner
extends Node2D

# 每生成一个敌人发射一次(HUD 等接上去监听 enemy.died 做击杀计数)
signal enemy_spawned(enemy: Node)

# 敌人注册表(id → scene)。唯一来源 data/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}

# 从 res://data/enemies.json 加载注册表;缺文件/格式错 → push_error,表保持空。
static func load_types() -> void:
	TYPES = {}
	var json_text := FileAccess.get_file_as_string("res://data/enemies.json")
	if json_text.is_empty():
		push_error("EnemySpawner: 读不到 res://data/enemies.json")
		return
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("enemies", []) is Array):
		push_error("EnemySpawner: enemies.json 格式非法")
		return
	for e in parsed["enemies"]:
		if typeof(e) == TYPE_DICTIONARY and e.has("id") and e.has("scene"):
			TYPES[str(e["id"])] = str(e["scene"])

# 在 grid 里随机取 count 个「地板格」、且距 player_cell 的环面距离 >= min_dist_cells。
# 地板格 = EMPTY 且正下方(y+1,环面取模)是非 EMPTY:敌人站立/落地有实心表面托底,
# 否则返程落地时没有 is_on_floor() 的地面,会坠穿空洞(见 FlyBird 回家入睡 bug)。
static func sample_spawn_cells(grid: Array[Array], player_cell: Vector2i,
		count: int, min_dist_cells: int) -> Array[Vector2i]:
	var rows := grid.size()
	var cols := grid[0].size()
	var floor_cells: Array[Vector2i] = []
	for y in range(rows):
		for x in range(cols):
			if grid[y][x] == MazeGenerator.EMPTY and TileDefs.is_blocked(grid[posmod(y + 1, rows)][x]):
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
# spawns 为 MazeGenerator.load_spawns() 的字典;地图是唯一来源(无 # enemy 即 0 只)。
func spawn_all(spawns: Dictionary = {}) -> void:
	var world := get_parent().get_node("WorldViewport")
	var ts: int = GameParameters.TILE_SIZE
	var enemies_meta: Array = spawns.get("enemies", [])
	for entry in enemies_meta:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var type_name: String = str(entry.get("type", ""))
		var cell: Variant = entry.get("cell")
		if type_name.is_empty() or typeof(cell) != TYPE_VECTOR2I:
			push_warning("EnemySpawner: 忽略非法 spawn 条目 %s" % str(entry))
			continue
		if not TYPES.has(type_name):
			push_warning("EnemySpawner: 未知敌人类型 %s" % type_name)
			continue
		var scene: PackedScene = load(TYPES[type_name])
		var e := scene.instantiate()
		world.add_child(e)
		e.global_position = Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
		enemy_spawned.emit(e)
	print("[EnemySpawner] spawned %d enemies from map" % enemies_meta.size())
