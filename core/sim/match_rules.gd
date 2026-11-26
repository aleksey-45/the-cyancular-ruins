class_name MatchRules
extends RefCounted

# 按对战模式分配地图出生点、推进回合和计分。
enum Phase { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER, WAITING }
enum State { PHASE, NUMBER, TIMER, MATCH_TIME, SPAWNS, SCORES, WINS, ROUND_WINNER, WINNER, ROSTER }
const RESPAWN_TICKS := 120
const ATTRIB_WINDOW_TICKS := 180

var _spec: WorldSpec
var spawns: Dictionary = {}
var phase := Phase.WAITING
var round_number := 1
var round_timer := 0.0
var match_time := float(RoomOptions.MATCH_SECONDS)
var scores: Dictionary = {}
var rounds_won: Dictionary = {}
var round_winner := 0
var winner := 0
var _roster: Array
var _spawn_pools: Dictionary
var _simulation: WeakRef
var _combat: CombatSimulator:
	get: return _simulation.get_ref()
var _time: PersonalTime
var stats := {}

func _init(spec: WorldSpec, combat: CombatSimulator, time: PersonalTime) -> void:
	_simulation = weakref(combat)
	_time = time
	_spec = spec
	_roster = spec.roles
	match_time = spec.options.get("match_time", RoomOptions.MATCH_SECONDS)
	_spawn_pools = {0: spec.sides[1] + spec.sides[2]} if spec.mode == WorldSpec.ROYALE else spec.sides
	for id: int in _roster:
		stats[id] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0, "left": false, "hits": {}}
	_open_round()

func same_team(a: int, b: int) -> bool:
	return _spec.teams.has(a) and _spec.teams[a] == _spec.teams.get(b, 0)

## 新回合清除之前的比分。人数不等时，人数较少的一队以补偿分开局。
func _reset_scores() -> void:
	scores.clear()
	for team: int in _spec.team_counts:
		var bonus := TeamRules.score_bonus(team, _spec.team_counts)
		if bonus > 0:
			scores[team] = bonus

func _pool_for(role: int) -> Array:
	if _spec.mode == WorldSpec.ROYALE:
		return _spawn_pools[0]
	var side: int = _spec.teams[role] if _spec.mode == WorldSpec.TEAM else role
	return _spawn_pools[side if round_number % 2 == 1 else 3 - side]

func _plan_round_spawns() -> void:
	spawns.clear()
	var taken: Array[Vector2i] = []
	var roles := _roster.duplicate()
	MathUtil.shuffle(roles, _combat.rng)
	for role: int in roles:
		var cell := SpawnPicker.pick(_pool_for(role), taken, taken, _spec.map.size, _combat.rng)
		spawns[role] = cell
		taken.append(cell)

func spawn_for(role: int) -> Vector2i:
	var occupied: Array[Vector2i] = []
	var enemies: Array[Vector2i] = []
	for other: int in _combat.players:
		var player := _combat.players[other]
		if other == role or player.sim_downed:
			continue
		var cell := ToroidalGrid.cell_of(player.position, CyrmMap.CELL_SIZE, _spec.map.size.x, _spec.map.size.y)
		if _spec.options.get("player_collision", false):
			occupied.append(cell)
		if not same_team(role, other):
			enemies.append(cell)
	return SpawnPicker.pick(_pool_for(role), occupied, enemies, _spec.map.size, _combat.rng)

func start_countdown() -> void:
	phase = Phase.COUNTDOWN
	round_timer = 3.0

func score_down(role: int, killer: int) -> int:
	var credited := 3 - role if _spec.mode == WorldSpec.DUEL else killer
	var scorer := 3 - int(_spec.teams[role]) if _spec.mode == WorldSpec.TEAM else credited
	if scorer > 0:
		scores[scorer] = int(scores.get(scorer, 0)) + 1
	return credited

func settle() -> void:
	for hit: Array in _combat.hits:
		_credit_hit(hit[0], _combat.players[hit[1]], hit[2])
	if phase == Phase.PLAYING:
		_settle_downs_and_respawns()
	match phase:
		Phase.COUNTDOWN:
			round_timer = maxf(round_timer - ActorStep.DT, 0.0)
			if round_timer == 0.0:
				phase = Phase.PLAYING
				if _spec.options.get("round_full_heal", false):
					for player: Player in _combat.players.values():
						player.heal()
		Phase.PLAYING:
			if _spec.mode == WorldSpec.ROYALE:
				match_time = maxf(match_time - ActorStep.DT, 0.0)
				if match_time == 0.0:
					_finish(_royale_winner())
				return
			var limit := TeamRules.kills_to_win(_spec.teams.size()) if _spec.mode == WorldSpec.TEAM else 5
			for scorer: int in scores:
				if scores[scorer] >= limit:
					round_winner = scorer
					rounds_won[scorer] = int(rounds_won.get(scorer, 0)) + 1
					phase = Phase.ROUND_OVER
					round_timer = 4.0
					return
		Phase.ROUND_OVER:
			round_timer = maxf(round_timer - ActorStep.DT, 0.0)
			if round_timer > 0.0:
				return
			if rounds_won[round_winner] >= 2:
				_finish(round_winner)
				return
			round_number += 1
			_combat.clear()
			_combat.terrain.reset()
			_combat.ground.clear()
			_open_round()

