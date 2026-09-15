class_name RoomManager
extends Node

# 大厅的**进程编排 + 定时清扫**(端口 7777 进程内)。房间状态本身在 `server/lobby_rooms.gd`
# (LobbyRooms),本类持有它并注入 launcher;拆除收口 `teardown_room` 随账本走,故这里一律
# 经 `lobby.teardown_room(...)` 调用。
#
# 本类只做两件事:
#   · **拉起对局 worker 并让玩家转连**:`royale_start` / `ai_duel` / `royale_start_ai`
#     (RPC 进来)+ `_start_match`(由 `lobby.pairing_ready` 信号进来)+ `_send_go_match*`;
#   · **定时清扫**超龄房间(两张注册表一起扫;推导与已知边界见 `_sweep_stale_rooms`)。
#
# ★ 房间 ↔ 编排 的方向是**单向**的:`lobby` 不知道本类;「1v1 凑齐两人」由 `pairing_ready`
#   信号上来。别再往 LobbyRooms 里塞 RoomManager 引用(那会退回 back-reference 的写法)。
var _launcher := WorkerLauncher.new()
# 房间账本(公开字段:探针/观察者要读注册表,如 royale_bound_probe 的 _rm().lobby.royale_rooms)
var lobby: LobbyRooms = null

# ── 僵尸房间定时清理:每 SWEEP_INTERVAL 秒扫一次,存在超 MAX_ROOM_AGE 的房间连 worker 一起杀 ──
const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
var _sweep_acc := 0.0


func _enter_tree() -> void:
	# 房间账本:本类持有并装配(注入 launcher),两者单向依赖。
	lobby = LobbyRooms.new()
	lobby.launcher = _launcher
	# 「1v1 凑齐两人」跨了边界(房间的事 + 拉 worker 的事)→ 由信号上来,避免反向引用。
	lobby.pairing_ready.connect(_start_match)
	add_child(lobby)
	# 编排侧的三条 RPC(它们要拉 worker,故不归房间账本)
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)


func _exit_tree() -> void:
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)


# 房主开局:满 2 人即可;拉起 N 人 worker → 全员 go_match 转连
func royale_start(caller: int) -> void:
	var rr := lobby.royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.rpc_id(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return   # 已开局(重复请求防重入:不会双开 worker)
	if rr.players.size() < LobbyRooms.ROYALE_MIN_PLAYERS:
		NetBus.rpc_id(caller, "server_message", "至少 %d 人才能开始" % LobbyRooms.ROYALE_MIN_PLAYERS)
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
	if not _launcher.spawn_royale_worker(port, rr.player_role.values()):
		rr.in_match = false
		# ★ 必须走拆除单一收口(2026-09-14,修 M1):收口会归还端口 + 摘掉注册表 + 通知房内玩家。
		#   原先直接 release_now 会把房间留在注册表里、且带着**已归还**的 worker_port →
		#   后续清扫按这个陈旧端口号去杀进程,可能误杀另一个正在跑的对局 worker。
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	# 房主对局选项经 worker 侧 NetBusExt.player_options 以 role1 报到为准;这里随开局存档不打扰
	print("大乱斗房 %s 开局(%d 人,roles %s)→ worker 端口 %d" % [rr.code, rr.players.size(),
			str(rr.player_role.values()), port])
	# 稍等 worker 完成 bind,再全员转连
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)


