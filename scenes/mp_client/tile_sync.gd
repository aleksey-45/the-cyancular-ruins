class_name TileSync
extends RefCounted

# 拆砖(瓦片破坏)组合件(2026-10-22 从 PvpMatchClient 拆出;Task 7):两条订阅 + 格级/子格级处理。
# 形状是**组合**不是继承:宿主 PvpMatchClient 只剩 `_subscribe_tile_events()` /
# `_on_remote_tile_destroyed()` / `_on_remote_sub_destroyed()` 三个委托口(原 `resync_world_probe` 直接调格级那个,该探针已于 2026-10-24 删除);
# 本类经 bind(client) 读宿主的 `_world`(与拆件前同一个字段、同一个对象)与 `_local`。
# ★ `--diag` 的事件名 `tile_cell` / `tile_sub` 逐字未改(NetDiag 判据)。
#
# ★ 表现层两条纪律(2026-10-26 粒子修复,原缺陷见 docs/eng/registered-debt.md):
#   ① 服务器事件带的是 **canonical** 坐标([0,MAP));玩家每帧被 wrap 回 canonical、墙体按 3×3 环面副本铺
#      ⇒ 粒子必须先 anchor_to_nearest 到本地玩家附近再画,否则接缝附近直接画到另一份副本/屏幕外。
#   ② 一次"格级销毁"只播 **1 簇**粒子:16 个子格的清理一律 silent,由格级那一簇统一负责(旧实现 17 簇)。
#
# ★★ 2026-11-01(R2):拆砖是**服务器外部事件**,必须按 seq 锚点注入预测历史,不能"到达即改地形"。
#   到达即改 ⇒ 回滚重放时地形已经是"拆完之后"的,而客户端当初预测那几帧时墙还在 ⇒ 重放结果 ≠ 原预测
#   ⇒ 在刚打穿的砖/掩体附近连环回滚(幽灵墙循环)。现在两条 RPC 都带逐 peer 的 seq(服务器用 `_stepped_seq`),
#   变更走 `PredictionRollback.apply_external_event(seq, cb)`(与受击事件同一套机制):
#   恢复 capture[seq] → 应用变更 → 重放 (seq, last_applied],并把 cb 记进事件表供之后每次重放重新应用。
#   ★ 幂等硬要求:cb 会被重放多次 ⇒ 只许调 `TileDefs.damage_sub`(已死子格返回 false),不许播粒子/发奖励。
#   ★ 无锚点(重连补态 / 探针直调 / seq=0)或注入被拒(环外 / 已 ack / 没有 rollback)⇒ **立即应用** = 旧行为。
#   变异(去掉注入、改回到达即应用)会让 `net_tile_fx_probe` 的"有预测环时应注入"断言红。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

var _client: Node = null


func bind(client: Node) -> void:
	_client = client


# ★★ 拆砖的**两条订阅必须成对**,所以收在这一处给三个子类各调一次(原先三份手抄 ⇒ 1v1 那份漏了子格那条)。
#   为什么两条都要:`local_tile_destroyed` 由 `damage_tile` 触发(激光、普通子弹的整格单位——2026-10-26 起
#   普通子弹也走格级,见 bullet_base.tile_break_unit),`sub_destroyed` 由 `damage_sub` 触发(榴弹的 1/2 格 = 32px 块爆炸
#   与子格破坏)。只接其中一条 = 服务器已经拆了、客户端墙上
#   **贴图与碰撞都还在**(幽灵墙):本地预测撞在服务器不存在的墙上 ⇒ 每帧分歧回滚(橡皮筋),视觉子弹也被挡下。
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
	# 否则格级展开的 16 次里会混进早就没了的子格,看起来像凭空爆一簇。
	# ★ 用数组当可变捕获:注入路径下 cb 会在 `apply_external_event` 里**同步**执行,这里读得到返回值;
	#   重放时 cb 再跑一遍只会把 false 写回,不产生第二次粒子(粒子在下面、cb 之外)。
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
