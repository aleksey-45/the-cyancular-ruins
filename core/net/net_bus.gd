extends Node

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_room_list(rooms: Array)
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal room_list_requested(caller: int)
signal lobby_name_set(caller: int, name: String)
signal peer_left(peer_id: int)
signal input_received(caller: int, pkt: Dictionary)
signal role_claimed(caller: int, role: int, player_name: String, proto: int)
signal local_snapshot_world(world: Dictionary)
signal local_snapshot_own(own: Dictionary)
signal local_bullet_spawn(data: Dictionary)
signal local_beam_fired(data: Dictionary)
signal local_go_match(role: int, port: int)
signal local_peer_info(names: Dictionary)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int)
signal local_tile_destroyed(cell: Vector2i, seq: int)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_weapon_spawned(data: Dictionary)
signal local_weapon_removed(data: Dictionary)
signal local_opponent_left
signal ping_updated(ms: int)
signal match_sync_received(caller: int)
signal local_match_sync(payload: Dictionary)

const DEFAULT_PORT := 7777
const ENet_CHANNELS := 4

var is_server_mode: bool = false

var ping_ms := 0
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
	reset_snapshot_state()


func is_peer_online(id: int) -> bool:
	return multiplayer.has_multiplayer_peer() and is_peer_live(id)


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
# 判据 = 这条定向发送会成功的全部前置:ENet 状态 CONNECTED 且通道数 > 0(后者正是引擎 send 会检查的那个量)。
	return p.get_state() == ENetPacketPeer.STATE_CONNECTED and p.get_channels() > 0


func can_send_to_server() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return is_peer_live(1)


func all_peers_sendable() -> bool:
	var ids := multiplayer.get_peers()
	if ids.is_empty():
		return false
	for id in ids:
		if not is_peer_live(int(id)):
			return false
	return true


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

@rpc("any_peer", "call_remote", "reliable", 0)
func create_room() -> void:
	room_create_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func join_room(code: String) -> void:
	room_join_requested.emit(multiplayer.get_remote_sender_id(), code)

@rpc("any_peer", "call_remote", "reliable", 0)
func list_rooms() -> void:
	room_list_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func lobby_name(name: String) -> void:
	lobby_name_set.emit(multiplayer.get_remote_sender_id(), name)

@rpc("any_peer", "call_remote", "reliable", 1)
func send_input(payload: PackedByteArray) -> void:
	var pkt := _rx.accept_input(payload)
	if pkt.is_empty():
		if _rx.warn_input_once():
			_input_decode_warned(payload)
		return
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)

@rpc("any_peer", "call_remote", "reliable", 0)
func claim_role(role: int, player_name: String, proto: int) -> void:
	role_claimed.emit(multiplayer.get_remote_sender_id(), role, player_name, proto)

# 客户端→worker:进场拉取(昵称/色相/生效选项/出生点/role 集合)。★ 它取代"服务器推三载荷":推给一个正在切场景的
# 客户端时,同一次 poll 推的 4 条没有订阅方 ⇒ 静默丢失。拉的方向反过来,应答按 role 回,不依赖时序。
@rpc("any_peer", "call_remote", "reliable", 0)
func match_sync() -> void:
	match_sync_received.emit(multiplayer.get_remote_sender_id())

var _rx := SnapshotRx.new()


func snapshot_need_full() -> bool:
	return false


func reset_snapshot_state() -> void:
	_rx.reset()


func snap_stats() -> Dictionary:
	return _rx.stats()


@rpc("authority", "call_remote", "unreliable", 0)
func snapshot_world(payload: PackedByteArray) -> void:
	var now := Time.get_ticks_usec()
	var d := _rx.accept_world(payload, now)
	if d.is_empty():
		if _rx.warn_snapshot_once():
			_snapshot_decode_warned(payload)
		return
	if NetDiag.enabled():
		var diag := _rx.take_diag(now)
		if not diag.is_empty():
			NetDiag.log_metric("snap_rx", diag)
		var gap_ms := int(d.get("gap_ms", 0))
		if gap_ms > SnapshotRx.SNAP_GAP_MS:
			NetDiag.log_event("snap_gap", {"gap_ms": gap_ms, "tick": int(d.get("tick", 0)),
					"bytes": payload.size()}, true)
	local_snapshot_world.emit({"tick": int(d.get("tick", 0)), "players": d.get("players", {})})


