extends Node

# 网络总线服务（全局单例节点，PvP 网络通信的核心入口）。
# 客户端与服务端共用 /root/NetBus 路径，提供跨场景 RPC 路由与基础通信信道。
# 服务端通过本地信号将建房、加入与断线事件派发给 RoomManager，输入数据与对局事件派发给 MatchHost。

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_room_list(rooms: Array)
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

# 服务端转交信号：
signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal room_list_requested(caller: int)
signal lobby_name_set(caller: int, name: String)
signal peer_left(peer_id: int)
signal input_received(caller: int, pkt: Dictionary)
signal role_claimed(caller: int, role: int, player_name: String)

# 服务端到客户端广播信号：
signal local_snapshot_world(world: Dictionary)   # 全体玩家基础渲染属性（用于镜像平滑与血条展示）
signal local_snapshot_own(own: Dictionary)       # 本地玩家专属的确认序列号与权威物理状态
signal local_bullet_spawn(data: Dictionary)
signal local_beam_fired(data: Dictionary)       # 即时光束武器权威开火广播
signal local_go_match(role: int, port: int)     # 配对完成通知客户端进入对局
signal local_peer_info(names: Dictionary)       # 开局同步玩家昵称字典
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
signal local_tile_destroyed(cell: Vector2i)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_weapon_spawned(data: Dictionary)   # 地面武器生成事件
signal local_weapon_removed(data: Dictionary)   # 地面武器移除事件
signal local_opponent_left                      # 对局中途对手离线
signal ping_updated(ms: int)                    # 平滑后的网络往返延迟（毫秒）

# 进场全量状态同步信号：
signal match_sync_received(caller: int)
signal local_match_sync(payload: Dictionary)

const DEFAULT_PORT := 7777

# ENet 逻辑通道分配数量。两端需保持通道数一致。
const ENet_CHANNELS := 4

var is_server_mode: bool = false
# 当前服务端进程监听的 UDP 端口（非服务端模式下默认为 DEFAULT_PORT）。
# 单进程单端口架构下，大厅与对局共享该端口。
var server_port: int = DEFAULT_PORT

var ping_ms := 0        # 平滑后的网络延迟（毫秒），0 表示尚未采样
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
	var err := peer.create_server(port, 16, ENet_CHANNELS)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = true
		server_port = port
	return err

func start_client(addr: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port, ENet_CHANNELS)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = false
	return err

func stop() -> void:
	multiplayer.multiplayer_peer = null
	is_server_mode = false


# 检查指定网络对等节点当前是否处于可发送状态。
# 校验底层 ENet 实例状态为 STATE_CONNECTED 且通道数大于 0，避免向已断开或队列已重置的连接发包引发通道错误。
func is_peer_live(id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if not (multiplayer.multiplayer_peer is ENetMultiplayerPeer):
		return multiplayer.get_peers().has(id)
	if not multiplayer.get_peers().has(id):
		return false
	var p := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(id)
	if p == null:
		return false
	return p.get_state() == ENetPacketPeer.STATE_CONNECTED and p.get_channels() > 0


# 检查客户端当前能否向服务端发送数据包。
func can_send_to_server() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return is_peer_live(1)


# 检查是否所有对等节点均处于可收包状态（广播前调用，空列表返回 false）。
func all_peers_sendable() -> bool:
	var ids := multiplayer.get_peers()
	if ids.is_empty():
		return false
	for id in ids:
		if not is_peer_live(int(id)):
			return false
	return true


# 向指定对等节点定向发送 RPC 响应。若对端已离线则静默忽略，避免通道异常。
func reply(id: int, method: String, a = null, b = null, c = null, d = null) -> bool:
	if not is_peer_live(id):
		return false
	var args: Array = [id, method]
	for v in [a, b, c, d]:
		if v == null:
			break
		args.append(v)
	callv("rpc_id", args)
	return true

# 客户端上行 RPC 方法：

@rpc("any_peer", "reliable")
func create_room() -> void:
	room_create_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "reliable")
func join_room(code: String) -> void:
	room_join_requested.emit(multiplayer.get_remote_sender_id(), code)

