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
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口

class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> 1/2
	var match_host: Node = null           # 保留字段:worker 模式下大厅恒为 null
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)

var rooms: Dictionary = {}   # code -> Room
var _peer_names: Dictionary = {}   # peer id -> 昵称(客户端连上大厅时上报,列表/建房展示)

# ── 僵尸房间定时清理:每 SWEEP_INTERVAL 秒扫一次,存在超 MAX_ROOM_AGE 的房间连 worker 一起杀 ──
const SWEEP_INTERVAL := 600.0       # 清理扫描周期(秒=10min)
const MAX_ROOM_AGE := 7200.0        # 房间允许存在上限(秒=2h)
var _sweep_acc := 0.0

func _enter_tree() -> void:
	NetBus.room_create_requested.connect(create_room)
	NetBus.room_join_requested.connect(join_room)
	NetBus.room_list_requested.connect(on_list_rooms)
	NetBus.lobby_name_set.connect(on_lobby_name)
	NetBus.peer_left.connect(on_peer_left)

func _exit_tree() -> void:
	NetBus.room_create_requested.disconnect(create_room)
	NetBus.room_join_requested.disconnect(join_room)
	NetBus.room_list_requested.disconnect(on_list_rooms)
	NetBus.lobby_name_set.disconnect(on_lobby_name)
	NetBus.peer_left.disconnect(on_peer_left)

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
	room.created_at = Time.get_unix_time_from_system()
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
			_worker_ports.erase(room.worker_port)   # 关房归还端口
			rooms.erase(code)
			print("房间 %s 关闭" % code)

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

# ── 定时扫描:每 SWEEP_INTERVAL 清理存在超 MAX_ROOM_AGE 的僵尸房间(连 worker 一起杀)──
func _process(delta: float) -> void:
	_sweep_acc += delta
	if _sweep_acc >= SWEEP_INTERVAL:
		_sweep_acc = 0.0
		_sweep_stale_rooms()

# 清理:房间从创建起超 MAX_ROOM_AGE 秒 → 杀其 worker(若有)→ 踢房内玩家 → 删房归还端口。
func _sweep_stale_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var stale: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if now - room.created_at > MAX_ROOM_AGE:
			stale.append(room)
	if stale.is_empty():
		return
	print("[lobby] 清理 %d 个超龄房间(>%.0f 秒)" % [stale.size(), MAX_ROOM_AGE])
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
	# 立即断开被清理房间的玩家(等 peer_left 收尾;避免它们还留在半满房间表里)
	for room in stale:
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
# 与旧 lobby._start_match 同逻辑,只是脱离大厅进程/房间状态;role_peers = {role: peer_id}。
static func start_match_on(role_peers: Dictionary, map_path: String = PVP_MAP) -> Node:
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
	var host := MatchHost.new(map_path, role_peers)
	return host
