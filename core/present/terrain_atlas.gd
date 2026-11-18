class_name TerrainAtlas
extends RefCounted

const SKY_COLOR := Color("b0e5f6")
const SOURCE_PATH := "res://assets/textures/structure.png"
const TEX_COUNT := 22
const SRC_COLS := 10
const SRC_TILE := 32
const QUAD_SRC := 8
const QUAD_TILE := 16
const QUAD_COLS := 16
const GROUPS_PER_ROW := 4
const SUB_PER_CELL := MapFormatV4.SUB_PER_CELL
const WATER_BODY_BRICK := 20
const WATER_SURFACE_BRICK := 21

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

# 源砖使用从零开始的图集编号。
static func source_rect(idx: int) -> Rect2i:
	return Rect2i((idx % SRC_COLS) * SRC_TILE, (idx / SRC_COLS) * SRC_TILE, SRC_TILE, SRC_TILE)

static func descriptor_rows(descriptors: PackedInt32Array) -> Dictionary:
	var rows := {}
	for desc in descriptors:
		var tex := MapFormatV4.descriptor_texture(desc)
		if tex > 0 and tex <= TEX_COUNT:
			rows.get_or_add(desc, rows.size())
	return rows

static func atlas_coords(group: int, variant: int) -> Vector2i:
	return Vector2i((group % GROUPS_PER_ROW) * QUAD_COLS + variant, group / GROUPS_PER_ROW)

static func _atlas_image(tile: int, count: int) -> Image:
	var groups := maxi(1, count)
	return Image.create(mini(groups, GROUPS_PER_ROW) * QUAD_COLS * tile,
			ceili(float(groups) / GROUPS_PER_ROW) * tile, false, Image.FORMAT_RGBA8)

## 与编辑器 tint.js 使用相同的 HSV、透明度和字节取整规则。
static func tint_color(color: Color, tint: int) -> Color:
	if (tint & MapFormatV4.TINT_MASK) == MapFormatV4.NEUTRAL_TINT:
		return color
	var r := roundi(color.r * 255.0) / 255.0
	var g := roundi(color.g * 255.0) / 255.0
	var b := roundi(color.b * 255.0) / 255.0
	var peak := maxf(r, maxf(g, b))
	var chroma := peak - minf(r, minf(g, b))
	var hue := 0.0
	if chroma > 0.0:
		if peak == r:
			hue = 60.0 * fposmod((g - b) / chroma, 6.0)
		elif peak == g:
			hue = 60.0 * ((b - r) / chroma + 2.0)
		else:
			hue = 60.0 * ((r - g) / chroma + 4.0)
	hue = fposmod(fposmod(hue, 360.0) + ((tint & 7) - 4) * 15.0, 360.0)
	var saturation_scale := (((tint >> 6) & 7) + 6) / 10.0
	var brightness_scale := (((tint >> 3) & 7) + 6) / 10.0
	var saturation := 0.0 if peak == 0.0 else clampf(chroma / peak * saturation_scale, 0.0, 1.0)
	var value := clampf(peak * brightness_scale, 0.0, 1.0)
	var span := value * saturation
	var offset := value - span
	var mid := span * (1.0 - absf(fposmod(hue / 60.0, 2.0) - 1.0))
	var hi := roundi((span + offset) * 255.0)
	var lo := roundi(offset * 255.0)
	var blend := roundi((mid + offset) * 255.0)
	var alpha_scale := ((tint >> 9) & 7) / 7.0
	var alpha := roundi((roundi(color.a * 255.0) / 255.0) * alpha_scale * 255.0)
	match int(hue / 60.0):
		0: return Color8(hi, blend, lo, alpha)
		1: return Color8(blend, hi, lo, alpha)
		2: return Color8(lo, hi, blend, alpha)
		3: return Color8(lo, blend, hi, alpha)
		4: return Color8(blend, lo, hi, alpha)
		_: return Color8(hi, lo, blend, alpha)

