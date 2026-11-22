class_name TerrainView
extends Node2D

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const SUB := CyrmMap.CELL_SIZE
const ATLAS_SIDE := TerrainAtlas.SUBS_PER_TEXTURE

var _wall := TileMapLayer.new()
var _water := TileMapLayer.new()
var _water_material := ShaderMaterial.new()
var _wall_film := ShaderMaterial.new()
var _span: Vector2i
var _margin: Vector2
var _descriptors: PackedInt32Array
var _wall_rows: Dictionary

func install(map: Dictionary, margin: Vector2) -> void:
	TileDefs.load_defs()
	_span = map.size
	_descriptors = map.layers[CyrmMap.SCENE]
	_margin = margin
	var water_rows := {}
	for desc: int in TerrainAtlas.descriptor_rows(_descriptors):
		if TileDefs.is_liquid(CyrmMap.tile_material(desc)):
			var body := CyrmMap.tile_value(TerrainAtlas.WATER_BODY_MATERIAL, CyrmMap.tile_tint(desc))
			water_rows.get_or_add(body, water_rows.size())
		else:
			_wall_rows[desc] = _wall_rows.size()
	for layer in [_wall, _water]:
		layer.collision_enabled = false
		layer.navigation_enabled = false
		layer.occlusion_enabled = false
		add_child(layer)
	_water.z_index = 4
	_wall_film.shader = preload("res://core/present/time_film.gdshader")
	_water_material.shader = preload("res://core/present/water_current.gdshader")
	_water_material.set_shader_parameter("map_size", Vector2(_span * SUB))
	_water_material.set_shader_parameter("wave_speed", WCFG.water_sway_speed)
	_water_material.set_shader_parameter("wave_amplitude", WCFG.water_sway_amp)
	_water.material = _water_material
	_wall.tile_set = TerrainAtlas.make_wall_tileset(_wall_rows)
	_water.tile_set = TerrainAtlas.make_wall_tileset(water_rows)
	for index in _descriptors.size():
		_paint_wall(index, true)
	_add_water(water_rows)

func patch(changes: Dictionary) -> void:
	for index: int in changes:
		_paint_wall(index, changes[index])

func present(elapsed: float, coverage: float) -> void:
	_wall.material = _wall_film if coverage > 0.0 else null
	_wall_film.set_shader_parameter("coverage", coverage)
	_water_material.set_shader_parameter("elapsed", elapsed)
	_water_material.set_shader_parameter("coverage", coverage)

func _paint_wall(index: int, alive: bool) -> void:
	var row: int = _wall_rows.get(_descriptors[index], -1)
	if row < 0:
		return
	var sub := Vector2i(index % _span.x, index / _span.x)
	var quad := (sub.y % ATLAS_SIDE) * ATLAS_SIDE + sub.x % ATLAS_SIDE
	var atlas := TerrainAtlas.atlas_coords(row, quad)
	var copies := GridPathfinder.seam_copy_range(Rect2(Vector2(sub), Vector2.ONE), Vector2(_span), _margin / SUB)
	for y in range(copies.position.y, copies.end.y):
		for x in range(copies.position.x, copies.end.x):
			var cell := sub + Vector2i(x, y) * _span
			if alive:
				_wall.set_cell(cell, 0, atlas)
			else:
				_wall.erase_cell(cell)

func _add_water(rows: Dictionary) -> void:
	var groups := {}
	for i in _descriptors.size():
		var desc := _descriptors[i]
		if not TileDefs.is_liquid(CyrmMap.tile_material(desc)): continue
		var cell := Vector2i(i % _span.x, i / _span.x)
		var above := posmod(cell.y - 1, _span.y) * _span.x + cell.x
		var surface := not TileDefs.is_liquid(CyrmMap.tile_material(_descriptors[above]))
		var tint := CyrmMap.tile_tint(desc)
		var body := CyrmMap.tile_value(TerrainAtlas.WATER_BODY_MATERIAL, tint)
		var quad := cell % ATLAS_SIDE
		var atlas := TerrainAtlas.atlas_coords(rows[body], quad.y * ATLAS_SIDE + quad.x)
		var bounds := Rect2(Vector2(cell), Vector2.ONE)
		if surface: bounds = bounds.grow_individual(0, WCFG.water_sway_amp / SUB, 0, 0)
		var copies := GridPathfinder.seam_copy_range(bounds, Vector2(_span), _margin / SUB)
		for y in range(copies.position.y, copies.end.y):
			for x in range(copies.position.x, copies.end.x):
				var at := cell + Vector2i(x, y) * _span
				if surface:
					var uv := Rect2(Vector2(quad.x, 0) / ATLAS_SIDE, Vector2.ONE / ATLAS_SIDE)
					groups.get_or_add(tint, []).append([(Vector2(at) + Vector2(0.5, 1.0)) * SUB, (cell.x * 1.7 + cell.y * 2.3) / ATLAS_SIDE, uv])
				else:
					_water.set_cell(at, 0, atlas)
	for tint: Vector4i in groups:
		var batch := WaterSurfaceBatch.new()
		batch.z_index = 5
		batch.material = _water_material
		batch.set_instance_shader_parameter("wave", true)
		var image := TerrainAtlas.tile_image(ATLAS_SIDE * SUB, CyrmMap.tile_value(TerrainAtlas.WATER_SURFACE_MATERIAL, tint))
		batch.setup(groups[tint], ImageTexture.create_from_image(image), SUB)
		add_child(batch)
