class_name WeaponPickup
extends RectBody

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

enum Network { POS, VEL, TYPE, LOCKED_ROLE, UNLOCK_TICK }
const LAYER := 8
const MASK := CollisionWorld.LAYER_TERRAIN | LAYER
const WORLD_SCALE := 2.5

var inst: int
var type_id: int
var carried: int
var locked_role := 0
var unlock_tick := 0
var _grounded := false
var _settled := false

func _init(map: Terrain, id: int, type: int, ammo: int, pos: Vector2, vel: Vector2) -> void:
	inst = id
	type_id = type
	carried = ammo
	velocity = vel
	var bounds: Rect2 = WeaponRegistry.definition(type)["pickup_bounds"]
	super(map, bounds.size * WORLD_SCALE, Transform2D(0.0, GridPathfinder.wrap_to_range(pos, map.map_size)), LAYER, MASK)

func settle_on_spawn_floor() -> void:
	var from := transform
	from.origin.y += (CyrmMap.CELL_SIZE - shape.size.y) * 0.5 - CollisionWorld.MOTION_MARGIN
	PhysicsServer2D.body_set_collision_mask(rid, CollisionWorld.LAYER_TERRAIN)
	var hit := CollisionWorld.probe_body(rid, from, Vector2.DOWN * CyrmMap.CELL_SIZE, _motion)
	PhysicsServer2D.body_set_collision_mask(rid, MASK)
	if hit and _motion.get_collision_normal().y < -0.5:
		position = GridPathfinder.wrap_to_range(from.origin + _motion.get_travel(), terrain.map_size)
		velocity = Vector2.ZERO
		_grounded = true
		_settled = true

func simulate_tick(delta: float) -> void:
	if not _settled:
		velocity.y += CFG.weapon_fall_gravity * delta
		var drag := CFG.weapon_ground_friction if _grounded else CFG.weapon_air_drag
		velocity.x *= exp(-drag * delta)
		_grounded = false
		for axis in 2:
			var travel := Vector2.ZERO
			travel[axis] = velocity[axis] * delta
			if travel[axis] == 0.0 or not move(travel) or not CollisionWorld.axis_blocked(_motion, axis, travel[axis]):
				continue
			if axis == 0 or travel.y > 0.0:
				velocity[axis] = 0.0
			if travel.y > 0.0:
				_grounded = _motion.get_collision_normal().y < -0.5
		if _grounded and absf(velocity.x) < CFG.weapon_stop_eps:
			velocity = Vector2.ZERO
			_settled = true
	# 地形或其他掉落物可能占据这块空间。找到空位后再移动物理体。
	var pose := transform
	if CollisionWorld.probe_body(rid, pose, Vector2.ZERO, null, 0.0, true):
		for i in 32:
			pose.origin.y -= CyrmMap.CELL_SIZE
			if not CollisionWorld.probe_body(rid, pose, Vector2.ZERO, null, 0.0, true):
				position = pose.origin
				velocity.y = 0.0
				_grounded = false
				_settled = false
				break
	var wrapped := GridPathfinder.wrap_to_range(position, terrain.map_size)
	if position != wrapped:
		position = wrapped
