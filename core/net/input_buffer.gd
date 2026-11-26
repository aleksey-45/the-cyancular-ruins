class_name InputBuffer
extends RefCounted

const REDUNDANCY := 4
const HOLD_TICKS := 6
const FUTURE_TICKS := 32
const ACTION_TICKS := 12

enum { PACKET_FRAMES, PACKET_ACTIONS }

# 持续输入和单次动作共用前三个字段。SEQ 是输入序号，EPOCH 区分重置前后的输入，TARGET_TICK 是原定生效的模拟帧。
enum { SEQ, EPOCH, TARGET_TICK, FRAME_AX, FRAME_HELD, FRAME_AIM }
enum { ACTION_PRESSED = TARGET_TICK + 1, ACTION_RELEASED, ACTION_WINST, ACTION_AIM }

const _AVAILABLE_TICK: int = 0
const _ACTION_RECORD: int = 1

var epoch := 1
var action_ack := 0
var frames: Dictionary[int, Array] = {}
var actions: Dictionary[int, Array] = {}
var _last := neutral_frame()
var consumed_seq: int:
	get: return _last[SEQ]

static func neutral_frame() -> Array:
	return [0, 1, 0, 0.0, 0, Vector2.RIGHT]

func reset(new_epoch: int) -> void:
	epoch = new_epoch
	action_ack = 0
	frames.clear()
	actions.clear()
	_last = neutral_frame()

func restore_authority(new_epoch: int, confirmed_action: int, record: Array) -> void:
	reset(new_epoch)
	action_ack = confirmed_action
	_last = record

## 在当前预测进度上应用服务器确认，保留序号更大的本地持续输入。
func acknowledge(confirmed_action: int, record: Array) -> void:
	if record[SEQ] >= consumed_seq:
		_last = record
	if confirmed_action > action_ack:
		action_ack = confirmed_action
		for seq: int in actions.keys():
			if seq <= action_ack:
				actions.erase(seq)

static func _expired(record: Array, tick: int) -> bool:
	return tick - record[TARGET_TICK] > HOLD_TICKS

func push(packet: Array, tick: int) -> void:
	var last_seq := consumed_seq
	for record: Array in packet[PACKET_FRAMES]:
		if record[EPOCH] != epoch:
			continue
		var seq: int = record[SEQ]
		var target: int = record[TARGET_TICK]
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
