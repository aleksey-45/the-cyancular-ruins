extends RefCounted
class_name MazeGenerator

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

static func _shape_char_to_value(ch: String) -> int:
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
			push_warning("MazeGenerator: 非法形状字符 \"%s\"，按 0 处理" % ch)
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
			push_warning("MazeGenerator: 非法瓦片字符 \"%s\"，按 0 处理" % ch)
			return EMPTY

const MAP_DIR: String = "res://map"

# ── 地图文件(.cyrm)──
# 先随机取 exe 旁的 .cyrm(玩家/开发者外置自定义地图),否则随机取 res://map/*.cyrm;
# 同目录多份 .cyrm 随机读一份。选中的地图整个会话固定(缓存在 _picked_map),
# 保证 map_size / load_map_file / parse_spawn_metadata 读的是同一份。
static var _picked_map: String = ""
static func map_file_path() -> String:
	if _picked_map != "":
		return _picked_map
	var ext := _random_cyrm(OS.get_executable_path().get_base_dir())
	_picked_map = ext if ext != "" else _random_cyrm(MAP_DIR)
	return _picked_map

# 在 dir 目录下随机挑一个 .cyrm 地图;没有则返回 ""。
static func _random_cyrm(dir: String) -> String:
	var da := DirAccess.open(dir)
	if da == null:
		return ""
	var maps: Array[String] = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			maps.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	if maps.is_empty():
		return ""
	return maps[randi() % maps.size()]

# 环面曼哈顿距离(格子级)。cols/rows 由调用方按实际地图传入,
# 不依赖全局常量——地图文件变更后距离计算不会失真。
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


