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
# 水体的两块源砖(0-based 下标 = 纹理 id − 1;源砖表 10 列,第 idx 块 = 第 (idx/10) 行第 (idx%10) 列):
const WATER_BODY_BRICK: int = 20        # 纹理 21「水」= 均匀半透明填充
const WATER_SURFACE_BRICK: int = 21     # 纹理 22「水面」= 顶边亮带

static var _src_cache: Image = null
static var _brick_cache: Dictionary = {}    # "ts|idx" → ts×ts 水砖 Image(键必须带 idx,见 water_brick_image)
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


# ── 描述符像素数学(level_editor/tint.js 的移植 = 唯一规范;parity 守卫 = tests/probe/tint_parity_probe.gd)──
# HSV 不是 HSL;色相偏移 = (hue档-4)*15 度(fposmod 360);亮度/饱和度是乘法,乘数 = (档+6)/10;alpha = a*档/7;取整只有一条:round(clamp01(x)*255)。

## 按描述符 tint 一个颜色(纯函数;通道先量化到字节再算,与 tint.js 的 tintBytes 逐字节一致)。
static func tint_color(c: Color, desc: int) -> Color:
	var hue_l := desc & 7
	var bri_l := (desc >> 3) & 7
	var sat_l := (desc >> 6) & 7
	var alp_l := (desc >> 9) & 7
	var r := _byte_of(c.r) / 255.0
	var g := _byte_of(c.g) / 255.0
	var b := _byte_of(c.b) / 255.0
	var a := _byte_of(c.a) / 255.0
	var hsv := _rgb_to_hsv(r, g, b)
	var h2 := fposmod(hsv[0] + float((hue_l - 4) * 15), 360.0)
	var s2 := clampf(hsv[1] * ((sat_l + 6) / 10.0), 0.0, 1.0)
	var v2 := clampf(hsv[2] * ((bri_l + 6) / 10.0), 0.0, 1.0)
	var rgb := _hsv_to_rgb(h2, s2, v2)
	return Color(_byte_of(rgb[0]) / 255.0, _byte_of(rgb[1]) / 255.0, _byte_of(rgb[2]) / 255.0,
			_byte_of(a * float(alp_l) / 7.0) / 255.0)


static func _byte_of(x: float) -> int:
	return clampi(int(round(clampf(x, 0.0, 1.0) * 255.0)), 0, 255)


static func _rgb_to_hsv(r: float, g: float, b: float) -> Array:
	var mx := maxf(maxf(r, g), b)
	var mn := minf(minf(r, g), b)
	var d := mx - mn
	var h := 0.0
	if d != 0.0:
		if mx == r:
			h = 60.0 * fposmod((g - b) / d, 6.0)
		elif mx == g:
			h = 60.0 * ((b - r) / d + 2.0)
		else:
			h = 60.0 * ((r - g) / d + 4.0)
	return [fposmod(h, 360.0), 0.0 if mx == 0.0 else d / mx, mx]


static func _hsv_to_rgb(h: float, s: float, v: float) -> Array:
	var hh := fposmod(h, 360.0)
	var c := v * s
	var x := c * (1.0 - absf(fposmod(hh / 60.0, 2.0) - 1.0))
	var m := v - c
	var r1 := 0.0
	var g1 := 0.0
	var b1 := 0.0
	match int(floor(hh / 60.0)) % 6:
		0: r1 = c; g1 = x
		1: r1 = x; g1 = c
		2: g1 = c; b1 = x
		3: g1 = x; b1 = c
		4: r1 = x; b1 = c
		_: r1 = c; b1 = x
	return [r1 + m, g1 + m, b1 + m]


# ── 墙体图集(16px 象限制,按描述符行烘)────────────────────────────

