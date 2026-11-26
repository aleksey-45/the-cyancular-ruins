class_name NetCodec
extends RefCounted

# 多字节数值使用小端字节序。接收方按消息类型读取约定的字段顺序和数据类型。
const INPUT := 0
const STATE := 1
const EVENT := 2
const KEEP := 64
const MAX_UNRELIABLE_STATE := 256 * 1024
const WIRE_MAGIC := 199
const PROTOCOL_VERSION := 41
const MODES := [WorldSpec.DUEL, WorldSpec.TEAM, WorldSpec.ROYALE]
enum Field { U8, I8, U16, I32, U32, F64, VEC, BOOL, INVENTORY, U64, POLYLINE, DATA }
const PlayerSlots := preload("res://core/sim/player_state_schema.gd")
# 世界字段使用自己的布局。传输只为各字段指定编码。
const INPUT_FRAME_TYPES := [Field.U32, Field.U32, Field.I32, Field.F64, Field.U16, Field.VEC]
const ACTOR_FIELDS := [
	Field.VEC, Field.BOOL, Field.F64, Field.VEC, Field.I8, Field.F64, Field.F64, Field.F64,
	Field.BOOL, Field.BOOL, Field.BOOL, Field.F64, Field.BOOL, Field.BOOL, Field.VEC, Field.U32,
	Field.F64, Field.BOOL, Field.F64, Field.F64, Field.BOOL, Field.U8, Field.I32, Field.I32,
	Field.BOOL, Field.F64, Field.BOOL, Field.U32, Field.U32, Field.U16, Field.U32, Field.VEC,
	Field.U8, Field.U32, Field.U32, Field.INVENTORY,
]
const EQUIPMENT_FIELDS := [Field.F64, Field.BOOL, Field.BOOL, Field.I8, Field.F64, Field.F64]
const MOTION_FIELDS := [Field.VEC, Field.VEC, Field.F64, Field.F64, Field.F64, Field.F64]
const PROJECTILE_FIELDS := MOTION_FIELDS + [Field.U8, Field.U16, Field.I32, Field.BOOL]
const HISTORY_FIELDS := [Field.F64, Field.F64, Field.F64]
const RULE_FIELDS := [Field.U8, Field.U32, Field.F64, Field.F64, Field.DATA, Field.DATA,
	Field.DATA, Field.U16, Field.U16, Field.DATA]
const META_KEYS := ["combat_tick", "pickup_tick", "pickup_next", "enemy_next", "kills", "rng"]
const META_FIELDS := [Field.U32, Field.U32, Field.U32, Field.I32, Field.U32, Field.U64]
const RECORDS := {
	"projectiles": [Field.U64, PROJECTILE_FIELDS],
	"pickups": [Field.U32, [Field.VEC, Field.VEC, Field.U8, Field.U16, Field.U32, Field.I32, Field.BOOL, Field.BOOL]],
	"beams": [Field.U64, [Field.U32, Field.POLYLINE]],
	"blasts": [Field.U64, [Field.U8, Field.VEC, Field.U32]],
	"accounts": [Field.U16, [Field.F64, Field.F64, Field.F64, Field.BOOL]],
	"inputs": [Field.U16, [Field.U32, Field.U32] + INPUT_FRAME_TYPES],
}
const SECTIONS := ["players", "projectiles", "pickups", "beams", "blasts", "accounts", "inputs",
	"histories", "rules", "stats", "enemies", "world_time", "grace"]

var state_ack := 0
var serial := 0
var latest := 0
var waiting_full := 0
var history: Dictionary = {}
var _history_order: Array[int] = []
var _history_cursor := 0

