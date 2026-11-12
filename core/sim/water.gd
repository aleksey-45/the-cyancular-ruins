class_name Water
extends RefCounted

const SWIM_ENTER_DEPTH := 8.0
const SWIM_EXIT_MARGIN := 2.0


static func feet(bounds: Rect2) -> Vector2:
	return Vector2(bounds.get_center().x, bounds.end.y)


static func head_submerged(terrain: Terrain, bounds: Rect2) -> bool:
	return terrain.water(Vector2(bounds.get_center().x, bounds.position.y))


## 返回进入或保持游泳时的脚底深度，离水时为 -INF。
static func swim_depth(terrain: Terrain, foot: Vector2, swimming: bool) -> float:
	var depth := terrain.water_depth(foot)
	if swimming:
		if depth == -INF:
			depth = terrain.water_depth(foot + Vector2(0.0, SWIM_EXIT_MARGIN)) - SWIM_EXIT_MARGIN
		return depth
	return depth if depth >= SWIM_ENTER_DEPTH else -INF


# 子弹水中速度阻力系数(纯函数,-s 可测):在水里返回 exp(-drag·Δt),否则 1.0。
static func bullet_drag_factor(in_water: bool, drag: float, delta: float) -> float:
	return exp(-drag * delta) if in_water else 1.0
