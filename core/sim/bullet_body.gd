class_name BulletBody
extends ServerBody

# 弹丸物理与生命周期。弹丸是自管 RID 物理体：地形与角色接触都由
# CollisionWorld.move_body() 统一运动求解，命中归属经挂载实例反查；
# 引信、反弹、水域阻力与射程仍是 GDScript 玩法规则。

enum AdvanceResult { MOVED, BOUNCED, TERRAIN_HIT, ACTOR_HIT, RANGE_END, FUSE_END }

@export var explodes := false
@export var direct_hit_damage := 10
@export var fuse_time := 0.5
@export var hit_fuse_time := 0.1
@export var explosion_radius := 128.0
@export var explosion_damage := 35
@export var explosion_knockback := 900.0

var entity_id := 0
var type_id := 0
var hit_damage := 0
var speed := 0.0
var size := 1.0
var gravity_factor := 0.0
var max_range := 0.0
var traveled := 0.0
var hit_impact := 0.0
var _fuse_elapsed := 0.0
var _fuse_duration := 0.0
var adjudicated := false
var apply_damage := true
var prediction_only := false
var fuse_started := false
var finished := false
var exploded := false
var direct_hit := false
var _fuse_active := false
var adjudicated_pos := Vector2.ZERO
var velocity_vec := Vector2.ZERO
var impact_velocity := Vector2.ZERO
# 本 tick 命中的角色归属；0 表示命中地形或非角色实体。
var impact_role := 0
# 命中现场数据：服务器结果对象全局复用，接触时立即抄值；归属经挂载实例反查。
var impact_point := Vector2.ZERO
var impact_normal := Vector2.ZERO
var impact_collider_id := 0
# 视觉投影偏移：逻辑与物理坐标保持规范区间，渲染按最近环面副本平移。
var visual_offset := Vector2.ZERO
var shape: Shape2D = null

var _terrain: Terrain = null
var _shooter_id := 0
var _source_node_id := 0
var _world_gravity := 0.0
var _water_drag := 0.0
var _bounce_damping := 0.0


var shooter: Node:
	get:
		return null if _shooter_id == 0 else instance_from_id(_shooter_id)
	set(value):
		_shooter_id = value.get_instance_id() if value != null else 0

func _enter_tree() -> void:
	super()   # 空间挂接、层掩码提交与归属挂载
	sync_collision_shape()

# 场景载体给出弹丸形状；形状固定，进树时同步一次即可，位姿由运动路径持续写。
func sync_collision_shape() -> void:
	if not _world_space.is_valid():
		return
	var carrier := find_child("CollisionShape2D", true, false) as CollisionShape2D
	CollisionWorld.sync_body_shapes(_rid, [carrier] if carrier != null else [], global_transform)

func bind_physics(terrain: Terrain, gravity: float, drag: float, damping: float) -> void:
	_terrain = terrain
	_world_gravity = gravity
	_water_drag = drag
	_bounce_damping = damping

func get_shooter() -> Node:
	return null if _shooter_id == 0 else instance_from_id(_shooter_id)

func set_source_node(value: Node) -> void:
	_source_node_id = value.get_instance_id() if value != null else 0

func get_source_node() -> Node:
	return null if _source_node_id == 0 else instance_from_id(_source_node_id)

## 弹丸只与对手队伍的玩家、敌人和地形碰撞；射手与队友穿透由层与显式排除给出。
func bind_actor_layers(owner: ActorBody) -> void:
	if owner == null:
		return
	var mask := collision_mask | CollisionWorld.LAYER_ENEMY
	if owner.team == 1:
		mask |= CollisionWorld.LAYER_TEAM_B
	elif owner.team == 2:
		mask |= CollisionWorld.LAYER_TEAM_A
	else:
		mask |= CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B
	collision_mask = mask
	_apply_layers()
	# 射手本体（含镜像槽）加入碰撞例外，避免弹丸命中自己。
	PhysicsServer2D.body_add_collision_exception(_rid, owner.get_rid())

func start_fuse(duration: float) -> void:
	if not _fuse_active:
		_fuse_duration = duration
		fuse_started = true
	_fuse_active = true

func start_player_fuse() -> void:
	if explodes:
		start_fuse(hit_fuse_time)

func _end_step(started: int) -> void:
	PerformanceStats.end(PerformanceStats.PROJECTILE_STEP, started)

