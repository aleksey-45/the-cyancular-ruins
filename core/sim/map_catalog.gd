class_name MapCatalog
extends RefCounted

# 地图目录(选图 UI + 联机定图的**单一来源**):
#   · 列出可用 .cyrm(res://maps/ + exe 旁的开发者地图,与 MazeGenerator 的取图规则同源)
#   · 判定"能不能打联机"(是否两个出生点都有)与地图尺寸
#   · 生成**开局简略图**(每格 1 像素的色块图,由 UI 侧转成纹理)
#   · 服务器侧校验客户端上报的地图路径(联机定图时**只能**用仓内 res://maps/*.cyrm)
#
# ★ 本类**不引任何 autoload**(Settings/RunOptions 一律不碰),这样 `-s` 探针能直接用它;
#   也只返回 `Image` 纯数据、不碰渲染 —— 缩略图"内容对不对"才机器可验(纹理由 UI 侧包)。
# ★ 缓存是会话级的(静态);探针改完语料/想重扫时调 `clear_cache()`。

const CELL_PX: int = 2                     # 每格 2px:125×75 → 250×150;150×100 → 300×200
const BG := Color(0.04, 0.07, 0.11, 1.0)   # 空气 = 背景
const SPAWN_P1 := Color(0.35, 1.0, 0.45, 1.0)
const SPAWN_P2 := Color(0.35, 0.72, 1.0, 1.0)

# 瓦片配色(纹理 id → 颜色),与 ui/minimap.gd 的观感保持一致:
# 1-10 墙(冷灰阶,越深越"硬")/ 11 梯 / 12-14 链 / 15-18 树叶 / 19-20 树干 / 21-22 水。
const PALETTE := {
	1: Color(0.72, 0.76, 0.82), 2: Color(0.68, 0.72, 0.79), 3: Color(0.64, 0.68, 0.75),
	4: Color(0.60, 0.64, 0.71), 5: Color(0.56, 0.60, 0.67), 6: Color(0.52, 0.56, 0.63),
	7: Color(0.48, 0.52, 0.59), 8: Color(0.44, 0.48, 0.55), 9: Color(0.40, 0.44, 0.51),
	10: Color(0.36, 0.40, 0.47),
	11: Color(0.80, 0.66, 0.34),
	12: Color(0.55, 0.55, 0.60), 13: Color(0.48, 0.48, 0.53), 14: Color(0.42, 0.42, 0.47),
	15: Color(0.34, 0.66, 0.34), 16: Color(0.29, 0.58, 0.30), 17: Color(0.24, 0.50, 0.26),
	18: Color(0.20, 0.43, 0.22),
	19: Color(0.46, 0.33, 0.22), 20: Color(0.40, 0.29, 0.19),
	21: Color(0.14, 0.36, 0.82), 22: Color(0.26, 0.56, 0.95),
}

static var _img_cache: Dictionary = {}     # "path|cell_px" → Image
static var _tex_cache: Dictionary = {}     # "path|cell_px" → ImageTexture
static var _list_cache: Array = []
static var _random_img: Image = null


static func clear_cache() -> void:
	_img_cache.clear()
	_tex_cache.clear()
	_list_cache.clear()
	_random_img = null


# ── 目录 ───────────────────────────────────────────────────────────

## 全部可用地图。每项:
##   {path: String, name: String, size: Vector2i, pvp: bool, external: bool}
## pvp = 同时有 `# player` 与 `# player2`(联机双出生点的契约)。
static func list_maps(refresh := false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not refresh and not _list_cache.is_empty():
		out.assign(_list_cache)
		return out
	var seen := {}
	for dir in _dirs():
		for path in _scan(dir):
			if seen.has(path):
				continue
			seen[path] = true
			if not is_valid_map(path):
				continue
			var sp := MapFormat.load_spawns(path)
			out.append({
				"path": path,
				"name": display_name(path),
				"size": MapFormat.map_size(path),
				"pvp": sp.has("player") and sp.has("player2"),
				"external": not path.begins_with(MazeGenerator.MAP_DIR + "/"),
			})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["path"]) < str(b["path"]))
	_list_cache = out
	return out


## 地图显示名:优先取文件头注释里的名字行(demo.cyrm 的 `# demo_2`),否则用文件名。
static func display_name(path: String) -> String:
	if FileAccess.file_exists(path):
		# ★ 用 load_meta_lines 而不是 read_lines:v4 的注释在 body 的 meta 文本里,
		#   直接按文本行读二进制只会读到乱码头,名字会退化成文件名。
		for l in MapFormat.load_meta_lines(path):
			var s := String(l).strip_edges()
			if not s.begins_with("#"):
				break                    # 注释块结束 → 不再往下找
			var t := s.substr(1).strip_edges()
			if t == "" or t.begins_with("cyrm") or t.begins_with("player") \
					or t.begins_with("enemy"):
				continue
			return t
	return path.get_file().get_basename()


