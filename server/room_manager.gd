class_name RoomManager
extends Node

# 大厅的**进程编排 + 定时清扫**(端口 7777 进程内)。房间状态本身在 `server/lobby_rooms.gd`
# (LobbyRooms),本类持有它并注入 launcher;拆除收口 `teardown_room` 随账本走,故这里一律
# 经 `lobby.teardown_room(...)` 调用。
#
# 本类只做两件事:
#   · **拉起对局 worker 并让玩家转连**:`royale_start` / `ai_duel` / `royale_start_ai` /
#     `team_start`(RPC 进来)+ `_start_match`(由 `lobby.pairing_ready` 信号进来)+ `_send_go_match*`;
#   · **定时清扫**超龄房间(三张注册表一起扫;推导与已知边界见 `_sweep_stale_rooms`)。
#
# ★ 房间 ↔ 编排 的方向是**单向**的:`lobby` 不知道本类;「1v1 凑齐两人」由 `pairing_ready`
#   信号上来。别再往 LobbyRooms 里塞 RoomManager 引用(那会退回 back-reference 的写法)。
var _launcher := WorkerLauncher.new()
# 房间账本(公开字段:探针/观察者要读注册表,如 royale_bound_probe 的 _rm().lobby.royale_rooms)
var lobby: LobbyRooms = null

# ── 僵尸房间定时清理:每 SWEEP_INTERVAL 秒扫一次,存在超 MAX_ROOM_AGE 的房间连 worker 一起杀 ──
const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
# 3v3 一局时长的**估**值(秒=30min),只用于 _sweep_stale_rooms 的在局宽限。
# ★ 它是**估**值,不是从任何常量读来的:TeamHost 侧没有一个"本局最多打多久"的常量可读
#   (RoyaleHost 那边有 MATCH_TIME,3v3 是三局两胜 —— 界变成"杀掉 9 人 × 3 局",没有对应常量),
#   故这里取粗上界:3 局 × (COUNTDOWN 3 + 打到 9 杀 + ROUND_OVER 4) 的量级。
# ★ 与 royale 那条宽限**同根因的已知边界**(照实登记):正确的界要读**本局实际时长**,而那个值
#   只存在于 worker 的 TeamHost 里,sweep 手里没有 —— 真要修得先把实际时长回传/登记到房上。
const TEAM_MATCH_ESTIMATE := 1800.0
var _sweep_acc := 0.0

# 对局中房间的回收梯周期(秒)。★ 比 SWEEP_INTERVAL(600s)密得多,因为判据与目的都不同:
# 那条是"房挂太久了"(超龄清扫),这条是"**这一局结束了**" —— 端口与列表位白占的代价是
# "池子少一个 / 列表里挂着一个死房",10 分钟一轮意味着每局结束后要多占最多 10 分钟。
# 30s 是"比端口归还延迟(120/360)小一个量级"的量级选择,与宽限期无关(判据不读宽限期)。
const MATCH_SWEEP_INTERVAL := 30.0
var _match_sweep_acc := 0.0


func _enter_tree() -> void:
	# 房间账本:本类持有并装配(注入 launcher),两者单向依赖。
	lobby = LobbyRooms.new()
	lobby.launcher = _launcher
	# 「1v1 凑齐两人」跨了边界(房间的事 + 拉 worker 的事)→ 由信号上来,避免反向引用。
	lobby.pairing_ready.connect(_start_match)
	add_child(lobby)
	# 编排侧的四条 RPC(它们要拉 worker,故不归房间账本)
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)
	# 3v3 的**第六条**上行归本类(其余五条 team_create/join/pick/leave/list 在 LobbyRooms)
	# —— 与大乱斗逐字同款的分工:账本接 royale_list,编排接 royale_start。
	NetBusExt.team_start_requested.connect(team_start)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)
	NetBusExt.team_start_requested.disconnect(team_start)


