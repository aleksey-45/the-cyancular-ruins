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

## 字符 → 数值的**唯一解码表**(0-9 / A-F / a-f);非法返回 -1,**不打印**(口径由调用方定)。
## ★ 原先「形状字符」与「瓦片字符」各写一份 match 表,后者是前者的子集 ⇒ 收到这里一份。
static func _hex_char_value(ch: String) -> int:
	if ch.length() != 1:
		return -1
	var c := ch.unicode_at(0)
	if c >= 48 and c <= 57:
		return c - 48          # 0-9
	if c >= 65 and c <= 70:
		return c - 55          # A-F
	if c >= 97 and c <= 102:
		return c - 87          # a-f
	return -1

## 形状字符(v3 每格 4 字符组里那一位)→ 0-15;非法按 0 处理并告警。
static func shape_char_to_value(ch: String) -> int:
	var v := _hex_char_value(ch)
	if v < 0:
		push_warning("MapFormat: 非法形状字符 " + ch + "，按 0 处理")
		return 0
	return v

static func _value_to_shape_char(v: int) -> String:
	return "0123456789ABCDEF"[v]

# .cyrm 单字符 → 瓦片值:0-9 → 0-9;A/a → 10(旧格式只到 A,没有 B~F);其余按 0 处理并告警。
static func _tile_char_to_value(ch: String) -> int:
	var v := _hex_char_value(ch)
	if v < 0 or v > 10:
		push_warning("MapFormat: 非法瓦片字符 " + ch + "，按 0 处理")
		return 0
	return v

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


## 原样读整个文件(字节)。v4 二进制用;文本格式仍走 read_lines。
static func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var data := f.get_buffer(int(f.get_length()))
	f.close()
	return data



## v4 判定 + 解析**一次读盘**:命中 v4 返回 parse 结果(含 ok/error),非 v4 返回空字典。
## ★ 5 处调用点原先各写 `if is_v4(path): MapFormatV4.parse(_read_bytes(path))` —— 同一份文件
##   每次调用被读盘 2 次、CRC32 算 2 次(启动时这些路径会全走一遍)。空字典 = 「不是 v4」,不是错误。
static func _v4(path: String) -> Dictionary:
	var data := _read_bytes(path)
	if data.is_empty() or not MapFormatV4.is_v4_data(data):
		return {}
	return MapFormatV4.parse(data)


## 16px 子格纹理表(选项 A 的会话态装填源):
##   v4 → 场景层描述符直读;v3/旧格式 → 把 2×2 形状掩码展开成 4×4(每个 32px 象限 = 2×2 个
##   同纹理 16px 子格,与 §3.6 迁移规则一致,几何逐像素等价)。
static func load_subgrid(path: String) -> Array[Array]:
	var v := _v4(path)
	if not v.is_empty():
		if not bool(v.get("ok", false)):
			push_error("MapFormat: v4 解析失败 %s(%s)" % [path, str(v.get("error", "?"))])
			return []
		return MapFormatV4.scene_to_subgrid(v["scene"], int(v["sub_cols"]), int(v["sub_rows"]))
	var grid := load_map_file(path)
	return expand_cells_to_subgrid(grid)


## 格级网格 → 16px 子格纹理表(2×2 形状掩码 ×2 展开;兼容旧格式与测试合成网格)。
static func expand_cells_to_subgrid(grid: Array) -> Array[Array]:
	var out: Array[Array] = []
	if grid.is_empty():
		return out
	var cols: int = (grid[0] as Array).size()
	var rows := grid.size()
	for ry in rows * 4:
		var row: Array[int] = []
		row.resize(cols * 4)
		out.append(row)
	for y in rows:
		for x in cols:
			var v := int(grid[y][x])
			if v == 0:
				continue
			var tex := texture_of(v)
			var sh := shape_of(v)
			for qy in 2:
				for qx in 2:
					if sh & (1 << (qy * 2 + qx)) == 0:
						continue
					for sy in 2:
						for sx in 2:
							out[y * 4 + qy * 2 + sy][x * 4 + qx * 2 + sx] = tex
	return out


## 地图的注释/出生点行(v4 = body 里的 meta 文本;文本格式 = 原样行)。显示名等目录工具用。
static func load_meta_lines(path: String) -> Array:
	var v := _v4(path)
	if not v.is_empty():
		if not bool(v.get("ok", false)):
			return []
		return v["meta_lines"]
	return read_lines(path)

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
	for ny in rows / 2:
		var row: Array[int] = []
		for nx in cols / 2:
			var shape := 0
			var tex := 0
			for sy in 2:
				for sx in 2:
					var ov: int = (old[ny * 2 + sy] as Array)[nx * 2 + sx]
					if ov != 0:
						shape |= 1 << (sy * 2 + sx)
						if tex == 0:
							tex = ov
			row.append(pack(tex, shape))
		out.append(row)
	return out

