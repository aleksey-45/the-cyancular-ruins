class_name EnemySpawner
extends Node2D

# 每生成一个敌人发射一次(HUD 等接上去监听 enemy.died 做击杀计数)
signal enemy_spawned(enemy: Node)

# 敌人注册表。唯一来源 data/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}           # id → scene 路径
static var DISPLAY_NAMES: Dictionary = {}   # scene 路径(res://…/enemy_fly_bird.tscn)→ 中文显示名

# 从 res://data/enemies.json 加载注册表(两张表一起填);缺文件/格式错 → push_error,表保持空。
static func load_types() -> void:
	_load_registry()

# 敌人中文显示名(击杀播报用)。按**场景路径**查 —— 不再像旧实现那样"去掉 `Enemy` 前缀再查表",
# 那种约定在场景文件改名时会**静默**回落英文名。
# ★ 自带惰性加载,刻意**不依赖 load_types()**:后者只在单机 `Level0._ready` 里调,而 PvP 在它
#   **之前**就 `return` 了(PvP 里没有本地敌人:PvPvE 中立鸟特性 2026-09-14 定案不开、已整体移除,
#   故 PvP 侧今天不会走到这里 —— 但那正是"哪天加了 PvP 敌人,才发现回落成了英文名"的形状);
#   让本函数自给自足,比依赖"调用前恰好有人 load 过"便宜得多。
static func display_name_of(scene_path: String) -> String:
	if DISPLAY_NAMES.is_empty():
		_load_registry()
	return str(DISPLAY_NAMES.get(scene_path, scene_path.get_file().trim_suffix(".tscn")))


static func _load_registry() -> void:
	TYPES = {}
	DISPLAY_NAMES = {}
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
		var scene_path := str(e["scene"])
		TYPES[str(e["id"])] = scene_path
		DISPLAY_NAMES[scene_path] = str(e.get("display_name", scene_path.get_file().trim_suffix(".tscn")))

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


# 全图"头顶 2 格净空"的开阔地板格,供地面武器布点用(2026-09-15)。
# ★ 判据本体在 `MazeGenerator.is_floor_cell_with_headroom` —— 本函数**只做扫描**,
#   别再抄一份判定条件(抄一份 = 改一处漏一处,而且两处都不报错)。
# ★ 联机侧 `RoyaleHost._floor_cells` 是同款扫描(那边还要连通区规模,故没合并)。
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
