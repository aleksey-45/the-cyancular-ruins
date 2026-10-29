extends Node
# Wire —— 传输层唯一收口(autoload,v5)。两端共用 /root/Wire。
# 取代 net_bus.gd + net_bus_ext.gd:v4 的三处结构病灶在此一并废除 ——
#   ① 方法表两份且冻结 ⇒ 单一登记表 WireKind.TABLE(协议唯一真相源);
#   ② 判活与发送分离(max channels: 0 竞态根因)⇒ send_to 内「查状态→组帧→入队」一个调用内完成,
#      且直连 ENetConnection 后不再有「MultiplayerAPI 还没忘掉已拆 peer」这一层;
#   ③ 事件在 service() 的调用栈内派发 ⇒ 攒批后再派发:handler 里 stop()/start_client()
#      永远不在 ENet 的 C 栈内执行(v4 靠调用点各处 call_deferred 规避的原生段错误,结构上关死)。
#
# 信号表面 = 原 NetBus + NetBusExt 的并集(死协议三条除外:peer_info / match_options /
# peer_hues,发送端与消费端均已不存在);签名逐字保留 ⇒ 场景层迁移是机械替换。
#
# ★ 语义变更(有意,v5):SNAPSHOT_* 从「与可靠会话挤 ch0」挪到 CH_STATE 专用道;
#   SERVER_MESSAGE 的「连接失败/服务器断开」仍经 local_server_message 发(对局重连的触发点挂着它)。

const DEFAULT_PORT := 7777
# 握手魔数:connect_to_host 的 data 带上它,服务端在 EVENT_CONNECT 当场核对,
# 版本不符直接 reset ⇒ 旧客户端(v4)永远连不进 v5 服务端,反之亦然(不保留混连)。
const CONNECT_MAGIC := 0x00435905   # "CYR" << 8 | PROTO(5)

var is_server_mode := false

var ping_ms := 0        # 平滑后 RTT(ms),0 = 尚未采样
var _ping_sent_ms := 0


# ── 信号(名字与参数 = 原 NetBus / NetBusExt 逐字保留;详注见 git 历史里的旧文件)──
# 客户端侧(收自服务器):
signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_room_list(rooms: Array)
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)
signal local_snapshot_world(world: Dictionary)
signal local_snapshot_own(own: Dictionary)
signal local_bullet_spawn(data: Dictionary)
signal local_beam_fired(data: Dictionary)
signal local_go_match(role: int, port: int)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
signal local_tile_destroyed(cell: Vector2i)
signal local_sub_destroyed(sub: Vector2i)
signal local_round_state(data: Dictionary)
signal local_kill_event(killer: int, victim: int)
signal local_weapon_spawned(data: Dictionary)
signal local_weapon_removed(data: Dictionary)
signal local_opponent_left
signal local_match_sync(payload: Dictionary)
signal local_hit_confirm(shooter_role: int, victim_role: int)
signal local_time_state(payload: Dictionary)
signal local_royale_rooms(rooms: Array)
signal local_royale_room_state(state: Dictionary)
signal local_pvp_room_state(state: Dictionary)
signal local_team_rooms(rooms: Array)
signal local_team_room_state(state: Dictionary)
signal local_session_token(token: String)
signal local_rejoin_denied(reason: String)
signal ping_updated(ms: int)

# 连接生命周期(客户端侧;v4 挂在 MultiplayerAPI 上的那三个,语义同名搬来):
signal connected_to_server          # 握手完成,可以开始发会话消息
signal connection_failed            # 连接失败(超时/被拒)
signal server_disconnected          # 连上过之后对端断开(重连逻辑的触发点)

# 服务器侧(收自客户端;caller = Wire 分配的 peer id):
signal room_create_requested(caller: int)
signal room_join_requested(caller: int, code: String)
signal room_list_requested(caller: int)
signal lobby_name_set(caller: int, name: String)
signal peer_left(peer_id: int)
signal input_received(caller: int, pkt: Dictionary)
signal role_claimed(caller: int, role: int, player_name: String)
signal match_sync_received(caller: int)
signal player_options_received(caller: int, opts: Dictionary)
signal suicide_requested(caller: int)
signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String, beta: bool)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int, token: String)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)
signal royale_start_ai_requested(caller: int)
signal pvp_start_requested(caller: int)
signal team_create_requested(caller: int, opts: Dictionary)
signal team_join_requested(caller: int, code: String, invite: String, beta: bool)
signal team_pick_requested(caller: int, team: int)
signal team_leave_requested(caller: int)
signal team_start_requested(caller: int)
signal team_list_requested(caller: int, token: String)
signal room_map_requested(caller: int, code: String, path: String)
signal token_reported(caller: int, token: String)
signal reclaim_requested(caller: int, role: int, token: String)
signal rejoin_requested(caller: int, code: String, token: String)


