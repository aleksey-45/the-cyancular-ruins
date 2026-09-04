extends Node
# 网络总线(autoload,PvP 唯一网络收口):服务器与客户端共用同一节点路径 /root/NetBus,
# RPC 才能跨场景路由(autoload 常驻,不随场景切换销毁)。方法按"调用方"区分两端。
# 服务器侧经转交信号把建房/加入/断线交给 RoomManager(不硬依赖其类型,任务可独立编译)。

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

# 服务器端 → RoomManager 的转交信号
signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal peer_left(peer_id: int)
# 服务器端 → MatchHost 的输入包
signal input_received(caller: int, pkt: Dictionary)
# worker:客户端连上后 claim_role 转交(caller=peer id, role=客户端在大厅领的角色, player_name=昵称)
signal role_claimed(caller: int, role: int, player_name: String)
# 服务器 → 客户端
signal local_snapshot(snap: Dictionary)
signal local_bullet_spawn(data: Dictionary)
signal local_go_match(role: int, port: int)   # 大厅配对完:客户端去连对局 worker(role/port 由此给)
signal local_peer_info(names: Dictionary)     # worker 开局:双方昵称 {role(int) -> name}(头上显示)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
signal local_bullet_hit(victim_role: int, shooter_role: int, bid: int, hit_pos: Vector2)  # 命中即移除子弹视觉
signal local_tile_destroyed(cell: Vector2i)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_opponent_left          # 对局中途对手断线(服务器 → 存活方,播报后回菜单)
signal ping_updated(ms: int)        # 平滑后延迟 ms
signal local_enemy_spawn(roster: Array)  # 服务器:本局鸟清单 [{id,scene,pos}],客户端建副本
signal local_enemy_died(id: int)         # 服务器:某只鸟死亡(id),客户端移除副本

const DEFAULT_PORT := 7777

var is_server_mode: bool = false

var ping_ms := 0        # 平滑后 RTT(ms),0=尚未采样
var _ping_sent_ms := 0

func _ready() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: print("NetBus: 玩家连入 peer=%d" % id))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func() -> void: print("NetBus: 已连接服务器"))
	multiplayer.connection_failed.connect(func() -> void: local_server_message.emit("连接失败"))
	multiplayer.server_disconnected.connect(func() -> void: local_server_message.emit("服务器断开"))

func _on_peer_disconnected(id: int) -> void:
	print("NetBus: 玩家断开 peer=%d" % id)
	peer_left.emit(id)

func start_server(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 16)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = true
	return err

func start_client(addr: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = false
	return err

func stop() -> void:
	multiplayer.multiplayer_peer = null
	is_server_mode = false

# ── 客户端 → 服务器 ──
@rpc("any_peer", "reliable")
func create_room() -> void:
	room_create_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "reliable")
func join_room(code: String) -> void:
	room_join_requested.emit(multiplayer.get_remote_sender_id(), code)

@rpc("any_peer", "reliable")
func send_input(pkt: Dictionary) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)

# 客户端→worker:报到自己在对局里的角色+昵称(role 大厅已发;player_name 用于对方头上显示)。
# worker 据此建 role→peer 映射,并在两人到齐后把双方昵称回传给各端(peer_info)。
@rpc("any_peer", "reliable")
func claim_role(role: int, player_name: String) -> void:
	role_claimed.emit(multiplayer.get_remote_sender_id(), role, player_name)

# ── 服务器 → 客户端(权威方=peer1 可调)──
@rpc("authority", "unreliable")
func snapshot(snap: Dictionary) -> void:
	local_snapshot.emit(snap)

@rpc("authority", "reliable")
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

@rpc("authority", "reliable")
func hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	local_hit_event.emit(victim_role, damage, source_pos)

# 服务器判定某发子弹命中对手 → 广播:中弹端按 bid 移除对应视觉弹,射手端移除最接近命中的本地弹。
# (配合 PvP 取消无敌帧:每发结算一次、命中即消失,不会穿透连打/不会帧伤)
@rpc("authority", "reliable")
func bullet_hit(victim_role: int, shooter_role: int, bid: int, hit_pos: Vector2) -> void:
	local_bullet_hit.emit(victim_role, shooter_role, bid, hit_pos)

@rpc("authority", "reliable")
func tile_destroyed(cell: Vector2i) -> void:
	local_tile_destroyed.emit(cell)

@rpc("authority", "reliable")
func round_state(data: Dictionary) -> void:
	local_round_state.emit(data)

@rpc("authority", "reliable")
func kill_event(killer: int, victim: int) -> void:
	local_kill_event.emit(killer, victim)

@rpc("authority", "reliable")
func enemy_spawn(roster: Array) -> void:
	local_enemy_spawn.emit(roster)

@rpc("authority", "reliable")
func enemy_died(id: int) -> void:
	local_enemy_died.emit(id)

@rpc("authority", "reliable")
func room_created(code: String) -> void:
	local_room_created.emit(code)

@rpc("authority", "reliable")
func room_joined(role: int) -> void:
	local_room_joined.emit(role)

@rpc("authority", "reliable")
func match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	local_match_start.emit(role, spawn, map_path)

# 大厅→客户端:配对完成,去连对局 worker(role 由大厅定;端口是 worker 独占的 UDP 端口)。
@rpc("authority", "reliable")
func go_match(role: int, port: int) -> void:
	local_go_match.emit(role, port)

# worker→客户端:开局广播双方昵称(role -> name),两端据此在头上显示各自 ID。
@rpc("authority", "reliable")
func peer_info(names: Dictionary) -> void:
	local_peer_info.emit(names)

@rpc("authority", "reliable")
func server_message(text: String) -> void:
	local_server_message.emit(text)

# ── 延迟测量:客户端周期 ping → 服务器原样回 pong → 客户端算 RTT(EWMA 平滑)──
func send_ping() -> void:
	_ping_sent_ms = Time.get_ticks_msec()
	rpc_id(1, "ping")

@rpc("any_peer", "reliable")
func ping() -> void:
	rpc_id(multiplayer.get_remote_sender_id(), "pong")

@rpc("authority", "reliable")
func pong() -> void:
	var ms := Time.get_ticks_msec() - _ping_sent_ms
	if ms < 0:
		return
	ping_ms = ms if ping_ms == 0 else int(round(ping_ms * 0.6 + ms * 0.4))
	ping_updated.emit(ping_ms)

# 对局中途对手断线(1v1 无法继续 → 存活方播报后回菜单)
@rpc("authority", "reliable")
func opponent_left() -> void:
	local_opponent_left.emit()