# 全员转连(延到帧末再判在线:见 _peer_online 注释 —— 转连期成员会陆续断开大厅,
# 同步发会踩"刚断开"窗口,报 channel 错误且 go_match 丢失)
func _send_go_match(rr: LobbyRooms.RoyaleRoom, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	for peer_id in rr.players:
		if lobby.is_peer_online(peer_id):
			NetBus.rpc_id(peer_id, "go_match", rr.player_role[peer_id], port)

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
		NetBus.rpc_id(caller, "server_message", "只有建房(房主)才能开 AI 对战")
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
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
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
	NetBus.rpc_id(caller, "go_match", 1, port)

# 大乱斗:房主 AI 补位开局 → 现有真人 + AI 补到 max_players
func royale_start_ai(caller: int) -> void:
	var rr := lobby.royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.rpc_id(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return
	var ai_count := rr.max_players - rr.players.size()
	if ai_count <= 0:
		NetBus.rpc_id(caller, "server_message", "房间已满,无需 AI 补位")
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
	# AI role 号 = 1..max_players 内**人类未占用**的空闲号(见 _royale_free_roles)
	var ai_roles := lobby.royale_free_roles(rr, ai_count)
	# 参战集合 = 房里真人的已分配号 + AI 补位号(真人号可能带空洞,故不能写成 1..max_players)
	if not _launcher.spawn_royale_worker(port, rr.player_role.values() + ai_roles, ai_roles):
		rr.in_match = false
		# ★ 走拆除单一收口(2026-09-14,修 M1;同 royale_start 的理由)
		lobby.teardown_room(rr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	print("大乱斗房 %s AI 补位开局(%d 真人 + %d AI)→ worker 端口 %d" % [rr.code, rr.players.size(), ai_count, port])
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(rr, port)

# ── 配对完成 → 拉起对局 worker 并让两端转连 ──
func _start_match(room: LobbyRooms.Room) -> void:
	# 先置 started:配对瞬间任何一方掉线都走 on_peer_left 的「started 即关房」分支,
	# 不会留下 1/2 幽灵房;同时也挡住第三人在这 0.3s 窗口误入重复拉起 worker。
	room.started = true
	var port := _launcher.pick_port()
	if port < 0:
		# 起不来局:房间作废,通知双方(不再滞留)
		room.worker_port = 0
		NetBus.rpc_id(room.players[0], "server_message", "无法分配对局端口")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	room.worker_port = port
	if not _launcher.spawn_worker(port):
		NetBus.rpc_id(room.players[0], "server_message", "无法启动对局")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	# 稍等 worker 完成 bind,再通知两端转连(worker 很快,300ms 足够)
	await get_tree().create_timer(0.3).timeout
	if not lobby.rooms.has(room.code):   # 0.3s 内已有玩家掉线触发关房 → 别再给幽灵房发 go_match
		return
	_send_go_match_1v1.call_deferred(room, port)
	print("房间 %s 配对完成 → worker 端口 %d" % [room.code, port])


# 1v1 全员转连(延到帧末再判在线:转连期双方会陆续断开大厅,见 _peer_online 注释)
func _send_go_match_1v1(room: LobbyRooms.Room, port: int) -> void:
	await get_tree().process_frame   # 同 _flush_royale_state:等断开信号落定再判在线
	if not lobby.rooms.has(room.code):   # 帧末前已关房 → 别再给幽灵房发 go_match
		return
	for peer_id in room.players:
		if lobby.is_peer_online(peer_id):
			NetBus.rpc_id(peer_id, "go_match", room.player_role[peer_id], port)

# ── 定时扫描:每 SWEEP_INTERVAL 清理存在超 MAX_ROOM_AGE 的僵尸房间(连 worker 一起杀)──
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()

# 清理:房间从创建起超 MAX_ROOM_AGE 秒 → 杀其 worker(若有)→ 踢房内玩家 → 删房归还端口。
# 刻意偏离移植来源(非误改):原清扫只遍历 rooms(1v1),royale_rooms 是合并后并存的第二张注册表。
# 大乱斗房的 worker_port 只在开局时分配,而唯一归还路径是 on_peer_left 的「空房」分支——
# 成员若一直连着不吭声(ENet 不会超时「连接仍在但对端沉默」的 peer),端口就被永久占用
# (WORKER_PORT_SPAN=500 耗尽后 WorkerLauncher.pick_port 恒 -1,大厅彻底拉不起 worker)。
# 故两表共用同一 MAX_ROOM_AGE 一并清扫。不跳过 in_match 房:在局中的房另加
# 「一整个扫描周期 + 一局时长」的宽限,推导与**已知边界**见下方 royale 分支。
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
		# 1v1 分支不享受同样宽限:"started 房一方掉线即整房作废"(_start_match/on_peer_left)堵住的
		# 是**泄漏**,不是**竞态**——同一个开局转连窗口在 1v1 同样成立:started 房在 _start_match 的
		# await 与客户端转连期间仍持有端口,却按裸 MAX_ROOM_AGE 判超龄,同样可能被一次 tick 连 worker
		# 一起杀掉。本次不动 1v1 是**刻意的范围裁剪**(照实登记,而非已修好);若要同样收紧需另行评估。
		var in_match_grace := (SWEEP_INTERVAL + RoyaleHost.MATCH_TIME) if rr.in_match else 0.0
		if now - rr.created_at > MAX_ROOM_AGE + in_match_grace:
			stale_royale.append(rr)
	if stale.is_empty() and stale_royale.is_empty():
		return
	# 日志照实报两条不同的界:1v1 与等待中的大乱斗房都是裸 MAX_ROOM_AGE,在局大乱斗房另加
	# SWEEP_INTERVAL + RoyaleHost.MATCH_TIME(见 _sweep_stale_rooms 内 royale 分支的注释)。
	print("[lobby] 清理 %d 个超龄房间(1v1 %d 个 >%.0f 秒;大乱斗 %d 个:等待 >%.0f 秒 / 在局 >%.0f 秒)" % [
			stale.size() + stale_royale.size(), stale.size(), MAX_ROOM_AGE,
			stale_royale.size(), MAX_ROOM_AGE,
			MAX_ROOM_AGE + SWEEP_INTERVAL + RoyaleHost.MATCH_TIME])
	# 两张注册表共用同一条拆除(worker 已被杀 → 端口直接回收,**不经** ROYALE_PORT_REUSE_DELAY:
	# 那条延迟是给「没被杀、还在跑」的 worker 的)。通知 + 立刻断开房内玩家都交给收口函数。
	for room in stale + stale_royale:
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "房间超时(>2h),已关闭", true)
		print("%s %s 超时清理(存活 %.0f 秒)" % [
				"大乱斗房" if room is LobbyRooms.RoyaleRoom else "房间", room.code, now - room.created_at])

# 建局引导已搬到 server/match_bootstrap.gd(MatchBootstrap.start_on)—— 那是 worker 进程内的
# 职责,与对局宿主(MatchHost/RoyaleHost)同侧;留在大厅的房间注册表里会让 worker 因
# class_name 连带加载整张大厅注册表(端口池/房间广播/杀进程)。调用点见 server_main.gd。
