class_name MatchRules
extends RefCounted

# 联机模式共用地图出生点，本类负责分配地图侧、推进回合和计分。
const RoundState = NetEvent.RoundState
const RESPAWN_TICKS := 120

var mode := PvpSession.MODE_PVP
var teams: Dictionary = {}
var team_counts: Dictionary = {}
var spawns: Dictionary = {}
var phase := RoundState.WAITING
var round_number := 1
var round_timer := 0.0
var match_time := float(RoomOptions.MATCH_SECONDS)
var player_collision := false
var scores: Dictionary = {}
var rounds_won: Dictionary = {}
var round_winner := 0
var winner := 0
var _roster: Array
var _spawn_pools: Dictionary
var _size: Vector2i

func setup(p_mode: String, roster: Array, p_teams: Dictionary, map: Dictionary, options: Dictionary) -> String:
	mode = p_mode
	_roster = roster
	teams = p_teams
	match_time = float(options.get("match_time", RoomOptions.MATCH_SECONDS))
	player_collision = options.get("player_collision", false)
	_size = map["size"]
	var problem := SpawnPicker.validate_multiplayer_spawns(map)
	if not problem.is_empty():
		return problem
	var sides: Dictionary = map["spawns"]["respawn"]
	if mode == PvpSession.MODE_ROYALE:
		var combined: Array = sides[1] + sides[2]
		if combined.size() < roster.size():
			return "大乱斗需要 %d 个不同出生点，实际 %d 个" % [roster.size(), combined.size()]
		_spawn_pools = {0: combined}
	else:
		var minimum := TeamRules.MAX_TEAM if mode == PvpSession.MODE_TEAM else 1
		for side: int in [1, 2]:
			if sides[side].size() < minimum:
				return "侧 %d 出生点不足（需要 %d 个，实际 %d 个）" % [side, minimum, sides[side].size()]
		_spawn_pools = sides
	if mode == PvpSession.MODE_TEAM:
		# 开局后固定阵容，掉线不重算补偿。
		team_counts = TeamRules.team_counts(teams)
		assert(not team_counts.is_empty())
	_plan_round_spawns()
	_reset_scores()
	return ""

func same_team(a: int, b: int) -> bool:
	return teams.has(a) and teams[a] == teams.get(b, 0)

## 单局初始比分：团队双方按人数差补贴，其他模式保持清空。
func _reset_scores() -> void:
	scores.clear()
	if team_counts.is_empty():
		return
	for team: int in [1, 2]:
		var bonus := TeamRules.score_bonus(team, team_counts)
		if bonus > 0:
			scores[team] = bonus

func _pool_for(role: int) -> Array:
	if mode == PvpSession.MODE_ROYALE:
		return _spawn_pools[0]
	var side: int = teams[role] if mode == PvpSession.MODE_TEAM else role
	return _spawn_pools[side if round_number % 2 == 1 else 3 - side]

func _plan_round_spawns() -> void:
	spawns.clear()
	var taken: Array[Vector2i] = []
	var roles := _roster.duplicate()
	roles.shuffle()
	for role: int in roles:
		var cell := SpawnPicker.pick(_pool_for(role), taken, taken, _size)
		spawns[role] = cell
		taken.append(cell)

func spawn_for(players: Dictionary, role: int, initial: bool = false) -> Vector2i:
	if initial:
		return spawns[role]
	var occupied: Array[Vector2i] = []
	var enemies: Array[Vector2i] = []
	for other: int in players:
		var player: Player = players[other]
		if other == role or player.sim_downed:
			continue
		var cell := GridPathfinder.cell_of(player.global_position, GameParameters.TILE_SIZE, _size.x, _size.y)
		if player_collision:
			occupied.append(cell)
		if not same_team(role, other):
			enemies.append(cell)
	return SpawnPicker.pick(_pool_for(role), occupied, enemies, _size)

func start_countdown() -> bool:
	if phase != RoundState.WAITING:
		return false
	phase = RoundState.COUNTDOWN
	round_timer = 3.0
	return true

func score_down(role: int, killer: int) -> int:
	var credited := 3 - role if mode == PvpSession.MODE_PVP else killer
	var scorer := 3 - int(teams[role]) if mode == PvpSession.MODE_TEAM else credited
	if scorer > 0:
		scores[scorer] = int(scores.get(scorer, 0)) + 1
	return credited

func advance(delta: float) -> void:
	match phase:
		RoundState.COUNTDOWN:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer == 0.0:
				phase = RoundState.PLAYING
		RoundState.PLAYING:
			if mode == PvpSession.MODE_ROYALE:
				match_time = maxf(match_time - delta, 0.0)
				if match_time == 0.0:
					_finish(_royale_winner())
				return
			var limit := TeamRules.kills_to_win(teams.size()) if mode == PvpSession.MODE_TEAM else 5
			for scorer: int in scores:
				if scores[scorer] >= limit:
					round_winner = scorer
					rounds_won[scorer] = int(rounds_won.get(scorer, 0)) + 1
					phase = RoundState.ROUND_OVER
					round_timer = 4.0
					return
		RoundState.ROUND_OVER:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer > 0.0:
				return
			if rounds_won[round_winner] >= 2:
				_finish(round_winner)
				return
			round_number += 1
			_plan_round_spawns()
			_reset_scores()
			phase = RoundState.WAITING

func role_left(remaining_roles: Array) -> bool:
	if phase == RoundState.MATCH_OVER:
		return false
	var contenders := remaining_roles
	if mode == PvpSession.MODE_TEAM:
		_roster = remaining_roles
		var remaining_teams := {}
		for role in remaining_roles:
			remaining_teams[teams[role]] = true
		contenders = remaining_teams.keys()
	if contenders.size() >= 2:
		return false
	var remaining_winner := 0 if contenders.is_empty() else int(contenders[0])
	_finish(_royale_winner() if mode == PvpSession.MODE_ROYALE else remaining_winner)
	return true

func _finish(winning_id: int) -> void:
	winner = winning_id
	phase = RoundState.MATCH_OVER
	round_timer = 0.0

func _royale_winner() -> int:
	var leader := 0
	var best := -1
	for role: int in _roster:
		var score := int(scores.get(role, 0))
		if score > best:
			leader = role
			best = score
		elif score == best:
			leader = 0
	return leader
