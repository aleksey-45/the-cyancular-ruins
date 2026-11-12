class_name BlastCurve
extends RefCounted

# 爆炸衰减的唯一实现：内圈满值，外圈按 1-t² 平缓降到 0。
# 场景玩法、原生战斗与地形扫描共用同一条曲线，内圈比例也只在下面定义一次。
const INNER_FRACTION := 0.4

static func falloff(distance: float, radius: float, inner: float, maximum: float) -> float:
	if distance < inner:
		return maximum
	if distance >= radius:
		return 0.0
	var t := (distance - inner) / (radius - inner)
	return maximum * (1.0 - t * t)

static func cover_multiplier(distance: float, radius: float, blocked: bool) -> float:
	return 0.75 if blocked and distance > radius * INNER_FRACTION else 1.0
