class_name CollisionAabb
extends RefCounted

# 计算节点内所有处于启用状态的碰撞体在世界坐标系下的轴对齐包围盒 AABB。
# 仅合并未被禁用的碰撞体（跳过 disabled 节点），避免多姿态碰撞箱重叠干扰。
# 纯静态工具类，无 Autoload 依赖。


# 检查节点下是否存在任何处于启用状态的碰撞体（支持 CollisionPolygon2D 与 CollisionShape2D）。
static func has_any(n: Node2D) -> bool:
	for child in n.get_children():
		if child is CollisionPolygon2D:
			if not (child as CollisionPolygon2D).disabled:
				return true
		elif child is CollisionShape2D:
			if not (child as CollisionShape2D).disabled:
				return true
	return false


# 计算所有启用碰撞体的合并世界 AABB。
# 若无启用碰撞体，返回以节点全局坐标为原点的零尺寸矩形。
static func world_rect(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		# 分别处理多边形碰撞体与几何形状碰撞体
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
