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

static func neutral() -> Dictionary:
	return {"seq": 0, "epoch": 1, "target_tick": 0, "ax": 0.0, "held": 0, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT}

func reset(new_epoch: int) -> void:
	epoch = new_epoch
	ack = 0
	action_ack = 0
	timing_seq = 0
	lead = 2
	frames.clear()
	actions.clear()
	_last = neutral()

func seed(record: Dictionary, known_tick: int = -1) -> void:
	_last = _expire_frame(record, known_tick) if known_tick >= 0 else record

func restore_authority(new_epoch: int, frame_ack: int, confirmed_action: int, record: Dictionary, tick: int) -> void:
	# 重置前保留本地尚未消耗的动作。随后的重推以权威 tick 为基准计算可用时机
	# （max(target, tick+1)），会把"目标 tick 恰好被这批权威状态追上"的边沿推迟
	# 一 tick，服务器已确认时甚至按 seq > action_ack 整体丢弃——本地预测因此比
	# 服务器晚一拍应用跳跃等边沿，产生 jbuf/pos 校正。epoch 变更的旧动作照常丢弃。
	var pending: Dictionary = {}
	for seq: int in actions.keys():
		if seq > action_ack:
			pending[seq] = actions[seq]
	reset(new_epoch)
	ack = frame_ack
	action_ack = confirmed_action
	self.seed(record, tick)
	for seq: int in pending:
		if pending[seq]["epoch"] == epoch:
			actions[seq] = pending[seq]

static func _expire_frame(record: Dictionary, known_tick: int) -> Dictionary:
	if known_tick - record["target_tick"] <= HOLD_TICKS: return record
	return record.merged({"ax": 0.0, "held": 0}, true)

func capture_cursor() -> Array:
	return [epoch, ack, action_ack, _last["seq"], _last["target_tick"],
			_last["ax"], _last["held"], _last["aim"]]

# 输入队列可从模拟游标和保留的命令重建；不复制仍在变化的网络接收队列。
func restore_cursor(cursor: Array) -> void:
	reset(cursor[0])
	ack = cursor[1]
	action_ack = cursor[2]
	_last = neutral().merged({"epoch": cursor[0], "seq": cursor[3], "target_tick": cursor[4],
			"ax": cursor[5], "held": cursor[6], "aim": cursor[7]}, true)

func push(packet: Dictionary, tick: int) -> void:
	for record: Dictionary in packet["frames"]:
		if record["epoch"] != epoch:
			continue
		if record["seq"] > timing_seq:
			timing_seq = record["seq"]
			lead = record["target_tick"] - tick
		if record["seq"] <= ack or record["target_tick"] > tick + FUTURE_TICKS:
			continue
		var at: int = maxi(record["target_tick"], tick + 1)
		if at > tick + FUTURE_TICKS: continue
		if not frames.has(at) or record["seq"] > frames[at]["seq"]:
			frames[at] = record
	for action: Dictionary in packet["actions"]:
		if action["epoch"] == epoch and action["seq"] > action_ack and action["target_tick"] <= tick + FUTURE_TICKS:
			var available: int = maxi(action["target_tick"], tick + 1)
			if available > tick + FUTURE_TICKS: continue
			if not actions.has(action["seq"]) or available < actions[action["seq"]]["available_tick"]:
				actions[action["seq"]] = action.merged({"available_tick": available})

func take(tick: int) -> Dictionary:
	for at in frames.keys():
		if at <= tick:
			var next: Dictionary = frames[at]
			if next["seq"] > ack:
				ack = next["seq"]
				_last = next
			frames.erase(at)
	# seed 已清除权威锚点处过期的按键；模拟中仅保留 HOLD_TICKS 的持续输入。
	var expired: bool = tick - _last["target_tick"] > HOLD_TICKS
	var record := _last.duplicate()
	if expired:
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
		if action["available_tick"] > tick:
			break
		action_ack = seq
		actions.erase(seq)
		if tick - action["target_tick"] > ACTION_TICKS:
			continue
		for key in ["seq", "pressed", "released", "winst", "aim"]:
			record[key] = action[key]
		break
	return record