class Reader extends RefCounted:
	const FIELD_BYTES := {
		Field.U8: 1, Field.I8: 1, Field.BOOL: 1, Field.INVENTORY: 1, Field.POLYLINE: 1, Field.U16: 2,
		Field.U32: 4, Field.I32: 4, Field.U64: 8, Field.F64: 8, Field.VEC: 8, Field.DATA: 4,
	}

	var valid := true
	var _data: PackedByteArray
	var _pos: int
	var _size: int

	func _init(data: PackedByteArray, offset: int = 0) -> void:
		_data = data
		_pos = offset
		_size = data.size()

	func remaining() -> int:
		return _size - _pos

	func finish() -> bool:
		valid = valid and _pos == _size
		return valid

	func count(items: int, bytes_per_item: int) -> int:
		if items * bytes_per_item > remaining():
			valid = false
		return items if valid else 0

	func _take(size: int) -> int:
		if not valid or _pos + size > _size:
			valid = false
			return -1
		var at := _pos
		_pos += size
		return at

	func read(kind: int) -> Variant:
		var at := _take(FIELD_BYTES[kind])
		if at < 0:
			return 0
		match kind:
			Field.U8: return _data[at]
			Field.BOOL: return bool(_data[at])
			Field.I8: return _data.decode_s8(at)
			Field.U16: return _data.decode_u16(at)
			Field.I32: return _data.decode_s32(at)
			Field.U32: return _data.decode_u32(at)
			Field.U64: return _data.decode_u64(at)
			Field.DATA:
				var blob := bytes(_data.decode_u32(at))
				return bytes_to_var(blob) if valid else null
			Field.F64:
				var value := _data.decode_double(at)
				valid = is_finite(value)
				return value
			Field.VEC:
				var value := Vector2(_data.decode_float(at), _data.decode_float(at + 4))
				valid = value.is_finite()
				return value
			Field.POLYLINE:
				var points := PackedVector2Array()
				var length := count(_data[at], 8)
				valid = valid and length >= 2
				while valid and points.size() < length:
					points.append(read(Field.VEC))
				return points
			Field.INVENTORY:
				var items := count(_data[at], 9)
				var inventory := PackedInt32Array()
				inventory.resize(items * WeaponInventory.STRIDE)
				for i in items:
					var slot := i * WeaponInventory.STRIDE
					inventory[slot + WeaponInventory.INST] = read(Field.U32)
					inventory[slot + WeaponInventory.TYPE] = read(Field.U8)
					inventory[slot + WeaponInventory.CARRIED] = read(Field.I32)
				return inventory
		return null

	func bytes(size: int) -> PackedByteArray:
		var at := _take(size)
		return _data.slice(at, _pos) if at >= 0 else PackedByteArray()

class StateBatch extends RefCounted:
	var data: Dictionary
	var snapshot := RefCounted.new()
	var deltas := {}

	func _init(frame: Dictionary) -> void:
		data = frame["checkpoint"].duplicate()
		data["inputs"] = frame["inputs"]
		data["grace"] = frame["grace"]

func encode_input(packet: Array) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(INPUT)
	s.put_u32(state_ack)
	_write_input(s, packet)
	return s.data_array

func _write_input(s: StreamPeerBuffer, packet: Array) -> void:
	var frames: Array = packet[InputBuffer.PACKET_FRAMES]
	var actions: Array = packet[InputBuffer.PACKET_ACTIONS]
	var epoch := 1
	if not frames.is_empty():
		epoch = frames[0][InputBuffer.EPOCH]
	elif not actions.is_empty():
		epoch = actions[0][InputBuffer.EPOCH]
	s.put_u32(epoch)
	s.put_u8(frames.size())
	var previous: Array = []
	for frame: Array in frames:
		s.put_u32(frame[InputBuffer.SEQ])
		# 在包内对目标帧与输入序号之差做增量编码。时钟稳定时，四份冗余输入共用一个偏移。
		var encoded := frame.duplicate()
		encoded[InputBuffer.TARGET_TICK] -= frame[InputBuffer.SEQ]
		_put_delta(s, encoded, previous, INPUT_FRAME_TYPES, InputBuffer.TARGET_TICK)
		previous = encoded
	s.put_u8(actions.size())
	for action: Array in actions:
		s.put_u32(action[InputBuffer.SEQ])
		s.put_u32(action[InputBuffer.TARGET_TICK])
		s.put_u16(action[InputBuffer.ACTION_PRESSED])
		s.put_u16(action[InputBuffer.ACTION_RELEASED])
		s.put_u32(action[InputBuffer.ACTION_WINST])
		_put_vec(s, action[InputBuffer.ACTION_AIM])

