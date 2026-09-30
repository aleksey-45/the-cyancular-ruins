class_name RoomManager
extends Node

# 大厅的**对局编排 + 定时清扫**(服务端进程内)。房间状态本身在 `server/lobby_rooms.gd`(LobbyRooms),
# 本类持有它。
#
# 本类只做三件事:
#   · **开局**:`royale_start` / `ai_duel` / `royale_start_ai` / `team_start`(RPC 进来)+
#     `_start_match`(由 `lobby.pairing_ready` 信号进来)四处,统一汇到 `_open_match`;
#   · **收局**:`MatchSession.finished` 信号进来 → 作废凭据 + 拆房 + 释放会话;
#   · **定时清扫**超龄房间(推导与已知边界见 `_sweep_stale_rooms`)。
#
# ★★ 与原形的**根本差别**:原先每局是一个 `--worker` 子进程,于是"开局"= 挑端口 + `create_process`
#   + 让客户端转连;"收局"= 等 worker 进程自己退(`_reclaim_finished_matches` 每 30s 轮询)。
#   现在对局是**本进程里的一个 `MatchSession` 节点** —— 那两件事各自塌缩成一次 `add_child`
#   与一条信号。随之消失的还有:端口池、三档端口复用延迟、按端口杀进程、"worker 还在不在"的
#   轮询梯(以及它赖以成立的 pid 记账)。
#
# ★ 房间 ↔ 编排 的方向仍是**单向**的:`lobby` 不知道本类;「1v1 凑齐两人」由 `pairing_ready`
#   信号上来。别再往 LobbyRooms 里塞 RoomManager 引用。
var lobby: LobbyRooms = null

# 本服务端监听的端口(唯一的那个)。发给客户端的 `go_match` 带它 —— 客户端把它记进
# `PvpSession.server_port`,局内断线重连要直连同一个端口。
var port := NetBus.DEFAULT_PORT
# 局号分配器(**唯一递增,不复用**)。它替代了原先"用 worker 端口当这一局的键"那套记账:
# 回局凭据表要在大厅侧活过房对象,而三张注册表的**房号空间重叠**,按房号作键会误伤同号的
# 另一间房(见 RejoinRegistry 类头)。
var _next_match_id := 1

# ── 僵尸房间定时清理:每 SWEEP_INTERVAL 秒扫一次,存在超 MAX_ROOM_AGE 的房间连会话一起拆 ──
const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
# 3v3 一局时长的**估**值(秒=30min),只用于 _sweep_stale_rooms 的在局宽限。
# ★ 它是**估**值,不是从任何常量读来的:TeamHost 侧没有一个"本局最多打多久"的常量可读。
# ★ 与 royale 那条宽限**同根因的已知边界**(照实登记):正确的界要读**本局实际时长**,而那个值
#   只存在于 TeamHost 里,sweep 手里没有。
const TEAM_MATCH_ESTIMATE := 1800.0
var _sweep_acc := 0.0

# 回局凭据表的 GC 梯周期(秒)。凭据的 TTL 只是表的上界,不需要独立定时器。
const REJOIN_GC_INTERVAL := 30.0
var _gc_acc := 0.0


func _init(server_port: int = NetBus.DEFAULT_PORT) -> void:
	port = server_port


func _enter_tree() -> void:
	# 房间账本:本类持有并装配。★ 服务端端口要在**账本可用之前**注入 —— 回局应答
	# (`LobbyRooms.on_rejoin_request`)要带它。
	lobby = LobbyRooms.new()
	lobby.server_port = port
	# 「1v1 凑齐两人」跨了边界(房间的事 + 开局的事)→ 由信号上来,避免反向引用。
	lobby.pairing_ready.connect(_start_match)
	add_child(lobby)
	# 编排侧的四条 RPC(它们要开局,故不归房间账本)
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)
	# 3v3 的**第六条**上行归本类(其余五条 team_create/join/pick/leave/list 在 LobbyRooms)
	NetBusExt.team_start_requested.connect(team_start)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)


# ── 开局 ──

# 大乱斗房主开局:满 `ROYALE_MIN_PLAYERS` 人即可。
func royale_start(caller: int) -> void:
	var rr := lobby.royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return   # 已开局(重复请求防重入:不会双开一局)
	if rr.players.size() < LobbyRooms.ROYALE_MIN_PLAYERS:
		NetBus.reply(caller, "server_message", "至少 %d 人才能开始" % LobbyRooms.ROYALE_MIN_PLAYERS)
		return
	var roles: Array = rr.player_role.values()
	print("大乱斗房 %s 开局(%d 人,roles %s)" % [rr.code, rr.players.size(), str(roles)])
	_open_match(rr, MatchSession.Mode.ROYALE, roles, [], {})


# 大乱斗房主 AI 补位开局 → 现有真人 + AI 补到 max_players
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
	# AI role 号 = 1..max_players 内**人类未占用**的空闲号(见 royale_free_roles)
	var ai_roles := lobby.royale_free_roles(rr, ai_count)
	# 参战集合 = 房里真人的已分配号 + AI 补位号(真人号可能带空洞,故不能写成 1..max_players)
	var roles: Array = rr.player_role.values() + ai_roles
	print("大乱斗房 %s AI 补位开局(%d 真人 + %d AI,roles %s)" % [rr.code, rr.players.size(),
			ai_count, str(roles)])
	_open_match(rr, MatchSession.Mode.ROYALE, roles, ai_roles, {})


