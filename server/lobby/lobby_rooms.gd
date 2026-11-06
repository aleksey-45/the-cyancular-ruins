class_name LobbyRooms
extends Node


signal pairing_ready(room)

const ROYALE_MIN_PLAYERS := 2
const ROYALE_MAX_PLAYERS := ModeDefs.ROLE_MAX
const ROYALE_DEFAULT_MAX := 4

const TEAM_SIZE := ModeDefs.TEAM_SIZE
const TEAM_ROLES := ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT

const Room = RoomTypes.Room
const RoyaleRoom = RoomTypes.Room
const TeamRoom = RoomTypes.Room

var launcher: WorkerLauncher = null
var rejoin := RejoinRegistry.new()
var _registry := RoomRegistry.new()

var rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_PVP)
var royale_rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_ROYALE)
var team_rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_TEAM)

# 昵称表(与 registry 同一份,不是第二份真相):读走它,写走 _registry.set_name / drop_name。
var _peer_names: Dictionary:
	get:
		return _registry.peer_names
var peer_names: Dictionary:
	get:
		return _registry.peer_names
var registry: RoomRegistry:
	get:
		return _registry



func _enter_tree() -> void:
	NetBus.room_create_requested.connect(create_room)
	NetBus.room_join_requested.connect(join_room)
	NetBus.room_list_requested.connect(on_list_rooms)
	NetBus.lobby_name_set.connect(on_lobby_name)
	NetBus.peer_left.connect(on_peer_left)
	NetBusExt.royale_create_requested.connect(royale_create)
	NetBusExt.royale_join_requested.connect(royale_join)
	NetBusExt.royale_leave_requested.connect(royale_leave)
	NetBusExt.royale_list_requested.connect(royale_list)
	NetBusExt.team_create_requested.connect(team_create)
	NetBusExt.team_join_requested.connect(team_join)
	NetBusExt.team_pick_requested.connect(team_pick)
	NetBusExt.team_leave_requested.connect(team_leave)
	NetBusExt.team_list_requested.connect(team_list)
	NetBusExt.rejoin_requested.connect(on_rejoin_request)

func _exit_tree() -> void:
	NetBus.room_create_requested.disconnect(create_room)
	NetBus.room_join_requested.disconnect(join_room)
	NetBus.room_list_requested.disconnect(on_list_rooms)
	NetBus.lobby_name_set.disconnect(on_lobby_name)
	NetBus.peer_left.disconnect(on_peer_left)
	NetBusExt.royale_create_requested.disconnect(royale_create)
	NetBusExt.royale_join_requested.disconnect(royale_join)
	NetBusExt.royale_leave_requested.disconnect(royale_leave)
	NetBusExt.royale_list_requested.disconnect(royale_list)
	NetBusExt.team_create_requested.disconnect(team_create)
	NetBusExt.team_join_requested.disconnect(team_join)
	NetBusExt.team_pick_requested.disconnect(team_pick)
	NetBusExt.team_leave_requested.disconnect(team_leave)
	NetBusExt.team_list_requested.disconnect(team_list)
	NetBusExt.rejoin_requested.disconnect(on_rejoin_request)

func on_lobby_name(caller: int, name: String) -> void:
	_registry.set_name(caller, name if not name.is_empty() else "Anon")

# 房间列表的纯构造(不含发送)。★ 抽出来是为了可测:探针没有对端,NetBus.reply 会静默跳过 ⇒ 列表内容观测不到。
# ★ 对局中的房照列:第三人要看得见它,而「进不去」由 join_room 那侧的 in_match 守卫保证;那一行的名单取冻结的那份。
func room_list_payload() -> Array:
	return _registry.list_payload(ModeDefs.MODE_PVP)


func on_list_rooms(caller: int) -> void:
	NetBus.reply(caller, "room_list", room_list_payload())