func decode_input(s: Reader) -> Array:
	var ack: int = s.read(Field.U32)
	var epoch: int = s.read(Field.U32)
	var count := s.count(s.read(Field.U8), 5) # 输入序号占 4 字节，变化位掩码占 1 字节，因此每条记录至少需要 5 字节。
	var frames: Array = []
	var previous: Array = []
	for i in count:
		var seq: int = s.read(Field.U32)
		previous = _get_delta(s, previous, INPUT_FRAME_TYPES, InputBuffer.TARGET_TICK)
		if not s.valid:
			return []
		var target := seq + int(previous[InputBuffer.TARGET_TICK])
		if seq == 0 or target <= 0 or target > 0x7fffffff:
			s.valid = false
			return []
		var frame := previous.duplicate()
		frame[InputBuffer.SEQ] = seq
		frame[InputBuffer.EPOCH] = epoch
		frame[InputBuffer.TARGET_TICK] = target
		frames.append(frame)
	var actions: Array = []
	for i in s.count(s.read(Field.U8), 24):
		var seq: int = s.read(Field.U32)
		var target: int = s.read(Field.U32)
		if seq == 0 or target <= 0 or target > 0x7fffffff:
			s.valid = false
			return []
		actions.append([seq, epoch, target, s.read(Field.U16), s.read(Field.U16), s.read(Field.U32), s.read(Field.VEC)])
	if not s.finish():
		return []
	state_ack = 0 if ack == 0 else maxi(state_ack, ack)
	return [frames, actions]

func encode_state(feedback: PackedByteArray, batch: StateBatch, full := false) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(STATE)
	_write_state(s, feedback, batch, full, MAX_UNRELIABLE_STATE)
	waiting_full = serial if s.get_size() > MAX_UNRELIABLE_STATE else 0
	return s.data_array

func _write_state(s: StreamPeerBuffer, feedback: PackedByteArray, batch: StateBatch, full := false, limit := 0) -> void:
	serial += 1
	var base: Dictionary = {} if full else history.get(state_ack, {})
	var delta := _world_bytes(batch, base)
	# STATE 类型、四个 u32 和反馈长度共 21 字节。
	if limit > 0 and not base.is_empty() and 21 + feedback.size() + delta.size() > limit:
		base = {}
		delta = _world_bytes(batch, base)
	s.put_u32(serial)
	s.put_u32(state_ack if not base.is_empty() else 0)
	s.put_u32(batch.data["tick"])
	s.put_u32(batch.data["terrain"])
	_put_blob(s, feedback)
	s.put_data(delta)
	_store_history(serial, {"data": batch.data, "snapshot": batch.snapshot})

func _world_bytes(batch: StateBatch, base: Dictionary) -> PackedByteArray:
	var key: Variant = base.get("snapshot")
	if not batch.deltas.has(key):
		batch.deltas[key] = _encode_world(batch.data, base.get("data", {}))
	return batch.deltas[key]

func _encode_world(current: Dictionary, base: Dictionary) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	_put_delta(s, _meta(current), _meta(base), META_FIELDS)
	var mask := 0
	for i in SECTIONS.size():
		var key: String = SECTIONS[i]
		if base.is_empty() or current[key] != base[key]:
			mask |= 1 << i
	_put_mask(s, mask, SECTIONS.size())
	for i in SECTIONS.size():
		if not mask & (1 << i):
			continue
		var key: String = SECTIONS[i]
		if RECORDS.has(key):
			var format: Array = RECORDS[key]
			_put_records(s, current[key], base.get(key, {}), format[0], format[1])
		else:
			match key:
				"players": _write_players(s, current[key], base.get(key, {}))
				"histories": _write_histories(s, current[key], base.get(key, {}))
				"rules":
					var has_rounds: bool = not current[key].is_empty()
					s.put_u8(int(has_rounds))
					if has_rounds: _put_delta(s, current[key], base.get(key, []), RULE_FIELDS)
				_: _write_value(s, Field.DATA, current[key])
	return s.data_array

static func _meta(data: Dictionary) -> Array:
	var row := []
	if not data.is_empty():
		for key in META_KEYS:
			row.append(data[key])
	return row

