class_name RoomSession
extends Node

const GRACE_SECONDS := 60.0
var code := ""
var mode := PvpSession.MODE_PVP
var options: Dictionary = {}
var seats: Dictionary = {}
var guests: Dictionary = {}
var host_role := 1
var world: AuthorityWorld
var _returned: Dictionary = {}

func _ready() -> void:
	NetBus.event_received.connect(_on_event)
	NetBus.input_received.connect(_on_input)
	NetBus.peer_left.connect(_on_left)

func _on_event(peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.HELLO:
			guests[peer] = data
		NetEvent.Kind.CREATE:
			if not code.is_empty():
				message(peer, "本进程已有房间")
				return
			if not guests.has(peer):
				message(peer, "请先提交玩家资料")
				return
			mode = data["mode"]
			options = data["options"].duplicate()
			if mode == PvpSession.MODE_ROYALE:
				options["max_players"] = clampi(options.get("max_players", 8), 2, 8)
				options["match_time"] = clampi(options.get("match_time", 300), 60, 900)
			if options.get("beta", false):
				options["time"] = TimeRules.normalized(options.get("time", {}))
			code = "%08d" % (randi() % 100000000)
			add_seat(peer)
			broadcast_room()
		NetEvent.Kind.LIST:
			var entry := room_data() if not code.is_empty() and options.get("beta", false) == data else {}
			NetBus.send_event(NetEvent.Kind.ROOM_LIST, entry, peer)
		NetEvent.Kind.JOIN:
			var role := role_of(peer)
			if data["code"] != code or code.is_empty():
				message(peer, "房间不存在")
			elif options.get("beta", false) != data["beta"]:
				var beta: bool = options.get("beta", false)
				message(peer, "该房间为「%s」，请从「%s」进入" % [
						PvpSession.mode_name(mode, beta), "Beta" if beta else "多人模式"])
			elif role != 0:
				broadcast_room(role)
			elif world != null or seats.size() >= max_players():
				message(peer, "房间已满")
			elif not guests.has(peer):
				message(peer, "请先提交玩家资料")
			else:
				add_seat(peer)
				broadcast_room()
		NetEvent.Kind.PICK_TEAM:
			var role := role_of(peer)
			if world == null and seats.has(role):
				_pick_team(peer, role, int(data))
		NetEvent.Kind.START:
			if role_of(peer) == host_role and world == null:
				var problem := _start_problem()
				if problem.is_empty():
					start_match()
				else:
					message(peer, problem)
		NetEvent.Kind.REJOIN:
			rejoin(peer, data["code"], data["token"])
		NetEvent.Kind.READY:
			var role := role_of(peer)
			if world == null or role == 0:
				return
			if int(data) != world.rules.round_number or world.rules.phase == NetEvent.RoundState.MATCH_OVER:
				return
			seats[role]["ready"] = true
			if seats.values().all(func(seat: Dictionary) -> bool: return seat["ready"]):
				world.start_countdown()
		NetEvent.Kind.SUICIDE:
			var role := role_of(peer)
			if world != null and role != 0:
				world.suicide(role)
		NetEvent.Kind.LEAVE:
			var role := role_of(peer)
			if not seats.has(role):
				return
			if world != null and world.rules.phase == NetEvent.RoundState.MATCH_OVER:
				_returned[role] = true
				if _returned.size() == online_count():
					return_to_room()
			else:
				remove_seat(role)

func message(peer: int, value: String) -> void:
	NetBus.send_event(NetEvent.Kind.MESSAGE, value, peer)

func role_of(peer: int) -> int:
	for role in seats:
		if seats[role]["peer"] == peer:
			return role
	return 0

func max_players() -> int:
	return 10 if mode == PvpSession.MODE_TEAM else (2 if mode == PvpSession.MODE_PVP else int(options.get("max_players", 8)))

func map_path() -> String:
	return str(options.get("map", "res://maps/newfactory.cyrm"))

# 新席位进入人数较少的队伍；平手进入 A 队。每队最多 5 人，容量由 max_players 保证。
func add_seat(peer: int) -> void:
	var role := 1
	while seats.has(role):
		role += 1
	var guest: Dictionary = guests[peer]
	var team := 0
	if mode == PvpSession.MODE_TEAM:
		var a := team_count(1)
		var b := team_count(2)
		team = 1 if a <= b and a < TeamRules.MAX_TEAM else 2
	seats[role] = {"peer": peer, "token": Crypto.new().generate_random_bytes(16).hex_encode(),
			"name": guest["name"], "hue": guest["hue"], "team": team, "deadline": 0.0, "ready": false}

func team_count(team: int) -> int:
	var n := 0
	for seat in seats.values():
		if int(seat["team"]) == team:
			n += 1
	return n

func _seat_teams() -> Dictionary:
	var teams := {}
	for role in seats:
		teams[role] = int(seats[role]["team"])
	return teams

# 选边只接受 1/2；先排除当前角色再判断目标队容量。
func _pick_team(peer: int, role: int, team: int) -> void:
	if team != 1 and team != 2:
		message(peer, "只能选择 A 队或 B 队")
		return
	var count := 0
	for other in seats:
		if other != role and int(seats[other]["team"]) == team:
			count += 1
	if count >= TeamRules.MAX_TEAM:
		message(peer, "%s队已满（每队最多 %d 人）" % ["A" if team == 1 else "B", TeamRules.MAX_TEAM])
		return
	if int(seats[role]["team"]) != team:
		seats[role]["team"] = team
		broadcast_room()

# 只产出线路会编码的字段；team_counts、host_name 等派生数据由客户端从 players 还原。
func room_data() -> Dictionary:
	var roster: Array = []
	for role in seats:
		roster.append({"role": role, "name": seats[role]["name"], "team": seats[role]["team"]})
	return {"code": code, "mode": mode, "map": map_path(), "players": roster,
			"max_players": max_players(), "match_time": options.get("match_time", 300),
			"host_role": host_role, "in_match": world != null, "beta": options.get("beta", false),
			"can_start": world == null and _start_problem().is_empty()}

func broadcast_room(only_role: int = 0) -> void:
	var base := room_data()
	for role in seats.keys() if only_role == 0 else [only_role]:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0:
			var payload := base.merged({"your_role": role, "token": seat["token"]})
			NetBus.send_event(NetEvent.Kind.ROOM, payload, seat["peer"])

## 团队可开局：模式正确、所有席位在线，且唯一一次阵容校验通过。
func team_ready() -> bool:
	if mode != PvpSession.MODE_TEAM:
		return false
	for role in seats:
		if seats[role]["peer"] == 0:
			return false
	return not TeamRules.team_counts(_seat_teams()).is_empty()

func _start_problem() -> String:
	if mode == PvpSession.MODE_TEAM:
		return "" if team_ready() else "A 队 %d 人、B 队 %d 人，每队 1~%d 人且全部在线才能开始" % [
				team_count(1), team_count(2), TeamRules.MAX_TEAM]
	var online := online_count()
	if mode == PvpSession.MODE_PVP and online != max_players():
		return "1v1 需要两名在线玩家"
	if online < 2:
		return "至少需要两名在线玩家"
	if online != seats.size():
		return "所有席位在线后才能开始"
	return ""

func start_match() -> void:
	var teams := _seat_teams() if mode == PvpSession.MODE_TEAM else {}
	world = AuthorityWorld.new()
	add_child(world)
	var problem := world.setup(mode, map_path(), seats.keys(), teams, options)
	if not problem.is_empty():
		message(int(seats[host_role]["peer"]), problem)
		_discard_world()
		return
	world.state_ready.connect(_send_state)
	world.event.connect(_broadcast)
	world.baseline_needed.connect(send_baselines)
	send_baselines(true)

func _send_state(frame: Dictionary) -> void:
	var perf_fanout := PerformanceStats.begin()
	var batch: NetCodec.StateBatch
	for role in frame["players"]:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0 and seat["ready"]:
			var perf_prepare := PerformanceStats.begin()
			var state := world.state_for(role, frame, batch.time if batch != null else null)
			if batch == null: batch = NetCodec.StateBatch.new(state)
			PerformanceStats.end(PerformanceStats.STATE_PREPARE, perf_prepare)
			NetBus.send_state(seat["peer"], state, batch)
	if batch != null: PerformanceStats.end(PerformanceStats.STATE_FANOUT, perf_fanout)

func _broadcast(kind: int, data: Variant, except_role: int) -> void:
	if kind == NetEvent.Kind.ROUND:
		data = _with_grace(data)
	var peers := PackedInt32Array()
	for role in seats:
		if role != except_role and seats[role]["peer"] != 0:
			peers.append(seats[role]["peer"])
	NetBus.broadcast_event(kind, data, peers)

func send_baselines(include_map: bool = false, only_role: int = 0) -> void:
	var names := {}
	var hues := {}
	for r in seats:
		names[r] = seats[r]["name"]
		hues[r] = seats[r]["hue"]
	var common := {"code": code, "mode": mode, "options": options, "names": names, "hues": hues,
			"teams": world.rules.teams, "map": world.map_bytes if include_map else PackedByteArray(),
			"sub_hp": world.terrain.get_modified(), "round_state": _with_grace(world.round_state())}
	var frame := world.world_state()
	var accounts := world.time_economy.state_payload() if world.time_economy != null else {}
	var targets := seats.keys() if only_role == 0 else [only_role]
	for role in targets:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0:
			seat["ready"] = false
			var payload := common.merged({"role": role, "frame": world.state_for(role, frame, accounts)})
			NetBus.send_event(NetEvent.Kind.BASELINE, payload, seat["peer"])

func _on_input(peer: int, packet: Array) -> void:
	var role := role_of(peer)
	if world != null and role != 0 and seats[role]["ready"]:
		world.accept_input(role, packet)

func _on_left(peer: int) -> void:
	guests.erase(peer)
	var role := role_of(peer)
	if not seats.has(role):
		return
	seats[role]["peer"] = 0
	seats[role]["deadline"] = Time.get_ticks_msec() / 1000.0 + GRACE_SECONDS
	seats[role]["ready"] = false
	_returned.erase(role)
	if world == null:
		broadcast_room.call_deferred()
		return
	world.clear_input(role)
	if world.rules.phase == NetEvent.RoundState.MATCH_OVER and _returned.size() == online_count():
		return_to_room()
	else:
		world.broadcast_round()

func rejoin(peer: int, target_code: String, token: String) -> void:
	var seated_role := role_of(peer)
	for role in seats:
		if code == target_code and seats[role]["token"] == token and (seated_role == 0 or seated_role == role):
			seats[role]["peer"] = peer
			seats[role]["deadline"] = 0.0
			if world != null:
				world.new_epoch(role)
				send_baselines(true, role)
				world.broadcast_round()
			else:
				broadcast_room()
			return
	NetBus.send_event(NetEvent.Kind.REJOIN_DENIED, "席位已过期", peer)

func _with_grace(state: Dictionary) -> Dictionary:
	var grace := {}
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats:
		var deadline: float = seats[role]["deadline"]
		if deadline > 0.0:
			grace[role] = deadline - now
	state["grace"] = grace
	return state

func remove_seat(role: int) -> void:
	if role == host_role:
		_broadcast(NetEvent.Kind.ROOM_CLOSED, "房主已离开", role)
		_discard_world()
		seats.clear()
		_returned.clear()
		code = ""
		return
	if world != null:
		if world.rules.phase == NetEvent.RoundState.WAITING:
			_discard_world()
		else:
			world.remove_role(role)
	seats.erase(role)
	broadcast_room()

func online_count() -> int:
	return seats.values().filter(func(seat: Dictionary) -> bool: return seat["peer"] != 0).size()

func return_to_room() -> void:
	_discard_world()
	_returned.clear()
	broadcast_room()

func _discard_world() -> void:
	if world == null:
		return
	remove_child(world)
	world.queue_free()
	world = null

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats.keys():
		if seats[role]["deadline"] > 0 and now >= seats[role]["deadline"]:
			remove_seat(role)
			if role == host_role:
				return
