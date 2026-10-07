class_name RoomManager
extends Node

# 大厅房间管理器与生命周期调度（服务端进程内）：
# 持有 LobbyRooms 房间状态，负责协调对局开局（MatchSession）、连接复用以及过期房间的周期性回收清理。
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
	# 房间账本:本类持有它,两者单向依赖(账本不知道本类)。
	lobby = LobbyRooms.new()
	# 「1v1 凑齐两人」跨了边界(房间的事 + 开局的事)→ 由信号上来,避免反向引用。
	lobby.pairing_ready.connect(_start_match)
	# 反向的那一条:超龄清扫要收掉一个**还在跑**的本机对局(房记录被抹掉只是一半,那一局本身
	# 也得停 —— 否则会话节点留在进程里空转、占着 peer 与内存,而列表上再也看不见它)。
	lobby.inproc_room_teardown.connect(_on_inproc_room_teardown)
	add_child(lobby)
	# 编排侧的四条 RPC(它们要启动 Worker 子进程,故不归房间账本)
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)
	# 3v3 的**第六条**上行归本类(其余五条 team_create/join/pick/leave/list 在 LobbyRooms)
	# —— 与大乱斗逐字相同机制的分工:账本接 royale_list,编排接 royale_start。
	NetBusExt.team_start_requested.connect(team_start)
	# 统一大厅:房主上报地图(只写房记录的展示字段,不启动 Worker 子进程、不碰对局)
	NetBusExt.room_map_requested.connect(lobby.on_room_map)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)
	# 与上面那条 connect 对称(其余四条 NetBusExt 信号都在这里成对出现)
	NetBusExt.room_map_requested.disconnect(lobby.on_room_map)
	if lobby.inproc_room_teardown.is_connected(_on_inproc_room_teardown):
		lobby.inproc_room_teardown.disconnect(_on_inproc_room_teardown)


# 房记录被拆除、而那一局还活着 → 把那一局也收掉。
# - 唯一可达的调用点是**超龄清扫**(`_sweep_stale_rooms`,2h);正常收局是反过来的顺序
#   (会话先 `_finish` → `_on_session_finished` 再拆房),那时本函数会走到 `_session` 已被
#   置空或 `_finish()` 的 `_done` 幂等守卫上,不做事。
# - 判据带 `match_id`:AI 对战那条路**先摘房、局还活着**,拆房时不该把那一局停掉。
func _on_inproc_room_teardown(room) -> void:
	if _session == null or not is_instance_valid(_session):
		return
	if int(room.match_id) <= 0 or int(room.match_id) != int(_session.match_id):
		return
	print("[lobby] 房间 %s 已销毁，同时终止关联对局会话(局号 %d)" % [room.code, int(room.match_id)])
	_session._finish()


# ── 开局流程编排：各模式统一开局入口 ──
# 核心步骤：冻结房间成员名单 → 创建 MatchSession 会话节点并挂载 → 登记局号与重连凭据 → 向全体成员下发 go_match。
#
# 架构特性：
# 1. 单进程单端口模型：
#    对局作为当前大厅进程中的 MatchSession 子节点运行，生命周期结束时发出 finished 信号。
# 2. 连接与端口复用：
#    go_match 消息下发 NetBus.server_port（当前服务端监听端口），客户端在原 ENet 连接上直接切入对局场景。
#    该方案确保客户端在局域网直连或 EasyTier 隧道映射下均可无缝通信，无需额外的端口映射。
# 3. 参数校验统一：
#    与 `--worker` 命令行模式共用 MatchSession.validate 校验逻辑，保证模式参数的一致性。
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
	# 登记重连凭据：以分配的局号（match_id）作为主键存入 RejoinRegistry
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), room.code, int(g[0]), session.match_id, now)
	print("[lobby] %s %s 开局(%s,roles %s)" % [_kind_of(room), room.code,
			_mode_name(mode), str(roles)])
	var role_of := {}
	for pid in roster:
		role_of[pid] = int(room.player_role.get(pid, 1))
	_send_go_match.call_deferred(roster, role_of)


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
	_open_match(rr, MatchSession.Mode.ROYALE, roles, [], {})


