class_name MatchWorld
extends RefCounted

enum Command { START, SUICIDE, LEAVE, RESTART }
enum EnemyView { POS, VEL, SLOT, FRAMES, SCALE, ACTIVITY, FACING, GROUNDED, HP, DOWNED,
	HIT_LEFT, ACTIVE, ELITE, BLACK_BIRD, LUNGE, BOUNDS }

const Phase := MatchRules.Phase

var spec: WorldSpec
var combat: CombatSimulator
var terrain: Terrain
var players: Dictionary[int, Player]:
	get: return combat.players
var rules: MatchRules
var time: MatchTime
var personal_time: PersonalTime:
	get: return time as PersonalTime
var world_time: WorldTime:
	get: return combat.time_field
var finished: bool:
	get: return rules != null and rules.phase == Phase.MATCH_OVER
var tick := 0

func _init(config: WorldSpec) -> void:
	spec = config
	var rng := RandomNumberGenerator.new()
	rng.seed = spec.seed
	terrain = Terrain.new(spec.map)
	combat = CombatSimulator.new(terrain, rng)
	combat.team_counts = spec.team_counts
	time = spec.create_time()
	combat.time_field = time as WorldTime
	for id: int in spec.roles:
		_add_player(id)
	if spec.mode == WorldSpec.SOLO:
		_restart_level()
	else:
		rules = MatchRules.new(spec, combat, personal_time)

## 每个席位提交本帧输入。世界回溯可恢复战斗时钟，模拟帧号始终递增。
func advance(seat_inputs: Dictionary, commands: Array = []) -> void:
	if finished: return
	tick += 1
	var inputs := seat_inputs.duplicate()
	for command: Array in commands:
		match command[0]:
			Command.RESTART:
				_restart_level()
				return
			Command.START:
				rules.start_countdown()
			Command.SUICIDE:
				if rules.phase == Phase.PLAYING and players.has(command[1]):
					var player := players[command[1]]
					player.last_attacker = 0
					player.force_down()
			Command.LEAVE:
				rules.leave(command[1])
				inputs.erase(command[1])
	if rules != null:
		if finished: return
		for player: Player in players.values():
			player._controls_locked = rules.phase != Phase.PLAYING
	if time != null:
		var started := PerformanceStats.begin()
		time.advance(combat, inputs, tick)
		PerformanceStats.end(PerformanceStats.HISTORY_SAVE, started)
	combat.step(inputs)
	if personal_time != null:
		for id: int in combat.destroyed_subcells:
			personal_time.award_blocks(id, combat.destroyed_subcells[id])
	if rules != null:
		rules.settle()

func capture() -> Dictionary:
	var started := PerformanceStats.begin()
	var state := combat.capture_attacks()
	state.merge(combat.ground.capture())
	state.merge(rules.capture() if rules != null else {"rules": [], "stats": {}})
	state.merge({
		"tick": tick, "terrain": terrain.version, "combat_tick": combat.tick, "rng": combat.rng.state,
		"players": combat.capture_players(),
		"enemies": combat.capture_enemies(), "kills": combat.enemy_kills,
		"world_time": [], "accounts": {}, "histories": {},
	})
	if time != null: state.merge(time.capture(), true)
	PerformanceStats.end(PerformanceStats.WORLD_CAPTURE, started)
	return state

func restore(state: Dictionary) -> void:
	terrain.apply_at(state["terrain"], {})
	tick = state["tick"]
	combat.tick = state["combat_tick"]
	if rules != null:
		rules.restore(state)
	if time != null: time.restore(state)
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
	combat.ground.restore(state)
	combat.enemy_kills = state["kills"]
	combat.hits.clear()
	combat.destroyed_subcells.clear()
	combat.rng.state = state["rng"]

func close() -> void:
	combat.close()

func _add_player(role: int) -> void:
	var player := combat.add_player(role, spec.teams.get(role, 0), spec.options.get("player_collision", false))
	player.weapons.enabled_types = spec.weapons
	player.sim_max_hp = TeamRules.max_hp(player.team, combat.team_counts)

func time_account(role: int) -> GrainAccount:
	return time.account_for(role) if time != null else null

## 采集当前帧的表现数据。only_role 用于筛选玩家及其攻击，传入 0 时采集整个世界。
func sample(only_role := 0) -> Dictionary:
	var actors := combat.capture_players() if only_role == 0 else {only_role: players[only_role].capture_state()}
	var account := time_account(only_role)
	var view := {"tick": tick, "combat_tick": combat.tick, "players": actors,
		"pickups": combat.ground.sample() if only_role == 0 else {}, "pickup_tick": combat.ground.tick,
		"kills": combat.enemy_kills, "enemies": combat.sample_enemies(),
		"elapsed": world_time.elapsed if world_time != null else combat.tick * ActorStep.DT,
		"time_mode": world_time.mode if world_time != null else WorldTime.Mode.NONE,
		"account": account.capture_state() if account != null else []}
	view.merge(combat.sample_attacks(only_role))
	return view

func _restart_level() -> void:
	if time != null: time.reset_history(spec.roles[0])
	combat.clear()
	combat.clear_enemies()
	combat.ground.clear()
	terrain.reset()
	terrain.forget_before(terrain.version)
	var player := players[spec.roles[0]]
	player.spawn_at(spec.solo_spawn)
	player.sim_iframes = 0.0
	player.weapons.set_initial_inventory([spec.weapons[0]])
	var ids: Array = spec.map.points.keys()
	ids.sort()
	for id in ids:
		var entry: Dictionary = spec.map.points[id]
		if entry.kind == "enemy":
			combat.add_enemy(entry["type"], player, CyrmMap.world_position(entry.cell))
	combat.ground.scatter(spec.floors, spec.weapons, combat.rng)
