class_name TileDefs
extends RefCounted

# 从 tile_defs.json 加载材质配置；运行时地形交给 NativeTerrain。

const PATH: String = "res://data/tile_defs.json"
const MAX_TEXTURE: int = 22
const BLAST_INNER_FRACTION: float = 0.4

static var _defs: Dictionary = {}
static var _loaded := false

# 纹理类型 id(避免每格一次字符串比较)。
const TYPE_WALL: int = 0
const TYPE_PASSAGE: int = 1
const TYPE_LIQUID: int = 2
const TYPE_GAS: int = 3
const _TYPE_NAMES: Array = ["wall", "passage", "liquid", "gas"]

static var _type: PackedByteArray = PackedByteArray()          # 类型 id
static var _hp: PackedInt32Array = PackedInt32Array()
static var _bullet_destroyable: PackedByteArray = PackedByteArray()
static var _explosion_destroyable: PackedByteArray = PackedByteArray()
static var _elastic: PackedByteArray = PackedByteArray()
static var _climb_speed: PackedFloat32Array = PackedFloat32Array()
static var _climb_descent: PackedFloat32Array = PackedFloat32Array()
static var _decay: PackedFloat32Array = PackedFloat32Array()   # 逐格爆炸衰减(缺省回落全局)
static var _tables_built := false
# 运行时状态和计算只属于原生地形；这里加载配置并保留脚本查询入口。
static var terrain := NativeTerrain.new()

static func load_terrain(grid: Array, subgrid: Array) -> void:
	load_defs()
	var next := NativeTerrain.new()
	next.configure(grid, subgrid, _defs, {"tile_size": CollisionBuilder.TILE_TS,
			"sub_size": CollisionBuilder.SUB_TS, "chunk_cells": CollisionBuilder.CHUNK_CELLS,
			"cache_states": CollisionBuilder.CHUNK_CACHE_STATES, "solid_code": MazeGenerator.SOLID,
			"wall_type": TYPE_WALL, "liquid_type": TYPE_LIQUID,
			"ledge_thickness": CollisionBuilder.LEDGE_THICKNESS, "blast_inner": BLAST_INNER_FRACTION})
	terrain = next

# 未加载配置时的默认兜底逻辑：
# 任意纹理类型默认为 wall、生命值为 1、各类开关为 false、爬行速度为 0、衰减回退至全局 0.75。
static func _ensure_tables() -> void:
	if _tables_built:
		return
	_tables_built = true
	var n := MAX_TEXTURE + 1
	_type.resize(n)
	_hp.resize(n)
	_bullet_destroyable.resize(n)
	_explosion_destroyable.resize(n)
	_elastic.resize(n)
	_climb_speed.resize(n)
	_climb_descent.resize(n)
	_decay.resize(n)
	_type.fill(TYPE_WALL)
	_hp.fill(1)
	_bullet_destroyable.fill(0)
	_explosion_destroyable.fill(0)
	_elastic.fill(0)
	_climb_speed.fill(0.0)
	_climb_descent.fill(0.0)
	var fallback := float(_defs.get("explosion_decay", 0.75))
	_decay.fill(fallback)
	var tiles: Dictionary = _defs.get("tiles", {})
	for tex in range(1, n):
		var d: Dictionary = tiles.get(str(tex), {})
		var t := String(d.get("type", "wall"))
		var tid := TYPE_WALL
		if t == "passage":
			tid = TYPE_PASSAGE
		elif t == "liquid":
			tid = TYPE_LIQUID
		elif t == "gas":
			tid = TYPE_GAS
		_type[tex] = tid
		_hp[tex] = int(d.get("hp", 1))
		_bullet_destroyable[tex] = 1 if bool(d.get("bullet_destroyable", false)) else 0
		_explosion_destroyable[tex] = 1 if bool(d.get("explosion_destroyable", false)) else 0
		_elastic[tex] = 1 if bool(d.get("elastic", false)) else 0
		_climb_speed[tex] = float(d.get("climb_speed", 0.0))
		_climb_descent[tex] = float(d.get("climb_descent_speed", 0.0))
		_decay[tex] = float(d.get("explosion_decay", fallback))


