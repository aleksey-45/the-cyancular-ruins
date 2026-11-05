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
			mode = data["mode"]
			options = data["options"]
			code = "%08d" % (randi() % 100000000)
			add_seat(peer)
			broadcast_room()
		NetEvent.Kind.LIST:
			var rooms: Array = []
			if not code.is_empty() and options.get("beta", false) == data["beta"]:
				var entry := room_data()
				entry["joinable"] = world == null and seats.size() < max_players()
				entry["rejoinable"] = seats.values().any(func(seat: Dictionary) -> bool: return seat["token"] == data["token"])
				rooms.append(entry)
			NetBus.send_event(NetEvent.Kind.ROOMS, rooms, peer)
		NetEvent.Kind.JOIN:
			if data["code"] != code or code.is_empty():
				message(peer, "房间不存在")
			elif world != null or seats.size() >= max_players():
				message(peer, "房间已满")
			elif options.get("beta", false) != data["beta"]:
				var beta: bool = options.get("beta", false)
				message(peer, "该房间为「%s」，请从「%s」进入" % [
						PvpSession.mode_name(mode, beta), "Beta" if beta else "多人模式"])
			else:
				add_seat(peer)
				broadcast_room()
		NetEvent.Kind.PICK_TEAM:
			var role := role_of(peer)
			if world == null and seats.has(role):
				_pick_team(peer, role, int(data))
		NetEvent.Kind.START:
			if role_of(peer) == host_role and world == null:
				if mode == PvpSession.MODE_PVP and online_count() != max_players():
					message(peer, "1v1 需要两名在线玩家")
				elif mode == PvpSession.MODE_TEAM and not team_ready():
					message(peer, _team_start_message())
				elif online_count() < 2:
					message(peer, "至少需要两名在线玩家")
				elif mode == PvpSession.MODE_TEAM:
					var problem := MatchRules.validate_team_spawns(map_path(), _seat_teams())
					if problem.is_empty():
						start_match()
					else:
						message(peer, problem)
				else:
					start_match()
		NetEvent.Kind.MAP:
			if role_of(peer) == host_role and world == null:
				options["map"] = data
				broadcast_room()
		NetEvent.Kind.REJOIN:
			rejoin(peer, data["code"], data["token"])
		NetEvent.Kind.READY:
			var role := role_of(peer)
			if world == null or role == 0 or not seats.has(role) or not world.players.has(role):
				return
			if int(data) != world._round_num or world._round_state == NetEvent.RoundState.MATCH_OVER:
				return
			seats[role]["ready"] = true
			_start_countdown_if_ready()
		NetEvent.Kind.SUICIDE:
			var role := role_of(peer)
			if world != null and world._round_state == NetEvent.RoundState.PLAYING and world.players.has(role):
				world.players[role].last_attacker = 0
				world.players[role].combat.force_down()
		NetEvent.Kind.LEAVE:
			var role := role_of(peer)
			if not seats.has(role):
				return
			if world != null and world._round_state == NetEvent.RoundState.MATCH_OVER:
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

# 只产出线路会编码的字段；names、team_counts、host_name 等派生数据由客户端从 players 还原。
func room_data() -> Dictionary:
	var roster: Array = []
	for role in seats:
		roster.append({"role": role, "name": seats[role]["name"], "team": seats[role]["team"]})
	return {"code": code, "mode": mode, "map": options.get("map", "res://maps/newfactory.cyrm"), "players": roster,
			"max_players": max_players(), "match_time": options.get("match_time", 300),
			"host_role": host_role, "in_match": world != null, "beta": options.get("beta", false)}

func broadcast_room() -> void:
	var base := room_data()
	for role in seats:
		if seats[role]["peer"] != 0:
			var payload := base.duplicate()
			payload["your_role"] = role
			payload["token"] = seats[role]["token"]
			NetBus.send_event(NetEvent.Kind.ROOM, payload, seats[role]["peer"])

## 团队可开局：模式正确、所有席位在线，且唯一一次阵容校验通过。
func team_ready() -> bool:
	if mode != PvpSession.MODE_TEAM:
		return false
	for role in seats:
		if seats[role]["peer"] == 0:
			return false
	return not TeamRules.team_counts(_seat_teams()).is_empty()

func _team_start_message() -> String:
	return "A 队 %d 人、B 队 %d 人；每队 1~%d 人且全部在线才能开始" % [
			team_count(1), team_count(2), TeamRules.MAX_TEAM]

func start_match() -> void:
	var roles: Array = []
	var teams := {}
	for role in seats:
		if seats[role]["peer"] != 0:
			roles.append(role)
			if mode == PvpSession.MODE_TEAM:
				teams[role] = seats[role]["team"]
	world = AuthorityWorld.new()
	add_child(world)
	world.setup(mode, map_path(), roles, teams, options)
	# 出生点规划失败时 setup 会在创建任何角色前退出；不能带着不完整阵容开始。
	if world.players.size() != roles.size():
		if seats.has(host_role):
			message(int(seats[host_role]["peer"]), "出生点或对局初始化失败，无法开始")
		_discard_world()
		return
	world.state_ready.connect(_send_state)
	world.event.connect(_broadcast)
	world.baseline_needed.connect(send_baselines)
	send_baselines()

