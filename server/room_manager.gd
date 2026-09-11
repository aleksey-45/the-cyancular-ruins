class_name RoomManager
extends Node

# 房间注册表(大厅进程,端口 7777):房间号 → 玩家;2 人就绪配对。
# 不再在大厅进程建 MatchHost——配对完成后为每局拉起一个独立 headless worker 子进程
# (独占一个 UDP 端口),对局全程在 worker 内运行 → 各局内存天然隔离,共享全局(current_grid/
# TileDefs)不会跨局互踩。worker 由 NetBus 转交信号驱动,不硬依赖 RoomManager 类型。

# PvP 固定竞技场地图(1v1,含 # player / # player2 出生点)。
const PVP_MAP := "res://maps/factory1v1.cyrm"
# 对局 worker 端口分配:每次 spawn 发**不重复**的端口。注意不能用本进程 bind 探测"空闲"
# —— worker 是独立进程,大厅本进程绑定测试看不到其它进程已占的 socket(并发时会把同端口
# 发给两个 worker,后者绑定失败退出)。唯一递增 + 占用集合即可保证并发零冲突。
const WORKER_PORT_BASE := 7800
const WORKER_PORT_SPAN := 500
# 端口归还延迟(秒)。不能在房间清空时立刻归还:玩家转连 worker 的瞬间大厅就关房,
# 而旧 worker 要等客户端真正断开(对局结束/退菜单)才退出,窗口期可达数分钟;
# 立刻复用会把同端口发给新 worker → bind 冲突,或旧 worker 抢到新局的客户端(跨房间串线)。
# 30s 足够旧 worker 走完收尾;极端情况(客户端僵死不断开)由 500 端口轮回兜底。
const WORKER_PORT_REUSE_DELAY := 30.0
# 大乱斗 worker 的端口归还延迟:一局最长 5 分钟(RoyaleHost.MATCH_TIME=300)+ 收尾,
# 沿用 30s 会让对局中途端口被发给新 worker(串线/bind 冲突)——自检 M2。
const ROYALE_PORT_REUSE_DELAY := 360.0
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口

class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> 1/2
	var started := false                 # 已拉起 worker/已配对:拒绝再次加入,一方掉线即整房作废
	var match_host: Node = null           # 保留字段:worker 模式下大厅恒为 null
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)

var rooms: Dictionary = {}   # code -> Room
var _peer_names: Dictionary = {}   # peer id -> 昵称(客户端连上大厅时上报,列表/建房展示)

# ── 僵尸房间定时清理:每 SWEEP_INTERVAL 秒扫一次,存在超 MAX_ROOM_AGE 的房间连 worker 一起杀 ──
const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
var _sweep_acc := 0.0

# ── 大乱斗房间(与 1v1 房间并存,独立注册表;N 人在同一房等待,房主手动开局)──
const ROYALE_MIN_PLAYERS := 2
const ROYALE_MAX_PLAYERS := 8
const ROYALE_DEFAULT_MAX := 4

class RoyaleRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(房内成员,含房主)
	var player_role: Dictionary = {}      # peer id -> role(1..N,大乱斗角色号)
	var is_public := true
	var invite_code := ""                 # 私密房凭此码进入
	var max_players := ROYALE_DEFAULT_MAX
	var options: Dictionary = {}          # 房主对局选项(禁武器/回合回血),开局随房主生效
	var in_match := false                 # 已开局(拒绝加入;成员转连 worker 后房即散)
	var worker_port: int = 0              # 本房拉起的大乱斗 worker 端口(关房时归还)
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超龄清理用,与 Room.created_at 同形)

var royale_rooms: Dictionary = {}   # code -> RoyaleRoom

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
	NetBusExt.royale_start_requested.connect(royale_start)
	NetBusExt.ai_duel_requested.connect(ai_duel)
	NetBusExt.royale_start_ai_requested.connect(royale_start_ai)

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
	NetBusExt.royale_start_requested.disconnect(royale_start)
	NetBusExt.ai_duel_requested.disconnect(ai_duel)
	NetBusExt.royale_start_ai_requested.disconnect(royale_start_ai)

