class_name TimeField
extends RefCounted

signal grain_received

enum Mode { NONE, REWIND, HASTE }

var mode := Mode.NONE
var account: GrainAccount
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
		grain_received.emit()

func update(delta: float, want_rewind: bool, want_haste: bool) -> void:
	account.regen(delta)
	mode = Mode.NONE
	if not account.can_spend():
		return
	if want_haste:
		mode = Mode.HASTE
		account.spend(delta, TimeParams.COST_HASTE)
	elif want_rewind:
		mode = Mode.REWIND
		account.spend(delta, TimeParams.COST_REWIND)
	if account.balance <= 0.0:
		mode = Mode.NONE

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
