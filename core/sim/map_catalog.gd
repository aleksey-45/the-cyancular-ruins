class_name MapCatalog
extends RefCounted

# 地图选择界面从这里取得地图列表和地形缩略图。列表包括内置地图和外部地图。

const MAP_DIR := "res://maps"
const USER_DIR := "user://maps"
const CACHE_SIZE := 8
const BG := Color(0.04, 0.07, 0.11, 1.0)
const SOLO_SPAWN := Color(0.35, 0.72, 1.0)
const SIDE_COLORS := {1: Color(0.35, 1.0, 0.45), 2: Color(1.0, 0.62, 0.27)}

static var _entries: Dictionary[PackedByteArray, Dictionary] = {}
static var _random_texture: ImageTexture

static func _directories() -> Array[String]:
	return [USER_DIR, OS.get_executable_path().get_base_dir(), MAP_DIR]

static func list_maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for dir in _directories():
		for path in _scan(dir):
			var entry := _entry(path)
			if entry.is_empty(): continue
			out.append(entry.merged({"path": path, "name": _display_name(path, entry.notes), "external": dir != MAP_DIR}))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["path"]) < str(b["path"]))
	return out

static func shuffled_paths() -> Array[String]:
	var choices: Array[String] = []
	for dir in _directories():
		var paths := _scan(dir)
		paths.shuffle()
		choices.append_array(paths)
	return choices

static func random_map() -> Dictionary:
	for path in shuffled_paths():
		var map := CyrmMap.load_file(path)
		if not map.is_empty():
			return map
	return {}

static func _display_name(path: String, notes: String) -> String:
	for line in notes.split("\n", false):
		var text := line.strip_edges()
		if text.is_empty(): continue
		if not text.begins_with("#"):
			break
		var title := text.substr(1).strip_edges()
		if not title.is_empty() and not title.begins_with("cyrm"):
			return title
	return path.get_file().get_basename()

static func _entry(path: String) -> Dictionary:
	var bytes := CyrmMap.read_bytes(path)
	if _entries.has(bytes): return _entries[bytes]
	var map := CyrmMap.from_bytes(bytes)
	if map.is_empty(): return {}
	if _entries.size() >= CACHE_SIZE: _entries.erase(_entries.keys()[0])
	var sides := SpawnPicker.respawn_cells(map)
	var entry := {"size": map.size, "notes": map.notes, "spawn_counts": Vector2i(sides[1].size(), sides[2].size()),
			"texture": ImageTexture.create_from_image(_build_image(map, sides))}
	_entries[bytes] = entry
	return entry

static func _build_image(map: Dictionary, sides: Dictionary) -> Image:
	var size: Vector2i = map.size
	var cells: PackedInt32Array = map.layers[CyrmMap.SCENE]
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(BG)
	for i in cells.size():
		if cells[i] != 0:
			img.set_pixel(i % size.x, i / size.x, TileDefs.preview[CyrmMap.tile_material(cells[i])])
	var player := CyrmMap.first_point_id(map, "player")
	if player >= 0:
		img.fill_rect(Rect2i(map.points[player].cell, Vector2i.ONE).grow(3), SOLO_SPAWN)
	for side: int in sides:
		for at: Vector2i in sides[side]:
			img.fill_rect(Rect2i(at, Vector2i.ONE).grow(1), SIDE_COLORS[side])
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
