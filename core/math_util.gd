class_name MathUtil
extends RefCounted

# 通用数学助手。纯静态、无实例状态、不引 autoload:可被任何场景/工具直接调用,
# 也能在 `-s` 冒烟阶段安全引用(同 core/collision_builder.gd / core/water.gd 的风格)。


# 指数缓动:朝目标值逼近。rate 越大越跟手;
# 起步快后渐缓、松键带滑行、转身平滑穿过 0,避免线性 move_toward 的生硬。
# 原本在 enemy_base / player / swim_component 各抄一份(逐字相同),此处收为单一来源。
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
