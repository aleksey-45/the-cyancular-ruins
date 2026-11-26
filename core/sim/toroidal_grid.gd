class_name ToroidalGrid
extends RefCounted

# 两个子格之间的曼哈顿距离，横向和纵向分别取较短的路线。
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, cols - dx)
	var dy := absi(a.y - b.y)
	dy = mini(dy, rows - dy)
	return dx + dy


# 取得 a 指向 b 的最短位移。若从地图另一侧到达更近，则用跨边缘的位移。
static func toroidal_delta_px(a: Vector2, b: Vector2, size: Vector2) -> Vector2:
	var dx := b.x - a.x
	if absf(dx) > size.x * 0.5:
		dx = -signf(dx) * (size.x - absf(dx))
	var dy := b.y - a.y
	if absf(dy) > size.y * 0.5:
		dy = -signf(dy) * (size.y - absf(dy))
	return Vector2(dx, dy)


# 返回离 anchor 最近的对应位置。必要时将 pos 按地图宽度或高度平移。
static func anchor_to_nearest(pos: Vector2, anchor: Vector2, size: Vector2) -> Vector2:
	return anchor + toroidal_delta_px(anchor, pos, size)


# 返回为满足边缘碰撞或绘制范围所需的平移副本索引。
# (0, 0) 表示原位置。横向和纵向索引每增加 1，分别平移一个地图宽度和高度。
static func seam_copy_range(bounds: Rect2, period: Vector2, reach: Vector2) -> Rect2i:
	var first := -Vector2i(((bounds.end + reach - period) / period).ceil())
	var last := Vector2i(((reach - bounds.position) / period).ceil())
	return Rect2i(first, last - first + Vector2i.ONE)


# 把越界坐标换回地图另一侧的对应位置，结果总在 [0, width) × [0, height) 内。
static func wrap_to_range(pos: Vector2, size: Vector2) -> Vector2:
	var p := pos
	if p.x >= size.x or p.x < 0.0:
		p.x = fposmod(p.x, size.x)
	if p.y >= size.y or p.y < 0.0:
		p.y = fposmod(p.y, size.y)
	return p


# 把世界坐标换算成子格索引，并将越界位置对应到地图另一侧。
static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	var c := Vector2i(floori(pos.x / ts), floori(pos.y / ts))
	return Vector2i(posmod(c.x, cols), posmod(c.y, rows))