static func load_defs() -> void:
	if _loaded:
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("TileDefs: 无法打开 %s" % PATH)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_defs = parsed
	else:
		push_error("TileDefs: %s 解析失败" % PATH)
	_loaded = true
	# defs 改变 → 重建属性表(把先前可能的"未加载缺省表"覆盖成真实值)
	_tables_built = false
	_ensure_tables()


static func explosion_decay() -> float:
	return float(_defs.get("explosion_decay", 0.75))


# 逐格爆炸衰减(水 0.25);缺省回落全局 explosion_decay()。
static func explosion_decay_of(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return explosion_decay()
	return _decay[texture]


# 旧接口保留(少量非热点调用/tests 仍比对字符串);内部走预计算表。
static func type_of(texture: int) -> String:
	var tid := type_id_of(texture)
	return _TYPE_NAMES[tid] if tid >= 0 and tid < _TYPE_NAMES.size() else "wall"


# 类型 id(热点:寻路/LOS/水判定),省去字符串比较。
static func type_id_of(texture: int) -> int:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return TYPE_WALL
	return int(_type[texture])


static func is_liquid(texture: int) -> bool:
	return type_id_of(texture) == TYPE_LIQUID


static func hp_of(texture: int) -> int:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 1
	return _hp[texture]


static func bullet_destroyable(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _bullet_destroyable[texture] != 0


static func explosion_destroyable(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _explosion_destroyable[texture] != 0


static func elastic(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _elastic[texture] != 0


static func climb_speed(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 0.0
	return _climb_speed[texture]


# 攀爬下降速度倍率(梯子 2.0;锁链无此字段 → 0,玩家下降走自由落体)。
static func climb_descent_speed(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 0.0
	return _climb_descent[texture]


# packed 格值 → 是否挡路:非 0 且 type=wall。
static func is_blocked(v: int) -> bool:
	if v == 0:
		return false
	return type_id_of(MazeGenerator.texture_of(v)) == TYPE_WALL


# 下列属性都是显式快照或标量查询，不是另一份可写运行时状态。
static var sub_hp: PackedInt32Array:
	get: return terrain.get_hp_snapshot()
static var sub_cols: int:
	get: return terrain.get_sub_columns()
static var sub_rows: int:
	get: return terrain.get_sub_rows()
static var collision_revision: int:
	get: return terrain.get_collision_revision()
static var hp_grid: Array[Array]:
	get: return terrain.get_tile_hp_snapshot()

static func capture_terrain_cell(cell: Vector2i) -> Dictionary:
	return terrain.capture_cell(cell)

static func sub_of(pos: Vector2) -> Vector2i:
	return terrain.sub_of(pos)

static func sub_texture(sub: Vector2i) -> int:
	return terrain.sub_texture(sub)

static func sub_alive(sub: Vector2i) -> bool:
	return terrain.sub_alive(sub)

static func owner_role(owner: Node) -> int:
	return owner.role if owner is NativeActorBody else 0

static func damage_sub(sub: Vector2i, amount: int, source: String, owner: Node = null) -> bool:
	return terrain.damage_sub(sub, amount, int(source != "bullet"), owner_role(owner))

static func apply_sub_hp(sub: Vector2i, hp: int, owner: Node = null) -> bool:
	return terrain.apply_hp(sub, hp, owner_role(owner))

static func restore_sub(sub: Vector2i, hp: int) -> void:
	terrain.restore_hp(sub, hp)

static func damage_tile(cell: Vector2i, amount: int, source: String, owner: Node = null) -> bool:
	return terrain.damage_tile(cell, amount, int(source != "bullet"), owner_role(owner))