func on_lobby_name(caller: int, name: String) -> void:
	_peer_names[caller] = name if not name.is_empty() else "Anon"

# 刷新房间列表:回当前所有非空房间(号码 + 人数 + 在房玩家昵称;人数≥2 为已满,客户端据此禁用/排序)。
func on_list_rooms(caller: int) -> void:
	var arr: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if room.players.is_empty():
			continue
		var names: Array = []
		for peer_id in room.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": room.players.size(), "names": names})
	NetBus.rpc_id(caller, "room_list", arr)

func _generate_code() -> String:
	return "%04d" % (randi() % 10000)

func create_room(caller: int) -> void:
	# 1v1/大乱斗互斥(自检 L5):同一客户端同时挂两种房会收到双重 go_match 互相覆盖
	if _royale_room_of(caller) != null:
		NetBus.rpc_id(caller, "server_message", "你已在大乱斗房间,请先退出再创建 1v1 房间")
		return
	var code := _generate_code()
	while rooms.has(code):
		code = _generate_code()
	var room := Room.new()
	room.code = code
	room.players.append(caller)
	room.player_role[caller] = 1
	room.created_at = Time.get_unix_time_from_system()
	rooms[code] = room
	print("房间 %s 创建(房主 peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_created", code)

func join_room(caller: int, code: String) -> void:
	if not rooms.has(code):
		NetBus.rpc_id(caller, "server_message", "房间不存在")
		return
	var room: Room = rooms[code]
	if room.started:
		# 已开局(worker 已拉起):双方已转连对局,列表残留期间拒绝第三人误入
		NetBus.rpc_id(caller, "server_message", "房间已满")
		return
	if room.players.size() >= 2:
		NetBus.rpc_id(caller, "server_message", "房间已满")
		return
	if _royale_room_of(caller) != null:
		NetBus.rpc_id(caller, "server_message", "你已在大乱斗房间,请先退出再加入 1v1 房间")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	print("房间 %s 加入(peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_joined", 2)
	_start_match(room)

func on_peer_left(peer_id: int) -> void:
	_peer_names.erase(peer_id)
	for code in rooms.keys():
		var room: Room = rooms[code]
		if not room.players.has(peer_id):
			continue
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
		# 关房条件:空房,或已开局(worker 已拉起)后任一方掉线。
		# 开局后双方会相继转连 worker 断开大厅;若只走掉一方(如房主在配对瞬间掉线),
		# 旧逻辑会留下 1/2 幽灵房:对局实际已死,房却常驻列表可被反复加入、重复拉起 worker。
		# 改为:started 房一方掉线即整房作废,防幽灵房/连环僵尸 worker。
		if room.players.is_empty() or room.started:
			# 开局后仍留在房内的一方(还没收到 go_match/还没转连):告知并放走,别让它干等
			if not room.players.is_empty():
				for survivor in room.players:
					NetBus.rpc_id(survivor, "server_message", "配对已取消(对手离开),请刷新列表")
			_release_port_later(room.worker_port)   # 延迟归还(见 WORKER_PORT_REUSE_DELAY 注释)
			rooms.erase(code)
			print("房间 %s 关闭(端口 %d 将于 %ds 后回收)" % [code, room.worker_port, int(WORKER_PORT_REUSE_DELAY)])
	# 大乱斗房:掉线即离房(空房关闭;房主掉线转移;开局后成员转连 worker 断开大厅属正常流转)
	for rcode in royale_rooms.keys():
		var rr: RoyaleRoom = royale_rooms[rcode]
		if not rr.players.has(peer_id):
			continue
		rr.players.erase(peer_id)
		rr.player_role.erase(peer_id)
		if rr.players.is_empty():
			royale_rooms.erase(rcode)
			if rr.worker_port > 0:
				# 大乱斗一局最长 5 分钟:端口回收延迟远长于 1v1(自检 M2)
				_release_port_later(rr.worker_port, ROYALE_PORT_REUSE_DELAY)
			print("大乱斗房 %s 关闭(端口 %d 将于 %ds 后回收)" % [rcode, rr.worker_port, int(ROYALE_PORT_REUSE_DELAY)])
		else:
			if rr.host_peer == peer_id:
				rr.host_peer = rr.players[0]
				print("大乱斗房 %s 房主转移 → peer %d" % [rcode, rr.host_peer])
			_broadcast_royale_state(rr)


