class_name TerrainAtlas
extends RefCounted

enum Channel { DIFFUSE, NORMAL, SPECULAR }
const SOURCES: Array[Texture2D] = [
	preload("res://assets/textures/structure.png"),
	preload("res://assets/textures/structure_normal.png"),
	preload("res://assets/textures/structure_specular.png"),
]
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

static var _src_cache: Dictionary[int, Image] = {}
static var _brick_cache: Dictionary[Vector3i, Image] = {}

static func clear_cache() -> void:
	_src_cache.clear()
	_brick_cache.clear()

static func background_image(map: Dictionary, layer: int) -> Image:
	var bytes: PackedByteArray = map.layers[layer].to_byte_array()
	bytes.bswap32() # 将 0xRRGGBBAA 整数的小端字节顺序转换为图像需要的 R、G、B、A 顺序。
	return Image.create_from_data(map.size.x, map.size.y, false, Image.FORMAT_RGBA8, bytes)

## 返回瓦片在原始图集中的矩形，坐标和尺寸均以纹理像素为单位。
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

static func _brick(tile: int, channel: Channel) -> Image:
	if tile == 0:
		return Image.create_empty(SRC_TILE, SRC_TILE, false, Image.FORMAT_RGBA8)
	if not _src_cache.has(channel):
		var source := SOURCES[channel].get_image()
		source.convert(Image.FORMAT_RGBA8)
		_src_cache[channel] = source
	var image := _src_cache[channel].get_region(source_rect(CyrmMap.tile_material(tile) - 1))
	var tint := CyrmMap.tile_tint(tile)
	if channel == Channel.DIFFUSE and tint != CyrmMap.NEUTRAL_TINT:
		for y in SRC_TILE:
			for x in SRC_TILE:
				image.set_pixel(x, y, tint_color(image.get_pixel(x, y), tint))
	return image

static func _atlas_channel(rows: Dictionary, channel: Channel) -> Image:
	var atlas := _atlas_image(QUAD_TILE, rows.size())
	for desc in rows:
		var brick := _brick(desc, channel)
		brick.resize(SUBS_PER_TEXTURE * QUAD_TILE, SUBS_PER_TEXTURE * QUAD_TILE, Image.INTERPOLATE_NEAREST)
		for quad in QUAD_COLS:
			var origin := Vector2i(quad % SUBS_PER_TEXTURE, quad / SUBS_PER_TEXTURE) * QUAD_TILE
			atlas.blit_rect(brick, Rect2i(origin, Vector2i.ONE * QUAD_TILE), atlas_coords(rows[desc], quad) * QUAD_TILE)
	return atlas

static func _surface(diffuse: Image, normal: Image, specular: Image) -> CanvasTexture:
	var surface := CanvasTexture.new()
	surface.diffuse_texture = ImageTexture.create_from_image(diffuse)
	surface.normal_texture = ImageTexture.create_from_image(normal)
	surface.specular_texture = ImageTexture.create_from_image(specular)
	surface.specular_shininess = 0.6
	return surface

static func make_wall_tileset(rows: Dictionary) -> TileSet:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i.ONE * QUAD_TILE
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = tile_set.tile_size
	atlas.texture = _surface(_atlas_channel(rows, Channel.DIFFUSE), _atlas_channel(rows, Channel.NORMAL),
			_atlas_channel(rows, Channel.SPECULAR))
	tile_set.add_source(atlas)
	for group in rows.size():
		for variant in QUAD_COLS:
			atlas.create_tile(atlas_coords(group, variant))
	return tile_set

static func tile_image(ts: int, tile: int, channel := Channel.DIFFUSE) -> Image:
	var key := Vector3i(ts, tile if channel == Channel.DIFFUSE else CyrmMap.tile_material(tile), channel)
	if _brick_cache.has(key):
		return _brick_cache[key]
	var img := _brick(tile, channel)
	img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
	_brick_cache[key] = img
	return img

static func tile_surface(ts: int, tile: int) -> CanvasTexture:
	return _surface(tile_image(ts, tile), tile_image(ts, tile, Channel.NORMAL), tile_image(ts, tile, Channel.SPECULAR))
