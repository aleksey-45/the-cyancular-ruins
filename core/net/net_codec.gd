class_name NetCodec
extends RefCounted

# 固定小端协议。字段表只描述已知记录，不发送字段名或 Variant 类型。
const INPUT := 0
const STATE := 1
const EVENT := 2
const KEEP := 64
const WIRE_MAGIC := 199
const PROTOCOL_VERSION := 3
const MODES := [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]
enum Field { U8, I8, U16, I32, U32, F64, VEC, BOOL, INVENTORY, DRIVER, RECORD, PATH }
const INPUT_FIELDS := [["target_tick", Field.I32], ["view_tick", Field.I32], ["ax", Field.F64], ["held", Field.U16], ["aim", Field.VEC]]
const ACTOR_FIELDS := [
	["pos", Field.VEC], ["vel", Field.VEC], ["knock", Field.VEC], ["aim", Field.VEC], ["facing", Field.I8], ["pose", Field.U8],
	["type_id", Field.U8], ["hp", Field.I32], ["waterproof", Field.I32], ["epoch", Field.U32],
	["downed", Field.BOOL], ["previewing", Field.BOOL], ["haste", Field.BOOL], ["rewind", Field.BOOL],
	["floor", Field.BOOL], ["jcut", Field.BOOL], ["squat", Field.BOOL], ["charge", Field.BOOL],
	["clatch", Field.BOOL], ["swim", Field.BOOL], ["haste_mult", Field.F64],
	["slock", Field.F64], ["coyote", Field.F64], ["jbuf", Field.F64], ["ct", Field.F64],
	["lmv_d", Field.I8], ["lmv_t", Field.F64], ["axis", Field.F64], ["held", Field.U16], ["move_mult", Field.VEC],
	["respawn_tick", Field.U32],
	["input_ack", Field.U32], ["action_ack", Field.U32], ["input_age", Field.U8],
	["driver", Field.DRIVER], ["input", Field.RECORD],
	["rewind_path", Field.PATH],
]
const OWN_FIELDS := [["epoch", Field.U32], ["ack", Field.U32], ["action_ack", Field.U32], ["timing_seq", Field.U32], ["lead", Field.I32], ["rewind", Field.BOOL]]
const OWN_INPUT_FIELDS := [["seq", Field.U32], ["epoch", Field.U32], ["target_tick", Field.I32], ["view_tick", Field.I32], ["ax", Field.F64], ["held", Field.U16], ["aim", Field.VEC]]
const OWN_STATE_FIELDS := [
	["floor", Field.BOOL], ["jcut", Field.BOOL], ["squat", Field.BOOL], ["charge", Field.BOOL],
	["wp_s", Field.BOOL], ["clatch", Field.BOOL], ["swim", Field.BOOL], ["down", Field.BOOL],
	["pos", Field.VEC], ["vel", Field.VEC], ["knock", Field.VEC],
	["haste_mult", Field.F64], ["slock", Field.F64], ["coyote", Field.F64], ["jbuf", Field.F64], ["ct", Field.F64],
	["lmv_t", Field.F64], ["wp_t", Field.F64], ["wp_d", Field.F64], ["ifr", Field.F64],
	["wp", Field.I32], ["shot_serial", Field.U32], ["facing", Field.I8], ["state", Field.U8], ["lmv_d", Field.I8],
	["hp", Field.I32], ["winst", Field.U32], ["inv", Field.INVENTORY],
	["locked", Field.BOOL],
]
const DRIVER_FIELDS := [
	["wp_s", Field.BOOL], ["locked", Field.BOOL], ["wp_t", Field.F64], ["wp_d", Field.F64],
	["ifr", Field.F64], ["shot_serial", Field.U32], ["winst", Field.U32], ["inv", Field.INVENTORY],
]
const PROJECTILE_FIELDS := [
	["type_id", Field.U8], ["pos", Field.VEC], ["vel", Field.VEC], ["traveled", Field.F64],
	["fuse_active", Field.BOOL], ["fuse_elapsed", Field.F64], ["fuse_duration", Field.F64], ["direct_hit", Field.BOOL],
]
const PROJECTILE_MOTION_MASK := (1 << 1) | (1 << 3)
const WEAPON_FIELDS := [
	["aiming", Field.BOOL], ["fire_buf", Field.BOOL], ["rld", Field.BOOL], ["fire_cd", Field.F64],
	["rld_t", Field.F64], ["aim_f", Field.I8], ["aim_cf", Field.I8], ["mag", Field.I32],
]
const TIME_FIELDS := [["b", Field.F64], ["w", Field.F64], ["l", Field.F64], ["win", Field.F64], ["m", Field.F64], ["cap", Field.I32], ["k", Field.BOOL]]
const OPTIONS := ["is_public", "invite_code", "map", "max_players", "match_time", "round_full_heal", "disabled_weapons", "beta", "time", "hue"]
const TIME_RULES := ["initial", "cap", "rewind_burn", "haste_burn", "window", "regen", "kill_ratio", "haste_mult"]
const STATS := ["kills", "deaths", "assists", "dealt", "taken", "kscore"]
var state_ack := 0
var serial := 0
var latest := 0
var history: Dictionary = {}
var roles: Array = []
var diagnostics := {"full": 0, "delta": 0, "stale": 0, "missing_base": 0, "serial_skips": 0}
var _received_serial := 0
var _history_order: Array[int] = []
var _history_cursor := 0

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
		world = frame["world"].duplicate(true)
		time = frame["time"].duplicate(true)

