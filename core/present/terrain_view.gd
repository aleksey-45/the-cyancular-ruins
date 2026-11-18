class_name TerrainView
extends Node2D

const CELL := GameParameters.TILE_SIZE
const SUBS := MapFormatV4.SUB_PER_CELL
const SUB := CELL / SUBS

var _wall := TileMapLayer.new()
var _water := TileMapLayer.new()
var _surfaces: Array[WaterSurfaceBatch] = []
var _span: Vector2i
var _margin: Vector2
var _descriptors: PackedInt32Array
var _wall_rows: Dictionary

func install(grid: Array[Array], descriptors: PackedInt32Array, margin: Vector2) -> void:
	_span = Vector2i(grid[0].size(), grid.size())
	_descriptors = descriptors
	_margin = margin
	var water_rows := {}
	for desc: int in TerrainAtlas.descriptor_rows(descriptors):
		if TileDefs.is_liquid(MapFormatV4.descriptor_texture(desc)):
			water_rows.get_or_add(desc & MapFormatV4.TINT_MASK, water_rows.size())
		else:
			_wall_rows[desc] = _wall_rows.size()
	for layer in [_wall, _water]:
		layer.collision_enabled = false
		layer.navigation_enabled = false
		layer.occlusion_enabled = false
		add_child(layer)
	_water.z_index = 4
	_wall.tile_set = TerrainAtlas.make_wall_tileset(_wall_rows)
	_water.tile_set = TerrainAtlas.make_water_tileset(CELL, TerrainAtlas.WATER_BODY_BRICK, water_rows)
	for index in descriptors.size():
		_paint_wall(index, true)
	_add_water(grid, water_rows)

func patch(changes: Dictionary) -> void:
	for index: int in changes:
		_paint_wall(index, changes[index])

func present(elapsed: float, film: ShaderMaterial) -> void:
	for surface in _surfaces:
		surface.present(elapsed)
	_wall.material = film
	_water.material = film

func _paint_wall(index: int, alive: bool) -> void:
	var row: int = _wall_rows.get(_descriptors[index], -1)
	if row < 0:
		return
	var span := _span * SUBS
	var sub := Vector2i(index % span.x, index / span.x)
	var quad := (sub.y % SUBS) * SUBS + sub.x % SUBS
	var atlas := TerrainAtlas.atlas_coords(row, quad)
	var copies := GridPathfinder.seam_copy_range(Rect2(Vector2(sub), Vector2.ONE), Vector2(span), _margin / SUB)
	for y in range(copies.position.y, copies.end.y):
		for x in range(copies.position.x, copies.end.x):
			var cell := sub + Vector2i(x, y) * span
			if alive:
				_wall.set_cell(cell, 0, atlas)
			else:
				_wall.erase_cell(cell)

func _water_tint(cell: Vector2i, texture: int) -> int:
	var counts := {}
	var best := MapFormatV4.NEUTRAL_TINT
	var best_count := 0
	var stride := _span.x * SUBS
	var start := cell.y * SUBS * stride + cell.x * SUBS
	for y in SUBS:
		for x in SUBS:
			var desc := _descriptors[start + y * stride + x]
			if MapFormatV4.descriptor_texture(desc) == texture:
				var tint := desc & MapFormatV4.TINT_MASK
				var count := int(counts.get(tint, 0)) + 1
				counts[tint] = count
				if count > best_count or (count == best_count and tint < best):
					best = tint
					best_count = count
	return best

func _add_water(grid: Array[Array], water_rows: Dictionary) -> void:
	var groups := {}
	for y in _span.y:
		var above: Array = grid[posmod(y - 1, _span.y)]
		for x in _span.x:
			var value: int = grid[y][x]
			var texture := MapFormat.texture_of(value)
			if not TileDefs.is_liquid(texture):
				continue
			var cell := Vector2i(x, y)
			var tint := _water_tint(cell, texture)
			var surface := not TileDefs.is_liquid(MapFormat.texture_of(above[x]))
			var atlas := TerrainAtlas.atlas_coords(water_rows[tint], MapFormat.shape_of(value))
			var bounds := Rect2(Vector2(cell), Vector2.ONE)
			if surface:
				bounds = bounds.grow_individual(0.0, GameParameters.water_sway_amp / CELL, 0.0, 0.0)
			var copies := GridPathfinder.seam_copy_range(bounds, Vector2(_span), _margin / CELL)
			for ty in range(copies.position.y, copies.end.y):
				for tx in range(copies.position.x, copies.end.x):
					var at := cell + Vector2i(tx, ty) * _span
					if surface:
						groups.get_or_add(tint, []).append([
							(Vector2(at) + Vector2(0.5, 1.0)) * CELL, x * 1.7 + y * 2.3])
					else:
						_water.set_cell(at, 0, atlas)
	for tint: int in groups:
		var batch := WaterSurfaceBatch.new()
		batch.z_index = 5
		var image := TerrainAtlas.water_brick_image(CELL, TerrainAtlas.WATER_SURFACE_BRICK, tint)
		batch.setup(groups[tint], ImageTexture.create_from_image(image), CELL)
		add_child(batch)
		_surfaces.append(batch)
