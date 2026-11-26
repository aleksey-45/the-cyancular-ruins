class_name RoomSession
extends Node

const GRACE_SECONDS := 60.0
const LanBeaconScript := preload("res://core/net/lan_beacon.gd")
var code := ""
var mode := WorldSpec.DUEL
var options := RoomOptions.normalized(WorldSpec.DUEL, {})
var seats: Dictionary = {}
var _match_info := {}
var host_role := 1
var session: MatchHost
var world: MatchWorld:
	get: return session.world if session != null else null
var _published_terrain := 0
var _returned: Dictionary = {}
var _beacon: LanBeaconScript

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_arg := args.find("--port")
	var port := int(args[port_arg + 1]) if port_arg >= 0 else NetBus.DEFAULT_PORT
	var error := NetBus.start_server(port)
	if error != OK:
		push_error("服务器绑定失败: %d" % error)
		get_tree().quit(1)
		return
	NetBus.event_received.connect(_on_event)
	NetBus.input_received.connect(_on_input)
	NetBus.peer_left.connect(_on_left)
	print("SERVER READY port=%d" % NetBus.server_port)

func _physics_process(_delta: float) -> void:
	_expire_seats()
	if world == null or world.finished:
		return
	var started := PerformanceStats.begin()
	var previous := world.rules.phase
	if previous == MatchRules.Phase.WAITING and seats.values().all(func(seat: Dictionary) -> bool: return seat["ready"]):
		session.enqueue(MatchWorld.Command.START)
	var sim_started := PerformanceStats.begin()
	session.fixed_step()
	PerformanceStats.end(PerformanceStats.SERVER_SIMULATION, sim_started)
	var phase := world.rules.phase
	var new_round := phase == MatchRules.Phase.WAITING and phase != previous
	var terrain := world.terrain
	if terrain.version != _published_terrain:
		if not new_round:
			_broadcast(NetEvent.Kind.TERRAIN, {"version": terrain.version, "cells": terrain.changes_since(_published_terrain)})
		_published_terrain = terrain.version
		terrain.forget_before(_published_terrain)
	if new_round:
		send_baselines(0, NetEvent.Kind.ROUND)
	elif world.tick % 2 == 0 or not world.combat.hits.is_empty() or phase != previous:
		_send_state(phase == MatchRules.Phase.MATCH_OVER)
	PerformanceStats.end(PerformanceStats.SERVER_TICK, started)

