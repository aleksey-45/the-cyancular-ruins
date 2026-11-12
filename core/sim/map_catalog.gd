class_name MapCatalog
extends RefCounted

# 扫描内置与外置地图，用解析出的地图数据生成缩略图。

const MAP_DIR := "res://maps"
const CELL_PX: int = 2                     # 每格 2px:125×75 → 250×150;150×100 → 300×200
const BG := Color(0.04, 0.07, 0.11, 1.0)   # 空气 = 背景
const SPAWN_P1 := Color(0.35, 1.0, 0.45, 1.0)
const SPAWN_P2 := Color(0.35, 0.72, 1.0, 1.0)

# 瓦片配色(纹理 id → 颜色),与 ui/minimap.gd 的观感保持一致:
# 墙、梯、链、树叶、树干和水体的材质标记色。
const PALETTE := {
	1: Color(0.72, 0.76, 0.82), 6: Color(0.52, 0.56, 0.63),
	7: Color(0.48, 0.52, 0.59), 8: Color(0.44, 0.48, 0.55), 9: Color(0.40, 0.44, 0.51),
	10: Color(0.36, 0.40, 0.47),
	11: Color(0.80, 0.66, 0.34),
	12: Color(0.55, 0.55, 0.60), 13: Color(0.48, 0.48, 0.53), 14: Color(0.42, 0.42, 0.47),
	15: Color(0.34, 0.66, 0.34),
	19: Color(0.46, 0.33, 0.22), 20: Color(0.40, 0.29, 0.19),
	21: Color(0.14, 0.36, 0.82), 22: Color(0.26, 0.56, 0.95),
}

static var _textures: Dictionary[PackedByteArray, ImageTexture] = {}
static var _random_texture: ImageTexture

static func list_maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for dir in [MAP_DIR, OS.get_executable_path().get_base_dir()]:
		for path in _scan(dir):
			var map := MapFormat.load_map(path)
			if map.is_empty():
				continue
			var spawns: Dictionary = map["spawns"]
			out.append({
				"path": path,
				"name": _display_name(path, map["meta_lines"]),
				"size": map["size"],
				"pvp": spawns.has("player") and spawns.has("player2"),
				"external": dir != MAP_DIR,
				"texture": texture(map),
			})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["path"]) < str(b["path"]))
	return out

static func random_map() -> Dictionary:
	for dir in [OS.get_executable_path().get_base_dir(), MAP_DIR]:
		var paths := _scan(dir)
		paths.shuffle()
		for path in paths:
			var map := MapFormat.load_map(path)
			if not map.is_empty():
				return map
	return {}

static func _display_name(path: String, meta_lines: Array) -> String:
	for line in meta_lines:
		var text := String(line).strip_edges()
		if not text.begins_with("#"):
			break
		var title := text.substr(1).strip_edges()
		if title == "" or title.begins_with("cyrm") or title.begins_with("player") \
				or title.begins_with("enemy") or title.begins_with("respawn"):
			continue
		return title
	return path.get_file().get_basename()

static func texture(map: Dictionary) -> ImageTexture:
	var bytes: PackedByteArray = map["bytes"]
	if not _textures.has(bytes):
		if _textures.size() >= MapFormat.CACHE_SIZE:
			_textures.erase(_textures.keys()[0])
		_textures[bytes] = ImageTexture.create_from_image(_build_image(map))
	return _textures[bytes]

static func _build_image(map: Dictionary) -> Image:
	var size: Vector2i = map["size"]
	var grid: Array[Array] = map["grid"]
	var img := Image.create(size.x * CELL_PX, size.y * CELL_PX, false, Image.FORMAT_RGBA8)
	img.fill(BG)
	for y in size.y:
		for x in size.x:
			var value: int = grid[y][x]
			if value != MapFormat.EMPTY:
				_fill(img, x, y, _color_of(value))
	_mark_spawn(img, map["spawns"])
	return img

## 随机卡片的棋盘格占位图。
static func random_texture() -> ImageTexture:
	if _random_texture == null:
		var n := 64
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		for y in n:
			for x in n:
				var on := ((x / 8) + (y / 8)) % 2 == 0
				img.set_pixel(x, y, Color(0.16, 0.20, 0.28) if on else Color(0.10, 0.13, 0.19))
		_random_texture = ImageTexture.create_from_image(img)
	return _random_texture

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
	return out

static func _color_of(v: int) -> Color:
	var tex := MapFormat.texture_of(v)
	var col: Color = PALETTE.get(tex, Color(0.6, 0.6, 0.62))
	# 半砖/缺角(形状 != 15)压暗一点:简略图上能看出"这格是半格",与实际可走性相符
	if MapFormat.shape_of(v) != 15:
		col = col.lerp(BG, 0.45)
	return col

static func _fill(img: Image, x: int, y: int, color: Color) -> void:
	img.fill_rect(Rect2i(x * CELL_PX, y * CELL_PX, CELL_PX, CELL_PX), color)

static func _mark_spawn(img: Image, sp: Dictionary) -> void:
	for key in ["player", "player2"]:
		if not sp.has(key):
			continue
		var cell: Vector2i = sp[key]
		var col := SPAWN_P1 if key == "player" else SPAWN_P2
		_fill(img, cell.x, cell.y, col)
