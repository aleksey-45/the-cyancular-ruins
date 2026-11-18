class_name ServerBody
extends RefCounted

var rid: RID
var terrain: Terrain
var velocity := Vector2.ZERO
var transform := Transform2D.IDENTITY:
	set(value):
		transform = value
		PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, value)
var position: Vector2:
	get: return transform.origin
	set(value): transform.origin = value

func _init(map: Terrain, pose: Transform2D, shape: Shape2D, layer: int, mask: int) -> void:
	terrain = map
	rid = CollisionWorld.create_body(layer, mask)
	PhysicsServer2D.body_add_shape(rid, shape)
	transform = pose
	PhysicsServer2D.body_set_space(rid, map.physics.world.space)

func release() -> void:
	PhysicsServer2D.free_rid(rid)
	rid = RID()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rid.is_valid():
		PhysicsServer2D.free_rid(rid)