# ── 大乱斗房间:建房/加入(邀请码)/离开/列表/房主开局 ──

# 房内全员广播实时状态(等待室 UI 刷新)
func _broadcast_royale_state(rr: RoyaleRoom) -> void:
	var plist: Array = []
	for peer_id in rr.players:
		plist.append({"role": rr.player_role[peer_id], "name": _peer_names.get(peer_id, "玩家")})
	var state := {
		"code": rr.code, "is_public": rr.is_public, "invite_code": rr.invite_code,
		"max_players": rr.max_players, "host_role": rr.player_role.get(rr.host_peer, 0),
		"players": plist, "in_match": rr.in_match,
	}
	var live_peers := multiplayer.get_peers()
	for peer_id in rr.players:
		# 只发给仍在线的 peer:对已断开连接 rpc_id 会报 channel 错误(自检日志实测)
		if live_peers.has(peer_id):
			NetBusExt.rpc_id(peer_id, "royale_room_state", state)

func _royale_room_of(caller: int) -> RoyaleRoom:
	for r in royale_rooms:
		if (royale_rooms[r] as RoyaleRoom).players.has(caller):
			return royale_rooms[r]
	return null

# 该 caller 是否已在某个 1v1 房间(大乱斗/1v1 互斥,自检 L5)
func _in_1v1_room(caller: int) -> bool:
	for code in rooms:
		if (rooms[code] as Room).players.has(caller):
			return true
	return false

func royale_create(caller: int, opts: Dictionary) -> void:
	if _royale_room_of(caller) != null:
		NetBus.rpc_id(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.rpc_id(caller, "server_message", "你已在 1v1 房间,请先退出再创建大乱斗房间")
		return
	var code := _generate_code()
	while royale_rooms.has(code):
		code = _generate_code()
	var rr := RoyaleRoom.new()
	rr.code = code
	rr.host_peer = caller
	rr.players.append(caller)
	rr.player_role[caller] = 1
	rr.created_at = Time.get_unix_time_from_system()
	rr.is_public = bool(opts.get("is_public", true))
	rr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not rr.is_public and rr.invite_code.is_empty():
		rr.invite_code = _generate_code()   # 私密未填码 → 自动生成
	var n := int(opts.get("max_players", ROYALE_DEFAULT_MAX))
	rr.max_players = clampi(n, ROYALE_MIN_PLAYERS, ROYALE_MAX_PLAYERS)
	rr.options = {
		"round_full_heal": bool(opts.get("round_full_heal", false)),
		"disabled_weapons": opts.get("disabled_weapons", []),
	}
	royale_rooms[code] = rr
	print("大乱斗房 %s 创建(房主 peer=%d,%s,上限 %d)" % [code, caller,
			"公开" if rr.is_public else "私密", rr.max_players])
	_broadcast_royale_state(rr)

func royale_join(caller: int, code: String, invite: String) -> void:
	if not royale_rooms.has(code):
		NetBus.rpc_id(caller, "server_message", "房间不存在")
		return
	if _royale_room_of(caller) != null:
		NetBus.rpc_id(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.rpc_id(caller, "server_message", "你已在 1v1 房间,请先退出再加入大乱斗房间")
		return
	var rr: RoyaleRoom = royale_rooms[code]
	if rr.in_match:
		NetBus.rpc_id(caller, "server_message", "对局已开始")
		return
	if rr.players.size() >= rr.max_players:
		NetBus.rpc_id(caller, "server_message", "房间已满")
		return
	if not rr.is_public and invite.strip_edges() != rr.invite_code:
		NetBus.rpc_id(caller, "server_message", "邀请码错误")
		return
	var role := 1
	while rr.player_role.values().has(role):
		role += 1
	rr.players.append(caller)
	rr.player_role[caller] = role
	print("大乱斗房 %s 加入(peer=%d,role=%d,%d/%d)" % [code, caller, role,
			rr.players.size(), rr.max_players])
	_broadcast_royale_state(rr)

func royale_leave(caller: int) -> void:
	var rr := _royale_room_of(caller)
	if rr == null:
		return
	rr.players.erase(caller)
	rr.player_role.erase(caller)
	if rr.players.is_empty():
		# 「退出房间」按钮走的是这条路径(它**不断开大厅 peer** → on_peer_left 不会为它触发);
		# 房间随即从 royale_rooms 摘除,而 _sweep_stale_rooms / on_peer_left 都只遍历
		# royale_rooms → 之后**再无任何路径**能归还本房端口。开局过的房会把端口永久占死
		# (500 个耗尽后 _pick_worker_port 恒 -1,大厅彻底拉不起 worker)。
		# 故与其他大乱斗拆除路径同法归还,并同样走大乱斗那条更长的复用延迟
		# (一局进行中,旧 worker 还在跑,见 ROYALE_PORT_REUSE_DELAY)。
		if rr.worker_port > 0:
			_release_port_later(rr.worker_port, ROYALE_PORT_REUSE_DELAY)
		royale_rooms.erase(rr.code)
		print("大乱斗房 %s 关闭(房主离开;端口 %d 将于 %ds 后回收)" % [rr.code, rr.worker_port,
				int(ROYALE_PORT_REUSE_DELAY)])
	else:
		if rr.host_peer == caller:
			rr.host_peer = rr.players[0]
		_broadcast_royale_state(rr)

# 公开房间列表(只列未开局的;[{code, players, max_players, names}])
func royale_list(caller: int) -> void:
	var arr: Array = []
	for code in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[code]
		if rr.in_match or not rr.is_public or rr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in rr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names})
	NetBusExt.rpc_id(caller, "royale_rooms", arr)

