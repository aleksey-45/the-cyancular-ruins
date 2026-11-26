class_name BulletBody
extends RectBody

enum AdvanceResult { MOVED, TERRAIN_HIT, ACTOR_HIT, RANGE_END, FUSE_END }
enum { MOTION_POS, MOTION_VEL, MOTION_TRAVELED, MOTION_FUSE_ELAPSED, MOTION_FUSE_DURATION, ROTATION,
		SNAP_TYPE, SNAP_OWNER, SNAP_DAMAGE, SNAP_DIRECT_HIT }

var entity_id: int
var type_id: int
var definition: Dictionary
var hit_damage: int
var hit_impact: float
var max_range: float
var gravity_factor: float
var traveled := 0.0
var fuse_elapsed := 0.0
var fuse_duration := 0.0
# 快照保存榴弹的直击记录，使预测回滚恢复后仍可判断直击是否已结算。
var direct_hit := false

var impact_point := Vector2.ZERO
var impact_normal := Vector2.ZERO
var impact_collider_id := 0

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

## 沿位移分段扫掠，每段长度不超过地图边缘的碰撞覆盖范围。
## 每段移动后将位置归入地图范围，下一段可从地图另一侧继续。
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
	return [position, velocity, traveled, fuse_elapsed, fuse_duration, transform.get_rotation()]

func capture_state() -> Array:
	var owner: int = shooter.role if shooter is Player else (shooter as EnemyBase).slot
	return motion_state() + [type_id, owner, hit_damage, direct_hit]

func restore_motion(state: Array) -> void:
	traveled = state[MOTION_TRAVELED]
	fuse_elapsed = state[MOTION_FUSE_ELAPSED]
	fuse_duration = state[MOTION_FUSE_DURATION]
	velocity = state[MOTION_VEL]
	transform = Transform2D(state[ROTATION], state[MOTION_POS])
