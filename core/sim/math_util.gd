class_name MathUtil
extends RefCounted



# 以指数方式缩小当前值与目标值的差距，便于在不同时长的物理更新中保持平滑。
# rate 控制靠近的速度，值越大，每秒缩小的差距越多。
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-rate * delta))