# 房主开局:满 2 人即可;拉起 N 人 worker → 全员 go_match 转连
func royale_start(caller: int) -> void:
	var rr := _royale_room_of(caller)
	if rr == null:
		return
	if rr.host_peer != caller:
		NetBus.rpc_id(caller, "server_message", "只有房主能开始游戏")
		return
	if rr.in_match:
		return   # 已开局(重复请求防重入:不会双开 worker)
	if rr.players.size() < ROYALE_MIN_PLAYERS:
		NetBus.rpc_id(caller, "server_message", "至少 %d 人才能开始" % ROYALE_MIN_PLAYERS)
		return
	var port := _pick_worker_port()
	if port < 0:
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
	if not _spawn_royale_worker(port, rr.players.size(), _royale_role_bound(rr)):
		rr.in_match = false
		_worker_ports.erase(port)
		NetBus.rpc_id(caller, "server_message", "无法启动对局")
		return
	# 房主对局选项经 worker 侧 NetBusExt.player_options 以 role1 报到为准;这里随开局存档不打扰
	print("大乱斗房 %s 开局(%d 人,role 上界 %d)→ worker 端口 %d" % [rr.code, rr.players.size(),
			_royale_role_bound(rr), port])
	# 稍等 worker 完成 bind,再全员转连
	await get_tree().create_timer(0.3).timeout
	for peer_id in rr.players:
		NetBus.rpc_id(peer_id, "go_match", rr.player_role[peer_id], port)

# ── AI 补位对战(实验性):1v1 房主可请求与 AI 对战;大乱斗房主可 AI 补位开局 ──

