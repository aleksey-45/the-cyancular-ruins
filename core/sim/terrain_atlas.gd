class_name TerrainAtlas
extends RefCounted

# 地形像素的唯一权威:源砖 → 图集 Image → TileSet,以及"整张地图 → 真实地形图"的烘焙(构造那半;铺贴仍在 Level0)。
# ★ 主菜单背景要"真实的那个世界",必须与对局共用同一份映射 —— 复制一份就是第二个真相源(源砖换了/象限映射改了就对不上,且不报错)。
# ★ 零 autoload 依赖(TILE_SIZE 由调用方传参),可被 -s 冒烟直接加载;源砖/水砖/纹理都是会话级静态缓存,而 bake_map_image 返回的 Image 不缓存。

# ★ 世界底色(空气格/清屏色):菜单背景与对局必须同源(对局读本常量);它不是 UI 调色板 token(不归 UiFactory 管),也别拿它改 MapCatalog.BG(那是选图面板缩略图底色)。
const SKY_COLOR: Color = Color("b0e5f6")

const SOURCE_PATH: String = "res://assets/textures/structure.png"
const TEX_COUNT: int = 22      # 源砖 22 块(10 列 × 3 行,每块 32×32);纹理 id 1..22
const SRC_COLS: int = 10       # 源砖表列数
const SRC_TILE: int = 32       # 源砖边长
const QUAD_SRC: int = 8        # 源砖拆成 4×4 个 8×8 象限
const QUAD_TILE: int = 16      # 每个象限最近邻放大 2× → 16×16
const QUAD_COLS: int = 16      # 图集列数 = 4×4 象限
const SUB_PER_CELL: int = 4    # 一个 64px 格 = 4×4 个 16px 子格(与 cyrm v4 网格一致)
# 水体层用的那块源砖 —— 0-based 下标(= 纹理 id − 1),21 = 源砖表第 22 块(与"水"的 id 21 差一,既有画面就是这块砖,别改)。
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

# 16 列(4×4 象限)× 22 行(纹理)的图集:每块源砖的每个 8×8 象限最近邻放大成 16×16;与 Level0 原实现逐像素一致。
static func build_atlas_image() -> Image:
	var src_img := source_image()
	var atlas := Image.create(QUAD_COLS * QUAD_TILE, TEX_COUNT * QUAD_TILE, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for tex in range(TEX_COUNT):
		var src := source_rect(tex)
		for qy in range(4):
			for qx in range(4):
# ★ 每个象限必须一张新图:复用同一张会让 blit 只覆盖左上 8×8,而 resize(16,16) 是空操作 ⇒ 象限互相串味(静默)。
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


# 水体专用 ts×ts 图集(16 形状列):每列 = 水砖按 2×2 形状掩码挖掉缺失象限;形状列与 _paint_water 的 shape_of(v) 对应,不是象限位置。
# ★ 水砖是半透明的(alpha≈0.82),保持原样由渲染端与背景合成,与 Level0 行为逐字一致。
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


# ── 整张地图 → 真实地形图(主菜单背景)──────────────────────────────

# 把一张 .cyrm 按"游戏里那一格长什么样"烘成 Image:地形来源 = MapFormat.load_subgrid + 本类同一份图集(与 Level0 画出的是同一套像素)。
# ★ 空气先与图集合成一遍再缩放:源砖里有半透明(水 ≈0.82、树叶、梯子)与全透明像素,直接 blit 会把原始 RGB(可能是黑)搬过去 ⇒ 梯子/树叶变黑块。
# ★ 本函数不缓存返回值:cell_px = 32 时整张 newfactory 是 4800×3200 ≈ 61MB;要么用 terrain_texture(),要么调用方拿完就丢。
static func bake_map_image(path: String, cell_px: int, air: Color) -> Image:
	var sp: int = maxi(1, cell_px / SUB_PER_CELL)      # 每个子格占几像素
# 图集先与空气色合成(得到不透明全图集),再整体缩到 sp/象限 —— 只做一次原生缩放,不是每个子格各缩一次。
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


# 地形图的纹理版(会话级缓存):缓存纹理而不是 Image,只付一份显存;烘出来的 Image 在建成纹理后即释放。
static func terrain_texture(path: String, cell_px: int, air: Color) -> ImageTexture:
	var key := "%s|%d|%s" % [path, cell_px, str(air)]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var tex := ImageTexture.create_from_image(bake_map_image(path, cell_px, air))
	_tex_cache[key] = tex
	return tex
