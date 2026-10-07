class_name RoomManager
extends Node

# 大厅房间管理器与生命周期调度（服务端进程内）：
# 持有 LobbyRooms 房间状态，负责协调 MatchSession 对局开局、连接复用以及过期房间的周期性回收清理。
#
# 核心职责：
# 1. 对局生命周期调度：接收开局请求（royale_start / ai_duel / royale_start_ai / team_start / 1v1 配对就绪），
#    统一调用 _open_match 创建 MatchSession 子节点，并向房间成员广播 go_match 消息。
# 2. 房间超时回收清理：定期扫描并释放超龄未活跃房间（_sweep_stale_rooms）。
# 3. 单进程单端口限制：当前服务端进程单次仅托管一场活跃对局。

var _session: Node = null
var _next_match_id := 1               # 全局单调递增的对局局号分配器
var lobby: LobbyRooms = null          # 房间数据与状态注册表

# ── 过期房间定期清理配置 ──
const SWEEP_INTERVAL := 600.0         # 长期未活跃房间清理扫描周期（10 分钟）
const MAX_ROOM_AGE := 7200.0          # 房间最大存活时长（2 小时）
const TEAM_MATCH_ESTIMATE := 1800.0   # 3v3 模式单局预估最大时长（30 分钟）
const ROYALE_MATCH_TIME_CEILING := 1800.0 # 大乱斗模式单局最大配置时长上限（30 分钟）
var _sweep_acc := 0.0

# ── 已结束对局房间回收周期 ──
const MATCH_SWEEP_INTERVAL := 30.0    # 对局结束后房间资源回收检测周期（30 秒）
var _match_sweep_acc := 0.0


func _enter_tree() -> void:
	lobby = LobbyRooms.new()
	lobby.pairing_ready.connect(_start_match)
	lobby.inproc_room_teardown.connect(_on_inproc_room_teardown)
	add_child(lobby)
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)
	NetBusExt.team_start_requested.connect(team_start)
	NetBusExt.room_map_requested.connect(lobby.on_room_map)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)
	NetBusExt.room_map_requested.disconnect(lobby.on_room_map)
	if lobby.inproc_room_teardown.is_connected(_on_inproc_room_teardown):
		lobby.inproc_room_teardown.disconnect(_on_inproc_room_teardown)


# 房间销毁时同步清理其关联的进行中对局会话
func _on_inproc_room_teardown(room) -> void:
	if _session == null or not is_instance_valid(_session):
		return
	if int(room.match_id) <= 0 or int(room.match_id) != int(_session.match_id):
		return
	print("[lobby] 房间 %s 已销毁，同时终止关联对局会话(局号 %d)" % [room.code, int(room.match_id)])
	_session._finish()


# ── 开局流程编排：各模式统一开局入口 ──
# 核心步骤：冻结房间成员名单 -> 创建 MatchSession 会话节点并挂载 -> 登记局号与重连凭据 -> 向全体成员下发 go_match。
#
# 架构特性：
# 1. 单进程单端口模型：对局作为当前大厅进程中的 MatchSession 子节点运行，生命周期结束时发出 finished 信号。
# 2. 连接与端口复用：go_match 消息下发当前服务端监听端口，客户端在原连接上直接切换至对局场景。
# 3. 统一参数校验：共用 MatchSession.validate 校验逻辑，保证模式参数一致性。
func _open_match(room, mode: int, roles: Array, ai_roles: Array, teams: Dictionary) -> void:
	var why: String = MatchSession.validate(mode, roles, teams)
	if why != "":
		push_error("[lobby] 开局参数不合法:%s" % why)
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# 本机已有对局运行：单进程下单次仅托管一局对局
	if _session != null and is_instance_valid(_session):
		NetBus.reply(room.players[0], "server_message", "本机已有一局在进行中")
		return
	# 开局时将当前成员名单冻结至房间记录中
	lobby.freeze_roster(room)
	if room is LobbyRooms.RoyaleRoom or room is LobbyRooms.TeamRoom:
		room.in_match = true
	else:
		room.started = true
	# 开局名册：记录此时房间内的有效 peer_id，用于后续客户端准入白名单校验，防止未授权客户端连接
	var roster: Array = room.players.duplicate()
	var session := MatchSession.new(mode, room.code, _next_match_id, roster, roles, ai_roles, teams)
	_next_match_id += 1
	room.match_id = session.match_id
	session.finished.connect(_on_session_finished)
	_session = session
	add_child(session)
	# 重连令牌需在 go_match 之前下发，确保客户端在认领角色时能同步上报
	var granted: Array = []   # [[role, token], …]
	for pid in roster:
		var role := int(room.player_role.get(pid, 0))
		if role <= 0:
			continue
		var tk := LobbyRooms.new_token()
		granted.append([role, tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	# 登记重连凭据：以分配的局号 match_id 作为主键存入 RejoinRegistry
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), room.code, int(g[0]), session.match_id, now)
	print("[lobby] %s %s 开局(%s,roles %s)" % [_kind_of(room), room.code,
			_mode_name(mode), str(roles)])
	var role_of := {}
	for pid in roster:
		role_of[pid] = int(room.player_role.get(pid, 1))
	_send_go_match.call_deferred(roster, role_of)


# 大乱斗模式房主开局处理
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
	var roles: Array = rr.player_role.values()
	_open_match(rr, MatchSession.Mode.ROYALE, roles, [], {})