func leave(role: int) -> void:
	stats[role]["left"] = true
	_combat.remove_player(role)
	if _time != null:
		_time.remove_role(role)
	if phase == Phase.MATCH_OVER: return
	var remaining_roles := _combat.players.keys()
	var contenders := remaining_roles
	if _spec.mode == WorldSpec.TEAM:
		_roster = remaining_roles
		var remaining_teams := {}
		for id: int in remaining_roles:
			remaining_teams[_spec.teams[id]] = true
		contenders = remaining_teams.keys()
	if contenders.size() >= 2:
		return
	var remaining_winner := 0 if contenders.is_empty() else int(contenders[0])
	_finish(_royale_winner() if _spec.mode == WorldSpec.ROYALE else remaining_winner)

func _finish(winning_id: int) -> void:
	_combat.finish_match()
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

func capture() -> Dictionary:
	return {"stats": stats.duplicate(true), "rules": [phase, round_number, round_timer, match_time, spawns.duplicate(), scores.duplicate(),
			rounds_won.duplicate(), round_winner, winner, _roster]}

func restore(state: Dictionary) -> void:
	stats = state["stats"].duplicate(true)
	var row: Array = state["rules"]
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

func _settle_downs_and_respawns() -> void:
	for role: int in _combat.players:
		var player := _combat.players[role]
		if not player.sim_downed or player.respawn_tick > 0:
			continue
		player.respawn_tick = _combat.tick + RESPAWN_TICKS
		_drop_all_but_one(player)
		var killer := score_down(role, _killer_for(player))
		_record_down(role, killer)
		if _spec.mode == WorldSpec.DUEL and not _combat.players[killer].sim_downed:
			_respawn(killer, spawn_for(killer), false)
	for role: int in _combat.players:
		var player := _combat.players[role]
		if player.respawn_tick > 0 and _combat.tick >= player.respawn_tick:
			_respawn(role, spawn_for(role))

func _respawn(role: int, cell: Vector2i, heal := true) -> void:
	if cell == SpawnPicker.NO_CELL:
		return
	var player := _combat.players[role]
	player.spawn_at(cell, heal)
	player.respawn_tick = 0
	player.last_attacker = 0
	player.rewinding = false
	stats[role]["hits"].clear()
	if _time != null:
		_time.reset_history(role)

func _credit_hit(attacker: int, victim: Player, damage: int) -> void:
	var role := victim.role
	if attacker == role:
		stats[role]["self_damage"] += damage
	elif attacker != 0:
		victim.last_attacker = attacker
		victim.last_hit_tick = _combat.tick
		stats[role]["hits"][attacker] = _combat.tick
		if same_team(attacker, role):
			stats[attacker]["team_damage"] += damage
		else:
			stats[attacker]["dealt"] += damage
			stats[role]["taken"] += damage
			if _time != null:
				_time.award_damage(attacker, damage)

func _record_down(victim: int, killer: int) -> void:
	stats[victim]["deaths"] += 1
	if killer == 0:
		return
	if same_team(killer, victim):
		stats[killer]["team_kills"] += 1
		return
	stats[killer]["kills"] += 1
	if _time != null:
		_time.award_kill(killer, victim)
	var hits: Dictionary = stats[victim]["hits"]
	for attacker: int in hits:
		if attacker != killer and same_team(attacker, killer) and _combat.tick - hits[attacker] <= ATTRIB_WINDOW_TICKS:
			stats[attacker]["assists"] += 1

func _killer_for(player: Player) -> int:
	var recent := _combat.tick - player.last_hit_tick <= ATTRIB_WINDOW_TICKS
	return player.last_attacker if recent and _combat.players.has(player.last_attacker) else 0

func _drop_all_but_one(player: Player) -> void:
	var items := player.weapons.random_keep_one(_combat.rng)
	for i in items.size():
		var angle := TAU * i / items.size()
		_combat.ground.spawn(items[i]["type"], items[i]["carried"], player.position + Vector2(0, -12),
				Vector2(cos(angle), -absf(sin(angle))) * 380, player.role)

func _open_round() -> void:
	phase = Phase.WAITING
	_plan_round_spawns()
	_reset_scores()
	for id: int in _combat.players:
		var player := _combat.players[id]
		player.weapons.set_initial_inventory([_spec.weapons[_combat.rng.randi_range(0, _spec.weapons.size() - 1)]])
		_respawn(id, spawns[id])
		player._controls_locked = true
		stats[id]["rounds"] = round_number
	_combat.ground.scatter(_spec.floors, _spec.weapons, _combat.rng)
