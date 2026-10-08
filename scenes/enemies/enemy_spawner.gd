class_name EnemySpawner
extends Node2D

# 每生成一个敌人发射一次(HUD 等接上去监听 enemy.died 做击杀计数)
signal enemy_spawned(enemy: Node)

# 敌人注册表。唯一来源 data/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}           # id → scene 路径
# 敌人生成器：负责关卡敌人按需实例化与生成点管理

# 从 res://data/enemies.json 加载注册表;缺文件/格式错 → push_error,表保持空。
static func load_types() -> void:
	_load_registry()


static func _load_registry() -> void:
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
		if typeof(e) != TYPE_DICTIONARY or not e.has("id") or not e.has("scene"):
			continue
		TYPES[str(e["id"])] = str(e["scene"])

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


# 扫描全图上方具有 2 格净空的平整地面瓦片，供武器散落布点使用
func open_floor_cells(grid: Array) -> Array:
	var out: Array = []
	if grid.is_empty():
		return out
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				out.append(c)
	return out
