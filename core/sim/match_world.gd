class_name MatchWorld
extends RefCounted

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")

enum Command { START, SUICIDE, LEAVE, RESTART }
enum EnemyView { POS, VEL, SLOT, FRAMES, SCALE, ACTIVITY, FACING, GROUNDED, HP, DOWNED,
	HIT_LEFT, ACTIVE, ELITE, BLACK_BIRD, LUNGE, BOUNDS }

const Actor := preload("res://core/sim/player_state_schema.gd")
const Phase := MatchRules.Phase
const ATTRIB_WINDOW_TICKS := 180

var spec: WorldSpec
var problem: String
var combat: CombatSimulator
var terrain: Terrain
var players: Dictionary[int, Player]:
	get: return combat.players
var rules: MatchRules
var personal_time: PersonalTime
var world_time: WorldTime
var tick := 0
var _stats: Dictionary = {}
var _floors: Array[Vector2i]

static func create(config: WorldSpec) -> MatchWorld:
	var world := MatchWorld.new()
	world.spec = config
	world.problem = world._build()
	return world

func _build() -> String:
	if spec.weapons.is_empty():
		return "请至少启用一种武器"
	var rng := RandomNumberGenerator.new()
	rng.seed = spec.seed
	if spec.mode != WorldSpec.SOLO:
		rules = MatchRules.new(rng)
		var failure := rules.setup(spec.mode, spec.roles, spec.teams, spec.map, spec.options)
		if not failure.is_empty():
			return failure
	terrain = Terrain.new(spec.map)
	combat = CombatSimulator.new(terrain, spec.seed)
	combat.rng = rng
	_floors = SpawnPicker.floor_cells(spec.map)
	if rules == null:
		world_time = WorldTime.new(GrainAccount.new())
		combat.time_field = world_time
		_add_player(1)
		_restart_solo()
	else:
		combat.team_counts = rules.team_counts
		if spec.options.get("beta", false):
			personal_time = PersonalTime.new(spec.options["time"], spec.roles)
		for role: int in spec.roles:
			var player := _add_player(role)
			player.spawn_at(rules.spawns[role])
			player._controls_locked = true
			_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
					"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
		_scatter_weapons()
	return ""

## 单人世界回溯会恢复战斗时钟和历史状态，模拟帧号继续递增。
func advance(inputs: Dictionary, commands: Array = []) -> void:
	if rules != null and rules.phase == Phase.MATCH_OVER:
		return
	tick += 1
	if world_time != null:
		if _step_solo_time(inputs, commands):
			return
	else:
		_commit_commands(inputs, commands)
		if rules.phase == Phase.MATCH_OVER:
			return
		var playing := rules.phase == Phase.PLAYING
		for player: Player in players.values():
			player._controls_locked = not playing
		if personal_time != null:
			var started := PerformanceStats.begin()
			personal_time.advance(combat, inputs, tick)
			PerformanceStats.end(PerformanceStats.HISTORY_SAVE, started)
	combat.hits.clear()
	combat.step(inputs)
	if rules != null:
		for hit: Array in combat.hits:
			_credit_hit(hit[0], players[hit[1]], hit[2])
		if personal_time != null:
			for role: int in combat.destroyed_subcells:
				personal_time.award_blocks(role, combat.destroyed_subcells[role])
		if rules.phase == Phase.PLAYING:
			_settle_downs_and_respawns()
		_advance_round()

func capture() -> Dictionary:
	var started := PerformanceStats.begin()
	var state := combat.capture_attacks()
	state.merge({
		"tick": tick, "terrain": terrain.version, "combat_tick": combat.tick, "rng": combat.rng.state,
		"players": combat.capture_players(),
		"pickups": combat.ground.capture(), "pickup_tick": combat.ground.tick, "pickup_next": combat.ground._next_id,
		"enemies": combat.capture_enemies(), "kills": combat.enemy_kills,
		"rules": rules.capture() if rules != null else [], "stats": _stats.duplicate(true),
		"accounts": personal_time.state_payload() if personal_time != null else {},
		"histories": personal_time.capture_histories() if personal_time != null else {},
		"world_time": world_time.capture() if world_time != null else [],
	})
	PerformanceStats.end(PerformanceStats.WORLD_CAPTURE, started)
	return state