# 3v3 房主开局(**两队各 3 人**才允许)。
# ★ 与 royale_start 的实质差异:
#   ① 满员判据是"两队各 3 人"(不是"人数 ≥2")—— 4v2 人数也够 6,但那不是 3v3;
#   ② 多一份 `team_of`(role→队号),它才是队伍归属的唯一来源
#      (role 号因"退出留空洞、最小空闲号复用"而不连续,**推不出**队号);
#   ③ 没有 AI 补位(用户裁定:满 6 人才开)。
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
	print("3v3 房 %s 开局(roles %s / teams %s)" % [tr.code, str(roles), str(teams)])
	_open_match(tr, MatchSession.Mode.TEAM, roles, [], teams)


# 1v1:房主请求与 AI 对战 → 单人开局,role2 由服务端 AI 驱动
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
	# 已开局:拒绝(防双开一局覆盖房上的会话引用)
	if host_room.started:
		return
	print("房间 %s → AI 对战开局(1 人 + AI)" % host_room.code)
	_open_match(host_room, MatchSession.Mode.DUEL, [1, 2], [2], {})
	# ★ 房记录**摘掉**(AI 不占第二人位):房一旦"开局"就再没人能加入,留着它只是列表里
	#   一行点不动的死房。★ 拆房**不动会话、也不动作废凭据** —— 那一局还活着,而凭据要活到
	#   对局结束(回收由 `_on_session_finished` 收口)。
	lobby.teardown_room(host_room, "", false)


# ── 配对完成 → 开局 + 通知两端进对局场景 ──
func _start_match(room: LobbyRooms.Room) -> void:
	# 先置 started:同刻挡住第三人在这段窗口误入(`join_room` 的 started 守卫)重复开局。
	room.started = true
	print("房间 %s 配对完成 → 开局" % room.code)
	_open_match(room, MatchSession.Mode.DUEL, [1, 2], [], {})


# ── 四个开局入口的**唯一实现** ──
# 做四件事:冻名单 → 建会话(订阅 RPC)→ 登记局号与凭据 → 通知全员 `go_match`。
#
# ★ `go_match` 带的**端口就是本服务端端口**:与原先"worker 独占另一个端口、客户端停掉大厅连接
#   再连过去"不同,客户端现在**全程连着同一台服务端**,`go_match` 只表示"进对局场景"。
func _open_match(room, mode: int, roles: Array, ai_roles: Array, teams: Dictionary) -> void:
	# ★ 开局那一刻把名单冻进房记录:对局中的房在列表里要显示"这一局有哪些人",而 `players`
	#   会随掉线变化(以前还会因为转连而整个空掉)—— 列表只能读这份快照。
	lobby.freeze_roster(room)
	if room is LobbyRooms.RoyaleRoom or room is LobbyRooms.TeamRoom:
		room.in_match = true
	else:
		room.started = true
	var roster: Array = room.players.duplicate()
	var session := MatchSession.new(mode, room.code, _next_match_id, roster, roles, ai_roles, teams)
	_next_match_id += 1
	room.match_id = session.match_id
	room.session = session
	session.finished.connect(_on_session_finished)
	add_child(session)
	# ★ token 必须在 **go_match 之前**发到客户端:客户端收到 go_match 当场认领 role,而
	#   `report_token` 紧跟着 claim 走;晚发会与 claim 抢同一次 poll。
	var granted: Array = []   # [[role, token], …]
	var role_of := {}
	for pid in roster:
		var role := int(room.player_role.get(pid, 0))
		if role <= 0:
			continue
		role_of[pid] = role
		var tk := LobbyRooms.new_token()
		granted.append([role, tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	# ★ 凭据登记:这一局的"还在不在"由**会话节点**回答(见 RejoinRegistry 的 alive 字段),
	#   故局号必须先于 grant 分配好。
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), room.code, int(g[0]), session.match_id, now)
	_send_go_match.call_deferred(roster, role_of)


# 全员通知进场(延到帧末再判在线:调用点常在"刚有人断开"的路径上,同步发会踩那个窗口)。
# ★ 参数**刻意不带类型标注**:大乱斗房(`RoyaleRoom`)、3v3 房(`TeamRoom`)与 1v1 房(`Room`)
#   在本函数用到的东西上同名同义;标了具体房型就会在传另一种时运行时类型不符,而"再抄一份"是
#   本仓明令禁止的第二份真相。
func _send_go_match(peers: Array, role_of: Dictionary) -> void:
	await get_tree().process_frame   # 等断开信号落定再判在线
	for peer_id in peers:
		if lobby.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", int(role_of.get(peer_id, 1)), port)


