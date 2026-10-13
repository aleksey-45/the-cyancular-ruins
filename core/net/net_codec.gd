class_name NetCodec
extends RefCounted

# 固定小端协议。字段表只描述已知记录，不发送字段名或 Variant 类型。
const INPUT := 0
const STATE := 1
const EVENT := 2
const KEEP := 64
const MODES := [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]
const OWN_FLAGS := ["floor", "jcut", "squat", "charge", "wp_s", "clatch", "swim", "down"]
const OWN_TIMERS := ["haste_mult", "slock", "coyote", "jbuf", "ct", "lmv_t", "wp_t", "wp_d", "ifr"]
const ACTOR_FLAGS := ["downed", "previewing", "haste", "rewind"]
const WEAPON_FLAGS := ["aiming", "fire_buf", "rld"]
const OPTIONS := ["is_public", "invite_code", "map", "max_players", "match_time", "round_full_heal", "disabled_weapons", "beta", "time", "hue"]
const TIME_RULES := ["initial", "cap", "rewind_burn", "haste_burn", "window", "regen", "kill_ratio", "haste_mult"]
const TIME_VALUES := ["b", "w", "l", "win", "m"]
const STATS := ["kills", "deaths", "assists", "dealt", "taken", "kscore"]
var state_ack := 0
var serial := 0
var latest := 0
var history: Dictionary = {}
var roles: Array = []

func encode_input(packet: Dictionary) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u8(INPUT)
	s.put_u32(state_ack)
	var frames: Array = packet["frames"]
	var actions: Array = packet["actions"]
	var epoch: int = frames[0]["epoch"] if not frames.is_empty() else (actions[0]["epoch"] if not actions.is_empty() else 1)
	s.put_u32(epoch)
	s.put_u8(frames.size())
	s.put_u32(frames[0]["seq"] if not frames.is_empty() else 0)
	for frame: Dictionary in frames:
		_put_input_time(s, frame)
		s.put_double(frame["ax"])
		s.put_u16(frame["held"])
		_put_vec(s, frame["aim"])
	s.put_u8(actions.size())
	for action: Dictionary in actions:
		s.put_u32(action["seq"])
		_put_input_time(s, action)
		s.put_u16(action["pressed"])
		s.put_u16(action["released"])
		s.put_u32(action["winst"])
		_put_vec(s, action["aim"])
	return s.data_array

func decode_input(s: StreamPeerBuffer) -> Dictionary:
	var ack := s.get_u32()
	state_ack = 0 if ack == 0 else maxi(state_ack, ack)
	var epoch := s.get_u32()
	var count := s.get_u8()
	var first := s.get_u32()
	var frames: Array = []
	for i in count:
		var frame := _get_input_time(s)
		frame.merge({"seq": first + i, "epoch": epoch, "ax": s.get_double(), "held": s.get_u16(), "aim": _get_vec(s)})
		frames.append(frame)
	var actions: Array = []
	for i in s.get_u8():
		var action := {"seq": s.get_u32(), "epoch": epoch}
		action.merge(_get_input_time(s))
		action.merge({"pressed": s.get_u16(), "released": s.get_u16(), "winst": s.get_u32(), "aim": _get_vec(s)})
		actions.append(action)
	return {"frames": frames, "actions": actions}

func encode_state(frame: Dictionary) -> PackedByteArray:
	if roles.is_empty():
		roles = frame["world"]["players"].keys()
		roles.sort()
	var s := StreamPeerBuffer.new()
	s.put_u8(STATE)
	_write_state(s, frame)
	return s.data_array

func _write_state(s: StreamPeerBuffer, frame: Dictionary) -> void:
	serial += 1
	var base: Dictionary = history.get(state_ack, {})
	s.put_u32(serial)
	s.put_u32(state_ack if not base.is_empty() else 0)
	s.put_u32(frame["tick"])
	s.put_u32(frame["map_revision"])
	if base.is_empty():
		_put_roles(s, roles)
	var old_world: Dictionary = base.get("world", {"players": {}, "projectiles": {}, "pickups": {}})
	_write_players(s, frame["world"]["players"], old_world["players"])
	_write_entities(s, frame["world"]["projectiles"], old_world["projectiles"], true)
	_write_entities(s, frame["world"]["pickups"], old_world["pickups"], false)
	_put_own(s, frame["own"], base.get("own", {}))
	_put_time(s, frame["time"], base.get("time", {}))
	_remember(serial, frame)

