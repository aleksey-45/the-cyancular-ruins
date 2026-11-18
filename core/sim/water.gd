class_name Water
extends RefCounted

const SWIM_ENTER_DEPTH := 8.0
const SWIM_EXIT_MARGIN := 2.0


static func feet(bounds: Rect2) -> Vector2:
	return Vector2(bounds.get_center().x, bounds.end.y)


static func head_submerged(terrain: Terrain, bounds: Rect2) -> bool:
	return terrain.water(Vector2(bounds.get_center().x, bounds.position.y))


## 返回脚底的入水深度。开始游泳需要达到最低深度。已在游泳时，脚底稍微离开水面也不会立即退出。无法继续游泳时返回 -INF。
static func swim_depth(terrain: Terrain, foot: Vector2, swimming: bool) -> float:
	var depth := terrain.water_depth(foot)
	if swimming:
		if depth == -INF:
			depth = terrain.water_depth(foot + Vector2(0.0, SWIM_EXIT_MARGIN)) - SWIM_EXIT_MARGIN
		return depth
	return depth if depth >= SWIM_ENTER_DEPTH else -INF


# 阻力只作用于水中的弹丸。指数衰减使经过相同时间后的减速量不受更新次数影响。
static func bullet_drag_factor(in_water: bool, drag: float, delta: float) -> float:
	return exp(-drag * delta) if in_water else 1.0
