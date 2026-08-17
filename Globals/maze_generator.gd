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
