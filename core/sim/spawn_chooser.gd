class_name SpawnChooser
extends RefCounted


const RELAX_STEP := 5

const SIDE_LEFT := 1
const SIDE_RIGHT := 2
const SIDE_EDGE_MARGIN := 10


static func side_of(cell: Vector2i, dims: Vector2i) -> int:
	if dims.x <= 0:
		return SIDE_LEFT
	return SIDE_LEFT if cell.x < dims.x / 2 else SIDE_RIGHT


static func side_offset(side: int, dims: Vector2i) -> int:
	return 0 if side == SIDE_LEFT else dims.x / 2


static func side_inside_margin(cell: Vector2i, side: int, dims: Vector2i) -> bool:
	var half := dims.x / 2
	if side == SIDE_LEFT:
		return cell.x >= SIDE_EDGE_MARGIN and cell.x < half - SIDE_EDGE_MARGIN
	return cell.x >= half + SIDE_EDGE_MARGIN and cell.x < dims.x - SIDE_EDGE_MARGIN


static func bucket_of(cell: Vector2i, side: int, dims: Vector2i) -> int:
	var half := maxi(dims.x / 2, 1)
	var rel := cell.x - side_offset(side, dims)
	var bx := clampi(int(rel * 3 / half), 0, 2)
	var by := clampi(int(cell.y * 3 / maxi(dims.y, 1)), 0, 2)
	return by * 3 + bx


static func pick(candidates: Array, exclude: Array = [], rng: RandomNumberGenerator = null,
		min_dist: int = 0, anchors: Array = [], dims: Vector2i = Vector2i.ZERO) -> Vector2i:
	if candidates.is_empty():
		return Vector2i(-1, -1)
	var usable: Array = []
	for c in candidates:
		if exclude.has(c) or anchors.has(c):
			continue
		usable.append(c)
	if usable.is_empty():
		for c in candidates:
			if not anchors.has(c):
				usable.append(c)
	if usable.is_empty():
		return Vector2i(-1, -1)
	if min_dist > 0 and not anchors.is_empty() and dims.x > 0 and dims.y > 0:
		var relaxed := min_dist
		while relaxed > 0:
			var far: Array = []
			for c in usable:
				if _far_from_all(c, anchors, relaxed, dims):
					far.append(c)
			if not far.is_empty():
				return _sample(far, rng)
			relaxed -= RELAX_STEP
	return _sample(usable, rng)


static func pick_many(candidates: Array, count: int, rng: RandomNumberGenerator = null,
		min_dist: int = 0, dims: Vector2i = Vector2i.ZERO, exclude: Array = []) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	var banned: Array = exclude.duplicate()
	while out.size() < count:
		var c := pick(candidates, banned, rng, min_dist, out, dims)
		if c.x < 0:
			break
		out.append(c)
		banned.append(c)
	return out


static func _far_from_all(c: Vector2i, anchors: Array, min_dist: int, dims: Vector2i) -> bool:
	for a in anchors:
		if GridPathfinder.toroidal_dist(c, a, dims.x, dims.y) < min_dist:
			return false
	return true


static func _sample(pool: Array, rng: RandomNumberGenerator) -> Vector2i:
	var i: int
	if rng != null:
		i = rng.randi_range(0, pool.size() - 1)
	else:
		i = randi_range(0, pool.size() - 1)
	return pool[i]