func decode_state(s: Reader, baseline := false) -> Dictionary:
	var number: int = s.read(Field.U32)
	var base_number: int = s.read(Field.U32)
	var tick: int = s.read(Field.U32)
	var terrain: int = s.read(Field.U32)
	if baseline and base_number != 0:
		s.valid = false
		return {}
	if number <= latest:
		return {}
	var base: Dictionary = history.get(base_number, {}).get("data", {})
	if base_number != 0 and base.is_empty():
		state_ack = 0
		return {}
	var feedback := _get_blob(s)
	var meta := _get_delta(s, _meta(base), META_FIELDS)
	var mask := _get_mask(s, SECTIONS.size(), base.is_empty())
	var data := base.duplicate()
	data["tick"] = tick
	data["terrain"] = terrain
	for i in META_KEYS.size():
		data[META_KEYS[i]] = meta[i]
	for i in SECTIONS.size():
		if not s.valid or not mask & (1 << i):
			continue
		var key: String = SECTIONS[i]
		if RECORDS.has(key):
			var format: Array = RECORDS[key]
			data[key] = _get_records(s, base.get(key, {}), format[0], format[1])
		else:
			match key:
				"players": data[key] = _read_players(s, base.get(key, {}))
				"histories": data[key] = _read_histories(s, base.get(key, {}))
				"rules": data[key] = _get_delta(s, base.get(key, []), RULE_FIELDS) if s.read(Field.BOOL) else []
				_: data[key] = s.read(Field.DATA)
	if not s.finish():
		return {}
	if baseline:
		history.clear()
	latest = number
	state_ack = number
	_store_history(number, {"data": data})
	var inputs: Dictionary = data["inputs"]
	var grace: Dictionary = data["grace"]
	var checkpoint := data.duplicate()
	checkpoint.erase("inputs")
	checkpoint.erase("grace")
	return {"checkpoint": checkpoint, "inputs": inputs, "input_feedback": feedback, "grace": grace}

# 按序号保存最近的快照，发送和接收增量时都从这里查找基准。达到容量上限后覆盖最早保存的记录。
func _store_history(number: int, frame: Dictionary) -> void:
	if history.is_empty():
		_history_order.clear()
		_history_cursor = 0
	if not history.has(number):
		if _history_order.size() < KEEP:
			_history_order.append(number)
		else:
			history.erase(_history_order[_history_cursor])
			_history_order[_history_cursor] = number
			_history_cursor = (_history_cursor + 1) % KEEP
	history[number] = frame

func encode_event(kind: int, data: Variant, batch: StateBatch = null) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(EVENT + kind)
	if kind in [NetEvent.Kind.CREATE, NetEvent.Kind.JOIN]:
		_put_string(s, data["name"])
		s.put_double(data["hue"])
	match kind:
		NetEvent.Kind.CREATE:
			s.put_u8(MODES.find(data["mode"]))
			_put_options(s, data["options"])
		NetEvent.Kind.JOIN:
			s.put_u32(int(data["code"]))
			s.put_u8(int(data["beta"]))
		NetEvent.Kind.REJOIN:
			s.put_u32(int(data["code"]))
			_put_token(s, data["token"])
		NetEvent.Kind.PICK_TEAM, NetEvent.Kind.READY:
			s.put_u32(data)
		NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED:
			_put_string(s, data)
		NetEvent.Kind.ROOM:
			_put_room(s, data)
			s.put_u16(data["your_role"])
			_put_token(s, data["token"])
		NetEvent.Kind.BASELINE:
			s.put_u32(int(data["code"]))
			s.put_u8(MODES.find(data["mode"]))
			s.put_u16(data["role"])
			s.put_u64(data["seed"])
			_put_roles(s, data["roles"])
			_put_options(s, data["options"])
			_put_names(s, data["names"], data["hues"])
			_put_role_map(s, data["teams"])
			_put_blob(s, data["map"])
		NetEvent.Kind.TERRAIN:
			s.put_u32(data["version"])
			_put_cell_hp(s, data["cells"])
	if kind in [NetEvent.Kind.BASELINE, NetEvent.Kind.ROUND]:
		history.clear()
		state_ack = 0
		waiting_full = 0
		_put_cell_hp(s, data["sub_hp"])
		_write_state(s, data["frame"]["input_feedback"], batch if batch != null else StateBatch.new(data["frame"]), true)
	return s.data_array

func decode_event(kind: int, s: Reader) -> Variant:
	var payload: Variant = _read_event(kind, s)
	return payload if s.finish() else null

