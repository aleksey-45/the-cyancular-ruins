class_name Explosion
extends RefCounted

const INNER_FRACTION: float = 0.4
const BLOCKED_FRACTION: float = 0.75
const HitShape := preload("res://core/sim/hit_shape.gd")
const TILE_TS: int = GameParameters.TILE_SIZE


static func _map_px() -> Vector2:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2.ZERO
	return Vector2(grid[0].size() * TILE_TS, grid.size() * TILE_TS)

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float, shooter: Node = null, tile_unit_cells: float = 1.0) -> void:
	var tree := _tree()
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		if not HitShape.hurtable(e):
			continue
		var d := _hurt_dist(center, e as Node2D)
		if d > radius:
			continue
		var blocked := has_grid and not _has_los(center, e as Node2D, grid)
		var cover := cover_multiplier(d, radius, blocked)
		var wmult := Water.water_mult((e as Node2D).global_position, grid)
		var dmg := _falloff(d, radius, max_damage) * cover * wmult
		if dmg <= 0:
			continue
		CombatFeedback.hit_marker()
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * cover * wmult, true)
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
		var d := _hurt_dist(center, pp)
		if d <= radius:
			var blocked := has_grid and not _has_los(center, pp, grid)
			var mult := cover_multiplier(d, radius, blocked)
			mult *= Water.water_mult(pp.global_position, grid)
# ★ 自伤标记必须在 take_hit 之前(attribute 对 attacker == victim 静默跳过,自伤没有归因通道);只有投掷者本人在爆区里才写;本函数只写标记,伤害/击退一个数都不动。
			if shooter == pp:
				CombatFeedback.note_self_hit(pp)
			CombatFeedback.attribute(pp, shooter)
			pp.take_hit(center, int(_falloff(d, radius, max_damage) * mult), true,
					_falloff(d, radius, max_knockback) * mult)
	if has_grid:
		damage_tiles(center, radius, max_damage, shooter, tile_unit_cells)

# 爆区内的可破坏瓦片扫描(纯几何查询、不改状态):权威侧扣血与表现层碎片共用同一份扫描 ⇒ 两端同源。
static func destructible_subs(center: Vector2, radius: float) -> Array:
	var out: Array = []
	var sgrid := MazeGenerator.current_subgrid
	if sgrid.is_empty():
		return out
	var sc: int = sgrid[0].size()
	var sr: int = sgrid.size()
	var csub := Vector2i(posmod(int(center.x) / 16, sc), posmod(int(center.y) / 16, sr))
	var reach := ceili(radius / 16.0) + 1
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var sx := posmod(csub.x + dx, sc)
			var sy := posmod(csub.y + dy, sr)
			var tex: int = sgrid[sy][sx]
			if tex == 0 or not TileDefs.explosion_destroyable(tex):
				continue
			if TileDefs.sub_cols > 0 and not TileDefs.sub_hp.is_empty() \
					and TileDefs.sub_hp_at(Vector2i(sx, sy)) <= 0:
				continue
			var pos := Vector2(sx * 16.0 + 8.0, sy * 16.0 + 8.0)
			var d := _dist(center, pos)
			if d > radius:
				continue
			out.append({"sub": Vector2i(sx, sy), "pos": pos, "tex": tex, "d": d})
	return out


static func damage_tiles(center: Vector2, radius: float, max_damage: int, owner: Node = null, tile_unit_cells: float = 1.0) -> void:
	if tile_unit_cells >= 1.0:
		_damage_tiles_per_cell(center, radius, max_damage)
	elif tile_unit_cells >= 0.5:
		_damage_tiles_per_block(center, radius, max_damage, owner)
	else:
		_damage_tiles_per_sub(center, radius, max_damage, owner)


static func destructible_units(center: Vector2, radius: float, tile_unit_cells: float) -> Array:
	var unit_px := 16
	if tile_unit_cells >= 1.0:
		unit_px = 64
	elif tile_unit_cells >= 0.5:
		unit_px = 32
	var per := unit_px / 16
	var out: Array = []
	var at: Dictionary = {}
	for e in destructible_subs(center, radius):
		var sub: Vector2i = e["sub"]
		var key := Vector2i(int(sub.x) / per, int(sub.y) / per)
		var d := float(e["d"])
		if not at.has(key):
			at[key] = out.size()
			out.append({
				"block": key,
				"pos": Vector2(key.x * unit_px + unit_px * 0.5, key.y * unit_px + unit_px * 0.5),
				"tex": int(e["tex"]),
				"d": d,
				"unit_px": unit_px,
			})
		elif d < float(out[at[key]]["d"]):
			out[at[key]]["d"] = d
			out[at[key]]["tex"] = int(e["tex"])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ba: Vector2i = a["block"]
		var bb: Vector2i = b["block"]
		if ba.y != bb.y:
			return ba.y < bb.y
		return ba.x < bb.x)
	return out


