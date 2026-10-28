extends Node
# 网络总线(autoload,PvP 唯一网络收口):两端共用同一节点路径 /root/NetBus,RPC 才能跨场景路由。
# 方法按"调用方"区分两端;服务器侧经转交信号把建房/加入/断线交给 RoomManager(不硬依赖其类型)。

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_room_list(rooms: Array)   # 大厅回复房间列表 [{code,players}]
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal room_list_requested(caller: int)
signal lobby_name_set(caller: int, name: String)   # 客户端连上大厅时报昵称(房间列表显示)
signal peer_left(peer_id: int)
signal input_received(caller: int, pkt: Dictionary)   # 30Hz 一包(内含 2 条 tick 记录;U1 后一条记录 = 1 个物理 tick)
signal role_claimed(caller: int, role: int, player_name: String)
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
signal match_sync_received(caller: int)          # worker 侧转交 → server_main
signal local_match_sync(payload: Dictionary)     # 客户端侧:应答到达

const DEFAULT_PORT := 7777
# ENet 通道数:通道参数留 0 会报 "Unable to send packet on channel 0, max channels: 0";两端数值须一致(握手按较小者协商)。
# ★ 配好通道数治不了那条报错全部:剩下的来源是往一个 ENet 已拆掉、MultiplayerAPI 还没忘掉的 peer 发包 ⇒ 判活用 is_peer_live()。
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
	reset_snapshot_state()


# ── 发包前的存活判据:不用 multiplayer.get_peers()(它随 API 信号更新,比 ENet 真实状态晚,断开握手期间可达秒级)。
# 真身:enet_peer_disconnect() 当场 reset_queues ⇒ channelCount=0 而 get_peers() 仍报在线 ⇒ 定向发送报 channel 0 错(0 = reliable)。
func is_peer_live(id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if not (multiplayer.multiplayer_peer is ENetMultiplayerPeer):
		return multiplayer.get_peers().has(id)
# ★ 先问 get_peers():它虽滞后,但"它说没有"可信 —— 且 get_peer() 对不在表里的 id 会打 ERR_FAIL_COND 噪音。
	if not multiplayer.get_peers().has(id):
		return false
	var p := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(id)
	if p == null:
		return false
# 判据 = 这条定向发送会成功的全部前置:ENet 状态 CONNECTED 且通道数 > 0(后者正是引擎 send 会检查的那个量)。
	return p.get_state() == ENetPacketPeer.STATE_CONNECTED and p.get_channels() > 0


# 本端能否发给服务器:除 peer 还在,还要求已 CONNECTED(CONNECTING 的 peer 发出去只会被丢,且 put_packet 先打错误)。
func can_send_to_server() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return is_peer_live(1)


# ── 广播前判据:表里每一个 peer 都能收包吗(空表 = false)。★ rpc() 广播在 ENet 层是逐 peer 发包,表里只要剩一个
# "队列已拆、API 还没忘掉"的 peer 就报 channel 0/1 错(往往正是刚被 disconnect_peer 踢掉、还没退出 get_peers() 的那个)。
func all_peers_sendable() -> bool:
	var ids := multiplayer.get_peers()
	if ids.is_empty():
		return false
	for id in ids:
		if not is_peer_live(int(id)):
			return false
	return true


# 定向回一条 RPC(答复某个 caller),对端不活着就静默跳过(返回 false)。★ 必须收口到一个口:请求与对端断开常挤在
# 同一次 poll 里,ENet 处理 DISCONNECT 命令时当场清通道数,同批更早的 RECEIVE 要到 dispatch 才派发 ⇒ 应答必然打 channel 0 错。
# 实参形状同 rpc_id(最多 4 个),★ 实参不得传 null(null 表示"到此为止")。
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

# ★ 输入上行:30Hz 一包,**内含连续两个物理 tick 的记录**(U1:客户端 60Hz 真输入、不锁存;服务器每 tick 消费一条)。
# 载荷是手打包的 PackedByteArray(NetCodec.encode_input:头 2 B + 记录 40 B = 42 B,P1 定点化前 46 B;更早 30Hz 单条锁存记录 = 34 B)。
# 可靠通道保序 + seq 单调(包级 seq = 高 tick 记录,低 tick = seq-1)= 服务端与客户端重放同序(C2 回滚「1 seq = 1 tick」的前提)。
@rpc("any_peer", "call_remote", "reliable", 1)
func send_input(payload: PackedByteArray) -> void:
	var pkt := NetCodec.decode_input(payload)
	if pkt.is_empty():
		_input_decode_warned(payload)
		return
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)