func encode_input(packet: Dictionary) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(INPUT)
	s.put_u32(state_ack)
	_write_input(s, packet)
	return s.data_array

func encode_input_hints(hints: Dictionary) -> PackedByteArray:
	var encoded := {}
	for role in hints:
		encoded[role] = encode_input_hint(role, hints[role])
	return pack_input_hints(encoded)

# 角色记录内部的增量只依赖本条记录；接收者只影响整包排除哪个角色。
func encode_input_hint(role: int, hint: Dictionary) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(role)
	s.put_u32(hint["tick"])
	_write_input(s, hint["packet"], true)
	return s.data_array

static func pack_input_hints(encoded: Dictionary, except_role: int = 0) -> PackedByteArray:
	var bytes := PackedByteArray([INPUT, encoded.size() - int(encoded.has(except_role))])
	for role in encoded:
		if role != except_role: bytes.append_array(encoded[role])
	return bytes

func decode_input_hints(s: StreamPeerBuffer) -> Dictionary:
	var hints := {}
	for i in s.get_u8():
		var role := s.get_u8()
		hints[role] = {"tick": s.get_u32(), "packet": read_input(s, true)}
	return hints

func _write_input(s: StreamPeerBuffer, packet: Dictionary, scheduled: bool = false) -> void:
	var frames: Array = packet["frames"]
	var actions: Array = packet["actions"]
	var epoch: int = frames[0]["epoch"] if not frames.is_empty() else (actions[0]["epoch"] if not actions.is_empty() else 1)
	s.put_u32(epoch)
	s.put_u8(frames.size())
	var previous := {}
	for frame: Dictionary in frames:
		s.put_u32(frame["seq"])
		_put_delta(s, frame, previous, INPUT_FIELDS)
		if scheduled: _put_available_tick(s, frame)
		previous = frame
	s.put_u8(actions.size())
	for action: Dictionary in actions:
		s.put_u32(action["seq"])
		_put_input_time(s, action)
		if scheduled: _put_available_tick(s, action)
		s.put_u16(action["pressed"])
		s.put_u16(action["released"])
		s.put_u32(action["winst"])
		_put_vec(s, action["aim"])

func decode_input(s: StreamPeerBuffer) -> Dictionary:
	var ack := s.get_u32()
	state_ack = 0 if ack == 0 else maxi(state_ack, ack)
	return read_input(s)

func read_input(s: StreamPeerBuffer, scheduled: bool = false) -> Dictionary:
	var epoch := s.get_u32()
	var count := s.get_u8()
	var frames: Array = []
	var previous := {}
	for i in count:
		var seq := s.get_u32()
		var frame := _get_delta(s, previous, INPUT_FIELDS)
		frame.merge({"seq": seq, "epoch": epoch})
		if scheduled: _get_available_tick(s, frame)
		frames.append(frame)
		previous = frame
	var actions: Array = []
	for i in s.get_u8():
		var action := {"seq": s.get_u32(), "epoch": epoch}
		action.merge(_get_input_time(s))
		if scheduled: _get_available_tick(s, action)
		action.merge({"pressed": s.get_u16(), "released": s.get_u16(), "winst": s.get_u32(), "aim": _get_vec(s)})
		actions.append(action)
	return {"frames": frames, "actions": actions}

static func _put_available_tick(s: StreamPeerBuffer, record: Dictionary) -> void:
	var delayed: bool = record["available_tick"] != record["target_tick"]
	s.put_u8(int(delayed))
	if delayed: s.put_u32(record["available_tick"])

static func _get_available_tick(s: StreamPeerBuffer, record: Dictionary) -> void:
	record["available_tick"] = s.get_u32() if s.get_u8() != 0 else record["target_tick"]

func encode_state(frame: Dictionary, batch: StateBatch = null) -> PackedByteArray:
	if batch == null: batch = StateBatch.new(frame)
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
	if _put_own(s, frame["own"], base.get("own", {})):
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