# 客户端请求房间列表
@rpc("any_peer", "reliable")
func list_rooms() -> void:
	room_list_requested.emit(multiplayer.get_remote_sender_id())

# 客户端上报昵称
@rpc("any_peer", "reliable")
func lobby_name(name: String) -> void:
	lobby_name_set.emit(multiplayer.get_remote_sender_id(), name)

@rpc("any_peer", "reliable")
func send_input(pkt: Dictionary) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)

# 客户端认领角色与昵称
@rpc("any_peer", "reliable")
func claim_role(role: int, player_name: String) -> void:
	role_claimed.emit(multiplayer.get_remote_sender_id(), role, player_name)

# 客户端进场拉取完整对局状态
@rpc("any_peer", "reliable")
func match_sync() -> void:
	match_sync_received.emit(multiplayer.get_remote_sender_id())

# 服务端下行 RPC 方法：

# 快照拆分广播机制：
# 1. 世界快照：包含全员镜像渲染数据，广播下发给所有客户端。
# 2. 本人快照：包含本地玩家预测所必需的确认序列号与权威物理状态。
@rpc("authority", "unreliable")
func snapshot_world(world: Dictionary) -> void:
	local_snapshot_world.emit(world)

@rpc("authority", "unreliable")
func snapshot_own(own: Dictionary) -> void:
	local_snapshot_own.emit(own)

@rpc("authority", "reliable")
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

# 即时光束武器视觉广播
@rpc("authority", "reliable")
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

# 服务端响应客户端的进场拉取请求（下发完整对局快照）
@rpc("authority", "reliable")
func match_sync_data(payload: Dictionary) -> void:
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 客户端收到 match_sync_data: 键=%s" % str(payload.keys()))
	local_match_sync.emit(payload)

@rpc("authority", "reliable")
func hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	local_hit_event.emit(victim_role, damage, source_pos)

@rpc("authority", "reliable")
func tile_destroyed(cell: Vector2i) -> void:
	local_tile_destroyed.emit(cell)

@rpc("authority", "reliable")
func round_state(data: Dictionary) -> void:
	local_round_state.emit(data)

# 地面武器权威同步事件
@rpc("authority", "reliable")
func weapon_spawned(data: Dictionary) -> void:
	local_weapon_spawned.emit(data)

@rpc("authority", "reliable")
func weapon_removed(data: Dictionary) -> void:
	local_weapon_removed.emit(data)

@rpc("authority", "reliable")
func kill_event(killer: int, victim: int) -> void:
	local_kill_event.emit(killer, victim)

@rpc("authority", "reliable")
func room_created(code: String) -> void:
	local_room_created.emit(code)

@rpc("authority", "reliable")
func room_joined(role: int) -> void:
	local_room_joined.emit(role)

# 大厅广播房间列表
@rpc("authority", "reliable")
func room_list(rooms: Array) -> void:
	local_room_list.emit(rooms)

@rpc("authority", "reliable")
func match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	local_match_start.emit(role, spawn, map_path)

# 大厅通知客户端进入对局
@rpc("authority", "reliable")
func go_match(role: int, port: int) -> void:
	local_go_match.emit(role, port)

# 服务端广播玩家昵称表
@rpc("authority", "reliable")
func peer_info(names: Dictionary) -> void:
	local_peer_info.emit(names)

@rpc("authority", "reliable")
func server_message(text: String) -> void:
	local_server_message.emit(text)

# 延迟测量心跳
func send_ping() -> void:
	if not can_send_to_server():
		return
	_ping_sent_ms = Time.get_ticks_msec()
	rpc_id(1, "ping")

@rpc("any_peer", "reliable")
func ping() -> void:
	var from := multiplayer.get_remote_sender_id()
	if not is_peer_live(from):
		return
	rpc_id(from, "pong")

@rpc("authority", "reliable")
func pong() -> void:
	var ms := Time.get_ticks_msec() - _ping_sent_ms
	if ms < 0:
		return
	ping_ms = ms if ping_ms == 0 else int(round(ping_ms * 0.6 + ms * 0.4))
	ping_updated.emit(ping_ms)

# 对局中途对手离线广播
@rpc("authority", "reliable")
func opponent_left() -> void:
	local_opponent_left.emit()

