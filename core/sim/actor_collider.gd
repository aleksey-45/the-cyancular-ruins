class_name ActorCollider
extends NativeActorCollider

# 身份、包围盒缓存和查询计算由原生类持有，场景继续拥有实际物理体。
func _init(player: Player, layer: int) -> void:
	initialize(player, layer)

static func queries_match(queries: Array, actor: Player) -> bool:
	return actor.native_queries_match(queries)
