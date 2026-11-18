class_name MapCatalog
extends RefCounted

# 地图选择界面从这里取得地图列表和地形缩略图。列表包括内置地图和外部地图。

const MAP_DIR := "res://maps"
const CELL_PX: int = 2                     # 每块地图瓦片在缩略图中占 2 × 2 像素。
const BG := Color(0.04, 0.07, 0.11, 1.0)
const SOLO_SPAWN := Color(0.35, 0.72, 1.0)
const SIDE_COLORS := {1: Color(0.35, 1.0, 0.45), 2: Color(1.0, 0.62, 0.27)}

# 缩略图用纯色区分地形材质，无需加载墙面和水体纹理。
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
			var respawns: Dictionary = map["spawns"]["respawn"]
			out.append({
				"path": path,
				"name": _display_name(path, map["meta_lines"]),
				"size": map["size"],
				"spawn_counts": Vector2i(respawns[1].size(), respawns[2].size()),
				"external": dir != MAP_DIR,
				"texture": texture(map),
			})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["path"]) < str(b["path"]))
	return out

static func shuffled_paths() -> Array[String]:
	var choices: Array[String] = []
	for dir in [OS.get_executable_path().get_base_dir(), MAP_DIR]:
		var paths := _scan(dir)
		paths.shuffle()
		choices.append_array(paths)
	return choices

static func random_map() -> Dictionary:
	for path in shuffled_paths():
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
	_mark_spawns(img, map["spawns"])
	return img

## 随机地图尚未选定，界面用棋盘格作为占位缩略图。
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
	# 只有四个区域都被占用的瓦片使用原色，其余瓦片调暗。
	if MapFormat.shape_of(v) != 15:
		col = col.lerp(BG, 0.45)
	return col

static func _fill(img: Image, x: int, y: int, color: Color) -> void:
	img.fill_rect(Rect2i(x * CELL_PX, y * CELL_PX, CELL_PX, CELL_PX), color)

static func _mark_spawns(img: Image, spawns: Dictionary) -> void:
	if spawns.has("player"):
		var anchor: Vector2i = spawns["player"]
		# 单人点多画一圈，即便与联机点重合也能看见。
		img.fill_rect(Rect2i(anchor * CELL_PX, Vector2i.ONE * CELL_PX).grow(1), SOLO_SPAWN)
	for side: int in spawns["respawn"]:
		for cell: Vector2i in spawns["respawn"][side]:
			_fill(img, cell.x, cell.y, SIDE_COLORS[side])
