class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.4  # 内圈半径比例,内圈内满伤
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
		var wmult := Water.water_mult((e as Node2D).global_position, grid)  # 目标在水里:×水格 decay
		var dmg := _falloff(d, radius, max_damage) * (BLOCKED_FRACTION if blocked else 1.0) * wmult
		if dmg <= 0:
			continue
		# set_velocity=true:爆炸击退覆盖原速度,严格沿爆心→目标径向(不叠加鸟自身飞行速度带偏)
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * (BLOCKED_FRACTION if blocked else 1.0) * wmult, true)
	# 遍历所有玩家(PvP 服务器两个玩家;单机组里只有一个 → 行为不变)
	var first_player: Node2D = null
	for p in tree.get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		var pp := p as Node2D
		if first_player == null:
			first_player = pp
			_cam_shake(center, radius, pp)
		if not pp.has_method("take_hit"):
			continue
		if pp.has_method("is_downed") and pp.is_downed():
			continue
		var d := _dist(center, pp.global_position)
		if d <= radius:
			var blocked := has_grid and not _has_los(center, pp, grid)
			var mult := BLOCKED_FRACTION if blocked else 1.0
			mult *= Water.water_mult(pp.global_position, grid)  # 目标在水里:×0.25
			# 击退随距离衰减传入玩家(独立击退向量结算);ignore_iframes=true 穿透无敌帧
			pp.take_hit(center, int(_falloff(d, radius, max_damage) * mult), true,
					_falloff(d, radius, max_knockback) * mult)
	# 可破坏瓦片(树叶/树干):按 tile_defs 爆炸衰减(75%)扣血,破坏后变空气
	if has_grid:
		_damage_tiles(center, radius, max_damage, grid)

# 爆炸对可破坏瓦片(树叶/树干)扣血:按距离衰减 × tile_defs 爆炸衰减(0.75),破坏后变空气。
static func _damage_tiles(center: Vector2, radius: float, max_damage: int, grid: Array[Array]) -> void:
	var ts: int = GameParameters.TILE_SIZE
	var rows := grid.size()
	var cols := grid[0].size()
	var cc := MazeGenerator.cell_of(center, ts, cols, rows)
	var reach_cells := ceili(radius / ts) + 1
	for dy in range(-reach_cells, reach_cells + 1):
		for dx in range(-reach_cells, reach_cells + 1):
			var cx := posmod(cc.x + dx, cols)
			var cy := posmod(cc.y + dy, rows)
			var v: int = grid[cy][cx]
			if v == 0:
				continue
			var tex: int = v / 16
			if not TileDefs.explosion_destroyable(tex):
				continue
			var d := _dist(center, Vector2(cx * ts + ts * 0.5, cy * ts + ts * 0.5))
			if d > radius:
				continue
			var dmg := int(_falloff(d, radius, max_damage) * TileDefs.explosion_decay())
			if dmg <= 0:
				continue
			TileDefs.damage_tile(Vector2i(cx, cy), dmg, "explosion")


# 静态函数取场景树:全局 get_tree() 在 static 上下文不可用,走主循环。
# 爆炸相机震动:爆心越贴近玩家震得越猛,随距离线性衰减;超出影响距离无震动。
# 与伤害分支独立——玩家倒地/在爆区外也能看到震动。
static func _cam_shake(center: Vector2, radius: float, p: Node2D) -> void:
	if p == null:
		return
	var d := _dist(center, p.global_position)
	var reach := maxf(radius * 2.5, 400.0)
	if d > reach:
		return
	var cam: Camera2D = p.get_viewport().get_camera_2d()
	if cam == null or not cam.has_method("shake"):
		return
	var amt := PlayerParams.explosion_cam_shake * (1.0 - d / reach)
	cam.shake(amt, PlayerParams.explosion_cam_shake_time)

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

# 平缓衰减:内圈满值,二次方(1-t²)渐变到 0——比 smoothstep 平缓,中远距离保留更多伤害/击退
static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	var t := (d - inner) / (radius - inner)
	return max_val * (1.0 - t * t)
