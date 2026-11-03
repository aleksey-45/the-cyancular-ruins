class_name TileQuery
extends RefCounted

# 「一个世界矩形压到哪类格」的单一来源。纯静态、**不引 autoload**(tile 尺寸由参数传入,


# 矩形覆盖的任一格是实心(非 0 且 type=wall)→ true。空网格 → false。
static func rect_overlaps_solid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, false)


# 矩形覆盖的任一格是实心**或液体** → true(飞行敌人用:水也是它的障碍)。空网格 → false。
static func rect_overlaps_solid_or_liquid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, true)


# 矩形覆盖的格中**最靠上**的那一行实心格的**行号**(格坐标,**未取模**;无 → -1)。
static func topmost_solid_row(rect: Rect2, ts: int) -> int:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return -1
	var rows := grid.size()
	var cols := grid[0].size()
	var x0 := floori(rect.position.x / ts)
	var x1 := floori(rect.end.x / ts)
	var y0 := floori(rect.position.y / ts)
	var y1 := floori(rect.end.y / ts)
	# gy 升序 → 第一个命中的就是最靠上的那一行
	for gy in range(y0, y1 + 1):
		var ry := posmod(gy, rows)
		for gx in range(x0, x1 + 1):
			if TileDefs.is_blocked(grid[ry][posmod(gx, cols)]):
				return gy
	return -1


static func _overlaps(rect: Rect2, ts: int, with_liquid: bool) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := grid[0].size()
	var x0 := floori(rect.position.x / ts)
	var x1 := floori(rect.end.x / ts)
	var y0 := floori(rect.position.y / ts)
	var y1 := floori(rect.end.y / ts)
	for gy in range(y0, y1 + 1):
		for gx in range(x0, x1 + 1):
			var v: int = grid[posmod(gy, rows)][posmod(gx, cols)]
			if TileDefs.is_blocked(v):
				return true
			if with_liquid and Water.is_liquid(MazeGenerator.texture_of(v)):
				return true
	return false
