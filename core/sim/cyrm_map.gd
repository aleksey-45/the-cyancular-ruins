class_name CyrmMap

const FRONT := 0
const SCENE := 1
const BACK := 2
const FIRST_BACKGROUND := 3
const LAYER_COUNT := FIRST_BACKGROUND + 4
const CELL_SIZE := 16
const LAMP_HEIGHT := 5
const MAX_SIZE := Vector2i(1600, 1200)
const NEUTRAL_TINT := Vector4i(4, 4, 4, 7)

# 地图字典的坐标以 16×16 像素子格为单位。每个点位的 ID 在本图内唯一。
static func create(size: Vector2i) -> Dictionary:
	if not _valid_size(size): return {}
	var layers: Array[PackedInt32Array] = []
	for layer in LAYER_COUNT:
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

# 每个子格改动依次存储 x、y 和新值，占 12 字节。
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

static func lamp_support(cell: Vector2i, size: Vector2i) -> int:
	return ((cell.y + 1) % size.y) * size.x + cell.x

static func lamp_problem(map: Dictionary, cell: Vector2i, own_id := -1) -> String:
	var size: Vector2i = map.size
	var scene: PackedInt32Array = map.layers[SCENE]
	if not TileDefs.is_blocked(tile_material(scene[lamp_support(cell, size)])):
		return "灯脚下方需要实心墙"
	for dy in LAMP_HEIGHT:
		if scene[posmod(cell.y - dy, size.y) * size.x + cell.x] != 0:
			return "灯杆需要连续五格空气"
	for id: int in map.points:
		var other: Dictionary = map.points[id]
		if id == own_id or other.kind != "lamp" or other.cell.x != cell.x: continue
		var dy := absi(cell.y - other.cell.y)
		if mini(dy, size.y - dy) < LAMP_HEIGHT:
			return "灯杆与另一盏路灯重叠"
	return ""

static func to_bytes(map: Dictionary) -> PackedByteArray:
	return CyrmStorage.pack(var_to_bytes(map))

static func from_bytes(file: PackedByteArray) -> Dictionary:
	var raw := CyrmStorage.unpack(file)
	if raw.is_empty(): return {}
	var map: Variant = bytes_to_var(raw)
	if not map is Dictionary or not _valid_size(map.size) or map.layers.size() != LAYER_COUNT: return {}
	for layer in LAYER_COUNT:
		var cells: PackedInt32Array = map.layers[layer]
		if cells.size() != map.size.x * map.size.y: return {}
		if layer >= FIRST_BACKGROUND: continue
		for value in cells:
			if value != 0 and (value < 0x1000 or value > 0xFFFFFF or not TileDefs.has_texture(tile_material(value))): return {}
	return map

## 先完整写入同目录的临时文件，再替换目标文件。
static func save_file(map: Dictionary, path: String) -> Error:
	if path.is_empty() or path.begins_with("res://"): return ERR_INVALID_PARAMETER
	var bytes := to_bytes(map)
	if bytes.is_empty(): return ERR_INVALID_DATA
	return AtomicFile.save(path, func(file: FileAccess) -> bool: return file.store_buffer(bytes))

static func load_file(path: String) -> Dictionary:
	return from_bytes(read_bytes(path))

static func read_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return PackedByteArray()
	var length := file.get_length()
	return file.get_buffer(length) if length <= CyrmStorage.MAX_FILE_BYTES else PackedByteArray()