func decode_state(s: StreamPeerBuffer) -> Dictionary:
	var number := s.get_u32()
	var base_number := s.get_u32()
	if _received_serial > 0 and number > _received_serial:
		diagnostics["serial_skips"] += number - _received_serial - 1
	_received_serial = maxi(_received_serial, number)
	if number <= latest:
		diagnostics["stale"] += 1
		return {}
	if base_number != 0 and not history.has(base_number):
		diagnostics["missing_base"] += 1
		state_ack = 0 # 下次 INPUT 请求独立全量快照。
		return {}
	diagnostics["full" if base_number == 0 else "delta"] += 1
	var base: Dictionary = history.get(base_number, {})
	var frame := {"tick": s.get_u32(), "map_revision": s.get_u32()}
	if base_number == 0:
		roles = _get_roles(s)
	# 历史归解码器所有，只读复用未变记录；写入某个区块前先复制其索引表。
	# 对外返回时统一深拷贝，调用方仍可自由修改，不能反向污染任何历史基线。
	var world: Dictionary = base.get("world", {"players": {}, "pickups": {}, "projectiles": {}}).duplicate()
	var blocks := s.get_u8()
	if blocks & 1:
		world["players"] = world["players"].duplicate()
		_read_players(s, world["players"])
	if blocks & 2:
		world["pickups"] = world["pickups"].duplicate()
		_read_pickups(s, world["pickups"])
	frame["world"] = world
	frame["own"] = _get_own(s, base.get("own", {})) if blocks & 4 else base["own"]
	frame["time"] = _get_time(s, base.get("time", {})) if blocks & 8 else base["time"]
	if blocks & 16:
		world["projectiles"] = world["projectiles"].duplicate()
		_read_projectile_delta(s, world["projectiles"])
	latest = number
	state_ack = number
	_store_history(number, frame)
	return frame.duplicate(true)

func _remember(number: int, frame: Dictionary, batch: StateBatch) -> void:
	_store_history(number, {"tick": batch.tick, "map_revision": batch.map_revision,
			"world": batch.world, "time": batch.time, "_snapshot": batch.snapshot,
			"own": frame["own"].duplicate(true)})

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
			_put_string(s, data["invite"])
			s.put_u8(int(data["beta"]))
		NetEvent.Kind.LIST:
			_put_token(s, data["token"])
			s.put_u8(int(data["beta"]))
		NetEvent.Kind.REJOIN:
			s.put_u32(int(data["code"]))
			_put_token(s, data["token"])
		NetEvent.Kind.PICK_TEAM, NetEvent.Kind.START, NetEvent.Kind.READY:
			s.put_u32(data)
		NetEvent.Kind.MAP, NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED:
			_put_string(s, data)
		NetEvent.Kind.ROOM:
			_put_room(s, data)
			_put_string(s, data["invite_code"])
			s.put_u16(data["your_role"])
			_put_token(s, data["token"])
		NetEvent.Kind.ROOMS:
			s.put_u8(data.size())
			for room: Dictionary in data:
				_put_room(s, room)
				s.put_u8(int(room["joinable"]) | (int(room["rejoinable"]) << 1))
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
			s.put_u16(data["spawns"].size())
			for role in data["spawns"]:
				s.put_u16(role)
				_put_cell(s, data["spawns"][role])
			_put_blob(s, data["map"])
			s.put_u32(data["sub_hp"].size())
			for cell in data["sub_hp"]:
				_put_cell(s, cell)
				s.put_32(data["sub_hp"][cell])
			_put_round(s, data["round_state"])
			_write_state(s, data["frame"], StateBatch.new(data["frame"]))
			_put_projectiles(s, data["projectiles"])
		NetEvent.Kind.TERRAIN:
			s.put_u32(data["tick"])
			s.put_u32(data["revision"])
			s.put_u32(data["cells"].size())
			for sub: Vector2i in data["cells"]:
				_put_cell(s, sub)
				s.put_32(data["cells"][sub])
		NetEvent.Kind.ROUND:
			_put_round(s, data)
		NetEvent.Kind.HIT:
			s.put_u16(data["shooter"])
			s.put_u16(data["victim"])
			s.put_u32(data["damage"])
			_put_vec(s, data["pos"])
			s.put_u64(data["id"])
			s.put_u32(data["tick"])
			s.put_u8(data["source"])
			_put_vec(s, data["knock"])
			s.put_32(data["hp"])
			s.put_8(data["facing"])
		NetEvent.Kind.KILL:
			s.put_u16(data[0])
			s.put_u16(data[1])
		NetEvent.Kind.BEAM:
			s.put_u64(data["id"])
			s.put_u32(data["tick"])
			s.put_u8(data["type_id"])
			s.put_u16(data["shooter_role"])
			s.put_u16(data["pts"].size())
			for point: Vector2 in data["pts"]:
				_put_vec(s, point)
			_put_vec(s, data["canonical"])
			_put_color(s, data["color"])
			s.put_double(data["half_width"])
			s.put_double(data["lifetime"])
			s.put_u8(data["style"])
		NetEvent.Kind.FIRE:
			s.put_u16(data["role"])
			s.put_u32(data["shot"])
			s.put_u8(data["type_id"])
			_put_string(s, data["sound"])
		NetEvent.Kind.BULLET_SPAWN:
			s.put_u64(data["id"])
			s.put_u32(data["tick"])
			_put_projectile(s, data)
		NetEvent.Kind.BULLET_REWIND:
			s.put_u16(data["role"])
			s.put_u32(data["tick"])
			s.put_u8(int(data["rewind"]))
			_put_projectiles(s, data["projectiles"])
		NetEvent.Kind.EXPLOSION:
			s.put_u64(data["id"])
			s.put_u8(data["type_id"])
			_put_vec(s, data["pos"])
			s.put_u32(data["tick"])
		NetEvent.Kind.BULLET_FUSE:
			s.put_u32(data["tick"])
			_put_projectiles(s, data["projectiles"])
		NetEvent.Kind.BULLET_END:
			s.put_u32(data["tick"])
			s.put_u16(data["ids"].size())
			for id in data["ids"]: s.put_u64(id)
		NetEvent.Kind.TIME_REWARD:
			s.put_u32(data["tick"])
			s.put_u32(data["serial"])
			s.put_32(data["phase"])
			s.put_u16(data["role"])
			s.put_u32(data["amount"])
	return s.data_array