# 把「开局那一刻在房里的名单」冻进房记录(role + 昵称快照)。★ 谁调:RoomManager 在每一处开局调一次(_start_match / royale_start /
# royale_start_ai / team_start)—— 那是「这一局有哪些人」唯一确定的时刻。★ 名单错了不报错,只会让第三人看到「玩家, 玩家」。
func freeze_roster(room) -> void:
	_registry.freeze_roster(room)


func create_room(caller: int) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在对抗房间,请先退出再创建 1v1 房间")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再创建 1v1 房间")
		return
	if _in_1v1_room(caller):

		NetBus.reply(caller, "server_message", "你已经在房间里了")
		return
	var code := _registry.next_code(ModeDefs.MODE_PVP)
	var room := RoomTypes.Room.new()
	room.mode = ModeDefs.MODE_PVP
	room.code = code
	room.host_peer = caller
	room.max_players = 2
	room.players.append(caller)
	room.player_role[caller] = 1
	room.created_at = Time.get_unix_time_from_system()
	_registry.add(room)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_PVP, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家"))})
	NetBus.reply(caller, "room_created", code)
	WaitRoomBroadcast.flush_pvp.call_deferred(self, room)

func join_room(caller: int, code: String) -> void:
	var room: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_PVP)
	if room == null:
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	if _in_1v1_room(caller):
		NetBus.reply(caller, "server_message", "你已经在房间里了")
		return
	if room.in_match:
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if room.started:
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if room.players.size() >= 2:
		NetBus.reply(caller, "server_message", "房间已满")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再加入 1v1 房间")
		return
	if _in_team_room(caller):

		NetBus.reply(caller, "server_message", "你已在对抗房间,请先退出再加入 1v1 房间")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_PVP, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "players": room.players.size()})
	NetBus.reply(caller, "room_joined", 2)

	WaitRoomBroadcast.flush_pvp.call_deferred(self, room)

func on_peer_left(peer_id: int) -> void:
	_registry.drop_name(peer_id)
	for mode in ModeDefs.MODE_IDS:
		for code in _registry.of(mode).keys():
			var room: RoomTypes.Room = _registry.of(mode)[code]
			if not room.players.has(peer_id):
				continue
			var n_before := room.players.size()
			room.players.erase(peer_id)
			room.player_role.erase(peer_id)
			if room.in_match:
				NetDiag.audit("player_detach", {"room": str(code), "mode": mode, "peer": peer_id})
			else:
				NetDiag.audit("player_leave", {"room": str(code), "mode": mode, "peer": peer_id,
						"players": n_before - 1})
			if room.is_team():
				_prune_team_of(room)
			if room.in_match:
				continue
			if room.players.is_empty():
				teardown_room(room, LobbyRooms.TEARDOWN_DELAYED, "", false, "empty")
				continue
			if room.is_duel():
				WaitRoomBroadcast.flush_pvp.call_deferred(self, room)
				continue
			if room.host_peer == peer_id:
				room.host_peer = room.players[0]
				NetDiag.audit("host_transfer", {"room": str(code), "mode": mode,
						"from_peer": peer_id, "to_peer": room.host_peer})
			if not room.in_match:
				_broadcast_state(room)

func _prune_team_of(room: RoomTypes.Room) -> void:
	for r in room.team_of.keys():
		if not room.player_role.values().has(int(r)):
			room.team_of.erase(r)


func _broadcast_state(room: RoomTypes.Room) -> void:
	if room.is_royale():
		_broadcast_royale_state(room)
	elif room.is_team():
		_broadcast_team_state(room)
	elif room.is_duel():
		WaitRoomBroadcast.flush_pvp.call_deferred(self, room)


func _broadcast_royale_state(rr: RoomTypes.Room) -> void:
	WaitRoomBroadcast.flush_royale.call_deferred(self, rr)

func royale_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_ROYALE, caller)


func _in_1v1_room(caller: int) -> bool:
	return _registry.room_of_peer(ModeDefs.MODE_PVP, caller) != null


func pvp_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_PVP, caller)


