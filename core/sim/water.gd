class_name Water
extends RefCounted

# 水判定:唯一入口是 sample_body(按整具身体采样),点查询只留给未迁移面。
# ★ 采样点与阈值全收在本文件 —— 调用方各选一个点/各定一条线正是旧实现"一帧三种答案"的根。
# 依赖 MazeGenerator.current_grid(level_0 赋值);静态、不引 autoload,-s 可直接 load。

const TILE_TS: int = 64
const FALLBACK_HALF_HEIGHT: float = 24.0   # 没有碰撞体的实体按 ±24px 估身高(与旧兜底一致)
const HEAD_UNDER_MARGIN: float = 0.0       # 头低于水面线多少算没顶;0 = 严格没入

# 滞回阈值定义在 GameParameters(共享参数集中地)。这里用 preload 取脚本常量而不是读 autoload 单例:
# -s 冒烟里 autoload 未实例化,直接引用会拿到空实例;脚本常量与实例无关。
const GameConfig := preload("res://core/config/game_parameters.gd")
const WaterSample := preload("res://core/sim/water_sample.gd")

# ── 点查询(未迁移面:子弹阻力 / 爆炸 / 预瞄)────────────────────────────

static func is_liquid(texture: int) -> bool:
	return TileDefs.is_liquid(texture)