# 大乱斗:房主 AI 补位开局 → 现有真人 + AI 补到 max_players
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
	_open_match(rr, MatchSession.Mode.ROYALE, roles, ai_roles, {})


# ── 3v3:房主开局(**两队各 3 人**才允许)→ 启动 --team worker → 全员 go_match 转连 ──
# - 与 royale_start 的三处实质差异:
#   ① 满员判据是"两队各 3 人"(不是"人数 ≥2")—— 4v2 人数也够 6,但那不是 3v3;
#   ② 命令行多一个 `--teams`(与 `--roles` **同序等长**),它才是队伍归属的唯一来源
#      (role 号因"退出留空洞、最小空闲号复用"而不连续,**推不出**队号);
#   ③ 没有 AI 补位(设计约定:满 6 人才开)。
func team_start(caller: int) -> void:
	var tr := lobby.team_room_of(caller)
	if tr == null:
		return
	if tr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if tr.in_match:
		return   # 已开局(重复请求防重入:不会双开一局)
	if not lobby.team_room_ready(tr):
		NetBus.reply(caller, "server_message", "两队各 3 人才能开始")
		return
	# - roles 与 teams **同序**:roles 按号升序取,teams 跟着同一个顺序取队号。
	#   `team_of` 缺该 role(有人在满员判据之后、这里之前掉线/退房)时取 0 →
	#   `MatchSession.validate` 的取值校验当场拒绝(只收 1/2),走拆除 —— **不会**开出一局
	#   队号错的对局(那正是 Task 9 评审 M2 要堵的静默失败模式)。
	var roles: Array = tr.player_role.values()
	roles.sort()
	var teams := {}
	for r in roles:
		teams[int(r)] = int(tr.team_of.get(int(r), 0))
	_open_match(tr, MatchSession.Mode.TEAM, roles, [], teams)


# ── AI 补位对战(实验性):1v1 房主可请求与 AI 对战 ──

# 1v1:房主请求 AI 对战 → 单人开局,role2 由服务端 AI 驱动
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
	print("房间 %s：开启人机对战对局(玩家 + AI)" % host_room.code)
	_open_match(host_room, MatchSession.Mode.DUEL, [1, 2], [2], {})
	# 房间开启对局后从大厅列表中移除（AI 玩家不占位，避免产生无效空房间）
	if lobby.rooms.has(host_room.code):
		lobby.teardown_room(host_room)


# ── 配对完成 → 开局 ──
func _start_match(room: LobbyRooms.Room) -> void:
	# 先置 started:同刻挡住第三人在这段窗口误入(`join_room` 的 started 守卫)重复开局。
	room.started = true
	print("房间 %s：配对完成，进入对局" % room.code)
	_open_match(room, MatchSession.Mode.DUEL, [1, 2], [], {})


# 向房间成员广播进入对局消息（推迟至下一帧执行，确保网络连接状态已完全稳定）。
# 下发端口统一为当前服务端监听端口，客户端在原连接上直接切换至对局场景。
func _send_go_match(peers: Array, role_of: Dictionary) -> void:
	await get_tree().process_frame   # 等断开信号与网络状态稳定收敛后再判定在线
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


# 根据局号（match_id）反查对应的房间对象（跨 1v1、大乱斗与 3v3 房间表检索）。
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

# ── 定时扫描:每 SWEEP_INTERVAL 清理存在超 MAX_ROOM_AGE 的僵尸房间(连 worker 一起杀)──
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()
	# - 对局中房间的回收走**另一条更密的**梯(判据与目的都不同,见 MATCH_SWEEP_INTERVAL)。
	_match_sweep_acc += delta
	if _match_sweep_acc >= MATCH_SWEEP_INTERVAL:
		_match_sweep_acc = 0.0
		_reclaim_finished_matches()