func pvp_start(caller: int) -> void:
	var room := pvp_room_of(caller)
	if room == null:
		return
	if room.started or room.in_match:
		return
	if room.players.is_empty() or room.players[0] != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if room.players.size() < 2:
		NetBus.reply(caller, "server_message", "等待对手加入")
		return
	pairing_ready.emit(room)



func royale_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在对抗房间,请先退出再创建大乱斗房间")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.reply(caller, "server_message", "你已在 1v1 房间,请先退出再创建大乱斗房间")
		return
	var code := _registry.next_code(ModeDefs.MODE_ROYALE)
	var rr := RoomTypes.Room.new()
	rr.mode = ModeDefs.MODE_ROYALE
	rr.code = code
	rr.host_peer = caller
	rr.players.append(caller)
	rr.player_role[caller] = 1
	rr.created_at = Time.get_unix_time_from_system()
	rr.is_public = bool(opts.get("is_public", true))
	rr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not rr.is_public and rr.invite_code.is_empty():
		rr.invite_code = _registry.generate_code()
	var n := int(opts.get("max_players", ROYALE_DEFAULT_MAX))
	rr.max_players = clampi(n, ROYALE_MIN_PLAYERS, ROYALE_MAX_PLAYERS)
	rr.match_time = int(opts.get("match_time", 0))

	rr.beta = bool(opts.get("beta", false))
	rr.time_rules = opts.get("time", {}) if rr.beta else {}
	_registry.add(rr)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "cap": rr.max_players,
			"public": rr.is_public, "beta": rr.beta})
	_broadcast_royale_state(rr)

func royale_join(caller: int, code: String, invite: String, beta: bool) -> void:
	var rr: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_ROYALE)
	if rr == null:
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	if rr.beta and not beta:
		NetBus.reply(caller, "server_message", "这是时间玩法(Beta)房间,请从主菜单 Beta 页进入")
		return
	if not rr.beta and beta:
		NetBus.reply(caller, "server_message", "这是普通大乱斗房间,请从主菜单「大乱斗」进入")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.reply(caller, "server_message", "你已在 1v1 房间,请先退出再加入大乱斗房间")
		return
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在对抗房间,请先退出再加入大乱斗房间")
		return
	if rr.in_match:

		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if rr.players.size() >= rr.max_players:
		NetBus.reply(caller, "server_message", "房间已满")
		return
	if not rr.is_public and invite.strip_edges() != rr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
	var role := 1
	while rr.player_role.values().has(role):
		role += 1
	rr.players.append(caller)
	rr.player_role[caller] = role
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "role": role,
			"players": rr.players.size(), "cap": rr.max_players})
	_broadcast_royale_state(rr)

func royale_leave(caller: int) -> void:
	var rr := royale_room_of(caller)
	if rr == null:
		return
	rr.players.erase(caller)
	rr.player_role.erase(caller)
	NetDiag.audit("player_leave", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"players": rr.players.size(), "explicit": true})
	if rr.players.is_empty() and not rr.in_match:
		teardown_room(rr, LobbyRooms.TEARDOWN_DELAYED, "", false, "left")
	else:
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]
			NetDiag.audit("host_transfer", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE,
					"from_peer": caller, "to_peer": rr.host_peer, "explicit": true})

		if not rr.in_match:
			_broadcast_royale_state(rr)

# 房间列表的纯构造(理由同 room_list_payload:无对端时 reply 静默跳过 ⇒ 不抽出来探针观测不到)。★ 只列公开房;in_match 的房照列
func royale_list_payload(token: String = "") -> Array:
	return _registry.list_payload(ModeDefs.MODE_ROYALE, token, rejoin)


func royale_list(caller: int, token: String = "") -> void:
# 判活同 NetBus.reply:请求与断开可能挤在同一次 poll 里。本节点(NetBusExt)没有自己的 reply 助手 —— 判据是跨节点的单一来源(NetBus.is_peer_live)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload(token))


