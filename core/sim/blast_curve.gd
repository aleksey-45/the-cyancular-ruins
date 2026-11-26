class_name BlastCurve
extends RefCounted

# 角色与地形共用爆炸衰减曲线。内圈取最大值，外圈按归一化距离做二次衰减，在爆炸边缘降为零。
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
