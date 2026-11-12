class_name LocalInputSource
extends RefCounted

const ACTIONS := [
	[&"up", ActorInput.BIT_UP],
	[&"down", ActorInput.BIT_DOWN],
	[&"charge", ActorInput.BIT_CHARGE],
	[&"attack", ActorInput.BIT_ATTACK],
	[&"R", ActorInput.BIT_RELOAD],
]

static func sample(aim: Vector2, frozen: bool) -> Array:
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
	return [axis, held, pressed, released, 0, aim]

static func switch_index() -> int:
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0
