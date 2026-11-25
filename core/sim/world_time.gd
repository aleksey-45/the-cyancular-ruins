class_name WorldTime
extends RefCounted

enum Mode { NONE, REWIND, HASTE }

var mode := Mode.NONE
var account: GrainAccount
var elapsed := 0.0  # 玩家经历的秒数，随世界快照回溯。
var history := TimeHistory.new(TimeParams.SNAP_SECONDS)
var _elite_hits := {}
var _tick := 0
var _grain_due: Dictionary[int, int] = {}

func _init(grains: GrainAccount) -> void:
	account = grains

func schedule_grain(amount: int) -> void:
	var due := _tick + TimeParams.ELITE_GRAIN_DELAY_TICKS
	_grain_due[due] = _grain_due.get(due, 0) + amount

func step_rewards() -> void:
	_tick += 1
	if _grain_due.has(_tick):
		account.deposit(_grain_due[_tick])
		_grain_due.erase(_tick)

func advance(combat: CombatSimulator, player: Player, held: int, at: int) -> void:
	var delta := ActorStep.DT
	step_rewards()
	account.regen(delta)
	var was_reversing := is_rewinding()
	mode = Mode.NONE
	if account.can_spend():
		if held & ActorInput.BIT_HASTE:
			mode = Mode.HASTE
			account.spend(delta, TimeParams.COST_HASTE)
		elif held & ActorInput.BIT_REWIND and history.can_rewind():
			mode = Mode.REWIND
			account.spend(delta, TimeParams.COST_REWIND)
		if account.balance <= 0.0:
			mode = Mode.NONE
	if is_rewinding():
		if not was_reversing:
			_elite_hits.clear()
		rewind(combat, player)
		combat.hit_rewound_elites(_elite_hits)
	else:
		elapsed += delta * player_speed_mult()
		if not player.sim_downed:
			history.record(delta, at, _sample.bind(combat, player))
		var terrain := combat.terrain
		terrain.forget_before(history.oldest_environment().get("terrain", terrain.version))

func _sample(combat: CombatSimulator, player: Player) -> Array:
	return [player.capture_state(), combat.capture_projectiles(), {
		"tick": combat.tick, "terrain": combat.terrain.version, "elapsed": elapsed,
		"enemies": combat.capture_enemies(true), "beams": combat.beams.duplicate(),
		"blasts": combat.pending_blasts.duplicate(),
	}]

func rewind(combat: CombatSimulator, player: Player, delta := ActorStep.DT) -> void:
	mode = Mode.REWIND
	var sample := history.backward(delta)
	var environment: Dictionary = sample[TimeHistory.Sample.ENVIRONMENT]
	combat.tick = environment["tick"]
	elapsed = environment["elapsed"]
	combat.terrain.apply_at(environment["terrain"], {})
	player.rewind_state(sample[TimeHistory.Sample.ACTOR], true)
	combat.restore_projectiles(sample[TimeHistory.Sample.PROJECTILES])
	combat.beams.assign(environment["beams"])
	combat.pending_blasts.assign(environment["blasts"])
	for slot: int in environment["enemies"]:
		combat.enemies[slot].restore_state(environment["enemies"][slot])

func capture() -> Array:
	return [mode, elapsed, _tick, _grain_due.duplicate(), account.capture_state(),
			history.capture(), _elite_hits.duplicate(true)]

func restore(row: Array) -> void:
	mode = row[0]
	elapsed = row[1]
	_tick = row[2]
	_grain_due.assign(row[3])
	account.restore_state(row[4])
	history.restore(row[5])
	_elite_hits = row[6].duplicate(true)

func is_rewinding() -> bool:
	return mode == Mode.REWIND

func is_hasting() -> bool:
	return mode == Mode.HASTE

func enemy_delta(delta: float, elite: bool) -> float:
	if mode == Mode.REWIND:
		return delta if elite else 0.0
	if elite:
		return delta * player_speed_mult()
	return world_delta(delta) * (1.0 + TimeParams.LOAN_ENEMY_SPEED_BONUS * account.loan_depth())

func world_delta(delta: float) -> float:
	if mode == Mode.REWIND:
		return 0.0
	return delta * TimeParams.HASTE_WORLD if mode == Mode.HASTE else delta

func player_speed_mult() -> float:
	if mode == Mode.REWIND:
		return 0.0
	return TimeParams.HASTE_PLAYER if mode == Mode.HASTE else 1.0