# 清理:房间从创建起超 MAX_ROOM_AGE 秒 → 杀其 worker(若有)→ 踢房内玩家 → 删房归还端口。
# 刻意偏离移植来源(非误改):原清扫只遍历 rooms(1v1),royale_rooms / team_rooms 是合并后
# 并存的第二、第三张注册表。
# 大乱斗/3v3 房的 worker_port 只在开局时分配,而唯一归还路径是 on_peer_left 的「空房」分支——
# 成员若一直连着不吭声(ENet 不会超时「连接仍在但对端沉默」的 peer),端口就被永久占用
# (WORKER_PORT_SPAN=500 耗尽后 WorkerLauncher.pick_port 恒 -1,大厅彻底拉不起 worker)。
# 故三表共用同一 MAX_ROOM_AGE 一并清扫。不跳过 in_match 房:在局中的房另加
# 「一整个扫描周期 + 一局时长」的宽限(大乱斗那一档的「一局」取**可证上界**,见
# ROYALE_MATCH_TIME_CEILING),推导见下方 royale / team 两个分支 —— 3v3 那档仍是估值,
# 其**已知边界**见 TEAM_MATCH_ESTIMATE 的注释。
# - 加新一张注册表时**两处都要动**:各自的 stale_* 收集块,以及末尾那条
#   「全空则提前 return」的并列判据(漏了它 = 只有那一张表的房超龄时永不清扫)。
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
		# 刻意偏离移植来源(非误改):在局中的大乱斗房宽限 = SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING
		# (即「一整个扫描周期」+「一局时长的**可证上界**」,不是默认时长),这条界的**推导**是可证的:
		# 房龄从**建房**起算,含此前在大厅等待的全部时间——一个等满 MAX_ROOM_AGE 才开局的房,在开局
		# 那一刻就已"超龄";而清扫由 _process 的 SWEEP_INTERVAL 计时器驱动(不是每帧),房间可能已经
		# 比阈值老上**整整一个扫描周期**才等到判它超龄的那次 tick,即最迟可在房龄 MAX_ROOM_AGE +
		# SWEEP_INTERVAL 时开局。从 royale_start/royale_start_ai 启动 worker 到成员转连离厅还有
		# 0.3~1.5s 的窗口,若宽限只有一局时长,紧随其后的那次 tick 仍会终止一个刚起几秒的 worker
		# 并剔除断开正在转连的成员(边界竞态只是被推窄,没被关闭)。宽限覆盖「阈值 + 整个扫描周期 +
		# 最长一局」后,等待期攒下的那一整个周期与整局对局都落在界内 —— -  这里的「一局」取的是
		# **可证上界** ROYALE_MATCH_TIME_CEILING(2026-09-28 之前取的是默认时长,房主配长时长时
		# 会在对局中途被杀,理由见该常量的注释)。
		# 等待中(in_match=false)的房不占端口、杀不到任何东西,仍按裸 MAX_ROOM_AGE 清,无需宽限。
		# - 1v1 分支**刻意不享受**同样宽限。2026-09-21 订正本条的**理由**(行为一字未动):
		#   旧理由引的是「started 房一方掉线即整房作废」(_start_match / on_peer_left 那条 started 分支)
		#   —— 那条分支**已删除**,对局中的 1v1 房现在活到 worker 退出、回收改按 worker 进程活性判。
		#   即 1v1 与另两个模式**在房间寿命上已经相同机制**,而宽限**仍然只有它没有** —— 这是一条
		#   **照实登记的既有不对称**,不是"因为不会发生所以不必加"。
		#   - 不收紧的**实际**依据是**量级**:触发它得先满足"房龄 ≥2h",而一局只有几分钟(正常房
		#   建房后几分钟内就开局)。但那不等于那扇窗不存在:同一个"开局转连窗口"在 1v1 同样成立 ——
		#   started 房在 `_start_match` 的 await 与客户端转连期间仍持有端口,一个房龄恰好 ≥2h 的房
		#   会在那次 tick 被连 worker 一起终止。本批**刻意不改**(范围裁剪,而非已修好);要收紧需另行评估。
		var in_match_grace := (SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + in_match_grace:
			stale_royale.append(rr)
	var stale_team: Array = []
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		# 在局中的 3v3 房宽限与 royale 相同机制(SWEEP_INTERVAL + 一局时长),但「一局时长」取的是
		# room_manager 自己的**估**值常量 TEAM_MATCH_ESTIMATE(3v3 没有可读的时长常量,推导与
		# **已知边界**见该常量的注释);等待中的房不占端口,仍按裸 MAX_ROOM_AGE 清。
		var grace := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace:
			stale_team.append(tr)
	# 注意： 这三条 `is_empty()` 是**并列**的,加第三张注册表时**必须一起收进来**:漏掉任何一张,
	#    "只有那张表的房超龄"的那次 tick 会在这里**提前 return、永远不清扫** → 端口永久泄漏
	#    (症状是静默的:列表拼接那行照旧在,看着像清扫还在跑)。本层为「端口泄漏」这同一个失败
	#    模式补过三次(见 lobby_rooms.teardown_room 的注释),这是它的第四种形态。
	#    守卫:`tests/smoke/room_sweep_smoke` 的 _check 逐个明确提示这三张表(去掉任一张即红)。
	if stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty():
		return
	# 日志照实报三条不同的界:1v1 与等待中的大乱斗/3v3 房都是裸 MAX_ROOM_AGE,在局的大乱斗房另加
	# SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING、在局的 3v3 房另加 SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE
	# (见 _sweep_stale_rooms 内 royale / team 两个分支的注释 —— 后者是估值)。
	print("[lobby] 清理 %d 个超时房间(1v1 %d 个 >%.0f 秒；大乱斗 %d 个：等待 >%.0f 秒 / 对局中 >%.0f 秒；3v3 %d 个：等待 >%.0f 秒 / 对局中 >%.0f 秒)" % [
			stale.size() + stale_royale.size() + stale_team.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING,
			stale_team.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE])
	# 三张注册表共用同一条拆除(worker 已被杀 → 端口直接回收,**不经** ROYALE/TEAM_PORT_REUSE_DELAY:
	# 那条延迟是给「没被杀、还在跑」的 worker 的)。通知 + 立刻断开房内玩家都交给统一集中处理函数。
	for room in stale + stale_royale + stale_team:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true)
		print("%s %s 超时清理完成(已存活 %.0f 秒)" % [
				"大乱斗房" if room is LobbyRooms.RoyaleRoom else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间"),
				room.code, now - room.created_at])

# 对局结束即回收:`in_match`(1v1 是 `started`)的房不再在"客户端转连 worker"那一刻被拆,
# 于是**必须有替代的回收路径** —— 否则端口与列表位永久占用(本层为「端口泄漏」这同一个失败
# 模式补过的第五次)。
# - 判据 = **worker 进程还在不在**(`WorkerLauncher.pid_alive`):三种模式的 worker 都在对局
#   结束时自己退(1v1 宽限到点收场退进程 / 大乱斗与 3v3 全员走光),这是"这局结束了吗"的
#   **精确**答案;任何按"一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口)。
# - 保底处理仍在:2h 超龄清扫(`_sweep_stale_rooms`)会把"worker 一直不退"的僵尸房连进程一起终止
#   —— 两条路径并存,不是二选一。
# 定期清理已结束的对局与超龄房间，资源释放统一经由 lobby.teardown_room 处理。
func _reclaim_finished_matches() -> void:
	# 定期清理凭据注册表中的过期条目（以 TOKEN_TTL_SECONDS 为上限）
	lobby.rejoin.prune(Time.get_ticks_msec())
	# 单进程架构下，若当前托管的对局会话仍有效，则无需回收房间；
	# 当会话对象已被释放或异常终止时，执行超时兜底清理。
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


