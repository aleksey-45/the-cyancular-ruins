class_name Water
extends RefCounted

# 水判定/水面线/没顶判定。静态、不引 autoload(-s 可直接测)。
# 依赖 MazeGenerator.current_grid(level_0 赋值)与本地 TILE_TS。
# 约定:脚底(中心+半身)在水格 = 在水中;浮力弹簧把「身体中心」拉回水面线(半没入)。

const TILE_TS: int = 64


static func is_liquid(texture: int) -> bool:
	return TileDefs.type_of(texture) == "liquid"


static func is_in_water(pos: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var c := MazeGenerator.cell_of(pos, TILE_TS, grid[0].size(), grid.size())
	var v: int = grid[c.y][c.x]
	return v != 0 and is_liquid(v / 16)


# 所在列向上扫到最顶 liquid 格,返回其顶边 y(px);点不在水里时返回 pos.y(不硬拉)。
static func surface_y_at(pos: Vector2) -> float:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return pos.y
	var cols := grid[0].size()
	var rows := grid.size()
	var c := MazeGenerator.cell_of(pos, TILE_TS, cols, rows)
	if not is_in_water(pos):
		return pos.y
	var top := c.y
	var y := c.y
	while true:
		var above := posmod(y - 1, rows)
		var v: int = grid[above][c.x]
		if v != 0 and is_liquid(v / 16):
			top = above
			y = above
		else:
			break
	return float(top * TILE_TS)


# 没顶判定:中心低于水面线(浮着中心≈水面线,不算)。
static func submerged(center: Vector2, surface_y: float) -> bool:
	return center.y > surface_y


# 实体脚底相对原点偏移(世界 px):取活动碰撞箱底边;找不到回退 24。
static func feet_offset(body: Node) -> float:
	var offset := 24.0
	for child in body.get_children():
		if not (child is CollisionShape2D):
			continue
		if (child as CollisionShape2D).disabled:
			continue
		if child is CollisionPolygon2D:
			var cp := child as CollisionPolygon2D
			var pts := cp.polygon
			if pts.size() > 0:
				var maxy := cp.to_global(pts[0]).y
				for p in pts:
					maxy = maxf(maxy, cp.to_global(p).y)
				offset = maxf(offset, maxy - body.global_position.y)
		else:
			var shape := (child as CollisionShape2D).shape
			if shape is RectangleShape2D:
				var rs := shape as RectangleShape2D
				var hh := rs.size.y * 0.5
				offset = maxf(offset, (child as CollisionShape2D).to_global(Vector2(0, hh)).y - body.global_position.y)
	return offset
