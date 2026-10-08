class_name TileQuery
extends RefCounted

# 世界矩形与地形瓦片重叠判定工具。纯静态实现，无外部 Autoload 依赖。
#
# 提供两类查询接口：
#   - rect_overlaps_solid(_or_liquid)：判定区域内是否存在实心瓦片（或液体）
#   - topmost_solid_row：查询重叠区域内最靠上的实心瓦片行号，用于计算向上推出脱困位移
#
# 边界处理：根据 AABB 两端坐标映射瓦片范围，并通过 posmod 处理环面无缝回绕。


# 判定矩形覆盖范围内是否存在实心瓦片（非空气且 type 为 wall）。空网格返回 false。
static func rect_overlaps_solid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, false)


# 判定矩形覆盖范围内是否存在实心瓦片或液体瓦片（供飞行敌人避障使用）。空网格返回 false。
static func rect_overlaps_solid_or_liquid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, true)


# 获取矩形覆盖范围内最靠上的实心瓦片行号（未取模瓦片坐标，无重叠返回 -1）。
# 供脱困算法计算向上推出的最小位移。
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
