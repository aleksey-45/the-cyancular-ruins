class_name TileDefs
extends RefCounted

# 从项目配置装载一次，预览、校验与模拟共用静态材质表。
const PATH := "res://data/tile_defs.json"
const TYPE_WALL := 0
const TYPE_PASSAGE := 1
const TYPE_LIQUID := 2
const TYPE_GAS := 3
const UNDEFINED := 255
enum DamageMask { BULLET = 1, EXPLOSION = 2 }

static var _defs: Dictionary = {}
static var types := PackedByteArray()
static var hit_points := PackedInt32Array()
static var damage_masks := PackedByteArray()
static var elastic := PackedByteArray()
static var climb := PackedFloat64Array()
static var descent := PackedFloat64Array()
static var decay := PackedFloat64Array()
static var ledges := PackedInt32Array()
static var blast_decay: float

static func load_defs() -> void:
	if not _defs.is_empty():
		return
	_defs = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	blast_decay = _defs["explosion_decay"]
	var materials: Dictionary = _defs["tiles"]
	var count := 1
	for key in materials:
		count = maxi(count, int(key) + 1)
	types.resize(count)
	types.fill(UNDEFINED)
	types[0] = TYPE_GAS
	hit_points.resize(count)
	damage_masks.resize(count)
	elastic.resize(count)
	climb.resize(count)
	descent.resize(count)
	decay.resize(count)
	ledges.resize(count)
	var kinds := {"wall": TYPE_WALL, "passage": TYPE_PASSAGE, "liquid": TYPE_LIQUID, "gas": TYPE_GAS}
	for key in materials:
		var texture := int(key)
		var material: Dictionary = materials[key]
		types[texture] = kinds[material["type"]]
		hit_points[texture] = material["hp"]
		var bullet := DamageMask.BULLET if material["bullet_destroyable"] else 0
		var explosion := DamageMask.EXPLOSION if material["explosion_destroyable"] else 0
		damage_masks[texture] = bullet | explosion
		elastic[texture] = int(material["elastic"])
		climb[texture] = material.get("climb_speed", 0.0)
		descent[texture] = material.get("climb_descent_speed", 0.0)
		decay[texture] = material.get("explosion_decay", blast_decay)
		ledges[texture] = material.get("collision_ledge", 0)

static func has_texture(texture: int) -> bool:
	return texture < types.size() and types[texture] != UNDEFINED

static func legacy_textures() -> Dictionary:
	load_defs()
	return _defs["legacy_texture_map"]

static func type_id_of(texture: int) -> int:
	return types[texture]

static func is_liquid(texture: int) -> bool:
	return type_id_of(texture) == TYPE_LIQUID

static func explosion_destroyable(texture: int) -> bool:
	return (damage_masks[texture] & DamageMask.EXPLOSION) != 0

static func is_blocked(value: int) -> bool:
	return types[MapFormat.texture_of(value)] == TYPE_WALL
