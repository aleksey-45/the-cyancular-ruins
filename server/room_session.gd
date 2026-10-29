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
				if options.get("is_public", true) or entry["rejoinable"]:
					rooms.append(entry)
			NetBus.send_event(NetEvent.Kind.ROOMS, rooms, peer)
		NetEvent.Kind.JOIN:
			if data["code"] != code or code.is_empty():
				message(peer, "房间不存在")
			elif world != null or seats.size() >= max_players():
				message(peer, "房间已满")
			elif options.get("beta", false) != data["beta"]:
				message(peer, "房间玩法不同")
			elif not options.get("is_public", true) and data["invite"] != options.get("invite_code", ""):
				message(peer, "邀请码错误")
			else:
				add_seat(peer)
				broadcast_room()
		NetEvent.Kind.PICK_TEAM:
			var role := role_of(peer)
			if world == null and seats.has(role):
				var count := 0
				for seat in seats.values():
					if seat["team"] == data:
						count += 1
				if count < 3:
					seats[role]["team"] = data
					broadcast_room()
		NetEvent.Kind.START:
			if role_of(peer) == host_role and world == null:
				if mode == PvpSession.MODE_PVP and online_count() != max_players():
					message(peer, "1v1 需要两名在线玩家")
				elif mode == PvpSession.MODE_TEAM and not team_ready():
					message(peer, "两队各需 3 人")
				elif online_count() < 2:
					message(peer, "至少需要两名在线玩家")
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
			if world != null and world.players.has(role) and data == world._round_num:
				seats[role]["ready"] = true
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
	return 6 if mode == PvpSession.MODE_TEAM else (2 if mode == PvpSession.MODE_PVP else int(options.get("max_players", 8)))

func add_seat(peer: int) -> void:
	var role := 1
	while seats.has(role):
		role += 1
	var guest: Dictionary = guests[peer]
	var team := 0
	if mode == PvpSession.MODE_TEAM:
		team = 1 if seats.values().filter(func(seat: Dictionary) -> bool: return seat["team"] == 1).size() < 3 else 2
	seats[role] = {"peer": peer, "token": Crypto.new().generate_random_bytes(16).hex_encode(),
			"name": guest["name"], "hue": guest["hue"], "team": team, "deadline": 0.0, "ready": false}

func room_data() -> Dictionary:
	var roster: Array = []
	var names: Array = []
	var teams := {}
	var team_counts := {0: 0, 1: 0, 2: 0}
	for role in seats:
		roster.append({"role": role, "name": seats[role]["name"], "team": seats[role]["team"]})
		names.append(seats[role]["name"])
		teams[role] = seats[role]["team"]
		team_counts[seats[role]["team"]] += 1
	return {"code": code, "mode": mode, "map": options.get("map", "res://maps/newfactory.cyrm"), "players": roster,
			"names": names, "count": seats.size(), "max_players": max_players(), "team_size": 3,
			"teams": teams, "team_counts": team_counts, "match_time": options.get("match_time", 300),
			"is_public": options.get("is_public", true), "host_role": host_role, "in_match": world != null,
			"beta": options.get("beta", false), "host_name": seats[host_role]["name"] if seats.has(host_role) else ""}

func broadcast_room() -> void:
	for role in seats:
		if seats[role]["peer"] != 0:
			var payload := room_data()
			payload["invite_code"] = options.get("invite_code", "")
			payload["your_role"] = role
			payload["token"] = seats[role]["token"]
			NetBus.send_event(NetEvent.Kind.ROOM, payload, seats[role]["peer"])

func team_ready() -> bool:
	return online_count() == 6 and seats.values().filter(func(seat: Dictionary) -> bool: return seat["team"] == 1).size() == 3

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
	world.setup(mode, options.get("map", "res://maps/newfactory.cyrm"), roles, teams, options)
	world.state_ready.connect(_send_state)
	world.event.connect(_broadcast)
	world.baseline_needed.connect(send_baselines)
	send_baselines()

func _send_state(frame: Dictionary, targets: Array) -> void:
	var batch: NetCodec.StateBatch
	for role in seats:
		if targets.has(role) and seats[role]["peer"] != 0 and seats[role]["ready"]:
			var state := world.state_for(role, frame, batch.time if batch != null else null)
			if batch == null: batch = NetCodec.StateBatch.new(state)
			NetBus.send_state(seats[role]["peer"], state, batch)

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
	_returned.erase(role)
	if world != null:
		seats[role]["ready"] = false
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
		if world != null:
			remove_child(world)
			world.queue_free()
			world = null
		seats.clear()
		_returned.clear()
		code = ""
		return
	if world != null and world.players.has(role):
		world.remove_role(role)
	seats.erase(role)
	if seats.is_empty():
		if world != null:
			world.queue_free()
			world = null
		code = ""
	broadcast_room()

func online_count() -> int:
	return seats.values().filter(func(seat: Dictionary) -> bool: return seat["peer"] != 0).size()

func return_to_room() -> void:
	remove_child(world)
	world.queue_free()
	world = null
	_returned.clear()
	broadcast_room()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats.keys():
		if seats[role]["deadline"] > 0 and now >= seats[role]["deadline"]:
			remove_seat(role)
			if role == host_role:
				return