var _host: ENetConnection = null
var _peers: Dictionary = {}          # server:peer_id(int) -> ENetPacketPeer
var _server_peer: ENetPacketPeer = null   # client:唯一的服务器 peer
var _next_peer_id := 2               # 1 保留给「服务器」这个概念本身
var _client_connected := false
var _seq := 0                        # u16 帧序(LE;仅诊断,不承重)
var _generation := 0                 # 每次 stop()/start_*() +1:丢弃属于旧 host 的迟到事件

# 诊断计数(--netstat / NetDiag 读取;不做行为分支)
var bad_frames := 0                  # 版本不符 / 长度不足 / 未知 kind
var dropped_sends := 0               # 判活失败 / peer.send 报错而丢弃的定向帧
var unknown_kinds := 0


func start_server(port: int = DEFAULT_PORT) -> Error:
	_teardown()
	_host = ENetConnection.new()
	# max_peers 给 32(>16 人上限,重连时新旧 peer 短暂并存也够);带宽不限 = 与 v4 同口径。
	var err := _host.create_host_bound("*", port, 32, WireKind.CHANNELS, 0, 0)
	if err == OK:
		is_server_mode = true
	return err


func start_client(addr: String, port: int = DEFAULT_PORT) -> Error:
	_teardown()
	_host = ENetConnection.new()
	var err := _host.create_host(1, WireKind.CHANNELS, 0, 0)
	if err != OK:
		return err
	is_server_mode = false
	# 连接结果异步:成功/失败都在 _process 的 EVENT_CONNECT / EVENT_DISCONNECT 里落到
	# local_server_message(「连接失败」/「服务器断开」),与 v4 的 MultiplayerAPI 映射同词。
	_server_peer = _host.connect_to_host(addr, port, WireKind.CHANNELS, CONNECT_MAGIC)
	return OK if _server_peer != null else ERR_CANT_CONNECT


func stop() -> void:
	_teardown()


func _teardown() -> void:
	_generation += 1
	if _host != null:
		_host.destroy()   # 当场拆 socket 与全部 peer;handler 里调用也安全(见文件头 ③)
		_host = null
	_peers.clear()
	_server_peer = null
	is_server_mode = false
	_client_connected = false


# ── 判活与账本 ────────────────────────────────────────────────────────────────
func is_peer_live(id: int) -> bool:
	if not is_server_mode:
		return false
	var p: ENetPacketPeer = _peers.get(id)
	return p != null and p.get_state() == ENetPacketPeer.STATE_CONNECTED


func peer_ids() -> Array:
	return _peers.keys()


func can_send_to_server() -> bool:
	return _client_connected and _server_peer != null \
			and _server_peer.get_state() == ENetPacketPeer.STATE_CONNECTED


func kick(id: int) -> void:
	var p: ENetPacketPeer = _peers.get(id)
	if p == null:
		return
	_peers.erase(id)
	p.peer_disconnect_now()
	peer_left.emit(id)   # 立即记离场;ENet 事后的 DISCONNECT 事件按未知 id 静默吞掉


# RTT 毫秒(ENet 自己的往返统计;命中补偿/诊断用,与应用层 ping_ms 互不替代)。
func rtt_ms(id: int) -> int:
	var p: ENetPacketPeer = _peers.get(id)
	if p == null or p.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return 0
	return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))


# ── 发送 ─────────────────────────────────────────────────────────────────────
# client → server。binary kind(SEND_INPUT)的 args[0] 必须是 PackedByteArray。
func send(kind: int, args: Array = []) -> bool:
	if _server_peer == null or _server_peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		dropped_sends += 1
		return false
	return _send_peer(_server_peer, kind, args)


# server → 定向 peer。判活在同一个调用内完成(原子:GDScript 无重入,查与发之间不可能被拆)。
func send_to(id: int, kind: int, args: Array = []) -> bool:
	if not is_peer_live(id):
		dropped_sends += 1
		return false
	return _send_peer(_peers[id], kind, args)


# server → 全体(或 only 给出的 id 子集)。★ 语义与 v4 的 rpc() 广播不同:逐 live peer 发送、
# 死 peer 跳过 —— v4 里 all_peers_sendable() 是「一个坏 peer ⇒ 整帧快照全跳」的整体闸。
func broadcast(kind: int, args: Array = [], only: Array = []) -> int:
	var n := 0
	for id in _peers.keys():
		if not only.is_empty() and not only.has(int(id)):
			continue
		if send_to(int(id), kind, args):
			n += 1
	return n


