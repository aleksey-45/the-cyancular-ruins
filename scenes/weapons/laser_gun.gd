extends LaserWeaponBase

# 激光枪(第6槽,中型即时光束):LaserWeaponBase 的参考子类,只定义"这一发几何是什么"——

# 反射次数上限(第 max_bounces+1 次碰墙即吸收消失)。默认 2(需求),tscn 可调高。
# BeamTrace 常量继承自基类。
@export var max_bounces: int = 2

func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, max_bounces)