func restore(state: Dictionary) -> void:
	terrain.apply_at(state["terrain"], {})
	tick = state["tick"]
	combat.tick = state["combat_tick"]
	_stats = state["stats"].duplicate(true)
	if rules != null:
		rules.restore(state["rules"])
	if personal_time != null:
		personal_time.restore(state["accounts"], state["histories"])
	if world_time != null:
		world_time.restore(state["world_time"])
	var actors: Dictionary = state["players"]
	for role: int in players.keys():
		if not actors.has(role):
			combat.remove_player(role)
	var roles := actors.keys()
	roles.sort()
	var ordered: Dictionary[int, Player] = {}
	for role: int in roles:
		if not players.has(role):
			_add_player(role)
		players[role].restore_state(actors[role])
		ordered[role] = players[role]
	combat.players = ordered
	for slot: int in state["enemies"]:
		combat.enemies[slot].restore_state(state["enemies"][slot])
	combat.restore_attacks(state)
	combat.ground.restore(state["pickups"], state["pickup_tick"], state["pickup_next"])
	combat.enemy_kills = state["kills"]
	combat.hits.clear()
	combat.destroyed_subcells.clear()
	combat.rng.state = state["rng"]

func close() -> void:
	combat.close()

func _add_player(role: int) -> Player:
	var player := combat.add_player(role, spec.teams.get(role, 0), spec.options.get("player_collision", false))
	player.weapons.enabled_types = spec.weapons
	player.sim_max_hp = TeamRules.max_hp(player.team, combat.team_counts)
	return player

## 采集当前帧的表现数据。only_role 用于筛选玩家及其攻击，传入 0 时采集整个世界。
func sample(only_role := 0) -> Dictionary:
	var actors := combat.capture_players() if only_role == 0 else {only_role: players[only_role].capture_state()}
	var enemies := []
	for enemy: EnemyBase in combat.enemies:
		enemies.append([enemy.position, enemy.velocity, enemy.slot, enemy.kind.frames, enemy.scale,
			enemy.activity, -1 if enemy.facing_left else 1, enemy._grounded, enemy.hp, enemy.is_dead,
			maxf(enemy.hit_reaction_left, enemy.corpse_left), enemy.active, enemy.kind.elite,
			enemy is EnemyBlackBird, EnemyJumpBird.DASH_TIMEOUT - enemy._dash_timer if enemy is EnemyJumpBird else 0.0,
			enemy.collision_rect()])
	var account: GrainAccount
	if world_time != null:
		account = world_time.account
	elif personal_time != null and only_role != 0:
		account = personal_time.accounts[only_role]
	var view := {"tick": tick, "combat_tick": combat.tick, "players": actors,
		"pickups": combat.ground.capture() if only_role == 0 else {}, "pickup_tick": combat.ground.tick,
		"kills": combat.enemy_kills, "enemies": enemies,
		"elapsed": world_time.elapsed if world_time != null else combat.tick * ActorStep.DT,
		"time_mode": world_time.mode if world_time != null else WorldTime.Mode.NONE,
		"account": account.capture_state() if account != null else []}
	view.merge(combat.sample_attacks(only_role))
	return view

func _step_solo_time(inputs: Dictionary, commands: Array) -> bool:
	for command: Array in commands:
		if command[0] == Command.RESTART:
			_restart_solo()
			return true
	var started := PerformanceStats.begin()
	world_time.advance(combat, players[1], inputs[1][ActorInput.HELD], tick)
	PerformanceStats.end(PerformanceStats.HISTORY_SAVE, started)
	return false

func _restart_solo() -> void:
	world_time.mode = WorldTime.Mode.NONE
	world_time.history = TimeHistory.new(TCFG.SNAP_SECONDS)
	combat.clear()
	combat.clear_enemies()
	combat.ground.clear()
	terrain.reset()
	terrain.forget_before(terrain.version)
	var player := players[1]
	player.spawn_at(spec.solo_spawn)
	player.sim_iframes = 0.0
	player.weapons.set_initial_inventory([spec.weapons[0]])
	var ids: Array = spec.map.points.keys()
	ids.sort()
	for id in ids:
		var entry: Dictionary = spec.map.points[id]
		if entry.kind == "enemy":
			combat.add_enemy(entry["type"], player, CyrmMap.world_position(entry.cell))
	combat.ground.scatter(_floors, spec.weapons, combat.rng)

