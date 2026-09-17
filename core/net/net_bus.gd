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
# 快照拆两条(2026-09-12,取代原单条 `local_snapshot`)
signal local_snapshot_world(world: Dictionary)   # 全部玩家的渲染字段(副本/血条用)
signal local_snapshot_own(own: Dictionary)       # 只有本人需要的 ack_seq + 权威整态 c2
signal local_bullet_spawn(data: Dictionary)
signal local_beam_fired(data: Dictionary)   # 即时光束武器(激光)权威开火:对手端据此画光束视觉副本
signal local_go_match(role: int, port: int)   # 大厅配对完:客户端去连对局 worker(role/port 由此给)
signal local_peer_info(names: Dictionary)     # worker 开局:双方昵称 {role(int) -> name}(头上显示)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
signal local_tile_destroyed(cell: Vector2i)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_weapon_spawned(data: Dictionary)   # 场上多了一件地面武器({inst,type_id,mag,pos,vel})
signal local_weapon_removed(data: Dictionary)   # 少了一件({inst,by_role})
signal local_opponent_left          # 对局中途对手断线(服务器 → 存活方,播报后回菜单)
signal ping_updated(ms: int)        # 平滑后延迟 ms
# (原 local_enemy_spawn / local_enemy_died 已删:它们只服务 PvPvE 中立鸟,该特性 2026-09-14 定案不开
#  并整体移除 —— 客户端副本机制/服务端刷鸟/快照 enemies 键/本节点两条 @rpc 一并删干净。)
# 进场拉取(取代"服务器推三载荷"):见下方 match_sync/match_sync_data 的注释
signal match_sync_received(caller: int)          # worker 侧转交 → server_main
signal local_match_sync(payload: Dictionary)     # 客户端侧:应答到达

const DEFAULT_PORT := 7777
# ENet 通道数。create_server/create_client 的通道参数默认 0 → 发包报
# "Unable to send packet on channel 0, max channels: 0"(引擎把 0 当"无通道可用")。
# 显式分配若干条通道即可根治;两端数值保持一致(握手按较小者协商)。
# ★ 2026-09-17 订正:**这条常量治不了那个报错的全部**。引擎源码里能打出这条消息的只有
#   `enet_packet_peer.cpp` 的 `p_channel >= peer->channelCount`,即**目标 peer 的通道数为 0** ——
#   而 ENet 只在 `enet_peer_reset_queues()`(**断开/超时/被 reset**)里把它置 0。
#   所以通道数配好之后,剩下的来源是「**往一个 ENet 已拆掉、但 MultiplayerAPI 还没忘掉的
#   peer 发包**」—— 判活请用下面的 `is_peer_live()`(它读 ENet 自己的 state,不滞后)。
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


