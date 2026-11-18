class_name BulletBody
extends RectBody

enum Network { TYPE, POS, VEL }

enum AdvanceResult { MOVED, TERRAIN_HIT, ACTOR_HIT, RANGE_END, FUSE_END }
# 个人回溯只恢复前五项运动状态，直击等已经结算的结果属于当前世界。
enum { MOTION_POS, MOTION_VEL, MOTION_TRAVELED, MOTION_FUSE_ELAPSED, MOTION_FUSE_DURATION,
		SNAP_TYPE, SNAP_OWNER, SNAP_DAMAGE, SNAP_LAUNCH, SNAP_DIRECT_HIT }

var entity_id: int
var type_id: int
var launch: Dictionary
var definition: Dictionary
var hit_damage: int
var hit_impact: float
var max_range: float
var gravity_factor: float
var traveled := 0.0
var fuse_elapsed := 0.0
var fuse_duration := 0.0
# 记录榴弹是否已经造成过直击伤害，供快照恢复，避免预测回滚后重复结算直接命中。
var direct_hit := false

var impact_point := Vector2.ZERO
var impact_normal := Vector2.ZERO
var impact_collider_id := 0
var rewind_hits := {}

var shooter: ActorBody

func _init(map: Terrain, id: int, type: int, source: ActorBody, pos: Vector2, vel: Vector2, damage: int) -> void:
	var spec := WeaponRegistry.projectile_definition(type)
	entity_id = id
	type_id = type
	definition = spec["projectile"]
	shooter = source
	gravity_factor = spec["gravity"]
	max_range = spec["range"]
	hit_damage = spec["damage"] if damage == -1 else damage
	hit_impact = spec["impact"]
	velocity = vel
	var mask := CollisionWorld.LAYER_TERRAIN
	if definition.has("collision_layers"):
		mask |= int(definition["collision_layers"])
	else:
		var owner := shooter as Player
		mask |= CollisionWorld.LAYER_ENEMY
		mask |= (CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B) if owner.team == 0 \
				else CollisionWorld.team_layer(3 - owner.team)
	var pose := Transform2D(vel.angle(), GridPathfinder.wrap_to_range(pos, map.map_size))
	super(map, (definition["shape"] as Vector2) * float(spec["size"]), pose, 0, mask)
	PhysicsServer2D.body_add_collision_exception(rid, shooter.rid)

func start_fuse(duration: float) -> void:
	if fuse_duration == 0.0:
		fuse_duration = duration

func bounce(normal: Vector2) -> void:
	velocity = velocity.bounce(normal) * 0.6
	if velocity != Vector2.ZERO:
		transform = Transform2D(velocity.angle(), position)

func advance_physics(delta: float) -> AdvanceResult:
	var started := PerformanceStats.begin()
	impact_collider_id = 0
	velocity = ShotRules.flight_velocity(terrain, position, velocity, gravity_factor, delta)
	if gravity_factor > 0.0 and velocity != Vector2.ZERO:
		transform = Transform2D(velocity.angle(), position)
	if fuse_duration > 0.0:
		fuse_elapsed += delta
		if fuse_elapsed >= fuse_duration:
			PerformanceStats.end(PerformanceStats.PROJECTILE_STEP, started)
			return AdvanceResult.FUSE_END
	var motion := velocity * delta
	traveled += motion.length()
	var result := _sweep(motion)
	_wrap_bounds()
	if result == AdvanceResult.MOVED and traveled >= max_range:
		result = AdvanceResult.RANGE_END
	PerformanceStats.end(PerformanceStats.PROJECTILE_STEP, started)
	return result

## 移动时分段检查弹丸的整条路径。如果路径穿过地图边缘，就从另一侧接着检查。
## 每段距离不超过地图边缘已覆盖的碰撞范围。
func _sweep(step: Vector2) -> AdvanceResult:
	var length := step.length()
	if length <= 0.0:
		return AdvanceResult.MOVED
	var chunks := maxi(1, ceili(length / CollisionWorld.SEAM_REACH))
	var run := step / float(chunks)
	for i in chunks:
		if move(run):
			return _contact(_motion)
		_wrap_bounds()
	return AdvanceResult.MOVED

func _wrap_bounds() -> void:
	var wrapped := GridPathfinder.wrap_to_range(position, terrain.map_size)
	if wrapped != position:
		position = wrapped


func _contact(result: PhysicsTestMotionResult2D) -> AdvanceResult:
	impact_point = result.get_collision_point()
	impact_normal = result.get_collision_normal()
	impact_collider_id = result.get_collider_id()
	var layer := PhysicsServer2D.body_get_collision_layer(result.get_collider_rid())
	return AdvanceResult.TERRAIN_HIT if layer & CollisionWorld.LAYER_TERRAIN else AdvanceResult.ACTOR_HIT

func impact_actor() -> ActorBody:
	return instance_from_id(impact_collider_id) as ActorBody if impact_collider_id != 0 else null

func motion_state() -> Array:
	return [position, velocity, traveled, fuse_elapsed, fuse_duration]

func capture_state() -> Array:
	var owner: int = shooter.role if shooter is Player else (shooter as EnemyBase).slot
	return motion_state() + [type_id, owner, hit_damage, launch, direct_hit]

static func with_authoritative_pose(state: Array, pos: Vector2, vel: Vector2) -> Array:
	if state[MOTION_POS] == pos and state[MOTION_VEL] == vel:
		return state
	var corrected := state.duplicate()
	corrected[MOTION_POS] = pos
	corrected[MOTION_VEL] = vel
	return corrected

func restore_motion(state: Array) -> void:
	traveled = state[MOTION_TRAVELED]
	fuse_elapsed = state[MOTION_FUSE_ELAPSED]
	fuse_duration = state[MOTION_FUSE_DURATION]
	restore_pose(state[MOTION_POS], state[MOTION_VEL])

func restore_pose(pos: Vector2, vel: Vector2) -> void:
	velocity = vel
	transform = Transform2D(vel.angle() if vel != Vector2.ZERO else transform.get_rotation(), pos)