# 对局结束(MatchSession 唯一的正常出口)→ 作废凭据 + 拆房 + 释放会话。
# ★ 凭据作废的**唯一**时点就是这里:它表达的是"这一局没了"。别挪进 `teardown_room` ——
#   那里分不清"房记录被摘掉"与"对局结束"(AI 对战就是前者:房摘了、局还活着)。
func _on_session_finished(session) -> void:
	lobby.rejoin.end_match(int(session.match_id))
	var room = _room_of_session(session)
	if room != null:
		print("[lobby] 对局结束,回收%s %s" % [_kind_of(room), room.code])
		lobby.teardown_room(room, "对局已结束", false)
	if is_instance_valid(session) and not session.is_queued_for_deletion():
		session.queue_free()


func _room_of_session(session) -> Variant:
	for code in lobby.rooms:
		if (lobby.rooms[code] as LobbyRooms.Room).session == session:
			return lobby.rooms[code]
	for code in lobby.royale_rooms:
		if (lobby.royale_rooms[code] as LobbyRooms.RoyaleRoom).session == session:
			return lobby.royale_rooms[code]
	for code in lobby.team_rooms:
		if (lobby.team_rooms[code] as LobbyRooms.TeamRoom).session == session:
			return lobby.team_rooms[code]
	return null


static func _kind_of(room) -> String:
	if room is LobbyRooms.RoyaleRoom:
		return "大乱斗房"
	if room is LobbyRooms.TeamRoom:
		return "3v3 房"
	return "房间"


# ── 定时扫描 ──
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()
	# 凭据表的 GC 搭这条梯(它只需要"有个周期性的主人",不值得再立一条定时器)。
	_gc_acc += delta
	if _gc_acc >= REJOIN_GC_INTERVAL:
		_gc_acc = 0.0
		lobby.rejoin.prune(Time.get_ticks_msec())


# 清理:房间从创建起超 MAX_ROOM_AGE 秒 → 拆房(连会话)+ 踢房内玩家 + 删房。
# 刻意偏离移植来源(非误改):原清扫只遍历 rooms(1v1),royale_rooms / team_rooms 是合并后
# 并存的第二、第三张注册表。
# ★ 加新一张注册表时**两处都要动**:各自的 stale_* 收集块,以及末尾那条
#   「全空则提前 return」的并列判据(漏了它 = 只有那一张表的房超龄时永不清扫)。
# ★ 在局中的房给额外宽限:房龄从**建房**起算,含此前在等待室里耗掉的全部时间 —— 一个等满
#   MAX_ROOM_AGE 才开局的房,在开局那一刻就已"超龄"。宽限 = 一个扫描周期 + 一局时长,
#   让"等待期攒下的那整个周期"与"默认时长的整局"都落在界内。
#   ★ **1v1 现在也有这条宽限了**(原先只有大乱斗有 —— 那是登记过的既有不对称)。它借的是
#     `RoyaleHost.MATCH_TIME` 的**量级**当上界:1v1 一局(三局两胜 × 每局几分钟)严格短于它,
#     而单独立一个常量只为这一处判据不合算。3v3 另有 `TEAM_MATCH_ESTIMATE`(见上)。
#   ★ **已知边界(照实登记,本次不修)**:宽限里那个"一局"取的是默认值/估值,而房主可以把
#     一局配得更长(大乱斗有建房页的限时滑块,3v3 是三局两胜)。触发它得先满足"房龄近 2h",
#     正常房几分钟内就开局,而正确的修法是让宽限读**本局实际时长** —— 那要先把时长回传/登记
#     到房上,属另行评估的范围。
func _sweep_stale_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var stale: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		var grace := (SWEEP_INTERVAL + RoyaleHost.MATCH_TIME) if room.started else 0.0
		if now - room.created_at > MAX_ROOM_AGE + grace:
			stale.append(room)
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		var grace_r := (SWEEP_INTERVAL + RoyaleHost.MATCH_TIME) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + grace_r:
			stale.append(rr)
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		var grace_t := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace_t:
			stale.append(tr)
	# ★★ 这条 `is_empty()` 的并列判据必须覆盖**全部**注册表:漏掉任何一张,"只有那张表的房
	#    超龄"的那次 tick 会在这里**提前 return、永远不清扫**。
	if stale.is_empty():
		return
	print("[lobby] 清理 %d 个超龄房间(>%.0f 秒,在局中的另加宽限)" % [stale.size(), MAX_ROOM_AGE])
	for room in stale:
		print("%s %s 超时清理(存活 %.0f 秒)" % [_kind_of(room), room.code, now - room.created_at])
		# ★ 有活会话的房:**先结束会话**再拆 —— `abort()` 会走 `finished` → `_on_session_finished`
		#   那一条收口(作废凭据 + 拆房 + 释放),不在本地再抄一遍那三件事。
		#   没有会话的房(还没开局的僵尸房)直接拆。
		var s = room.get("session")
		if s != null and is_instance_valid(s):
			s.abort()
		else:
			lobby.teardown_room(room, "房间超时(>2h),已关闭", true)


# 建局引导已搬到 server/match_bootstrap.gd(MatchBootstrap.start_on)—— 那是"对局宿主"那一侧
# 的职责,与 MatchHost/RoyaleHost 同侧。调用点见 server/match_session.gd。
