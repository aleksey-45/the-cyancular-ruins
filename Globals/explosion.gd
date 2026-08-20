class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.35  # 内圈半径比例,内圈内满伤
const BLOCKED_FRACTION: float = 0.75  # 墙后(LOS 遮挡)伤害/击退保留比例

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float) -> void:
	var tree := _tree()
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d := _dist(center, (e as Node2D).global_position)
		if d > radius:
			continue
		# 遮挡(墙后)= 部分掩体:伤害/击退保留 BLOCKED_FRACTION;无遮挡全额
		var blocked := has_grid and not _has_los(center, e as Node2D, grid)
		var dmg := _falloff(d, radius, max_damage) * (BLOCKED_FRACTION if blocked else 1.0)
		if dmg <= 0:
			continue
		# set_velocity=true:爆炸击退覆盖原速度,严格沿爆心→目标径向(不叠加鸟自身飞行速度带偏)
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * (BLOCKED_FRACTION if blocked else 1.0), true)
	var p := tree.get_first_node_in_group("player")
	if p != null and p.has_method("take_hit") and not (p.has_method("is_downed") and p.is_downed()):
		var d := _dist(center, (p as Node2D).global_position)
		if d <= radius:
			var blocked := has_grid and not _has_los(center, p as Node2D, grid)
			var mult := BLOCKED_FRACTION if blocked else 1.0
			# 击退随距离衰减传入玩家(独立击退向量结算)
			p.take_hit(center, int(_falloff(d, radius, max_damage) * mult), false,
					_falloff(d, radius, max_knockback) * mult)

# 静态函数取场景树:全局 get_tree() 在 static 上下文不可用,走主循环。
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

# 软圆白贴图:占位爆炸/榴弹占位/预瞄爆点标记共用。
static func make_circle_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x - cx, y - cx).length() / cx
			if d <= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, (1.0 - d) * 0.9))
	return ImageTexture.create_from_image(img)

static func _dist(center: Vector2, target: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()

static func _outward_dir(center: Vector2, target: Vector2) -> Vector2:
	var delta := MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return delta.normalized() if not delta.is_zero_approx() else Vector2.RIGHT

static func _has_los(center: Vector2, target: Node2D, grid: Array[Array]) -> bool:
	var ts: int = GameParameters.TILE_SIZE
	var center_cell := MazeGenerator.cell_of(center, ts, grid[0].size(), grid.size())
	var target_cell := MazeGenerator.cell_of(target.global_position, ts, grid[0].size(), grid.size())
	return MazeGenerator.has_line_of_sight(center_cell, target_cell)

# 平滑衰减:内圈满值,smoothstep 渐变到 0(两端斜率归零,消除线性衰减在内外圈交接处的折角)
static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	var t := (d - inner) / (radius - inner)
	var s := t * t * (3.0 - 2.0 * t)  # smoothstep(t)
	return max_val * (1.0 - s)
