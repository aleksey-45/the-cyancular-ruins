extends LaserWeaponBase


@export var max_bounces: int = 2

func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, max_bounces)
