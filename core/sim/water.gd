class_name Water
extends RefCounted

# 水体判定模块：提供水中状态检测、水面高度计算与完全浸水判定。纯静态工具类，不依赖 Autoload（支持命令行独立测试 -s）。
# 依赖 MazeGenerator.current_grid（由 Level0 初始化赋值）与网格规格 TILE_TS。
# 判定约定：角色脚底进入水体网格即判定处于水中；浮力机制将身体中心拉至水面高度（呈半没入浮动状态）。

const TILE_TS: int = 64


static func is_liquid(texture: int) -> bool:
	return TileDefs.is_liquid(texture)


static func is_in_water(pos: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var c := MazeGenerator.cell_of(pos, TILE_TS, grid[0].size(), grid.size())
	var v: int = grid[c.y][c.x]
	return v != 0 and is_liquid(MazeGenerator.texture_of(v))


# 沿所在列向上扫描连续水体网格，返回水面顶边的 Y 坐标（像素单位）；若目标点不在水中则返回原始坐标 pos.y。
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
		if v != 0 and is_liquid(MazeGenerator.texture_of(v)):
			top = above
			y = above
		else:
			break
	return float(top * TILE_TS)


# 完全浸水（完全没入水中）判定：当身体中心低于水面高度时判定为完全浸水（正常漂浮时中心接近水面线，不计为完全没入水中）。
static func submerged(center: Vector2, surface_y: float) -> bool:
	return center.y > surface_y


# 计算水体环境下的爆炸衰减：若目标处于水体中，爆炸伤害与击退按水格的 explosion_decay（0.25）保留，否则为 1.0。
static func water_mult(pos: Vector2, grid: Array[Array]) -> float:
	if grid.is_empty():
		return 1.0
	var c := MazeGenerator.cell_of(pos, TILE_TS, grid[0].size(), grid.size())
	var v: int = grid[c.y][c.x]
	if v == 0:
		return 1.0
	var tex: int = MazeGenerator.texture_of(v)
	if is_liquid(tex):
		return TileDefs.explosion_decay_of(tex)
	return 1.0


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
