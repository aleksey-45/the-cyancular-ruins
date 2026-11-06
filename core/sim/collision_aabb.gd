class_name CollisionAabb
extends RefCounted



static func has_any(n: Node2D) -> bool:
	for child in n.get_children():
		if child is CollisionPolygon2D:
			if not (child as CollisionPolygon2D).disabled:
				return true
		elif child is CollisionShape2D:
			if not (child as CollisionShape2D).disabled:
				return true
	return false


static func world_rect(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		var r: Rect2
		if child is CollisionPolygon2D:
			var cp := child as CollisionPolygon2D
			if cp.disabled:
				continue
			var pts := cp.polygon
			if pts.size() == 0:
				continue
			var mn := cp.to_global(pts[0])
			var mx := mn
			for pt in pts:
				var wp := cp.to_global(pt)
				mn = mn.min(wp)
				mx = mx.max(wp)
			r = Rect2(mn, mx - mn)
		elif child is CollisionShape2D:
			var cs := child as CollisionShape2D
			if cs.disabled:
				continue
			var shape := cs.shape
			if shape == null:
				continue
			if shape is RectangleShape2D:
				var size := (shape as RectangleShape2D).size * cs.global_scale
				r = Rect2(cs.global_position - size * 0.5, size)
			elif shape is CircleShape2D:
				var rad := (shape as CircleShape2D).radius * maxf(cs.global_scale.x, cs.global_scale.y)
				r = Rect2(cs.global_position - Vector2(rad, rad), Vector2(rad, rad) * 2.0)
			else:
				continue
		else:
			continue
		rect = r if not has else rect.merge(r)
		has = true
	return rect
