extends RefCounted


const HURT_MARGIN: float = 0.0
const FALLBACK_HALF: float = 18.0

static func rect_of(node: Node2D) -> Rect2:
	if node == null:
		return Rect2()
	if CollisionAabb.has_any(node):
		return CollisionAabb.world_rect(node)
	var half := Vector2(FALLBACK_HALF, FALLBACK_HALF)
	return Rect2(node.global_position - half, half * 2.0)

static func hurt_rect_of(node: Node2D) -> Rect2:
	var r := rect_of(node)
	return r if is_zero_approx(HURT_MARGIN) else r.grow(HURT_MARGIN)

static func hurtable(node: Node) -> bool:
	if node == null:
		return false
	if node.has_method("is_hurtable"):
		return bool(node.call("is_hurtable"))
	var co := node as CollisionObject2D
	return co == null or co.collision_layer != 0

static func rect_at(rect: Rect2, anchor: Vector2, w: float, h: float) -> Rect2:
	var c := rect.get_center()
	var off := Vector2.ZERO
	if w > 0.0:
		off.x = w * roundf((anchor.x - c.x) / w)
	if h > 0.0:
		off.y = h * roundf((anchor.y - c.y) / h)
	return Rect2(rect.position + off, rect.size)

static func sweep_may_hit(a: Vector2, b: Vector2, rect: Rect2, torus_w: float = 0.0, torus_h: float = 0.0,
		grow: Vector2 = Vector2.ZERO) -> bool:
	var r := rect_at(rect, a, torus_w, torus_h)
	if not grow.is_zero_approx():
		r = Rect2(r.position - grow, r.size + grow * 2.0)
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	return lo.x <= r.end.x and hi.x >= r.position.x and lo.y <= r.end.y and hi.y >= r.position.y

static func segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2, torus_w: float = 0.0, torus_h: float = 0.0,
		grow: Vector2 = Vector2.ZERO) -> float:
	var r := rect_at(rect, a, torus_w, torus_h)
	if not grow.is_zero_approx():
		r = Rect2(r.position - grow, r.size + grow * 2.0)
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		if absf(d[axis]) < 1e-9:
			if a[axis] < r.position[axis] or a[axis] > r.end[axis]:
				return -1.0
			continue
		var inv := 1.0 / d[axis]
		var ta := (r.position[axis] - a[axis]) * inv
		var tb := (r.end[axis] - a[axis]) * inv
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return -1.0
	return t0

static func candidate_hits(a: Vector2, b: Vector2, rect: Rect2, w: float, h: float,
		grow: Vector2, exact_only: bool = false) -> bool:
	if not exact_only and not sweep_may_hit(a, b, rect, w, h, grow):
		return false
	return segment_hits_rect(a, b, rect, w, h, grow) >= 0.0

static func segment_entry_point(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	var t := segment_hits_rect(a, b, rect)
	return Vector2(INF, 0.0) if t < 0.0 else a + (b - a) * t

static func distance_px_to_rect(p: Vector2, rect: Rect2) -> float:
	var dx := maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0)
	var dy := maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)

static func distance_px_to_rect_at(p: Vector2, rect: Rect2, anchor: Vector2, w: float, h: float) -> float:
	return distance_px_to_rect(p, rect_at(rect, anchor, w, h))

static func first_hit(a: Vector2, b: Vector2, rects: Array[Rect2], anchor: Vector2, w: float, h: float) -> Dictionary:
	var best_t := INF
	var best_i := -1
	for i in rects.size():
		var t := segment_hits_rect(a, b, rects[i], w, h)
		if t >= 0.0 and t < best_t:
			best_t = t
			best_i = i
	if best_i < 0:
		return {}
	return {"t": best_t, "index": best_i}