func _commit_commands(inputs: Dictionary, commands: Array) -> void:
	for command: Array in commands:
		match command[0]:
			Command.START:
				rules.start_countdown()
			Command.SUICIDE:
				if rules.phase == Phase.PLAYING and players.has(command[1]):
					var player := players[command[1]]
					player.last_attacker = 0
					player.force_down()
			Command.LEAVE:
				_remove_role(command[1])
				inputs.erase(command[1])

func _advance_round() -> void:
	var previous := rules.phase
	rules.advance(ActorStep.DT)
	if previous == rules.phase:
		return
	match rules.phase:
		Phase.WAITING:
			combat.clear()
			terrain.reset()
			combat.ground.clear()
			_scatter_weapons()
			for role: int in players:
				_respawn(role, true, true)
				_stats[role]["rounds"] = rules.round_number
		Phase.PLAYING:
			if spec.options.get("round_full_heal", false):
				for player: Player in players.values():
					player.apply_authoritative_state(player.sim_max_hp, player.max_waterproof, false)
		Phase.MATCH_OVER:
			combat.finish_match()

func _settle_downs_and_respawns() -> void:
	for role: int in players:
		var player := players[role]
		if not player.sim_downed or player.respawn_tick > 0:
			continue
		player.respawn_tick = combat.tick + MatchRules.RESPAWN_TICKS
		_drop_all_but_one(player)
		var killer := rules.score_down(role, killer_for(player))
		_record_down(role, killer)
		if spec.mode == WorldSpec.DUEL and not players[killer].sim_downed:
			_respawn(killer, false)
	for role: int in players:
		var player := players[role]
		if player.respawn_tick > 0 and combat.tick >= player.respawn_tick:
			_respawn(role)

func _respawn(role: int, heal := true, initial := false) -> void:
	var cell := rules.spawn_for(players, role, initial)
	if cell == SpawnPicker.NO_CELL:
		return
	var player := players[role]
	player.spawn_at(cell, heal)
	player.respawn_tick = 0
	player.last_attacker = 0
	player.rewinding = false
	_stats[role]["hits"].clear()
	if personal_time != null:
		personal_time.reset_history(role)

func _remove_role(role: int) -> void:
	_stats[role]["left"] = true
	combat.remove_player(role)
	if personal_time != null:
		personal_time.remove_role(role)
	if rules.role_left(players.keys()):
		combat.finish_match()

func _credit_hit(attacker: int, victim: Player, damage: int) -> void:
	var role := victim.role
	if attacker == role:
		_stats[role]["self_damage"] += damage
	elif attacker != 0:
		victim.last_attacker = attacker
		victim.last_hit_tick = combat.tick
		_stats[role]["hits"][attacker] = combat.tick
		if rules.same_team(attacker, role):
			_stats[attacker]["team_damage"] += damage
		else:
			_stats[attacker]["dealt"] += damage
			_stats[role]["taken"] += damage
			if personal_time != null:
				personal_time.award_damage(attacker, role, damage)

func _record_down(victim: int, killer: int) -> void:
	_stats[victim]["deaths"] += 1
	if killer == 0:
		return
	if rules.same_team(killer, victim):
		_stats[killer]["team_kills"] += 1
		return
	_stats[killer]["kills"] += 1
	if personal_time != null:
		personal_time.award_kill(killer, victim)
	var hits: Dictionary = _stats[victim]["hits"]
	for attacker: int in hits:
		if attacker != killer and rules.same_team(attacker, killer) and combat.tick - hits[attacker] <= ATTRIB_WINDOW_TICKS:
			_stats[attacker]["assists"] += 1

func killer_for(player: Player) -> int:
	var recent := combat.tick - player.last_hit_tick <= ATTRIB_WINDOW_TICKS
	return player.last_attacker if recent and players.has(player.last_attacker) else 0

func _drop_all_but_one(player: Player) -> void:
	var items := player.weapons.random_keep_one(combat.rng)
	for i in items.size():
		var angle := TAU * i / items.size()
		combat.ground.spawn(items[i]["type"], items[i]["carried"], player.position + Vector2(0, -12),
				Vector2(cos(angle), -absf(sin(angle))) * 380, player.role)

func _scatter_weapons() -> void:
	for player: Player in players.values():
		player.weapons.set_initial_inventory([spec.weapons[combat.rng.randi_range(0, spec.weapons.size() - 1)]])
	combat.ground.scatter(_floors, spec.weapons, combat.rng)
