class_name TerrainAtlas
extends RefCounted

# 地形渲染图集生成器与地图地形图像烘焙工具。
# 负责将 structure.png 源贴图解析为 16 列 x 22 行的子格图集，
# 并为关卡与菜单背景提供一致的地形像素渲染支持。
# 纯静态工具类，零 Autoload 依赖。

# 世界天空气氛底色（空气瓦片底色），供关卡清屏色与菜单背景渲染共用。
const SKY_COLOR: Color = Color("b0e5f6")

const SOURCE_PATH: String = "res://assets/textures/structure.png"
const TEX_COUNT: int = 22      # 源砖 22 块(10 列 × 3 行,每块 32×32);纹理 id 1..22
const SRC_COLS: int = 10       # 源砖表列数
const SRC_TILE: int = 32       # 源砖边长
const QUAD_SRC: int = 8        # 源砖拆成 4×4 个 8×8 象限
const QUAD_TILE: int = 16      # 每个象限最近邻放大 2× → 16×16
const QUAD_COLS: int = 16      # 图集列数 = 4×4 象限
const SUB_PER_CELL: int = 4    # 一个 64px 格 = 4×4 个 16px 子格(与 cyrm v4 网格一致)
# 水体层引用的源砖瓦片索引（从 0 开始计数，21 对应源砖表第 22 块）。
const WATER_LAYER_BRICK: int = 21

static var _src_cache: Image = null
static var _brick_cache: Dictionary = {}    # ts → ts×ts 水砖 Image
static var _tex_cache: Dictionary = {}      # "path|cell_px|air" → ImageTexture


static func clear_cache() -> void:
	_src_cache = null
	_brick_cache.clear()
	_tex_cache.clear()


# ── 源砖表 ─────────────────────────────────────────────────────────

static func source_image() -> Image:
	if _src_cache == null:
		var tex: Texture2D = load(SOURCE_PATH)
		if tex == null:
			push_error("TerrainAtlas: 找不到源砖图 %s" % SOURCE_PATH)
			_src_cache = Image.create(1, 1, false, Image.FORMAT_RGBA8)
		else:
			_src_cache = tex.get_image()
	return _src_cache


# 第 idx 块源砖(0-based,idx = 纹理 id - 1)在源砖表里的矩形。
static func source_rect(idx: int) -> Rect2i:
	return Rect2i((idx % SRC_COLS) * SRC_TILE, (idx / SRC_COLS) * SRC_TILE, SRC_TILE, SRC_TILE)


# ── 墙体图集(16px 象限制)──────────────────────────────────────────

