class_name InputBuffer
extends RefCounted
const REDUNDANCY := 4
const HOLD_TICKS := 6
const FUTURE_TICKS := 32
const ACTION_TICKS := 12

const PACKET_FRAMES: int = 0
const PACKET_ACTIONS: int = 1

# 持续输入和单次动作共用前三个槽。
const SEQ: int = 0
const EPOCH: int = 1
const TARGET_TICK: int = 2
const FRAME_AX: int = 3
const FRAME_HELD: int = 4
const FRAME_AIM: int = 5
const ACTION_PRESSED: int = 3
const ACTION_RELEASED: int = 4
const ACTION_WINST: int = 5
const ACTION_AIM: int = 6

const _AVAILABLE_TICK: int = 0
const _ACTION_RECORD: int = 1

var epoch := 1
var action_ack := 0
var timing_seq := 0
var lead := 2
var frames: Dictionary[int, Array] = {}
var actions: Dictionary[int, Array] = {}
var _last := neutral_frame()

static func neutral_frame() -> Array:
	return [0, 1, 0, 0.0, 0, Vector2.RIGHT]

func reset(new_epoch: int) -> void:
	epoch = new_epoch
	action_ack = 0
	timing_seq = 0
	lead = 2
	frames.clear()
	actions.clear()
	_last = neutral_frame()

func restore_authority(new_epoch: int, confirmed_action: int, record: Array, tick: int) -> void:
	reset(new_epoch)
	action_ack = confirmed_action
	_last = record
	if _expired(record, tick):
		_last = record.duplicate()
		_last[FRAME_AX] = 0.0
		_last[FRAME_HELD] = 0

static func _expired(record: Array, tick: int) -> bool:
	return tick - record[TARGET_TICK] > HOLD_TICKS

static func cursor(ep: int, confirmed_action: int, record: Array, tick: int) -> Array:
	var expired := _expired(record, tick)
	return [ep, record[SEQ], confirmed_action, record[TARGET_TICK],
			0.0 if expired else record[FRAME_AX], 0 if expired else record[FRAME_HELD], record[FRAME_AIM]]

func capture_cursor(tick: int) -> Array:
	return cursor(epoch, action_ack, _last, tick)

func push(packet: Array, tick: int) -> void:
	var last_seq: int = _last[SEQ]
	for record: Array in packet[PACKET_FRAMES]:
		if record[EPOCH] != epoch:
			continue
		var seq: int = record[SEQ]
		var target: int = record[TARGET_TICK]
		if seq > timing_seq:
			timing_seq = seq
			lead = target - tick
		if seq <= last_seq or target > tick + FUTURE_TICKS:
			continue
		var at := maxi(target, tick + 1)
		if not frames.has(at) or seq > frames[at][SEQ]:
			frames[at] = record
	for action: Array in packet[PACKET_ACTIONS]:
		var seq: int = action[SEQ]
		var target: int = action[TARGET_TICK]
		if action[EPOCH] != epoch or seq <= action_ack or target > tick + FUTURE_TICKS:
			continue
		var available := maxi(target, tick + 1)
		if not actions.has(seq) or available < actions[seq][_AVAILABLE_TICK]:
			actions[seq] = [available, action]

func take(tick: int) -> Array:
	for at in frames.keys():
		if at <= tick:
			var next: Array = frames[at]
			if next[SEQ] > _last[SEQ]:
				_last = next
			frames.erase(at)
	var expired := _expired(_last, tick)
	var record := [0.0 if expired else _last[FRAME_AX], 0 if expired else _last[FRAME_HELD],
			0, 0, 0, _last[FRAME_AIM]]
	var seqs := actions.keys()
	seqs.sort()
	for seq in seqs:
		var scheduled: Array = actions[seq]
		if scheduled[_AVAILABLE_TICK] > tick:
			break
		action_ack = seq
		actions.erase(seq)
		var action: Array = scheduled[_ACTION_RECORD]
		if tick - action[TARGET_TICK] > ACTION_TICKS:
			continue
		record[ActorInput.PRESSED] = action[ACTION_PRESSED]
		record[ActorInput.RELEASED] = action[ACTION_RELEASED]
		record[ActorInput.WINST] = action[ACTION_WINST]
		record[ActorInput.AIM] = action[ACTION_AIM]
		break
	return record
