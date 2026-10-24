class_name RoomManager
extends Node

# 大厅的进程编排 + 定时清扫(端口 7777 进程内):房间状态在 LobbyRooms,本类持有它并注入 launcher,拆除一律经 lobby.teardown_room。
# ★ 方向是单向的:lobby 不知道本类,「1v1 凑齐两人」由 pairing_ready 信号上来 —— 别再往 LobbyRooms 里塞 RoomManager 引用。
var _launcher := WorkerLauncher.new()

var lobby: LobbyRooms = null


const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
# 3v3 一局时长的估值(秒=30min),只用于 _sweep_stale_rooms 的在局宽限。★ TeamHost 侧没有「本局最多打多久」的常量可读
# (大乱斗有 MATCH_TIME,3v3 是三局两胜),故取粗上界:3 局 × (COUNTDOWN 3 + 打到 9 杀 + ROUND_OVER 4)。⚠ 已知边界(3v3 独有,不修)。
const TEAM_MATCH_ESTIMATE := 1800.0
# 大乱斗一局长度的可证上界:Settings.royale_match_min 的装载钳位是 [1.0, 30.0] 分钟 ⇒ 秒数上界 30 × 60 = 1800。
# ★ 用硬上界而不是「把房主配的时长存到房上」:_player_options() 是报到那一刻才读 Settings,而 royale_create 更早(它压根不转发
# match_time)⇒ 存下来的是下界。★ 跨文件不变量(链有两环):钳位放宽到 30 分钟以上、或 mp_lobby.gd 的秒换算被改 —— 任一环断裂
# 本上界就静默失效;守卫 = tools/room_sweep_lint.gd(它读那两个文件的片段)。⚠ 本界覆盖的是对局时钟 + 一个扫描周期,残余暴露 ~3~25s。
const ROYALE_MATCH_TIME_CEILING := 1800.0
var _sweep_acc := 0.0

# 对局中房间的回收梯周期(秒)。★ 比 SWEEP_INTERVAL 密得多,因为判据与目的都不同:那条是「房挂太久了」,这条是「这一局结束了」——
# 10 分钟一轮意味着每局结束后要多占最多 10 分钟。30s 是「比端口归还延迟(120/360)小一个量级」的量级选择,判据不读宽限期。
const MATCH_SWEEP_INTERVAL := 30.0
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
	NetBusExt.pvp_start_requested.connect(pvp_start)   # 1v1 房主开局(2026-10-24:不再两人自动开)

	NetBusExt.room_map_requested.connect(lobby.on_room_map)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)
	NetBusExt.pvp_start_requested.disconnect(pvp_start)

	NetBusExt.room_map_requested.disconnect(lobby.on_room_map)



# 1v1 房主开局:门禁全在房间层(LobbyRooms.pvp_start:房主 = players[0] / 必须 2 人 / 未开局),这里只转发。
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
		return   # 已开局(重复请求防重入:不会双开 worker)
	if rr.players.size() < LobbyRooms.ROYALE_MIN_PLAYERS:
		NetBus.reply(caller, "server_message", "至少 %d 人才能开始" % LobbyRooms.ROYALE_MIN_PLAYERS)
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
# ★ 开局那一刻把名单冻进房记录:成员转连 worker 后会陆续断开大厅,靠 players / _peer_names 渲染的列表会退化(见 LobbyRooms.freeze_roster)。
	lobby.freeze_roster(rr)
# ★ token 必须在 go_match 之前发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,之后再发就静默丢失;登记进回局表则要等 spawn 成功(要 pid)。
	var granted: Array = []   # [[role, token], …]
	for pid in rr.players:
		var tk := LobbyRooms.new_token()
		granted.append([int(rr.player_role[pid]), tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values()):
		rr.in_match = false
# ★ 拉起失败必须走拆除单一收口:直接 release_now 会把房间留在注册表里、且带着已归还的 worker_port ⇒ 后续清扫按那个陈旧
# 端口去杀进程,可能误杀另一个正在跑的对局 worker。
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
# ★ spawn 成功后才登记 pid(回收梯靠它判「这一局还在不在」);位置不能挪到 spawn 之前 —— 失败那一刻 pid 还是 0,登记 0 只会让回收梯晚一个周期才发现。
	rr.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(rr.code, port, granted)

	NetDiag.audit("match_start", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "port": port,
			"players": rr.players.size(), "roles": str(rr.player_role.values()), "ai": 0})

	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


# 把这一局的回局凭据登进大厅的凭据表。★ 必须在 spawn 成功之后调(凭据里带 pid,「这一局还在不在」就是靠它判的);granted 的构造在 spawn 之前(token 要先于 go_match 发)。
func _grant_rejoin(code: String, port: int, granted: Array) -> void:
	var pid := _launcher.pid_of(port)
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), code, int(g[0]), port, pid, now)