# 该点所属 64px 格是否液体。★ 判断"人在不在水里"用 sample_body,别拿一个点代表整具身体。
static func is_in_water(pos: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var c := MazeGenerator.cell_of(pos, TILE_TS, grid[0].size(), grid.size())
	return _cell_is_liquid(grid, c.y, c.x)


# 所在连续液体段的顶边(px),归一到离 pos 最近的环面副本;点不在水里时返回 pos.y。
# 全液列没有自由面:向上扫有 rows 上限,返回一个格顶边,不死循环。
static func surface_y_at(pos: Vector2) -> float:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return pos.y
	var cols := grid[0].size()
	var rows := grid.size()
	var c := MazeGenerator.cell_of(pos, TILE_TS, cols, rows)
	if not _cell_is_liquid(grid, c.y, c.x):
		return pos.y
	var top := c.y
	var steps := 0
	while steps < rows - 1:
		var above := posmod(top - 1, rows)
		if not _cell_is_liquid(grid, above, c.x):
			break
		top = above
		steps += 1
	var surface := float(top * TILE_TS)
	var map_h := float(rows * TILE_TS)
	return surface - map_h * roundf((surface - pos.y) / map_h)


# 旧口径薄封装:一条水面线比一个中心 y。★ 新代码用 sample_body().head_under。
static func submerged(center: Vector2, surface_y: float) -> bool:
	return center.y > surface_y

# ── 身体查询(唯一入口)────────────────────────────────────────────────

# 采样点 = 活动碰撞箱的头顶/脚底;水面线 = 所在水袋顶边(最近环面副本)。
# was_in_water = 上一帧结论,用于 enter/exit 滞回;采样有 rows 上限(全液列标 SURFACE_FULL)。
static func sample_body(body: Node2D, was_in_water: bool) -> WaterSample:
	var s := WaterSample.new()
	var grid := MazeGenerator.current_grid
	if body == null or grid.is_empty():
		return s
	var rows := grid.size()
	var cols: int = grid[0].size()
	var offs := _body_vert_offsets(body)
	var feet_y: float = body.global_position.y + offs.y
	var head_y: float = body.global_position.y + offs.x
	s.feet_y = feet_y
	s.head_y = head_y
	var body_h := maxf(feet_y - head_y, 1.0)
	var x := posmod(int(floorf(body.global_position.x / TILE_TS)), cols)
	var feet_row := posmod(int(floorf(feet_y / TILE_TS)), rows)
	var head_row := posmod(int(floorf(head_y / TILE_TS)), rows)
	# 身体纵向覆盖的行(向上数,含两端);比整图还高时按整图截断
	var span := mini(posmod(feet_row - head_row, rows) + 1, rows)
	var start_row := -1
	for i in span:
		var r := posmod(feet_row - i, rows)
		if _cell_is_liquid(grid, r, x):
			start_row = r
			break
	if start_row < 0:
		return s
	var top := start_row
	var steps := 0
	while steps < rows:
		var above := posmod(top - 1, rows)
		if not _cell_is_liquid(grid, above, x):
			break
		top = above
		steps += 1
	if steps >= rows:
		# 整列液体:环面没有自由面 ⇒ 永远在水里,也永远没顶
		s.surface_kind = WaterSample.SURFACE_FULL
		s.surface_y = feet_y
		s.in_water = true
		s.head_under = true
		s.submersion_ratio = 1.0
		return s
	var bot := start_row
	var dsteps := 0
	while dsteps < rows:
		var below := posmod(bot + 1, rows)
		if not _cell_is_liquid(grid, below, x):
			break
		bot = below
		dsteps += 1
	var map_h := float(rows * TILE_TS)
	var surface := float(top * TILE_TS)
	surface -= map_h * roundf((surface - body.global_position.y) / map_h)
	s.surface_y = surface
	s.surface_kind = _surface_kind_of(grid, top, x, rows)
	s.feet_depth = feet_y - surface
	s.depth_px = s.feet_depth
	s.head_under = head_y > surface + HEAD_UNDER_MARGIN
	var bottom_y := surface + float(posmod(bot - top, rows) + 1) * TILE_TS
	var overlap := clampf(minf(feet_y, bottom_y) - maxf(head_y, surface), 0.0, body_h)
	s.submersion_ratio = overlap / body_h
	# 滞回:上一帧在里 ⇒ 退到 water_exit_depth 才出;上一帧在外 ⇒ 进到 water_enter_depth 才进
	if was_in_water:
		s.in_water = s.feet_depth > GameConfig.water_exit_depth
	else:
		s.in_water = s.feet_depth >= GameConfig.water_enter_depth
	return s

# ── 爆炸 / 子弹 ──────────────────────────────────────────────────────

# 目标所在格是水 → 爆炸伤害/击退按该格 explosion_decay(0.25)保留,否则 1.0。
# ★ 点口径:爆炸 S4 再收口到 sample_body,本轮不动。
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

# ── 碰撞箱几何 ──────────────────────────────────────────────────────

# 实体脚底相对原点偏移(px):活动碰撞箱底边;无碰撞体回退 24。
# ★ 签名必须同时数 CollisionPolygon2D 与 CollisionShape2D:玩家 5 个姿态箱与三敌身体全在多边形上,
#   只数形状会让签名恒 0、缓存永不失效(旧 bug:首帧 5 箱全启用被缓存成 58.0)。
static func feet_offset(body: Node) -> float:
	if body == null:
		return FALLBACK_HALF_HEIGHT
	var sig := _feet_signature(body)
	if body.has_meta("_water_feet_off") and body.has_meta("_water_feet_sig") \
			and int(body.get_meta("_water_feet_sig")) == sig:
		return float(body.get_meta("_water_feet_off"))
	var off := _body_vert_offsets(body).y
	body.set_meta("_water_feet_off", off)
	body.set_meta("_water_feet_sig", sig)
	return off


static func _feet_signature(body: Node) -> int:
	var sig := 0
	for child in body.get_children():
		var id := int(child.get_instance_id())
		if child is CollisionPolygon2D:
			sig += id if not (child as CollisionPolygon2D).disabled else -id
		elif child is CollisionShape2D:
			sig += id if not (child as CollisionShape2D).disabled else -id
	return sig


# (头顶偏移, 脚底偏移):活动碰撞箱的上下边相对原点;无碰撞体按 ±24 兜底。
static func _body_vert_offsets(body: Node) -> Vector2:
	var b := body as Node2D
	if b == null or not CollisionAabb.has_any(b):
		return Vector2(-FALLBACK_HALF_HEIGHT, FALLBACK_HALF_HEIGHT)
	var rect := CollisionAabb.world_rect(b)
	var oy := b.global_position.y
	return Vector2(minf(-FALLBACK_HALF_HEIGHT, rect.position.y - oy),
			maxf(FALLBACK_HALF_HEIGHT, rect.end.y - oy))


static func _cell_is_liquid(grid: Array[Array], row: int, x: int) -> bool:
	var v: int = grid[row][x]
	return v != 0 and is_liquid(MazeGenerator.texture_of(v))


# 水袋顶边之上是什么:0 = 空气,非墙(梯/链/气体)= 自由面,墙 = 封闭顶
static func _surface_kind_of(grid: Array[Array], top_row: int, x: int, rows: int) -> int:
	var v: int = grid[posmod(top_row - 1, rows)][x]
	if v == 0:
		return WaterSample.SURFACE_FREE
	return WaterSample.SURFACE_CEILING if TileDefs.is_blocked(v) else WaterSample.SURFACE_FREE