func _on_event(peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.CREATE:
			if not code.is_empty():
				message(peer, "本进程已有房间")
				return
			mode = data["mode"]
			options = RoomOptions.normalized(mode, data["options"])
			code = "%08d" % (randi() % 100000000)
			add_seat(peer, data)
			_start_beacon()
			broadcast_room()
		NetEvent.Kind.JOIN:
			var role := role_of(peer)
			if data["code"] != code or code.is_empty():
				message(peer, "房间不存在")
			elif options["beta"] != data["beta"]:
				var beta: bool = options["beta"]
				message(peer, "该房间为「%s」，请从「%s」进入" % [
						PvpSession.mode_name(mode, beta), "Beta" if beta else "多人模式"])
			elif role != 0:
				broadcast_room(role)
			elif world != null or seats.size() >= max_players():
				message(peer, "房间已满")
			else:
				add_seat(peer, data)
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
			if world != null and role != 0 and int(data) == world.rules.round_number:
				seats[role]["ready"] = true
		NetEvent.Kind.SUICIDE:
			var role := role_of(peer)
			if world != null and role != 0:
				session.enqueue(MatchWorld.Command.SUICIDE, role)
		NetEvent.Kind.LEAVE:
			var role := role_of(peer)
			if not seats.has(role):
				return
			if world != null and world.finished:
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
	return RoomOptions.capacity(mode, options)

func map_path() -> String:
	return str(options["map"])

# 团队模式将新玩家分到人数较少的一队。人数相同时优先选尚有空位的 A 队。
func add_seat(peer: int, guest: Dictionary) -> void:
	var role := 1
	while seats.has(role):
		role += 1
	var team := 0
	if mode == WorldSpec.TEAM:
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

# 换队前检查目标队是否有空位。玩家已在该队时，自己的位置不计入这次检查。
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

# 房间状态包含玩家名单、分队和房主角色 ID，供客户端更新大厅界面。
func room_data() -> Dictionary:
	var roster: Array = []
	for role in seats:
		roster.append({"role": role, "name": seats[role]["name"], "team": seats[role]["team"]})
	return {"code": code, "mode": mode, "map": map_path(), "players": roster,
			"max_players": max_players(), "match_time": options["match_time"],
			"host_role": host_role, "in_match": world != null, "beta": options["beta"],
			"player_collision": options["player_collision"],
			"can_start": world == null and _start_problem().is_empty()}

func broadcast_room(only_role: int = 0) -> void:
	var base := room_data()
	for role in seats.keys() if only_role == 0 else [only_role]:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0:
			var payload := base.merged({"your_role": role, "token": seat["token"]})
			NetBus.send_event(NetEvent.Kind.ROOM, payload, seat["peer"])

# 建房成功后按房间选项 lan_public 决定是否启动局域网广播。
func _start_beacon() -> void:
	_stop_beacon()
	if not options["lan_public"]:
		return
	_beacon = LanBeaconScript.new()
	_beacon.start(_lan_info)


func _stop_beacon() -> void:
	if _beacon != null:
		_beacon.stop()
		_beacon = null


# 广播包中的 port 是游戏服务器的监听端口。等待玩家加入时也会广播。
func _lan_info() -> Dictionary:
	return {"code": code, "mode": mode, "players": seats.size(), "max": max_players(),
		"in_match": world != null, "beta": options["beta"], "port": NetBus.server_port}


func _exit_tree() -> void:
	_stop_beacon()
	_close_match()


## 团队对抗要求所有房间成员均已连接，且两队各有至少一名玩家、都没有超过每队上限。
func team_ready() -> bool:
	if mode != WorldSpec.TEAM:
		return false
	for role in seats:
		if seats[role]["peer"] == 0:
			return false
	return not TeamRules.team_counts(_seat_teams()).is_empty()

func _start_problem() -> String:
	if mode == WorldSpec.TEAM:
		return "" if team_ready() else "A 队 %d 人、B 队 %d 人，每队 1~%d 人且全部在线才能开始" % [
				team_count(1), team_count(2), TeamRules.MAX_TEAM]
	var online := online_count()
	if mode == WorldSpec.DUEL and online != max_players():
		return "1v1 需要两名在线玩家"
	if online < RoomOptions.MIN_PLAYERS:
		return "至少需要 %d 名在线玩家" % RoomOptions.MIN_PLAYERS
	if online != seats.size():
		return "所有席位在线后才能开始"
	return ""

func start_match() -> void:
	var teams := _seat_teams() if mode == WorldSpec.TEAM else {}
	var paths: Array[String] = [map_path()]
	if map_path().is_empty():
		paths = MapCatalog.shuffled_paths()
	var problem := "没有可用的联机地图"
	var seed := randi()
	for path in paths:
		var bytes := CyrmMap.read_bytes(path)
		var map := CyrmMap.from_bytes(bytes)
		if map.is_empty():
			problem = "无法读取地图 %s" % path
			continue
		var spec := WorldSpec.arena(map, mode, seats.keys(), teams, options, seed)
		problem = spec.problem()
		if problem.is_empty():
			session = MatchHost.new(spec)
			var names := {}
			var hues := {}
			for role: int in seats:
				names[role] = seats[role]["name"]
				hues[role] = seats[role]["hue"]
			_match_info = {"code": code, "mode": mode, "options": options, "names": names, "hues": hues,
				"teams": spec.teams, "map": bytes, "roles": spec.roles, "seed": spec.seed}
			_published_terrain = world.terrain.version
			send_baselines()
			return
		problem = "地图 %s：%s" % [path, problem]
	message(int(seats[host_role]["peer"]), problem)

func _send_state(final: bool) -> void:
	var started := PerformanceStats.begin()
	var batch: NetCodec.StateBatch
	var final_peers := PackedInt32Array()
	for role: int in world.players:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0 and (final or seat["ready"]):
			var prepare := PerformanceStats.begin()
			if batch == null:
				batch = NetCodec.StateBatch.new(session.packet(_grace()))
			PerformanceStats.end(PerformanceStats.STATE_PREPARE, prepare)
			if final:
				final_peers.append(seat["peer"])
			else:
				NetBus.send_state(seat["peer"], session.remote[role].feedback, batch)
	if not final_peers.is_empty():
		NetBus.send_final_state(final_peers, batch)
	if batch != null:
		PerformanceStats.end(PerformanceStats.STATE_FANOUT, started)

func _broadcast(kind: int, data: Variant, except_role := 0) -> void:
	var peers := PackedInt32Array()
	for role in seats:
		if role != except_role and seats[role]["peer"] != 0:
			peers.append(seats[role]["peer"])
	NetBus.broadcast_event(kind, data, peers)

func send_baselines(only_role := 0, kind := NetEvent.Kind.BASELINE) -> void:
	var common := _match_info.duplicate() if kind == NetEvent.Kind.BASELINE else {}
	common["sub_hp"] = world.terrain.get_modified()
	var frame := session.packet(_grace())
	var batch := NetCodec.StateBatch.new(frame)
	var targets := seats.keys() if only_role == 0 else [only_role]
	for role in targets:
		var seat: Dictionary = seats[role]
		if seat["peer"] != 0:
			seat["ready"] = false
			var payload := common.merged({"role": role, "frame": frame.merged({"input_feedback": session.remote[role].feedback}, true)})
			NetBus.send_event(kind, payload, seat["peer"], batch)

func _on_input(peer: int, packet: Array, received_us: int) -> void:
	var role := role_of(peer)
	if world != null and role != 0 and seats[role]["ready"]:
		session.accept_input(role, packet, received_us)

func _on_left(peer: int) -> void:
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
	session.remote[role].reset(session.remote[role].epoch)
	if world.finished and _returned.size() == online_count():
		return_to_room()

func rejoin(peer: int, target_code: String, token: String) -> void:
	var seated_role := role_of(peer)
	for role in seats:
		if code == target_code and seats[role]["token"] == token and (seated_role == 0 or seated_role == role):
			seats[role]["peer"] = peer
			seats[role]["deadline"] = 0.0
			if world != null:
				session.remote[role].reset(session.remote[role].epoch + 1)
				send_baselines(role)
			else:
				broadcast_room()
			return
	NetBus.send_event(NetEvent.Kind.REJOIN_DENIED, "席位已过期", peer)

func _grace() -> Dictionary:
	var grace := {}
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats:
		var deadline: float = seats[role]["deadline"]
		if deadline > 0.0:
			grace[role] = deadline - now
	return grace

func remove_seat(role: int) -> void:
	if role == host_role:
		_broadcast(NetEvent.Kind.ROOM_CLOSED, "房主已离开", role)
		_stop_beacon()
		_close_match()
		seats.clear()
		_returned.clear()
		code = ""
		return
	if world != null:
		if world.rules.phase == MatchRules.Phase.WAITING:
			_close_match()
		else:
			session.enqueue(MatchWorld.Command.LEAVE, role)
	seats.erase(role)
	broadcast_room()

func online_count() -> int:
	return seats.values().filter(func(seat: Dictionary) -> bool: return seat["peer"] != 0).size()

func return_to_room() -> void:
	_close_match()
	_returned.clear()
	broadcast_room()

func _close_match() -> void:
	if session != null:
		world.close()
		session = null
		_match_info.clear()

func _expire_seats() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in seats.keys():
		if seats[role]["deadline"] > 0 and now >= seats[role]["deadline"]:
			remove_seat(role)
			if role == host_role:
				return
	if _beacon != null:
		_beacon.tick(now)
