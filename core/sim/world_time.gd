class_name WorldTime
extends MatchTime

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")

enum Mode { NONE, REWIND, HASTE }

var mode := Mode.NONE
var account := GrainAccount.new()
var _role: int
var elapsed := 0.0  # 关卡时钟（秒），随世界回溯恢复。
var history := TimeHistory.new(TCFG.SNAP_SECONDS)
var _elite_hits := {}
var _tick := 0
var _grain_due: Dictionary[int, int] = {}

func _init(controlling_role: int) -> void:
	_role = controlling_role

func account_for(_seat: int) -> GrainAccount:
	return account

func reset_history(_seat: int) -> void:
	mode = Mode.NONE
	history = TimeHistory.new(TCFG.SNAP_SECONDS)

func schedule_grain(amount: int) -> void:
	var due := _tick + TCFG.ELITE_GRAIN_DELAY_TICKS
	_grain_due[due] = _grain_due.get(due, 0) + amount

func step_rewards() -> void:
	_tick += 1
	if _grain_due.has(_tick):
		account.deposit(_grain_due[_tick])
		_grain_due.erase(_tick)

func advance(combat: CombatSimulator, inputs: Dictionary, at: int) -> void:
	var player := combat.players[_role]
	var held: int = inputs[_role][ActorInput.HELD]
	var delta := ActorStep.DT
	step_rewards()
	account.regen(delta)
	var was_reversing := is_rewinding()
	mode = Mode.NONE
	if account.can_spend():
		if held & ActorInput.BIT_HASTE:
			mode = Mode.HASTE
			account.spend(delta, TCFG.COST_HASTE)
		elif held & ActorInput.BIT_REWIND and history.can_rewind():
			mode = Mode.REWIND
			account.spend(delta, TCFG.COST_REWIND)
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
	return [player.capture_state(), combat.sample_attacks(), {
		"tick": combat.tick, "terrain": combat.terrain.version, "elapsed": elapsed,
		"enemies": combat.capture_enemies(true),
	}]

func rewind(combat: CombatSimulator, player: Player, delta := ActorStep.DT) -> void:
	mode = Mode.REWIND
	var sample := history.backward(delta)
	var environment: Dictionary = sample[TimeHistory.Sample.ENVIRONMENT]
	combat.tick = environment["tick"]
	elapsed = environment["elapsed"]
	combat.terrain.apply_at(environment["terrain"], {})
	player.rewind_state(sample[TimeHistory.Sample.ACTOR], true)
	# 仍在行动的精英敌人继续使用递减的弹丸序号。
	combat.restore_attacks(sample[TimeHistory.Sample.ATTACKS], false)
	for slot: int in environment["enemies"]:
		combat.enemies[slot].restore_state(environment["enemies"][slot])

func capture() -> Dictionary:
	return {"world_time": [mode, elapsed, _tick, _grain_due.duplicate(), account.capture_state(),
			history.capture(), _elite_hits.duplicate(true)]}

func restore(state: Dictionary) -> void:
	var row: Array = state["world_time"]
	mode = row[0]
	elapsed = row[1]
	_tick = row[2]
	_grain_due.assign(row[3])
	account.restore_state(row[4])
	history.restore(row[5])
	_elite_hits = row[6].duplicate(true)

func is_rewinding() -> bool:
	return mode == Mode.REWIND

func enemy_delta(delta: float, elite: bool) -> float:
	if mode == Mode.REWIND:
		return delta if elite else 0.0
	if elite:
		return delta * player_speed_mult()
	return world_delta(delta) * (1.0 + TCFG.LOAN_ENEMY_SPEED_BONUS * account.loan_depth())

func world_delta(delta: float) -> float:
	if mode == Mode.REWIND:
		return 0.0
	return delta * TCFG.HASTE_WORLD if mode == Mode.HASTE else delta

func player_speed_mult() -> float:
	if mode == Mode.REWIND:
		return 0.0
	return TCFG.HASTE_PLAYER if mode == Mode.HASTE else 1.0