# 客户端→worker:报到角色+昵称(role 大厅已发);worker 据此建 role→peer 映射,两人到齐后回传双方昵称(peer_info)。
@rpc("any_peer", "call_remote", "reliable", 0)
func claim_role(role: int, player_name: String) -> void:
	role_claimed.emit(multiplayer.get_remote_sender_id(), role, player_name)

# 客户端→worker:进场拉取(昵称/色相/生效选项/出生点/role 集合)。★ 它取代"服务器推三载荷":推给一个正在切场景的
# 客户端时,同一次 poll 推的 4 条没有订阅方 ⇒ 静默丢失。拉的方向反过来,应答按 role 回,不依赖时序。
@rpc("any_peer", "call_remote", "reliable", 0)
func match_sync() -> void:
	match_sync_received.emit(multiplayer.get_remote_sender_id())

# ── 服务器 → 客户端(权威方 = peer1 可调);快照拆两条:世界包(全部玩家渲染字段,构造一次、广播一次 = O(N))
# 与本人包(自己的 ack_seq + 权威整态 c2,定向发本人)。★ 世界包必须用 rpc() 广播,别退化回逐 rpc_id 循环(那是 O(N²),
# 旧实现 8 人局上行 ≈29Mbps);两者互不连累:c2 丢只少一个回滚锚点,世界包丢只冻结一帧副本插值。
# ★ 载荷是手打包的 PackedByteArray(NetCodec 编解码),RPC 入口仍 emit 同形状 Dictionary ⇒ 消费方一行没动。
#   实测 8 人局上行 587→72KB/s、世界包 N≤8 恒 1 片(详表见 docs/eng/netcode-snapshots.md §2);载荷无量化(float32 逐位相同)。
#   ★ 那个读数是 60Hz 发包口径(2026-10-09 实测);2026-10-23 起下行改 30Hz ⇒ 每秒字节按 ≈½ 折算(未复测,别把 72 当现状)。
# 诊断(--diag,默认关):快照到达间隔 >150ms 记一条。世界包是 unreliable,断流时副本只能冻结,
# 恢复那一帧再跳 —— 这是用户报「卡顿后瞬移」里"他人瞬移"的直接证据(判据与读数见 docs/eng/tests.md)。
var _diag_snap_us := 0
var _diag_rx := 0        # 本秒收世界包数(--diag;与服务器 snapshot_tx 的 world_msgs 对账)
var _diag_rx_at := 0     # 上一次汇总的世界包时间戳(usec)

# ── 增量/差分合并态(P1.5,PROTO_VERSION 6)──
# ★ 合并放在**解码边界**(NetBus):下游(三模式客户端 / 探针 / watcher)仍收到与增量前同形状的完整
#   `{tick, players}` / `{ack_seq, q, c2}` ⇒ 消费方零改动,协议知识不外泄。
# ★ 乱序/丢包处理(unreliable 通道):DELTA 依赖 base_tick 链,先到的包可能"差一档"。旧实现一律丢包并请求 FULL
#   ⇒ 每个乱序/丢包换一次 RTT 级冻结(用户报"联机对手显示卡")。现在分三态:
#   - base < 已应用 = 迟到旧包 ⇒ 静默丢(我们的状态更新,别为此要 FULL);
#   - base > 已应用 = 链条缺口 ⇒ 进 pending 等前序包,接上后按序补链(乱序零冻结);
#   - pending 超上限才请求 FULL(真丢包才付这一次代价)。
const WORLD_PENDING_MAX := 4
const OWN_PENDING_MAX := 4
var _world_state: Dictionary = {}   # 合并后的完整世界状态 {"tick": int, "players": {role_str: 全字段}}
var _world_pending: Array = []      # 等待前序包的世界 DELTA(按到达序)
var _own_state: Dictionary = {}     # 合并后的完整 c2
var _own_tick := -1                 # _own_state 对应的服务器本人包 tick(delta 基准)
var _own_pending: Array = []        # 本人包乱序缓冲
var _need_full_world := false        # 基准断了 → 下一条输入包置 BIT_NEED_FULL
var _need_full_own := false


# 是否有基准断了、需要请求服务器补 FULL(输入打包处读)。
func snapshot_need_full() -> bool:
	return _need_full_world or _need_full_own


# 重连/换局:合并基准作废(不清会拿上一纪元的 tick 去比,永远不连续)。
func reset_snapshot_state() -> void:
	_world_state = {}
	_world_pending.clear()
	_own_state = {}
	_own_tick = -1
	_own_pending.clear()
	_need_full_world = false
	_need_full_own = false


