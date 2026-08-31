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
# 服务器 → 客户端
signal local_snapshot(snap: Dictionary)
signal local_bullet_spawn(data: Dictionary)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)

const DEFAULT_PORT := 7777

var is_server_mode: bool = false

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

@rpc("authority", "reliable")
func room_created(code: String) -> void:
	local_room_created.emit(code)

@rpc("authority", "reliable")
func room_joined(role: int) -> void:
	local_room_joined.emit(role)

@rpc("authority", "reliable")
func match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	local_match_start.emit(role, spawn, map_path)

@rpc("authority", "reliable")
func server_message(text: String) -> void:
	local_server_message.emit(text)
