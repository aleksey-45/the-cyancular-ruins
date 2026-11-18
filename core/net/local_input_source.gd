class_name LocalInputSource
extends RefCounted

static func aim_direction(origin: Vector2, facing: int, map_size: Vector2, base: Vector2,
		zoom: float, mouse_offset: Vector2) -> Vector2:
	var center := GridPathfinder.anchor_to_nearest(base, origin + Vector2(0, PlayerParams.cam_y_bias), map_size)
	var direction := center + mouse_offset / zoom - origin
	return Vector2(facing, 0.0) if direction.length_squared() < 0.0001 else direction.normalized()

const ACTIONS := [
	[&"up", ActorInput.BIT_UP],
	[&"down", ActorInput.BIT_DOWN],
	[&"charge", ActorInput.BIT_CHARGE],
	[&"attack", ActorInput.BIT_ATTACK],
	[&"R", ActorInput.BIT_RELOAD],
]

static func sample(frozen: bool) -> Array:
	var held := 0
	var pressed := 0
	var released := 0
	var axis := 0.0
	if not frozen:
		axis = Input.get_axis(&"left", &"right")
		for entry in ACTIONS:
			var action: StringName = entry[0]
			var bit: int = entry[1]
			if Input.is_action_pressed(action):
				held |= bit
			if Input.is_action_just_pressed(action):
				pressed |= bit
			if Input.is_action_just_released(action):
				released |= bit
		if Input.is_action_pressed(&"haste"):
			held |= ActorInput.BIT_HASTE
		if Input.is_action_pressed(&"rewind"):
			held |= ActorInput.BIT_REWIND
		if Input.is_action_just_pressed(&"F"):
			pressed |= ActorInput.BIT_PICKUP
	return [axis, held, pressed, released, 0, Vector2.ZERO]

static func switch_index() -> int:
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0