static func _colored_brick(brick: int, tint: int) -> Image:
	var image := source_image().get_region(source_rect(brick))
	if (tint & MapFormatV4.TINT_MASK) != MapFormatV4.NEUTRAL_TINT:
		for y in SRC_TILE:
			for x in SRC_TILE:
				image.set_pixel(x, y, tint_color(image.get_pixel(x, y), tint))
	return image

static func build_atlas_image(rows: Dictionary) -> Image:
	var atlas := _atlas_image(QUAD_TILE, rows.size())
	for desc in rows:
		var brick := _colored_brick(MapFormatV4.descriptor_texture(desc) - 1, desc)
		for quad in QUAD_COLS:
			var origin := Vector2i(quad % SUB_PER_CELL, quad / SUB_PER_CELL) * QUAD_SRC
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

# 水体和水面共用辅码，分别取各自的源砖。
static func water_brick_image(ts: int, brick: int, tint: int = MapFormatV4.NEUTRAL_TINT) -> Image:
	var key := Vector3i(ts, brick, tint & MapFormatV4.TINT_MASK)
	if _brick_cache.has(key):
		return _brick_cache[key]
	var img := _colored_brick(brick, tint)
	img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
	_brick_cache[key] = img
	return img

static func make_water_tileset(ts: int, brick: int, rows: Dictionary) -> TileSet:
	var half := ts / 2
	var atlas := _atlas_image(ts, rows.size())
	for tint in rows:
		var img := water_brick_image(ts, brick, tint)
		for shape in QUAD_COLS:
			var at := atlas_coords(rows[tint], shape) * ts
			for bit in 4:
				if (shape & (1 << bit)) != 0:
					var offset := Vector2i(bit % 2, bit / 2) * half
					atlas.blit_rect(img, Rect2i(offset, Vector2i.ONE * half), at + offset)
	return _tileset(atlas, ts, rows.size())

# 菜单背景复用关卡的子格图集，先将图集合成到天空底色，再整体缩放。
static func _bake_map_image(map: Dictionary, cell_px: int, air: Color) -> Image:
	var sp := maxi(1, cell_px / SUB_PER_CELL)
	var descriptors: PackedInt32Array = map["descriptors"]
	var rows := descriptor_rows(descriptors)
	var atlas := build_atlas_image(rows)
	var flat := Image.create(atlas.get_width(), atlas.get_height(), false, Image.FORMAT_RGBA8)
	flat.fill(air)
	flat.blend_rect(atlas, Rect2i(Vector2i.ZERO, atlas.get_size()), Vector2i.ZERO)
	flat.resize(atlas.get_width() / QUAD_TILE * sp, atlas.get_height() / QUAD_TILE * sp, Image.INTERPOLATE_NEAREST)
	var sub_size: Vector2i = map["size"] * SUB_PER_CELL
	var out := Image.create(sub_size.x * sp, sub_size.y * sp, false, Image.FORMAT_RGBA8)
	out.fill(air)
	for i in descriptors.size():
		var desc := descriptors[i]
		if not rows.has(desc):
			continue
		var sub := Vector2i(i % sub_size.x, i / sub_size.x)
		var quad := (sub.y % SUB_PER_CELL) * SUB_PER_CELL + sub.x % SUB_PER_CELL
		var at := atlas_coords(rows[desc], quad) * sp
		out.blit_rect(flat, Rect2i(at, Vector2i.ONE * sp), sub * sp)
	return out

static func terrain_texture(path: String, cell_px: int, air: Color) -> ImageTexture:
	var map := MapFormat.load_map(path)
	if map.is_empty():
		push_error("TerrainAtlas: 地图为空,无法烘背景 %s" % path)
		var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		blank.fill(air)
		return ImageTexture.create_from_image(blank)
	var key := [map["bytes"], cell_px, air]
	if not _tex_cache.has(key):
		_tex_cache[key] = ImageTexture.create_from_image(_bake_map_image(map, cell_px, air))
	return _tex_cache[key]
