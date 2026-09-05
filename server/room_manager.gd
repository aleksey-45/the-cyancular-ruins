class_name RoomManager
extends Node

# 房间注册表(大厅进程,端口 7777):房间号 → 玩家;2 人就绪配对。
# 不再在大厅进程建 MatchHost——配对完成后为每局拉起一个独立 headless worker 子进程
# (独占一个 UDP 端口),对局全程在 worker 内运行 → 各局内存天然隔离,共享全局(current_grid/
# TileDefs)不会跨局互踩。worker 由 NetBus 转交信号驱动,不硬依赖 RoomManager 类型。

# PvP 固定竞技场地图(1v1,含 # player / # player2 出生点)。
const PVP_MAP := "res://map/factory1v1.cyrm"
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
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口

class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> 1/2
	var match_host: Node = null           # 保留字段:worker 模式下大厅恒为 null
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)

var rooms: Dictionary = {}   # code -> Room
var _peer_names: Dictionary = {}   # peer id -> 昵称(客户端连上大厅时上报,列表/建房展示)

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
	var code := _generate_code()
	while rooms.has(code):
		code = _generate_code()
	var room := Room.new()
	room.code = code
	room.players.append(caller)
	room.player_role[caller] = 1
	rooms[code] = room
	print("房间 %s 创建(房主 peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_created", code)

func join_room(caller: int, code: String) -> void:
	if not rooms.has(code):
		NetBus.rpc_id(caller, "server_message", "房间不存在")
		return
	var room: Room = rooms[code]
	if room.players.size() >= 2:
		NetBus.rpc_id(caller, "server_message", "房间已满")
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
		# worker 模式下大厅无对局;玩家转连 worker 后的断开只是清房间。
		# 若某方在配对前掉线 → 房间不满、等另一方(或一直空着由时间清理)。
		if room.players.is_empty():
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
				_release_port_later(rr.worker_port)
			print("大乱斗房 %s 关闭" % rcode)
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
	for peer_id in rr.players:
		NetBusExt.rpc_id(peer_id, "royale_room_state", state)

func _royale_room_of(caller: int) -> RoyaleRoom:
	for r in royale_rooms:
		if (royale_rooms[r] as RoyaleRoom).players.has(caller):
			return royale_rooms[r]
	return null

func royale_create(caller: int, opts: Dictionary) -> void:
	if _royale_room_of(caller) != null:
		NetBus.rpc_id(caller, "server_message", "你已在大乱斗房间中")
		return
	var code := _generate_code()
	while royale_rooms.has(code):
		code = _generate_code()
	var rr := RoyaleRoom.new()
	rr.code = code
	rr.host_peer = caller
	rr.players.append(caller)
	rr.player_role[caller] = 1
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
		royale_rooms.erase(rr.code)
		print("大乱斗房 %s 关闭(房主离开)" % rr.code)
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
	if not _spawn_royale_worker(port, rr.players.size()):
		rr.in_match = false
		_worker_ports.erase(port)
		NetBus.rpc_id(caller, "server_message", "无法启动对局")
		return
	# 房主对局选项经 worker 侧 NetBusExt.player_options 以 role1 报到为准;这里随开局存档不打扰
	print("大乱斗房 %s 开局(%d 人)→ worker 端口 %d" % [rr.code, rr.players.size(), port])
	# 稍等 worker 完成 bind,再全员转连
	await get_tree().create_timer(0.3).timeout
	for peer_id in rr.players:
		NetBus.rpc_id(peer_id, "go_match", rr.player_role[peer_id], port)

# 拉起 N 人大乱斗 worker(--royale --players N;其余同 _spawn_worker)
func _spawn_royale_worker(port: int, players: int) -> bool:
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor"):
		args = PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--royale",
				"--port", str(port), "--players", str(players)])
	else:
		args = PackedStringArray(["--headless", "--", "--worker", "--royale",
				"--port", str(port), "--players", str(players)])
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn royale worker pid=%d port=%d players=%d" % [pid, port, players])
	return pid > 0

# ── 配对完成 → 拉起对局 worker 并让两端转连 ──
func _start_match(room: Room) -> void:
	var port := _pick_worker_port()
	if port < 0:
		NetBus.rpc_id(room.players[0], "server_message", "无法分配对局端口")
		return
	room.worker_port = port
	if not _spawn_worker(port):
		_worker_ports.erase(port)
		NetBus.rpc_id(room.players[0], "server_message", "无法启动对局")
		return
	# 稍等 worker 完成 bind,再通知两端转连(worker 很快,300ms 足够)
	await get_tree().create_timer(0.3).timeout
	for peer_id in room.players:
		NetBus.rpc_id(peer_id, "go_match", room.player_role[peer_id], port)
	print("房间 %s 配对完成 → worker 端口 %d" % [room.code, port])

# 延迟归还 worker 端口:给旧 worker 留足退出时间,防止端口被立刻复用导致串线。
func _release_port_later(port: int) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(WORKER_PORT_REUSE_DELAY).timeout
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
func _spawn_worker(port: int) -> bool:
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor"):
		args = PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--port", str(port)])
	else:
		args = PackedStringArray(["--headless", "--", "--worker", "--port", str(port)])
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn worker pid=%d port=%d editor=%s" % [pid, port, str(OS.has_feature("editor"))])
	return pid > 0

# ── 建局(在 worker 进程调用):重算世界尺寸 + 给两端发 match_start + 建权威 MatchHost ──
# 与旧 lobby._start_match 同逻辑,只是脱离大厅进程/房间状态;role_peers = {role: peer_id};
# options = 房主(role1)的对局选项(禁武器/回合回血等,见 MatchHost)。
static func start_match_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}) -> Node:
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
	var host := MatchHost.new(map_path, role_peers, options)
	return host