func royale_free_roles(rr: RoomTypes.Room, count: int) -> Array:
	var used := {}
	for r in rr.player_role.values():
		used[int(r)] = true
	var out: Array = []
	for r in range(1, rr.max_players + 1):
		if out.size() >= count:
			break
		if not used.has(r):
			out.append(r)
			used[r] = true
	return out


func _team_of(tr: RoomTypes.Room, role: int) -> int:
	return int(tr.team_of.get(role, 0))

func team_room_ready(tr: RoomTypes.Room) -> bool:
	return RoomTypes.team_room_ready(tr)


func team_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_TEAM, caller)


func _in_team_room(caller: int) -> bool:
	return team_room_of(caller) != null


func team_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在对抗房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	var code := _registry.next_code(ModeDefs.MODE_TEAM)
	var tr := RoomTypes.Room.new()
	tr.mode = ModeDefs.MODE_TEAM
	tr.code = code
	tr.host_peer = caller
	tr.max_players = TEAM_ROLES
	tr.players.append(caller)
	tr.player_role[caller] = 1
	tr.created_at = Time.get_unix_time_from_system()
	tr.beta = bool(opts.get("beta", false))
	tr.time_rules = opts.get("time", {}) if tr.beta else {}
	tr.is_public = bool(opts.get("is_public", true))
	tr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not tr.is_public and tr.invite_code.is_empty():
		tr.invite_code = _registry.generate_code()
	_registry.add(tr)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "public": tr.is_public, "beta": tr.beta})
	_broadcast_team_state(tr)


func team_join(caller: int, code: String, invite: String, beta: bool) -> void:
	var tr: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_TEAM)
	if tr == null:
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	if tr.beta and not beta:
		NetBus.reply(caller, "server_message", "这是时间玩法(Beta)房间,请从主菜单 Beta 页进入")
		return
	if not tr.beta and beta:
		NetBus.reply(caller, "server_message", "这是普通对抗房间,请从主菜单「多 人 模 式」进入")
		return
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在对抗房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	if tr.in_match:

		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if tr.players.size() >= TEAM_ROLES:
		NetBus.reply(caller, "server_message", "房间已满(%d 人)" % TEAM_ROLES)
		return
	if not tr.is_public and invite.strip_edges() != tr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
	var role := RoomTypes.team_next_role(tr.player_role.values())
	tr.players.append(caller)
	tr.player_role[caller] = role
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "role": role,
			"players": tr.players.size()})
	_broadcast_team_state(tr)


func team_pick(caller: int, team: int) -> void:
	var tr := team_room_of(caller)
	if tr == null or tr.in_match:
		return
	if team != 1 and team != 2:
		return
	var role := int(tr.player_role.get(caller, 0))
	if role == 0:
		return
	var by_team := RoomTypes.by_team(tr)
	if not RoomTypes.team_can_join(by_team, team, TEAM_SIZE):
		NetBus.reply(caller, "server_message", "该队已满 %d 人" % TEAM_SIZE)
		return
	tr.team_of[role] = team
	_broadcast_team_state(tr)


func team_leave(caller: int) -> void:
	var tr := team_room_of(caller)
	if tr == null:
		return
	tr.players.erase(caller)
	tr.player_role.erase(caller)
	NetDiag.audit("player_leave", {"room": tr.code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"players": tr.players.size(), "explicit": true})

	_prune_team_of(tr)
	if tr.players.is_empty() and not tr.in_match:
		teardown_room(tr, LobbyRooms.TEARDOWN_DELAYED, "", false, "left")
	else:

		if tr.host_peer == caller and not tr.players.is_empty():
			tr.host_peer = tr.players[0]
			NetDiag.audit("host_transfer", {"room": tr.code, "mode": ModeDefs.MODE_TEAM,
					"from_peer": caller, "to_peer": tr.host_peer, "explicit": true})
		if not tr.in_match:
			_broadcast_team_state(tr)


func team_list_payload(token: String = "") -> Array:
	return _registry.list_payload(ModeDefs.MODE_TEAM, token, rejoin)


