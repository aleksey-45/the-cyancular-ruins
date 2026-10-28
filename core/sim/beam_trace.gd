extends RefCounted

# 光束网格追踪和反射由地形执行，脚本只消费折线及接触结果。
static func trace(origin: Vector2, direction: Vector2, max_len: float, max_bounces: int) -> Dictionary:
	return TileDefs.terrain.trace_beam(origin, direction, max_len, max_bounces)
