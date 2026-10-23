class_name RoyaleSpawn
extends RefCounted

# 大乱斗的散点选格 / 复活选格(纯搬移自 RoyaleHost,行为零变化):只有静态计算,不持有状态、不碰生命周期。
# ★ 与 3v3 那份(TeamSpawn)的实质差异:复活点判「离**所有存活玩家**远」(全员互敌)而不是「离敌人远」,且池子按远档取。
# ★ 出生点的权威那份(_round_spawns)仍住 RoyaleHost:_spawned_once 那次性副作用与「广播给客户端的是同一份」都在宿主里。

const SPAWN_CLEARANCE := 15      # 开局散点两两最小距离(格)
const RESPAWN_CLEARANCE := 8     # 复活点与存活敌人的最小环面距离(格)


static func _grid_dims() -> Vector2i:
	return SpawnPicker.grid_dims()


static func _tdist(a: Vector2i, b: Vector2i) -> int:
	var d := _grid_dims()
	return MazeGenerator.toroidal_dist(a, b, d.x, d.y)

static func _floor_cells() -> Array:
	return SpawnPicker.floor_cells()


static func _floor_cells_has(c: Vector2i) -> bool:
	return SpawnPicker.floor_cells_has(c)


static func _region_sizes() -> Dictionary:
	return SpawnPicker.region_sizes()


static func _roomy_floor(c: Vector2i) -> bool:
	return SpawnPicker.roomy_floor(c)


static func _spawn_candidates() -> Array:
	return SpawnPicker.spawn_candidates()



static func _respawn_pools() -> Array:
	return SpawnPicker.respawn_pools()


# 开局散点:洗牌后贪心取两两环面距离 ≥ SPAWN_CLEARANCE 的 N 个格,不够就放宽(全量补齐)。★ roles 必须按实际键返回:缺员降级开局时 role 不连续(如剩 {1,3}),否则 spawns[role] 缺键抛错、对局卡死。
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var d := _grid_dims()
# 散点几何已抽到 GridPathfinder.spread_cells(单机铺地面武器共用同一份实现)。★ 它内部有 shuffle() ⇒ 本函数的既有纪律不变:不得在广播之后再调一次。
	var picked: Array = GridPathfinder.spread_cells(
		_spawn_candidates().duplicate(), n, SPAWN_CLEARANCE, d.x, d.y)
# 候选不够散点(极小图/密封图):回退任意地板格补足,免得塞 (-1,-1) 出生到墙角。★ 这层回退与候选层的优先级必须留在本函数里
# (并成一个池子 = 取消优先级,会优先选到死角格)。★ 今天不可达:spread_cells 恒返回 min(n, 池大小),故可达 ⟺ 首档池 < 人数(两图池 122/59 对人数上限 8)。⚠ 零守卫:spawn_pool_smoke ⑦ 已删(2026-10-09)。
	if picked.size() < n:
		var rest: Array = _floor_cells().duplicate()
		for c in picked:
			rest.erase(c)
		rest.shuffle()
		for c in rest:
			if picked.size() >= n:
				break
			picked.append(c)
	var out := {}
	for i in range(n):
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 复活选格:优选开阔格中离所有存活玩家 ≥ RESPAWN_CLEARANCE 的随机格。★ 池子序列只读 SpawnPicker.respawn_pools():
# 原第二档是全部地板格,干净池筛空时会把人的复活点放进孤立单格区。★ 已移出对局的 role(_left)不参与「存活」判定 ——
# 他们的节点可能已 queue_free(players 里已 erase),但 _left 是那一步之前的痕迹。
static func respawn_cell(role: int, players: Dictionary, left: Dictionary) -> Vector2i:
	for pool: Array in _respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		var far: Array = []
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or left.has(int(other)):
					continue
				var op: Node2D = players[other]
				if op.is_downed():
					continue
				if _tdist(c,
						Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
								int(op.global_position.y) / GameParameters.TILE_SIZE)) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				far.append(c)
		if not far.is_empty():
			return far[0]
	return Vector2i(-1, -1)
