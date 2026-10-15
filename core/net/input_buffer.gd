class_name InputBuffer
extends RefCounted
const REDUNDANCY := 4
const HOLD_TICKS := 6
const FUTURE_TICKS := 32
const ACTION_TICKS := 12
var epoch := 1
var ack := 0
var action_ack := 0
var timing_seq := 0
var lead := 2
var frames: Dictionary = {}
var actions: Dictionary = {}
var _last := neutral()
var _missing := HOLD_TICKS
var diagnostics := {"late_arrivals": 0, "held_ticks": 0, "neutral_ticks": 0, "expired_actions": 0}

static func neutral() -> Dictionary:
	return {"seq": 0, "epoch": 1, "target_tick": 0, "view_tick": 0, "ax": 0.0, "held": 0, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT}

func reset(new_epoch: int) -> void:
	epoch = new_epoch
	ack = 0
	action_ack = 0
	timing_seq = 0
	lead = 2
	frames.clear()
	actions.clear()
	_last = neutral()
	_missing = HOLD_TICKS

func seed(record: Dictionary) -> void:
	_last = record

func push(packet: Dictionary, tick: int) -> void:
	for record: Dictionary in packet["frames"]:
		if record["epoch"] != epoch:
			continue
		if record["seq"] > timing_seq:
			if record["target_tick"] <= tick:
				diagnostics["late_arrivals"] += 1
			timing_seq = record["seq"]
			lead = record["target_tick"] - tick
		if record["seq"] <= ack or record["target_tick"] > tick + FUTURE_TICKS:
			continue
		var at: int = maxi(record["target_tick"], tick + 1)
		if not frames.has(at) or record["seq"] > frames[at]["seq"]:
			frames[at] = record
	for action: Dictionary in packet["actions"]:
		if action["epoch"] == epoch and action["seq"] > action_ack and action["target_tick"] <= tick + FUTURE_TICKS:
			actions[action["seq"]] = action

func take(tick: int) -> Dictionary:
	for at in frames.keys():
		if at <= tick:
			var next: Dictionary = frames[at]
			if next["seq"] > ack:
				ack = next["seq"]
				_last = next
			frames.erase(at)
	_missing = tick - _last["target_tick"]
	if _missing > 0:
		diagnostics["neutral_ticks" if _missing > HOLD_TICKS else "held_ticks"] += 1
	var record := _last.duplicate()
	if _missing > HOLD_TICKS:
		record["ax"] = 0.0
		record["held"] = 0
	record["seq"] = ack
	record["epoch"] = epoch
	record["pressed"] = 0
	record["released"] = 0
	record["winst"] = 0
	var seqs := actions.keys()
	seqs.sort()
	for seq in seqs:
		var action: Dictionary = actions[seq]
		if action["target_tick"] > tick:
			break
		action_ack = seq
		actions.erase(seq)
		if tick - action["target_tick"] > ACTION_TICKS:
			diagnostics["expired_actions"] += 1
			continue
		for key in ["seq", "pressed", "released", "winst", "aim", "view_tick"]:
			record[key] = action[key]
		break
	return record