# 读取地图文件的列/行数(格子级),供 GameParameters 初始化 MAP 像素尺寸。
# 逻辑与 load_map_file 一致:跳过空行与 # 注释行,以首个有效行为宽度,
# 宽度不一致的行(如抬头)不计入行数。返回转换后的游戏网格尺寸(v3 125×75,旧图同)。
static func map_size(path: String) -> Vector2i:
	if not FileAccess.file_exists(path):
		push_error("MapFormat: 找不到地图文件 %s" % path)
		return Vector2i.ZERO
	# v4 二进制优先(头部即尺寸);旧文本格式走下面的逐行统计
	var raw := _read_bytes(path)
	if MapFormatV4.is_v4_data(raw):
		var h := MapFormatV4.read_header(raw)
		return Vector2i(int(h["sub_cols"]) / 4, int(h["sub_rows"]) / 4)
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
	# v4 二进制(现行格式):场景层扁平化成游戏网格
	var v := _v4(path)
	if not v.is_empty():
		if not bool(v.get("ok", false)):
			push_error("MapFormat: v4 解析失败 %s(%s)" % [path, str(v.get("error", "?"))])
			return []
		return MapFormatV4.flatten_scene(v["scene"], int(v["sub_cols"]), int(v["sub_rows"]))
	# v3 / 旧文本格式(只读兼容:老图、编辑器旧导出)
	var lines := read_lines(path)
	if has_v3_marker(lines):
		return parse_v3_grid(lines)
	var grid := parse_old_grid(lines)
	if grid.is_empty():
		push_error("MapFormat: 地图文件 %s 无有效行" % path)
		return []
	return convert_old_grid(grid)


# 解析地图文件的 spawn 元数据行(坐标=格,空格分隔)。
# 支持:
#   # player <col> <row>           单机玩家出生点(向后兼容;多行时最后一行生效)
#   # player2 <col> <row>          PvP 第二出生点(向后兼容;老图回退路径用)
#   # enemy <type_id> <col> <row>  敌人出生点
#   # respawn <1|2> <col> <row>    按阵营半区的复活点列表(侧 1 = 左半 / 侧 2 = 右半;每侧 ≥5 个,由地图作者写死)
# 返回 {"player": Vector2i, "player2": Vector2i, "enemies": [...],
#       "respawns": {1: [Vector2i], 2: [Vector2i]}};
# 列表键只在非空时出现(与 enemies 同约定)。# respawn 按文件顺序**按侧去重**(首次出现生效)。
# 非法行 push_warning 跳过、不抛错(老地图没有这些行 ⇒ respawns 键不存在,各模式走改造前的回退路径)。
static func parse_spawn_metadata(lines: Array) -> Dictionary:
	var result := {}
	var enemies: Array = []
	var respawns := {1: [], 2: []}
	var seen := {1: {}, 2: {}}
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
			"respawn":
				if parts.size() < 2 or not parts[1].is_valid_int():
					push_warning("MapFormat: 非法 respawn 行(缺侧号)%s" % text)
					continue
				var side := int(parts[1])
				if side != 1 and side != 2:
					push_warning("MapFormat: 非法 respawn 侧号 %s(只认 1/2)" % text)
					continue
				var c := _parse_cell_tokens(parts, 2)
				if c.x >= 0 and c.y >= 0:
					if not (seen[side] as Dictionary).has(c):
						(seen[side] as Dictionary)[c] = true
						(respawns[side] as Array).append(c)
				else:
					push_warning("MapFormat: 非法 respawn 行 %s" % text)
			_:
				pass  # 普通 # 注释,忽略
	if enemies.size() > 0:
		result["enemies"] = enemies
	if not (respawns[1] as Array).is_empty() or not (respawns[2] as Array).is_empty():
		result["respawns"] = respawns
	return result


# "col row" 两个 token 从 parts[start] 起解析;任一非法/负数 → (-1,-1)(调用方据此报非法行)。
# ★ 用 is_valid_int() 而不是 int():后者把 "abc" 静默转成 0,会让非法行在地图上落出 (0,0) 这个"合法"点。
static func _parse_cell_tokens(parts: PackedStringArray, start: int) -> Vector2i:
	if parts.size() < start + 2:
		return Vector2i(-1, -1)
	if not parts[start].is_valid_int() or not parts[start + 1].is_valid_int():
		return Vector2i(-1, -1)
	var x := int(parts[start])
	var y := int(parts[start + 1])
	if x < 0 or y < 0:
		return Vector2i(-1, -1)
	return Vector2i(x, y)


# 从地图文件读取 spawn 元数据(与 load_map_file 各自读一遍;小文件可接受)。
static func load_spawns(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("MapFormat: 找不到地图文件 %s" % path)
		return {}
	# v4:spawn/注释都在 body 的 meta 文本里(仍是 "# player x y" 那几行),坐标本来就是格级
	var v := _v4(path)
	if not v.is_empty():
		if not bool(v.get("ok", false)):
			push_error("MapFormat: v4 解析失败 %s(%s)" % [path, str(v.get("error", "?"))])
			return {}
		return parse_spawn_metadata(v["meta_lines"])
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
	# # respawn 同样是格坐标,旧格式(2×2→1)同步 ÷2(老图没有这些行 ⇒ 空列表不受影响)
	if result.has("respawns"):
		var sides: Dictionary = result["respawns"]
		for t in sides:
			var arr: Array = sides[t]
			for i in range(arr.size()):
				arr[i] = Vector2i(arr[i].x / 2, arr[i].y / 2)
	return result
