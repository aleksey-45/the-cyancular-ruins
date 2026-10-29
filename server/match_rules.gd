class_name MatchRules
extends RefCounted

var mode := PvpSession.MODE_PVP
var teams: Dictionary = {}
var spawns: Dictionary = {}
var swapped: Dictionary = {}
var match_time := 300.0
var hud_time := 0.0
var winner := 0

func setup(p_mode: String, roster: Array, p_teams: Dictionary, options: Dictionary) -> void:
	mode = p_mode
	teams = p_teams
	match_time = float(options.get("match_time", 300.0))
	if mode == PvpSession.MODE_TEAM:
		spawns = plan_team_spawns(teams)
		swapped = compute_swap_spawns(spawns, teams)
	elif mode == PvpSession.MODE_ROYALE:
		var dims := SpawnPicker.grid_dims()
		var points := GridPathfinder.spread_cells(SpawnPicker.spawn_candidates(), roster.size(), 15, dims.x, dims.y)
		for i in roster.size():
			spawns[roster[i]] = points[i]
	else:
		var points := MazeGenerator.current_spawns
		var a: Vector2i = points["player"]
		var b: Vector2i = points.get("player2", Vector2i(-1, -1))
		if b.x < 0:
			b = SpawnPicker.far_spawn_from(a, TileDefs.terrain.get_grid_snapshot())
		spawns = {1: a, 2: b}
		swapped = {1: b, 2: a}

func same_team(a: int, b: int) -> bool:
	return teams.has(a) and teams[a] == teams.get(b, 0)

func spawn_for(world: Node, role: int, initial: bool = false) -> Vector2i:
	if initial or mode == PvpSession.MODE_PVP:
		return spawns[role]
	var dims := SpawnPicker.grid_dims()
	var best := spawns[role] as Vector2i
	var best_distance := -1
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for cell: Vector2i in cells:
			var distance := 1000000
			for other in world.players:
				var player: Node2D = world.players[other]
				if other == role or same_team(role, other) or player.is_downed():
					continue
				distance = mini(distance, GridPathfinder.toroidal_dist(cell, Vector2i(player.position / GameParameters.TILE_SIZE), dims.x, dims.y))
			if distance > best_distance:
				best = cell
				best_distance = distance
			if distance >= 8:
				return cell
	return best

func tick(world: Node, delta: float) -> void:
	if world._round_state == NetEvent.RoundState.MATCH_OVER:
		return
	for role in world.players:
		var player: Node2D = world.players[role]
		if not player.is_downed() or world._round_state != NetEvent.RoundState.PLAYING:
			continue
		if player.respawn_tick > 0:
			continue
		player.respawn_tick = world._snap_tick + 120
		world._drop_all_but_one(player, role)
		var killer: int = world.killer_for(player)
		var scorer := killer
		if mode == PvpSession.MODE_PVP:
			killer = 3 - int(role)
			scorer = killer
		elif mode == PvpSession.MODE_TEAM:
			scorer = 3 - int(teams[role])
		world._record_down(role, killer)
		if scorer > 0:
			world._scores[scorer] = int(world._scores.get(scorer, 0)) + 1
		world.broadcast(NetEvent.Kind.KILL, [killer, role])
		if mode == PvpSession.MODE_PVP and not world.players[killer].is_downed():
			world.respawn(killer, false)
		world.broadcast_round()
	match world._round_state:
		NetEvent.RoundState.COUNTDOWN:
			world._round_timer -= delta
			if world._round_timer <= 0.0:
				world._round_state = NetEvent.RoundState.PLAYING
				if world._options.get("round_full_heal", false):
					for role in world.players:
						var player: Node2D = world.players[role]
						player.apply_authoritative_state(player.max_hp, player.max_waterproof, false)
				world.broadcast_round()
		NetEvent.RoundState.PLAYING:
			for role in world.players:
				var player: Node2D = world.players[role]
				if player.respawn_tick > 0 and world._snap_tick >= player.respawn_tick:
					world.respawn(role)
			if mode == PvpSession.MODE_ROYALE:
				match_time -= delta
				hud_time -= delta
				if hud_time <= 0.0:
					hud_time = 1.0
					world.broadcast_round()
				if match_time <= 0.0:
					finish(world)
			else:
				var limit := 9 if mode == PvpSession.MODE_TEAM else 5
				for scorer in world._scores:
					if world._scores[scorer] >= limit:
						world._last_round_winner = scorer
						world._rounds_won[scorer] = int(world._rounds_won.get(scorer, 0)) + 1
						world._round_state = NetEvent.RoundState.ROUND_OVER
						world._round_timer = 4.0
						world.broadcast_round()
						break
		NetEvent.RoundState.ROUND_OVER:
			world._round_timer -= delta
			if world._round_timer <= 0.0:
				for scorer in world._rounds_won:
					if world._rounds_won[scorer] >= 2:
						winner = scorer
						finish(world)
						return
				var previous := spawns
				spawns = swapped
				swapped = previous
				world.start_round()

func finish(world: Node) -> void:
	if mode == PvpSession.MODE_ROYALE:
		var best := -1
		for role in world._roster():
			var score := int(world._scores.get(role, 0))
			if score > best:
				winner = role
				best = score
			elif score == best:
				winner = 0
	world._round_state = NetEvent.RoundState.MATCH_OVER
	world.broadcast_round()

func left(world: Node, _role: int) -> void:
	if world._round_state == NetEvent.RoundState.MATCH_OVER:
		return
	if mode == PvpSession.MODE_TEAM:
		var remaining := {}
		for role in world.players:
			remaining[teams[role]] = true
		if remaining.size() < 2:
			winner = int(remaining.keys()[0]) if remaining.size() == 1 else 0
			finish(world)
	elif world.players.size() < 2:
		winner = int(world.players.keys()[0]) if world.players.size() == 1 else 0
		finish(world)

static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	var points := MazeGenerator.current_spawns
	var first: Vector2i = points["player"]
	var bases := [first, SpawnPicker.far_spawn_from(first, TileDefs.terrain.get_grid_snapshot())]
	var dims := SpawnPicker.grid_dims()
	var result := {}
	for team in [1, 2]:
		var roles := teams.keys().filter(func(role: int) -> bool: return teams[role] == team)
		roles.sort()
		var cells := GridPathfinder.spread_cells(SpawnPicker.cells_within(bases[team - 1], 6), roles.size(), 3, dims.x, dims.y)
		for i in roles.size():
			result[roles[i]] = cells[i]
	return result

static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a := teams.keys().filter(func(role: int) -> bool: return teams[role] == 1)
	var b := teams.keys().filter(func(role: int) -> bool: return teams[role] == 2)
	a.sort()
	b.sort()
	var result := {}
	for i in a.size():
		result[a[i]] = spawns[b[i]]
		result[b[i]] = spawns[a[i]]
	return result
