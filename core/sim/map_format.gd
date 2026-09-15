class_name MapFormat
extends RefCounted

# `.cyrm` 地图**格式**层:格子值编解码(packed)+ 文件解析/序列化 + spawn 元数据。
# ★ 本类**无会话状态** —— 读哪份文件、当前网格是什么,一律由调用方给(路径参数 / grid 参数)。
#   会话级状态(选中的地图文件、current_grid)留在 MazeGenerator,那里也是生产代码的统一入口。
# ★ 改这里 = 改磁盘格式;改 GridPathfinder = 改环面数学/寻路。两者不搭界。

# 地图格子值:packed = 纹理*16 + 形状掩码(0-335)。0 = 空气。
# 形状掩码 4bit = 2×2 子格(1<<(sy*2+sx):bit0 左上/bit1 右上/bit2 左下/bit3 右下),15=全砖。
const EMPTY: int = 0
const SOLID: int = 31  # pack(1, 15) = 纹理1 全砖;测试/网格里"实体格"一律用此常量

# 纹理(1-20,structure.png 两行各 10 块)× 形状(0-15)打包成单 int;shape 或 texture 为 0 → 空气。
static func pack(texture: int, shape: int) -> int:
	if shape == 0 or texture == 0:
		return 0
	return texture * 16 + shape

static func texture_of(v: int) -> int:
	return v / 16

static func shape_of(v: int) -> int:
	return v % 16

# v3 每格 4 字符:[纹理 3 位 0xx][形状hex]。纹理 000=空气,001/002/.../021=水体等;形状 hex 0-F。
# 纹理用 3 位十进制数字,不用字母(纹理数增长不依赖字母表)。

static func shape_char_to_value(ch: String) -> int:
	if ch.is_valid_int():
		var n := ch.to_int()
		if n >= 0 and n <= 9:
			return n
	match ch:
		"A", "a": return 10
		"B", "b": return 11
		"C", "c": return 12
		"D", "d": return 13
		"E", "e": return 14
		"F", "f": return 15
		_:
			push_warning("MapFormat: 非法形状字符 \"%s\"，按 0 处理" % ch)
			return 0

static func _value_to_shape_char(v: int) -> String:
	return "0123456789ABCDEF"[v]

# .cyrm 单字符 → 瓦片值:0-9 → 0-9,'A'/'a' → 10;非法字符按 0 处理。
static func _tile_char_to_value(ch: String) -> int:
	match ch:
		"0": return 0
		"1": return 1
		"2": return 2
		"3": return 3
		"4": return 4
		"5": return 5
		"6": return 6
		"7": return 7
		"8": return 8
		"9": return 9
		"A", "a": return 10
		_:
			push_warning("MapFormat: 非法瓦片字符 \"%s\"，按 0 处理" % ch)
			return EMPTY

