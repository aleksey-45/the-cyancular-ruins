class_name TileQuery
extends RefCounted

# 原生地形的批量区域查询；与角色和弹丸读取同一状态。
static func rect_overlaps_solid(rect: Rect2, ts: int) -> bool:
	return TileDefs.terrain.rect_overlaps(rect, ts, false)

static func rect_overlaps_solid_or_liquid(rect: Rect2, ts: int) -> bool:
	return TileDefs.terrain.rect_overlaps(rect, ts, true)

static func topmost_solid_row(rect: Rect2, ts: int) -> int:
	return TileDefs.terrain.topmost_solid_row(rect, ts)