# 1v1:房主请求 AI 对战 → 单人 go_match,role2 由服务端 AI 驱动
func ai_duel(caller: int) -> void:
	var host_room: Room = null
	for code in rooms:
		var room: Room = rooms[code]
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
	var port := _pick_worker_port()
	if port < 0:
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
		return
	host_room.worker_port = port
	if not _spawn_worker(port, [2]):
		_worker_ports.erase(port)
		NetBus.rpc_id(caller, "server_message", "无法启动对局")
		return
	# L5 合并补丁(刻意偏离移植来源,非误改):下一行把房间从 rooms 摘除后,on_peer_left
	# 与 _sweep_stale_rooms 都只遍历 rooms,再无任何路径能归还本端口 —— 不在此处释放就会
	# 永久占用(500 次后 _pick_worker_port 返回 -1,大厅彻底拉不起 worker)。
	# _release_port_later 是协程(内含 await),fire-and-forget 不 await(与 on_peer_left 同法)。
	_release_port_later(port)
	rooms.erase(host_room.code)   # 对局消费掉房间(AI 不占第二人位)
	print("房间 %s → AI 对战开局(1 人 + AI)→ worker 端口 %d" % [host_room.code, port])
	await get_tree().create_timer(0.3).timeout
	NetBus.rpc_id(caller, "go_match", 1, port)

# 大乱斗:房主 AI 补位开局 → 现有真人 + AI 补到 max_players
func royale_start_ai(caller: int) -> void:
	var rr := _royale_room_of(caller)
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
	var port := _pick_worker_port()
	if port < 0:
		NetBus.rpc_id(caller, "server_message", "无法分配对局端口")
		return
	rr.worker_port = port
	rr.in_match = true
	# AI role 号 = 1..max_players 内**人类未占用**的空闲号(见 _royale_free_roles)
	var ai_roles := _royale_free_roles(rr, ai_count)
	if not _spawn_royale_worker(port, rr.max_players, _royale_role_bound(rr, ai_roles), ai_roles):
		rr.in_match = false
		_worker_ports.erase(port)
		NetBus.rpc_id(caller, "server_message", "无法启动对局")
		return
	print("大乱斗房 %s AI 补位开局(%d 真人 + %d AI)→ worker 端口 %d" % [rr.code, rr.players.size(), ai_count, port])
	await get_tree().create_timer(0.3).timeout
	for peer_id in rr.players:
		NetBus.rpc_id(peer_id, "go_match", rr.player_role[peer_id], port)

# 大乱斗 worker 的**角色号上界**(worker 拿它判 claim 合法性,见 server_main._on_role_claimed)。
# 刻意与「成员数」分开:role 由 royale_join 的「最小空闲号」分配,有人退出后不重排,
# 编号会留空洞(如 3 人房里中间那位退出 → 房里是 {1,3},成员数 2 < 最高 role 3)。
# 此时若把成员数当上界,worker 会把**手持 3 号的真客户端**当串线踢掉 → 只剩 1 个 claim,
# worker 的超时梯走完退出,两名客户端卡在「连接对局服务器超时」且无恢复路径(自检 B1)。
# 上界取实际已分配的最高 role,既不漏放任何真客户端,又不比成员数宽松多少
# (空洞多大就宽松多少),串线防线基本不变。
func _royale_role_bound(rr: RoyaleRoom, ai_roles: Array = []) -> int:
	var bound := 0
	for r in rr.player_role.values():
		bound = maxi(bound, int(r))
	for r in ai_roles:
		bound = maxi(bound, int(r))
	return bound

# AI 补位用的 role 号:取 1..max_players 内**人类未占用**的最小空闲号。
# 不能用「成员数 + 1 + i」——那是「编号恒连续」的假设;有人退出留空洞时(如真人 {1,3}),
# 按人数推出来的 AI 号会撞上仍在房里的高号真人(3 号既是真人又是 AI)→ 同 role 双份玩家、
# 且 worker 侧的「人类 claim 数」算术跟着失真(自检 B1)。
func _royale_free_roles(rr: RoyaleRoom, count: int) -> Array:
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

# 拉起 N 人大乱斗 worker(--royale --players N --max-role R;其余同 _spawn_worker)
# players=**预期报到总人数**(含 AI:worker 拿它做收齐判据与 AI 数减法),
# max_role=**role 号上界**(worker 拿它判 claim 合法性;两者语义不同,勿合并,见 _royale_role_bound)。
func _spawn_royale_worker(port: int, players: int, max_role: int, ai_roles: Array = []) -> bool:
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	# editor 与 template_debug(调试引擎)都要带 --path+场景;仅导出 exe 可省(dedicated_server 主场景)
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--royale",
				"--port", str(port), "--players", str(players), "--max-role", str(max_role)])
	else:
		args = PackedStringArray(["--headless", "--", "--worker", "--royale",
				"--port", str(port), "--players", str(players), "--max-role", str(max_role)])
	if not ai_roles.is_empty():
		var roles := []
		for r in ai_roles:
			roles.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(roles))
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn royale worker pid=%d port=%d players=%d max_role=%d ai=%s" % [pid, port,
			players, max_role, str(ai_roles)])
	return pid > 0

