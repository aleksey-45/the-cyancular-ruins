extends Node
# 网络总线(autoload,PvP 唯一网络收口):服务器与客户端共用同一节点路径 /root/NetBus,
# RPC 才能跨场景路由(autoload 常驻,不随场景切换销毁)。方法按"调用方"区分两端。
# 服务器侧经转交信号把建房/加入/断线交给 RoomManager(不硬依赖其类型,任务可独立编译)。

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_room_list(rooms: Array)   # 大厅回复房间列表 [{code,players}]
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

# 服务器端 → RoomManager 的转交信号
signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal room_list_requested(caller: int)
signal lobby_name_set(caller: int, name: String)   # 客户端连上大厅时报昵称(房间列表显示)
signal peer_left(peer_id: int)
# 服务器端 → MatchHost 的输入包
signal input_received(caller: int, pkt: Dictionary)
# worker:客户端连上后 claim_role 转交(caller=peer id, role=客户端在大厅领的角色, player_name=昵称)
signal role_claimed(caller: int, role: int, player_name: String)
# 服务器 → 客户端
signal local_snapshot(snap: Dictionary)
signal local_bullet_spawn(data: Dictionary)
signal local_beam_fired(data: Dictionary)   # 即时光束武器(激光)权威开火:对手端据此画光束视觉副本
signal local_go_match(role: int, port: int)   # 大厅配对完:客户端去连对局 worker(role/port 由此给)
signal local_peer_info(names: Dictionary)     # worker 开局:双方昵称 {role(int) -> name}(头上显示)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
signal local_tile_destroyed(cell: Vector2i)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_opponent_left          # 对局中途对手断线(服务器 → 存活方,播报后回菜单)
signal ping_updated(ms: int)        # 平滑后延迟 ms
signal local_enemy_spawn(roster: Array)  # 服务器:本局鸟清单 [{id,scene,pos}],客户端建副本
signal local_enemy_died(id: int)         # 服务器:某只鸟死亡(id),客户端移除副本
# 进场拉取(取代"服务器推三载荷"):见下方 match_sync/match_sync_data 的注释
signal match_sync_received(caller: int)          # worker 侧转交 → server_main
signal local_match_sync(payload: Dictionary)     # 客户端侧:应答到达

const DEFAULT_PORT := 7777
# ENet 通道数。create_server/create_client 的通道参数默认 0 → 发包报
# "Unable to send packet on channel 0, max channels: 0"(引擎把 0 当"无通道可用")。
# 显式分配若干条通道即可根治;两端数值保持一致(握手按较小者协商)。
const ENet_CHANNELS := 4

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

# ── 客户端 → 服务器 ──
@rpc("any_peer", "reliable")
func create_room() -> void:
	room_create_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "reliable")
func join_room(code: String) -> void:
	room_join_requested.emit(multiplayer.get_remote_sender_id(), code)

# 客户端:请求当前全部房间(刷新房间列表)
@rpc("any_peer", "reliable")
func list_rooms() -> void:
	room_list_requested.emit(multiplayer.get_remote_sender_id())

# 客户端→大厅:上报昵称(房间列表展示在房玩家)
@rpc("any_peer", "reliable")
func lobby_name(name: String) -> void:
	lobby_name_set.emit(multiplayer.get_remote_sender_id(), name)

@rpc("any_peer", "reliable")
func send_input(pkt: Dictionary) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)

# 客户端→worker:报到自己在对局里的角色+昵称(role 大厅已发;player_name 用于对方头上显示)。
# worker 据此建 role→peer 映射,并在两人到齐后把双方昵称回传给各端(peer_info)。
@rpc("any_peer", "reliable")
func claim_role(role: int, player_name: String) -> void:
	role_claimed.emit(multiplayer.get_remote_sender_id(), role, player_name)

# 客户端→worker:**进场拉取**。对局场景建好之后主动要一次(昵称/色相/生效选项/出生点/role 集合)。
# ★ 它**取代**原来"服务器推三载荷"那条路径。推的根因问题是「推给一个正在切场景的客户端」:
#   服务器在**同一次 poll** 里推 4 条,而那一刻新场景的订阅方一个都不存在 → 静默丢失(自检 B2,
#   后果是对手颜色不生效、昵称表空、禁武器闸门没上)。拉的方向反过来:客户端建好之后才开口,
#   晚到也无所谓 —— 应答按 role 回,不依赖任何时序。
@rpc("any_peer", "reliable")
func match_sync() -> void:
	match_sync_received.emit(multiplayer.get_remote_sender_id())

# ── 服务器 → 客户端(权威方=peer1 可调)──
@rpc("authority", "unreliable")
func snapshot(snap: Dictionary) -> void:
	local_snapshot.emit(snap)

@rpc("authority", "reliable")
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

# 即时光束武器(激光)权威开火:服务器把本发光束几何广播给非射手客户端画视觉副本
# (物理子弹走 bullet_spawn;即时光束无移动实体,只能事件里带整条折线)。
@rpc("authority", "reliable")
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

# worker→客户端:match_sync 的应答(一次性完整快照)。
# 载荷 = {names:{role->昵称}, hues:{role->色相}, options:生效选项, roles:[int], spawns:{role->Vector2i}}。
# 可靠通道:一次性、必须到(不像快照那样可以丢一帧)。
@rpc("authority", "reliable")
func match_sync_data(payload: Dictionary) -> void:
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

# 大厅 → 客户端:房间列表 [{code:String, players:int}]
@rpc("authority", "reliable")
func room_list(rooms: Array) -> void:
	local_room_list.emit(rooms)

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