func _send_state(frame: Dictionary, targets: Array) -> void:
	var perf_fanout := PerformanceStats.begin()
	var batch: NetCodec.StateBatch
	for role in seats:
		if targets.has(role) and seats[role]["peer"] != 0 and seats[role]["ready"]:
			var perf_prepare := PerformanceStats.begin()
			var state := world.state_for(role, frame, batch.time if batch != null else null)
			if batch == null: batch = NetCodec.StateBatch.new(state)
			PerformanceStats.end(PerformanceStats.STATE_PREPARE, perf_prepare)
			NetBus.send_state(seats[role]["peer"], state, batch)
	if batch != null: PerformanceStats.end(PerformanceStats.STATE_FANOUT, perf_fanout)

func _broadcast(kind: int, data: Variant, except_role: int) -> void:
	var peers := PackedInt32Array()
	for role in seats:
		if role != except_role and seats[role]["peer"] != 0:
			peers.append(seats[role]["peer"])
	NetBus.broadcast_event(kind, data, peers)

func send_baselines() -> void:
	for role in seats:
		if seats[role]["peer"] != 0:
			send_baseline(role)

func baseline_for(role: int) -> Dictionary:
	var names := {}
	var hues := {}
	for r in seats:
		names[r] = seats[r]["name"]
		hues[r] = seats[r]["hue"]
	return {"code": code, "mode": mode, "role": role, "options": options, "names": names, "hues": hues,
			"teams": world.rules.teams, "spawns": world.rules.spawns, "map": FileAccess.get_file_as_bytes(MazeGenerator.map_file_path()),
			"sub_hp": world.terrain.get_modified(), "round_state": world.round_state(),
			"frame": world.state_for(role, world.world_state()), "projectiles": world.projectile_states()}

func send_baseline(role: int) -> void:
	seats[role]["ready"] = false
	var payload := baseline_for(role)
	NetBus.send_event(NetEvent.Kind.BASELINE, payload, seats[role]["peer"])

# 最后一个 READY 才把 WAITING 推进为 COUNTDOWN；重复 READY 不重启倒计时。
func _start_countdown_if_ready() -> void:
	if world == null or world._round_state != NetEvent.RoundState.WAITING:
		return
	if not _all_seats_ready():
		return
	assert(seats.size() == world.players.size(), "RoomSession: 席位与对局角色数量不一致")
	for role in seats:
		assert(world.players.has(role), "RoomSession: 席位角色 %d 不在对局中" % int(role))
	world._round_state = NetEvent.RoundState.COUNTDOWN
	world._round_timer = 3.0
	world.broadcast_round()

func _all_seats_ready() -> bool:
	if world == null or seats.size() < 2:
		return false
	for role in seats:
		if seats[role]["peer"] == 0 or not bool(seats[role]["ready"]):
			return false
		if not world.players.has(role):
			return false
	return true

func _on_input(peer: int, packet: Dictionary) -> void:
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
	if world != null:
		world.players[role].input_buffer.frames.clear()
		world.players[role].input_source.reset_state()
		update_grace()
		if world._round_state == NetEvent.RoundState.MATCH_OVER and _returned.size() == online_count():
			return_to_room()
	else:
		broadcast_room.call_deferred()

func rejoin(peer: int, target_code: String, token: String) -> void:
	for role in seats:
		if code == target_code and seats[role]["token"] == token:
			seats[role]["peer"] = peer
			seats[role]["deadline"] = 0.0
			if world != null:
				world.new_epoch(role)
				send_baseline(role)
				update_grace()
			else:
				broadcast_room()
			return
	NetBus.send_event(NetEvent.Kind.REJOIN_DENIED, "席位已过期", peer)

func update_grace() -> void:
	world.grace_snapshot.clear()
	for role in seats:
		if seats[role]["deadline"] > 0:
			world.grace_snapshot[role] = seats[role]["deadline"] - Time.get_ticks_msec() / 1000.0
	world.broadcast_round.call_deferred()

func remove_seat(role: int) -> void:
	if role == host_role:
		_broadcast(NetEvent.Kind.ROOM_CLOSED, "房主已离开", role)
		_discard_world()
		seats.clear()
		_returned.clear()
		code = ""
		return
	if world != null and world._round_state == NetEvent.RoundState.WAITING:
		_cancel_waiting_match()
	if world != null and world.players.has(role):
		world.remove_role(role)
	seats.erase(role)
	if seats.is_empty():
		_discard_world()
		code = ""
	broadcast_room()

func online_count() -> int:
	return seats.values().filter(func(seat: Dictionary) -> bool: return seat["peer"] != 0).size()

func return_to_room() -> void:
	_discard_world()
	_returned.clear()
	broadcast_room()

## 释放当前对局节点；重复调用、已入队释放或已脱离父节点都安全。
func _discard_world() -> void:
	if world == null or not is_instance_valid(world) or world.is_queued_for_deletion():
		world = null
		return
	if world.get_parent() == self:
		remove_child(world)
	world.queue_free()
	world = null

# WAITING 中席位到期离场：明确取消未开始的对局并返回房间。
func _cancel_waiting_match() -> void:
	if world == null or world._round_state != NetEvent.RoundState.WAITING:
		return
	_discard_world()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats.keys():
		if seats[role]["deadline"] > 0 and now >= seats[role]["deadline"]:
			# WAITING 对局只由 remove_seat() 取消，避免同一席位触发两次取消。
			remove_seat(role)
			if role == host_role:
				return