# ── 配对完成 → 拉起对局 worker 并让两端转连 ──
func _start_match(room: Room) -> void:
	# 先置 started:配对瞬间任何一方掉线都走 on_peer_left 的「started 即关房」分支,
	# 不会留下 1/2 幽灵房;同时也挡住第三人在这 0.3s 窗口误入重复拉起 worker。
	room.started = true
	var port := _pick_worker_port()
	if port < 0:
		# 起不来局:房间作废,通知双方(不再滞留)
		NetBus.rpc_id(room.players[0], "server_message", "无法分配对局端口")
		for peer_id in room.players:
			NetBus.rpc_id(peer_id, "server_message", "配对失败,房间已关闭——请重新建房/加入")
		room.worker_port = 0
		rooms.erase(room.code)
		return
	room.worker_port = port
	if not _spawn_worker(port):
		_worker_ports.erase(port)
		NetBus.rpc_id(room.players[0], "server_message", "无法启动对局")
		for peer_id in room.players:
			NetBus.rpc_id(peer_id, "server_message", "配对失败,房间已关闭——请重新建房/加入")
		room.worker_port = 0
		rooms.erase(room.code)
		return
	# 稍等 worker 完成 bind,再通知两端转连(worker 很快,300ms 足够)
	await get_tree().create_timer(0.3).timeout
	if not rooms.has(room.code):   # 0.3s 内已有玩家掉线触发关房 → 别再给幽灵房发 go_match
		return
	for peer_id in room.players:
		NetBus.rpc_id(peer_id, "go_match", room.player_role[peer_id], port)
	print("房间 %s 配对完成 → worker 端口 %d" % [room.code, port])

# 延迟归还 worker 端口:给旧 worker 留足退出时间,防止端口被立刻复用导致串线。
# delay:1v1=30s;大乱斗房传 ROYALE_PORT_REUSE_DELAY(一局可长达 5 分钟)。
func _release_port_later(port: int, delay: float = WORKER_PORT_REUSE_DELAY) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(delay).timeout
	_worker_ports.erase(port)


# 分配一个当前未占用的 worker 端口(唯一递增 + 占用集合;见类头注释,勿用 bind 探测)。
func _pick_worker_port() -> int:
	for _tries in range(WORKER_PORT_SPAN):
		var p := _next_port
		_next_port += 1
		if _next_port >= WORKER_PORT_BASE + WORKER_PORT_SPAN:
			_next_port = WORKER_PORT_BASE
		if not _worker_ports.has(p):
			_worker_ports[p] = true
			return p
	return -1

