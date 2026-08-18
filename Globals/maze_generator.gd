extends RefCounted
class_name MazeGenerator

# 地图格子值
const SOLID: int = 1
const EMPTY: int = 0

const MAP_FILE: String = "res://map/demo.txt"

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


# 读取地图文件的列/行数(格子级),供 GameParameters 初始化 MAP 像素尺寸。
# 逻辑与 load_map_file 一致:跳过空行与 # 注释行,以首个有效行为宽度,
# 宽度不一致的行(如抬头)不计入行数。
static func map_size() -> Vector2i:
	if not FileAccess.file_exists(MAP_FILE):
		push_error("MazeGenerator: 找不到地图文件 %s" % MAP_FILE)
		return Vector2i.ZERO
	var f := FileAccess.open(MAP_FILE, FileAccess.READ)
	var cols := -1
	var rows := 0
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if cols < 0:
			cols = line.length()
		elif line.length() != cols:
			continue
		rows += 1
	f.close()
	return Vector2i(cols, rows)


static func load_map_file() -> Array[Array]:
	if not FileAccess.file_exists(MAP_FILE):
		push_error("MazeGenerator: 找不到地图文件 %s" % MAP_FILE)
		return []
	var f := FileAccess.open(MAP_FILE, FileAccess.READ)
	var grid: Array[Array] = []
	var row_len := -1
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if row_len >= 0 and line.length() != row_len:
			push_warning("MazeGenerator: 第 %d 行长度 %d 与首行 %d 不一致，已跳过" % [grid.size() + 1, line.length(), row_len])
			continue
		var row: Array[int] = []
		for ch in line:
			row.append(SOLID if ch == "1" else EMPTY)
		grid.append(row)
		row_len = line.length()
	f.close()
	if grid.is_empty():
		push_error("MazeGenerator: 地图文件 %s 无有效行" % MAP_FILE)
	return grid


# 当前关卡网格(level_0._ready 赋值;空网格时寻路一律视为无路)。
static var current_grid: Array[Array] = []


# 像素坐标 → 环面格子坐标(取模回 [0,cols)×[0,rows))。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))


# 环面 4 邻居 BFS:返回从 from_cell 到 to_cell 的格序列(不含起点,含终点)。
# 只走 EMPTY 格;限量访问 max_visit,超限视为无路。同格/无路返回空数组。
static func bfs_path(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 8000) -> Array[Vector2i]:
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
			if visited.has(n) or grid[n.y][n.x] == SOLID:
				continue
			visited[n] = true
			prev[n] = cur
			if n == to_cell:
				return _rebuild_path(prev, from_cell, to_cell)
			queue.append(n)
	return []


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
		if grid[y][x] == SOLID:
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
