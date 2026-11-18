class_name EnemySpawner
extends RefCounted

# 敌人注册表。唯一来源 data/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}           # id → scene 路径
# 敌人生成器：负责关卡敌人按需实例化与生成点管理

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
		if typeof(e) != TYPE_DICTIONARY or not e.has("id") or not e.has("scene"):
			continue
		TYPES[str(e["id"])] = str(e["scene"])

# 敌人来自地图的 # enemy 出生点。
static func spawn_all(enemies: Array, world: SubViewport, combat: CombatSimulator) -> Array[EnemyBase]:
	var spawned: Array[EnemyBase] = []
	var ts: int = GameParameters.TILE_SIZE
	for entry: Dictionary in enemies:
		var type_name: String = entry["type"]
		var cell: Vector2i = entry["cell"]
		if not TYPES.has(type_name):
			push_warning("EnemySpawner: 未知敌人类型 %s" % type_name)
			continue
		var scene: PackedScene = load(TYPES[type_name])
		var e: EnemyBase = scene.instantiate()
		e.combat_rules = combat
		world.add_child(e)
		e.global_position = Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
		spawned.append(e)
	print("[EnemySpawner] spawned %d enemies from map" % enemies.size())
	return spawned