static func _damage_tiles_per_block(center: Vector2, radius: float, max_damage: int, owner: Node = null) -> void:
	for u in destructible_units(center, radius, 0.5):
		var dmg := int(_falloff(float(u["d"]), radius, max_damage) * TileDefs.explosion_decay())
		if dmg <= 0:
			continue
		var b: Vector2i = u["block"]
		TileDefs.damage_block32(b, dmg, "explosion", owner)


static func _damage_tiles_per_sub(center: Vector2, radius: float, max_damage: int, owner: Node = null) -> void:
	for e in destructible_subs(center, radius):
		var dmg := int(_falloff(float(e["d"]), radius, max_damage) * TileDefs.explosion_decay())
		if dmg <= 0:
			continue
		TileDefs.damage_sub(e["sub"], dmg, "explosion", owner)


# 整格单位:同一格会被多个子格扫到 ⇒ 必须去重,否则一爆扣 N 次(表现上等同"多打了 N 发")。
static func _damage_tiles_per_cell(center: Vector2, radius: float, max_damage: int) -> void:
	var nearest: Dictionary = {}
	for e in destructible_subs(center, radius):
		var sub: Vector2i = e["sub"]
		var cell := Vector2i(int(sub.x) / 4, int(sub.y) / 4)
		var d := float(e["d"])
		if not nearest.has(cell) or d < float(nearest[cell]):
			nearest[cell] = d
	for cell in nearest:
		var dmg := int(_falloff(float(nearest[cell]), radius, max_damage) * TileDefs.explosion_decay())
		if dmg <= 0:
			continue
		TileDefs.damage_tile(cell, dmg, "explosion")


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

static func client_cam_shake(center: Vector2, radius: float) -> void:
	var tree := _tree()
	if tree == null:
		return
	for p in tree.get_nodes_in_group("player"):
		if p is Node2D:
			_cam_shake(center, radius, p as Node2D)
			return

static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

static func make_circle_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - cx, y - cx).length() / cx
			if d <= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, (1.0 - d) * 0.9))
	return ImageTexture.create_from_image(img)

static func _dist(center: Vector2, target: Vector2) -> float:
	var map := _map_px()
	if map == Vector2.ZERO:
		return center.distance_to(target)
	return MazeGenerator.toroidal_delta_px(center, target, map.x, map.y).length()


# 目标受击面到爆心的距离:按 hurt_rect 的体积算(旧实现拿节点原点当点 ⇒ 半径边缘"身体重叠但零伤害")。
# ★ 这是平衡变化:等效爆半径按半身变大,手感需人眼验收(已登记 docs/eng/registered-debt.md)。
static func _hurt_dist(center: Vector2, n: Node2D) -> float:
	var rect: Rect2 = n.hurt_rect() if n.has_method("hurt_rect") else HitShape.hurt_rect_of(n)
	var map := _map_px()
	if map == Vector2.ZERO:
		return HitShape.distance_px_to_rect(center, rect)
	return HitShape.distance_px_to_rect_at(center, rect, center, map.x, map.y)

static func _outward_dir(center: Vector2, target: Vector2) -> Vector2:
	var map := _map_px()
	var delta := MazeGenerator.toroidal_delta_px(center, target, map.x, map.y) if map != Vector2.ZERO \
			else target - center
	return delta.normalized() if not delta.is_zero_approx() else Vector2.RIGHT

static func _has_los(center: Vector2, target: Node2D, grid: Array[Array]) -> bool:
	var center_cell := MazeGenerator.cell_of(center, TILE_TS, grid[0].size(), grid.size())
	var target_cell := MazeGenerator.cell_of(target.global_position, TILE_TS, grid[0].size(), grid.size())
	return MazeGenerator.has_line_of_sight(center_cell, target_cell)

static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	var t := (d - inner) / (radius - inner)
	return max_val * (1.0 - t * t)


# 掩护衰减系数:内圈(≤ INNER_FRACTION 半径)免疫遮挡 —— 否则贴脸目标会被墙棱角判无视线,出现"爆心比开阔边缘伤害低"的倒挂(实测 bug)。
# 纯函数(-s 可测);apply_aoe 的敌人/玩家分支共用,保证任意距离伤害随距离不增。
static func cover_multiplier(d: float, radius: float, blocked: bool) -> float:
	if d <= radius * INNER_FRACTION:
		return 1.0
	return BLOCKED_FRACTION if blocked else 1.0