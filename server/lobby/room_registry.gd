class_name RoomRegistry
extends RefCounted


var peer_names: Dictionary = {}

var _tables: Dictionary = {}


func _init() -> void:
	for mode in ModeDefs.MODE_IDS:
		_tables[mode] = {}


# 只读视图(按 mode 过滤)。★ 别改它:增删走 add / erase,否则拆除的单一收口被绕过。
func of(mode: String) -> Dictionary:
	return _tables.get(mode, {})


func add(room: RoomTypes.Room) -> void:
	if not _tables.has(room.mode):
		return
	(_tables[room.mode] as Dictionary)[room.code] = room


func erase(room: RoomTypes.Room) -> void:
	(_tables.get(room.mode, {}) as Dictionary).erase(room.code)


func find(code: String, mode: String = "") -> RoomTypes.Room:
	if mode != "":
		return (_tables.get(mode, {}) as Dictionary).get(code, null)
	for m in ModeDefs.MODE_IDS:
		var t: Dictionary = _tables[m]
		if t.has(code):
			return t[code]
	return null


func room_of_peer(mode: String, peer_id: int) -> RoomTypes.Room:
	var t: Dictionary = _tables.get(mode, {})
	for code in t:
		if (t[code] as RoomTypes.Room).players.has(peer_id):
			return t[code]
	return null


func generate_code() -> String:
	return "%04d" % (randi() % 10000)


func next_code(mode: String) -> String:
	var t: Dictionary = of(mode)
	var code := generate_code()
	while t.has(code):
		code = generate_code()
	return code


func set_name(peer_id: int, name: String) -> void:
	peer_names[peer_id] = name


func name_of(peer_id: int) -> String:
	return str(peer_names.get(peer_id, "玩家"))


func drop_name(peer_id: int) -> void:
	peer_names.erase(peer_id)


func freeze_roster(room: RoomTypes.Room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)), "name": name_of(pid)})
	room.roster = out


# 端口在拆除后多久才可复用(秒)。★ 唯一来源 = ModeDefs.port_return_seconds / PORT_REUSE_DELAY_*
# (1v1 120 / 大乱斗 360 / 3v3 360);这里不写第二份数 —— 写一份就会与 worker 侧漂。
func port_return_delay(mode: String) -> float:
	return ModeDefs.port_return_seconds(mode)


func list_payload(mode: String, token: String = "", rejoin: RejoinRegistry = null) -> Array:
	var now := Time.get_ticks_msec()
	var arr: Array = []
	for code in of(mode):
		var r: RoomTypes.Room = of(mode)[code]
		if not r.is_duel() and not r.is_public \
				and (rejoin == null or not rejoin.owns(token, code, now, mode)):
			continue
		if r.players.is_empty() and not r.in_match:
			continue
		var view := ServerStatus.host_and_roster(r.is_duel(), r.in_match, r.host_peer,
				int(r.player_role.get(r.host_peer, 0)), r.roster, r.players, r.player_role, peer_names)
		var names: Array = view["names"]
		var host := str(view["host"])
		var row := {"code": code, "players": names.size(), "names": names,
				"in_match": r.in_match, "is_public": r.is_public, "host": host, "map": r.map}
		if r.is_royale():
			row["max_players"] = r.max_players
			row["beta"] = r.beta
			row["match_time"] = r.match_time
		elif r.is_team():
			row["max_players"] = r.max_players
			row["beta"] = r.beta
			row["team_counts"] = RoomTypes.team_counts_of(r)
		arr.append(row)
	return arr