func _read_event(kind: int, s: Reader) -> Variant:
	match kind:
		NetEvent.Kind.CREATE, NetEvent.Kind.JOIN:
			var profile := {"name": _get_string(s), "hue": s.read(Field.F64)}
			if kind == NetEvent.Kind.CREATE:
				return profile.merged({"mode": _get_mode(s), "options": _get_options(s)})
			return profile.merged({"code": "%08d" % s.read(Field.U32), "beta": s.read(Field.BOOL)})
		NetEvent.Kind.REJOIN: return {"code": "%08d" % s.read(Field.U32), "token": _get_token(s)}
		NetEvent.Kind.PICK_TEAM, NetEvent.Kind.READY: return s.read(Field.U32)
		NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED: return _get_string(s)
		NetEvent.Kind.ROOM:
			var room := _get_room(s)
			room.merge({"your_role": s.read(Field.U16), "token": _get_token(s)})
			return room
		NetEvent.Kind.BASELINE:
			var data := {"code": "%08d" % s.read(Field.U32), "mode": _get_mode(s),
				"role": s.read(Field.U16), "seed": s.read(Field.U64), "roles": _get_roles(s),
				"options": _get_options(s)}
			data.merge(_get_names(s))
			data["teams"] = _get_role_map(s)
			data["map"] = _get_blob(s)
			data["sub_hp"] = _get_cell_hp(s)
			data["frame"] = decode_state(s, true)
			return data
		NetEvent.Kind.ROUND:
			return {"sub_hp": _get_cell_hp(s), "frame": decode_state(s, true)}
		NetEvent.Kind.TERRAIN:
			return {"version": s.read(Field.U32), "cells": _get_cell_hp(s)}
		NetEvent.Kind.LEAVE, NetEvent.Kind.START, NetEvent.Kind.SUICIDE:
			return null
	s.valid = false
	return null

