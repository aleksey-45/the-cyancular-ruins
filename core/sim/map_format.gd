class_name MapFormat
extends RefCounted

# 游戏与编辑器统一使用 v4。
const EMPTY: int = 0
const CACHE_SIZE := 8
static var _maps: Dictionary[PackedByteArray, Dictionary] = {}

# 64px 格的纹理编号和 2×2 象限掩码；0 表示空气。
static func pack(texture: int, shape: int) -> int:
	return texture * 16 + shape if texture != 0 and shape != 0 else EMPTY

static func texture_of(value: int) -> int:
	return value / 16

static func shape_of(value: int) -> int:
	return value % 16

static func load_map(path: String) -> Dictionary:
	if path.get_extension().to_lower() != "cyrm":
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	return parse_map(file.get_buffer(file.get_length()), path)

# 本地文件和联机基线按原始字节共用地图数据。
static func parse_map(bytes: PackedByteArray, source: String) -> Dictionary:
	if _maps.has(bytes):
		return _maps[bytes]
	var parsed := MapFormatV4.parse(bytes)
	if not parsed["ok"]:
		push_error("MapFormat: %s (%s)" % [source, parsed["error"]])
		return {}
	var cols: int = parsed["sub_cols"]
	var rows: int = parsed["sub_rows"]
	var descriptors: PackedInt32Array = parsed["scene"]
	if descriptors.size() != cols * rows:
		push_error("MapFormat: 地图缺少场景层 %s" % source)
		return {}
	var size := Vector2i(cols, rows) / MapFormatV4.SUB_PER_CELL
	var meta: Array = Array(parsed["meta_lines"])
	var spawns := parse_spawn_metadata(meta, size)
	if not spawns["errors"].is_empty():
		push_warning("MapFormat: %s（%s）" % [source, spawns["errors"][0]])
		return {}
	var info := {
		"bytes": bytes,
		"size": size,
		"grid": MapFormatV4.flatten_scene(descriptors, cols, rows),
		"descriptors": descriptors,
		"meta_lines": meta,
		"spawns": spawns,
	}
	info.make_read_only()
	if _maps.size() >= CACHE_SIZE:
		_maps.erase(_maps.keys()[0])
	_maps[bytes] = info
	return info

## 出生点使用 64px 格坐标，团队复活点的错误在团队赛开局校验中报告。
static func parse_spawn_metadata(lines: Array, dims: Vector2i) -> Dictionary:
	var enemies: Array[Dictionary] = []
	var respawn := {1: [], 2: []}
	var errors: Array[String] = []
	var respawn_errors: Array[String] = []
	var result := {"enemies": enemies, "respawn": respawn, "errors": errors, "respawn_errors": respawn_errors}
	for index in lines.size():
		var text := String(lines[index]).strip_edges()
		if not text.begins_with("#"):
			continue
		var parts := text.substr(1).strip_edges().replace("\t", " ").split(" ", false)
		if parts.is_empty():
			continue
		var kind := parts[0]
		if kind not in ["player", "player2", "enemy", "respawn"]:
			continue
		var coordinate := 2 if kind == "enemy" or kind == "respawn" else 1
		var problem := _coordinate_error(parts, coordinate, dims)
		if problem.is_empty() and kind == "respawn" and (not parts[1].is_valid_int() or not respawn.has(int(parts[1]))):
			problem = "队伍只能是 1 或 2"
		if not problem.is_empty():
			var issues := respawn_errors if kind == "respawn" else errors
			issues.append("第 %d 行：%s（%s）" % [index + 1, problem, text])
			continue
		var cell := Vector2i(int(parts[coordinate]), int(parts[coordinate + 1]))
		match kind:
			"respawn": respawn[int(parts[1])].append(cell)
			"enemy": enemies.append({"type": parts[1], "cell": cell})
			_: result[kind] = cell
	return result

static func _coordinate_error(parts: PackedStringArray, at: int, dims: Vector2i) -> String:
	if parts.size() != at + 2:
		return "需要 %d 个字段，实际 %d 个" % [at + 1, parts.size() - 1]
	if not parts[at].is_valid_int() or not parts[at + 1].is_valid_int():
		return "坐标不是整数"
	var x := int(parts[at])
	var y := int(parts[at + 1])
	if x < 0 or y < 0 or x >= dims.x or y >= dims.y:
		return "坐标超出地图范围（%dx%d）" % [dims.x, dims.y]
	return ""
