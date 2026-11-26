class_name Water
extends RefCounted

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")



static func feet(bounds: Rect2) -> Vector2:
	return Vector2(bounds.get_center().x, bounds.end.y)


static func head_submerged(terrain: Terrain, bounds: Rect2) -> bool:
	return terrain.water(Vector2(bounds.get_center().x, bounds.position.y))


## 返回脚底的入水深度，未进入或已退出游泳状态时返回 -INF。
## 开始游泳需要达到入水深度阈值，游泳中脚底略高于水面仍可维持状态。
static func swim_depth(terrain: Terrain, foot: Vector2, swimming: bool) -> float:
	var depth := terrain.water_depth(foot)
	if swimming:
		if depth == -INF:
			depth = terrain.water_depth(foot + Vector2(0.0, -WCFG.water_exit_depth)) + WCFG.water_exit_depth
		return depth
	return depth if depth >= WCFG.water_enter_depth else -INF


# 水中弹丸的速度按指数衰减，相同的累计浸水时间对应相同的阻力倍率。
static func bullet_drag_factor(in_water: bool, drag: float, delta: float) -> float:
	return exp(-drag * delta) if in_water else 1.0
