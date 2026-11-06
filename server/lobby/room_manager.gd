class_name RoomManager
extends Node

var _launcher := WorkerLauncher.new()

var lobby: LobbyRooms = null


const SWEEP_INTERVAL := 600.0
const MAX_ROOM_AGE := 7200.0
const TEAM_MATCH_ESTIMATE := 1800.0
const ROYALE_MATCH_TIME_CEILING := 1800.0
var _sweep_acc := 0.0

const MATCH_SWEEP_INTERVAL := 1.0
var _match_sweep_acc := 0.0


func _enter_tree() -> void:

	lobby = LobbyRooms.new()
	lobby.launcher = _launcher

	lobby.pairing_ready.connect(_start_match)
	add_child(lobby)

	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)

	NetBusExt.team_start_requested.connect(team_start)
	NetBusExt.pvp_start_requested.connect(pvp_start)

	NetBusExt.room_map_requested.connect(lobby.on_room_map)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)
	NetBusExt.pvp_start_requested.disconnect(pvp_start)

	NetBusExt.room_map_requested.disconnect(lobby.on_room_map)



func pvp_start(caller: int) -> void:
	lobby.pvp_start(caller)


func royale_start(caller: int) -> void:
	var rr := lobby.royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return
	if rr.players.size() < LobbyRooms.ROYALE_MIN_PLAYERS:
		NetBus.reply(caller, "server_message", "至少 %d 人才能开始" % LobbyRooms.ROYALE_MIN_PLAYERS)
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
	lobby.freeze_roster(rr)
# ★ token 必须在 go_match 之前发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,之后再发就静默丢失;登记进回局表则要等 spawn 成功(要 pid)。
	var granted: Array = []
	for pid in rr.players:
		var tk := RejoinRegistry.new_token()
		granted.append([int(rr.player_role[pid]), tk])
		if NetBus.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values()):
		rr.in_match = false
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
# ★ spawn 成功后才登记 pid(回收梯靠它判「这一局还在不在」);位置不能挪到 spawn 之前 —— 失败那一刻 pid 还是 0,登记 0 只会让回收梯晚一个周期才发现。
	rr.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(rr.code, port, granted, ModeDefs.MODE_ROYALE)

	NetDiag.audit("match_start", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "port": port,
			"players": rr.players.size(), "roles": str(rr.player_role.values()), "ai": 0})

	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


func _grant_rejoin(code: String, port: int, granted: Array, mode: String) -> void:
	var pid := _launcher.pid_of(port)
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), code, int(g[0]), port, pid, now, mode)


func _send_go_match(rr, port: int) -> void:
	await get_tree().process_frame
	for peer_id in rr.players:
		if NetBus.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", rr.player_role[peer_id], port)




func ai_duel(caller: int) -> void:
	var host_room: LobbyRooms.Room = null
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if room.players.has(caller) and int(room.player_role.get(caller, 0)) == 1:
			host_room = room
			break
	if host_room == null:
		NetBus.reply(caller, "server_message", "只有建房(房主)才能开 AI 对战")
		return
	# ★ BUG-12(2026-10-30):房内已有第二人 ⇒ 拒绝。AI 对战会把房从注册表摘掉,而 guest 收不到 go_match /
	#   server_message(摘房那条 teardown 的 msg 是空串)⇒ 停在已消失的等待室里,之后的 pvp_start 恒静默 return。
	if host_room.players.size() > 1:
		NetBus.reply(caller, "server_message", "房内还有其他玩家,AI 对战只能单人开局")
		return
	if host_room.started:
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	host_room.worker_port = port
	if not _launcher.spawn_worker(port, [2]):

		lobby.teardown_room(host_room, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	lobby.teardown_room(host_room, LobbyRooms.TEARDOWN_ADOPT, "", false, "match_end")
	NetDiag.audit("match_start", {"room": host_room.code, "mode": ModeDefs.MODE_PVP, "port": port,
			"players": 1, "ai": 1})
	await get_tree().create_timer(0.3).timeout
	NetBus.reply(caller, "go_match", 1, port)

func royale_start_ai(caller: int) -> void:
	var rr := lobby.royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return
	var ai_count := rr.max_players - rr.players.size()
	if ai_count <= 0:
		NetBus.reply(caller, "server_message", "房间已满,无需 AI 补位")
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true

	lobby.freeze_roster(rr)

	var ai_roles := lobby.royale_free_roles(rr, ai_count)

	var granted: Array = []
	for pid in rr.players:
		var tk := RejoinRegistry.new_token()
		granted.append([int(rr.player_role[pid]), tk])
		if NetBus.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values() + ai_roles, ai_roles):
		rr.in_match = false

		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return

	rr.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(rr.code, port, granted, ModeDefs.MODE_ROYALE)
	NetDiag.audit("match_start", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "port": port,
			"players": rr.players.size(), "ai": ai_count})
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