## 按描述符行烘图集:行 = 传入的描述符序列(调用方给**去重排序后**的列表),每行 16 列象限(4×4 个 8px
## 源象限最近邻 2×);像素 = 源砖(tex-1 槽)对应象限逐像素 tint_color。返回 {"image": Image, "row_of": Dictionary}。
static func build_atlas_image_for(descs: Array) -> Dictionary:
	var src_img := source_image()
	var atlas := Image.create(QUAD_COLS * QUAD_TILE, maxi(descs.size(), 1) * QUAD_TILE, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	var row_of := {}
	for r in descs.size():
		var desc := int(descs[r])
		row_of[desc] = r
		var tex := (desc >> 12) & 0xFFF
		if tex < 1 or tex > TEX_COUNT:
			continue                                # 空气/越界纹理:整行留透明
		var src := source_rect(tex - 1)
		for qy in 4:
			for qx in 4:
# ★ 每个象限必须一张新图:复用同一张会让 blit 只覆盖左上 8×8,而 resize(16,16) 是空操作 ⇒ 象限互相串味(静默)。
				var q := Image.create(QUAD_SRC, QUAD_SRC, false, Image.FORMAT_RGBA8)
				q.blit_rect(src_img, Rect2i(src.position.x + qx * QUAD_SRC,
						src.position.y + qy * QUAD_SRC, QUAD_SRC, QUAD_SRC), Vector2i.ZERO)
				for py in QUAD_SRC:
					for px in QUAD_SRC:
						q.set_pixel(px, py, tint_color(q.get_pixel(px, py), desc))
				q.resize(QUAD_TILE, QUAD_TILE, Image.INTERPOLATE_NEAREST)
				atlas.blit_rect(q, Rect2i(0, 0, QUAD_TILE, QUAD_TILE),
						Vector2i((qy * 4 + qx) * QUAD_TILE, r * QUAD_TILE))
	return {"image": atlas, "row_of": row_of}


## 墙体/所有非空气砖的 TileSet(16×16,16 列象限 × descs.size() 行描述符)。
## 返回 {"tileset": TileSet, "row_of": Dictionary};瓦片坐标 = (象限 qy*4+qx, row_of[desc])。
static func make_wall_tileset_for(descs: Array) -> Dictionary:
	var built := build_atlas_image_for(descs)
	var atlas_img: Image = built["image"]
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(QUAD_TILE, QUAD_TILE)
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(QUAD_TILE, QUAD_TILE)
	atlas.texture = ImageTexture.create_from_image(atlas_img)
	tile_set.add_source(atlas)
	for q in QUAD_COLS:
		for r in maxi(descs.size(), 1):
			atlas.create_tile(Vector2i(q, r))
	return {"tileset": tile_set, "row_of": built["row_of"]}


## 行号回落(纯函数):desc 命中 row_of 直接返回;缺失回落**该纹理的中性描述符行**;再缺返回 0(告警由调用方做)。
static func fallback_row(row_of: Dictionary, desc: int) -> int:
	if row_of.has(desc):
		return int(row_of[desc])
	var neutral := MapFormatV4.neutral_descriptor((desc >> 12) & 0xFFF)
	if row_of.has(neutral):
		return int(row_of[neutral])
	return 0


# ── 水体图集(64px 整格,shape 掩码)────────────────────────────────

# 把指定的水砖(默认 = 水体砖)放大到 ts×ts:水体图集的源图,也是水面合批 shader 的采样源。
# ★ idx 必须由调用方按用途传(WATER_BODY_BRICK / WATER_SURFACE_BRICK);缓存键带 idx —— 只按 ts 缓存会让
#   先来的那个调用把另一个用途的图也拿走(静默串味)。
static func water_brick_image(ts: int, idx: int = WATER_BODY_BRICK) -> Image:
	var key := "%d|%d" % [ts, idx]
	if _brick_cache.has(key):
		return _brick_cache[key]
	var src_img := source_image()
	var img := Image.create(SRC_TILE, SRC_TILE, false, Image.FORMAT_RGBA8)
	img.blit_rect(src_img, source_rect(idx), Vector2i.ZERO)
	img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
	_brick_cache[key] = img
	return img


# 水体专用 ts×ts 图集(中性行):水面合批不消费辅码,水体层的中性回落也用它(历史调用面不变)。
static func make_water_tileset(ts: int) -> TileSet:
	return make_water_tileset_for(ts, [MapFormatV4.neutral_descriptor(WATER_BODY_BRICK + 1)])["tileset"]


## 水体图集按描述符行烘:行 = 传入的描述符序列(去重排序),每行 16 形状列(水砖按 2×2 掩码挖象限);
## 像素 = 水体砖(WATER_BODY_BRICK)逐像素 tint_color。返回 {"tileset": TileSet, "row_of": Dictionary}。
static func make_water_tileset_for(ts: int, descs: Array) -> Dictionary:
	var half: int = ts / 2
	var rows := maxi(descs.size(), 1)
	var atlas_img := Image.create(16 * ts, rows * ts, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color(0, 0, 0, 0))
	var row_of := {}
	for r in descs.size():
		var desc := int(descs[r])
		row_of[desc] = r
		var img := _tinted_water_brick(ts, desc)
		for shape in 16:
			var tile := img.duplicate()
			for sy in 2:
				for sx in 2:
					if (shape & (1 << (sy * 2 + sx))) == 0:
						tile.fill_rect(Rect2i(sx * half, sy * half, half, half), Color(0, 0, 0, 0))
			atlas_img.blit_rect(tile, Rect2i(0, 0, ts, ts), Vector2i(shape * ts, r * ts))
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(ts, ts)
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(ts, ts)
	atlas.texture = ImageTexture.create_from_image(atlas_img)
	tile_set.add_source(atlas)
	for shape in 16:
		for r in rows:
			atlas.create_tile(Vector2i(shape, r))
	return {"tileset": tile_set, "row_of": row_of}


# 按描述符 tint 过的水体砖(ts×ts)。中性描述符 = 逐字节恒等(tint_color 的恒等性由 tint_parity_probe 穷举守)。
static func _tinted_water_brick(ts: int, desc: int) -> Image:
	var img := water_brick_image(ts, WATER_BODY_BRICK).duplicate()
	if desc == MapFormatV4.neutral_descriptor(WATER_BODY_BRICK + 1):
		return img
	for y in ts:
		for x in ts:
			img.set_pixel(x, y, tint_color(img.get_pixel(x, y), desc))
	return img


# ── 整张地图 → 真实地形图(主菜单背景)──────────────────────────────

# 把一张 .cyrm 按"游戏里那一格长什么样"烘成 Image:地形来源 = MapFormat.load_subgrid_with_descs 的
static func bake_map_image(path: String, cell_px: int, air: Color) -> Image:
	var sp: int = maxi(1, cell_px / SUB_PER_CELL)      # 每个子格占几像素
	var descgrid: Array = MapFormat.load_subgrid_with_descs(path)["descs"]
	if descgrid.is_empty():
		push_error("TerrainAtlas: 地图为空,无法烘背景 %s" % path)
		var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		blank.fill(air)
		return blank
	var uniq := {}
	for drow in descgrid:
		for d in drow:
			if int(d) != 0:
				uniq[int(d)] = true
	var descs: Array = uniq.keys()
	descs.sort()
	if descs.is_empty():
		descs.append(MapFormatV4.neutral_descriptor(1))   # 全空气图:仍要一行,否则图集高度为 0
	var built := build_atlas_image_for(descs)
	var row_of: Dictionary = built["row_of"]
# 图集先与空气色合成(得到不透明全图集),再整体缩到 sp/象限 —— 只做一次原生缩放,不是每个子格各缩一次。
	var flat := Image.create(QUAD_COLS * QUAD_TILE, descs.size() * QUAD_TILE, false, Image.FORMAT_RGBA8)
	flat.fill(air)
	flat.blend_rect(built["image"], Rect2i(0, 0, flat.get_width(), flat.get_height()), Vector2i.ZERO)
	var small := flat.duplicate()
	small.resize(QUAD_COLS * sp, descs.size() * sp, Image.INTERPOLATE_NEAREST)

	var rows := descgrid.size()
	var cols: int = (descgrid[0] as Array).size()
	var out := Image.create(cols * sp, rows * sp, false, Image.FORMAT_RGBA8)
	out.fill(air)
	for y in rows:
		var drow: Array = descgrid[y]
		var qy := y % SUB_PER_CELL
		for x in cols:
			var d := int(drow[x])
			var tex := (d >> 12) & 0xFFF
			if tex < 1 or tex > TEX_COUNT:
				continue                                # 0 = 空气;越界纹理当空气
			var col := qy * SUB_PER_CELL + (x % SUB_PER_CELL)
			out.blit_rect(small, Rect2i(col * sp, int(row_of[d]) * sp, sp, sp), Vector2i(x * sp, y * sp))
	return out


# 地形图的纹理版(会话级缓存):缓存纹理而不是 Image,只付一份显存;烘出来的 Image 在建成纹理后即释放。
static func terrain_texture(path: String, cell_px: int, air: Color) -> ImageTexture:
	var key := "%s|%d|%s" % [path, cell_px, str(air)]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var tex := ImageTexture.create_from_image(bake_map_image(path, cell_px, air))
	_tex_cache[key] = tex
	return tex
