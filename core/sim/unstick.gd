class_name Unstick
extends RefCounted

# 「把一个压进实心格的矩形向上挤出去」的单一来源。纯静态、不引 autoload(格尺寸由参数传入,

const PROBE_INSET := 0.5   # 探测矩形四边内缩(像素)


# 返回把 rect 向上推出实心格所需的**最小位移**(≥0;0 = 没卡住)。
# max_cells 同时是迭代上限与"最多推几格"的安全阀(被推上去可能又贴到更上面的墙 --
# 那是收敛,不是死循环;上限到了就返回累计值,不崩)。
static func push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float:
	if ts <= 0:
		return 0.0
	var total := 0.0
	for _i in max_cells:
		var cur := Rect2(rect.position - Vector2(0.0, total), rect.size)
		# ★ 内缩不能省:TileQuery 的格范围是 floori(rect.end / ts) 且**含端点**,
		#   一个正好 64 宽、正好对齐格线的矩形会把右边那一列也算进去 —— 那一列若是墙,
		#   每帧都会判成"卡住"往上弹。内缩还顺带保证下面 need 恒 ≥ PROBE_INSET。
		var probe := cur.grow(-PROBE_INSET)
		if probe.size.x <= 0.0 or probe.size.y <= 0.0:
			return total
		var top := TileQuery.topmost_solid_row(probe, ts)
		if top < 0:
			return total
		# 把框底推到那一行的上边。取**最靠上**的行 → 它 ×ts 最小 → need 最大 →
		# 一步就清掉当前所有被压的行。
		var need := cur.end.y - float(top) * float(ts)
		if need <= 0.0:
			return total
		total += need
	return total
