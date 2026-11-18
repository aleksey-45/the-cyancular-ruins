class_name ActorBody
extends ServerBody

enum Contact { BODY, NORMAL, POINT, COLLIDER_ID }
var motion_contacts: Array[Array] = []
var _match: WeakRef
var combat: CombatSimulator:
	get: return _match.get_ref()
var time_field: TimeField:
	get: return combat.time_field
var scale: Vector2:
	get: return transform.get_scale()
var collision_layer: int:
	get: return PhysicsServer2D.body_get_collision_layer(rid)
	set(value): PhysicsServer2D.body_set_collision_layer(rid, value)
var collision_mask: int:
	get: return PhysicsServer2D.body_get_collision_mask(rid)
	set(value): PhysicsServer2D.body_set_collision_mask(rid, value)

func _init(match_sim: CombatSimulator, at: Vector2, size: float, shape: Shape2D, layer: int, mask: int) -> void:
	_match = weakref(match_sim)
	super(match_sim.terrain, Transform2D(0.0, Vector2.ONE * size, 0.0, at), shape, layer, mask)
	PhysicsServer2D.body_attach_object_instance_id(rid, get_instance_id())

func _record_contact(hit: PhysicsTestMotionResult2D) -> void:
	motion_contacts.append([hit.get_collider_rid(), hit.get_collision_normal(),
			hit.get_collision_point(), hit.get_collider_id()])