func decode_state(s: StreamPeerBuffer) -> Dictionary:
	var number := s.get_u32()
	var base_number := s.get_u32()
	if number <= latest:
		return {}
	if base_number != 0 and not history.has(base_number):
		state_ack = 0 # 下次 INPUT 请求独立全量快照。
		return {}
	var base: Dictionary = history.get(base_number, {})
	var frame := {"tick": s.get_u32(), "map_revision": s.get_u32()}
	if base_number == 0:
		roles = _get_roles(s)
	var world: Dictionary = base.get("world", {"players": {}, "projectiles": {}, "pickups": {}}).duplicate(true)
	_read_players(s, world["players"])
	_read_entities(s, world["projectiles"], true)
	_read_entities(s, world["pickups"], false)
	frame["world"] = world
	frame["own"] = _get_own(s, base.get("own", {}))
	frame["time"] = _get_time(s, base.get("time", {}))
	latest = number
	state_ack = number
	_remember(number, frame)
	return frame

func _remember(number: int, frame: Dictionary) -> void:
	history[number] = frame.duplicate(true)
	while history.size() > KEEP:
		history.erase(history.keys()[0])

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
			_write_state(s, data["frame"])
		NetEvent.Kind.TERRAIN:
			s.put_u32(data["revision"])
			_put_cell(s, data["sub"])
			s.put_32(data["hp"])
		NetEvent.Kind.ROUND:
			_put_round(s, data)
		NetEvent.Kind.HIT:
			s.put_u16(data["shooter"])
			s.put_u16(data["victim"])
			s.put_u32(data["damage"])
			_put_vec(s, data["pos"])
		NetEvent.Kind.KILL:
			s.put_u16(data[0])
			s.put_u16(data[1])
		NetEvent.Kind.BEAM:
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
			return data
		NetEvent.Kind.TERRAIN: return {"revision": s.get_u32(), "sub": _get_cell(s), "hp": s.get_32()}
		NetEvent.Kind.ROUND: return _get_round(s)
		NetEvent.Kind.HIT: return {"shooter": s.get_u16(), "victim": s.get_u16(), "damage": s.get_u32(), "pos": _get_vec(s)}
		NetEvent.Kind.KILL: return [s.get_u16(), s.get_u16()]
		NetEvent.Kind.BEAM:
			var role := s.get_u16()
			var points := PackedVector2Array()
			for i in s.get_u16(): points.append(_get_vec(s))
			return {"shooter_role": role, "pts": points, "origin": points[0] if not points.is_empty() else Vector2.ZERO,
					"canonical": _get_vec(s), "color": _get_color(s), "half_width": s.get_double(), "lifetime": s.get_double(), "style": s.get_u8()}
		NetEvent.Kind.FIRE: return {"role": s.get_u16(), "shot": s.get_u32(), "type_id": s.get_u8(), "sound": _get_string(s)}
	return null

