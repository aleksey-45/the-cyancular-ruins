class_name PredictionRollback
extends RefCounted
const KEEP := 64
const MAX_REPLAY := 32
const MARGIN := 2.0
var history: Array = []
var epoch := 1
var sequence := 0
var sent: Array = []
var actions: Array = []
var _clock := 0.0
var _sim_tick := 0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _clock_correction_seq := 0
var _discarded_through := 0
var _input := InputBuffer.new()
var _player: CharacterBody2D
var diagnostics := {"reason": "", "replay_ticks": 0}

func bind(player: CharacterBody2D) -> void:
	_player = player

func reset(new_epoch: int, ack: int, tick: int, ping_ms: int) -> void:
	epoch = new_epoch
	sequence = ack
	sent.clear()
	history.clear()
	actions.clear()
	_input.reset(epoch)
	_clock = tick + ceilf(ping_ms * 0.06) + MARGIN
	_sim_tick = tick
	_lead = MARGIN
	_rate = 1.0
	_timing_seq = 0
	_clock_correction_seq = 0
	_discarded_through = 0

func capture(source: PlayerInput, aim: Vector2, view_tick: int, weapon_inst: int) -> void:
	actions = actions.filter(func(action: Dictionary) -> bool:
		return _clock - action["target_tick"] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var record := PacketInputSource.pack_record(source, sequence, aim)
	record["epoch"] = epoch
	record["target_tick"] = int(_clock) + 1
	record["view_tick"] = view_tick
	record["winst"] = weapon_inst
	if record["pressed"] != 0 or record["released"] != 0 or weapon_inst != 0:
		var action := record.duplicate()
		if weapon_inst == 0 and (record["pressed"] | record["released"]) & (PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD | PacketInputSource.BIT_DROP):
			action["winst"] = _player.weapons.current_inst()
		action.erase("ax")
		action.erase("held")
		actions.append(action)
	for key in ["pressed", "released", "winst"]:
		record.erase(key)
	sent.append(record)
	if sent.size() > InputBuffer.REDUNDANCY:
		sent.pop_front()
	history.append(record)
	if history.size() > KEEP:
		_discarded_through = history.pop_front()["seq"]
	_input.push(packet(), _sim_tick)

func packet() -> Dictionary:
	return {"frames": sent, "actions": actions}

func advance(delta: float) -> void:
	_clock += delta * 60.0 * _rate
	while _sim_tick < int(_clock):
		_sim_tick += 1
		var record := _input.take(_sim_tick)
		if not _player.rewinding:
			_player.begin_visual_step()
			_player.execute_actions(ActorStep.step(_player, record))

func reconcile(own: Dictionary, tick: int, ping_ms: int) -> bool:
	var changed: bool = own["epoch"] != epoch
	diagnostics = {"reason": "epoch" if changed else "", "replay_ticks": 0}
	if changed:
		reset(own["epoch"], own["ack"], tick, ping_ms)
	var desired := tick + ceilf(ping_ms * 0.06) + MARGIN
	if absf(_clock - desired) > MAX_REPLAY:
		diagnostics["reason"] = "clock"
		_clock = desired
		history.clear()
		sent.clear()
		actions.clear()
		_clock_correction_seq = sequence
	if own["timing_seq"] > _timing_seq and own["timing_seq"] > _clock_correction_seq:
		_timing_seq = own["timing_seq"]
		if absf(own["lead"] - MARGIN) > InputBuffer.ACTION_TICKS:
			diagnostics["retime_ticks"] = int(MARGIN) - own["lead"]
			var offset: int = int(MARGIN) - own["lead"]
			_clock += offset
			for record: Dictionary in history:
				record["target_tick"] += offset
			for action: Dictionary in actions:
				action["target_tick"] += offset
			_clock_correction_seq = sequence
			_lead = MARGIN
		else:
			_lead = lerpf(_lead, own["lead"], 0.1)
		_rate = 1.02 if _lead < MARGIN - 1.0 else 0.96 if _lead > MARGIN + 1.0 else 1.0
	history = history.filter(func(record: Dictionary) -> bool: return record["seq"] > own["ack"])
	sent = sent.filter(func(record: Dictionary) -> bool: return record["seq"] > own["ack"])
	actions = actions.filter(func(action: Dictionary) -> bool:
		return action["seq"] > own["action_ack"] and tick - action["target_tick"] <= InputBuffer.ACTION_TICKS)
	var previous := _player.global_position
	_player.restore_state(own["state"])
	_player.rebase_visual_step(previous)
	_input.reset(epoch)
	_input.ack = own["ack"]
	_input.action_ack = own["action_ack"]
	_input.seed(own["input"])
	_input.push({"frames": history, "actions": actions}, tick)
	_sim_tick = tick
	if own["ack"] < _discarded_through or int(_clock) - tick > MAX_REPLAY or own["rewind"]:
		diagnostics["reason"] = "rewind" if own["rewind"] else "history" if own["ack"] < _discarded_through else "budget"
		history.clear()
		_sim_tick = int(_clock)
	else:
		while _sim_tick < int(_clock):
			diagnostics["replay_ticks"] += 1
			_sim_tick += 1
			_player.begin_visual_step()
			ActorStep.step(_player, _input.take(_sim_tick))
	_discarded_through = 0
	return changed or own["rewind"]