func team_list(caller: int, token: String = "") -> void:
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "team_rooms", team_list_payload(token))


# 客户端 → 大厅:房主上报本房的地图(仅用于列表展示)。★ 静默丢弃的两种情况都不回话、不踢人:找不到房 / caller 不是房主 —— 回话没有
# 意义(客户端无从处理),踢人更没道理(可能只是建完房还没同步完)。★ 刻意不判空房:写一个展示字段无害,多一个分支就多一条没人测的路径。
func on_room_map(caller: int, code: String, path: String) -> void:
	var r := _registry.find(code)
	if r == null:
		return
	if not _is_room_host(r, caller):
		return
	r.map = path


# 这个 caller 是不是这间房的房主?★ 1v1 没有 host 字段的语义不变(房主 = players[0]),另两种读 host_peer ——
# 写成「一律读 host_peer」会让 1v1 的上报永远被拒且不报错。
func _is_room_host(r: RoomTypes.Room, caller: int) -> bool:
	if r.is_duel():
		return r.players.size() > 0 and r.players[0] == caller
	return r.host_peer == caller




func on_rejoin_request(caller: int, code: String, token: String, mode: String) -> void:
	var now := Time.get_ticks_msec()
	var e := rejoin.lookup(token, now)
	var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))
	var why := RejoinRegistry.decision(e, code, alive, mode)
	if why != "":
		if not e.is_empty() and not alive:
			rejoin.drop_token(token)
		print("[lobby] 拒绝回局(peer=%d):%s" % [caller, why])
		if NetBus.is_peer_live(caller):
			NetBusExt.rpc_id(caller, "rejoin_denied", why)
		return
	print("[lobby] 回局:房间 %s role %d → worker 端口 %d" % [
			code, int(e.get("role", 0)), int(e.get("worker_port", 0))])
	NetBus.reply(caller, "go_match", int(e.get("role", 0)), int(e.get("worker_port", 0)))


func _broadcast_team_state(tr: RoomTypes.Room) -> void:
	WaitRoomBroadcast.flush_team.call_deferred(self, tr)


const TEARDOWN_DELAYED := 0
const TEARDOWN_KILL := 1
const TEARDOWN_ABORT := 2
const TEARDOWN_ADOPT := 3

func teardown_room(room, mode: int = TEARDOWN_DELAYED, msg: String = "",
		disconnect_peers: bool = false, reason: String = "") -> void:
# ★ 三态判定读 room.mode(is_duel/is_royale/is_team)。旧写法用 `room is RoyaleRoom` 二分 —— 三张表的房号空间重叠,
# 按号码反查是「同一个号在三张表里各有一份」的静默错拆,故判定必须落在这个房对象自己的模式上。
	var port: int = room.worker_port
	var peers: Array = room.players.duplicate()
	if port > 0:
		match mode:
			TEARDOWN_KILL:
				launcher.kill_worker(port)
				WorkerLauncher.release_port_later(self, launcher, port, _registry.port_return_delay(room.mode))
			TEARDOWN_ABORT:
				launcher.release_now(port)
			TEARDOWN_ADOPT:
				launcher.adopt_orphan(port)
			_:
				WorkerLauncher.release_port_later(self, launcher, port, _registry.port_return_delay(room.mode))
	if not msg.is_empty():
		for peer_id in peers:
			if NetBus.is_peer_online(peer_id):
				NetBus.reply(peer_id, "server_message", msg)
	_registry.erase(room)
	var why := reason
	if why.is_empty():
		why = "closed" if mode == TEARDOWN_KILL else ("abort" if mode == TEARDOWN_ABORT else "delayed")
	NetDiag.audit("room_closed", {"room": str(room.code), "mode": room.mode, "reason": why,
			"port": port, "players": peers.size(),
			"uptime_sec": int(Time.get_unix_time_from_system() - float(room.created_at))})
	var ntk := rejoin.drop_port(port)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
	if disconnect_peers:
		for peer_id in peers:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)
