class_name TerrainAtlas
extends RefCounted

const SOURCE_PATH := "res://assets/textures/structure.png"
const TEX_COUNT := 22
const SRC_COLS := 10
const SRC_TILE := 32
const QUAD_SRC := 8
const QUAD_TILE := 16
const QUAD_COLS := 16
const GROUPS_PER_ROW := 4
const SUBS_PER_TEXTURE := SRC_TILE / QUAD_SRC
const WATER_BODY_MATERIAL := 21
const WATER_SURFACE_MATERIAL := 22

static var _src_cache: Image
static var _brick_cache: Dictionary = {}
static var _tex_cache: Dictionary = {}

static func clear_cache() -> void:
	_src_cache = null
	_brick_cache.clear()
	_tex_cache.clear()

static func source_image() -> Image:
	if _src_cache == null:
		var tex: Texture2D = load(SOURCE_PATH)
		_src_cache = tex.get_image()
	return _src_cache

static func background_image(map: Dictionary, layer: int) -> Image:
	var bytes: PackedByteArray = map.layers[layer].to_byte_array()
	bytes.bswap32() # 地图存 0xRRGGBBAA，图像按 R、G、B、A 读取字节。
	return Image.create_from_data(map.size.x, map.size.y, false, Image.FORMAT_RGBA8, bytes)

# idx 是原始图集中的瓦片索引，返回对应的像素矩形。
static func source_rect(idx: int) -> Rect2i:
	return Rect2i((idx % SRC_COLS) * SRC_TILE, (idx / SRC_COLS) * SRC_TILE, SRC_TILE, SRC_TILE)

static func descriptor_rows(descriptors: PackedInt32Array) -> Dictionary:
	var rows := {}
	for desc in descriptors:
		var tex := CyrmMap.tile_material(desc)
		if tex > 0 and tex <= TEX_COUNT:
			rows.get_or_add(desc, rows.size())
	return rows

static func atlas_coords(group: int, variant: int) -> Vector2i:
	return Vector2i((group % GROUPS_PER_ROW) * QUAD_COLS + variant, group / GROUPS_PER_ROW)

static func _atlas_image(tile: int, count: int) -> Image:
	var groups := maxi(1, count)
	return Image.create(mini(groups, GROUPS_PER_ROW) * QUAD_COLS * tile,
			ceili(float(groups) / GROUPS_PER_ROW) * tile, false, Image.FORMAT_RGBA8)

static func tint_color(color: Color, tint: Vector4i) -> Color:
	if tint == CyrmMap.NEUTRAL_TINT: return color
	var adjusted := Color.from_hsv(
		fposmod(color.h + (tint.x - 4) / 24.0, 1.0),
		clampf(color.s * (tint.z + 6) / 10.0, 0.0, 1.0),
		clampf(color.v * (tint.y + 6) / 10.0, 0.0, 1.0),
		color.a * tint.w / 7.0)
	return Color.hex(adjusted.to_rgba32())

static func _colored_brick(tile: int) -> Image:
	if tile == 0:
		return Image.create_empty(SRC_TILE, SRC_TILE, false, Image.FORMAT_RGBA8)
	var image := source_image().get_region(source_rect(CyrmMap.tile_material(tile) - 1))
	var tint := CyrmMap.tile_tint(tile)
	if tint != CyrmMap.NEUTRAL_TINT:
		for y in SRC_TILE:
			for x in SRC_TILE:
				image.set_pixel(x, y, tint_color(image.get_pixel(x, y), tint))
	return image

static func build_atlas_image(rows: Dictionary) -> Image:
	var atlas := _atlas_image(QUAD_TILE, rows.size())
	for desc in rows:
		var brick := _colored_brick(desc)
		for quad in QUAD_COLS:
			var origin := Vector2i(quad % SUBS_PER_TEXTURE, quad / SUBS_PER_TEXTURE) * QUAD_SRC
			var q := brick.get_region(Rect2i(origin, Vector2i.ONE * QUAD_SRC))
			q.resize(QUAD_TILE, QUAD_TILE, Image.INTERPOLATE_NEAREST)
			atlas.blit_rect(q, Rect2i(Vector2i.ZERO, q.get_size()), atlas_coords(rows[desc], quad) * QUAD_TILE)
	return atlas

static func make_wall_tileset(rows: Dictionary) -> TileSet:
	return _tileset(build_atlas_image(rows), QUAD_TILE, rows.size())

static func _tileset(image: Image, tile: int, groups: int) -> TileSet:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i.ONE * tile
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = tile_set.tile_size
	atlas.texture = ImageTexture.create_from_image(image)
	tile_set.add_source(atlas)
	for group in groups:
		for variant in QUAD_COLS:
			atlas.create_tile(atlas_coords(group, variant))
	return tile_set

static func tile_image(ts: int, tile: int) -> Image:
	var key := Vector2i(ts, tile)
	if _brick_cache.has(key):
		return _brick_cache[key]
	var img := _colored_brick(tile)
	img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
	_brick_cache[key] = img
	return img

static func _bake_map_image(map: Dictionary, cell_px: int) -> Image:
	var sp := maxi(1, cell_px / SUBS_PER_TEXTURE)
	var descriptors: PackedInt32Array = map.layers[CyrmMap.SCENE]
	var rows := descriptor_rows(descriptors)
	var atlas := build_atlas_image(rows)
	atlas.resize(atlas.get_width() / QUAD_TILE * sp, atlas.get_height() / QUAD_TILE * sp, Image.INTERPOLATE_NEAREST)
	var sub_size: Vector2i = map.size
	var out := Image.create(sub_size.x * sp, sub_size.y * sp, false, Image.FORMAT_RGBA8)
	for i in descriptors.size():
		var desc := descriptors[i]
		if not rows.has(desc):
			continue
		var sub := Vector2i(i % sub_size.x, i / sub_size.x)
		var quad := (sub.y % SUBS_PER_TEXTURE) * SUBS_PER_TEXTURE + sub.x % SUBS_PER_TEXTURE
		var at := atlas_coords(rows[desc], quad) * sp
		out.blit_rect(atlas, Rect2i(at, Vector2i.ONE * sp), sub * sp)
	return out

static func terrain_texture(path: String, cell_px: int) -> ImageTexture:
	var bytes := CyrmMap.read_bytes(path)
	var key := [bytes, cell_px]
	if _tex_cache.has(key): return _tex_cache[key]
	var map := CyrmMap.from_bytes(bytes)
	if map.is_empty():
		push_error("TerrainAtlas: 地图为空,无法烘背景 %s" % path)
		var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		return ImageTexture.create_from_image(blank)
	_tex_cache[key] = ImageTexture.create_from_image(_bake_map_image(map, cell_px))
	return _tex_cache[key]