@rpc("authority", "call_remote", "unreliable", 0)
func snapshot_own(payload: PackedByteArray) -> void:
	var d := _rx.accept_own(payload)
	if d.is_empty():
		if _rx.warn_snapshot_once():
			_snapshot_decode_warned(payload)
		return
	local_snapshot_own.emit({"ack_seq": int(d.get("ack_seq", 0)), "q": int(d.get("q", 0)),
			"c2": d.get("c2", {})})


# 快照解码失败只在第一次大声报("只报一次"的旗在 SnapshotRx;本函数只管打)/静默丢弃会让客户端表现为对手不动/自己一直回拉。
func _snapshot_decode_warned(payload: PackedByteArray) -> void:
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("快照解码失败(长度 %d,首字节 %d):两端线格式版本不一致?" % [payload.size(), ver])

# 输入解码失败只在第一次大声报(同族:两端版本不一致是一次性条件,而输入包 60Hz 不间断)。★ 静默丢弃 = 该玩家整局"动不了",
# 且服务器侧不报任何错 —— 现场只看到卡住。宁可每次启动响一声,也不要把错位的值喂进权威模拟。
func _input_decode_warned(payload: PackedByteArray) -> void:
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("输入包解码失败(长度 %d,首字节 %d):两端线格式版本不一致?" % [payload.size(), ver])

@rpc("authority", "call_remote", "reliable", 3)
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

@rpc("authority", "call_remote", "reliable", 3)
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

@rpc("authority", "call_remote", "reliable", 0)
func match_sync_data(payload: Dictionary) -> void:
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 客户端收到 match_sync_data: 键=%s" % str(payload.keys()))
	local_match_sync.emit(payload)

@rpc("authority", "call_remote", "reliable", 3)
func hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void:
	local_hit_event.emit(victim_role, damage, source_pos, seq)

@rpc("authority", "call_remote", "reliable", 3)
func tile_destroyed(cell: Vector2i, seq: int) -> void:
	local_tile_destroyed.emit(cell, seq)

@rpc("authority", "call_remote", "reliable", 0)
func round_state(data: Dictionary) -> void:
	local_round_state.emit(data)

@rpc("authority", "call_remote", "reliable", 3)
func weapon_spawned(data: Dictionary) -> void:
	local_weapon_spawned.emit(data)

@rpc("authority", "call_remote", "reliable", 3)
func weapon_removed(data: Dictionary) -> void:
	local_weapon_removed.emit(data)

@rpc("authority", "call_remote", "reliable", 3)
func kill_event(killer: int, victim: int) -> void:
	local_kill_event.emit(killer, victim)


@rpc("authority", "call_remote", "reliable", 0)
func room_created(code: String) -> void:
	local_room_created.emit(code)

@rpc("authority", "call_remote", "reliable", 0)
func room_joined(role: int) -> void:
	local_room_joined.emit(role)

@rpc("authority", "call_remote", "reliable", 0)
func room_list(rooms: Array) -> void:
	local_room_list.emit(rooms)

@rpc("authority", "call_remote", "reliable", 0)
func match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	local_match_start.emit(role, spawn, map_path)

@rpc("authority", "call_remote", "reliable", 0)
func go_match(role: int, port: int) -> void:
	local_go_match.emit(role, port)

@rpc("authority", "call_remote", "reliable", 0)
func peer_info(names: Dictionary) -> void:
	local_peer_info.emit(names)

@rpc("authority", "call_remote", "reliable", 0)
func server_message(text: String) -> void:
	local_server_message.emit(text)

func send_ping() -> void:
	if not can_send_to_server():
		return
	_ping_sent_ms = Time.get_ticks_msec()
	rpc_id(1, "ping")

@rpc("any_peer", "call_remote", "reliable", 0)
func ping() -> void:
	var from := multiplayer.get_remote_sender_id()
	if not is_peer_live(from):
		return
	rpc_id(from, "pong")

@rpc("authority", "call_remote", "reliable", 0)
func pong() -> void:
	var ms := Time.get_ticks_msec() - _ping_sent_ms
	if ms < 0:
		return
	ping_ms = ms if ping_ms == 0 else int(round(ping_ms * 0.6 + ms * 0.4))
	ping_updated.emit(ping_ms)

@rpc("authority", "call_remote", "reliable", 0)
func opponent_left() -> void:
	local_opponent_left.emit()
