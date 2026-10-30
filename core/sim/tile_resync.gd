class_name TileResync
extends RefCounted

# 重连补态的子格列表(BUG-03,2026-10-30)。纯逻辑、不引 autoload / 不碰 SceneTree ⇒ `-s` 冒烟可直接驱动。
#
# 背景:`match_sync` 的 `destroyed` 只表达「64px 格与建局基线不同」;榴弹现在按 32px 块破坏(2×2 子格),
# 只灭几个子格的砖**格子本身没变** ⇒ 不在那一份里。不补这一份,重连后客户端比服务器多出这些砖的贴图与
# 碰撞(幽灵墙 ⇒ 本地预测每帧撞不存在的墙、子弹被挡、橡皮筋)。
#
# 口径:只报「所在 64px 格仍与基线相同」的死子格 —— 整格已消失的由 `destroyed_cells()` 展开 16 个子格覆盖,
# 这里再发一遍是冗余(载荷白大、客户端重复清)。顺序确定(y 升序、同 y 升序 x):载荷可复现,便于对读。

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