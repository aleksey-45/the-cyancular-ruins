class_name CollisionAabb
extends RefCounted

# 从任意节点求「启用中的碰撞体」在世界系的几何。纯静态、不引 autoload(-s 可空跑),


# ★ `CollisionPolygon2D` 与 `CollisionShape2D` 是**并列类**(都直接继承 Node2D),不是父子 ——
static func has_any(n: Node2D) -> bool:
	for child in n.get_children():
		if child is CollisionPolygon2D:
			if not (child as CollisionPolygon2D).disabled:
				return true
		elif child is CollisionShape2D:
			if not (child as CollisionShape2D).disabled:
				return true
	return false


# 启用中碰撞体的世界 AABB(多边形顶点 / 矩形角 / 圆的外接方框)。无启用碰撞体时返回
# 以 n.global_position 为中心的 0 尺寸矩形(调用方据此用 has_any 走自己的兜底)。
static func world_rect(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		# ★ 多边形与形状**分开判**(并列类,见 has_any 的注释)。
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
