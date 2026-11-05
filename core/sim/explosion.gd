class_name Explosion
extends RefCounted

# 爆炸 AoE 判定：引擎形状查询取候选、引擎射线判遮挡，衰减与友伤仍是玩法规则。
const INNER_FRACTION: float = TileDefs.BLAST_INNER_FRACTION  # 内圈半径比例,内圈内满伤
const BLOCKED_FRACTION: float = 0.75  # 墙后(LOS 遮挡)伤害/击退保留比例

## authority 不为空时目标集合已确定（联机权威端），直接按环面中心距离结算；
## 单人仍用物理候选，避免在权威端重复一次形状查询与 RID 反查。
static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float,
		shooter: Node = null, impact_id: int = 0, authority: AuthorityWorld = null) -> void:
	var tree := _tree()
	var has_grid := not TileDefs.terrain.empty()
	if authority != null:
		var roles := authority.players.keys()
		roles.sort()
		for role in roles:
			var body := authority.players[role] as Player
			if body == null:
				continue
			_damage_player(tree, center, radius, max_damage, max_knockback, shooter, impact_id, body, has_grid)
		if has_grid:
			_damage_tiles(center, radius, max_damage, shooter)
		return
	var seen := {}
	var candidates := _candidates(center, radius)
	for entry: Dictionary in candidates:
		var body := _owner_of(entry)
		if body == null or seen.has(body.get_instance_id()):
			continue
		seen[body.get_instance_id()] = true
		if body is EnemyBase:
			_damage_enemy(center, radius, max_damage, max_knockback, body as EnemyBase, has_grid)
		elif body is Player:
			_damage_player(tree, center, radius, max_damage, max_knockback, shooter, impact_id, body as Player, has_grid)
	# 可破坏瓦片(树叶/树干):按 tile_defs 爆炸衰减(75%)扣除生命值,破坏后变空气
	if has_grid:
		_damage_tiles(center, radius, max_damage, shooter)

# 候选只来自物理形状：真实形状触到爆炸圈才结算。
# 爆心贴接缝时同时查询镜像位置，否则接缝另一侧的角色会漏检。
static func _candidates(center: Vector2, radius: float) -> Array:
	var space := TileDefs.terrain.space_rid()
	if radius <= 0.0 or not space.is_valid():
		return []
	var world := CollisionWorld.for_space(space)
	var mask := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B
	var out: Array = []
	var seen := {}
	for at in CollisionWorld.toroidal_centers(center, radius):
		for entry: Dictionary in world.circle_overlaps(at, radius, mask):
			var key: int = entry["rid"].get_id()
			if seen.has(key):
				continue
			seen[key] = true
			out.append(entry)
	return out

static func _owner_of(entry: Dictionary) -> Node2D:
	return entry["collider"] as Node2D

static func _damage_enemy(center: Vector2, radius: float, max_damage: int, max_knockback: float,
		enemy: EnemyBase, has_grid: bool) -> void:
	var d := _dist(center, enemy.global_position)
	if d > radius:
		return
	# 遮挡(墙后)= 部分掩体;内圈免疫遮挡(见 cover_multiplier 注释)
	var blocked := has_grid and not _has_los(center, enemy.global_position)
	var cover := cover_multiplier(d, radius, blocked)
	var wmult := Water.water_mult(enemy.global_position)  # 目标在水里:×水格 decay
	var dmg := BlastCurve.falloff(d, radius, radius * INNER_FRACTION, max_damage) * cover * wmult
	if dmg <= 0:
		return
	# 屏幕中心准星命中反馈
	CombatFeedback.hit_marker()
	# 爆炸击退覆盖原速度，严格沿爆心到目标的径向方向
	enemy.hurt(int(dmg), _outward_dir(center, enemy.global_position),
			BlastCurve.falloff(d, radius, radius * INNER_FRACTION, max_knockback) * cover * wmult, true)

# 玩家分支只服务真实 Player（本地角色/权威端角色/远端 forecast）；伤害与归属经权威或本地结算。
static func _damage_player(tree: SceneTree, center: Vector2, radius: float, max_damage: int, max_knockback: float,
		shooter: Node, impact_id: int, player: Player, has_grid: bool) -> void:
	if player.authority_world == null:
		_cam_shake(center, radius, tree.get_first_node_in_group("player") as Node2D)
	if player.is_downed():
		return
	var effect := player_effect(center, radius, max_damage, max_knockback, player, has_grid)
	if effect.is_empty():
		return
	var amount: int = effect["damage"]
	var knock: float = effect["knock"]
	if player.authority_world != null:
		player.authority_world.damage(shooter.role if shooter != null else 0, player.role, center, amount, true, knock, impact_id, 2)
	else:
		CombatFeedback.attribute(player, shooter)
		player.take_hit(center, amount, true, knock)

static func player_effect(center: Vector2, radius: float, damage: int, knockback: float, player: Node2D, has_grid := true) -> Dictionary:
	var d := _dist(center, player.global_position)
	if d > radius:
		return {}
	var blocked := has_grid and not _has_los(center, player.global_position)
	var mult := cover_multiplier(d, radius, blocked) * Water.water_mult(player.global_position)
	var inner := radius * INNER_FRACTION
	return {"damage": int(BlastCurve.falloff(d, radius, inner, damage) * mult),
		"knock": BlastCurve.falloff(d, radius, inner, knockback) * mult}

# 扫描爆炸范围内存活的可破坏子格，供伤害结算与碎屑发射点共用。
static func destructible_subs(center: Vector2, radius: float, include_destroyed: bool = false) -> Array:
	return TileDefs.terrain.destructible_subs(center, radius, include_destroyed)

static func _damage_tiles(center: Vector2, radius: float, max_damage: int, owner: Node = null) -> void:
	TileDefs.terrain.damage_blast(center, radius, max_damage, TileDefs.owner_role(owner))

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
	if cam == null:
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
	return GridPathfinder.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()

static func _outward_dir(center: Vector2, target: Vector2) -> Vector2:
	var delta := GridPathfinder.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return delta.normalized() if not delta.is_zero_approx() else Vector2.RIGHT

static func _has_los(center: Vector2, target: Vector2) -> bool:
	return TileDefs.terrain.line_of_sight(center, target)


# 掩护衰减系数:内圈(≤INNER_FRACTION 半径)免疫遮挡——贴脸目标被墙棱角判"无视线"
# 扣 25% 会出现"爆心比开阔边缘伤害低"的倒挂(实测 bug);爆心贴脸时掩护不该生效。
# 纯函数(-s 可测);apply_aoe 的敌人/玩家分支共用,保证"任意距离伤害随距离不增"。
static func cover_multiplier(d: float, radius: float, blocked: bool) -> float:
	if d <= radius * INNER_FRACTION:
		return 1.0
	return BLOCKED_FRACTION if blocked else 1.0