# 拉起 headless worker 子进程(同一可执行文件 + --worker)。editor(开发)要带 --path 与场景;
# 导出的专用服务端 exe(disable_path_overrides)靠 main_scene.dedicated_server 起 server_main。
# ai_roles 非空 → 透传 --ai-roles(worker 侧这些 role 由服务端 AI 驱动,不等 claim)。
func _spawn_worker(port: int, ai_roles: Array = []) -> bool:
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--port", str(port)])
	else:
		args = PackedStringArray(["--headless", "--", "--worker", "--port", str(port)])
	if not ai_roles.is_empty():
		var roles := []
		for r in ai_roles:
			roles.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(roles))
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn worker pid=%d port=%d editor=%s ai=%s" % [pid, port, str(OS.has_feature("editor")), str(ai_roles)])
	return pid > 0

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
# (WORKER_PORT_SPAN=500 耗尽后 _pick_worker_port 恒 -1,大厅彻底拉不起 worker)。
# 故两表共用同一 MAX_ROOM_AGE 一并清扫。不跳过 in_match 房:大乱斗单局上限
# RoyaleHost.MATCH_TIME 远短于 2h,仍在表内且超龄者必是 worker 早已结束的残留;
# 在局中的房另加「一整个扫描周期 + 一局时长」的宽限,理由见下方 royale 分支。
func _sweep_stale_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var stale: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if now - room.created_at > MAX_ROOM_AGE:
			stale.append(room)
	var stale_royale: Array = []
	for rcode in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[rcode]
		# 刻意偏离移植来源(非误改):在局中的大乱斗房宽限 = SWEEP_INTERVAL + RoyaleHost.MATCH_TIME
		# (即「一整个扫描周期」+「一局时长」),这个界是**可证安全**的,而非经验值。
		# 房龄从**建房**起算,含此前在大厅等待的全部时间——一个等满 2h 才开局的房,在开局那一刻
		# 就已"超龄";而清扫由 _process 的 SWEEP_INTERVAL 计时器驱动(不是每帧),房间可能已经比
		# 阈值老上**整整一个扫描周期**才等到判它超龄的那次 tick,即最迟可在房龄 MAX_ROOM_AGE +
		# SWEEP_INTERVAL 时开局。从 royale_start/royale_start_ai 拉起 worker 到成员转连离厅还有
		# 0.3~1.5s 的窗口,若宽限只有一局时长,紧随其后的那次 tick 仍会杀掉一个刚起几秒的 worker
		# 并踢掉正在转连的成员(边界竞态只是被推窄,没被关闭)。宽限覆盖「阈值 + 整个扫描周期 +
		# 一局」后,等待期攒下的那一整个周期与整局对局都落在界内,任何一次 tick 都不可能扫到在局房。
		# 泄漏仍被限住:至多多留一个扫描周期 + 一局。
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
	for room in stale:
		if room.worker_port > 0:
			_kill_worker(room.worker_port)
			_worker_ports.erase(room.worker_port)
		# 通知并断开仍连着的房内玩家(触发 peer_left → on_peer_left 会再清一次,无害)
		for peer_id in room.players:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				NetBus.rpc_id(peer_id, "server_message", "房间超时(>2h),已关闭")
		rooms.erase(room.code)
		print("房间 %s 超时清理(存活 %.0f 秒)" % [room.code, now - room.created_at])
	# 大乱斗房收尾:字段与 Room 同形(worker_port/players/code);worker 已被杀,端口直接回收
	# (与 1v1 分支同法,不经 ROYALE_PORT_REUSE_DELAY——那条延迟是给「没被杀、还在跑」的 worker 的)
	for rr in stale_royale:
		if rr.worker_port > 0:
			_kill_worker(rr.worker_port)
			_worker_ports.erase(rr.worker_port)
		for peer_id in rr.players:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				NetBus.rpc_id(peer_id, "server_message", "房间超时(>2h),已关闭")
		royale_rooms.erase(rr.code)
		print("大乱斗房 %s 超时清理(存活 %.0f 秒)" % [rr.code, now - rr.created_at])
	# 立即断开被清理房间的玩家(等 peer_left 收尾;避免它们还留在半满房间表里)
	for room in stale + stale_royale:
		for peer_id in room.players:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)

# 杀指定 UDP 端口的进程(worker)。Windows:PowerShell 取该端口属主进程 → Stop-Process。
# 与 server_main._kill_port_holder 同法;不能只靠 OS.create_process 返回的 pid(跨进程需查端口)。
func _kill_worker(port: int) -> void:
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)

# ── 建局(在 worker 进程调用):重算世界尺寸 + 给两端发 match_start + 建权威 MatchHost ──
# 与旧 lobby._start_match 同逻辑,只是脱离大厅进程/房间状态;role_peers = {role: peer_id};
# options = 房主(role1)的对局选项(禁武器/回合回血等,见 MatchHost)。
# ai_roles = AI 补位 role 列表(实验性):这些 role 由服务端 AI 驱动,不发 match_start。
static func start_match_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	for role in role_peers:
		var peer_id: int = role_peers[role]
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles)
	return host