func decode_event(kind: int, s: StreamPeerBuffer) -> Variant:
	match kind:
		NetEvent.Kind.HELLO: return {"name": _get_string(s), "hue": s.get_double()}
		NetEvent.Kind.CREATE: return {"mode": MODES[s.get_u8()], "options": _get_options(s)}
		NetEvent.Kind.JOIN: return {"code": "%08d" % s.get_u32(), "invite": _get_string(s), "beta": bool(s.get_u8())}
		NetEvent.Kind.LIST: return {"token": _get_token(s), "beta": bool(s.get_u8())}
		NetEvent.Kind.REJOIN: return {"code": "%08d" % s.get_u32(), "token": _get_token(s)}
		NetEvent.Kind.PICK_TEAM, NetEvent.Kind.START, NetEvent.Kind.READY: return s.get_u32()
		NetEvent.Kind.MAP, NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED: return _get_string(s)
		NetEvent.Kind.ROOM:
			var room := _get_room(s)
			room.merge({"invite_code": _get_string(s), "your_role": s.get_u16(), "token": _get_token(s)})
			return room
		NetEvent.Kind.ROOMS:
			var rooms: Array = []
			for i in s.get_u8():
				var room := _get_room(s)
				var flags := s.get_u8()
				room.merge({"joinable": bool(flags & 1), "rejoinable": bool(flags & 2)})
				rooms.append(room)
			return rooms
		NetEvent.Kind.BASELINE:
			history.clear()
			var data := {"code": "%08d" % s.get_u32(), "mode": MODES[s.get_u8()], "role": s.get_u16(), "options": _get_options(s)}
			data.merge(_get_names(s))
			data["teams"] = _get_int_map(s)
			var spawns := {}
			for i in s.get_u16():
				var role := s.get_u16()
				spawns[role] = _get_cell(s)
			data["spawns"] = spawns
			data["map"] = _get_blob(s)
			var hp := {}
			for i in s.get_u32():
				var cell := _get_cell(s)
				hp[cell] = s.get_32()
			data["sub_hp"] = hp
			data["round_state"] = _get_round(s)
			data["frame"] = decode_state(s)
			data["projectiles"] = _get_projectiles(s)
			return data
		NetEvent.Kind.TERRAIN:
			var tick := s.get_u32()
			var revision := s.get_u32()
			var cells := {}
			for i in s.get_u32():
				var sub := _get_cell(s)
				cells[sub] = s.get_32()
			return {"tick": tick, "revision": revision, "cells": cells}
		NetEvent.Kind.ROUND: return _get_round(s)
		NetEvent.Kind.HIT:
			return {"shooter": s.get_u16(), "victim": s.get_u16(), "damage": s.get_u32(), "pos": _get_vec(s),
					"id": s.get_u64(), "tick": s.get_u32(), "source": s.get_u8(), "knock": _get_vec(s),
					"hp": s.get_32(), "facing": s.get_8()}
		NetEvent.Kind.KILL: return [s.get_u16(), s.get_u16()]
		NetEvent.Kind.BEAM:
			var id := s.get_u64()
			var tick := s.get_u32()
			var type_id := s.get_u8()
			var role := s.get_u16()
			var points := PackedVector2Array()
			for i in s.get_u16(): points.append(_get_vec(s))
			return {"id": id, "tick": tick, "type_id": type_id, "shooter_role": role, "pts": points, "origin": points[0] if not points.is_empty() else Vector2.ZERO,
					"canonical": _get_vec(s), "color": _get_color(s), "half_width": s.get_double(), "lifetime": s.get_double(), "style": s.get_u8()}
		NetEvent.Kind.FIRE: return {"role": s.get_u16(), "shot": s.get_u32(), "type_id": s.get_u8(), "sound": _get_string(s)}
		NetEvent.Kind.BULLET_SPAWN:
			var id := s.get_u64()
			var tick := s.get_u32()
			return _get_projectile(s).merged({"id": id, "tick": tick})
		NetEvent.Kind.BULLET_REWIND:
			var role := s.get_u16()
			var tick := s.get_u32()
			var rewind := bool(s.get_u8())
			return {"role": role, "tick": tick, "rewind": rewind, "projectiles": _get_projectiles(s)}
		NetEvent.Kind.EXPLOSION:
			return {"id": s.get_u64(), "type_id": s.get_u8(), "pos": _get_vec(s), "tick": s.get_u32()}
		NetEvent.Kind.BULLET_FUSE:
			return {"tick": s.get_u32(), "projectiles": _get_projectiles(s)}
		NetEvent.Kind.BULLET_END:
			var tick := s.get_u32()
			var ids: Array[int] = []
			for i in s.get_u16(): ids.append(s.get_u64())
			return {"tick": tick, "ids": ids}
		NetEvent.Kind.TIME_REWARD:
			return {"tick": s.get_u32(), "serial": s.get_u32(), "phase": s.get_32(),
					"role": s.get_u16(), "amount": s.get_u32()}
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
		if _put_delta(s, current[role], base.get(role, {}), ACTOR_FIELDS) != 0:
			changed |= 1 << i
		else:
			s.seek(position)
	var end := s.get_position()
	s.seek(start)
	_put_mask(s, present, roles.size())
	_put_mask(s, changed, roles.size())
	s.seek(end)
	return changed != 0 or removed