# 16 列（4x4 象限）x 22 行（纹理）图集：每块源砖的每个 8x8 象限最近邻放大为 16x16。
static func build_atlas_image() -> Image:
	var src_img := source_image()
	var atlas := Image.create(QUAD_COLS * QUAD_TILE, TEX_COUNT * QUAD_TILE, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for tex in range(TEX_COUNT):
		var src := source_rect(tex)
		for qy in range(4):
			for qx in range(4):
				# 每个象限独立创建图像并缩放，避免脏区域相互污染
				var q := Image.create(QUAD_SRC, QUAD_SRC, false, Image.FORMAT_RGBA8)
				q.blit_rect(src_img, Rect2i(src.position.x + qx * QUAD_SRC,
						src.position.y + qy * QUAD_SRC, QUAD_SRC, QUAD_SRC), Vector2i.ZERO)
				q.resize(QUAD_TILE, QUAD_TILE, Image.INTERPOLATE_NEAREST)
				atlas.blit_rect(q, Rect2i(0, 0, QUAD_TILE, QUAD_TILE),
						Vector2i((qy * 4 + qx) * QUAD_TILE, tex * QUAD_TILE))
	return atlas


# 墙体/所有非空气砖的 TileSet(16×16,16 列象限 × 22 行纹理)。
static func make_wall_tileset() -> TileSet:
	var atlas_img := build_atlas_image()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(QUAD_TILE, QUAD_TILE)
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(QUAD_TILE, QUAD_TILE)
	atlas.texture = ImageTexture.create_from_image(atlas_img)
	tile_set.add_source(atlas)
	for q in range(QUAD_COLS):
		for tex in range(TEX_COUNT):
			atlas.create_tile(Vector2i(q, tex))
	return tile_set


# ── 水体图集(64px 整格,shape 掩码)────────────────────────────────

# 水体层那块源砖放大到 ts×ts——水面合批 shader 的采样源,也是水体图集的源图。
static func water_brick_image(ts: int) -> Image:
	if _brick_cache.has(ts):
		return _brick_cache[ts]
	var src_img := source_image()
	var img := Image.create(SRC_TILE, SRC_TILE, false, Image.FORMAT_RGBA8)
	img.blit_rect(src_img, source_rect(WATER_LAYER_BRICK), Vector2i.ZERO)
	img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
	_brick_cache[ts] = img
	return img


# 构建水体专用的 TileSet 图集（包含 16 种 2x2 掩码形态）。
static func make_water_tileset(ts: int) -> TileSet:
	var img := water_brick_image(ts)
	var half: int = ts / 2
	var atlas_img := Image.create(16 * ts, ts, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color(0, 0, 0, 0))
	for shape in range(16):
		var tile := img.duplicate()
		for sy in range(2):
			for sx in range(2):
				if (shape & (1 << (sy * 2 + sx))) == 0:
					tile.fill_rect(Rect2i(sx * half, sy * half, half, half), Color(0, 0, 0, 0))
		atlas_img.blit_rect(tile, Rect2i(0, 0, ts, ts), Vector2i(shape * ts, 0))
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(ts, ts)
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(ts, ts)
	atlas.texture = ImageTexture.create_from_image(atlas_img)
	tile_set.add_source(atlas)
	for shape in range(16):
		atlas.create_tile(Vector2i(shape, 0))
	return tile_set


# ── 地图地形图烘焙（主菜单背景等场景）──

# 将 .cyrm 地图烘焙为完整的地形 Image：
# 1. 地形数据基于 16px 子格表与标准图集像素，与关卡实际渲染保持一致；
# 2. 结合 air 底色预先合成半透明与镂空像素，避免产生黑色边缘；
# 3. 大图尺寸较大，调用方使用后按需释放。
static func bake_map_image(path: String, cell_px: int, air: Color) -> Image:
	var sp: int = maxi(1, cell_px / SUB_PER_CELL)      # 每个子格占几像素
	# 图集先与空气色合成(得到一张不透明的全图集),再整体缩到 sp/象限 —— 只做一次
	# 原生缩放,而不是对每个子格各缩一次。
	var atlas := build_atlas_image()
	var flat := Image.create(QUAD_COLS * QUAD_TILE, TEX_COUNT * QUAD_TILE, false, Image.FORMAT_RGBA8)
	flat.fill(air)
	flat.blend_rect(atlas, Rect2i(0, 0, flat.get_width(), flat.get_height()), Vector2i.ZERO)
	var small := flat.duplicate()
	small.resize(QUAD_COLS * sp, TEX_COUNT * sp, Image.INTERPOLATE_NEAREST)

	var subgrid := MapFormat.load_subgrid(path)
	if subgrid.is_empty():
		push_error("TerrainAtlas: 地图为空,无法烘背景 %s" % path)
		var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		blank.fill(air)
		return blank
	var rows := subgrid.size()
	var cols: int = (subgrid[0] as Array).size()
	var out := Image.create(cols * sp, rows * sp, false, Image.FORMAT_RGBA8)
	out.fill(air)
	for y in range(rows):
		var row: Array = subgrid[y]
		var qy := y % SUB_PER_CELL
		for x in range(cols):
			var tex := int(row[x])
			if tex < 1 or tex > TEX_COUNT:
				continue                                # 0 = 空气;越界纹理当空气
			var col := qy * SUB_PER_CELL + (x % SUB_PER_CELL)
			out.blit_rect(small, Rect2i(col * sp, (tex - 1) * sp, sp, sp), Vector2i(x * sp, y * sp))
	return out


# 地形图的纹理版(会话级缓存)。主菜单每进一次都要同一张图 —— 缓存纹理而不是 Image,
# 只付一份显存;烘一次的 Image 在建成纹理后即被释放。
static func terrain_texture(path: String, cell_px: int, air: Color) -> ImageTexture:
	var key := "%s|%d|%s" % [path, cell_px, str(air)]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var tex := ImageTexture.create_from_image(bake_map_image(path, cell_px, air))
	_tex_cache[key] = tex
	return tex