static func is_valid_map(path: String) -> bool:
	if path == "" or not path.to_lower().ends_with(".cyrm"):
		return false
	if not FileAccess.file_exists(path):
		return false
	return not MapFormat.load_map_file(path).is_empty()


static func has_pvp_spawn(path: String) -> bool:
	var sp := MapFormat.load_spawns(path)
	return sp.has("player") and sp.has("player2")


## 服务器侧校验:客户端上报的联机定图路径。**只认仓内 `res://maps/*.cyrm`** ——
## exe 旁的开发者地图在别的机器上不存在,联机用它会一端加载失败。
## 拒绝:空 / 非 .cyrm / 越出 maps 目录(含 `..`)/ 不存在 / 无第二出生点。
## 返回 "" = 用不了(调用方回落默认图)。
static func resolve_pvp_map(requested: String) -> String:
	var pref := MazeGenerator.MAP_DIR + "/"
	if requested == "" or not requested.begins_with(pref):
		return ""
	if requested.contains("..") or not requested.to_lower().ends_with(".cyrm"):
		return ""
	if not FileAccess.file_exists(requested):
		return ""
	if not has_pvp_spawn(requested):
		return ""
	return requested


# ── 简略图(纯 Image;UI 侧自己 create_from_image)──────────────────

## 开局地形简略图:每格 cell_px 像素,空气=背景,墙体按纹理配色(半砖压暗),
## 出生点画成亮色块(绿=P1 / 蓝=P2)。
static func build_image(path: String, cell_px: int = CELL_PX) -> Image:
	var key := "%s|%d" % [path, cell_px]
	if _img_cache.has(key):
		return _img_cache[key]
	var grid := MapFormat.load_map_file(path)
	var img: Image
	if grid.is_empty():
		img = Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(BG)
	else:
		var rows := grid.size()
		var cols: int = (grid[0] as Array).size()
		img = Image.create(cols * cell_px, rows * cell_px, false, Image.FORMAT_RGBA8)
		img.fill(BG)
		for r in rows:
			var line: Array = grid[r]
			for c in min(cols, line.size()):
				var v := int(line[c])
				if v == 0:
					continue
				_fill(img, c, r, cell_px, _color_of(v))
		_mark_spawn(img, path, cell_px, rows, cols)
	_img_cache[key] = img
	return img


static func texture(path: String, cell_px: int = CELL_PX) -> ImageTexture:
	var key := "%s|%d" % [path, cell_px]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var t := ImageTexture.create_from_image(build_image(path, cell_px))
	_tex_cache[key] = t
	return t


## "随机"卡片的占位图(棋盘格):不是某张图的简略图,避免与真实地图混淆。
static func random_texture() -> ImageTexture:
	if _random_img == null:
		var n := 64
		_random_img = Image.create(n, n, false, Image.FORMAT_RGBA8)
		for y in n:
			for x in n:
				var on := ((x / 8) + (y / 8)) % 2 == 0
				_random_img.set_pixel(x, y, Color(0.16, 0.20, 0.28) if on else Color(0.10, 0.13, 0.19))
	return ImageTexture.create_from_image(_random_img)


# ── 内部 ───────────────────────────────────────────────────────────

static func _dirs() -> Array[String]:
	var out: Array[String] = [MazeGenerator.MAP_DIR]
	var ext := OS.get_executable_path().get_base_dir()
	if ext != "" and ext != MazeGenerator.MAP_DIR:
		out.append(ext)
	return out


static func _scan(dir: String) -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			out.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	out.sort()
	return out


static func _color_of(v: int) -> Color:
	var tex := MapFormat.texture_of(v)
	var col: Color = PALETTE.get(tex, Color(0.6, 0.6, 0.62))
	# 半砖/缺角(形状 != 15)压暗一点:简略图上能看出"这格是半格",与实际可走性相符
	if MapFormat.shape_of(v) != 15:
		col = col.lerp(BG, 0.45)
	return col


static func _fill(img: Image, c: int, r: int, cell_px: int, col: Color) -> void:
	var x0 := c * cell_px
	var y0 := r * cell_px
	for dy in cell_px:
		for dx in cell_px:
			img.set_pixel(x0 + dx, y0 + dy, col)


static func _mark_spawn(img: Image, path: String, cell_px: int, rows: int, cols: int) -> void:
	var sp := MapFormat.load_spawns(path)
	for key in ["player", "player2"]:
		if not sp.has(key):
			continue
		var cell: Vector2i = sp[key]
		if cell.x < 0 or cell.y < 0:
			continue
		var col := SPAWN_P1 if key == "player" else SPAWN_P2
		_fill(img, posmod(cell.x, cols), posmod(cell.y, rows), cell_px, col)