# 全员转连(延到帧末再判在线:转连期成员会陆续断开大厅,同步发会踩「刚断开」窗口,报 channel 错误且 go_match 丢失)。
# ★ 参数刻意不带类型标注:大乱斗房与 3v3 房在这两个字段上同名同义(players / player_role),标了就会在传另一种房时运行时
# 类型不符,而「再抄一份 _send_go_match_team」是本仓禁止的第二份真相(同一个动作只许有一处实现)。
func _send_go_match(rr, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	for peer_id in rr.players:
		if lobby.is_peer_online(peer_id):
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
# ★ 「已开局即拒绝」守卫是刻意补上的(其余 handler 都有):一个已配对开局的 1v1 房在 go_match 之后、被摘除之前的窗口里
# 收到 AI 对战请求,会再拉一个 worker 并覆盖 worker_port,而本房紧接着被摘除 ⇒ 首个端口从此无人归还。
	if host_room.started:
		return   # 已开局:拒绝(防双开 worker 覆盖 worker_port)
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	host_room.worker_port = port
	if not _launcher.spawn_worker(port, [2]):

		lobby.teardown_room(host_room, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
# ★ 下一行把房间从 rooms 摘除后,再无任何路径能归还本端口 —— 不在此处释放就是永久占用(500 次后 pick_port 恒 -1,大厅彻底拉不起 worker)。
	lobby.teardown_room(host_room, LobbyRooms.TEARDOWN_DELAYED, "", false, "match_end")   # 对局消费掉房间(AI 不占第二人位);端口延迟归还
	NetDiag.audit("match_start", {"room": host_room.code, "mode": ModeDefs.MODE_PVP, "port": port,
			"players": 1, "ai": 1})
	await get_tree().create_timer(0.3).timeout
	NetBus.reply(caller, "go_match", 1, port)

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
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true

	lobby.freeze_roster(rr)

	var ai_roles := lobby.royale_free_roles(rr, ai_count)

	var granted: Array = []   # [[role, token], …]
	for pid in rr.players:
		var tk := LobbyRooms.new_token()
		granted.append([int(rr.player_role[pid]), tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
# 参战集合 = 房里真人的已分配号 + AI 补位号(真人号可能带空洞,故不能写成 1..max_players)。
	if not _launcher.spawn_royale_worker(port, rr.player_role.values() + ai_roles, ai_roles):
		rr.in_match = false

		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return

	rr.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(rr.code, port, granted)
	NetDiag.audit("match_start", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "port": port,
			"players": rr.players.size(), "ai": ai_count})
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


# ── 3v3:房主开局(两队各 3 人才允许)→ 拉起 --team worker → 全员 go_match。★ 与 royale_start 的三处实质差异:
# ① 满员判据是「两队各 3 人」(4v2 人数也够 6,但那不是 3v3);② 命令行多一个 --teams(与 --roles 同序等长),它才是队伍
# 归属的唯一来源(role 号因「退出留空洞、最小空闲号复用」而不连续,推不出队号);③ 没有 AI 补位(用户裁定:满 6 人才开)。
func team_start(caller: int) -> void:
	var tr := lobby.team_room_of(caller)
	if tr == null:
		return
	if tr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if tr.in_match:
		return   # 已开局(重复请求防重入:不会双开 worker)
	if not lobby.team_room_ready(tr):
		NetBus.reply(caller, "server_message", "两队各 3 人才能开始")
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	tr.worker_port = port
	tr.in_match = true

	lobby.freeze_roster(tr)

	var granted: Array = []   # [[role, token], …]
	for pid in tr.players:
		var tk := LobbyRooms.new_token()
		granted.append([int(tr.player_role[pid]), tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
# ★ roles 与 teams 同序:roles 按号升序取,teams 跟着同一顺序取队号。★ team_of 缺该 role 时取 0 ⇒ spawn_team_worker 的取值校验当场拒绝并走拆除,不会拉起一个必然 quit 的子进程。
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

	_grant_rejoin(tr.code, port, granted)
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

	var granted: Array = []   # [[role, token], …]
	for pid in room.players:
		var tk := LobbyRooms.new_token()
		granted.append([int(room.player_role[pid]), tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_worker(port):
		NetBus.reply(room.players[0], "server_message", "无法启动对局")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return

	room.worker_pid = _launcher.pid_of(port)

	_grant_rejoin(room.code, port, granted)

	await get_tree().create_timer(0.3).timeout
	if not lobby.rooms.has(room.code):   # 0.3s 内已有玩家掉线触发关房 → 别再给幽灵房发 go_match
		return
	_send_go_match_1v1.call_deferred(room, port)
	NetDiag.audit("match_start", {"room": room.code, "mode": ModeDefs.MODE_PVP, "port": port,
			"players": room.players.size(), "ai": 0})



func _send_go_match_1v1(room: LobbyRooms.Room, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	if not lobby.rooms.has(room.code):   # 帧末前已关房 → 别再给幽灵房发 go_match
		return
	for peer_id in room.players:
		if lobby.is_peer_online(peer_id):
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

# 清理:房间从创建起超 MAX_ROOM_AGE 秒 → 杀其 worker(若有)→ 踢房内玩家 → 删房归还端口。★ 三张注册表都要扫:
# 大乱斗 / 3v3 房的 worker_port 只在开局时分配,成员若一直连着不吭声就被永久占用(池子 500 耗尽 ⇒ pick_port 恒 -1)。不跳过 in_match 房。
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
# ★ 在局宽限 = SWEEP_INTERVAL + 一局时长:房龄从建房起算(含此前在大厅等待的全部时间),而清扫由 _process 的计时器驱动、
# 不是每帧 ⇒ 房间可能已比阈值老上整整一个扫描周期才等到判它的那次 tick;从拉起 worker 到成员转连离厅还有 0.3~1.5s。
# 宽限盖住「阈值 + 整个扫描周期 + 最长一局」,等待中(in_match=false)的房不占端口、杀不到东西,仍按裸 MAX_ROOM_AGE 清。
# ⚠ 1v1 分支刻意不享受同样宽限(照实登记的既有不对称):2h 超龄 + 一局只有几分钟,量级上够不着,但同一扇「开局转连窗口」在 1v1 同样成立。
		var in_match_grace := (SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + in_match_grace:
			stale_royale.append(rr)
	var stale_team: Array = []
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
# 在局中的 3v3 房宽限与 royale 同款,但「一局时长」取的是估值常量 TEAM_MATCH_ESTIMATE(推导与已知边界见该常量);等待中的房仍按裸 MAX_ROOM_AGE 清。
		var grace := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace:
			stale_team.append(tr)
# ★★ 这三条 is_empty() 是并列的,加新注册表时必须一起收进来:漏掉任何一张,「只有那张表的房超龄」的那次 tick 会在这里提前
# return、永远不清扫 ⇒ 端口永久泄漏,而症状是静默的(列表拼接那行照旧在)。守卫 = tools/room_sweep_lint 的 _check 逐个点名这三张表。
	if stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty():
		return

	print("[lobby] 清理 %d 个超龄房间(1v1 %d 个 >%.0f 秒;大乱斗 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒;3v3 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒)" % [
			stale.size() + stale_royale.size() + stale_team.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING,
			stale_team.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE])
# 三张注册表共用同一条拆除(worker 已被杀 ⇒ 端口直接回收,不经 ROYALE/TEAM_PORT_REUSE_DELAY:那条延迟是给「没被杀、还在跑」的 worker 的)。
	for room in stale + stale_royale + stale_team:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true, "sweep_timeout")

# 对局结束即回收:in_match(1v1 是 started)的房不再在「客户端转连 worker」那一刻被拆,必须有替代回收路径,否则端口与列表位永久占用。
# ★ 判据 = worker 进程还在不在(WorkerLauncher.pid_alive):三种模式的 worker 都在对局结束时自己退,这是精确答案;任何按「一局
# 大约多久」估的界都会既早(收掉还在打的局)又晚(白占端口)。★ 兜底仍在:2h 超龄清扫会把 worker 一直不退的僵尸房连进程一起杀掉。
# ★ 回收必须走拆除单一收口(端口归还 / 注册表删除只许出现在 lobby_rooms.teardown_room 与 _release_port_later;lint 的 _check_reclaim_ladder 钉住本函数)。
func _reclaim_finished_matches() -> void:
# ★ 凭据表的 GC 搭这条梯(30s 一次):TTL 只是表的上界,不需要独立定时器,再立一条梯就是本仓禁止的「同一件事两处实现」。
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


# 这一局结束了吗(worker 进程已经不在)?★ port <= 0 或 pid <= 0 一律不算结束 —— 那两种取值都只出现在「拉起中」的窗口里
# (worker_port 在 pick_port 之后才赋值,pid 在 create_process 成功之后才登记),判成结束会让开局那一瞬被自己的回收梯拆掉。
static func _match_over(port: int, pid: int) -> bool:
	if port <= 0 or pid <= 0:
		return false
	return not WorkerLauncher.pid_alive(pid)



