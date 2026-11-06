class_name TileSync
extends RefCounted


const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

var _state: ClientState = null
var _ports: ClientPorts = null


func bind(state: ClientState, ports: ClientPorts) -> void:
	_state = state
	_ports = ports


func subscribe() -> void:
	NetBus.local_tile_destroyed.connect(_rpc_on_cell)
	NetBusExt.local_sub_destroyed.connect(_rpc_on_sub)


func _rpc_on_cell(cell: Vector2i, seq: int) -> void:
	_apply_cell(cell, seq, false)


func _rpc_on_sub(sub: Vector2i, seq: int) -> void:
	_apply_sub(sub, seq, false)


func on_cell(cell: Vector2i, silent: bool = false) -> void:
	_apply_cell(cell, 0, silent)


func on_sub(sub: Vector2i, silent: bool = false) -> void:
	_apply_sub(sub, 0, silent)


func _apply_cell(cell: Vector2i, seq: int, silent: bool) -> void:
	NetDiag.log_event("tile_cell", {"cell": [cell.x, cell.y], "silent": silent, "seq": seq})
	for sy in 4:
		for sx in 4:
			NetDiag.log_event("tile_sub", {"sub": [cell.x * 4 + sx, cell.y * 4 + sy], "silent": true,
					"has_world": _state._world != null, "seq": seq})
	var mutate := func() -> void:
		for sy in 4:
			for sx in 4:
				TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 999999, "explosion")
	_apply_event(seq, mutate)
	if silent or _state._world == null:
		return
	var tex := 0
	var sgrid := MazeGenerator.current_subgrid
	if not sgrid.is_empty() and cell.y * 4 < sgrid.size():
		var srow: Array = sgrid[cell.y * 4]
		if cell.x * 4 < srow.size():
			tex = int(srow[cell.x * 4])
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_state._world,
			_fx_pos(Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)), tex)


func _apply_sub(sub: Vector2i, seq: int, silent: bool) -> void:
	NetDiag.log_event("tile_sub", {"sub": [sub.x, sub.y], "silent": silent,
			"has_world": _state._world != null, "seq": seq})
	var destroyed := [false]
	var mutate := func() -> void:
		destroyed[0] = TileDefs.damage_sub(sub, 999999, "explosion")
	_apply_event(seq, mutate)
	if _state._world == null:
		return
	if silent or not destroyed[0]:
		return
	var tex := TileDefs.sub_texture(sub)
	var at := _fx_pos(Vector2(sub.x * 16.0 + 8.0, sub.y * 16.0 + 8.0))
	if TileHitFx.consume_hit_near(at):
		return
	TileHitFx.spawn(_state._world, at, tex)


func _apply_event(seq: int, mutate: Callable) -> void:
	if seq > 0:
		var rb = _state._rollback
		if rb != null and rb.has_method("apply_external_event") \
				and int(rb.apply_external_event(seq, mutate)) == PredictionRollback.EventApply.APPLIED:
			return
	mutate.call()


# 协议/事件里的坐标是 canonical(服务器系);表现层必须先锚到本地玩家附近的副本再画。
# 锚点 = 本地玩家;拿不到(单机/桩)时原样返回(单机只有一个副本,行为不变)。
func _fx_pos(at: Vector2) -> Vector2:
	var local := _local_node()
	if local == null:
		return at
	return MazeGenerator.anchor_to_nearest(at, local.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func _local_node() -> Node2D:
	if _state == null:
		return null
	var n = _state._local
	if n is Node2D and is_instance_valid(n):
		return n as Node2D
	return null
