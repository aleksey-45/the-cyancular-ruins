class_name StepJump
extends RefCounted

const SUB_PER_CELL := 4
const MAX_STEP_SUBCELLS := SUB_PER_CELL
const WALK_UP_MAX_SUBCELLS := 2


static func low_step_height(feet_sub: Vector2i, dir: int, solid_at: Callable) -> int:
	if dir == 0:
		return 0
	var ahead_x := feet_sub.x + dir
	var h := 0
	for k in MAX_STEP_SUBCELLS:
		if not bool(solid_at.call(Vector2i(ahead_x, feet_sub.y - k))):
			break
		h += 1
	if h == 0:
		return 0
	if bool(solid_at.call(Vector2i(ahead_x, feet_sub.y - MAX_STEP_SUBCELLS))):
		return -1
	return h


static func is_walk_up_step(height_subcells: int) -> bool:
	return height_subcells > 0 and height_subcells <= WALK_UP_MAX_SUBCELLS


static func jump_velocity_for_height(height_px: float, gravity: float) -> float:
	if gravity <= 0.0 or height_px <= 0.0:
		return 0.0
	return -sqrt(2.0 * gravity * height_px)