# 大乱斗模式房主开启 AI 补位开局：真人玩家保持原位，剩余空位由 AI 填满
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
	var ai_roles := lobby.royale_free_roles(rr, ai_count)
	var roles: Array = rr.player_role.values() + ai_roles
	_open_match(rr, MatchSession.Mode.ROYALE, roles, ai_roles, {})


# 3v3 团队对抗模式房主开局处理（需两队均达到 3 人满员要求）
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
		NetBus.reply(caller, "server_message", "两队各 3 人才能开始")
		return
	var roles: Array = tr.player_role.values()
	roles.sort()
	var teams := {}
	for r in roles:
		teams[int(r)] = int(tr.team_of.get(int(r), 0))
	_open_match(tr, MatchSession.Mode.TEAM, roles, [], teams)


# 1v1 房主请求 AI 对战：单人开局，role2 由服务端 AI 控制
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
	if host_room.started:
		return
	print("房间 %s：开启人机对战对局(玩家 + AI)" % host_room.code)
	_open_match(host_room, MatchSession.Mode.DUEL, [1, 2], [2], {})
	if lobby.rooms.has(host_room.code):
		lobby.teardown_room(host_room)


# 1v1 配对完成开局
func _start_match(room: LobbyRooms.Room) -> void:
	room.started = true
	print("房间 %s：配对完成，进入对局" % room.code)
	_open_match(room, MatchSession.Mode.DUEL, [1, 2], [], {})


# 向房间成员广播进入对局消息（推迟至下一帧执行，确保网络连接状态已完全稳定）。
# 下发端口统一为当前服务端监听端口，客户端在原连接上直接切换至对局场景。
func _send_go_match(peers: Array, role_of: Dictionary) -> void:
	await get_tree().process_frame
	for peer_id in peers:
		if lobby.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", int(role_of.get(peer_id, 1)), NetBus.server_port)


# 对局会话正常结束回调：注销该局重连凭据、延迟清理房间记录并释放 MatchSession 节点。
func _on_session_finished(session) -> void:
	lobby.rejoin.end_match(int(session.match_id))
	var room = _room_of_session(session)
	if room != null:
		print("[lobby] 对局已结束，回收%s %s" % [_kind_of(room), room.code])
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED, "")
	if _session == session:
		_session = null
	if is_instance_valid(session) and not session.is_queued_for_deletion():
		session.queue_free()


# 根据局号 match_id 反查对应的房间对象（跨 1v1、大乱斗与 3v3 房间表检索）。
func _room_of_session(session) -> Variant:
	var mid := int(session.match_id)
	for code in lobby.rooms:
		if (lobby.rooms[code] as LobbyRooms.Room).match_id == mid:
			return lobby.rooms[code]
	for rcode in lobby.royale_rooms:
		if (lobby.royale_rooms[rcode] as LobbyRooms.RoyaleRoom).match_id == mid:
			return lobby.royale_rooms[rcode]
	for tcode in lobby.team_rooms:
		if (lobby.team_rooms[tcode] as LobbyRooms.TeamRoom).match_id == mid:
			return lobby.team_rooms[tcode]
	return null


func _kind_of(room) -> String:
	if room is LobbyRooms.RoyaleRoom:
		return "大乱斗房"
	if room is LobbyRooms.TeamRoom:
		return "3v3 房"
	return "房间"


func _mode_name(mode: int) -> String:
	match mode:
		MatchSession.Mode.ROYALE:
			return "大乱斗"
		MatchSession.Mode.TEAM:
			return "3v3"
		_:
			return "1v1"


# 定时扫描清理超龄房间及已结束对局
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()
	_match_sweep_acc += delta
	if _match_sweep_acc >= MATCH_SWEEP_INTERVAL:
		_match_sweep_acc = 0.0
		_reclaim_finished_matches()


# 清理超龄未活跃房间：防止客户端非正常退出导致房间资源长期滞留
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
	if stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty():
		return
	print("[lobby] 清理 %d 个超时房间(1v1 %d 个 >%.0f 秒；大乱斗 %d 个；3v3 %d 个)" % [
			stale.size() + stale_royale.size() + stale_team.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), stale_team.size()])
	for room in stale + stale_royale + stale_team:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true)
		print("%s %s 超时清理完成(已存活 %.0f 秒)" % [
				"大乱斗房" if room is LobbyRooms.RoyaleRoom else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间"),
				room.code, now - room.created_at])


# 定期清理已结束的对局与超龄房间，资源释放统一经由 lobby.teardown_room 处理。
func _reclaim_finished_matches() -> void:
	# 定期清理凭据注册表中的过期条目（以 TOKEN_TTL_SECONDS 为上限）
	lobby.rejoin.prune(Time.get_ticks_msec())
	if _session != null and is_instance_valid(_session) and not _session.is_queued_for_deletion():
		return
	var done: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if room.started and room.match_id > 0:
			done.append(room)
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		if rr.in_match and rr.match_id > 0:
			done.append(rr)
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		if tr.in_match and tr.match_id > 0:
			done.append(tr)
	for room in done:
		var kind := "大乱斗房" if room is LobbyRooms.RoyaleRoom \
				else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间")
		print("[lobby] 对局会话资源已释放，回收%s %s" % [kind, room.code])
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)


