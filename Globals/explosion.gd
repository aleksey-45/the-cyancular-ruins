class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.35  # 内圈半径比例,内圈内满伤

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float) -> void:
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d := _dist(center, (e as Node2D).global_position)
		if d > radius:
			continue
		if has_grid and not _has_los(center, e as Node2D, grid):
			continue  # 遮挡(硬掩体):0 伤
		var dmg := _falloff(d, radius, max_damage)
		if dmg <= 0:
			continue
		e.hurt(dmg, _outward_dir(center, (e as Node2D).global_position), _falloff(d, radius, max_knockback))
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit") and not (p.has_method("is_downed") and p.is_downed()):
		var d := _dist(center, (p as Node2D).global_position)
		if d <= radius and (not has_grid or _has_los(center, p as Node2D, grid)):
			p.take_hit(center, _falloff(d, radius, max_damage))  # take_hit 按 source 方向推 = 向外冲击波

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

static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	return max_val * (1.0 - (d - inner) / (radius - inner))