func _send_peer(p: ENetPacketPeer, kind: int, args: Array) -> bool:
	var entry: Dictionary = WireKind.TABLE.get(kind, {})
	if entry.is_empty():
		unknown_kinds += 1
		push_error("Wire: 未登记的 kind=%d(登记表 WireKind.TABLE)" % kind)
		return false
	var frame := PackedByteArray()
	frame.resize(4)
	frame[0] = WireKind.PROTO
	frame[1] = kind
	frame[2] = _seq & 0xFF
	frame[3] = (_seq >> 8) & 0xFF
	_seq = (_seq + 1) & 0xFFFF
	if entry.has("bin"):
		frame.append_array(args[0])   # binary kind:载荷直通(NetCodec 三 kind 的手打包字节)
	else:
		frame.append_array(var_to_bytes(args))
	var flags := ENetPacketPeer.FLAG_UNSEQUENCED | ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT \
			if entry["ch"] == WireKind.CH_STATE else ENetPacketPeer.FLAG_RELIABLE
	var err := p.send(entry["ch"], frame, flags)
	if err != OK:
		dropped_sends += 1
		return false
	return true


# ── 应用层测速(v4 同款:0.5s 一次,EWMA 平滑)─────────────────────────────────
func send_ping() -> void:
	if not can_send_to_server():
		return
	_ping_sent_ms = Time.get_ticks_msec()
	send(WireKind.PING)


# 服务端实际绑定的端口(start_server(0) 绑临时端口时,测试/编排用它拿端口号)。
func host_port() -> int:
	if _host == null:
		return 0
	var p := _host.get_local_port()
	return int(p) if p != null else 0


# ── 轮询与派发 ───────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	pump()


# pump 单独成函数:`-s` 冒烟没有帧循环,由测试手动驱动同一份轮询/派发逻辑(不另抄一份)。
func pump() -> void:
	if _host == null:
		return
	var gen := _generation
	# ① 攒批:service(0) 每次至多吐一个事件,循环到 NONE;handler 不在 ENet 的 C 栈内跑。
	var batch: Array = []
	while batch.size() < 4096:
		var ev: Array = _host.service(0)
		if ev.is_empty() or int(ev[0]) == ENetConnection.EVENT_NONE:
			break
		batch.append(ev)
	# ② 派发:逐条处理;中途有人 stop()/start_*() 换了 host,余下事件整批作废。
	for ev in batch:
		if _generation != gen:
			break
		_dispatch(int(ev[0]), ev[1], ev[2])
	# ③ 冲队列(reliable 入队的帧也在这时上路)。
	if _host != null and _generation == gen:
		_host.flush()


func _dispatch(ev: int, peer, data: Variant) -> void:
	match ev:
		ENetConnection.EVENT_CONNECT:
			if is_server_mode:
				_on_connect_server(peer, data)
			else:
				_client_connected = true
				print("Wire: 已连接服务器")
				connected_to_server.emit()
		ENetConnection.EVENT_DISCONNECT:
			if is_server_mode:
				_on_disconnect_server(peer)
			else:
				var was: bool = _client_connected
				_client_connected = false
				_server_peer = null
				print("Wire: 服务器断开" if was else "Wire: 连接失败")
				local_server_message.emit("服务器断开" if was else "连接失败")
				if was:
					server_disconnected.emit()
				else:
					connection_failed.emit()
		ENetConnection.EVENT_RECEIVE:
			# 实测 4.7.2:第三元素是裸 int = 通道号(不是文档写过的 dict),数据体从 peer 队列取;
			# dict 形状也一并认(引擎若改回 dict 口径不至于再断)。
			var ch := -1
			var body := PackedByteArray()
			if data is Dictionary:
				ch = int((data as Dictionary).get("channel", -1))
				body = (data as Dictionary).get("data", PackedByteArray())
			elif data is float or data is int:
				ch = int(data)
				if peer != null:
					body = peer.get_packet()
			var caller := _id_of_peer(peer)
			_on_frame(caller, ch, body)