# ── 发包前的存活判据(2026-09-17)──
# 为什么不能用 `multiplayer.get_peers()`:它随 MultiplayerAPI 的连接/断开**信号**更新,比 ENet
# 的真实状态**晚**(本仓 lobby_rooms.gd 的注释里已实测记过"滞后超过一帧")。
#
# 真身(2026-09-17 读引擎源码确认):`enet_peer_disconnect()` 在**发起断开的当场**就调
# `enet_peer_reset_queues()` → `peer->channelCount = 0`(thirdparty/enet/peer.c:349),而
# DISCONNECT 事件要等对方 ACK 或 5s 超时才产生 —— 于是**整个断开握手期间**(可达秒级)
# 这个 peer 的 ENet 状态已不是 CONNECTED、`channelCount` 已是 0,而 `get_peers()` 仍报在线。
# 这期间任何**定向**发送 → `ENetPacketPeer::send` 的 `p_channel >= peer->channelCount` →
# `Unable to send packet on channel 0, max channels: 0`(报文里的通道号就是证据:
# `SYSCH_RELIABLE=0 / SYSCH_UNRELIABLE=1`,所以 "channel **0**" 只可能来自 **reliable** 的定向包;
#  广播那次是例外 —— `enet_host_broadcast` 自己会跳过非 CONNECTED 的 peer)。
# 这里改读 **ENet peer 自己的 state**:ENet 拆 peer 时它当场就变,严格早于 get_peers()。
func is_peer_live(id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	# 非 ENet 后端(理论上没有,探针里可能有桩)退回原判据,别在这里报错。
	if not (multiplayer.multiplayer_peer is ENetMultiplayerPeer):
		return multiplayer.get_peers().has(id)
	# ★ 先问 get_peers():它虽然**滞后**(可能把已拆的 peer 仍报在线),但"它说没有"这句是**可信**的
	#   —— 而且 `get_peer()` 对不在表里的 id 会打一条 `ERR_FAIL_COND`(等于换一条噪音)。
	if not multiplayer.get_peers().has(id):
		return false
	var p := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(id)
	if p == null:
		return false
	# 判据 = 「这条定向发送会成功吗」的全部前置条件:ENet 状态是 CONNECTED,**且通道数 > 0**
	# (后者正是引擎 `ENetPacketPeer::send` 会检查的那个量 —— 它同时兜住"ENet 已把这次连接
	#  的通道拆掉、但状态位还没翻过去"这种更窄的窗口)。
	return p.get_state() == ENetPacketPeer.STATE_CONNECTED and p.get_channels() > 0


# 本端此刻能不能把包发给服务器(客户端用)。除了"peer 还在",还要求它已经 **CONNECTED** ——
# 处于 CONNECTING 的 peer 发出去只会被 ENet 丢掉,而 `put_packet` 会先打一条错误。
func can_send_to_server() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return is_peer_live(1)


# 定向回一条 RPC(答复某个 caller)。**对端已经不活着就静默跳过**(返回 false),不报错、不发。
#
# ★ 为什么必须收口到一个口:请求与"对端断开"经常挤在**同一次 poll** 里 —— ENet 按到达顺序处理
#   收到的命令,**处理 DISCONNECT 命令时当场就把那个 peer 的通道数清零**,而同批里排在它前面的
#   RECEIVE 事件要等到 dispatch 阶段才派发 → 于是"客户端发完请求就 `stop()`"这一拍,
#   服务端是在**通道已清零**的状态下处理那个请求、并发它的应答 → 应答必然打
#   `Unable to send packet on channel 0, max channels: 0`(实测:1v1 配对完成 → 客户端转连
#   worker 那一拍必现一条;大厅/worker 里所有"答复 caller"的站定都是这一类)。
#   判据同 `is_peer_live`(它读 ENet 自己的 state + 通道数,不滞后)。
#
# 实参形状与 `rpc_id` 一致(最多 4 个),故所有调用点只需把方法名换成 `reply` ——
# ★ 因此**实参不得传 null**(null 表示"到此为止");要传更多实参请直接用 `callv("rpc_id", …)`。
# 审计:`grep -rn "NetBus\.reply(" server/` 就是"所有答复 caller 的定向发送"的完整清单。
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
# ── 快照:**拆两条**(2026-09-12)──
# 旧实现把**含全部 N 人 c2 整态**的同一份 dict 逐 peer 各 `rpc_id` 一次 → 服务器序列化量 O(N²)
# (实测:单人条目 948B,其中 c2 占 664B(70%);8 人局服务器上行 ≈29 Mbps)。而 C2 下每个
# 客户端其实**只用得到自己那一份 c2** —— 70% 的体积花在只有本人需要的数据上,却每人各发一遍。
# 拆开后:
#   ① 世界包 = 全部玩家的渲染字段,构造一次、**广播一次** → O(N)
#      ★ 必须用 `rpc()` 而不是逐 `rpc_id` 循环:前者在 ENet 层是单次序列化 + enet_host_broadcast,
#        后者会把 O(N²) 加回来。
#   ② 本人包 = 自己的 ack_seq + c2,定向发给本人
# 顺带好处:两者**互不连累** —— c2 丢只少一个回滚锚点(下一个快照补),世界包丢只冻结一帧副本插值。
# 实测(拆包后估算):8 人局服务器上行 3555KB/s → 446KB/s(≈29Mbps → 3.6Mbps)。
@rpc("authority", "unreliable")
func snapshot_world(world: Dictionary) -> void:
	local_snapshot_world.emit(world)

@rpc("authority", "unreliable")
func snapshot_own(own: Dictionary) -> void:
	local_snapshot_own.emit(own)

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

# ── 地面武器事件(2026-09-15)──
# 服务器权威的"场上多了一件/少了一件"广播。**低频**(掉落/捡起,一局几十次),
# 所以走事件而不是塞进 60Hz 快照(大乱斗的快照体积随人数线性增长,再加 12 把会雪上加霜)。
# ★ 只进 NetBus,**不要**在 NetBusExt 里也加一份:那两者已有 beam_fired 重名
#   (net_bus.gd / net_bus_ext.gd),接收端挂错节点会**静默 no-op**(对手的枪凭空消失且不报错)。
@rpc("authority", "reliable")
func weapon_spawned(data: Dictionary) -> void:
	local_weapon_spawned.emit(data)

@rpc("authority", "reliable")
func weapon_removed(data: Dictionary) -> void:
	local_weapon_removed.emit(data)

@rpc("authority", "reliable")
func kill_event(killer: int, victim: int) -> void:
	local_kill_event.emit(killer, victim)

# (原 enemy_spawn / enemy_died 两条 @rpc 已删 —— 只服务 PvPvE 中立鸟,特性 2026-09-14 定案不开。
#  ★ 它们**不是**原版服务端的协议面:由本项目提交 aa1d8f0「feat: PvPvE 中立鸟入竞技场」加入,
#    故删除不影响「原 NetBus 逐字节一致」那条不变量。)

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
	var from := multiplayer.get_remote_sender_id()
	# ★ 判活再回:发 ping 的客户端可能**在同一帧里断开**(它最后那次 ping 与它自己的 `stop()`
	#   挤在一起),而回复是定向可靠包 → 往 ENet 已拆掉的 peer 发就是那条 channel 0 错误。
	#   (同类站点已一并接上判据;本轮定位到"来源确实在被守卫的站点上"但没能钉死具体哪一处
	#    —— 见 docs/2026-09-17-pvp-weapon-net-fixes.md §1.5。)
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

# 对局中途对手断线(1v1 无法继续 → 存活方播报后回菜单)
@rpc("authority", "reliable")
func opponent_left() -> void:
	local_opponent_left.emit()
