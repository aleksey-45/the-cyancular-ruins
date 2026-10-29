class_name Water
extends RefCounted

# 水体判定模块：提供水中状态检测、水面高度计算与完全浸水判定。纯静态工具类，不依赖 Autoload。
# 判定约定：角色脚底进入水体网格即判定处于水中；浮力机制将身体中心拉至水面高度（呈半没入浮动状态）。

const TILE_TS: int = 64


static func is_liquid(texture: int) -> bool:
	return TileDefs.is_liquid(texture)


static func is_in_water(pos: Vector2) -> bool:
	return TileDefs.terrain.water(pos)

static func surface_y_at(pos: Vector2) -> float:
	return TileDefs.terrain.water_surface(pos)


# 完全浸水（完全没入水中）判定：当身体中心低于水面高度时判定为完全浸水（正常漂浮时中心接近水面线，不计为完全没入水中）。
static func submerged(center: Vector2, surface_y: float) -> bool:
	return center.y > surface_y


# 计算水体环境下的爆炸衰减：若目标处于水体中，爆炸伤害与击退按水格的 explosion_decay（0.25）保留，否则为 1.0。
static func water_mult(pos: Vector2) -> float:
	return TileDefs.terrain.water_multiplier(pos)


# 子弹水中速度阻力系数(纯函数,-s 可测):在水里返回 exp(-drag·Δt),否则 1.0。
static func bullet_drag_factor(in_water: bool, drag: float, delta: float) -> float:
	return exp(-drag * delta) if in_water else 1.0


# 实体脚底相对原点偏移(世界 px):取活动碰撞箱底边;找不到回退 24。
# 该值只随「启用的碰撞体集合」变化(纯平移/固定几何下相对偏移不变),故按签名缓存:
# 签名 = 各 CollisionShape2D 的 instance_id 带 disabled 符号求和(固定节点集下,不同
# 启用组合的和互不相同)。命中缓存直接返回,免去每帧对多边形顶点做 to_global 扫描。
static func feet_offset(body: Node) -> float:
	var sig := _feet_signature(body)
	if body.has_meta("_water_feet_off") and body.has_meta("_water_feet_sig") \
			and int(body.get_meta("_water_feet_sig")) == sig:
		return float(body.get_meta("_water_feet_off"))
	var off := _feet_offset_compute(body)
	body.set_meta("_water_feet_off", off)
	body.set_meta("_water_feet_sig", sig)
	return off


static func _feet_signature(body: Node) -> int:
	var sig := 0
	for child in body.get_children():
		if child is CollisionShape2D:
			var id := int(child.get_instance_id())
			sig += id if not (child as CollisionShape2D).disabled else -id
	return sig


static func _feet_offset_compute(body: Node) -> float:
	var b := body as Node2D
	if b == null or not CollisionAabb.has_any(b):
		return 24.0
	return maxf(24.0, CollisionAabb.world_rect(b).end.y - b.global_position.y)
