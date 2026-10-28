class_name ActorCollider
extends NativeActorCollider

# 身份、包围盒缓存和查询计算由原生类持有，场景继续拥有实际物理体。
func _init(player: Player, layer: int) -> void:
	initialize(player, layer)

static func obstacles(actor: Player, mask: int) -> Array[Rect2]:
	return actor.native_obstacles(mask)

static func query_motion(actor: Player, bounds: Rect2, axis: int, distance: float, values: Array[Rect2]) -> float:
	var result := clip(bounds, axis, distance, values)
	if actor.track_actor_queries:
		actor.actor_queries.append([axis, bounds, distance, result, actor.collision_mask, actor.global_position])
	return result

static func overlaps(actor: Player, bounds: Rect2) -> bool:
	return actor.native_overlaps(bounds)

static func queries_match(queries: Array, actor: Player) -> bool:
	return actor.native_queries_match(queries)

static func clip(bounds: Rect2, axis: int, distance: float, values: Array[Rect2]) -> float:
	return NativeActorBody.clip_motion(bounds, axis, distance, values)
