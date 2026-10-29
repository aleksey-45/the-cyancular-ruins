class_name MapFormat
extends RefCounted

# 游戏与编辑器统一使用 v4。
const EMPTY: int = 0
const SOLID: int = 31

# 64px 格的纹理编号和 2×2 象限掩码；0 表示空气。
static func pack(texture: int, shape: int) -> int:
	return texture * 16 + shape if texture != 0 and shape != 0 else EMPTY

static func texture_of(value: int) -> int:
	return value / 16

static func shape_of(value: int) -> int:
	return value % 16

static func _read_map(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("MapFormat: 无法打开地图 %s" % path)
		return {}
	var parsed := MapFormatV4.parse(file.get_buffer(file.get_length()))
	if not parsed["ok"]:
		push_error("MapFormat: %s (%s)" % [path, parsed["error"]])
		return {}
	if parsed["scene"].size() != parsed["sub_cols"] * parsed["sub_rows"]:
		push_error("MapFormat: 地图缺少场景层 %s" % path)
		return {}
	return parsed

# 尺寸只读取文件头，不解压整张地图。
static func map_size(path: String) -> Vector2i:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("MapFormat: 无法打开地图 %s" % path)
		return Vector2i.ZERO
	var bytes := file.get_buffer(MapFormatV4.HEADER_SIZE)
	if bytes.size() < MapFormatV4.HEADER_SIZE or not MapFormatV4.is_v4_data(bytes) or bytes[4] != 4:
		push_error("MapFormat: 地图须为 v4 格式 %s" % path)
		return Vector2i.ZERO
	var header := MapFormatV4.read_header(bytes)
	var cols: int = header["sub_cols"]
	var rows: int = header["sub_rows"]
	if cols <= 0 or rows <= 0 or cols % 4 != 0 or rows % 4 != 0:
		push_error("MapFormat: 地图尺寸非法 %s" % path)
		return Vector2i.ZERO
	return Vector2i(cols / 4, rows / 4)

# 关卡装载同时取子格；地图目录仅需要粗网格和元数据。
static func load_map_info(path: String, include_subgrid: bool = false) -> Dictionary:
	var grid: Array[Array] = []
	var info := {"grid": grid, "meta_lines": [], "spawns": {}}
	var parsed := _read_map(path)
	if parsed.is_empty(): return info
	var meta: Array = Array(parsed["meta_lines"])
	info["grid"] = MapFormatV4.flatten_scene(parsed["scene"], parsed["sub_cols"], parsed["sub_rows"])
	info["meta_lines"] = meta
	info["spawns"] = parse_spawn_metadata(meta)
	if include_subgrid:
		info["subgrid"] = MapFormatV4.scene_to_subgrid(parsed["scene"], parsed["sub_cols"], parsed["sub_rows"])
	return info

static func load_subgrid(path: String) -> Array[Array]:
	var parsed := _read_map(path)
	if parsed.is_empty(): return []
	return MapFormatV4.scene_to_subgrid(parsed["scene"], parsed["sub_cols"], parsed["sub_rows"])

static func parse_spawn_metadata(lines: Array) -> Dictionary:
	var result := {}
	var enemies: Array = []
	for line in lines:
		var text := String(line).strip_edges()
		if not text.begins_with("#"):
			continue
		var parts := text.substr(1).strip_edges().split(" ", false)
		if parts.is_empty():
			continue
		match parts[0]:
			"player":
				if parts.size() >= 3:
					var x := int(parts[1])
					var y := int(parts[2])
					if x >= 0 and y >= 0:
						result["player"] = Vector2i(x, y)
					else:
						push_warning("MapFormat: 非法 player 坐标 %s" % text)
			"player2":
				if parts.size() >= 3:
					var x := int(parts[1])
					var y := int(parts[2])
					if x >= 0 and y >= 0:
						result["player2"] = Vector2i(x, y)
					else:
						push_warning("MapFormat: 非法 player2 坐标 %s" % text)
			"enemy":
				if parts.size() >= 4:
					var type_id := parts[1]
					var x := int(parts[2])
					var y := int(parts[3])
					if x >= 0 and y >= 0 and not type_id.is_empty():
						enemies.append({"type": type_id, "cell": Vector2i(x, y)})
					else:
						push_warning("MapFormat: 非法 enemy 行 %s" % text)
			_:
				pass  # 普通 # 注释,忽略
	if enemies.size() > 0:
		result["enemies"] = enemies
	return result
