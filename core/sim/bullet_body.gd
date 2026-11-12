class_name BulletBody
extends ServerBody

enum AdvanceResult { MOVED, TERRAIN_HIT, ACTOR_HIT, RANGE_END, FUSE_END }

const MOTION_POS: int = 0
const MOTION_VEL: int = 1
const MOTION_TRAVELED: int = 2
const MOTION_FUSE_ELAPSED: int = 3
const MOTION_FUSE_DURATION: int = 4
const MOTION_SIZE: int = 5

static var _shapes := {}

var entity_id: int
var type_id: int
var definition: Dictionary
var hit_damage: int
var hit_impact: float
var max_range: float
var gravity_factor: float
var size: float
var shape: RectangleShape2D
var traveled := 0.0
var fuse_elapsed := 0.0
var fuse_duration := 0.0
# 联机直击已结算给其他角色，标记随弹丸实例保留。
var direct_hit := false

var velocity_vec := Vector2.ZERO
var impact_point := Vector2.ZERO
var impact_normal := Vector2.ZERO
var impact_collider_id := 0
var rewind_hits := {}

var _source_id: int
var _combat: CombatSimulator

var shooter: Node:
	get: return instance_from_id(_source_id) if _source_id != 0 else null

func configure(combat: CombatSimulator, id: int, type: int, profile: Dictionary, source_id: int,
		pos: Vector2, vel: Vector2, projectile_size: float, gravity: float,
		rng: float, damage: int, force: float) -> void:
	_combat = combat
	entity_id = id
	type_id = type
	definition = profile
	_source_id = source_id
	size = projectile_size
	gravity_factor = gravity
	max_range = rng
	hit_damage = damage
	hit_impact = force
	var dimensions: Vector2 = profile["shape"]
	if not _shapes.has(dimensions):
		var rect := RectangleShape2D.new()
		rect.size = dimensions
		_shapes[dimensions] = rect
	shape = _shapes[dimensions]
	position = GridPathfinder.wrap_to_range(pos, combat.terrain.map_size)
	velocity_vec = vel
	rotation = vel.angle()
	scale = Vector2.ONE * size
	collision_mask = CollisionWorld.LAYER_TERRAIN
	if profile.has("collision_layers"):
		collision_mask |= int(profile["collision_layers"])
	else:
		var owner := shooter as ActorBody
		collision_mask |= CollisionWorld.LAYER_ENEMY
		collision_mask |= (CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B) if owner.team == 0 \
				else CollisionWorld.team_layer(3 - owner.team)

func _enter_tree() -> void:
	super()
	PhysicsServer2D.body_add_shape(_rid, shape.get_rid())
	CollisionWorld.sync_body_pose(_rid, global_transform)
	if shooter is ActorBody:
		PhysicsServer2D.body_add_collision_exception(_rid, (shooter as ActorBody).get_rid())

func _physics_process(delta: float) -> void:
	var field := _combat.time_field
	if field != null:
		if field.is_rewinding():
			return
		delta = delta * field.player_speed_mult() if shooter is Player else field.world_delta(delta)
	_combat.step_projectile(self, delta)

func start_fuse(duration: float) -> void:
	if fuse_duration == 0.0:
		fuse_duration = duration

func bounce(normal: Vector2) -> void:
	velocity_vec = velocity_vec.bounce(normal) * 0.6
	if velocity_vec != Vector2.ZERO:
		rotation = velocity_vec.angle()
	CollisionWorld.sync_body_pose(_rid, global_transform)

func advance_physics(delta: float) -> AdvanceResult:
	var started := PerformanceStats.begin()
	impact_collider_id = 0
	velocity_vec = ShotRules.flight_velocity(terrain, global_position, velocity_vec, gravity_factor, delta)
	if gravity_factor > 0.0 and velocity_vec != Vector2.ZERO:
		rotation = velocity_vec.angle()
		CollisionWorld.sync_body_pose(_rid, global_transform)
	if fuse_duration > 0.0:
		fuse_elapsed += delta
		if fuse_elapsed >= fuse_duration:
			PerformanceStats.end(PerformanceStats.PROJECTILE_STEP, started)
			return AdvanceResult.FUSE_END
	var motion := velocity_vec * delta
	traveled += motion.length()
	var result := _sweep(motion)
	_wrap_bounds()
	if result == AdvanceResult.MOVED and traveled >= max_range:
		result = AdvanceResult.RANGE_END
	PerformanceStats.end(PerformanceStats.PROJECTILE_STEP, started)
	return result

## 位移按接缝拆成不超过镜像覆盖带的有限段，每段仍由统一运动求解。
## 跨接缝的长位移若一次走完，会越过对侧空档、漏掉规范世界里的中部形状。
func _sweep(step: Vector2) -> AdvanceResult:
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
	var wrapped := GridPathfinder.wrap_to_range(global_position, terrain.map_size)
	if wrapped != global_position:
		global_position = wrapped
	CollisionWorld.sync_body_pose(_rid, global_transform)


func _contact(result: PhysicsTestMotionResult2D) -> AdvanceResult:
	impact_point = result.get_collision_point()
	impact_normal = result.get_collision_normal()
	impact_collider_id = result.get_collider_id()
	var layer := PhysicsServer2D.body_get_collision_layer(result.get_collider_rid())
	return AdvanceResult.TERRAIN_HIT if layer & CollisionWorld.LAYER_TERRAIN else AdvanceResult.ACTOR_HIT

func impact_node() -> Node2D:
	return instance_from_id(impact_collider_id) as Node2D if impact_collider_id != 0 else null

func motion_state() -> Array:
	var state: Array = []
	append_motion_state(state)
	return state

func append_motion_state(state: Array) -> void:
	var start := state.size()
	state.resize(start + MOTION_SIZE)
	state[start + MOTION_POS] = position
	state[start + MOTION_VEL] = velocity_vec
	state[start + MOTION_TRAVELED] = traveled
	state[start + MOTION_FUSE_ELAPSED] = fuse_elapsed
	state[start + MOTION_FUSE_DURATION] = fuse_duration

func restore_motion(state: Array, start: int = 0) -> void:
	position = state[start + MOTION_POS]
	velocity_vec = state[start + MOTION_VEL]
	if velocity_vec != Vector2.ZERO:
		rotation = velocity_vec.angle()
	traveled = state[start + MOTION_TRAVELED]
	fuse_elapsed = state[start + MOTION_FUSE_ELAPSED]
	fuse_duration = state[start + MOTION_FUSE_DURATION]
	CollisionWorld.sync_body_pose(_rid, global_transform)