# 房主开局:满 2 人即可;拉起 N 人 worker → 全员 go_match 转连
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
	# ★ 开局那一刻把名单冻进房记录(理由见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(rr)
	# ★ token 必须在 **go_match 之前**发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,
	#   之后再发就静默丢失(Task 2 的 session_token 注释)。spawn 之前发则一定更早。
	for pid in rr.players:
		var tk := LobbyRooms.new_token()
		rr.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values()):
		rr.in_match = false
		# ★ 必须走拆除单一收口(2026-09-14,修 M1):收口会归还端口 + 摘掉注册表 + 通知房内玩家。
		#   原先直接 release_now 会把房间留在注册表里、且带着**已归还**的 worker_port →
		#   后续清扫按这个陈旧端口号去杀进程,可能误杀另一个正在跑的对局 worker。
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# ★ spawn 成功后登记 pid:回收梯靠它判"这一局还在不在"(`WorkerLauncher.pid_of` 读的正是
	#   那张端口→pid 表)。★ 位置不能挪到 spawn 之前:拉起失败那一刻 pid 还是 0,
	#   登记一个 0 等于让回收梯晚一个周期才发现(不致命,但没有理由)。
	rr.worker_pid = _launcher.pid_of(port)
	# 房主对局选项经 worker 侧 NetBusExt.player_options 以 role1 报到为准;这里随开局存档不打扰
	print("大乱斗房 %s 开局(%d 人,roles %s)→ worker 端口 %d" % [rr.code, rr.players.size(),
			str(rr.player_role.values()), port])
	# 稍等 worker 完成 bind,再全员转连
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


