class_name TileSync
extends RefCounted

# 拆砖(瓦片破坏)组合件(2026-10-22 从 PvpMatchClient 拆出;Task 7):两条订阅 + 格级/子格级处理。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

var _client: Node = null


func bind(client: Node) -> void:
	_client = client


# ★★ 拆砖的**两条订阅必须成对**,所以收在这一处给三个子类各调一次(原先三份手抄 ⇒ 1v1 那份漏了子格那条)。
func subscribe() -> void:
	NetBus.local_tile_destroyed.connect(_rpc_on_cell)
	NetBusExt.local_sub_destroyed.connect(_rpc_on_sub)


# ── RPC 入口:带服务器给**本客户端**的 seq 锚点 ⇒ 注入预测历史 ──
func _rpc_on_cell(cell: Vector2i, seq: int) -> void:
	_apply_cell(cell, seq, false)


func _rpc_on_sub(sub: Vector2i, seq: int) -> void:
	_apply_sub(sub, seq, false)


# ── 无锚点入口(重连补态 / 探针直调 / 本地事件):seq=0 ⇒ 立即应用(= 2026-11-01 之前的语义) ──
func on_cell(cell: Vector2i, silent: bool = false) -> void:
	_apply_cell(cell, 0, silent)


func on_sub(sub: Vector2i, silent: bool = false) -> void:
	_apply_sub(sub, 0, silent)


func _apply_cell(cell: Vector2i, seq: int, silent: bool) -> void:
	NetDiag.log_event("tile_cell", {"cell": [cell.x, cell.y], "silent": silent, "seq": seq})
	# ★ 这 16 次**一律 silent**:只清本地状态、不播粒子。粒子由下面格级那一簇统一负责 ——
	#   旧实现把 silent 原样透传 = 16 簇子格粒子 + 1 簇格级 = 17 簇/170 粒子(激光一发清一格,每发都炸屏)。
	for sy in 4:
		for sx in 4:
			NetDiag.log_event("tile_sub", {"sub": [cell.x * 4 + sx, cell.y * 4 + sy], "silent": true,
					"has_world": _client._world != null, "seq": seq})
	# cyrm v4:破坏按 16px 子格算 —— 一个 64px 格被拆 = 它的 16 个子格全灭。
	var mutate := func() -> void:
		for sy in 4:
			for sx in 4:
				TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 999999, "explosion")
	_apply_event(seq, mutate)
	if silent or _client._world == null:
		return
	var tex := 0
	var sgrid := MazeGenerator.current_subgrid
	if not sgrid.is_empty() and cell.y * 4 < sgrid.size():
		var srow: Array = sgrid[cell.y * 4]
		if cell.x * 4 < srow.size():
			tex = int(srow[cell.x * 4])
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_client._world,
			_fx_pos(Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)), tex)


# 单个 16px 子格被服务器摧毁:本地 HP / 渲染 / 碰撞一并清(Level0 的 on_sub_destroyed 链)。★ silent 语义与 tile 版相同(重连补态不播碎片)。
func _apply_sub(sub: Vector2i, seq: int, silent: bool) -> void:
	NetDiag.log_event("tile_sub", {"sub": [sub.x, sub.y], "silent": silent,
			"has_world": _client._world != null, "seq": seq})
	# 返回值 = 这次调用真的"拆掉了一个活子格"。false(本来就不可破 / 已死 / 迟到或重复事件)不播粒子 ——
	var destroyed := [false]
	var mutate := func() -> void:
		destroyed[0] = TileDefs.damage_sub(sub, 999999, "explosion")
	_apply_event(seq, mutate)
	if _client._world == null:
		return
	if silent or not destroyed[0]:
		return
	var tex := TileDefs.sub_texture(sub)
	var at := _fx_pos(Vector2(sub.x * 16.0 + 8.0, sub.y * 16.0 + 8.0))
	# 同一块砖本端刚播过即时命中碎片(本地/视觉子弹、激光、爆炸)⇒ 破坏事件不再叠一份(致死一击去重)。
	if TileHitFx.consume_hit_near(at):
		return
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)。
	TileHitFx.spawn(_client._world, at, tex)


# 变更走预测环(2026-11-01 R2):`apply_external_event(seq, cb)` = 恢复 capture[seq] → 应用 → 重放 (seq, last],
# 并把 cb 记进事件表 ⇒ 之后任何一次回滚重放都会在同一个 seq 重新应用它。
# ★ 拒绝(seq 环外 / 已被 ack / 序错 / 没有 rollback)⇒ **立即应用** = 旧行为,不报错、不告警。
func _apply_event(seq: int, mutate: Callable) -> void:
	if seq > 0:
		var rb = _client.get("_rollback")
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
	if _client == null:
		return null
	var n = _client.get("_local")
	if n is Node2D and is_instance_valid(n):
		return n as Node2D
	return null
