class_name Unstick
extends RefCounted

# 地形嵌入脱困计算模块。纯静态实现，不依赖外部 Autoload 单例。
# 提供将重叠在实心瓦片内的矩形区域沿垂直方向向上平移推出的位移量计算。
# 用于地面掉落物等实体生成或瓦片重建时的防卡死处理。

const PROBE_INSET := 0.5   # 探测矩形四边内缩（像素）


# 计算将 rect 向上推出实心格所需的最小垂直位移量（返回值 >= 0，为 0 表示未卡住）。
# max_cells 为最大迭代推挤格数安全阀。
static func push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float:
	if ts <= 0:
		return 0.0
	var total := 0.0
	for _i in range(max_cells):
		var cur := Rect2(rect.position - Vector2(0.0, total), rect.size)
		# 内缩检测框边缘，避免完全贴合网格边界时误判相邻实心瓦片
		var probe := cur.grow(-PROBE_INSET)
		if probe.size.x <= 0.0 or probe.size.y <= 0.0:
			return total
		var top := TileQuery.topmost_solid_row(probe, ts)
		if top < 0:
			return total
		# 计算推至最靠上实心行上边缘所需的位移
		var need := cur.end.y - float(top) * float(ts)
		if need <= 0.0:
			return total
		total += need
	return total
