extends SceneTree

# 一次性/可复用工具:把旧格式(250×150 单字符).cyrm 转换成 v2(125×75,每格 2 字符
# [纹理][形状hex])写回原文件。转换算法与 MazeGenerator 一致(2×2 分组 → 掩码+纹理,
# spawn 坐标 ÷2)。已是 v2(带 # cyrm-v2 标记)则跳过。
# 用法:godot --headless --path . -s res://Tests/convert_map.gd [路径;默认 res://map/demo.cyrm]
func _initialize() -> void:
	var path := "res://map/demo.cyrm"
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
	if MazeGenerator._has_v2_marker(lines):
		print("convert_map: %s 已是 v2,跳过" % path)
		quit(0)
		return
	# 直接基于本文件行解析(不走 map_file_path 随机选图)
	var grid := MazeGenerator.convert_old_grid(MazeGenerator._parse_old_grid(lines))
	var out: Array[String] = []
	out.append(MazeGenerator.V2_MARKER)
	for l in lines:
		var s := String(l).strip_edges()
		if s.is_empty() or not s.begins_with("#"):
			continue
		var parts := s.substr(1).strip_edges().split(" ", false)
		match parts[0]:
			"player":
				if parts.size() >= 3:
					out.append("# player %d %d" % [int(parts[1]) / 2, int(parts[2]) / 2])
			"enemy":
				if parts.size() >= 4:
					out.append("# enemy %s %d %d" % [parts[1], int(parts[2]) / 2, int(parts[3]) / 2])
			_:
				out.append(s)  # 普通 # 注释保留
	for r in MazeGenerator.serialize_v2_grid(grid):
		out.append(r)
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		push_error("convert_map: 写不回去 %s" % path)
		quit(1)
		return
	w.store_string("\n".join(out) + "\n")
	w.close()
	print("convert_map: %s 已转换为 v2: %d×%d" % [path, grid[0].size(), grid.size()])
	quit(0)
