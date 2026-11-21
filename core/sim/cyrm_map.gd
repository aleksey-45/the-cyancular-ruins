class_name CyrmMap

const FRONT := 0
const SCENE := 1
const BACK := 2
const COLOR := 3
const CELL_SIZE := 16
const MAX_SIZE := Vector2i(1600, 1200)
const NEUTRAL_TINT := Vector4i(4, 4, 4, 7)

# 所有坐标均为 16 像素子格。点位的键是全图唯一的编辑编号。
static func create(size: Vector2i) -> Dictionary:
	if not _valid_size(size): return {}
	var layers: Array[PackedInt32Array] = []
	for layer in 4:
		var cells := PackedInt32Array()
		cells.resize(size.x * size.y)
		layers.append(cells)
	return {"size": size, "layers": layers, "points": {}, "notes": ""}

static func _valid_size(dims: Vector2i) -> bool:
	return dims.x > 0 and dims.y > 0 and dims.x <= MAX_SIZE.x and dims.y <= MAX_SIZE.y

static func world_position(at: Vector2i) -> Vector2:
	return Vector2(at * CELL_SIZE)

static func cell_at(map: Dictionary, layer: int, at: Vector2i) -> int:
	return map.layers[layer][at.y * map.size.x + at.x]

# 一笔修改连续存放 x、y、值，每格 12 字节。
static func append_cell(changes: PackedInt32Array, x: int, y: int, value: int) -> void:
	changes.append(x)
	changes.append(y)
	changes.append(value)

static func write_cells(map: Dictionary, layer: int, changes: PackedInt32Array) -> void:
	var cells: PackedInt32Array = map.layers[layer]
	var width: int = map.size.x
	for i in range(0, changes.size(), 3):
		cells[changes[i + 1] * width + changes[i]] = changes[i + 2]

## 调色依次为色相、亮度、饱和度、透明度，各取 0–7。空气始终写作 0。
static func tile_value(material_id: int, tint := NEUTRAL_TINT) -> int:
	if material_id == 0:
		return 0
	return (material_id << 12) | tint.x | (tint.y << 3) | (tint.z << 6) | (tint.w << 9)

static func tile_material(value: int) -> int:
	return (value >> 12) & 0xFFF

static func tile_tint(value: int) -> Vector4i:
	if value == 0:
		return NEUTRAL_TINT
	return Vector4i(value & 7, (value >> 3) & 7, (value >> 6) & 7, (value >> 9) & 7)

static func read_region(map: Dictionary, layer: int, area: Rect2i) -> PackedInt32Array:
	var source: PackedInt32Array = map.layers[layer]
	if area.size == map.size: return source.duplicate()
	var result := PackedInt32Array()
	for y in range(area.position.y, area.end.y):
		var start: int = y * map.size.x + area.position.x
		result.append_array(source.slice(start, start + area.size.x))
	return result

static func resized(map: Dictionary, size: Vector2i) -> Dictionary:
	if not _valid_size(size): return {}
	var old: Vector2i = map.size
	var common := size.min(old)
	var layers: Array[PackedInt32Array] = []
	for source: PackedInt32Array in map.layers:
		var cells := PackedInt32Array()
		for y in common.y:
			cells.resize(y * size.x)
			cells.append_array(source.slice(y * old.x, y * old.x + common.x))
		cells.resize(size.x * size.y)
		layers.append(cells)
	var points := {}
	var bounds := Rect2i(Vector2i.ZERO, size)
	for id: int in map.points:
		if bounds.has_point(map.points[id].cell): points[id] = map.points[id]
	return {"size": size, "layers": layers, "points": points, "notes": map.notes}

static func first_point_id(map: Dictionary, kind: String) -> int:
	for id: int in map.points:
		if map.points[id].kind == kind: return id
	return -1

static func to_bytes(map: Dictionary) -> PackedByteArray:
	return CyrmStorage.pack(var_to_bytes(map))

static func from_bytes(file: PackedByteArray) -> Dictionary:
	var raw := CyrmStorage.unpack(file)
	if raw.is_empty(): return {}
	var map: Variant = bytes_to_var(raw)
	if not map is Dictionary or not _valid_size(map.size) or map.layers.size() != 4: return {}
	for layer in 4:
		var cells: PackedInt32Array = map.layers[layer]
		if cells.size() != map.size.x * map.size.y: return {}
		if layer == COLOR: continue
		for value in cells:
			if value != 0 and (value < 0x1000 or value > 0xFFFFFF or not TileDefs.has_texture(tile_material(value))): return {}
	return map

## 同目录临时文件写完后替换目标。
static func save_file(map: Dictionary, path: String) -> Error:
	if path.is_empty() or path.begins_with("res://"): return ERR_INVALID_PARAMETER
	var bytes := to_bytes(map)
	if bytes.is_empty(): return ERR_INVALID_DATA
	var target := ProjectSettings.globalize_path(path)
	var temporary := "%s.%d.%d.tmp" % [target, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var stored := file.store_buffer(bytes)
	file.flush()
	var error := file.get_error() if stored else ERR_FILE_CANT_WRITE
	file.close()
	if error == OK: error = DirAccess.rename_absolute(temporary, target)
	if error != OK:
		DirAccess.remove_absolute(temporary)
	return error

static func load_file(path: String) -> Dictionary:
	return from_bytes(read_bytes(path))

static func read_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return PackedByteArray()
	var length := file.get_length()
	return file.get_buffer(length) if length <= CyrmStorage.MAX_FILE_BYTES else PackedByteArray()
