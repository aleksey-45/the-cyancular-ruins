class_name TileDefs
extends RefCounted

# 配置由脚本装载；运行时地形和物理属性由 NativeTerrain 持有。
const PATH := "res://data/tile_defs.json"
const MAX_TEXTURE := 22
const BLAST_INNER_FRACTION := 0.4
const TYPE_WALL := 0
const TYPE_PASSAGE := 1
const TYPE_LIQUID := 2
const TYPE_GAS := 3
static var _defs: Dictionary = {}
static var _loaded := false
static var _type := PackedByteArray()
static var _explosion_destroyable := PackedByteArray()
static var terrain := NativeTerrain.new()

static func load_defs() -> void:
	if _loaded: return
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		push_error("TileDefs: 无法打开 %s" % PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("TileDefs: %s 解析失败" % PATH)
		return
	_defs = parsed
	_type.resize(MAX_TEXTURE + 1)
	_type.fill(TYPE_WALL)
	_explosion_destroyable.resize(MAX_TEXTURE + 1)
	var types := {"wall": TYPE_WALL, "passage": TYPE_PASSAGE, "liquid": TYPE_LIQUID, "gas": TYPE_GAS}
	for texture in range(1, MAX_TEXTURE + 1):
		var material: Dictionary = _defs["tiles"].get(str(texture), {})
		_type[texture] = types.get(material.get("type", "wall"), TYPE_WALL)
		_explosion_destroyable[texture] = int(material.get("explosion_destroyable", false))
	_loaded = true

static func load_terrain(grid: Array, subgrid: Array) -> void:
	load_defs()
	var next := NativeTerrain.new()
	next.configure(grid, subgrid, _defs, {"tile_size": CollisionBuilder.TILE_TS,
			"sub_size": CollisionBuilder.SUB_TS, "chunk_cells": CollisionBuilder.CHUNK_CELLS,
			"cache_states": CollisionBuilder.CHUNK_CACHE_STATES, "solid_code": MapFormat.SOLID,
			"wall_type": TYPE_WALL, "liquid_type": TYPE_LIQUID,
			"ledge_thickness": CollisionBuilder.LEDGE_THICKNESS, "blast_inner": BLAST_INNER_FRACTION})
	terrain = next

static func type_id_of(texture: int) -> int:
	load_defs()
	return _type[texture] if texture >= 0 and texture < _type.size() else TYPE_WALL

static func is_liquid(texture: int) -> bool:
	return type_id_of(texture) == TYPE_LIQUID

static func explosion_destroyable(texture: int) -> bool:
	load_defs()
	return texture >= 0 and texture < _explosion_destroyable.size() and _explosion_destroyable[texture] != 0

static func is_blocked(value: int) -> bool:
	return value != 0 and type_id_of(MapFormat.texture_of(value)) == TYPE_WALL

static func owner_role(owner: Node) -> int:
	return owner.role if owner is NativeActorBody else 0

static func damage_tile(cell: Vector2i, amount: int, owner: Node = null) -> bool:
	return terrain.damage_tile(cell, amount, 1, owner_role(owner))