func _on_connect_server(peer, data: Variant) -> void:
	# EVENT_CONNECT 的第三元素是裸 int(实测 4.7.2;文档口径曾写 dict),两种形状都认。
	var magic := int(data) if data is float or data is int else \
			int((data as Dictionary).get("data", 0)) if data is Dictionary else 0
	if magic != CONNECT_MAGIC:
		# 版本/魔数不符:当场 reset,不让它进任何房间账本。
		bad_frames += 1
		peer.reset()
		print("Wire: 拒绝握手不符的连接(magic 不匹配)")
		return
	var id := _next_peer_id
	_next_peer_id += 1
	_peers[id] = peer
	print("Wire: 玩家连入 peer=%d" % id)


func _on_disconnect_server(peer) -> void:
	var id := _id_of_peer(peer)
	if id == 0:
		return   # 从未登记(被 kick / 被拒握手)的 peer:静默
	_peers.erase(id)
	print("Wire: 玩家断开 peer=%d" % id)
	peer_left.emit(id)


func _id_of_peer(peer) -> int:
	for id in _peers:
		if _peers[id] == peer:
			return int(id)
	return 0


func _on_frame(caller: int, channel: int, payload: PackedByteArray) -> void:
	if payload.size() < 4:
		bad_frames += 1
		return
	if payload[0] != WireKind.PROTO:
		bad_frames += 1
		return
	var kind := payload[1]
	var entry: Dictionary = WireKind.TABLE.get(kind, {})
	if entry.is_empty():
		unknown_kinds += 1
		return
	var body := payload.slice(4)
	# 方向守卫:client 只收 s→c,server 只收 c→s(防自己人伪造对端方向)。
	if is_server_mode and entry["dir"] != WireKind.DIR_C2S:
		bad_frames += 1
		return
	if not is_server_mode and entry["dir"] != WireKind.DIR_S2C:
		bad_frames += 1
		return

	# 三条 binary kind:解码失败只在第一次大声报(版本不一致是一次性条件,30Hz 静默丢会
	# 表现成「对手不动/自己回拉/该玩家动不了」)。
	var bin: String = entry.get("bin", "")
	if bin == "input":
		var pkt := NetCodec.decode_input(body)
		if pkt.is_empty():
			_input_decode_warned(body)
			return
		input_received.emit(caller, pkt)
		return
	if bin == "world":
		var world := NetCodec.decode_world(body)
		if world.is_empty():
			_snapshot_decode_warned("world", body)
			return
		_diag_world_rx(world, body)
		local_snapshot_world.emit(world)
		return
	if bin == "own":
		var own := NetCodec.decode_own(body)
		if own.is_empty():
			_snapshot_decode_warned("own", body)
			return
		local_snapshot_own.emit(own)
		return

	var args: Variant = bytes_to_var(body)   # 本引擎口径 1 参;对象永不入线(载荷全是核心类型)
	if not (args is Array):
		bad_frames += 1
		return
	var argv: Array = args

	# 内联处理的两条测速消息。
	if kind == WireKind.PING:
		if is_server_mode:
			send_to(caller, WireKind.PONG, [])
		return
	if kind == WireKind.PONG:
		var ms := Time.get_ticks_msec() - _ping_sent_ms
		if ms >= 0:
			ping_ms = ms if ping_ms == 0 else int(round(ping_ms * 0.6 + ms * 0.4))
			ping_updated.emit(ping_ms)
		return

	var sig: String = entry["sig"]
	if sig == "":
		return
	if entry["dir"] == WireKind.DIR_C2S:
		callv("emit_signal", [sig, caller] + argv)
	else:
		callv("emit_signal", [sig] + argv)


# ── 诊断(v4 同款口径:世界包到达间隔 >150ms 记一条;1Hz 收包计数与服务器对账)──
var _diag_snap_us := 0
var _diag_rx := 0
var _diag_rx_at := 0

func _diag_world_rx(world: Dictionary, body: PackedByteArray) -> void:
	if not NetDiag.enabled():
		return
	var now := Time.get_ticks_usec()
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
			NetDiag.log_event("snap_gap", {"gap_ms": gap_ms, "tick": int(world.get("tick", 0)),
					"bytes": body.size()}, true)
	_diag_snap_us = now


var _snap_warned := false
var _input_warned := false

func _snapshot_decode_warned(which: String, payload: PackedByteArray) -> void:
	if _snap_warned:
		return
	_snap_warned = true
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("快照解码失败(%s 包,长度 %d,首字节 %d):两端线格式版本不一致?" % [
			which, payload.size(), ver])

func _input_decode_warned(payload: PackedByteArray) -> void:
	if _input_warned:
		return
	_input_warned = true
	var ver := payload[0] if payload.size() > 0 else -1
	push_error("输入包解码失败(长度 %d,首字节 %d):两端线格式版本不一致?" % [payload.size(), ver])
