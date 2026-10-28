class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = TileDefs.BLAST_INNER_FRACTION  # 内圈半径比例,内圈内满伤
const BLOCKED_FRACTION: float = 0.75  # 墙后(LOS 遮挡)伤害/击退保留比例

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float, shooter: Node = null, impact_id: int = 0) -> void:
	var tree := _tree()
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d := _dist(center, (e as Node2D).global_position)
		if d > radius:
			continue
		# 遮挡(墙后)= 部分掩体;内圈免疫遮挡(见 cover_multiplier 注释)
		var blocked := has_grid and not _has_los(center, e as Node2D, grid)
		var cover := cover_multiplier(d, radius, blocked)
		var wmult := Water.water_mult((e as Node2D).global_position)  # 目标在水里:×水格 decay
		var dmg := _falloff(d, radius, max_damage) * cover * wmult
		if dmg <= 0:
			continue
		# 屏幕中心准星命中反馈
		CombatFeedback.hit_marker()
		# 爆炸击退覆盖原速度，严格沿爆心到目标的径向方向
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * cover * wmult, true)
	# 遍历所有玩家(PvP 服务器两个玩家;单机组里只有一个 → 行为不变)
	var first_player: Node2D = null
	for p in tree.get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		var pp := p as Node2D
		if first_player == null and pp.authority_world == null:
			first_player = pp
			_cam_shake(center, radius, pp)
		if not pp.has_method("take_hit"):
			continue
		if pp.has_method("is_downed") and pp.is_downed():
			continue
		var effect := player_effect(center, radius, max_damage, max_knockback, pp)
		if not effect.is_empty():
			var amount: int = effect["damage"]
			var knock: float = effect["knock"]
			if pp.authority_world != null:
				pp.authority_world.damage(shooter.role if shooter != null else 0, pp.role, center, amount, true, knock, impact_id, 2)
			else:
				if shooter == pp:
					CombatFeedback.note_self_hit(pp)
				CombatFeedback.attribute(pp, shooter)
				pp.take_hit(center, amount, true, knock)
	# 可破坏瓦片(树叶/树干):按 tile_defs 爆炸衰减(75%)扣除生命值,破坏后变空气
	if has_grid:
		_damage_tiles(center, radius, max_damage, shooter)

static func player_effect(center: Vector2, radius: float, damage: int, knockback: float, player: Node2D) -> Dictionary:
	var d := _dist(center, player.global_position)
	if d > radius:
		return {}
	var grid := MazeGenerator.current_grid
	var blocked := not grid.is_empty() and not _has_los(center, player, grid)
	var mult := cover_multiplier(d, radius, blocked) * Water.water_mult(player.global_position)
	return {"damage": int(_falloff(d, radius, damage) * mult), "knock": _falloff(d, radius, knockback) * mult}

# 扫描爆炸范围内存活的可破坏子格，供伤害结算与碎屑发射点共用。
static func destructible_subs(center: Vector2, radius: float, include_destroyed: bool = false) -> Array:
	return TileDefs.terrain.destructible_subs(center, radius, include_destroyed)


static func _damage_tiles(center: Vector2, radius: float, max_damage: int, owner: Node = null) -> void:
	TileDefs.terrain.damage_blast(center, radius, max_damage, TileDefs.owner_role(owner))

static func sub_damage(entry: Dictionary, radius: float, max_damage: int) -> int:
	return int(_falloff(float(entry["d"]), radius, max_damage) * TileDefs.explosion_decay())


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


# 掩护衰减系数:内圈(≤INNER_FRACTION 半径)免疫遮挡——贴脸目标被墙棱角判"无视线"
# 扣 25% 会出现"爆心比开阔边缘伤害低"的倒挂(实测 bug);爆心贴脸时掩护不该生效。
# 纯函数(-s 可测);apply_aoe 的敌人/玩家分支共用,保证"任意距离伤害随距离不增"。
static func cover_multiplier(d: float, radius: float, blocked: bool) -> float:
	if d <= radius * INNER_FRACTION:
		return 1.0
	return BLOCKED_FRACTION if blocked else 1.0
