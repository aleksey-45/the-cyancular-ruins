class_name BulletBase
extends NativeBulletBody

var authority_world: Node

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

# 玩家命中判定半径（像素）
const PLAYER_HIT_RADIUS: float = 40.0
# 碰撞判定候选目标分组
const CONTACT_GROUPS: Array[String] = ["player", "player_replica"]

# 子弹物理属性（由武器发射时注入）
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理材质着色
var source: Node = null

@export var explosion_visual: PackedScene = null


func _init() -> void:
	configure_bullet({
		"entity_id": 0,
		"type_id": 0,
		"input_seq": 0,
		"input_epoch": 1,
		"adjudicated_pos": Vector2.ZERO,
		"adjudicated": false,
		"velocity_vec": Vector2.ZERO,
		"speed": 0.0,
		"size": 1.0,
		"gravity_factor": 0.0,
		"max_range": 0.0,
		"traveled": 0.0,
		"hit_damage": 0,
		"hit_impact": 0.0,
		"apply_damage": true,
		"prediction_only": false,
		"fuse_started": false,
		"finished": false,
		"exploded": false,
		"direct_hit": false,
		"explodes": false,
		"direct_hit_damage": 10,
		"fuse_time": 0.5,
		"hit_fuse_time": 0.1,
		"explosion_radius": 128.0,
		"explosion_damage": 35,
		"explosion_knockback": 900.0,
		"_fuse_active": false,
		"_fuse_elapsed": 0.0,
		"_fuse_duration": 0.0
	})

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	native_bind_source_node(src)
	rotation = velocity_vec.angle()
	scale = Vector2(size, size)  # 放大倍数作用于整颗子弹(贴图+碰撞体)

func _ready() -> void:
	if TileDefs.terrain.empty():
		TileDefs.terrain.set_empty_world_bounds(Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))
	bind_physics(TileDefs.terrain, GameParameters.gravity0,
			GameParameters.water_bullet_drag, BOUNCE_DAMPING)
	if prediction_only:
		return
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color
	add_to_group("bullet")
	if authority_world == null and Settings.pvp_show_trajectories:
		BulletTrail.attach(self, bullet_color)

func _physics_process(delta: float) -> void:
	simulate_tick(delta)

func simulate_tick(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding(): return
	if explodes and not _fuse_active and not prediction_only: _check_player_contact()
	var canonical := authority_world != null or prediction_only
	var result := advance_physics(delta, canonical)
	if result == MOVED and not canonical:
		_wrap()
	if result == BOUNCED:
		var hit := get_native_impact().get_collider()
		if hit != null and hit.is_in_group("enemies"): _direct_hit(hit, impact_velocity)
	elif result == TERRAIN_HIT:
		var col := get_native_impact()
		var hit := col.get_collider()
		if apply_damage and hit.is_in_group("enemies"):
			CombatFeedback.hit_marker()
			if is_instance_valid(source) and source.has_method("apply_hit"):
				source.apply_hit(hit, impact_velocity)
			else:
				hit.hurt(hit_damage, impact_velocity, hit_impact)
			Sfx.play("hit")
			queue_free()
		else:
			_damage_tile_at(col.get_position(), col.get_normal())
			set_physics_process(false)
			if not prediction_only: get_tree().create_timer(0.05).timeout.connect(queue_free)
	elif result == RANGE_END or result == FUSE_END:
		if explodes: _explode()
		finish()

func finish() -> void:
	finished = true
	if not prediction_only:
		queue_free()

# 权威世界与预测世界共用连续命中判定。
func player_contact(players: Array, contact_radius: float = PLAYER_HIT_RADIUS, point_only: bool = false) -> Node2D:
	var team: int = shooter.team if shooter != null else 0
	return native_player_contact(players, contact_radius, point_only,
			Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT), team)

static func contact_distance(from: Vector2, to: Vector2, position: Vector2, radius: float) -> float:
	return NativeBulletBody.contact_distance_native(from, to, position, radius,
			Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))



# 子弹在水中受阻力减速
func _apply_water_drag(delta: float) -> void:
	var factor := Water.bullet_drag_factor(Water.is_in_water(global_position), GameParameters.water_bullet_drag, delta)
	if factor < 1.0:
		velocity_vec *= factor


func _wrap() -> void:
	# 逻辑弹丸不读取场景树里第一个玩家的当前时间线；视觉副本仍按最近副本显示。
	if authority_world != null or prediction_only:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	# 环面世界坐标对齐：锚定至距射手或本地玩家最近的副本位置
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

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
	if hit.has_method("hurt"):
		var direction := incoming if incoming != Vector2.ZERO else velocity_vec
		var dir := direction.normalized() if not direction.is_zero_approx() else Vector2.RIGHT
		CombatFeedback.hit_marker()
		hit.hurt(direct_hit_damage, dir)


# 检测爆炸弹与玩家的接触，触发短延时引信
func _check_player_contact() -> void:
	if authority_world != null:
		if player_contact(authority_world.players.values(), PLAYER_HIT_RADIUS, true) != null:
			start_player_fuse()
		return
	var tree := get_tree()
	if tree == null:
		return
	for group in CONTACT_GROUPS:
		for n in tree.get_nodes_in_group(group):
			if n == shooter or not (n is Node2D):
				continue
			var d := MazeGenerator.toroidal_delta_px(global_position, (n as Node2D).global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < PLAYER_HIT_RADIUS:
				if authority_world != null and authority_world.is_friendly(shooter, n):
					continue
				if not apply_damage and shooter != null and shooter.team != 0 and shooter.team == n.team:
					continue
				start_player_fuse()
				return

# 启动命中玩家的短延时引信

func rewind_state() -> Dictionary:
	# 运动/引信沿用联机快照；补齐单人重建实例所需的开火参数。
	return motion_state().merged({"max_range": max_range, "gravity_factor": gravity_factor,
		"speed": speed, "size": size, "color": bullet_color,
		"hit_damage": hit_damage, "hit_impact": hit_impact})


# 应用时间回溯状态快照
func apply_rewind_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	type_id = d["type_id"]
	max_range = d["max_range"]
	gravity_factor = d["gravity_factor"]
	speed = d["speed"]
	size = d["size"]
	scale = Vector2(size, size)
	bullet_color = d["color"]
	hit_damage = d["hit_damage"]
	hit_impact = d["hit_impact"]
	var sp2 := get_node_or_null("Sprite2D") as Sprite2D
	if sp2 != null:
		sp2.modulate = bullet_color
	restore_motion(d)


# 启动引信倒计时

func _explode() -> void:
	exploded = true
	if not apply_damage:
		return
	var started := Time.get_ticks_usec()
	if authority_world == null:
		present_explosion(get_viewport(), global_position, explosion_visual, explosion_radius)
	Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback, shooter, entity_id)
	if authority_world != null:
		authority_world.broadcast(NetEvent.Kind.EXPLOSION, {"id": entity_id, "type_id": type_id,
				"pos": global_position, "tick": authority_world._snap_tick})
	GameLog.record("explosion", {"id": entity_id, "type": type_id, "position": global_position,
			"damage": apply_damage, "visual": authority_world == null and explosion_visual != null,
			"shooter": entity_id >> 48, "duration_ms": (Time.get_ticks_usec() - started) / 1000.0})

static func present_explosion(viewport: Viewport, pos: Vector2, visual: PackedScene, radius: float) -> void:
	if visual != null:
		var fx: Node2D = visual.instantiate()
		fx.position = pos
		viewport.add_child(fx)
	TileHitFx.spawn_explosion(viewport, pos, radius)
