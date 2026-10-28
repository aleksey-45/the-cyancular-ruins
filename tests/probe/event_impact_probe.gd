extends "res://tests/probe/prediction_reuse_probe.gd"

func _reset_economy(initial: float, held: int = 0) -> void:
	game._rollback.combat_prediction.clear()
	game._rollback.reset(1, 0, 200, 0)
	game._rollback._clock = 200.0
	var rules := TimeRules.new()
	rules.initial = initial
	game._rollback.time_economy = TimeEconomy.new(rules, [1, 2])
	game._local.rewinding = false
	game._local.position = Vector2(3000, 500)
	game._local.velocity = Vector2.ZERO
	game._local.combat.knock_velocity = Vector2.ZERO
	game._local.apply_authoritative_state(100, game._local.max_waterproof, false)
	game._local.set_controls_locked(false)
	game._local.pvp_haste_mult = 1.0
	game._pending_replay = ""
	game._pending_replay_tick = 0
	game._pending_replay_last_tick = 0
	game._authority_state = {}
	game._future_state = {}
	game._terrain.reset_prediction(200)
	game._rollback._prepare_colliders()
	game._rollback._remember_state()
	PvpSession.beta_mode = true
	game._apply_authority(_frame(200))
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0, "held": held}, true))

func _reward(serial: int, tick: int, amount: int, role: int = 1, phase: int = 0) -> Dictionary:
	return {"serial": serial, "tick": tick, "role": role, "phase": phase, "amount": amount}

func _deliver(reward: Dictionary) -> void:
	game._on_event(1, NetEvent.Kind.TIME_REWARD, reward)
	game._apply_pending_authority()

func _force_replay(frame: Dictionary) -> void:
	for role in frame["time"]: game._rollback.time_economy.restore_account(role, frame["time"][role])
	game._rollback.reconcile(frame["own"], frame["tick"], 0, false, frame["world"]["projectiles"])

func _expect_full_replay_equivalence(frame: Dictionary) -> void:
	var actors: Array = game._local.capture_prediction_state()
	var accounts := game._rollback.time_economy.state_payload()
	var projectiles := game._rollback.combat_prediction.snapshot_projectiles()
	var terrain := TileDefs.sub_hp.duplicate()
	var time_history := {}
	for at in game._rollback._states:
		if at >= frame["tick"]: time_history[at] = game._rollback._states[at]["time"].duplicate(true)
	_force_replay(frame)
	assert(game._local.capture_prediction_state() == actors and game._rollback.time_economy.state_payload() == accounts,
			"account patch or dependency suffix must match complete authoritative actor/account replay")
	assert(game._rollback.combat_prediction.snapshot_projectiles() == projectiles and TileDefs.sub_hp == terrain)
	for at in time_history:
		assert(game._rollback._states[at]["time"] == time_history[at], "every corrected account checkpoint must match full replay")

func _check_reward_kept() -> void:
	for held in [0, PacketInputSource.BIT_HASTE]:
		_reset_economy(1000, held)
		var frame := _frame(200)
		_advance(6)
		var actor: Array = game._local.capture_prediction_state()
		var applications: int = game._authority_applications
		var collision := TileDefs.collision_revision
		var geometry := CollisionBuilder.geometry_revision
		var clock := game._rollback._clock
		_deliver(_reward(1, 202, 20))
		assert(game._authority_applications == applications and game._pending_replay.is_empty(),
				"a new reward must be checked before queuing world replay")
		assert(game._local.capture_prediction_state() == actor and game._rollback._clock == clock
				and TileDefs.collision_revision == collision and CollisionBuilder.geometry_revision == geometry)
		assert(game._rollback.last_effect_review["reason"] == "kept")
		_expect_full_replay_equivalence(frame)
		applications = game._authority_applications
		var account := game._rollback.time_economy.state_payload()
		_deliver(_reward(1, 202, 20))
		assert(game._authority_applications == applications and game._rollback.time_economy.state_payload() == account,
				"a duplicate reward must neither replay nor deposit twice")

func _check_first_behavior_change() -> void:
	_reset_economy(0, PacketInputSource.BIT_HASTE)
	var frame := _frame(200)
	_advance(6)
	_deliver(_reward(1, 202, 10))
	assert(game._rollback.last_effect_review["reason"] == "haste" and game._rollback.last_effect_review["invalid_from"] == 203)
	assert(game._rollback.diagnostics["checkpoint_tick"] == 202 and game._rollback.diagnostics["replay_ticks"] == 4,
			"an end-of-tick reward changes behavior on the next tick; retain the earlier account-only prefix")
	_expect_full_replay_equivalence(frame)
	# 奖励已经到达，但透支锁要在后续回复后才解除：首个行为差异不等于奖励 tick。
	_reset_economy(0, PacketInputSource.BIT_HASTE)
	var account: GrainAccount = game._rollback.time_economy.accounts[1]
	account.short_used = account.window
	account.loan_used = 2.0
	account.locked = true
	game._rollback._remember_state()
	frame = _frame(200)
	_advance(6)
	_deliver(_reward(1, 201, 10))
	assert(game._rollback.last_effect_review["invalid_from"] == 204 and game._rollback.diagnostics["checkpoint_tick"] == 203)
	_expect_full_replay_equivalence(frame)

