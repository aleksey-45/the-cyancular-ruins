class_name MatchBootstrap
extends RefCounted


const PVP_MAP := "res://maps/newfactory.cyrm"
# ★ 1v1 出生点 = 地图 meta 的 `# respawn 1|2` 列表(按半区写死的固定数据):start_on 按侧随机算好一份交给宿主,并广播同一份。


static func plan_spawns(roles: Array) -> Dictionary:
	var sides: Dictionary = MazeGenerator.load_spawns().get("respawns", {})
	var out := {}
	if sides.is_empty():
		return out
	var dims := MazeGenerator.map_size()
	var taken: Array = []
	for role in roles:
		var side := SpawnChooser.SIDE_LEFT if int(role) == 1 else SpawnChooser.SIDE_RIGHT
		var points: Array = SpawnPicker.filter_reachable(sides.get(side, []))
		if points.is_empty():
			return {}
		var cell := SpawnChooser.pick(points, taken, null, SpawnPicker.FAR_CELLS, taken, dims)
		if cell.x < 0:
			return {}
		taken.append(cell)
		out[int(role)] = cell
	return out


static func legacy_plan_spawns(roles: Array, map_path: String) -> Dictionary:
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	if s2.x < 0 and s1.x >= 0:
		s2 = SpawnPicker.far_spawn_from(s1, MapFormat.load_map_file(map_path))
		print("MatchBootstrap: 图 %s 无 player2 出生点 → role2 自动分配 %s" % [map_path, s2])
	var out := {}
	for role in roles:
		out[int(role)] = s1 if int(role) == 1 else s2
	return out


static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	SpawnPicker.reset_cache()
	var roles: Array = role_peers.keys()
	var spawns := plan_spawns(roles)
	if spawns.is_empty():
		spawns = legacy_plan_spawns(roles, map_path)
	for role in role_peers:
		var peer_id: int = role_peers[role]
		if not NetBus.is_peer_live(peer_id):
			continue
		NetBus.rpc_id(peer_id, "match_start", role, spawns.get(int(role), Vector2i(-1, -1)), map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles, {}, spawns)
	return host
