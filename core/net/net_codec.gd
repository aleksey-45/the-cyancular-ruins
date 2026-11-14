class_name NetCodec
extends RefCounted

# 固定小端协议。字段表只描述已知记录，不发送字段名或 Variant 类型。
const INPUT := 0
const STATE := 1
const EVENT := 2
const KEEP := 64
const WIRE_MAGIC := 199
const PROTOCOL_VERSION := 24
const MODES := [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]
const Field := NetEvent.Field
# 持续输入的完整槽位顺序。INPUT 单独写序号和包级 epoch，增量从目标 tick 开始。
const INPUT_FRAME_TYPES := [Field.U32, Field.U32, Field.I32, Field.F64, Field.U16, Field.VEC]
const OWN_FIELDS := [["timing_seq", Field.U32], ["lead", Field.I32]]
const PLAYER_FIELDS := [["epoch", Field.U32], ["action_ack", Field.U32], ["rewind", Field.BOOL],
	["respawn_tick", Field.U32], ["aim", Field.VEC]]
const PlayerSlots := preload("res://core/sim/player_state_schema.gd")
const PROJECTILE_FIELDS := [["type_id", Field.U8], ["pos", Field.VEC], ["vel", Field.VEC]]
const COMBAT_EVENT_FIELDS := {
	NetEvent.Kind.FIRE: [["role", Field.U16], ["tick", Field.U32], ["serial", Field.U32], ["type_id", Field.U8],
		["pos", Field.VEC], ["dir", Field.VEC], ["charge", Field.F64], ["speed_mult", Field.F64]],
	NetEvent.Kind.HIT: [["shooter", Field.U16], ["victim", Field.U16], ["damage", Field.U32],
		["tick", Field.U32], ["epoch", Field.U32], ["hp", Field.I32], ["impulse_mode", Field.I8],
		["pos", Field.VEC], ["facing", Field.I8], ["vel", Field.VEC], ["knock", Field.VEC]],
	NetEvent.Kind.EXPLOSION: [["id", Field.U64], ["tick", Field.U32], ["type_id", Field.U8], ["pos", Field.VEC]],
}
const TIME_FIELDS := [["b", Field.F64], ["w", Field.F64], ["l", Field.F64], ["k", Field.BOOL]]
const OPTIONS := ["map", "max_players", "match_time", "round_full_heal", "disabled_weapons", "beta", "time"]
const STATS := ["kills", "deaths", "assists", "dealt", "taken"]
var state_ack := 0
var serial := 0
var latest := 0
var history: Dictionary = {}
var roles: Array = []
var _history_order: Array[int] = []
var _history_cursor := 0