func advance_physics(delta: float) -> int:
	var started := PerformanceStats.begin()
	if _terrain == null:
		_end_step(started)
		return AdvanceResult.MOVED
	_terrain.flush_collisions()
	impact_collider_id = 0
	impact_role = 0
	if gravity_factor > 0.0:
		velocity_vec.y = float(velocity_vec.y) + _world_gravity * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
			CollisionWorld.sync_body_pose(_rid, global_transform)
	if explodes and _fuse_active:
		_fuse_elapsed += delta
		if _fuse_elapsed >= _fuse_duration:
			_end_step(started)
			return AdvanceResult.FUSE_END
	if _terrain.water(global_position):
		var factor := exp(-_water_drag * delta)
		if factor < 1.0:
			velocity_vec *= factor
	var step := velocity_vec * delta
	traveled += step.length()
	var result := _sweep(step)
	# 所有出口都回到规范坐标：可视副本只由 present_projection() 平移渲染子节点。
	_wrap_bounds()
	if result == AdvanceResult.MOVED and traveled >= max_range:
		result = AdvanceResult.RANGE_END
	_end_step(started)
	return result

## 位移按接缝拆成不超过镜像覆盖带的有限段，每段仍由统一运动求解。
## 跨接缝的长位移若一次走完，会越过对侧空档、漏掉规范世界里的中部形状。
func _sweep(step: Vector2) -> int:
	var length := step.length()
	if length <= 0.0:
		return AdvanceResult.MOVED
	var chunks := maxi(1, ceili(length / CollisionWorld.SEAM_REACH))
	var run := step / float(chunks)
	for i in chunks:
		var out := CollisionWorld.move_body(_rid, global_transform, run)
		global_position += (out[1] as PhysicsTestMotionResult2D).get_travel()
		if bool(out[0]):
			return _contact(out[1] as PhysicsTestMotionResult2D)
		_wrap_bounds()
	return AdvanceResult.MOVED

func _wrap_bounds() -> void:
	var size := _terrain.size()
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var wrapped := GridPathfinder.wrap_to_range(global_position, size.x, size.y)
	if wrapped != global_position:
		global_position = wrapped
	CollisionWorld.sync_body_pose(_rid, global_transform)

## 命中结算：先定实体归属，再决定弹跳、短引信或终止。
## 榴弹撞角色同样要留下 impact_role，否则权威端找不到直击目标。
func _contact(result: PhysicsTestMotionResult2D) -> int:
	impact_velocity = velocity_vec
	var rid := result.get_collider_rid()
	impact_point = result.get_collision_point()
	impact_normal = result.get_collision_normal()
	impact_collider_id = result.get_collider_id()
	var actor_layer := PhysicsServer2D.body_get_collision_layer(rid) & ~CollisionWorld.LAYER_TERRAIN
	var node := impact_node()
	if node is ActorBody:
		impact_role = (node as ActorBody).role
	if explodes:
		start_fuse(hit_fuse_time if actor_layer != 0 else fuse_time)
		velocity_vec = velocity_vec.bounce(result.get_collision_normal()) * _bounce_damping
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
		return AdvanceResult.BOUNCED
	velocity_vec = Vector2.ZERO
	if actor_layer == 0:
		finished = true
		return AdvanceResult.TERRAIN_HIT
	if impact_role == 0:
		finished = true
	return AdvanceResult.ACTOR_HIT

## 命中实体的挂载节点；地形等无挂载体返回 null。
func impact_node() -> Node:
	return null if impact_collider_id == 0 else instance_from_id(impact_collider_id)

static func _motion_from_dictionary(state: Dictionary) -> Dictionary:
	return {"type_id": int(state["type_id"]), "pos": state["pos"], "vel": state["vel"],
		"traveled": float(state["traveled"]), "fuse_elapsed": float(state["fuse_elapsed"]),
		"fuse_duration": float(state["fuse_duration"]), "fuse_active": bool(state["fuse_active"]),
		"direct_hit": bool(state["direct_hit"])}

func visual_center() -> Vector2:
	return global_position + visual_offset

func motion_state() -> Dictionary:
	return {"type_id": type_id, "pos": position, "vel": velocity_vec, "traveled": traveled,
		"fuse_elapsed": _fuse_elapsed, "fuse_duration": _fuse_duration,
		"fuse_active": _fuse_active, "direct_hit": direct_hit}

# 数据侧位姿写入：节点变换与服务器变换一起更新。
func _set_pose(pos: Variant, rot: Variant) -> void:
	position = pos
	rotation = rot
	if _world_space.is_valid():
		CollisionWorld.sync_body_pose(_rid, global_transform)

func restore_motion(state: Dictionary) -> void:
	var st := _motion_from_dictionary(state)
	var rot: float = st["vel"].angle() if not (st["vel"] as Vector2).is_zero_approx() else rotation
	_set_pose(st["pos"], rot)
	velocity_vec = st["vel"]
	traveled = st["traveled"]
	_fuse_active = st["fuse_active"]
	_fuse_elapsed = st["fuse_elapsed"]
	_fuse_duration = st["fuse_duration"]
	adjudicated_pos = position
	adjudicated = true
	finished = false
	exploded = false
	direct_hit = st["direct_hit"]
	fuse_started = false
	impact_role = 0
	visual_offset = Vector2.ZERO