static func _write_players(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> void:
	_put_removed(s, current, base, Field.U16)
	var count_position := s.get_position()
	s.put_u16(0)
	var count := 0
	for id: int in current:
		var old: Array = base.get(id, [])
		if current[id] != old:
			s.put_u16(id)
			_put_actor(s, current[id], old)
			count += 1
	_patch_count(s, count_position, count)

static func _read_players(s: Reader, base: Dictionary) -> Dictionary:
	var players := base.duplicate()
	for i in s.count(s.read(Field.U16), 2):
		players.erase(s.read(Field.U16))
	for i in s.count(s.read(Field.U16), 2):
		var id: int = s.read(Field.U16)
		players[id] = _get_actor(s, players.get(id, []))
	return players

static func _put_actor(s: StreamPeerBuffer, state: Array, old: Array) -> void:
	_put_delta(s, state, old, ACTOR_FIELDS)
	var equipment: Array = state[PlayerSlots.EQUIPMENT]
	s.put_u8(int(not equipment.is_empty()))
	if not equipment.is_empty():
		_put_delta(s, equipment, _equipment_base(state, old), EQUIPMENT_FIELDS)

static func _get_actor(s: Reader, old: Array) -> Array:
	var state := _get_delta(s, old, ACTOR_FIELDS)
	state.resize(PlayerSlots.SIZE)
	state[PlayerSlots.EQUIPMENT] = _get_delta(s, _equipment_base(state, old), EQUIPMENT_FIELDS) if s.read(Field.BOOL) else []
	return state

static func _equipment_base(state: Array, old: Array) -> Array:
	if old.is_empty() or state[PlayerSlots.WEAPON_INST] != old[PlayerSlots.WEAPON_INST]:
		return []
	return old[PlayerSlots.EQUIPMENT]

## 复用已确认快照与当前快照重叠的连续历史采样，再编码新追加的采样。
static func _write_histories(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> void:
	s.put_u16(current.size())
	for role: int in current:
		s.put_u16(role)
		var row: Array = current[role]
		var previous: Array = base.get(role, [])
		_put_delta(s, row, previous, HISTORY_FIELDS)
		var old: Array = [] if previous.is_empty() else previous[TimeHistory.State.SAMPLES]
		var samples: Array = row[TimeHistory.State.SAMPLES]
		var start := 0
		var shared := 0
		if not samples.is_empty() and not old.is_empty():
			var first: int = samples[0][TimeHistory.Sample.COMMIT]
			while start < old.size() and old[start][TimeHistory.Sample.COMMIT] < first:
				start += 1
			if start < old.size() and old[start][TimeHistory.Sample.COMMIT] == first:
				shared = mini(samples.size(), old.size() - start)
				while samples[shared - 1][TimeHistory.Sample.COMMIT] != old[start + shared - 1][TimeHistory.Sample.COMMIT]:
					shared -= 1
		s.put_u16(start)
		s.put_u16(shared)
		s.put_u16(samples.size() - shared)
		var reference: Array = [] if shared == 0 else samples[shared - 1]
		for i in range(shared, samples.size()):
			var sample: Array = samples[i]
			s.put_u32(sample[TimeHistory.Sample.COMMIT])
			s.put_double(sample[TimeHistory.Sample.TIME])
			_put_actor(s, sample[TimeHistory.Sample.ACTOR], [] if reference.is_empty() else reference[TimeHistory.Sample.ACTOR])
			_put_records(s, sample[TimeHistory.Sample.ATTACKS],
					{} if reference.is_empty() else reference[TimeHistory.Sample.ATTACKS], Field.U64, MOTION_FIELDS)
			reference = sample

static func _read_histories(s: Reader, base: Dictionary) -> Dictionary:
	var histories := {}
	for i in s.count(s.read(Field.U16), 9):
		var role: int = s.read(Field.U16)
		var previous: Array = base.get(role, [])
		var row := _get_delta(s, previous, HISTORY_FIELDS)
		var old: Array = [] if previous.is_empty() else previous[TimeHistory.State.SAMPLES]
		var start: int = s.read(Field.U16)
		var shared: int = s.read(Field.U16)
		if start + shared > old.size():
			s.valid = false
			return {}
		var samples := old.slice(start, start + shared)
		for j in s.count(s.read(Field.U16), 12):
			var at: int = s.read(Field.U32)
			var time: float = s.read(Field.F64)
			var reference: Array = [] if samples.is_empty() else samples.back()
			var actor := _get_actor(s, [] if reference.is_empty() else reference[TimeHistory.Sample.ACTOR])
			var projectiles := _get_records(s, {} if reference.is_empty() else reference[TimeHistory.Sample.ATTACKS],
					Field.U64, MOTION_FIELDS)
			samples.append([at, time, actor, projectiles])
		row.resize(TimeHistory.State.SAMPLES + 1)
		row[TimeHistory.State.SAMPLES] = samples
		histories[role] = row
	return histories

static func _put_records(s: StreamPeerBuffer, current: Dictionary, base: Dictionary, id_type: int, types: Array) -> void:
	_put_removed(s, current, base, id_type)
	var count_position := s.get_position()
	s.put_u16(0)
	var changed := 0
	for id in current:
		var old: Array = base.get(id, [])
		if current[id] != old:
			_write_value(s, id_type, id)
			_put_delta(s, current[id], old, types)
			changed += 1
	if changed != 0: _patch_count(s, count_position, changed)

static func _get_records(s: Reader, base: Dictionary, id_type: int, types: Array) -> Dictionary:
	var result := base.duplicate()
	var id_bytes: int = Reader.FIELD_BYTES[id_type]
	for i in s.count(s.read(Field.U16), id_bytes):
		result.erase(s.read(id_type))
	for i in s.count(s.read(Field.U16), id_bytes + (types.size() + 7) / 8):
		var id: int = s.read(id_type)
		result[id] = _get_delta(s, result.get(id, []), types)
		if not s.valid: break
	return result

static func _write_value(s: StreamPeerBuffer, kind: int, value: Variant) -> void:
	match kind:
		Field.U8, Field.BOOL: s.put_u8(int(value))
		Field.I8: s.put_8(value)
		Field.U16: s.put_u16(value)
		Field.I32: s.put_32(value)
		Field.U32: s.put_u32(value)
		Field.U64: s.put_u64(value)
		Field.F64: s.put_double(value)
		Field.DATA: _put_blob(s, var_to_bytes(value))
		Field.VEC: _put_vec(s, value)
		Field.POLYLINE:
			s.put_u8(value.size())
			for point: Vector2 in value:
				_put_vec(s, point)
		Field.INVENTORY:
			s.put_u8(value.size() / WeaponInventory.STRIDE)
			for i in range(0, value.size(), WeaponInventory.STRIDE):
				s.put_u32(value[i + WeaponInventory.INST])
				s.put_u8(value[i + WeaponInventory.TYPE])
				s.put_32(value[i + WeaponInventory.CARRIED])

static func _put_delta(s: StreamPeerBuffer, data: Array, base: Array, types: Array, first := 0) -> void:
	var mask := 0
	for slot in range(first, types.size()):
		if base.is_empty() or data[slot] != base[slot]:
			mask |= 1 << (slot - first)
	_put_mask(s, mask, types.size() - first)
	for slot in range(first, types.size()):
		if mask & (1 << (slot - first)):
			_write_value(s, types[slot], data[slot])

static func _put_removed(s: StreamPeerBuffer, current: Dictionary, base: Dictionary, id_type: int) -> void:
	var position := s.get_position()
	s.put_u16(0)
	var removed := 0
	for id in base:
		if current.has(id): continue
		removed += 1
		_write_value(s, id_type, id)
	if removed != 0: _patch_count(s, position, removed)

static func _patch_count(s: StreamPeerBuffer, position: int, count: int) -> void:
	var end := s.get_position()
	s.seek(position)
	s.put_u16(count)
	s.seek(end)

static func _get_delta(s: Reader, base: Array, types: Array, first := 0) -> Array:
	var mask := _get_mask(s, types.size() - first, base.is_empty())
	var data := base.duplicate()
	if data.is_empty():
		data.resize(types.size())
	for slot in range(first, types.size()):
		if mask & (1 << (slot - first)):
			data[slot] = s.read(types[slot])
	return data

static func _time_rule_type(field: String) -> int:
	return Field.U32 if TimeRules.FIELDS[field][TimeRules.DEFAULT] is int else Field.F64

static func _put_options(s: StreamPeerBuffer, data: Dictionary) -> void:
	var keys := RoomOptions.DEFAULTS.keys()
	var mask := 0
	for i in keys.size():
		if data.has(keys[i]): mask |= 1 << i
	s.put_u16(mask)
	for key in keys:
		if not data.has(key): continue
		var value: Variant = data[key]
		match key:
			"map": _put_string(s, value)
			"disabled_weapons":
				s.put_u8(value.size())
				for id in value: s.put_u8(id)
			"time":
				s.put_u8(int(not value.is_empty()))
				if not value.is_empty():
					for field in TimeRules.FIELDS:
						_write_value(s, _time_rule_type(field), value[field])
			_: _write_value(s, Field.BOOL if RoomOptions.DEFAULTS[key] is bool else Field.U32, value)

static func _get_options(s: Reader) -> Dictionary:
	var mask: int = s.read(Field.U16)
	if mask >> RoomOptions.DEFAULTS.size():
		s.valid = false
		return {}
	var data := {}
	var keys := RoomOptions.DEFAULTS.keys()
	for i in keys.size():
		if not mask & (1 << i): continue
		var key: String = keys[i]
		match key:
			"map": data[key] = _get_string(s)
			"disabled_weapons":
				var ids: Array = []
				for j in s.count(s.read(Field.U8), 1): ids.append(s.read(Field.U8))
				data[key] = ids
			"time":
				var rules := {}
				if s.read(Field.BOOL):
					for field in TimeRules.FIELDS:
						rules[field] = s.read(_time_rule_type(field))
				data[key] = rules
			_: data[key] = s.read(Field.BOOL if RoomOptions.DEFAULTS[key] is bool else Field.U32)
	return data

static func _put_room(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u32(int(data["code"]))
	s.put_u8(MODES.find(data["mode"]))
	_put_string(s, data["map"])
	s.put_u16(data["max_players"])
	s.put_u32(data["match_time"])
	s.put_u16(data["host_role"])
	s.put_u8(int(data["in_match"]) | (int(data["beta"]) << 1) | (int(data["can_start"]) << 2)
			| (int(data["player_collision"]) << 3))
	s.put_u16(data["players"].size())
	for player: Dictionary in data["players"]:
		s.put_u16(player["role"])
		_put_string(s, player["name"])
		s.put_u8(player["team"])

static func _get_room(s: Reader) -> Dictionary:
	var data := {"code": "%08d" % s.read(Field.U32), "mode": _get_mode(s), "map": _get_string(s),
			"max_players": s.read(Field.U16), "match_time": s.read(Field.U32), "host_role": s.read(Field.U16)}
	var flags: int = s.read(Field.U8)
	data.merge({"in_match": bool(flags & 1), "beta": bool(flags & 2), "can_start": bool(flags & 4),
			"player_collision": bool(flags & 8)})
	var roster: Array = []
	for i in s.count(s.read(Field.U16), 7):
		var player := {"role": s.read(Field.U16), "name": _get_string(s), "team": s.read(Field.U8)}
		if player["team"] > 2:
			s.valid = false
			return {}
		roster.append(player)
	data["players"] = roster
	return data

static func _put_names(s: StreamPeerBuffer, names: Dictionary, hues: Dictionary) -> void:
	s.put_u16(names.size())
	for role in names:
		s.put_u16(role)
		_put_string(s, names[role])
		s.put_double(hues[role])

static func _get_names(s: Reader) -> Dictionary:
	var names := {}
	var hues := {}
	for i in s.count(s.read(Field.U16), 14):
		var role: int = s.read(Field.U16)
		names[role] = _get_string(s)
		hues[role] = s.read(Field.F64)
	return {"names": names, "hues": hues}

static func _put_mask(s: StreamPeerBuffer, mask: int, count: int) -> void:
	for shift in range(0, count, 8): s.put_u8((mask >> shift) & 255)

static func _get_mask(s: Reader, count: int, complete: bool = false) -> int:
	var mask := 0
	for shift in range(0, count, 8):
		mask |= s.read(Field.U8) << shift
	var all_fields := (1 << count) - 1
	if mask > all_fields or (complete and mask != all_fields):
		s.valid = false
	return mask

static func _put_role_map(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u16(data.size())
	for key in data:
		s.put_u16(key)
		s.put_32(data[key])

static func _get_role_map(s: Reader) -> Dictionary:
	var data := {}
	for i in s.count(s.read(Field.U16), 6):
		var key: int = s.read(Field.U16)
		data[key] = s.read(Field.I32)
	return data

static func _put_roles(s: StreamPeerBuffer, ids: Array) -> void:
	s.put_u16(ids.size())
	for id in ids: s.put_u16(id)

static func _get_roles(s: Reader) -> Array:
	var ids: Array = []
	for i in s.count(s.read(Field.U16), 2): ids.append(s.read(Field.U16))
	return ids

static func _put_vec(s: StreamPeerBuffer, value: Vector2) -> void:
	s.put_float(value.x)
	s.put_float(value.y)

static func _put_cell(s: StreamPeerBuffer, value: Vector2i) -> void:
	s.put_32(value.x)
	s.put_32(value.y)

static func _get_cell(s: Reader) -> Vector2i:
	return Vector2i(s.read(Field.I32), s.read(Field.I32))

static func _put_cell_hp(s: StreamPeerBuffer, cells: Dictionary) -> void:
	s.put_u32(cells.size())
	for cell: Vector2i in cells:
		_put_cell(s, cell)
		s.put_32(cells[cell])

static func _get_cell_hp(s: Reader) -> Dictionary:
	var cells := {}
	for i in s.count(s.read(Field.U32), 12):
		var cell := _get_cell(s)
		cells[cell] = s.read(Field.I32)
	return cells

static func _put_string(s: StreamPeerBuffer, value: String) -> void:
	_put_blob(s, value.to_utf8_buffer())

static func _get_string(s: Reader) -> String:
	return _get_blob(s).get_string_from_utf8()

static func _put_blob(s: StreamPeerBuffer, value: PackedByteArray) -> void:
	s.put_u32(value.size())
	s.put_data(value)

static func _get_blob(s: Reader) -> PackedByteArray:
	return s.bytes(s.read(Field.U32))

static func _put_token(s: StreamPeerBuffer, token: String) -> void:
	s.put_u8(int(not token.is_empty()))
	if not token.is_empty(): s.put_data(token.hex_decode())

static func _get_token(s: Reader) -> String:
	return s.bytes(16).hex_encode() if s.read(Field.BOOL) else ""

static func _get_mode(s: Reader) -> String:
	var index: int = s.read(Field.U8)
	if index >= MODES.size():
		s.valid = false
		return ""
	return MODES[index]
