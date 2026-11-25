class_name MathUtil
extends RefCounted

static func shuffle(items: Array, rng: RandomNumberGenerator) -> void:
	for i in range(items.size() - 1, 0, -1):
		var other := rng.randi_range(0, i)
		var item: Variant = items[i]
		items[i] = items[other]
		items[other] = item



# 以指数方式缩小当前值与目标值的差距，便于在不同时长的物理更新中保持平滑。
# rate 控制靠近的速度，值越大，每秒缩小的差距越多。
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-rate * delta))