func team_start(caller: int) -> void:
	var tr := lobby.team_room_of(caller)
	if tr == null:
		return
	if tr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if tr.in_match:
		return
	if not lobby.team_room_ready(tr):
		NetBus.reply(caller, "server_message", "两队各至少 1 人才能开始")
		return
	tr.team_of = RoomTypes.team_autofill(tr)
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	tr.worker_port = port
	tr.in_match = true

	lobby.freeze_roster(tr)

	var granted: Array = []
	for pid in tr.players:
		var tk := RejoinRegistry.new_token()
		granted.append([int(tr.player_role[pid]), tk])
		if NetBus.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	var roles: Array = tr.player_role.values()
	roles.sort()
	var teams: Array = []
	for r in roles:
		teams.append(int(tr.team_of.get(int(r), 0)))
	if not _launcher.spawn_team_worker(port, roles, teams):
		tr.in_match = false

		lobby.teardown_room(tr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return

	tr.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(tr.code, port, granted, ModeDefs.MODE_TEAM)
	NetDiag.audit("match_start", {"room": tr.code, "mode": ModeDefs.MODE_TEAM, "port": port,
			"players": tr.players.size(), "roles": str(roles), "teams": str(teams), "ai": 0})
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(tr, port)


func _start_match(room: LobbyRooms.Room) -> void:
# 先置 started:同刻挡住第三人在这 0.3s 窗口误入(join_room 的 started 守卫)重复拉起 worker。⚠ 「配对瞬间掉线即关房」那条分支
# 已删除(对局中的房必须活到对局结束,否则列表里再也看不见它),故下面两处 if not lobby.rooms.has(...) 今天已够不着,保留作防御。
	room.started = true

	lobby.freeze_roster(room)
	var port := _launcher.pick_port()
	if port < 0:

		room.worker_port = 0
		NetBus.reply(room.players[0], "server_message", "无法分配对局端口")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	room.worker_port = port

	var granted: Array = []
	for pid in room.players:
		var tk := RejoinRegistry.new_token()
		granted.append([int(room.player_role[pid]), tk])
		if NetBus.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_worker(port):
		NetBus.reply(room.players[0], "server_message", "无法启动对局")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return

	room.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(room.code, port, granted, ModeDefs.MODE_PVP)

	await get_tree().create_timer(0.3).timeout
	if not lobby.rooms.has(room.code):
		return
	_send_go_match_1v1.call_deferred(room, port)
	NetDiag.audit("match_start", {"room": room.code, "mode": ModeDefs.MODE_PVP, "port": port,
			"players": room.players.size(), "ai": 0})



func _send_go_match_1v1(room: LobbyRooms.Room, port: int) -> void:
	await get_tree().process_frame
	if not lobby.rooms.has(room.code):
		return
	for peer_id in room.players:
		if NetBus.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", room.player_role[peer_id], port)


func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()

	_match_sweep_acc += delta
	if _match_sweep_acc >= MATCH_SWEEP_INTERVAL:
		_match_sweep_acc = 0.0
		_reclaim_finished_matches()
	_launcher.reap_orphans()
	ProcUtil.reap_kill_threads()

func _sweep_stale_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var stale: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if now - room.created_at > MAX_ROOM_AGE:
			stale.append(room)
	var stale_royale: Array = []
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		var in_match_grace := (SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + in_match_grace:
			stale_royale.append(rr)
	var stale_team: Array = []
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		var grace := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace:
			stale_team.append(tr)
# ★★ 这三条 is_empty() 是并列的,加新注册表时必须一起收进来:漏掉任何一张,「只有那张表的房超龄」的那次 tick 会在这里提前
# return、永远不清扫 ⇒ 端口永久泄漏,而症状是静默的(列表拼接那行照旧在)。(现零守卫;人工自查见 docs/eng/room-lifecycle-conventions.md §3)
	if stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty():
		return

	print("[lobby] 清理 %d 个超龄房间(1v1 %d 个 >%.0f 秒;大乱斗 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒;3v3 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒)" % [
			stale.size() + stale_royale.size() + stale_team.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING,
			stale_team.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE])
	for room in stale + stale_royale + stale_team:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true, "sweep_timeout")

# 对局结束即回收:in_match(1v1 是 started)的房不再在「客户端转连 worker」那一刻被拆,必须有替代回收路径,否则端口与列表位永久占用。
func _reclaim_finished_matches() -> void:
	lobby.rejoin.prune(Time.get_ticks_msec())
	var done: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if room.started and _match_over(room.worker_port, room.worker_pid):
			done.append(room)
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		if rr.in_match and _match_over(rr.worker_port, rr.worker_pid):
			done.append(rr)
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		if tr.in_match and _match_over(tr.worker_port, tr.worker_pid):
			done.append(tr)
	for room in done:
		var wstart := _launcher.started_at(room.worker_port)
		var alive := int(Time.get_unix_time_from_system() - (wstart if wstart > 0.0 else float(room.created_at)))
		NetDiag.audit("match_end", {"room": room.code, "mode": room.mode,
				"port": room.worker_port, "uptime_sec": alive})
		# ★ 拿不到子进程退出码 ⇒ 记"worker 消失时的现场":存活时长 + 日志尾部;正常结束与崩溃都发,由读的人按尾部判。
		NetDiag.audit("worker_lost", {"room": room.code, "mode": room.mode, "port": room.worker_port,
				"pid": room.worker_pid, "alive_sec": alive,
				"tail": NetDiag.tail_lines(_launcher.log_path(room.worker_port), 3)})
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED, "", false, "match_end")


static func _match_over(port: int, pid: int) -> bool:
	if port <= 0 or pid <= 0:
		return false
	return not WorkerLauncher.pid_alive(pid)



