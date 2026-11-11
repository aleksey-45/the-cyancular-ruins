class_name TeamSpawn
extends RefCounted


const SPAWN_CLEARANCE := 15
const TEAMMATE_CLEARANCE := 3
const SPAWN_BASE_RADIUS := 30
const SPAWN_MAX_TRIES := 12
const RESPAWN_CLEARANCE := 8


static func plan_team_spawns(teams: Dictionary, last: Dictionary = {}, side_swap := false) -> Dictionary:
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if not by_team.has(t):
			_warn_legacy_spawn("role %d 的队号 %d 不在 {1,2}" % [int(role), t])
			return _plan_team_spawns_geometry(teams)
		(by_team[t] as Array).append(int(role))
	var sides := _map_sides()
	var can_use_data := (sides.get(1, []) as Array).size() >= (by_team[1] as Array).size() \
			and (sides.get(2, []) as Array).size() >= (by_team[2] as Array).size()
	if not can_use_data:
		_warn_legacy_spawn()
		return _plan_team_spawns_geometry(teams)
	var d := SpawnPicker.grid_dims()
	var out := {}
	for t in [1, 2]:
		var roles_t: Array = by_team[t]
		roles_t.sort()
		var side: int = (3 - t) if side_swap else t
		var pts: Array = sides.get(side, [])
		var picked: Array = []
		for role in roles_t:
			var exclude: Array = picked.duplicate()
			if last.has(int(role)):
				exclude.append(last[int(role)])
			var cell := SpawnChooser.pick(pts, exclude, null, TEAMMATE_CLEARANCE, picked, d)
			if cell.x < 0:
				cell = SpawnChooser.pick(pts, picked, null, TEAMMATE_CLEARANCE, picked, d)
			if cell.x < 0:
				_warn_legacy_spawn()
				return _plan_team_spawns_geometry(teams)
			picked.append(cell)
			out[int(role)] = cell
	return out


static func _map_sides() -> Dictionary:
	var raw: Dictionary = MazeGenerator.load_spawns().get("respawns", {})
	var out := {SpawnChooser.SIDE_LEFT: [], SpawnChooser.SIDE_RIGHT: []}
	for side in [SpawnChooser.SIDE_LEFT, SpawnChooser.SIDE_RIGHT]:
		out[side] = SpawnPicker.filter_reachable(raw.get(side, []))
	return out


static var _warned_legacy_spawn := false


static func _warn_legacy_spawn(why := "") -> void:
	if _warned_legacy_spawn:
		return
	_warned_legacy_spawn = true
	push_warning("TeamSpawn: 地图 # respawn 数据不足,回退 SpawnPicker 几何生成%s" % (
			"" if why.is_empty() else "(%s)" % why))


static func _plan_team_spawns_geometry(teams: Dictionary) -> Dictionary:
	var best := {}
	var best_margin := -(1 << 30)
	for _attempt in SPAWN_MAX_TRIES:
		var cand := _plan_team_spawns_once(teams)
		var margin := _spawn_margin(cand, teams)
		if margin > best_margin:
			best_margin = margin
			best = cand
		if margin > 0:
			break
	return best



static func _plan_team_spawns_once(teams: Dictionary) -> Dictionary:
	var d := SpawnPicker.grid_dims()
	var bases: Array = GridPathfinder.spread_cells(
			SpawnPicker.spawn_candidates().duplicate(), 2, SPAWN_CLEARANCE, d.x, d.y)
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if by_team.has(t):
			by_team[t].append(int(role))
	var out := {}
	for t in [1, 2]:
		(by_team[t] as Array).sort()
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out



static func _spawn_margin(spawns: Dictionary, teams: Dictionary) -> int:
	if spawns.size() < 2:
		return 1
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 1 << 30
	var roles: Array = spawns.keys()
	roles.sort()
	for i in range(roles.size()):
		for j in range(i + 1, roles.size()):
			var dist := MazeGenerator.toroidal_dist(spawns[roles[i]], spawns[roles[j]], d.x, d.y)
			if int(teams.get(roles[i], 0)) == int(teams.get(roles[j], 0)):
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	return min_cross - max_in


# 换边用的点集:两个队的点整体对调(队 A 第 i 人 ↔ 队 B 第 i 人)。★ 两队人数必须严格相等(满 6 人开局保证),否则返回空表、不换边 —— 宁可这局不换,也不要把人送到错的一侧。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a: Array = []
	var b: Array = []
	for role in teams:
		if int(teams[role]) == 1:
			a.append(int(role))
		else:
			b.append(int(role))
	a.sort()
	b.sort()
	var out := {}
	if a.is_empty() or a.size() != b.size():
		return out
	for i in range(a.size()):
		out[a[i]] = spawns.get(b[i], Vector2i(-1, -1))
		out[b[i]] = spawns.get(a[i], Vector2i(-1, -1))
	return out


static func respawn_cell(role: int, players: Dictionary, teams: Dictionary, last: Dictionary = {},
		sides: Dictionary = {}, side_swap := false) -> Vector2i:
	var t := int(teams.get(int(role), 0))
	var pts: Array = []
	if t == 1 or t == 2:
		var side: int = (3 - t) if side_swap else t
		pts = sides.get(side, [])
	if pts.is_empty():
		_warn_legacy_spawn()
		return _respawn_cell_geometry(role, players, teams)
	var d := SpawnPicker.grid_dims()
	var anchors: Array = []
	for other in players:
		if int(other) == int(role) or _same_team(teams, int(role), int(other)):
			continue
		var op: Node2D = players[other]
		if op == null or not is_instance_valid(op) or op.is_downed():
			continue
		anchors.append(Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
				int(op.global_position.y) / GameParameters.TILE_SIZE))
	var exclude: Array = []
	if last.has(int(role)):
		exclude.append(last[int(role)])
	var far: Array = []
	for c in pts:
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
	var cell := SpawnChooser.pick(pts, exclude, null, RESPAWN_CLEARANCE, anchors, d)
	if cell.x >= 0:
		return cell
	return _respawn_cell_geometry(role, players, teams)


static func _respawn_cell_geometry(role: int, players: Dictionary, teams: Dictionary) -> Vector2i:
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or _same_team(teams, role, int(other)):
					continue
				var op: Node2D = players[other]
				if op == null or not is_instance_valid(op) or op.is_downed():
					continue
				var oc := Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
						int(op.global_position.y) / GameParameters.TILE_SIZE)
				if MazeGenerator.toroidal_dist(c, oc, SpawnPicker.grid_dims().x,
						SpawnPicker.grid_dims().y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				return c
	return Vector2i(-1, -1)


static func _same_team(teams: Dictionary, a_role: int, b_role: int) -> bool:
	var a := int(teams.get(a_role, 0))
	var b := int(teams.get(b_role, 0))
	return a > 0 and a == b
