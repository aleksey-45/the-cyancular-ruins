extends LaserWeaponBase

# 激光枪(第6槽,中型即时光束):LaserWeaponBase 的参考子类,只定义"这一发几何是什么"——
# 沿瞄准方向 BeamTrace 算反射折线。开火编排/光束视觉/命中结算/磨砖/PvP 权威门控与上报
# 全走基类。反射语义:第 1..max_bounces 次碰墙镜面反射,第 max_bounces+1 次碰墙
# 或累计 ≥ bullet_range 即消失(BeamTrace 已内置;数值在 tscn 调,max_bounces 当前 5)。
#
# 后续其他行为模式的激光武器 = 各自 extends LaserWeaponBase 的薄子类,覆写基类三缝之一
# (_emit_beam 几何 / _apply_beam_damage 命中结算 / _spawn_beam_visual+_beam_style 视觉风格)。

# 反射次数上限(第 max_bounces+1 次碰墙即吸收消失)。默认 2(需求),tscn 可调高。
# BeamTrace 常量继承自基类。
@export var max_bounces: int = 2

func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, max_bounces)