# 像素级环面最短向量:从 a 指向 b(跨接缝取最短)。
static func toroidal_delta_px(a: Vector2, b: Vector2, w: float, h: float) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > w * 0.5:
		dx = -signf(dx) * (w - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > h * 0.5:
		dy = -signf(dy) * (h - absf(dy))
	return Vector2(dx, dy)


# 把 pos 锚定到 anchor 最近的环面副本:返回的位置与 anchor 各轴差 ≤ 半地图。
# 用于让敌人/子弹「跟着主角一起取模」——墙体在 level_0 按 3x3 铺贴,
# 相机在接缝处能看到另一侧副本,实体若仍取模到 [0,MAP) 会渲染到远副本而消失。
static func anchor_to_nearest(pos: Vector2, anchor: Vector2, w: float, h: float) -> Vector2:
	var p := pos
	if p.x - anchor.x > w * 0.5:
		p.x -= w
	elif p.x - anchor.x < -w * 0.5:
		p.x += w
	if p.y - anchor.y > h * 0.5:
		p.y -= h
	elif p.y - anchor.y < -h * 0.5:
		p.y += h
	return p


# 把点取模回 [0,w)×[0,h) 绝对区间(玩家锚点自身用;实体锚定玩家副本见 anchor_to_nearest)。
static func wrap_to_range(pos: Vector2, w: float, h: float) -> Vector2:
	var p := pos
	if p.x >= w:
		p.x -= w
	elif p.x < 0.0:
		p.x += w
	if p.y >= h:
		p.y -= h
	elif p.y < 0.0:
		p.y += h
	return p


# ── 地图格式(.cyrm v1/v3)──
# v3:首行带 `# cyrm-v3` 标记,每格 4 字符 [纹理 3 位 0xx][形状hex](纹理 000=空气,001/002/...;形状 0-F)。
# v1(旧):单字符 0-9/A(250×150),无标记 → 加载时自动 2×2 转换并 ÷2 spawn 坐标。
const V3_MARKER: String = "# cyrm-v3"

# 任一非空行以标记开头 → v3 格式;否则按旧格式(自动转换)。
static func _has_v3_marker(lines: Array) -> bool:
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
# v3 网格:每行 125 格 × 4 字符(纹理 3 位 0xx + 形状 hex)。宽度(字符数)不一致的抬头行跳过。
static func _parse_v3_grid(lines: Array) -> Array[Array]:
	var grid: Array[Array] = []
	var row_len := -1
	for raw in lines:
		var line := String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cells: Array[int] = []
		var i := 0
		while i + 3 < line.length():
			cells.append(pack(int(line.substr(i, 3)), _shape_char_to_value(line[i + 3])))
			i += 4
		if row_len < 0:
			row_len = cells.size()
		elif cells.size() != row_len:
			push_warning("MazeGenerator: v3 第 %d 行格数 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, cells.size(), row_len])
			continue
		grid.append(cells)
		row_len = cells.size()
	return grid

# 旧格式(单字符 0-10)→ 0-10 网格。
static func _parse_old_grid(lines: Array) -> Array[Array]:
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
			push_warning("MazeGenerator: 旧格式第 %d 行长度 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, row.size(), row_len])
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

# v3 网格序列化:125 格/行,每格 4 字符(纹理 3 位 0xx + 形状 hex)。供地图转换脚本(单一转换源)。
# v3 网格序列化:125 格/行,每格 4 字符(纹理 3 位 0xx + 形状 hex;空气 = "0000")。
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
static func map_size() -> Vector2i:
	var path := map_file_path()
	if not FileAccess.file_exists(path):
		push_error("MazeGenerator: 找不到地图文件 %s" % path)
		return Vector2i.ZERO
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
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
	if _has_v3_marker(lines):
		return Vector2i(cols / 4, rows)   # v3:每格 4 字符
	return Vector2i(cols / 2, rows / 2)   # 旧:转换后 2×2 → 1


static func load_map_file() -> Array[Array]:
	var path := map_file_path()
	if not FileAccess.file_exists(path):
		push_error("MazeGenerator: 找不到地图文件 %s" % path)
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	if _has_v3_marker(lines):
		return _parse_v3_grid(lines)
	var grid := _parse_old_grid(lines)
	if grid.is_empty():
		push_error("MazeGenerator: 地图文件 %s 无有效行" % map_file_path())
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
						push_warning("MazeGenerator: 非法 player 坐标 %s" % text)
			"player2":
				if parts.size() >= 3:
					var x := int(parts[1])
					var y := int(parts[2])
					if x >= 0 and y >= 0:
						result["player2"] = Vector2i(x, y)
					else:
						push_warning("MazeGenerator: 非法 player2 坐标 %s" % text)
			"enemy":
				if parts.size() >= 4:
					var type_id := parts[1]
					var x := int(parts[2])
					var y := int(parts[3])
					if x >= 0 and y >= 0 and not type_id.is_empty():
						enemies.append({"type": type_id, "cell": Vector2i(x, y)})
					else:
						push_warning("MazeGenerator: 非法 enemy 行 %s" % text)
			_:
				pass  # 普通 # 注释,忽略
	if enemies.size() > 0:
		result["enemies"] = enemies
	return result


# 从地图文件读取 spawn 元数据(与 load_map_file 各自读一遍;小文件可接受)。
static func load_spawns() -> Dictionary:
	var path := map_file_path()
	if not FileAccess.file_exists(path):
		push_error("MazeGenerator: 找不到地图文件 %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	var result := parse_spawn_metadata(lines)
	if _has_v3_marker(lines):
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


# 当前关卡网格(level_0._ready 赋值;空网格时寻路一律视为无路)。
static var current_grid: Array[Array] = []


# 像素坐标 → 环面格子坐标(取模回 [0,cols)×[0,rows))。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# 环面 4 邻居 BFS:返回从 from_cell 到 to_cell 的格序列(不含起点,含终点)。
# 只走 EMPTY 格;限量访问 max_visit,超限视为无路。同格/无路返回空数组。
# passable_pred 可传入可走性判定(如飞行敌人按自身碰撞箱是否挤得过);为空时用
# 默认「EMPTY 可走」。传 max_visit 时需一并给出,否则默认 4000。
static func bfs_path(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable()) -> Array[Vector2i]:
	var grid := current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols := grid[0].size()
	if from_cell == to_cell:
		return []
	var visited := {from_cell: true}
	var prev := {}
	var queue: Array[Vector2i] = [from_cell]
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		if visited.size() > max_visit:
			return []
		for n in _neighbors4(cur, cols, rows):
			if visited.has(n):
				continue
			if passable_pred.is_valid():
				if not passable_pred.call(n):
					continue
			elif TileDefs.is_blocked(grid[n.y][n.x]):
				continue
			visited[n] = true
			prev[n] = cur
			if n == to_cell:
				return _rebuild_path(prev, from_cell, to_cell)
			queue.append(n)
	return []


# 与 bfs_path 相同,但目标不可达(墙隔断/挤不进/预算超限)时返回「能到达的格中离
# to_cell 最近一格」的路径,而不是空数组。给飞行敌人当降级目标:目标格是墙或太窄
# 时仍能沿迷宫里最近的可达格靠近,而不是空路径后直线硬冲卡墙。可达时行为与 bfs_path 一致。
static func bfs_path_nearest(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable()) -> Array[Vector2i]:
	var grid := current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols := grid[0].size()
	if from_cell == to_cell:
		return []
	var visited := {from_cell: true}
	var prev := {}
	var queue: Array[Vector2i] = [from_cell]
	var head := 0
	var best := from_cell
	var best_d := toroidal_dist(from_cell, to_cell, cols, rows)
	while head < queue.size():
		var cur := queue[head]
		head += 1
		if visited.size() > max_visit:
			break
		var cd := toroidal_dist(cur, to_cell, cols, rows)
		if cd < best_d:
			best_d = cd
			best = cur
		for n in _neighbors4(cur, cols, rows):
			if visited.has(n):
				continue
			if passable_pred.is_valid():
				if not passable_pred.call(n):
					continue
			elif TileDefs.is_blocked(grid[n.y][n.x]):
				continue
			visited[n] = true
			prev[n] = cur
			if n == to_cell:
				return _rebuild_path(prev, from_cell, to_cell)
			queue.append(n)
	if best == from_cell:
		return []
	return _rebuild_path(prev, from_cell, best)


# A* 版 bfs_path_nearest:启发式 = 环面曼哈顿距离(4 邻域,可采纳且一致)。预算 max_visit
# 是弹出(展开)节点数上限,与 bfs 的 visited 上限语义对齐。目标不可达/预算超限时同样
# 返回「最近可达格」的路径。空旷区 BFS 波前会铺满半径内所有格,预算很快耗尽;A* 靠
# 启发式直奔目标,展开节点少一个量级——这正是玩家站在高平台时鸟"上不去"的根因。
#
# 性能:g/prev 从 Dictionary(Vector2i 键)换成扁平 PackedInt32Array(线性索引
# y*cols+x),visited 用 g≥0 标记;堆从「Array 装嵌套 Array」换成两条并行
# PackedInt32Array(_heap_f 存 f、_heap_c 存 cell 索引),不打包 → 无溢出风险。
# 静态缓冲区复用、每搜索只 fill 一遍 → 零字典分配、无 GC 压力,同预算下快一个量级。
static var _g_cost: PackedInt32Array = PackedInt32Array()
static var _prev: PackedInt32Array = PackedInt32Array()
static var _heap_f: PackedInt32Array = PackedInt32Array()
static var _heap_c: PackedInt32Array = PackedInt32Array()
static var astar_calls: int = 0  # A* 调用计数(冒烟测试验证路径缓存命中用)

static func astar_path_nearest(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable(), max_search_dist: int = -1) -> Array[Vector2i]:
	astar_calls += 1
	var grid := current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols := grid[0].size()
	if from_cell == to_cell:
		return []
	var n := rows * cols
	if _g_cost.size() < n:
		_g_cost.resize(n)
		_prev.resize(n)
	_g_cost.fill(-1)
	_prev.fill(-1)
	var start_idx := from_cell.y * cols + from_cell.x
	var goal_idx := to_cell.y * cols + to_cell.x
	_g_cost[start_idx] = 0
	_heap_f.clear()
	_heap_c.clear()
	var start_f := toroidal_dist(from_cell, to_cell, cols, rows)
	_astar_heap_push(start_f, start_idx)
	var expanded := 0
	var best_idx := start_idx
	var best_d := start_f
	while _heap_f.size() > 0:
		var pop := _astar_heap_pop()
		var f := pop.x
		var cur_idx := pop.y
		var g_cur: int = _g_cost[cur_idx]
		var cx := cur_idx % cols
		var cy := cur_idx / cols
		# 惰性删除:该格后来被更优路径更新过,旧堆项作废。
		if f > g_cur + toroidal_dist(Vector2i(cx, cy), to_cell, cols, rows):
			continue
		expanded += 1
		if expanded > max_visit:
			break
		if cur_idx == goal_idx:
			return _rebuild_path_flat(start_idx, goal_idx, cols, rows)
		var cd := toroidal_dist(Vector2i(cx, cy), to_cell, cols, rows)
		if cd < best_d:
			best_d = cd
			best_idx = cur_idx
		_astar_relax(cx, cy, cols, rows, grid, passable_pred, to_cell, g_cur + 1, cur_idx, from_cell, max_search_dist)
	if best_idx == start_idx:
		return []
	return _rebuild_path_flat(start_idx, best_idx, cols, rows)


# 4 邻域偏移(右/左/下/上,与旧 _neighbors4 顺序一致,保摊平后的平局行为)。
const _DIRS4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


# 展开当前格:对每个邻居做「可走 + 更优」判定,通过则更新 g/prev 并入堆。
static func _astar_relax(cx: int, cy: int, cols: int, rows: int, grid: Array[Array],
		passable_pred: Callable, to_cell: Vector2i, ng: int, cur_idx: int,
		from_cell: Vector2i, max_search_dist: int) -> void:
	for d in _DIRS4:
		var nx: int = cx + d.x
		var ny: int = cy + d.y
		if nx >= cols:
			nx = 0
		elif nx < 0:
			nx = cols - 1
		if ny >= rows:
			ny = 0
		elif ny < 0:
			ny = rows - 1
		# 搜索范围上限:不展开超出 from_cell 半径的节点(鸟的寻路不搜太远)
		if max_search_dist > 0 and toroidal_dist(from_cell, Vector2i(nx, ny), cols, rows) > max_search_dist:
			continue
		if passable_pred.is_valid():
			if not passable_pred.call(Vector2i(nx, ny)):
				continue
		elif TileDefs.is_blocked(grid[ny][nx]):
			continue
		var ni: int = ny * cols + nx
		var old := _g_cost[ni]
		if old >= 0 and old <= ng:
			continue
		_g_cost[ni] = ng
		_prev[ni] = cur_idx
		_astar_heap_push(ng + toroidal_dist(Vector2i(nx, ny), to_cell, cols, rows), ni)


# 隐式二叉堆(小根堆,按 f 排序;两条并行 PackedInt32Array 一起交换)。
static func _astar_heap_push(f: int, c: int) -> void:
	_heap_f.append(f)
	_heap_c.append(c)
	var i := _heap_f.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if _heap_f[i] < _heap_f[p]:
			var tf := _heap_f[i]
			_heap_f[i] = _heap_f[p]
			_heap_f[p] = tf
			var tc := _heap_c[i]
			_heap_c[i] = _heap_c[p]
			_heap_c[p] = tc
			i = p
		else:
			break


static func _astar_heap_pop() -> Vector2i:
	var top := Vector2i(_heap_f[0], _heap_c[0])
	var last_f: int = _heap_f[_heap_f.size() - 1]
	_heap_f.resize(_heap_f.size() - 1)
	var last_c: int = _heap_c[_heap_c.size() - 1]
	_heap_c.resize(_heap_c.size() - 1)
	if _heap_f.size() > 0:
		_heap_f[0] = last_f
		_heap_c[0] = last_c
		var i := 0
		var m := _heap_f.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var s := i
			if l < m and _heap_f[l] < _heap_f[s]:
				s = l
			if r < m and _heap_f[r] < _heap_f[s]:
				s = r
			if s == i:
				break
			var tf := _heap_f[i]
			_heap_f[i] = _heap_f[s]
			_heap_f[s] = tf
			var tc := _heap_c[i]
			_heap_c[i] = _heap_c[s]
			_heap_c[s] = tc
			i = s
	return top


# 从 prev 扁平链重建格序列(不含起点含终点)。
static func _rebuild_path_flat(start_idx: int, goal_idx: int, cols: int, rows: int) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var idx := goal_idx
	while idx != start_idx:
		path.push_front(Vector2i(idx % cols, idx / cols))
		idx = _prev[idx]
	return path


static func _neighbors4(c: Vector2i, cols: int, rows: int) -> Array[Vector2i]:
	return [
		Vector2i((c.x + 1) % cols, c.y),
		Vector2i((c.x - 1 + cols) % cols, c.y),
		Vector2i(c.x, (c.y + 1) % rows),
		Vector2i(c.x, (c.y - 1 + rows) % rows),
	]


static func _rebuild_path(prev: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var cur := goal
	while cur != start:
		path.push_front(cur)
		cur = prev[cur]
	return path


# 环面网格 LOS:整数 Bresenham 沿直线采样两格之间的格子,途中任一 SOLID 即阻断。
# 不能用「每步双轴各进一」的斜对角走法——|dx|≠|dy| 时会越过目标行/列、采样到线外的格子。
static func has_line_of_sight(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var grid := current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := grid[0].size()
	var d := _toroidal_step(from_cell, to_cell, cols, rows)
	if d == Vector2i.ZERO:
		return true
	var x := from_cell.x
	var y := from_cell.y
	var sx := 1 if d.x > 0 else -1
	var sy := 1 if d.y > 0 else -1
	var dx := absi(d.x)
	var dy := absi(d.y)
	var err := dx - dy
	while true:
		if TileDefs.is_blocked(grid[y][x]):
			return false
		if x == to_cell.x and y == to_cell.y:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x = posmod(x + sx, cols)
		if e2 < dx:
			err += dx
			y = posmod(y + sy, rows)
	return true


static func _toroidal_step(a: Vector2i, b: Vector2i, cols: int, rows: int) -> Vector2i:
	var dx := b.x - a.x
	if dx > cols / 2:
		dx -= cols
	elif dx < -cols / 2:
		dx += cols
	var dy := b.y - a.y
	if dy > rows / 2:
		dy -= rows
	elif dy < -rows / 2:
		dy += rows
	return Vector2i(dx, dy)