func _check_phase_and_caps() -> void:
	_reset_economy(1750)
	var frame := _frame(200)
	game._rollback.combat_prediction.receive_reward(_reward(20, 204, 30))
	_advance(6)
	var applications: int = game._authority_applications
	# 晚到的更早收入必须重算上限裁剪，不能只对当前余额加一个差值。
	_deliver(_reward(10, 202, 40))
	assert(game._authority_applications == applications and game._rollback.time_economy.accounts[1].balance == 1800)
	_expect_full_replay_equivalence(frame)
	_reset_economy(1000)
	frame = _frame(200)
	_advance(6)
	applications = game._authority_applications
	game._on_event(1, NetEvent.Kind.TIME_REWARD, _reward(2, 203, 7, 2, 1))
	game._on_event(1, NetEvent.Kind.TIME_REWARD, _reward(1, 202, 9, 1, -1))
	game._apply_pending_authority()
	assert(game._authority_applications == applications and game._rollback.time_economy.accounts[1].balance == 1009
			and game._rollback.time_economy.accounts[2].balance == 1000,
			"remote rewards must not advance a second predicted account")
	_expect_full_replay_equivalence(frame)
	# 改写同一 serial 的时间/金额：历史不能留下旧收入，也不能在新时间再重复入账。
	_deliver(_reward(1, 204, 13, 1, 0))
	assert(game._authority_applications == applications and game._rollback.time_economy.accounts[1].balance == 1013)
	_expect_full_replay_equivalence(frame)

func _check_future_and_current() -> void:
	_reset_economy(0, PacketInputSource.BIT_HASTE)
	_advance(6)
	var applications: int = game._authority_applications
	_deliver(_reward(1, 206, 10))
	assert(game._authority_applications == applications and game._local.pvp_haste_mult == 1.0)
	_advance(1)
	assert(game._local.pvp_haste_mult == game._rollback.time_economy.rules.haste_mult,
			"a corrected current account must affect the next natural tick without replay")
	_deliver(_reward(2, 209, 7))
	assert(game._authority_applications == applications)
	_advance(2)
	assert(game._rollback._commands[209]["economy"]["rewards"].size() == 1)
	var payload := game._rollback.time_economy.state_payload()
	game._apply_authority(_frame(209))
	_deliver(_reward(3, 208, 100))
	assert(game._rollback.time_economy.state_payload() == payload, "authority-covered rewards cannot alter the current account")

func _check_lock_and_rewind() -> void:
	_reset_economy(0, PacketInputSource.BIT_HASTE)
	game._local.set_controls_locked(true)
	game._rollback._remember_state()
	var frame := _frame(200)
	_advance(6)
	var applications: int = game._authority_applications
	_deliver(_reward(1, 202, 10))
	assert(game._authority_applications == applications, "held haste under a control lock is not a changed behavior")
	_expect_full_replay_equivalence(frame)
	_reset_economy(0, PacketInputSource.BIT_REWIND)
	_advance(6)
	_deliver(_reward(1, 202, 10))
	assert(game._rollback.last_effect_review["reason"] == "rewind"
			and game._rollback.last_effect_review["invalid_from"] == 203, "rewind permission is a gameplay dependency too")

func _check_state_accounts() -> void:
	for initial in [1000.0, 0.0]:
		_reset_economy(initial, PacketInputSource.BIT_HASTE)
		_advance(6)
		var frame := _frame(202)
		frame["time"] = frame["time"].duplicate(true)
		frame["time"][1]["b"] += 10
		var before := game._rollback.time_economy.state_payload()
		var terrain_generation := game._terrain.generation
		if initial > 0:
			assert(game._rollback.can_reuse(frame))
			assert(game._rollback.time_economy.state_payload() == before, "planning reuse must not mutate live accounts")
		game._apply_authority(frame)
		if initial > 0:
			assert(game._rollback.diagnostics["replay_ticks"] == 0)
		else:
			assert(game._rollback.diagnostics["checkpoint_tick"] == 202 and game._rollback.diagnostics["replay_ticks"] == 4)
		assert(game._terrain.generation == terrain_generation, "account-only authority must not reset the terrain world")
		_expect_full_replay_equivalence(frame)

func _check_unknown_dependency() -> void:
	_reset_economy(1000)
	_advance(6)
	game._rollback._commands[202].erase("economy")
	_deliver(_reward(1, 202, 10))
	assert(game._rollback.last_effect_review["reason"] == "economy_history"
			and game._rollback.diagnostics["checkpoint_tick"] == 201, "missing dependency history must not guess that a reward is harmless")

func _run() -> void:
	_setup()
	_check_reward_kept()
	_check_first_behavior_change()
	_check_phase_and_caps()
	_check_future_and_current()
	_check_lock_and_rewind()
	_check_state_accounts()
	_check_unknown_dependency()
	game._rollback.combat_prediction.clear()
	game.free()
	print("EVENT IMPACT PROBE OK account-only changes, exact phases, caps, haste, rewind, STATE, duplicates and missing history")
	get_tree().quit()
