class_name BulletBase
extends BulletBody

# 玩家与通用弹丸：命中判定全部来自引擎运动结果，本层只处理表现、瓦片破坏与爆炸表现。

var authority_world: Node

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

# 子弹物理属性（由武器发射时注入）
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理材质着色

# 纯视觉跟随目标：PvP 客户端的显示弹只复制预测弹的模拟位姿，不参与碰撞。
var follow_target: BulletBody = null

@export var explosion_visual: PackedScene = null

# 视觉投影：逻辑与物理坐标保持规范区间，渲染子节点按最近环面副本平移。
var _visual: Node2D = null

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	set_source_node(src)
	rotation = velocity_vec.angle()
	scale = Vector2(size, size)  # 放大倍数作用于整颗子弹(贴图+碰撞体)

func _ready() -> void:
	_visual = Node2D.new()
	_visual.name = "Visual"
	add_child(_visual)
	var sprite := get_node_or_null("Sprite2D") as Node2D
	if sprite != null:
		remove_child(sprite)
		_visual.add_child(sprite)
	var collider := find_child("CollisionShape2D", true, false) as CollisionShape2D
	if collider != null:
		shape = collider.shape
	bind_physics(TileDefs.terrain, GameParameters.gravity0,
			GameParameters.water_bullet_drag, BOUNCE_DAMPING)
	if prediction_only:
		return
	if sprite != null:
		(sprite as Sprite2D).modulate = bullet_color
	add_to_group("bullet")
	if authority_world == null and Settings.pvp_show_trajectories:
		BulletTrail.attach(self, bullet_color)

func _physics_process(delta: float) -> void:
	if follow_target != null:
		# 显示弹不参与碰撞：逐帧复制预测弹的规范位姿，再按环面最近副本渲染。
		if is_instance_valid(follow_target) and not follow_target.is_queued_for_deletion():
			global_position = follow_target.global_position
			rotation = follow_target.rotation
			present_projection()
		return
	simulate_tick(delta)

func simulate_tick(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding(): return
	var result := advance_physics(delta)
	# 物理位置每 tick 收尾都回绕；先更新视觉副本，拖尾与爆炸特效才有正确落点。
	present_projection()
	if result == AdvanceResult.BOUNCED:
		var node := impact_node()
		if node != null and node.is_in_group("enemies"): _direct_hit(node, impact_velocity)
	elif result == AdvanceResult.ACTOR_HIT:
		_hit_actor()
	elif result == AdvanceResult.TERRAIN_HIT:
		_damage_tile_at(impact_point, impact_normal)
		set_physics_process(false)
		if not prediction_only: get_tree().create_timer(0.05).timeout.connect(queue_free)
	elif result == AdvanceResult.RANGE_END or result == AdvanceResult.FUSE_END:
		if explodes: _explode()
		finish()

# 命中非地形实体：敌人由物理体自身结算，角色代理交给权威/预测端按角色归属结算。
func _hit_actor() -> void:
	var node := impact_node()
	if node != null and node.is_in_group("enemies"):
		if apply_damage:
			CombatFeedback.hit_marker()
			# 发射者按 instance_id 反查：节点已释放时返回 null，直接走通用伤害路径。
			var src := get_source_node()
			if src != null:
				src.apply_hit(node, impact_velocity)
			else:
				node.hurt(hit_damage, impact_velocity, hit_impact)
			Sfx.play("hit")
		queue_free()
	elif impact_role == 0:
		set_physics_process(false)
		if not prediction_only: get_tree().create_timer(0.05).timeout.connect(queue_free)

func finish() -> void:
	finished = true
	if not prediction_only:
		queue_free()

# 只平移渲染子节点；global_position 始终是参与碰撞与快照的规范坐标。
func present_projection() -> void:
	if _visual == null:
		return
	if authority_world != null or prediction_only:
		visual_offset = Vector2.ZERO
		_visual.position = Vector2.ZERO
		return
	var anchor := get_tree().get_first_node_in_group("player") as Node2D
	if is_instance_valid(shooter) and shooter.is_in_group("player"):
		anchor = shooter as Node2D
	if anchor == null:
		visual_offset = Vector2.ZERO
		_visual.position = Vector2.ZERO
		return
	var shown := GridPathfinder.anchor_to_nearest(global_position, anchor.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	visual_offset = shown - global_position
	_visual.position = to_local(shown)

# 撞击地形处理：对可破坏瓦片扣除耐久并生成受击碎屑
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	if prediction_only:
		return
	var tex := TileDefs.terrain.damage_impact(pos, normal, hit_damage if apply_damage else 0, TileDefs.owner_role(shooter))
	if tex != 0 and authority_world == null:
		TileHitFx.spawn(get_viewport(), pos, tex)

func _direct_hit(hit: Node, incoming: Vector2 = Vector2.ZERO) -> void:
	if not apply_damage:
		return
	var direction := incoming if incoming != Vector2.ZERO else velocity_vec
	var dir := direction.normalized() if not direction.is_zero_approx() else Vector2.RIGHT
	CombatFeedback.hit_marker()
	hit.hurt(direct_hit_damage, dir)

func rewind_state() -> Dictionary:
	# 运动/引信沿用联机快照；补齐单人重建实例所需的开火参数。
	return motion_state().merged({"max_range": max_range, "gravity_factor": gravity_factor,
		"speed": speed, "size": size, "color": bullet_color,
		"hit_damage": hit_damage, "hit_impact": hit_impact})


# 应用时间回溯状态快照
func apply_rewind_state(d: Dictionary) -> void:
	type_id = d["type_id"]
	max_range = d["max_range"]
	gravity_factor = d["gravity_factor"]
	speed = d["speed"]
	size = d["size"]
	scale = Vector2(size, size)
	bullet_color = d["color"]
	hit_damage = d["hit_damage"]
	hit_impact = d["hit_impact"]
	if _visual != null:
		var sp2 := _visual.get_node_or_null("Sprite2D") as Sprite2D
		if sp2 != null:
			sp2.modulate = bullet_color
	restore_motion(d)
	present_projection()


func _explode() -> void:
	exploded = true
	if not apply_damage:
		return
	if authority_world == null:
		# 逻辑坐标恒为规范值；单人爆炸特效按最近展示副本生成，避免接缝另一侧的画面外爆点。
		present_explosion(get_viewport(), visual_center(), explosion_visual, explosion_radius)
		Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback,
				shooter, entity_id, null)
		return
	# 权威端在触发 tick 立即广播原 EXPLOSION；伤害、击退与地形破坏交给 t+3 的固定阶段。
	authority_world.broadcast(NetEvent.Kind.EXPLOSION, {"id": entity_id, "type_id": type_id,
			"pos": global_position, "tick": authority_world._snap_tick})
	var shooter_role: int = int(shooter.role) if shooter is ActorBody else 0
	authority_world.submit_blast(entity_id, global_position, explosion_radius, explosion_damage,
			explosion_knockback, shooter_role)

static func present_explosion(viewport: Viewport, pos: Vector2, visual: PackedScene, radius: float) -> void:
	if visual != null:
		var fx: Node2D = visual.instantiate()
		fx.position = pos
		viewport.add_child(fx)
	TileHitFx.spawn_explosion(viewport, pos, radius)
