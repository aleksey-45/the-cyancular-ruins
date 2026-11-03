class_name RoyaleSpawn
extends RefCounted

# 大乱斗的散点选格 / 复活选格:只有静态计算,不持有状态、不碰生命周期。

const SPAWN_CLEARANCE := 15      # 开局散点两两最小距离(格)
const RESPAWN_CLEARANCE := 8     # 复活点与存活敌人的最小环面距离(格)

# 回退告警只打一次(静态闩;每进程一局,足够)。
static var _warned_legacy_spawn := false


static func _grid_dims() -> Vector2i:
	return SpawnPicker.grid_dims()


static func _floor_cells() -> Array:
	return SpawnPicker.floor_cells()


static func _spawn_candidates() -> Array:
	return SpawnPicker.spawn_candidates()


static func _respawn_pools() -> Array:
	return SpawnPicker.respawn_pools()


# 大乱斗的候选 = 两侧 `# respawn` 列表的并集(无阵营 ⇒ 全图散布;不可达点在此剔除 + warning 一次)。
static func map_spawn_points() -> Array:
	var sides: Dictionary = MazeGenerator.load_spawns().get("respawns", {})
	var out: Array = []
	out.append_array(sides.get(1, []))
	out.append_array(sides.get(2, []))
	return SpawnPicker.filter_reachable(out)


static func _warn_legacy_spawn() -> void:
	if _warned_legacy_spawn:
		return
	_warned_legacy_spawn = true
	push_warning("RoyaleSpawn: 地图没有 # respawn 行 —— 散点/复活回退 SpawnPicker 几何生成;要数据驱动请用 tools/map_spawn_meta.gd 写入地图")


# 开局散点:地图 `# respawn` 两侧并集里随机取 N 个(两两尽量 ≥ SPAWN_CLEARANCE),点不够 N 人时回退任意地板格补足。
# ★ roles 必须按实际键返回:缺员降级开局时 role 不连续(如剩 {1,3}),否则 spawns[role] 缺键抛错、对局卡死。
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var d := _grid_dims()
	var points := map_spawn_points()
	var picked: Array
	if points.is_empty():
		_warn_legacy_spawn()
		picked = SpawnChooser.pick_many(_spawn_candidates().duplicate(), n, null, SPAWN_CLEARANCE, d)
	else:
		picked = SpawnChooser.pick_many(points, n, null, SPAWN_CLEARANCE, d)
	# 地图数据不够 N 人(或回退几何池也不够):回退任意地板格补足,免得塞 (-1,-1) 出生到墙角。
	# ★ 这层回退与数据层的优先级必须留在本函数里(并成一个池子 = 取消优先级,会优先选到死角格)。
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
	for i in n:
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 复活选格:池内离所有存活玩家 ≥ RESPAWN_CLEARANCE、且不是本 role 上一次出生点的格,随机取一个。
static func respawn_cell(role: int, players: Dictionary, left: Dictionary,
		last: Dictionary = {}, points: Array = []) -> Vector2i:
	var d := _grid_dims()
	var anchors: Array = []
	for other in players:
		if int(other) == int(role) or left.has(int(other)):
			continue
		var op: Node2D = players[other]
		if op.is_downed():
			continue
		anchors.append(Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
				int(op.global_position.y) / GameParameters.TILE_SIZE))
	var exclude: Array = []
	if last.has(int(role)):
		exclude.append(last[int(role)])
	var pools: Array = [points] if not points.is_empty() else _respawn_pools()
	for pool: Array in pools:
		var far: Array = []
		for c in pool:
			if exclude.has(c):
				continue
			var ok := true
			for a in anchors:
				if MazeGenerator.toroidal_dist(c, a, d.x, d.y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				far.append(c)
		if not far.is_empty():
			return SpawnChooser.pick(far, [], null)
	for pool: Array in pools:
		var cell := SpawnChooser.pick(pool, exclude, null, RESPAWN_CLEARANCE, anchors, d)
		if cell.x >= 0:
			return cell
	return Vector2i(-1, -1)
