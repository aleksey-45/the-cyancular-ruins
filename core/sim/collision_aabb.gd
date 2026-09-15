class_name CollisionAabb
extends RefCounted

# 从任意节点求「启用中的碰撞体」在世界系的几何。纯静态、不引 autoload(-s 可空跑),
# 与 core/collision_builder.gd 同风格。
#
# ★只并**启用**的碰撞体(disabled 跳过):姿态碰撞箱(玩家蹲/站/飞、飞鸟站/飞两套)
# 运行时靠 disabled 切换,合并禁用箱会把命中框/避障框/脚底偏移撑得比实际碰撞体大一圈。
#
# 原本在 water / laser_weapon_base / enemy_fly_base 各写一遍,合并为单一来源。
# 兜底值(水 24px / 激光 18px / 鸟 40×40)是各自的调参结果,**由调用方自备**,不在这里统一。


# 该节点是否有任何启用中的碰撞体。
static func has_any(n: Node2D) -> bool:
	for child in n.get_children():
		if child is CollisionShape2D and not (child as CollisionShape2D).disabled:
			return true
	return false


# 启用中碰撞体的世界 AABB(多边形顶点 / 矩形角 / 圆的外接方框)。无启用碰撞体时返回
# 以 n.global_position 为中心的 0 尺寸矩形(调用方据此用 has_any 走自己的兜底)。
static func world_rect(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		# CollisionPolygon2D 继承自 CollisionShape2D,先判多边形,否则走 shape 分支会被跳过。
		if not (child is CollisionShape2D):
			continue
		if (child as CollisionShape2D).disabled:
			continue
		var r: Rect2
		if child is CollisionPolygon2D:
			var cp := child as CollisionPolygon2D
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
		else:
			var cs := child as CollisionShape2D
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
		rect = r if not has else rect.merge(r)
		has = true
	return rect