@rpc("authority", "call_remote", "unreliable", 0)
func snapshot_world(payload: PackedByteArray) -> void:
	var pkt := NetCodec.decode_world(payload)
	if pkt.is_empty():
		_snapshot_decode_warned("world", payload)
		return
	_world_feed(pkt, payload.size())


# 喂一个世界包:能接上就应用并补链;接不上按三态处理(乱序=缓冲、迟到=静默丢、真丢包才要 FULL)。
func _world_feed(pkt: Dictionary, bytes: int) -> void:
	if not _world_try_apply(pkt, bytes):
		var cs := NetCodec.chain_state(int(pkt.get("base_tick", -1)),
				int(_world_state.get("tick", -1)))
		if cs != NetCodec.CHAIN_GAP:
			return   # STALE/FULL 缺基准:静默丢(状态已更新或由 FULL 兜底)
		_world_pending.append(pkt)
		while _world_pending.size() > WORLD_PENDING_MAX:
			_world_pending.pop_front()
			_need_full_world = true
		return
	# 补链:反复尝试缓冲里能接上的包(乱序到达的后续包在这里被按序应用,零冻结)
	var progressed := true
	while progressed:
		progressed = false
		for i in _world_pending.size():
			var p: Dictionary = _world_pending[i]
			if _world_try_apply(p, 0):
				_world_pending.remove_at(i)
				progressed = true
				break


# 尝试把一个世界包应用到当前合并态。真应用了才向下游 emit(下游形状与增量前一致)。
func _world_try_apply(pkt: Dictionary, bytes: int) -> bool:
	var tick := int(pkt.get("tick", 0))
	if tick <= int(_world_state.get("tick", -1)):
		return false   # 重复/旧包
	var merged := NetCodec.apply_world(pkt, _world_state)
	if merged.is_empty():
		return false
	_world_state = merged
	_need_full_world = false
	if bool(pkt.get("full", false)):
		_world_pending.clear()   # FULL 是硬锚点:此前缓冲的 DELTA 基准已过期
	# 诊断只统计真实收包(补链包的 bytes=0)
	if bytes > 0:
		var now := Time.get_ticks_usec()
		if NetDiag.enabled():
			_diag_rx += 1
			if _diag_rx_at == 0:
				_diag_rx_at = now
			elif now - _diag_rx_at >= 1000000:
				NetDiag.log_event("snap_rx", {"interval_ms": int((now - _diag_rx_at) / 1000), "world_msgs": _diag_rx})
				_diag_rx_at = now
				_diag_rx = 0
			if _diag_snap_us > 0:
				var gap_ms := int((now - _diag_snap_us) / 1000)
				if gap_ms > 150:
					NetDiag.log_event("snap_gap", {"gap_ms": gap_ms, "tick": tick,
							"bytes": bytes}, true)
		_diag_snap_us = now
	local_snapshot_world.emit({"tick": tick, "players": _world_state["players"]})
	return true


@rpc("authority", "call_remote", "unreliable", 0)
func snapshot_own(payload: PackedByteArray) -> void:
	var pkt := NetCodec.decode_own(payload)
	if pkt.is_empty():
		_snapshot_decode_warned("own", payload)
		return
	_own_feed(pkt)


# 本人包:三态同世界包(乱序缓冲补链 / 迟到静默丢 / 真丢包才请求 FULL)。
func _own_feed(pkt: Dictionary) -> void:
	if bool(pkt.get("full", false)):
		var tick := int(pkt.get("tick", 0))
		if _own_tick >= 0 and tick <= _own_tick:
			return   # 旧包
		_own_state = (pkt.get("c2", {}) as Dictionary)
		_own_tick = tick
		_own_pending.clear()
		_need_full_own = false
		_emit_own(pkt)
		return
	var cs := NetCodec.chain_state(int(pkt.get("base_tick", -1)), _own_tick)
	if cs == NetCodec.CHAIN_STALE:
		return   # 迟到旧包
	if cs == NetCodec.CHAIN_GAP:
		_own_pending.append(pkt)
		while _own_pending.size() > OWN_PENDING_MAX:
			_own_pending.pop_front()
			_need_full_own = true
		return
	if not _own_try_apply(pkt):
		_need_full_own = true
		return
	var progressed := true
	while progressed:
		progressed = false
		for i in _own_pending.size():
			var p: Dictionary = _own_pending[i]
			if _own_try_apply(p):
				_own_pending.remove_at(i)
				progressed = true
				break