class Reader extends RefCounted:
	const FIELD_BYTES := {
		Field.U8: 1, Field.I8: 1, Field.BOOL: 1, Field.INVENTORY: 1, Field.U16: 2,
		Field.U32: 4, Field.I32: 4, Field.F32: 4, Field.U64: 8, Field.F64: 8, Field.VEC: 8,
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
			Field.F32, Field.F64:
				var value := _data.decode_float(at) if kind == Field.F32 else _data.decode_double(at)
				valid = is_finite(value)
				return value
			Field.VEC:
				var value := Vector2(_data.decode_float(at), _data.decode_float(at + 4))
				valid = value.is_finite()
				return value
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
	var tick: int
	var map_revision: int
	var world: Dictionary
	var time: Dictionary
	# 历史只保留独立身份，避免批次缓存随历史长期保留。
	var snapshot := RefCounted.new()
	var deltas: Dictionary = {}

	func _init(frame: Dictionary) -> void:
		tick = frame["tick"]
		map_revision = frame["map_revision"]
		# 世界与时间负载每 tick 重新构造，交付后只读；批次与帧共享同一份记录。
		world = frame["world"]
		time = frame["time"]

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
		_put_state(s, frame, previous, INPUT_FRAME_TYPES, InputBuffer.TARGET_TICK)
		previous = frame
	s.put_u8(actions.size())
	for action: Array in actions:
		s.put_u32(action[InputBuffer.SEQ])
		s.put_32(action[InputBuffer.TARGET_TICK])
		s.put_u16(action[InputBuffer.ACTION_PRESSED])
		s.put_u16(action[InputBuffer.ACTION_RELEASED])
		s.put_u32(action[InputBuffer.ACTION_WINST])
		_put_vec(s, action[InputBuffer.ACTION_AIM])

func decode_input(s: Reader) -> Array:
	var ack: int = s.read(Field.U32)
	var epoch: int = s.read(Field.U32)
	var count := s.count(s.read(Field.U8), 5) # 序号和至少一字节的增量掩码。
	var frames: Array = []
	var previous: Array = []
	for i in count:
		var seq: int = s.read(Field.U32)
		var frame := _get_state(s, previous, INPUT_FRAME_TYPES, InputBuffer.TARGET_TICK)
		if not s.valid:
			return []
		frame[InputBuffer.SEQ] = seq
		frame[InputBuffer.EPOCH] = epoch
		frames.append(frame)
		previous = frame
	var actions: Array = []
	for i in s.count(s.read(Field.U8), 24):
		actions.append([s.read(Field.U32), epoch, s.read(Field.I32),
			s.read(Field.U16), s.read(Field.U16), s.read(Field.U32), s.read(Field.VEC)])
	if not s.finish():
		return []
	state_ack = 0 if ack == 0 else maxi(state_ack, ack)
	return [frames, actions]

func encode_state(frame: Dictionary, batch: StateBatch) -> PackedByteArray:
	if roles.is_empty():
		roles = batch.world["players"].keys()
		roles.sort()
	var s := StreamPeerBuffer.new()
	s.put_u8(STATE)
	_write_state(s, frame, batch)
	return s.data_array

func _write_state(s: StreamPeerBuffer, frame: Dictionary, batch: StateBatch) -> void:
	serial += 1
	var base: Dictionary = history.get(state_ack, {})
	s.put_u32(serial)
	s.put_u32(state_ack if not base.is_empty() else 0)
	s.put_u32(batch.tick)
	s.put_u32(batch.map_revision)
	if base.is_empty():
		_put_roles(s, roles)
	var parts := _shared_delta(base, batch)
	var blocks: int = parts["blocks"]
	var block_position := s.get_position()
	s.put_u8(0)
	if blocks & 1: s.put_data(parts["players"])
	if blocks & 2: s.put_data(parts["pickups"])
	var own_position := s.get_position()
	if _put_delta(s, frame["own"], base.get("own", {}), OWN_FIELDS) != 0:
		blocks |= 4
	else:
		s.seek(own_position)
	if blocks & 8: s.put_data(parts["time"])
	if blocks & 16: s.put_data(parts["projectiles"])
	var end := s.get_position()
	s.seek(block_position)
	s.put_u8(blocks)
	s.seek(end)
	s.resize(end)
	_remember(serial, frame, batch)

# 一次广播可复用同基线的公共区块；序列号、ACK 和 own 仍由每条连接独立编码。
func _shared_delta(base: Dictionary, batch: StateBatch) -> Dictionary:
	var key := [null if base.is_empty() else base["_snapshot"], roles]
	if batch.deltas.has(key): return batch.deltas[key]
	var old: Dictionary = base.get("world", {"players": {}, "pickups": {}, "projectiles": {}})
	var old_time: Dictionary = base.get("time", {})
	var result := {"blocks": 0}
	for part in [[1, "players"], [2, "pickups"], [8, "time"], [16, "projectiles"]]:
		var body := StreamPeerBuffer.new()
		var changed := false
		match part[0]:
			1: changed = _write_players(body, batch.world["players"], old["players"])
			2: changed = _write_pickups(body, batch.world["pickups"], old["pickups"])
			8: changed = _put_time(body, batch.time, old_time)
			16: changed = _write_projectile_delta(body, batch.world["projectiles"], old["projectiles"])
		if changed or base.is_empty():
			body.resize(body.get_position())
			result["blocks"] |= part[0]
			result[part[1]] = body.data_array
	batch.deltas[key] = result
	return result

func decode_state(s: Reader, baseline: bool = false) -> Dictionary:
	var number: int = s.read(Field.U32)
	var base_number: int = s.read(Field.U32)
	var frame := {"tick": s.read(Field.U32), "map_revision": s.read(Field.U32)}
	if not s.valid or (baseline and (base_number != 0 or number <= latest)):
		s.valid = false
		return {}
	if number <= latest:
		return {}
	var frame_roles := _get_roles(s) if base_number == 0 else roles
	var blocks := _get_mask(s, 5, base_number == 0)
	if not s.valid or frame_roles.size() > TeamRules.MAX_TOTAL:
		s.valid = false
		return {}
	var base: Dictionary = history.get(base_number, {})
	if base_number != 0 and base.is_empty():
		state_ack = 0 # 增量基线缺失，下次 INPUT 请求全量。
		return {}
	# 历史归解码器所有，只读复用未变记录；写入某个区块前先复制其索引表。
	# 返回的帧与历史共用未变容器：交付后只读，调用方不得原地修改。
	var world: Dictionary = base.get("world", {"players": {}, "pickups": {}, "projectiles": {}}).duplicate()
	if blocks & 1:
		world["players"] = world["players"].duplicate()
		_read_players(s, world["players"], frame_roles)
	if blocks & 2:
		world["pickups"] = world["pickups"].duplicate()
		_read_pickups(s, world["pickups"])
	frame["world"] = world
	frame["own"] = _get_delta(s, base.get("own", {}), OWN_FIELDS) if blocks & 4 else base["own"]
	frame["time"] = _get_time(s, base.get("time", {})) if blocks & 8 else base["time"]
	if blocks & 16:
		world["projectiles"] = world["projectiles"].duplicate()
		_read_projectile_delta(s, world["projectiles"])
	if not s.finish():
		return {}
	if baseline:
		history.clear()
	roles = frame_roles
	latest = number
	state_ack = number
	_store_history(number, frame)
	return frame

func _remember(number: int, frame: Dictionary, batch: StateBatch) -> void:
	_store_history(number, {"tick": batch.tick, "map_revision": batch.map_revision,
			"world": batch.world, "time": batch.time, "_snapshot": batch.snapshot,
			"own": frame["own"]})

# 只接纳已拥有的快照；历史内的嵌套记录此后不能原地修改。
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

func encode_event(kind: int, data: Variant) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(EVENT + kind)
	match kind:
		NetEvent.Kind.HELLO:
			_put_string(s, data["name"])
			s.put_double(data["hue"])
		NetEvent.Kind.CREATE:
			s.put_u8(MODES.find(data["mode"]))
			_put_options(s, data["options"])
		NetEvent.Kind.JOIN:
			s.put_u32(int(data["code"]))
			s.put_u8(int(data["beta"]))
		NetEvent.Kind.LIST:
			s.put_u8(int(data))
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
		NetEvent.Kind.ROOM_LIST:
			s.put_u8(int(not data.is_empty()))
			if not data.is_empty():
				_put_room(s, data)
		NetEvent.Kind.BASELINE:
			history.clear()
			state_ack = 0
			roles = data["frame"]["world"]["players"].keys()
			roles.sort()
			s.put_u32(int(data["code"]))
			s.put_u8(MODES.find(data["mode"]))
			s.put_u16(data["role"])
			_put_options(s, data["options"])
			_put_names(s, data["names"], data["hues"])
			_put_int_map(s, data["teams"])
			_put_blob(s, data["map"])
			s.put_u32(data["sub_hp"].size())
			for cell in data["sub_hp"]:
				_put_cell(s, cell)
				s.put_32(data["sub_hp"][cell])
			_put_round(s, data["round_state"])
			_write_state(s, data["frame"], StateBatch.new(data["frame"]))
		NetEvent.Kind.TERRAIN:
			s.put_u32(data["tick"])
			s.put_u32(data["revision"])
			s.put_u32(data["cells"].size())
			for sub: Vector2i in data["cells"]:
				_put_cell(s, sub)
				s.put_32(data["cells"][sub])
		NetEvent.Kind.ROUND:
			_put_round(s, data)
		NetEvent.Kind.HIT, NetEvent.Kind.FIRE, NetEvent.Kind.EXPLOSION:
			for field in COMBAT_EVENT_FIELDS[kind]:
				_write_value(s, field[1], data[field[0]])
		NetEvent.Kind.KILL:
			s.put_u16(data[0])
			s.put_u16(data[1])
		NetEvent.Kind.BULLET_END:
			s.put_u32(data["tick"])
			s.put_u16(data["ids"].size())
			for id in data["ids"]: s.put_u64(id)
	return s.data_array

func decode_event(kind: int, s: Reader) -> Variant:
	var payload: Variant = _read_event(kind, s)
	return payload if s.finish() else null

func _read_event(kind: int, s: Reader) -> Variant:
	match kind:
		NetEvent.Kind.HELLO: return {"name": _get_string(s), "hue": s.read(Field.F64)}
		NetEvent.Kind.CREATE: return {"mode": _get_mode(s), "options": _get_options(s)}
		NetEvent.Kind.JOIN: return {"code": "%08d" % s.read(Field.U32), "beta": s.read(Field.BOOL)}
		NetEvent.Kind.LIST: return s.read(Field.BOOL)
		NetEvent.Kind.REJOIN: return {"code": "%08d" % s.read(Field.U32), "token": _get_token(s)}
		NetEvent.Kind.PICK_TEAM, NetEvent.Kind.READY: return s.read(Field.U32)
		NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED: return _get_string(s)
		NetEvent.Kind.ROOM:
			var room := _get_room(s)
			room.merge({"your_role": s.read(Field.U16), "token": _get_token(s)})
			return room
		NetEvent.Kind.ROOM_LIST:
			return _get_room(s) if s.read(Field.BOOL) else {}
		NetEvent.Kind.BASELINE:
			var data := {"code": "%08d" % s.read(Field.U32), "mode": _get_mode(s),
				"role": s.read(Field.U16), "options": _get_options(s)}
			data.merge(_get_names(s))
			data["teams"] = _get_int_map(s)
			data["map"] = _get_blob(s)
			var hp := {}
			for i in s.count(s.read(Field.U32), 12):
				var cell := _get_cell(s)
				hp[cell] = s.read(Field.I32)
			data["sub_hp"] = hp
			data["round_state"] = _get_round(s)
			data["frame"] = decode_state(s, true)
			return data
		NetEvent.Kind.TERRAIN:
			var tick: int = s.read(Field.U32)
			var revision: int = s.read(Field.U32)
			var cells := {}
			for i in s.count(s.read(Field.U32), 12):
				var sub := _get_cell(s)
				cells[sub] = s.read(Field.I32)
			return {"tick": tick, "revision": revision, "cells": cells}
		NetEvent.Kind.ROUND: return _get_round(s)
		NetEvent.Kind.HIT, NetEvent.Kind.FIRE, NetEvent.Kind.EXPLOSION:
			var data := {"kind": "fire"} if kind == NetEvent.Kind.FIRE else {}
			for field in COMBAT_EVENT_FIELDS[kind]:
				data[field[0]] = s.read(field[1])
			return data
		NetEvent.Kind.KILL: return [s.read(Field.U16), s.read(Field.U16)]
		NetEvent.Kind.BULLET_END:
			var tick: int = s.read(Field.U32)
			var ids: Array[int] = []
			for i in s.count(s.read(Field.U16), 8): ids.append(s.read(Field.U64))
			return {"tick": tick, "ids": ids}
		NetEvent.Kind.LEAVE, NetEvent.Kind.START, NetEvent.Kind.SUICIDE:
			return null
	s.valid = false
	return null

func _write_players(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var start := s.get_position()
	_put_mask(s, 0, roles.size())
	_put_mask(s, 0, roles.size())
	var present := 0
	var changed := 0
	var removed := false
	for i in roles.size():
		var role: int = roles[i]
		if not current.has(role):
			removed = removed or base.has(role)
			continue
		present |= 1 << i
		var position := s.get_position()
		if _put_player(s, current[role], base.get(role, {})):
			changed |= 1 << i
		else:
			s.seek(position)
	var end := s.get_position()
	s.seek(start)
	_put_mask(s, present, roles.size())
	_put_mask(s, changed, roles.size())
	s.seek(end)
	return changed != 0 or removed

func _read_players(s: Reader, players: Dictionary, frame_roles: Array) -> void:
	var present := _get_mask(s, frame_roles.size())
	var changed := _get_mask(s, frame_roles.size())
	if changed & ~present:
		s.valid = false
		return
	for i in frame_roles.size():
		var role: int = frame_roles[i]
		var bit := 1 << i
		if not present & bit:
			players.erase(role)
		elif changed & bit:
			players[role] = _get_player(s, players.get(role, {}))
		elif not players.has(role):
			s.valid = false
			return

func _write_pickups(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var removed := _put_removed(s, current, base, 4)
	var count_position := s.get_position()
	s.put_u16(0)
	var changed := 0
	for id in current:
		var data: Array = current[id]
		var old: Array = base.get(id, [])
		var mask := 0
		if data[PickupState.POS] != _state_value(old, PickupState.POS): mask |= 1
		if data[PickupState.VEL] != _state_value(old, PickupState.VEL): mask |= 2
		if (data[PickupState.TYPE_ID] != _state_value(old, PickupState.TYPE_ID)
				or data[PickupState.CARRIED] != _state_value(old, PickupState.CARRIED)): mask |= 4
		if mask == 0: continue
		changed += 1
		s.put_u32(id)
		s.put_u8(mask)
		if mask & 1: _put_vec(s, data[PickupState.POS])
		if mask & 2: _put_vec(s, data[PickupState.VEL])
		if mask & 4:
			s.put_u8(data[PickupState.TYPE_ID])
			s.put_32(data[PickupState.CARRIED])
	if changed != 0: _patch_count(s, count_position, changed)
	return removed != 0 or changed != 0

func _read_pickups(s: Reader, entities: Dictionary) -> void:
	for i in s.count(s.read(Field.U16), 4): entities.erase(s.read(Field.U32))
	for i in s.count(s.read(Field.U16), 5):
		var id: int = s.read(Field.U32)
		var mask: int = s.read(Field.U8)
		var data: Array = entities.get(id, [])
		if not s.valid or mask >= 8 or (data.is_empty() and mask != 7):
			s.valid = false
			return
		var out: Array = []
		out.resize(PickupState.SIZE)
		out[PickupState.POS] = s.read(Field.VEC) if mask & 1 else _state_value(data, PickupState.POS)
		out[PickupState.VEL] = s.read(Field.VEC) if mask & 2 else _state_value(data, PickupState.VEL)
		out[PickupState.TYPE_ID] = s.read(Field.U8) if mask & 4 else _state_value(data, PickupState.TYPE_ID)
		out[PickupState.CARRIED] = s.read(Field.I32) if mask & 4 else _state_value(data, PickupState.CARRIED)
		entities[id] = out

func _write_projectile_delta(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var removed := _put_removed(s, current, base, 8)
	s.put_u16(current.size())
	for id in current:
		s.put_u64(id)
		# 持续运动的数据直接发送；相同值也是合法增量，低频字段继续省略。
		_put_delta(s, current[id], base.get(id, {}), PROJECTILE_FIELDS)
	return removed != 0 or not current.is_empty()

func _read_projectile_delta(s: Reader, current: Dictionary) -> void:
	for i in s.count(s.read(Field.U16), 8): current.erase(s.read(Field.U64))
	for i in s.count(s.read(Field.U16), 9):
		var id: int = s.read(Field.U64)
		current[id] = _get_delta(s, current.get(id, {}), PROJECTILE_FIELDS)

static func _put_player(s: StreamPeerBuffer, player: Dictionary, base: Dictionary) -> bool:
	var changed := _put_delta(s, player, base, PLAYER_FIELDS) != 0
	var input := _put_state(s, player["input"], base.get("input", []), INPUT_FRAME_TYPES)
	var state: Dictionary = player["state"]
	var old: Dictionary = base.get("state", {})
	var actor: Array = state["actor"]
	var old_actor: Array = old.get("actor", [])
	var mask := _put_state(s, actor, old_actor, PlayerSlots.ACTOR_TYPES)
	var equipment: Array = state["equipment"]
	s.put_u8(int(not equipment.is_empty()))
	var equipment_mask := 0
	if not equipment.is_empty():
		equipment_mask = _put_state(s, equipment, _equipment_base(actor, old), PlayerSlots.EQUIPMENT_TYPES)
	return changed or input != 0 or mask != 0 or equipment_mask != 0

static func _get_player(s: Reader, base: Dictionary) -> Dictionary:
	var player := _get_delta(s, base, PLAYER_FIELDS)
	player["input"] = _get_state(s, base.get("input", []), INPUT_FRAME_TYPES)
	var old: Dictionary = base.get("state", {})
	var actor := _get_state(s, old.get("actor", []), PlayerSlots.ACTOR_TYPES)
	var equipment: Array = []
	if s.read(Field.BOOL):
		equipment = _get_state(s, _equipment_base(actor, old), PlayerSlots.EQUIPMENT_TYPES)
	player["state"] = {"actor": actor, "equipment": equipment}
	return player

static func _equipment_base(actor: Array, previous: Dictionary) -> Array:
	var slot := PlayerSlots.WEAPON_INST
	var old: Array = previous.get("actor", [])
	return previous["equipment"] if actor[slot] == _state_value(old, slot) else []

static func _state_value(source: Array, slot: int) -> Variant:
	return source[slot] if slot < source.size() else null

static func _put_state(s: StreamPeerBuffer, data: Array, base: Array, types: Array, first_slot: int = 0) -> int:
	assert(data.size() == types.size())
	var start := s.get_position()
	var size := types.size()
	var count := size - first_slot
	_put_mask(s, 0, count)
	var mask := 0
	for slot in range(first_slot, size):
		var value: Variant = data[slot]
		if value == _state_value(base, slot): continue
		mask |= 1 << (slot - first_slot)
		_write_value(s, types[slot], value)
	if mask != 0:
		var end := s.get_position()
		s.seek(start)
		_put_mask(s, mask, count)
		s.seek(end)
	return mask

static func _get_state(s: Reader, base: Array, types: Array, first_slot: int = 0) -> Array:
	var size := types.size()
	var mask := _get_mask(s, size - first_slot, base.is_empty())
	if not s.valid:
		return []
	var out: Array = []
	out.resize(size)
	for slot in range(first_slot, size):
		out[slot] = s.read(types[slot]) if mask & (1 << (slot - first_slot)) else _state_value(base, slot)
	return out

static func _put_time(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var removed := _put_removed(s, current, base, 2)
	var count_position := s.get_position()
	s.put_u16(0)
	var changed := 0
	for role in current:
		var position := s.get_position()
		s.put_u16(role)
		if _put_delta(s, current[role], base.get(role, {}), TIME_FIELDS) != 0:
			changed += 1
		else:
			s.seek(position)
	if changed != 0: _patch_count(s, count_position, changed)
	return removed != 0 or changed != 0

static func _get_time(s: Reader, base: Dictionary) -> Dictionary:
	var result := base.duplicate()
	for role in _get_roles(s): result.erase(role)
	for i in s.count(s.read(Field.U16), 3):
		var role: int = s.read(Field.U16)
		result[role] = _get_delta(s, base.get(role, {}), TIME_FIELDS)
	return result

# 增量表和状态槽共用写入规则。
static func _write_value(s: StreamPeerBuffer, kind: int, value: Variant) -> void:
	match kind:
		Field.U8, Field.BOOL: s.put_u8(int(value))
		Field.I8: s.put_8(value)
		Field.U16: s.put_u16(value)
		Field.I32: s.put_32(value)
		Field.U32: s.put_u32(value)
		Field.U64: s.put_u64(value)
		Field.F64: s.put_double(value)
		Field.VEC: _put_vec(s, value)
		Field.INVENTORY:
			s.put_u8(value.size() / WeaponInventory.STRIDE)
			for i in range(0, value.size(), WeaponInventory.STRIDE):
				s.put_u32(value[i + WeaponInventory.INST])
				s.put_u8(value[i + WeaponInventory.TYPE])
				s.put_32(value[i + WeaponInventory.CARRIED])

static func _put_delta(s: StreamPeerBuffer, data: Dictionary, base: Dictionary, fields: Array) -> int:
	var start := s.get_position()
	_put_mask(s, 0, fields.size())
	var mask := 0
	for i in fields.size():
		var key: String = fields[i][0]
		var value: Variant = data[key]
		if value == base.get(key): continue
		mask |= 1 << i
		_write_value(s, fields[i][1], value)
	if mask != 0:
		var end := s.get_position()
		s.seek(start)
		_put_mask(s, mask, fields.size())
		s.seek(end)
	return mask

static func _put_removed(s: StreamPeerBuffer, current: Dictionary, base: Dictionary, id_bytes: int) -> int:
	var position := s.get_position()
	s.put_u16(0)
	var removed := 0
	for id in base:
		if current.has(id): continue
		removed += 1
		match id_bytes:
			2: s.put_u16(id)
			4: s.put_u32(id)
			8: s.put_u64(id)
	if removed != 0: _patch_count(s, position, removed)
	return removed

static func _patch_count(s: StreamPeerBuffer, position: int, count: int) -> void:
	var end := s.get_position()
	s.seek(position)
	s.put_u16(count)
	s.seek(end)

static func _get_delta(s: Reader, base: Dictionary, fields: Array) -> Dictionary:
	var mask := _get_mask(s, fields.size(), base.is_empty())
	if not s.valid:
		return {}
	var data := {}
	for i in fields.size():
		var key: String = fields[i][0]
		data[key] = s.read(fields[i][1]) if mask & (1 << i) else base[key]
	return data

static func _time_rule_type(field: String) -> int:
	return Field.U32 if TimeRules.FIELDS[field][TimeRules.DEFAULT] is int else Field.F64

static func _put_options(s: StreamPeerBuffer, data: Dictionary) -> void:
	var mask := 0
	for i in OPTIONS.size():
		if data.has(OPTIONS[i]): mask |= 1 << i
	s.put_u16(mask)
	for i in OPTIONS.size():
		if not mask & (1 << i): continue
		var value: Variant = data[OPTIONS[i]]
		match OPTIONS[i]:
			"round_full_heal", "beta": s.put_u8(int(value))
			"map": _put_string(s, value)
			"max_players", "match_time": s.put_u32(value)
			"disabled_weapons":
				s.put_u8(value.size())
				for id in value: s.put_u8(id)
			"time":
				s.put_u8(int(not value.is_empty()))
				if not value.is_empty():
					for field in TimeRules.FIELDS:
						_write_value(s, _time_rule_type(field), value[field])

static func _get_options(s: Reader) -> Dictionary:
	var mask: int = s.read(Field.U16)
	if mask >> OPTIONS.size():
		s.valid = false
		return {}
	var data := {}
	for i in OPTIONS.size():
		if not mask & (1 << i): continue
		var key: String = OPTIONS[i]
		match key:
			"round_full_heal", "beta": data[key] = s.read(Field.BOOL)
			"map": data[key] = _get_string(s)
			"max_players", "match_time": data[key] = s.read(Field.U32)
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
	return data

static func _put_room(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u32(int(data["code"]))
	s.put_u8(MODES.find(data["mode"]))
	_put_string(s, data["map"])
	s.put_u16(data["max_players"])
	s.put_u32(data["match_time"])
	s.put_u16(data["host_role"])
	s.put_u8(int(data["in_match"]) | (int(data["beta"]) << 1) | (int(data["can_start"]) << 2))
	s.put_u16(data["players"].size())
	for player: Dictionary in data["players"]:
		s.put_u16(player["role"])
		_put_string(s, player["name"])
		s.put_u8(player["team"])

static func _get_room(s: Reader) -> Dictionary:
	var data := {"code": "%08d" % s.read(Field.U32), "mode": _get_mode(s), "map": _get_string(s),
			"max_players": s.read(Field.U16), "match_time": s.read(Field.U32), "host_role": s.read(Field.U16)}
	var flags: int = s.read(Field.U8)
	data.merge({"in_match": bool(flags & 1), "beta": bool(flags & 2), "can_start": bool(flags & 4), "host_name": ""})
	var roster: Array = []
	var counts := {0: 0, 1: 0, 2: 0}
	for i in s.count(s.read(Field.U16), 7):
		var player := {"role": s.read(Field.U16), "name": _get_string(s), "team": s.read(Field.U8)}
		if not counts.has(player["team"]):
			s.valid = false
			return {}
		roster.append(player)
		counts[player["team"]] += 1
		if player["role"] == data["host_role"]: data["host_name"] = player["name"]
	data.merge({"players": roster, "team_counts": counts, "count": roster.size()})
	return data

static func _put_round(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u8(data["state"])
	s.put_u32(data["round"])
	s.put_double(data["timer"])
	for key in ["winner", "match_winner", "mvp"]: s.put_u16(data[key])
	for key in ["scores", "rounds_won"]: _put_int_map(s, data[key])
	_put_roles(s, data["left"])
	s.put_u16(data["grace"].size())
	for role in data["grace"]:
		s.put_u16(role)
		s.put_double(data["grace"][role])
	s.put_u16(data["alive"].size())
	for role in data["alive"]:
		s.put_u16(role)
		s.put_u8(int(data["alive"][role]))
	s.put_u16(data["stats"].size())
	for role in data["stats"]:
		s.put_u16(role)
		for key in STATS: s.put_32(data["stats"][role][key])
		s.put_double(data["stats"][role]["acs"])

static func _get_round(s: Reader) -> Dictionary:
	var data := {"state": s.read(Field.U8), "round": s.read(Field.U32), "timer": s.read(Field.F64)}
	for key in ["winner", "match_winner", "mvp"]: data[key] = s.read(Field.U16)
	for key in ["scores", "rounds_won"]: data[key] = _get_int_map(s)
	data["left"] = _get_roles(s)
	var grace := {}
	for i in s.count(s.read(Field.U16), 10):
		var role: int = s.read(Field.U16)
		grace[role] = s.read(Field.F64)
	data["grace"] = grace
	var alive := {}
	for i in s.count(s.read(Field.U16), 3):
		var role: int = s.read(Field.U16)
		alive[role] = s.read(Field.BOOL)
	data["alive"] = alive
	var stats := {}
	for i in s.count(s.read(Field.U16), 2 + STATS.size() * 4 + 8):
		var role: int = s.read(Field.U16)
		var entry := {}
		for key in STATS: entry[key] = s.read(Field.I32)
		entry["acs"] = s.read(Field.F64)
		stats[role] = entry
	data["stats"] = stats
	return data

static func _put_names(s: StreamPeerBuffer, names: Dictionary, hues: Dictionary) -> void:
	s.put_u16(names.size())
	for role in names:
		s.put_u16(role)
		_put_string(s, names[role])
		s.put_u8(int(hues.has(role)))
		if hues.has(role): s.put_double(hues[role])

static func _get_names(s: Reader) -> Dictionary:
	var names := {}
	var hues := {}
	for i in s.count(s.read(Field.U16), 7):
		var role: int = s.read(Field.U16)
		names[role] = _get_string(s)
		if s.read(Field.BOOL): hues[role] = s.read(Field.F64)
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

static func _put_int_map(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u16(data.size())
	for key in data:
		s.put_u16(key)
		s.put_32(data[key])

static func _get_int_map(s: Reader) -> Dictionary:
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
