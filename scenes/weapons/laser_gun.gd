extends LaserWeaponBase

# 激光枪（第 6 槽位，中型即时命中光束武器）：LaserWeaponBase 的标准实现类，主要负责定义光束几何轨迹：
# 沿瞄准方向调用 BeamTrace 计算反射折线。开火调度、光束视觉渲染、命中结算、地形破坏以及网络同步逻辑统一由基类处理。
# 反射逻辑：前 max_bounces 次碰墙发生镜面反射，第 (max_bounces + 1) 次碰墙或累计达到射程上限后光束终止。
#
# 扩展说明：后续其他激光武器可继承 LaserWeaponBase 并按需重写基类核心虚方法：
# - _emit_beam：光束几何轨迹计算
# - _apply_beam_damage：命中伤害结算
# - _spawn_beam_visual / _beam_style：视觉渲染风格

# 反射次数上限（第 max_bounces + 1 次碰墙即吸收消失）。默认 2 次，可在场景实例中调整。
# BeamTrace 对应常量继承自基类。
@export var max_bounces: int = 2

func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, max_bounces)
