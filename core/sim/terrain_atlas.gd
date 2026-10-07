class_name TerrainAtlas
extends RefCounted

# 地形像素的**唯一权威**:源砖 → 图集 Image → TileSet,以及"整张地图 → 真实地形图"的烘焙。
#
# - 为什么要有这个类:`structure.png` 的 32×32 源砖**怎么变成屏幕像素**那套映射
#   (拆 4×4 个 8×8 象限 → 各最近邻放大 2× 成 16×16 → 拼成 16 列 × 22 行图集 →
#   一个 64px 格 = 4×4 个 16px 子格,子格取哪个象限由**它在格内的位置** (X%4, Y%4) 推出)
#   原先只住在 `Level0._create_wall_tileset()` 里。主菜单背景要"**真实的那个世界**"
#   就必须用**同一份**映射 —— 复制一份会当场变成第二个真相源(源砖换了 / 象限映射改了,
#   菜单里的世界与游戏里的世界就对不上,而且**不报错**)。
#   - 搬过来的只是**构造**那半(源砖 → 图集 → TileSet);铺贴(`_paint_maze` /
#     `_paint_water`)仍留在 Level0 —— 那半依赖 TileMapLayer 与 3×3 环面副本,
#     和"图集长什么样"是两件事。
#
# - 本类**零 autoload 依赖**(不碰 GameParameters/Settings;TILE_SIZE 由调用方传参),
#   与 MapCatalog / MapFormat 相同设计约束规范  ->  `-s` 冒烟与探针可以直接用它。
# - 源砖图 / 水砖 / 烘出来的**纹理**都是会话级静态缓存(主菜单每次重进都会要同一张图);
#   而 `bake_map_image` 返回的 Image **不缓存** —— 那玩意儿 61MB,见该函数头注。

# - 世界的**底色**(空气格 / 清屏色)。它是"那个世界长什么样"的一部分,且**菜单背景与
#   对局必须同源** —— 用户 2026-10-03 的原话是"背景颜色不对(与对局内不一致)"。
#   对局的落点是 `RenderingServer.set_default_clear_color()`(level_0.gd),那里现在读本常量。
#   - 它不是 UI 调色板 token(不归 `UiFactory` 管),也**不要**拿它去改 `MapCatalog.BG`
#     —— 那个是选图面板缩略图的底色,语义不同。
const SKY_COLOR: Color = Color("b0e5f6")

const SOURCE_PATH: String = "res://assets/textures/structure.png"
const TEX_COUNT: int = 22      # 源砖 22 块(10 列 × 3 行,每块 32×32);纹理 id 1..22
const SRC_COLS: int = 10       # 源砖表列数
const SRC_TILE: int = 32       # 源砖边长
const QUAD_SRC: int = 8        # 源砖拆成 4×4 个 8×8 象限
const QUAD_TILE: int = 16      # 每个象限最近邻放大 2× → 16×16
const QUAD_COLS: int = 16      # 图集列数 = 4×4 象限
const SUB_PER_CELL: int = 4    # 一个 64px 格 = 4×4 个 16px 子格(与 cyrm v4 网格一致)
# 水体层用的那块源砖 —— **0-based 下标**(= 纹理 id − 1),21 = 源砖表第 22 块。
# - 这是 Level0 原实现里的字面量 `Rect2i((21 % 10) * 32, (21 / 10) * 32, …)`,原样带过来:
#   它取的是**下标 21**(纹理 22),与"水"的 id 21 差一 —— 但既有画面就是这一块砖,
#   改它 = 改游戏里水的样子,不在本次提取范围内。菜单那边按纹理 id 取(21 → 行 20)。
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

# 16 列(4×4 象限)× 22 行(纹理)的图集:每块源砖的每个 8×8 象限最近邻放大成 16×16。
# 与 Level0 原实现**逐像素一致**(v4:一个 16px 子格画源块的某个 8×8 象限)。
static func build_atlas_image() -> Image:
	var src_img := source_image()
	var atlas := Image.create(QUAD_COLS * QUAD_TILE, TEX_COUNT * QUAD_TILE, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for tex in range(TEX_COUNT):
		var src := source_rect(tex)
		for qy in range(4):
			for qx in range(4):
				# - 每个象限一张**新**图:复用同一张会让 blit 只覆盖左上 8×8、
				#   而 resize(16,16) 是空操作  ->  象限之间互相串味(静默)。
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


# 水体专用 ts×ts 图集(16 形状列 × 1 行):每列 = 水砖按 2×2 形状掩码挖掉缺失象限。
# - 形状列与 `_paint_water` 的 `MazeGenerator.shape_of(v)` 对应,不是象限位置。
# - 水砖是**半透明**的(alpha≈0.82):这里保持原样,由渲染端与背景合成,
#   与 Level0 的行为逐字一致。
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

# 把一张 .cyrm 按"游戏里那一格长什么样"烘成 Image:
#   - 地形来源 = `MapFormat.load_subgrid`(16px 子格纹理表)+ **本类同一份图集**
#      ->  与 Level0 在屏幕上画出来的是同一套像素,不是另画一张示意色块图。
#   - 一个子格烘成 `cell_px / SUB_PER_CELL` 像素;子格取图集的哪一列 = (y%4)*4 + (x%4),
#     与 `Level0._paint_maze` 的 `Vector2i((y % 4) * 4 + (x % 4), tex - 1)` 同源。
#   - 水:subgrid 里 21/22 两个纹理都在(21 = 水体、22 = 水面),按纹理 id 各取图集行
#      ->  **水也画了**(水体平色 + 水面那一行亮边)。与 Level0 的差别只有"水面不是逐帧起伏的
#     动画、也不是 64px 水体图集",静态背景用不上那两条。
#   - 空气 = `air`(调用方给的底色);先把它与图集合成一遍再缩放:
#     源砖里有半透明(水 ≈0.82、树叶、梯子)与全透明像素,直接 blit 会把那些像素的
#     **原始 RGB**(可能是黑)搬过去  ->  必须先合成到不透明,否则梯子/树叶会变成黑块。
# - 本函数**不缓存**返回值:`cell_px = 32` 时整张 newfactory 是 4800×3200 ≈ 61MB 的 Image,
#   留一份在静态缓存里 = 主菜单常驻 61MB(还没算 GPU 那份)。要么用 `terrain_texture()`
#   (缓存的是纹理),要么调用方自己拿完就丢。
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
