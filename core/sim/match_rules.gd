class_name MatchRules
extends RefCounted

# 联机模式共用地图出生点，本类负责分配地图侧、推进回合和计分。
enum Phase { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER, WAITING }
enum State { PHASE, NUMBER, TIMER, MATCH_TIME, SPAWNS, SCORES, WINS, ROUND_WINNER, WINNER, ROSTER }
const RESPAWN_TICKS := 120

var mode := WorldSpec.DUEL
var teams: Dictionary = {}
var team_counts: Dictionary = {}
var spawns: Dictionary = {}
var phase := Phase.WAITING
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
var _rng: RandomNumberGenerator

func _init(rng: RandomNumberGenerator) -> void:
	_rng = rng

func setup(p_mode: String, roster: Array, p_teams: Dictionary, map: Dictionary, options: Dictionary) -> String:
	mode = p_mode
	_roster = roster
	teams = p_teams
	match_time = float(options.get("match_time", RoomOptions.MATCH_SECONDS))
	player_collision = options.get("player_collision", false)
	_size = map.size
	var problem := SpawnPicker.validate_multiplayer_spawns(map)
	if not problem.is_empty():
		return problem
	var sides := SpawnPicker.respawn_cells(map)
	var limit := SpawnPicker.player_limit(sides, mode, options)
	if limit == 0: return "该模式出生点不足（侧 1 / 侧 2：%d / %d）" % [sides[1].size(), sides[2].size()]
	if roster.size() < RoomOptions.MIN_PLAYERS: return "至少需要 %d 名玩家" % RoomOptions.MIN_PLAYERS
	if roster.size() > limit: return "本图在此模式下最多支持 %d 人，当前 %d 人" % [limit, roster.size()]
	_spawn_pools = {0: sides[1] + sides[2]} if mode == WorldSpec.ROYALE else sides
	if mode == WorldSpec.TEAM:
		# 开局记录两队人数。后续回合都用这份人数计算起始比分补偿。
		team_counts = TeamRules.team_counts(teams)
		assert(not team_counts.is_empty())
	_plan_round_spawns()
	_reset_scores()
	return ""

func same_team(a: int, b: int) -> bool:
	return teams.has(a) and teams[a] == teams.get(b, 0)

## 新回合清除之前的比分。人数不等时，人数较少的一队以补偿分开局。
func _reset_scores() -> void:
	scores.clear()
	if team_counts.is_empty():
		return
	for team: int in [1, 2]:
		var bonus := TeamRules.score_bonus(team, team_counts)
		if bonus > 0:
			scores[team] = bonus

func _pool_for(role: int) -> Array:
	if mode == WorldSpec.ROYALE:
		return _spawn_pools[0]
	var side: int = teams[role] if mode == WorldSpec.TEAM else role
	return _spawn_pools[side if round_number % 2 == 1 else 3 - side]

func _plan_round_spawns() -> void:
	spawns.clear()
	var taken: Array[Vector2i] = []
	var roles := _roster.duplicate()
	MathUtil.shuffle(roles, _rng)
	for role: int in roles:
		var cell := SpawnPicker.pick(_pool_for(role), taken, taken, _size, _rng)
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
		var cell := GridPathfinder.cell_of(player.position, CyrmMap.CELL_SIZE, _size.x, _size.y)
		if player_collision:
			occupied.append(cell)
		if not same_team(role, other):
			enemies.append(cell)
	return SpawnPicker.pick(_pool_for(role), occupied, enemies, _size, _rng)

func start_countdown() -> bool:
	if phase != Phase.WAITING:
		return false
	phase = Phase.COUNTDOWN
	round_timer = 3.0
	return true

func score_down(role: int, killer: int) -> int:
	var credited := 3 - role if mode == WorldSpec.DUEL else killer
	var scorer := 3 - int(teams[role]) if mode == WorldSpec.TEAM else credited
	if scorer > 0:
		scores[scorer] = int(scores.get(scorer, 0)) + 1
	return credited

func advance(delta: float) -> void:
	match phase:
		Phase.COUNTDOWN:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer == 0.0:
				phase = Phase.PLAYING
		Phase.PLAYING:
			if mode == WorldSpec.ROYALE:
				match_time = maxf(match_time - delta, 0.0)
				if match_time == 0.0:
					_finish(_royale_winner())
				return
			var limit := TeamRules.kills_to_win(teams.size()) if mode == WorldSpec.TEAM else 5
			for scorer: int in scores:
				if scores[scorer] >= limit:
					round_winner = scorer
					rounds_won[scorer] = int(rounds_won.get(scorer, 0)) + 1
					phase = Phase.ROUND_OVER
					round_timer = 4.0
					return
		Phase.ROUND_OVER:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer > 0.0:
				return
			if rounds_won[round_winner] >= 2:
				_finish(round_winner)
				return
			round_number += 1
			_plan_round_spawns()
			_reset_scores()
			phase = Phase.WAITING

func role_left(remaining_roles: Array) -> bool:
	if phase == Phase.MATCH_OVER:
		return false
	var contenders := remaining_roles
	if mode == WorldSpec.TEAM:
		_roster = remaining_roles
		var remaining_teams := {}
		for role in remaining_roles:
			remaining_teams[teams[role]] = true
		contenders = remaining_teams.keys()
	if contenders.size() >= 2:
		return false
	var remaining_winner := 0 if contenders.is_empty() else int(contenders[0])
	_finish(_royale_winner() if mode == WorldSpec.ROYALE else remaining_winner)
	return true

func _finish(winning_id: int) -> void:
	winner = winning_id
	phase = Phase.MATCH_OVER
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

func capture() -> Array:
	return [phase, round_number, round_timer, match_time, spawns.duplicate(), scores.duplicate(),
			rounds_won.duplicate(), round_winner, winner, _roster]

func restore(row: Array) -> void:
	phase = row[0]
	round_number = row[1]
	round_timer = row[2]
	match_time = row[3]
	spawns = row[4].duplicate()
	scores = row[5].duplicate()
	rounds_won = row[6].duplicate()
	round_winner = row[7]
	winner = row[8]
	_roster = row[9]
