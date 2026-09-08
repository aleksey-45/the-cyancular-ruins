extends SceneTree

# 一次性/可复用工具:把旧格式 .cyrm 转换成 v3(每格 4 字符 [纹理 3 位 0xx][形状hex],# cyrm-v3 标记)
# 写回原文件。支持两种旧格式:
#   - 旧 v2 字母版(带 # cyrm-v2 标记):每格 2 字符 [纹理字符][形状hex],纹理字符 0-9/A-K/L/M(0-22);
#     格子坐标已是游戏网格坐标,spawn 坐标不改。
#   - 旧 v1 单字符(无标记):250×150,自动 2×2 转换(convert_old_grid),spawn 坐标 ÷2。
# 已是 v3(带 # cyrm-v3 标记)则跳过。
# 用法:godot --headless --path . -s res://tests/convert_map.gd [路径;默认 res://maps/demo.cyrm]

const OLD_V2_MARKER := "# cyrm-v2"
const TEX_CHARS := "0123456789ABCDEFGHIJKLM"   # 索引=纹理值(0-22),兼容字母版

func _initialize() -> void:
	var path := "res://maps/demo.cyrm"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and args[0] != "":
		path = args[0]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("convert_map: 打不开 %s" % path)
		quit(1)
		return
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	if MazeGenerator._has_v3_marker(lines):
		print("convert_map: %s 已是 v3,跳过" % path)
		quit(0)
		return
	var is_old_v2 := _has_marker(lines, OLD_V2_MARKER)
	var grid: Array[Array]
	var half := 1
	if is_old_v2:
		grid = _parse_old_v2_grid(lines)
	else:
		grid = MazeGenerator.convert_old_grid(MazeGenerator._parse_old_grid(lines))
		half = 2
	var out: Array[String] = []
	out.append(MazeGenerator.V3_MARKER)
	for l in lines:
		var s := String(l).strip_edges()
		if s.is_empty() or not s.begins_with("#"):
			continue
		var parts := s.substr(1).strip_edges().split(" ", false)
		match parts[0]:
			"player":
				if parts.size() >= 3:
					out.append("# player %d %d" % [int(parts[1]) / half, int(parts[2]) / half])
			"enemy":
				if parts.size() >= 4:
					out.append("# enemy %s %d %d" % [parts[1], int(parts[2]) / half, int(parts[3]) / half])
			"cyrm-v2":
				pass  # 旧版本标记行不保留
			_:
				out.append(s)  # 普通 # 注释保留
	for r in MazeGenerator.serialize_v3_grid(grid):
		out.append(r)
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		push_error("convert_map: 写不回去 %s" % path)
		quit(1)
		return
	w.store_string("\n".join(out) + "\n")
	w.close()
	print("convert_map: %s 已转换为 v3: %d×%d" % [path, grid[0].size(), grid.size()])
	quit(0)


func _has_marker(lines: Array, marker: String) -> bool:
	for l in lines:
		if String(l).strip_edges().begins_with(marker):
			return true
	return false


# 旧 v2 字母版网格:每格 2 字符 [纹理字符][形状hex],纹理字符 0-9/A-K/L/M(0-22)。
func _parse_old_v2_grid(lines: Array) -> Array[Array]:
	var grid: Array[Array] = []
	var row_len := -1
	for raw in lines:
		var line := String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cells: Array[int] = []
		var i := 0
		while i + 1 < line.length():
			var tv := TEX_CHARS.find(line[i])
			if tv < 0:
				push_warning("convert_map: 旧 v2 非法纹理字符 \"%s\"，按空气处理" % line[i])
				tv = 0
			cells.append(MazeGenerator.pack(tv, MazeGenerator._shape_char_to_value(line[i + 1])))
			i += 2
		if row_len < 0:
			row_len = cells.size()
		elif cells.size() != row_len:
			push_warning("convert_map: 旧 v2 第 %d 行格数 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, cells.size(), row_len])
			continue
		grid.append(cells)
		row_len = cells.size()
	return grid
