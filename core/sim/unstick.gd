class_name Unstick
extends RefCounted

# 「把一个压进实心格的矩形向上挤出去」的单一来源。纯静态、不引 autoload(格尺寸由参数传入,

const PROBE_INSET := 0.5


static func push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float:
	if ts <= 0:
		return 0.0
	var total := 0.0
	for _i in max_cells:
		var cur := Rect2(rect.position - Vector2(0.0, total), rect.size)
		var probe := cur.grow(-PROBE_INSET)
		if probe.size.x <= 0.0 or probe.size.y <= 0.0:
			return total
		var top := TileQuery.topmost_solid_row(probe, ts)
		if top < 0:
			return total
		var need := cur.end.y - float(top) * float(ts)
		if need <= 0.0:
			return total
		total += need
	return total