func _own_try_apply(pkt: Dictionary) -> bool:
	if NetCodec.chain_state(int(pkt.get("base_tick", -1)), _own_tick) != NetCodec.CHAIN_OK:
		return false
	var merged := NetCodec.apply_own(pkt, _own_state)
	if merged.is_empty():
		return false
	_own_state = merged
	_own_tick = int(pkt.get("tick", 0))
	_emit_own(pkt)
	return true


# ★ 下游仍收完整 c2(与增量前同形状):rollback 锚点/软同步零改动。
func _emit_own(pkt: Dictionary) -> void:
	local_snapshot_own.emit({"ack_seq": int(pkt.get("ack_seq", 0)), "q": int(pkt.get("q", 0)),
			"c2": _own_state})

# 快照解码失败只在第一次大声报(版本不一致是一次性条件,而本函数每个快照包(~30Hz)被调);静默丢弃会让客户端表现为对手不动/自己一直回拉。
var _snap_warned := false

func _snapshot_decode_warned(which: String, payload: PackedByteArray) -> void:
	if _snap_warned:
		return
	_snap_warned = true
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("快照解码失败(%s 包,长度 %d,首字节 %d):两端线格式版本不一致?" % [
			which, payload.size(), ver])

# 输入解码失败只在第一次大声报(同族:两端版本不一致是**一次性条件**,而输入包 30Hz 不间断)。★ 静默丢弃 = 该玩家整局"动不了",
# 且服务器侧不报任何错 —— 现场只看到卡住。宁可每次启动响一声,也不要把错位的值喂进权威模拟。
var _input_warned := false

func _input_decode_warned(payload: PackedByteArray) -> void:
	if _input_warned:
		return
	_input_warned = true
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("输入包解码失败(长度 %d,首字节 %d):两端线格式版本不一致?" % [payload.size(), ver])

@rpc("authority", "call_remote", "reliable", 3)
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

# 即时光束(激光)权威开火:无移动实体,只能事件里带整条折线(物理子弹走 bullet_spawn)。
@rpc("authority", "call_remote", "reliable", 3)
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

# match_sync 的应答(一次性完整快照:昵称/色相/生效选项/roles/spawns),走可靠通道(不像快照能丢一帧)。
@rpc("authority", "call_remote", "reliable", 0)
func match_sync_data(payload: Dictionary) -> void:
# 纯诊断开关(须写在 -- 之后):关着时一行都不打 ⇒ 生产行为逐字不变。
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 客户端收到 match_sync_data: 键=%s" % str(payload.keys()))
	local_match_sync.emit(payload)

@rpc("authority", "call_remote", "reliable", 3)
func hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	local_hit_event.emit(victim_role, damage, source_pos)

@rpc("authority", "call_remote", "reliable", 3)
func tile_destroyed(cell: Vector2i) -> void:
	local_tile_destroyed.emit(cell)

@rpc("authority", "call_remote", "reliable", 0)
func round_state(data: Dictionary) -> void:
	local_round_state.emit(data)

# ── 地面武器事件:服务器权威的"多了一件/少了一件"广播。低频(掉落/捡起),故走事件而不是塞进 30Hz 快照。
# ★ 只进 NetBus,别在 NetBusExt 里也加一份:两者已有 beam_fired 重名,接收端挂错节点会静默 no-op。
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

# 大厅→客户端:配对完成,去连对局 worker(role 由大厅定;端口是 worker 独占的 UDP 端口)。
@rpc("authority", "call_remote", "reliable", 0)
func go_match(role: int, port: int) -> void:
	local_go_match.emit(role, port)

# worker→客户端:开局广播双方昵称(role -> name),两端据此在头上显示各自 ID。
@rpc("authority", "call_remote", "reliable", 0)
func peer_info(names: Dictionary) -> void:
	local_peer_info.emit(names)

@rpc("authority", "call_remote", "reliable", 0)
func server_message(text: String) -> void:
	local_server_message.emit(text)

# ★ 判活收在本函数里(不只靠调用点):每 0.5s 一次的周期发送,多一个调用点就多一条往死 peer 发包的路。
func send_ping() -> void:
	if not can_send_to_server():
		return
	_ping_sent_ms = Time.get_ticks_msec()
	rpc_id(1, "ping")

@rpc("any_peer", "call_remote", "reliable", 0)
func ping() -> void:
	var from := multiplayer.get_remote_sender_id()
# ★ 判活再回:发 ping 的客户端可能在同一帧里断开,而回复是定向可靠包 ⇒ 往已拆 peer 发就是 channel 0 错。
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

# 对局中途对手断线(1v1 无法继续 → 存活方播报后回菜单)
@rpc("authority", "call_remote", "reliable", 0)
func opponent_left() -> void:
	local_opponent_left.emit()
