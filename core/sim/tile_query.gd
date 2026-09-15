class_name TileQuery
extends RefCounted

# 「一个世界矩形是否压到某类格」的单一来源。纯静态、**不引 autoload**(tile 尺寸由参数传入,
# 同 core/water.gd、core/math_util.gd、core/collision_aabb.gd 的约定),故 `-s` 可 load。
#
# ★ 为什么收到这里:同一段骨架 —— 按 AABB 求格范围 → posmod 回环面 → 双层 for → 逐格判定 ——
#   原先在**三处**各写了一遍:
#     · `enemy_black_bird._body_clear_at`  瞬移落点能不能站
#     · `enemy_fly_base._bird_can_pass`    飞行避障(额外把**水**也算障碍:鸟不能游)
#     · `weapon_base._disk_overlaps_solid` 预瞄小球判墙
#   环面回绕/形状语义的修正要改三处,漏一处就是某个系统独有的 bug(黑鸟穿墙瞬移 / 鸟撞墙卡死 /
#   预瞄弧线画错)。
#
# ★ **空网格的兜底不在本类**:三处原本各不相同(黑鸟"视为全清" / 飞鸟"不可走" / 预瞄"无墙"),
#   那是各自的调参结论,一律由调用方自备。本类在空网格上一律返回 false(= "没压到东西")。
#   ★ 飞鸟要注意:它要的是"空网格 → 不可走",所以调用方必须**保留**自己的 is_empty 早退。
#
# 格范围取 AABB 两端 floori 出来的格(不是"格中心所属格")—— 与三处原实现逐字一致
# (`MazeGenerator.cell_of` 也是 floori + posmod);跨接缝/负坐标由逐格 posmod 兜住。


# 矩形覆盖的任一格是实心(非 0 且 type=wall)→ true。空网格 → false。
static func rect_overlaps_solid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, false)


# 矩形覆盖的任一格是实心**或液体** → true(飞行敌人用:水也是它的障碍)。空网格 → false。
static func rect_overlaps_solid_or_liquid(rect: Rect2, ts: int) -> bool:
	return _overlaps(rect, ts, true)


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