func _write_players(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> void:
	var present: Array = []
	var changed: Array = []
	for role in roles:
		present.append(current.has(role))
		changed.append(current.has(role) and current[role] != base.get(role))
	_put_bits(s, present)
	_put_bits(s, changed)
	for i in roles.size():
		if changed[i]: _put_actor(s, current[roles[i]])

func _read_players(s: StreamPeerBuffer, players: Dictionary) -> void:
	var present := _get_bits(s, roles.size())
	var changed := _get_bits(s, roles.size())
	for i in roles.size():
		if not present[i]: players.erase(roles[i])
		elif changed[i]: players[roles[i]] = _get_actor(s)

func _write_entities(s: StreamPeerBuffer, current: Dictionary, base: Dictionary, bullets: bool) -> void:
	var removed := base.keys().filter(func(id: int) -> bool: return not current.has(id))
	var changed := current.keys().filter(func(id: int) -> bool: return current[id] != base.get(id))
	s.put_u16(removed.size())
	for id in removed:
		if bullets: s.put_u64(id)
		else: s.put_u32(id)
	s.put_u16(changed.size())
	for id in changed:
		if bullets: s.put_u64(id)
		else: s.put_u32(id)
		var data: Dictionary = current[id]
		var old: Dictionary = base.get(id, {})
		var mask := 0
		if data["pos"] != old.get("pos"): mask |= 1
		if data["vel"] != old.get("vel"): mask |= 2
		if bullets:
			if data["type_id"] != old.get("type_id") or data["input_seq"] != old.get("input_seq") or data["input_epoch"] != old.get("input_epoch"): mask |= 4
		else:
			if data["type_id"] != old.get("type_id") or data["mag"] != old.get("mag"): mask |= 4
		s.put_u8(mask)
		if mask & 1: _put_vec(s, data["pos"])
		if mask & 2: _put_vec(s, data["vel"])
		if mask & 4:
			s.put_u8(data["type_id"])
			if bullets:
				s.put_u32(data["input_seq"])
				s.put_u32(data["input_epoch"])
			else: s.put_32(data["mag"])

func _read_entities(s: StreamPeerBuffer, entities: Dictionary, bullets: bool) -> void:
	for i in s.get_u16(): entities.erase(s.get_u64() if bullets else s.get_u32())
	for i in s.get_u16():
		var id := s.get_u64() if bullets else s.get_u32()
		var data: Dictionary = entities.get(id, {}).duplicate()
		var mask := s.get_u8()
		if mask & 1: data["pos"] = _get_vec(s)
		if mask & 2: data["vel"] = _get_vec(s)
		if mask & 4:
			data["type_id"] = s.get_u8()
			if bullets:
				data["input_seq"] = s.get_u32()
				data["input_epoch"] = s.get_u32()
			else: data["mag"] = s.get_32()
		entities[id] = data

static func _put_actor(s: StreamPeerBuffer, data: Dictionary) -> void:
	_put_vec(s, data["pos"])
	_put_vec(s, data["vel"])
	_put_vec(s, data["aim"])
	s.put_8(data["facing"])
	s.put_u8(data["pose"])
	s.put_u8(data["type_id"])
	s.put_32(data["hp"])
	s.put_32(data["waterproof"])
	s.put_u32(data["epoch"])
	s.put_u8(_flags(data, ACTOR_FLAGS))

static func _get_actor(s: StreamPeerBuffer) -> Dictionary:
	var data := {"pos": _get_vec(s), "vel": _get_vec(s), "aim": _get_vec(s), "facing": s.get_8(), "pose": s.get_u8(),
			"type_id": s.get_u8(), "hp": s.get_32(), "waterproof": s.get_32(), "epoch": s.get_u32()}
	_set_flags(data, ACTOR_FLAGS, s.get_u8())
	return data

static func _put_own(s: StreamPeerBuffer, own: Dictionary, base: Dictionary) -> void:
	for key in ["epoch", "ack", "action_ack", "timing_seq"]: s.put_u32(own[key])
	s.put_32(own["lead"])
	s.put_u8(int(own["rewind"]))
	var input: Dictionary = own["input"]
	s.put_u32(input["seq"])
	s.put_u32(input["epoch"])
	_put_input_time(s, input)
	s.put_double(input["ax"])
	s.put_u16(input["held"])
	_put_vec(s, input["aim"])
	var data: Dictionary = own["state"]
	var inventory: bool = base.is_empty() or data["inv"] != base["state"]["inv"]
	s.put_u16(_flags(data, OWN_FLAGS) | (int(inventory) << 8))
	_put_vec(s, data["pos"])
	_put_vec(s, data["vel"])
	_put_vec(s, data["knock"])
	for key in OWN_TIMERS: s.put_double(data[key])
	s.put_32(data["wp"])
	s.put_u32(data["shot_serial"])
	s.put_8(data["facing"])
	s.put_u8(data["state"])
	s.put_8(data["lmv_d"])
	s.put_32(data["hp"])
	s.put_u32(data["winst"])
	if inventory:
		s.put_u8(data["inv"].size())
		for item: Dictionary in data["inv"]:
			s.put_u32(item["inst"])
			s.put_u8(item["type"])
			s.put_32(item["mag"])
	if data["winst"] != 0:
		s.put_u8(_flags(data, WEAPON_FLAGS))
		for key in ["fire_cd", "rld_t"]: s.put_double(data[key])
		for key in ["aim_f", "aim_cf"]: s.put_8(data[key])
		s.put_32(data["mag"])

static func _get_own(s: StreamPeerBuffer, base: Dictionary) -> Dictionary:
	var own := {}
	for key in ["epoch", "ack", "action_ack", "timing_seq"]: own[key] = s.get_u32()
	own.merge({"lead": s.get_32(), "rewind": bool(s.get_u8())})
	var input := {"seq": s.get_u32(), "epoch": s.get_u32()}
	input.merge(_get_input_time(s))
	input["ax"] = s.get_double()
	input.merge({"held": s.get_u16(), "pressed": 0, "released": 0, "winst": 0, "aim": _get_vec(s)})
	own["input"] = input
	var flags := s.get_u16()
	var data := {"pos": _get_vec(s), "vel": _get_vec(s), "knock": _get_vec(s)}
	_set_flags(data, OWN_FLAGS, flags)
	for key in OWN_TIMERS: data[key] = s.get_double()
	data["wp"] = s.get_32()
	data.merge({"shot_serial": s.get_u32(), "facing": s.get_8(), "state": s.get_u8(), "lmv_d": s.get_8(), "hp": s.get_32(), "winst": s.get_u32()})
	var inventory: Array = []
	if flags & 256:
		for i in s.get_u8(): inventory.append({"inst": s.get_u32(), "type": s.get_u8(), "mag": s.get_32()})
	else: inventory = base["state"]["inv"].duplicate(true)
	data["inv"] = inventory
	if data["winst"] != 0:
		_set_flags(data, WEAPON_FLAGS, s.get_u8())
		for key in ["fire_cd", "rld_t"]: data[key] = s.get_double()
		for key in ["aim_f", "aim_cf"]: data[key] = s.get_8()
		data["mag"] = s.get_32()
	own["state"] = data
	return own

static func _put_time(s: StreamPeerBuffer, current: Dictionary, base: Dictionary) -> void:
	var removed := base.keys().filter(func(id: int) -> bool: return not current.has(id))
	_put_roles(s, removed)
	var changed := current.keys().filter(func(id: int) -> bool: return current[id] != base.get(id))
	s.put_u16(changed.size())
	for role in changed:
		s.put_u16(role)
		for key in TIME_VALUES: s.put_double(current[role][key])
		s.put_32(current[role]["cap"])
		s.put_u8(int(current[role]["k"]))

static func _get_time(s: StreamPeerBuffer, base: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for role in _get_roles(s): result.erase(role)
	for i in s.get_u16():
		var role := s.get_u16()
		var data := {}
		for key in TIME_VALUES: data[key] = s.get_double()
		data["cap"] = s.get_32()
		data["k"] = bool(s.get_u8())
		result[role] = data
	return result

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

static func _put_bits(s: StreamPeerBuffer, values: Array) -> void:
	for start in range(0, values.size(), 8):
		var bits := 0
		for i in mini(8, values.size() - start): bits |= int(values[start + i]) << i
		s.put_u8(bits)

static func _get_bits(s: StreamPeerBuffer, count: int) -> Array:
	var values: Array = []
	for start in range(0, count, 8):
		var bits := s.get_u8()
		for i in mini(8, count - start): values.append(bool(bits & (1 << i)))
	return values

static func _flags(data: Dictionary, fields: Array) -> int:
	var bits := 0
	for i in fields.size(): bits |= int(data[fields[i]]) << i
	return bits

static func _set_flags(data: Dictionary, fields: Array, bits: int) -> void:
	for i in fields.size(): data[fields[i]] = bool(bits & (1 << i))

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
