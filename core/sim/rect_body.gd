class_name RectBody
extends ServerBody

static var _motion := PhysicsTestMotionResult2D.new()
var shape: RectangleShape2D

func _init(map: Terrain, dimensions: Vector2, pose: Transform2D, layer: int, mask: int) -> void:
	shape = CollisionWorld.rectangle(dimensions)
	super(map, pose, shape, layer, mask)

func move(motion: Vector2) -> bool:
	var hit := CollisionWorld.probe_body(rid, transform, motion, _motion)
	position += _motion.get_travel()
	return hit
