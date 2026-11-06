class_name MapCatalog
extends RefCounted

# 地图目录(选图 UI + 联机定图的单一来源):

const CELL_PX: int = 2
const BG := Color(0.04, 0.07, 0.11, 1.0)
const SPAWN_P1 := Color(0.35, 1.0, 0.45, 1.0)
const SPAWN_P2 := Color(0.35, 0.72, 1.0, 1.0)

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

static var _img_cache: Dictionary = {}
static var _tex_cache: Dictionary = {}
static var _list_cache: Array = []
static var _random_img: Image = null


static func clear_cache() -> void:
	_img_cache.clear()
	_tex_cache.clear()
	_list_cache.clear()
	_random_img = null



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


static func display_name(path: String) -> String:
	if FileAccess.file_exists(path):
		for l in MapFormat.load_meta_lines(path):
			var s := String(l).strip_edges()
			if not s.begins_with("#"):
				break
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


static func random_texture() -> ImageTexture:
	if _random_img == null:
		var n := 64
		_random_img = Image.create(n, n, false, Image.FORMAT_RGBA8)
		for y in n:
			for x in n:
				var on := ((x / 8) + (y / 8)) % 2 == 0
				_random_img.set_pixel(x, y, Color(0.16, 0.20, 0.28) if on else Color(0.10, 0.13, 0.19))
	return ImageTexture.create_from_image(_random_img)



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
