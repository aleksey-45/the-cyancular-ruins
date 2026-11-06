extends RefCounted


const CONTACT_GAP := 12.0
const MAX_LAG_S := 0.05
const BASE_CONTACT_TOL := 8.0
const MAX_CONTACT_TOL := 48.0
const CONTACT_GRACE_S := 0.15


static func grace_after(left_s: float, delta: float, contact_now: bool) -> float:
	if contact_now:
		return CONTACT_GRACE_S
	return maxf(0.0, left_s - maxf(delta, 0.0))


static func rect_gap(a: Rect2, b: Rect2) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy := maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	return sqrt(dx * dx + dy * dy)


static func ghost_horizon_s(ping_ms: int) -> float:
	var one_way := float(maxi(ping_ms, 0)) / 2000.0
	return clampf(one_way + 0.5 / 60.0, 0.0, MAX_LAG_S)


const TOL_MODEL_FACTOR := 2.0

static func contact_tol(rel_speed: float, anchor_speed: float, horizon_s: float) -> float:
	var h := clampf(horizon_s, 0.0, MAX_LAG_S)
	var drift := maxf(absf(rel_speed), absf(anchor_speed)) * h * TOL_MODEL_FACTOR
	return clampf(BASE_CONTACT_TOL + drift, BASE_CONTACT_TOL, MAX_CONTACT_TOL)


static func is_contact(gap: float) -> bool:
	return gap <= CONTACT_GAP