# ── 读文件 ──
# 读整个 .cyrm 的行(含注释与空行)。调用方先自行 FileAccess.file_exists 并报错
# (三个调用方的"文件不存在"返回值各不相同,故存在性检查留在各自函数里)。
static func read_lines(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	return lines

# ── 地图格式(.cyrm v3/v1)──
# v3:首行带 `# cyrm-v3` 标记,每格 4 字符 [纹理 3 位 0xx][形状hex](纹理 000=空气,001/002/...;形状 0-F)。
# v1(旧):单字符 0-9/A(250×150),无标记 → 加载时自动 2×2 转换并 ÷2 spawn 坐标。
const V3_MARKER: String = "# cyrm-v3"

# 任一非空行以标记开头 → v3 格式;否则按旧格式(自动转换)。
static func has_v3_marker(lines: Array) -> bool:
	for l in lines:
		var s := String(l).strip_edges()
		if s.begins_with(V3_MARKER):
			return true
	return false

# 从原始行里取出网格行(跳过空行与 # 注释)。
static func _grid_lines(lines: Array) -> Array:
	var out: Array = []
	for l in lines:
		var s := String(l).strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		out.append(s)
	return out

# v3 网格:每行 125 格 × 4 字符(纹理 3 位 0xx + 形状 hex)。宽度(字符数)不一致的抬头行跳过。
static func parse_v3_grid(lines: Array) -> Array[Array]:
	var grid: Array[Array] = []
	var row_len := -1
	for raw in lines:
		var line := String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cells: Array[int] = []
		var i := 0
		while i + 3 < line.length():
			cells.append(pack(int(line.substr(i, 3)), shape_char_to_value(line[i + 3])))
			i += 4
		if row_len < 0:
			row_len = cells.size()
		elif cells.size() != row_len:
			push_warning("MapFormat: v3 第 %d 行格数 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, cells.size(), row_len])
			continue
		grid.append(cells)
		row_len = cells.size()
	return grid

# 旧格式(单字符 0-10)→ 0-10 网格。
static func parse_old_grid(lines: Array) -> Array[Array]:
	var grid: Array[Array] = []
	var row_len := -1
	for raw in lines:
		var line := String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var row: Array[int] = []
		for ch in line:
			row.append(_tile_char_to_value(ch))
		if row_len >= 0 and row.size() != row_len:
			push_warning("MapFormat: 旧格式第 %d 行长度 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, row.size(), row_len])
			continue
		grid.append(row)
		row_len = row.size()
	return grid

# 旧 2×2 → 新 1 格 packed。宽高需偶数;奇数丢弃多余行列。
# 参数用未类型化 Array(调用方可能传 `:=` 推断的类型数组,Array[Array] 会拒收 Array[int] 元素)。
static func convert_old_grid(old: Array) -> Array[Array]:
	var rows := old.size()
	var cols := (old[0] as Array).size()
	var out: Array[Array] = []
	for ny in range(rows / 2):
		var row: Array[int] = []
		for nx in range(cols / 2):
			var shape := 0
			var tex := 0
			for sy in range(2):
				for sx in range(2):
					var ov: int = (old[ny * 2 + sy] as Array)[nx * 2 + sx]
					if ov != 0:
						shape |= 1 << (sy * 2 + sx)
						if tex == 0:
							tex = ov
			row.append(pack(tex, shape))
		out.append(row)
	return out

# v3 网格序列化:125 格/行,每格 4 字符(纹理 3 位 0xx + 形状 hex;空气 = "0000")。
# 供地图转换脚本(单一转换源)。
static func serialize_v3_grid(grid: Array) -> Array[String]:
	var out: Array[String] = []
	for row in grid:
		var sb := ""
		for v in row:
			sb += "%03d" % texture_of(v) + _value_to_shape_char(shape_of(v))
		out.append(sb)
	return out

# 读取地图文件的列/行数(格子级),供 GameParameters 初始化 MAP 像素尺寸。
# 逻辑与 load_map_file 一致:跳过空行与 # 注释行,以首个有效行为宽度,
# 宽度不一致的行(如抬头)不计入行数。返回转换后的游戏网格尺寸(v3 125×75,旧图同)。
static func map_size(path: String) -> Vector2i:
	if not FileAccess.file_exists(path):
		push_error("MapFormat: 找不到地图文件 %s" % path)
		return Vector2i.ZERO
	var lines := read_lines(path)
	var grid_lines := _grid_lines(lines)
	var cols := -1
	var rows := 0
	for line in grid_lines:
		var l := String(line)
		if cols < 0:
			cols = l.length()
		elif l.length() != cols:
			continue
		rows += 1
	if rows == 0 or cols < 0:
		return Vector2i.ZERO
	if has_v3_marker(lines):
		return Vector2i(cols / 4, rows)   # v3:每格 4 字符
	return Vector2i(cols / 2, rows / 2)   # 旧:转换后 2×2 → 1


static func load_map_file(path: String) -> Array[Array]:
	if not FileAccess.file_exists(path):
		push_error("MapFormat: 找不到地图文件 %s" % path)
		return []
	var lines := read_lines(path)
	if has_v3_marker(lines):
		return parse_v3_grid(lines)
	var grid := parse_old_grid(lines)
	if grid.is_empty():
		push_error("MapFormat: 地图文件 %s 无有效行" % path)
		return []
	return convert_old_grid(grid)


# 解析地图文件的 spawn 元数据行(坐标=格,空格分隔)。
# 支持:# player <col> <row> 与 # enemy <type_id> <col> <row>。
# 返回 {"player": Vector2i, "enemies": [{"type": String, "cell": Vector2i}]};
# 无任何 spawn 指令返回空 Dictionary。player 多行时最后一行生效。非法行 push_warning 跳过。
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


# 从地图文件读取 spawn 元数据(与 load_map_file 各自读一遍;小文件可接受)。
static func load_spawns(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("MapFormat: 找不到地图文件 %s" % path)
		return {}
	var lines := read_lines(path)
	var result := parse_spawn_metadata(lines)
	if has_v3_marker(lines):
		return result
	# 旧格式:网格 2×2 → 1,spawn 坐标同步 ÷2。
	if result.has("player"):
		result["player"] = Vector2i(result["player"].x / 2, result["player"].y / 2)
	if result.has("player2"):
		result["player2"] = Vector2i(result["player2"].x / 2, result["player2"].y / 2)
	if result.has("enemies"):
		var enemies: Array = result["enemies"]
		for i in range(enemies.size()):
			enemies[i]["cell"] = Vector2i(enemies[i]["cell"].x / 2, enemies[i]["cell"].y / 2)
	return result
