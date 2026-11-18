class_name BlastCurve
extends RefCounted

# 爆炸范围内圈使用最大值。内圈以外，效果随距离的平方减弱，到爆炸边缘时降为零。角色和地形共用这一计算。
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
