class_name TileResync
extends RefCounted

# 重连补态的子格列表(BUG-03,2026-10-30)。纯逻辑、不引 autoload / 不碰 SceneTree ⇒ `-s` 冒烟可直接驱动。

static func partial_damaged_subs(damaged: Dictionary, cur: Array, base: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for sub in damaged:
		var s: Vector2i = sub
		var cell := Vector2i(s.x / 4, s.y / 4)
		if cell.y < 0 or cell.y >= cur.size() or cell.x < 0 or cell.x >= (cur[cell.y] as Array).size():
			continue
		if cell.y >= base.size() or cell.x >= (base[cell.y] as Array).size():
			continue
		if int(cur[cell.y][cell.x]) == int(base[cell.y][cell.x]):
			out.append(s)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out