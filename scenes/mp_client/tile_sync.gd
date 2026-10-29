class_name TileSync
extends RefCounted

# 拆砖(瓦片破坏)组合件(2026-10-22 从 PvpMatchClient 拆出;Task 7):两条订阅 + 格级/子格级处理。
# 形状是**组合**不是继承:宿主 PvpMatchClient 只剩 `_subscribe_tile_events()` /
# `_on_remote_tile_destroyed()` / `_on_remote_sub_destroyed()` 三个委托口(原 `resync_world_probe` 直接调格级那个,该探针已于 2026-10-24 删除);
# 本类经 bind(client) 读宿主的 `_world`(与拆件前同一个字段、同一个对象)。
# ★ `--diag` 的事件名 `tile_cell` / `tile_sub` 逐字未改(NetDiag 判据)。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

var _client: Node = null


func bind(client: Node) -> void:
	_client = client


# ★★ 拆砖的**两条订阅必须成对**,所以收在这一处给三个子类各调一次(原先三份手抄 ⇒ 1v1 那份漏了子格那条)。
#   为什么两条都要:`local_tile_destroyed` 只由 `damage_tile`(格级/激光/测试钩子)触发,而**子弹与爆炸**
#   走 `TileDefs.damage_sub` ⇒ 线上只发 `sub_destroyed`。只接格级那条 = 服务器已经拆了、客户端墙上
#   **贴图与碰撞都还在**(幽灵墙):本地预测撞在服务器不存在的墙上 ⇒ 每帧分歧回滚(橡皮筋),视觉子弹也被挡下。
func subscribe() -> void:
	Wire.local_tile_destroyed.connect(on_cell)
	Wire.local_sub_destroyed.connect(on_sub)


func on_cell(cell: Vector2i, silent: bool = false) -> void:
	NetDiag.log_event("tile_cell", {"cell": [cell.x, cell.y], "silent": silent})
	# cyrm v4:破坏按 16px 子格算 —— 一个 64px 格被拆 = 它的 16 个子格全灭(老实现走 damage_tile 格级强拆 ⇒ 子格渲染 / 碰撞不清,客户端留幽灵墙)。
	for sy in 4:
		for sx in 4:
			on_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), silent)
	if silent or _client._world == null:
		return
	var tex := 0
	var sgrid := MazeGenerator.current_subgrid
	if not sgrid.is_empty() and cell.y * 4 < sgrid.size():
		var srow: Array = sgrid[cell.y * 4]
		if cell.x * 4 < srow.size():
			tex = int(srow[cell.x * 4])
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_client._world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)


# 单个 16px 子格被服务器摧毁:本地 HP / 渲染 / 碰撞一并清(Level0 的 on_sub_destroyed 链)。★ silent 语义与 tile 版相同(重连补态不播碎片)。
func on_sub(sub: Vector2i, silent: bool = false) -> void:
	NetDiag.log_event("tile_sub", {"sub": [sub.x, sub.y], "silent": silent, "has_world": _client._world != null})
	if _client._world == null:
		TileDefs.damage_sub(sub, 999999, "explosion")
		return
	TileDefs.damage_sub(sub, 999999, "explosion")
	if silent:
		return
	var tex := TileDefs.sub_texture(sub)
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)。
	TileHitFx.spawn(_client._world, Vector2(sub.x * 16.0 + 8.0, sub.y * 16.0 + 8.0), tex)