# 全员转连(延到帧末再判在线:见 _peer_online 注释 —— 转连期成员会陆续断开大厅,
# 同步发会踩"刚断开"窗口,报 channel 错误且 go_match 丢失)
# ★ token 由调用方在 **spawn 之前**已经发出(见 royale_start / royale_start_ai 里那段注释)。本函数
#   只发 go_match —— 客户端收到它就 NetBus.stop() 断大厅,所以任何"跟着 go_match 一起发"的
#   载荷都必须更早。别把 token 挪到这里。
# ★ 参数**刻意不带类型标注**(2026-09-19,3v3 Task 4):大乱斗房(`RoyaleRoom`)与 3v3 房
#   (`TeamRoom`)在本函数用到的两个字段上**同名同义** —— `players`(peer 数组)与
#   `player_role`(peer → role)。标了 `RoyaleRoom` 就会在传 `TeamRoom` 时**运行时类型不符**,
#   而"再抄一份 `_send_go_match_team`"是本仓明令禁止的第二份真相(见 LobbyRooms.teardown_room
#   的三态化:同一个动作只许有一处实现)。放宽成无类型即可;真要再收窄,得先给两种房抽公共协议。
func _send_go_match(rr, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	for peer_id in rr.players:
		if lobby.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", rr.player_role[peer_id], port)

# ── AI 补位对战(实验性):1v1 房主可请求与 AI 对战;大乱斗房主可 AI 补位开局 ──

# 1v1:房主请求 AI 对战 → 单人 go_match,role2 由服务端 AI 驱动
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
	# L5 合并补丁(刻意偏离移植来源,非误改):royale_start / royale_start_ai 都有的
	# 「已开局即拒绝」守卫,本 handler 从另一分支原样移植时缺失。
	# (本文件内引用一律写函数名不写行号 —— 行号会随每次编辑腐烂,而这段注释存在的意义就是
	#  让后来者看懂偏离;引错行号比不引更坏。)
	# 真实可达路径(不是"同房重复调用"——本函数在派 go_match 之前就把本房从 rooms 摘除了,重入会在上面的
	# `host_room == null` 就返回):一个**已配对开局的 1v1 房**(`_start_match` 置 `started = true`)
	# 在 `go_match` 后、`on_peer_left` 把它从 rooms 摘除前的窗口里收到 AI 对战请求 →
	# 会**再拉一个 worker 并覆盖 worker_port**,而本房紧接着被摘除 → 首个端口从此无人归还
	# (与下方那条泄漏同一后果)。协议可达(RPC 是 any_peer),暂无界面调用点(D13)。
	if host_room.started:
		return   # 已开局:拒绝(防双开 worker 覆盖 worker_port)
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	host_room.worker_port = port
	if not _launcher.spawn_worker(port, [2]):
		# ★ 走拆除单一收口(2026-09-14,修 M1;同 royale_start 的理由)
		lobby.teardown_room(host_room, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# L5 合并补丁(刻意偏离移植来源,非误改):下一行把房间从 rooms 摘除后,on_peer_left
	# 与 _sweep_stale_rooms 都只遍历 rooms,再无任何路径能归还本端口 —— 不在此处释放就会
	# 永久占用(500 次后 WorkerLauncher.pick_port 返回 -1,大厅彻底拉不起 worker)。
	# _release_port_later 是协程(内含 await),fire-and-forget 不 await(与 on_peer_left 同法)。
	lobby.teardown_room(host_room)   # 对局消费掉房间(AI 不占第二人位);端口延迟归还
	print("房间 %s → AI 对战开局(1 人 + AI)→ worker 端口 %d" % [host_room.code, port])
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
	# ★ 开局那一刻把名单冻进房记录(理由见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(rr)
	# AI role 号 = 1..max_players 内**人类未占用**的空闲号(见 _royale_free_roles)
	var ai_roles := lobby.royale_free_roles(rr, ai_count)
	# ★ token 必须在 **go_match 之前**发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,
	#   之后再发就静默丢失(Task 2 的 session_token 注释)。spawn 之前发则一定更早。
	#   AI 补位号没有 peer,故只给 `rr.players`(真人)发。
	for pid in rr.players:
		var tk := LobbyRooms.new_token()
		rr.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	# 参战集合 = 房里真人的已分配号 + AI 补位号(真人号可能带空洞,故不能写成 1..max_players)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values() + ai_roles, ai_roles):
		rr.in_match = false
		# ★ 走拆除单一收口(2026-09-14,修 M1;同 royale_start 的理由)
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# ★ spawn 成功后登记 pid:回收梯靠它判"这一局还在不在"(`WorkerLauncher.pid_of` 读的正是
	#   那张端口→pid 表)。★ 位置不能挪到 spawn 之前:拉起失败那一刻 pid 还是 0,
	#   登记一个 0 等于让回收梯晚一个周期才发现(不致命,但没有理由)。
	rr.worker_pid = _launcher.pid_of(port)
	print("大乱斗房 %s AI 补位开局(%d 真人 + %d AI)→ worker 端口 %d" % [rr.code, rr.players.size(), ai_count, port])
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


# ── 3v3:房主开局(**两队各 3 人**才允许)→ 拉起 --team worker → 全员 go_match 转连 ──
# ★ 与 royale_start 的三处实质差异:
#   ① 满员判据是"两队各 3 人"(不是"人数 ≥2")—— 4v2 人数也够 6,但那不是 3v3;
#   ② 命令行多一个 `--teams`(与 `--roles` **同序等长**),它才是队伍归属的唯一来源
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
	# ★ 开局那一刻把名单冻进房记录(理由见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(tr)
	# ★ token 必须在 **go_match 之前**发(go_match 一到客户端就 NetBus.stop() 断大厅;晚发静默丢失)
	for pid in tr.players:
		var tk := LobbyRooms.new_token()
		tr.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	# ★ roles 与 teams **同序**:roles 按号升序取,teams 跟着同一个顺序取队号。
	#   `team_of` 缺该 role(有人在满员判据之后、这里之前掉线/退房)时取 0 → spawn_team_worker
	#   的取值校验当场拒绝(只收 1/2)并返回 false,走下面的拆除 —— **不会**拉起一个必然 quit 的
	#   子进程再把"拉起成功"报成真(那正是 Task 9 评审 M2 的那个静默失败模式)。
	var roles: Array = tr.player_role.values()
	roles.sort()
	var teams: Array = []
	for r in roles:
		teams.append(int(tr.team_of.get(int(r), 0)))
	if not _launcher.spawn_team_worker(port, roles, teams):
		tr.in_match = false
		# ★ 走拆除单一收口(同 royale_start 的理由:收口会归还端口 + 摘注册表 + 通知房内玩家)
		lobby.teardown_room(tr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# ★ spawn 成功后登记 pid:回收梯靠它判"这一局还在不在"(`WorkerLauncher.pid_of` 读的正是
	#   那张端口→pid 表)。★ 位置不能挪到 spawn 之前:拉起失败那一刻 pid 还是 0,
	#   登记一个 0 等于让回收梯晚一个周期才发现(不致命,但没有理由)。
	tr.worker_pid = _launcher.pid_of(port)
	print("3v3 房 %s 开局(roles %s / teams %s)→ worker 端口 %d" % [tr.code,
			str(roles), str(teams), port])
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(tr, port)

# ── 配对完成 → 拉起对局 worker 并让两端转连 ──
func _start_match(room: LobbyRooms.Room) -> void:
	# 先置 started:同刻挡住第三人在这 0.3s 窗口误入(`join_room` 的 started 守卫)重复拉起 worker。
	# ★ 2026-09-21 订正:本条原先还写着「配对瞬间任何一方掉线都走 on_peer_left 的 started 即关房
	#   分支」—— 那条分支**已删除**(对局中的房必须活到对局结束,否则列表里再也看不见它,见
	#   LobbyRooms.on_peer_left 的注释)。掉线不再关房;回收改由回收梯按 **worker 进程活性**判
	#   (设计 §2.4)。★ 故下面两处 `if not lobby.rooms.has(...)` 今天**实际已够不着**,保留作防御。
	room.started = true
	# ★ 开局那一刻把名单冻进房记录:成员转连 worker 后会陆续断开大厅,靠 players/_peer_names
	#   渲染的对局中列表会退化成"玩家/玩家"(见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(room)
	var port := _launcher.pick_port()
	if port < 0:
		# 起不来局:房间作废,通知双方(不再滞留)
		room.worker_port = 0
		NetBus.reply(room.players[0], "server_message", "无法分配对局端口")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	room.worker_port = port
	# ★ token 必须在 **go_match 之前**发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,
	#   之后再发就静默丢失(Task 2 的 session_token 注释)。spawn 之前发则一定更早。
	for pid in room.players:
		var tk := LobbyRooms.new_token()
		room.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_worker(port):
		NetBus.reply(room.players[0], "server_message", "无法启动对局")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	# ★ spawn 成功后登记 pid:回收梯靠它判"这一局还在不在"(`WorkerLauncher.pid_of` 读的正是
	#   那张端口→pid 表)。★ 位置不能挪到 spawn 之前:拉起失败那一刻 pid 还是 0,
	#   登记一个 0 等于让回收梯晚一个周期才发现(不致命,但没有理由)。
	room.worker_pid = _launcher.pid_of(port)
	# 稍等 worker 完成 bind,再通知两端转连(worker 很快,300ms 足够)
	await get_tree().create_timer(0.3).timeout
	if not lobby.rooms.has(room.code):   # 0.3s 内已有玩家掉线触发关房 → 别再给幽灵房发 go_match
		return
	_send_go_match_1v1.call_deferred(room, port)
	print("房间 %s 配对完成 → worker 端口 %d" % [room.code, port])


# 1v1 全员转连(延到帧末再判在线:转连期双方会陆续断开大厅,见 _peer_online 注释)
# ★ token 由调用方在 **spawn 之前**已经发出(见 `_start_match` 里那段注释)。本函数只发
#   go_match —— 客户端收到它就 NetBus.stop() 断大厅,所以任何"跟着 go_match 一起发"的
#   载荷都必须更早。别把 token 挪到这里。
func _send_go_match_1v1(room: LobbyRooms.Room, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	if not lobby.rooms.has(room.code):   # 帧末前已关房 → 别再给幽灵房发 go_match
		return
	for peer_id in room.players:
		if lobby.is_peer_online(peer_id):
			NetBus.reply(peer_id, "go_match", room.player_role[peer_id], port)

# ── 定时扫描:每 SWEEP_INTERVAL 清理存在超 MAX_ROOM_AGE 的僵尸房间(连 worker 一起杀)──
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()
	# ★ 对局中房间的回收走**另一条更密的**梯(判据与目的都不同,见 MATCH_SWEEP_INTERVAL)。
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
# 「一整个扫描周期 + 一局时长」的宽限,推导与**已知边界**见下方 royale / team 两个分支。
# ★ 加新一张注册表时**两处都要动**:各自的 stale_* 收集块,以及末尾那条
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
		# 刻意偏离移植来源(非误改):在局中的大乱斗房宽限 = SWEEP_INTERVAL + RoyaleHost.MATCH_TIME
		# (即「一整个扫描周期」+「一局时长,取该常量的默认值」),这条界的**推导**是可证的:
		# 房龄从**建房**起算,含此前在大厅等待的全部时间——一个等满 MAX_ROOM_AGE 才开局的房,在开局
		# 那一刻就已"超龄";而清扫由 _process 的 SWEEP_INTERVAL 计时器驱动(不是每帧),房间可能已经
		# 比阈值老上**整整一个扫描周期**才等到判它超龄的那次 tick,即最迟可在房龄 MAX_ROOM_AGE +
		# SWEEP_INTERVAL 时开局。从 royale_start/royale_start_ai 拉起 worker 到成员转连离厅还有
		# 0.3~1.5s 的窗口,若宽限只有一局时长,紧随其后的那次 tick 仍会杀掉一个刚起几秒的 worker
		# 并踢掉正在转连的成员(边界竞态只是被推窄,没被关闭)。宽限覆盖「阈值 + 整个扫描周期 +
		# 一局」后,等待期攒下的那一整个周期与默认时长的整局对局都落在界内。
		# ★ **已知边界(照实登记,本次不修)**:上面的「一局」取 RoyaleHost.MATCH_TIME(300s),
		#   而它是**默认值、不是上限**——房主可在建房页用「一局限时」滑块自定义,该值经
		#   NetBusExt.player_options 的 match_time(**Settings.royale_match_min × 60**,设置里钳在
		#   1~30 分钟)随 role1 报到进 RoyaleHost,一局最长 1800s。于是**一个等了近 2h 才开局、
		#   又配了长时长的房**,其对局进行到 300s 之后的那次 tick 仍会判它超龄并连 worker 一起杀掉
		#   (缺口最大约 1500s)。不在本次放宽的原因:触发它还得先满足「房龄近 2h」(正常房建房后
		#   几分钟内就开局),而正确的修法是让宽限读**本局实际时长**——该值只存在于 worker 的
		#   RoyaleHost 里,sweep 手里没有,要修得先把实际时长回传/登记到房上,属另行评估的范围。
		# 等待中(in_match=false)的房不占端口、杀不到任何东西,仍按裸 MAX_ROOM_AGE 清,无需宽限。
		# ★ 1v1 分支**刻意不享受**同样宽限。2026-09-21 订正本条的**理由**(行为一字未动):
		#   旧理由引的是「started 房一方掉线即整房作废」(_start_match / on_peer_left 那条 started 分支)
		#   —— 那条分支**已删除**,对局中的 1v1 房现在活到 worker 退出、回收改按 worker 进程活性判。
		#   即 1v1 与另两个模式**在房间寿命上已经同款**,而宽限**仍然只有它没有** —— 这是一条
		#   **照实登记的既有不对称**,不是"因为不会发生所以不必加"。
		#   ★ 不收紧的**实际**依据是**量级**:触发它得先满足"房龄 ≥2h",而一局只有几分钟(正常房
		#   建房后几分钟内就开局)。但那不等于那扇窗不存在:同一个"开局转连窗口"在 1v1 同样成立 ——
		#   started 房在 `_start_match` 的 await 与客户端转连期间仍持有端口,一个房龄恰好 ≥2h 的房
		#   会在那次 tick 被连 worker 一起杀掉。本批**刻意不改**(范围裁剪,而非已修好);要收紧需另行评估。
		var in_match_grace := (SWEEP_INTERVAL + RoyaleHost.MATCH_TIME) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + in_match_grace:
			stale_royale.append(rr)
	var stale_team: Array = []
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		# 在局中的 3v3 房宽限与 royale 同款(SWEEP_INTERVAL + 一局时长),但「一局时长」取的是
		# room_manager 自己的**估**值常量 TEAM_MATCH_ESTIMATE(3v3 没有可读的时长常量,推导与
		# **已知边界**见该常量的注释);等待中的房不占端口,仍按裸 MAX_ROOM_AGE 清。
		var grace := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace:
			stale_team.append(tr)
	# ★★ 这三条 `is_empty()` 是**并列**的,加第三张注册表时**必须一起收进来**:漏掉任何一张,
	#    "只有那张表的房超龄"的那次 tick 会在这里**提前 return、永远不清扫** → 端口永久泄漏
	#    (症状是静默的:列表拼接那行照旧在,看着像清扫还在跑)。本层为「端口泄漏」这同一个失败
	#    模式补过三次(见 lobby_rooms.teardown_room 的注释),这是它的第四种形态。
	#    守卫:`tests/room_sweep_smoke` 的 _check 逐个点名这三张表(去掉任一张即红)。
	if stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty():
		return
	# 日志照实报三条不同的界:1v1 与等待中的大乱斗/3v3 房都是裸 MAX_ROOM_AGE,在局的大乱斗房另加
	# SWEEP_INTERVAL + RoyaleHost.MATCH_TIME、在局的 3v3 房另加 SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE
	# (见 _sweep_stale_rooms 内 royale / team 两个分支的注释 —— 后者是估值)。
	print("[lobby] 清理 %d 个超龄房间(1v1 %d 个 >%.0f 秒;大乱斗 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒;3v3 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒)" % [
			stale.size() + stale_royale.size() + stale_team.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + RoyaleHost.MATCH_TIME,
			stale_team.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE])
	# 三张注册表共用同一条拆除(worker 已被杀 → 端口直接回收,**不经** ROYALE/TEAM_PORT_REUSE_DELAY:
	# 那条延迟是给「没被杀、还在跑」的 worker 的)。通知 + 立刻断开房内玩家都交给收口函数。
	for room in stale + stale_royale + stale_team:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true)
		print("%s %s 超时清理(存活 %.0f 秒)" % [
				"大乱斗房" if room is LobbyRooms.RoyaleRoom else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间"),
				room.code, now - room.created_at])

# 对局结束即回收:`in_match`(1v1 是 `started`)的房不再在"客户端转连 worker"那一刻被拆,
# 于是**必须有替代的回收路径** —— 否则端口与列表位永久占用(本层为「端口泄漏」这同一个失败
# 模式补过的第五次)。
# ★ 判据 = **worker 进程还在不在**(`WorkerLauncher.pid_alive`):三种模式的 worker 都在对局
#   结束时自己退(1v1 宽限到点收场退进程 / 大乱斗与 3v3 全员走光),这是"这局结束了吗"的
#   **精确**答案;任何按"一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口)。
# ★ 兜底仍在:2h 超龄清扫(`_sweep_stale_rooms`)会把"worker 一直不退"的僵尸房连进程一起杀掉
#   —— 两条路径并存,不是二选一。
# ★ 回收**必须走拆除单一收口**(端口归还/注册表删除只许出现在 `lobby_rooms.teardown_room`
#   与 `_release_port_later` 里;`room_sweep_smoke` 的 `_check_reclaim_ladder` 钉住本函数)。
func _reclaim_finished_matches() -> void:
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
		var kind := "大乱斗房" if room is LobbyRooms.RoyaleRoom \
				else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间")
		print("[lobby] 对局结束,回收%s %s(端口 %d)" % [kind, room.code, room.worker_port])
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)


# 这一局结束了吗(worker 进程已经不在)?★ `port <= 0` 或 `pid <= 0` 一律**不算**结束 ——
# 那两种取值都只出现在"拉起中"的窗口里(`worker_port` 在 `pick_port` 之后才赋值,pid 在
# `create_process` 成功之后才登记),判成结束会让开局那一瞬被自己的回收梯拆掉。
static func _match_over(port: int, pid: int) -> bool:
	if port <= 0 or pid <= 0:
		return false
	return not WorkerLauncher.pid_alive(pid)


# 建局引导已搬到 server/match_bootstrap.gd(MatchBootstrap.start_on)—— 那是 worker 进程内的
# 职责,与对局宿主(MatchHost/RoyaleHost)同侧;留在大厅的房间注册表里会让 worker 因
# class_name 连带加载整张大厅注册表(端口池/房间广播/杀进程)。调用点见 server_main.gd。