func _read_players(s: StreamPeerBuffer, players: Dictionary) -> void:
	var present := _get_bits(s, roles.size())
	var changed := _get_bits(s, roles.size())
	for i in roles.size():
		if not present[i]: players.erase(roles[i])
		elif changed[i]: players[roles[i]] = _get_delta(s, players.get(roles[i], {}), ACTOR_FIELDS)

func _write_pickups(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var removed := _put_removed(s, current, base, 4)
	var count_position := s.get_position()
	s.put_u16(0)
	var changed := 0
	for id in current:
		var data: Dictionary = current[id]
		var old: Dictionary = base.get(id, {})
		var mask := 0
		if data["pos"] != old.get("pos"): mask |= 1
		if data["vel"] != old.get("vel"): mask |= 2
		if data["type_id"] != old.get("type_id") or data["mag"] != old.get("mag"): mask |= 4
		if mask == 0: continue
		changed += 1
		s.put_u32(id)
		s.put_u8(mask)
		if mask & 1: _put_vec(s, data["pos"])
		if mask & 2: _put_vec(s, data["vel"])
		if mask & 4:
			s.put_u8(data["type_id"])
			s.put_32(data["mag"])
	if changed != 0: _patch_count(s, count_position, changed)
	return removed != 0 or changed != 0

func _read_pickups(s: StreamPeerBuffer, entities: Dictionary) -> void:
	for i in s.get_u16(): entities.erase(s.get_u32())
	for i in s.get_u16():
		var id := s.get_u32()
		var data: Dictionary = entities.get(id, {}).duplicate()
		var mask := s.get_u8()
		if mask & 1: data["pos"] = _get_vec(s)
		if mask & 2: data["vel"] = _get_vec(s)
		if mask & 4:
			data["type_id"] = s.get_u8()
			data["mag"] = s.get_32()
		entities[id] = data

static func _put_projectile(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u8(data["type_id"])
	_put_vec(s, data["pos"])
	_put_vec(s, data["vel"])

static func _get_projectile(s: StreamPeerBuffer) -> Dictionary:
	return {"type_id": s.get_u8(), "pos": _get_vec(s), "vel": _get_vec(s)}

static func _put_projectiles(s: StreamPeerBuffer, projectiles: Dictionary) -> void:
	s.put_u16(projectiles.size())
	for id in projectiles:
		s.put_u64(id)
		var data: Dictionary = projectiles[id]
		_put_projectile(s, data)
		s.put_double(data["traveled"])
		s.put_u8(int(data["fuse_active"]) | (int(data["direct_hit"]) << 1))
		s.put_double(data["fuse_elapsed"])
		s.put_double(data["fuse_duration"])

static func _get_projectiles(s: StreamPeerBuffer) -> Dictionary:
	var result := {}
	for i in s.get_u16():
		var id := s.get_u64()
		var data := _get_projectile(s)
		data["traveled"] = s.get_double()
		var flags := s.get_u8()
		data.merge({"fuse_active": bool(flags & 1), "direct_hit": bool(flags & 2),
				"fuse_elapsed": s.get_double(), "fuse_duration": s.get_double()})
		result[id] = data
	return result

func _write_projectile_delta(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> bool:
	var removed := _put_removed(s, current, base, 8)
	s.put_u16(current.size())
	for id in current:
		s.put_u64(id)
		# 持续运动的数据直接发送；相同值也是合法增量，低频字段继续省略。
		_put_delta(s, current[id], base.get(id, {}), PROJECTILE_FIELDS, PROJECTILE_MOTION_MASK)
	return removed != 0 or not current.is_empty()

func _read_projectile_delta(s: StreamPeerBuffer, current: Dictionary) -> void:
	for i in s.get_u16(): current.erase(s.get_u64())
	for i in s.get_u16():
		var id := s.get_u64()
		current[id] = _get_delta(s, current.get(id, {}), PROJECTILE_FIELDS)

static func _put_driver(s: StreamPeerBuffer, data: Dictionary, base: Dictionary) -> bool:
	var changed := _put_delta(s, data, base, DRIVER_FIELDS) != 0
	if data["winst"] != 0:
		var weapon := _put_delta(s, data, base if data["winst"] == base.get("winst") else {}, WEAPON_FIELDS)
		changed = changed or weapon != 0
	return changed

static func _get_driver(s: StreamPeerBuffer, base: Dictionary) -> Dictionary:
	var data := _get_delta(s, base, DRIVER_FIELDS)
	if data["winst"] != 0:
		data.merge(_get_delta(s, base if data["winst"] == base.get("winst") else {}, WEAPON_FIELDS))
	return data

static func _put_own(s: StreamPeerBuffer, own: Dictionary, base: Dictionary) -> bool:
	var changed := _put_delta(s, own, base, OWN_FIELDS) != 0
	var input := _put_delta(s, own["input"], base.get("input", {}), OWN_INPUT_FIELDS)
	var data: Dictionary = own["state"]
	var old: Dictionary = base.get("state", {})
	var state := _put_delta(s, data, old, OWN_STATE_FIELDS)
	changed = changed or input != 0 or state != 0
	if data["winst"] != 0:
		var weapon := _put_delta(s, data, old if data["winst"] == old.get("winst") else {}, WEAPON_FIELDS)
		changed = changed or weapon != 0
	return changed

static func _get_own(s: StreamPeerBuffer, base: Dictionary) -> Dictionary:
	var own := _get_delta(s, base, OWN_FIELDS)
	own["input"] = _get_delta(s, base.get("input", {}), OWN_INPUT_FIELDS)
	own["input"].merge({"pressed": 0, "released": 0, "winst": 0})
	var old: Dictionary = base.get("state", {})
	var data := _get_delta(s, old, OWN_STATE_FIELDS)
	if data["winst"] != 0:
		data.merge(_get_delta(s, old if data["winst"] == old.get("winst") else {}, WEAPON_FIELDS))
	own["state"] = data
	return own

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

static func _get_time(s: StreamPeerBuffer, base: Dictionary) -> Dictionary:
	var result := base.duplicate()
	for role in _get_roles(s): result.erase(role)
	for i in s.get_u16():
		var role := s.get_u16()
		result[role] = _get_delta(s, base.get(role, {}), TIME_FIELDS)
	return result

static func _put_delta(s: StreamPeerBuffer, data: Dictionary, base: Dictionary, fields: Array, forced: int = 0) -> int:
	var start := s.get_position()
	_put_mask(s, 0, fields.size())
	var mask := 0
	for i in fields.size():
		var key: String = fields[i][0]
		var kind: int = fields[i][1]
		var value: Variant = data[key]
		if kind == Field.DRIVER or kind == Field.RECORD:
			var position := s.get_position()
			var changed: bool
			if kind == Field.DRIVER:
				changed = _put_driver(s, value, base.get(key, {}))
			else:
				changed = _put_delta(s, value, base.get(key, {}), OWN_INPUT_FIELDS) != 0
			if changed:
				mask |= 1 << i
			else:
				s.seek(position)
			continue
		if (forced & (1 << i)) == 0 and value == base.get(key): continue
		mask |= 1 << i
		match kind:
			Field.U8, Field.BOOL: s.put_u8(int(value))
			Field.I8: s.put_8(value)
			Field.U16: s.put_u16(value)
			Field.I32: s.put_32(value)
			Field.U32: s.put_u32(value)
			Field.F64: s.put_double(value)
			Field.VEC: _put_vec(s, value)
			Field.PATH:
				s.put_u8(value.size())
				for knot: Dictionary in value:
					s.put_u32(knot["tick"])
					_put_vec(s, knot["body"]["pos"])
					s.put_u8(int(knot["body"]["squat"]) | (int(knot["body"]["down"]) << 1) | (int(knot["body"]["facing"] < 0) << 2))
			Field.INVENTORY:
				s.put_u8(value.size())
				for item: Dictionary in value:
					s.put_u32(item["inst"])
					s.put_u8(item["type"])
					s.put_32(item["mag"])
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

static func _get_delta(s: StreamPeerBuffer, base: Dictionary, fields: Array) -> Dictionary:
	var mask := 0
	for shift in range(0, fields.size(), 8): mask |= s.get_u8() << shift
	var data := {}
	for i in fields.size():
		var key: String = fields[i][0]
		if not mask & (1 << i):
			data[key] = base[key].duplicate(true) if fields[i][1] in [Field.INVENTORY, Field.DRIVER, Field.RECORD, Field.PATH] else base[key]
			continue
		match fields[i][1]:
			Field.U8: data[key] = s.get_u8()
			Field.BOOL: data[key] = bool(s.get_u8())
			Field.I8: data[key] = s.get_8()
			Field.U16: data[key] = s.get_u16()
			Field.I32: data[key] = s.get_32()
			Field.U32: data[key] = s.get_u32()
			Field.F64: data[key] = s.get_double()
			Field.VEC: data[key] = _get_vec(s)
			Field.DRIVER: data[key] = _get_driver(s, base.get(key, {}))
			Field.RECORD:
				data[key] = _get_delta(s, base.get(key, {}), OWN_INPUT_FIELDS)
				data[key].merge({"pressed": 0, "released": 0, "winst": 0})
			Field.PATH:
				data[key] = []
				for step in s.get_u8():
					var tick := s.get_u32()
					var pos := _get_vec(s)
					var flags := s.get_u8()
					data[key].append({"tick": tick, "body": {"pos": pos, "squat": bool(flags & 1), "down": bool(flags & 2), "facing": -1 if flags & 4 else 1}})
			Field.INVENTORY:
				var inventory: Array = []
				for j in s.get_u8(): inventory.append({"inst": s.get_u32(), "type": s.get_u8(), "mag": s.get_32()})
				data[key] = inventory
	return data

static func _put_options(s: StreamPeerBuffer, data: Dictionary) -> void:
	var mask := 0
	for i in OPTIONS.size():
		if data.has(OPTIONS[i]): mask |= 1 << i
	s.put_u16(mask)
	for i in OPTIONS.size():
		if not mask & (1 << i): continue
		var value: Variant = data[OPTIONS[i]]
		match OPTIONS[i]:
			"is_public", "round_full_heal", "beta": s.put_u8(int(value))
			"invite_code", "map": _put_string(s, value)
			"max_players", "match_time": s.put_u32(value)
			"hue": s.put_double(value)
			"disabled_weapons":
				s.put_u8(value.size())
				for id in value: s.put_u8(id)
			"time":
				s.put_u8(int(not value.is_empty()))
				if not value.is_empty():
					for key in TIME_RULES: s.put_double(value[key])
					s.put_u32(value["block_gain"])
					s.put_u32(value["damage_gain"])

static func _get_options(s: StreamPeerBuffer) -> Dictionary:
	var mask := s.get_u16()
	var data := {}
	for i in OPTIONS.size():
		if not mask & (1 << i): continue
		var key: String = OPTIONS[i]
		match key:
			"is_public", "round_full_heal", "beta": data[key] = bool(s.get_u8())
			"invite_code", "map": data[key] = _get_string(s)
			"max_players", "match_time": data[key] = s.get_u32()
			"hue": data[key] = s.get_double()
			"disabled_weapons":
				var ids: Array = []
				for j in s.get_u8(): ids.append(s.get_u8())
				data[key] = ids
			"time":
				var rules := {}
				if s.get_u8() != 0:
					for field in TIME_RULES: rules[field] = s.get_double()
					rules["block_gain"] = s.get_u32()
					rules["damage_gain"] = s.get_u32()
				data[key] = rules
	return data

static func _put_room(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u32(int(data["code"]))
	s.put_u8(MODES.find(data["mode"]))
	_put_string(s, data["map"])
	s.put_u16(data["max_players"])
	s.put_u32(data["match_time"])
	s.put_u16(data["host_role"])
	s.put_u8(int(data["is_public"]) | (int(data["in_match"]) << 1) | (int(data["beta"]) << 2))
	s.put_u16(data["players"].size())
	for player: Dictionary in data["players"]:
		s.put_u16(player["role"])
		_put_string(s, player["name"])
		s.put_u8(player["team"])

static func _get_room(s: StreamPeerBuffer) -> Dictionary:
	var data := {"code": "%08d" % s.get_u32(), "mode": MODES[s.get_u8()], "map": _get_string(s),
			"max_players": s.get_u16(), "match_time": s.get_u32(), "host_role": s.get_u16()}
	var flags := s.get_u8()
	data.merge({"is_public": bool(flags & 1), "in_match": bool(flags & 2), "beta": bool(flags & 4), "team_size": 3, "host_name": ""})
	var roster: Array = []
	var names: Array = []
	var teams := {}
	var counts := {0: 0, 1: 0, 2: 0}
	for i in s.get_u16():
		var player := {"role": s.get_u16(), "name": _get_string(s), "team": s.get_u8()}
		roster.append(player)
		names.append(player["name"])
		teams[player["role"]] = player["team"]
		counts[player["team"]] += 1
		if player["role"] == data["host_role"]: data["host_name"] = player["name"]
	data.merge({"players": roster, "names": names, "teams": teams, "team_counts": counts, "count": roster.size()})
	return data

static func _put_round(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u8(data["state"])
	s.put_u32(data["round"])
	s.put_double(data["timer"])
	for key in ["winner", "match_winner", "mvp"]: s.put_u16(data[key])
	for key in ["scores", "rounds_won", "deaths"]: _put_int_map(s, data[key])
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

static func _get_round(s: StreamPeerBuffer) -> Dictionary:
	var data := {"state": s.get_u8(), "round": s.get_u32(), "timer": s.get_double()}
	for key in ["winner", "match_winner", "mvp"]: data[key] = s.get_u16()
	for key in ["scores", "rounds_won", "deaths"]: data[key] = _get_int_map(s)
	data["left"] = _get_roles(s)
	var grace := {}
	for i in s.get_u16():
		var role := s.get_u16()
		grace[role] = s.get_double()
	data["grace"] = grace
	var alive := {}
	for i in s.get_u16():
		var role := s.get_u16()
		alive[role] = bool(s.get_u8())
	data["alive"] = alive
	var stats := {}
	for i in s.get_u16():
		var role := s.get_u16()
		var entry := {}
		for key in STATS: entry[key] = s.get_32()
		entry["acs"] = s.get_double()
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

static func _get_names(s: StreamPeerBuffer) -> Dictionary:
	var names := {}
	var hues := {}
	for i in s.get_u16():
		var role := s.get_u16()
		names[role] = _get_string(s)
		if s.get_u8() != 0: hues[role] = s.get_double()
	return {"names": names, "hues": hues}

static func _put_mask(s: StreamPeerBuffer, mask: int, count: int) -> void:
	for shift in range(0, count, 8): s.put_u8((mask >> shift) & 255)

static func _get_bits(s: StreamPeerBuffer, count: int) -> Array:
	var values: Array = []
	for start in range(0, count, 8):
		var bits := s.get_u8()
		for i in mini(8, count - start): values.append(bool(bits & (1 << i)))
	return values

static func _put_int_map(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_u16(data.size())
	for key in data:
		s.put_u16(key)
		s.put_32(data[key])

static func _get_int_map(s: StreamPeerBuffer) -> Dictionary:
	var data := {}
	for i in s.get_u16():
		var key := s.get_u16()
		data[key] = s.get_32()
	return data

static func _put_roles(s: StreamPeerBuffer, ids: Array) -> void:
	s.put_u16(ids.size())
	for id in ids: s.put_u16(id)

static func _get_roles(s: StreamPeerBuffer) -> Array:
	var ids: Array = []
	for i in s.get_u16(): ids.append(s.get_u16())
	return ids

static func _put_input_time(s: StreamPeerBuffer, data: Dictionary) -> void:
	s.put_32(data["target_tick"])
	s.put_32(data["view_tick"])

static func _get_input_time(s: StreamPeerBuffer) -> Dictionary:
	return {"target_tick": s.get_32(), "view_tick": s.get_32()}

static func _put_vec(s: StreamPeerBuffer, value: Vector2) -> void:
	s.put_float(value.x)
	s.put_float(value.y)

static func _get_vec(s: StreamPeerBuffer) -> Vector2:
	return Vector2(s.get_float(), s.get_float())

static func _put_cell(s: StreamPeerBuffer, value: Vector2i) -> void:
	s.put_32(value.x)
	s.put_32(value.y)

static func _get_cell(s: StreamPeerBuffer) -> Vector2i:
	return Vector2i(s.get_32(), s.get_32())

static func _put_color(s: StreamPeerBuffer, value: Color) -> void:
	for part in [value.r, value.g, value.b, value.a]: s.put_float(part)

static func _get_color(s: StreamPeerBuffer) -> Color:
	return Color(s.get_float(), s.get_float(), s.get_float(), s.get_float())

static func _put_string(s: StreamPeerBuffer, value: String) -> void:
	_put_blob(s, value.to_utf8_buffer())

static func _get_string(s: StreamPeerBuffer) -> String:
	return _get_blob(s).get_string_from_utf8()

static func _put_blob(s: StreamPeerBuffer, value: PackedByteArray) -> void:
	s.put_u32(value.size())
	s.put_data(value)

static func _get_blob(s: StreamPeerBuffer) -> PackedByteArray:
	return s.get_data(s.get_u32())[1]

static func _put_token(s: StreamPeerBuffer, token: String) -> void:
	s.put_u8(int(not token.is_empty()))
	if not token.is_empty(): s.put_data(token.hex_decode())

static func _get_token(s: StreamPeerBuffer) -> String:
	return s.get_data(16)[1].hex_encode() if s.get_u8() != 0 else ""
