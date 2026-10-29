extends SceneTree
# Wire 连通冒烟(v5 传输层在真 ENet + loopback 下的最小整链验证)。存在理由:
#   net_wire_smoke 管帧与编解码的**纯逻辑**;这里管 **ENet 语义**——两 Wire 实例在
#   127.0.0.1:0(临时端口)上:握手 magic 核对、事件派发、c→s/s→c 通用 kind 往返、
#   binary kind 三条(输入/世界/含 ping)往返、kick 即离场、握手不符的连接被拒。
# ★ 不进默认批:绑 127.0.0.1 临时端口(仓规「冒烟不碰网络」;run_all.sh EXCLUDED 已登记,
#   临时端口段不占 7777 与 worker 池)。跑法:
#   "$GODOT" --headless --path . -s res://tests/smoke/wire_conn_smoke.gd
#   判词 = WIRE CONN OK(n 条断言)。去掉什么才红:wire.gd 的组帧/派发/magic 核对/kick 任一处退回,
#   或 ENetConnection 语义与假设不符(事件形状/通道旗标)。

const EXPECTED_CHECKS := 10
const WireScript := preload("res://core/net/wire.gd")

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# 收集到的信号(断言读这些变量;pump 内同步 emit)。
var _join_code := ""
var _join_caller := 0
var _got_role := -1
var _got_world := {}
var _got_input := false
var _left_ids: Array = []


func _initialize() -> void:
	# 空载守卫:任一依赖加载/实例化失败都要显式失败退出(-s 下抛错走不到 quit 会永久挂起)。
	if WireScript == null or WireKind == null or NetCodec == null:
		print("WIRE CONN FAILED: 依赖加载失败(Wire/WireKind/NetCodec)")
		quit(1)
		return
	var server: Node = WireScript.new()
	var client: Node = WireScript.new()
	if server == null or client == null:
		print("WIRE CONN FAILED: Wire 实例化失败")
		quit(1)
		return

	server.room_join_requested.connect(func(caller: int, code: String) -> void:
		_join_caller = caller
		_join_code = code)
	server.input_received.connect(func(_caller: int, _pkt: Dictionary) -> void: _got_input = true)
	server.peer_left.connect(func(id: int) -> void: _left_ids.append(id))
	client.local_room_joined.connect(func(role: int) -> void: _got_role = role)
	client.local_snapshot_world.connect(func(world: Dictionary) -> void: _got_world = world)

	# ① 服务端起临时端口、客户端握手(去掉什么才红:magic 核对退回 ⇒ can_send_to_server 永假)。
	_chk(server.start_server(0) == OK, "服务端起在临时端口")
	var port: int = server.host_port()
	_chk(port > 0, "拿到临时端口号(get_local_port)")
	if port <= 0:
		_finish(server, client)
		return
	_chk(client.start_client("127.0.0.1", port) == OK, "客户端发起连接")
	# ★ 两端都要就位:客户端的 CONNECT 事件比服务端早一个泵周期(ENet 语义,服务端要把
	#   自己的 EVENT_CONNECT 再 service 一轮才吐出来)⇒ 只等客户端会把服务端留在「未登记」态。
	if not _pump_until(func() -> bool:
		return client.can_send_to_server() and server.peer_ids().size() >= 1, server, client, 3000):
		_chk(false, "握手完成(magic 核对通过;3s 内未连上)")
		_finish(server, client)
		return
	_chk(true, "握手完成(magic 核对通过)")

	# ② 通用 kind 上行:caller 必须是服务端分配的 peer id(≥2;1 保留给服务器概念)。
	_join_code = ""
	client.send(WireKind.JOIN_ROOM, ["4321"])
	_pump_until(func() -> bool: return _join_code != "", server, client, 1000)
	_chk(_join_code == "4321" and _join_caller >= 2, "JOIN_ROOM 上行,caller=分配的 peer id(实得 code=%s caller=%d)" % [_join_code, _join_caller])

	# ③ 通用 kind 下行。
	server.send_to(_join_caller, WireKind.ROOM_JOINED, [7])
	_pump_until(func() -> bool: return _got_role >= 0, server, client, 1000)
	_chk(_got_role == 7, "ROOM_JOINED 下行(实得 %d)" % _got_role)

	# ④ binary kind:世界包(ch2 unreliable)真 NetCodec 载荷整链往返。
	var world := _fixture_world()
	server.send_to(_join_caller, WireKind.SNAPSHOT_WORLD, [NetCodec.encode_world(world)])
	_pump_until(func() -> bool: return not _got_world.is_empty(), server, client, 1000)
	_chk(int(_got_world.get("tick", -1)) == int(world["tick"]) and _got_world.get("players", {}).size() == 2,
			"SNAPSHOT_WORLD 二进制链路往返(tick=%s, players=%d)" % [str(_got_world.get("tick", -1)), _got_world.get("players", {}).size()])

	# ⑤ binary kind:输入包(ch1 reliable)+ 应用层 ping/pong。
	var src := PacketInputSource.new()
	var lo := PacketInputSource.pack_record(src, 42, Vector2(1.0, 0.0))
	lo["held"] = PacketInputSource.BIT_ATTACK
	lo["ax"] = 0.25
	var hi := PacketInputSource.pack_record(src, 43, Vector2(1.0, 0.0))
	hi["held"] = 0
	hi["ax"] = -0.25
	var pair := PacketInputSource.pack_pair(lo, hi, Vector2(1.0, 0.0), 555, 666)
	client.send(WireKind.SEND_INPUT, [NetCodec.encode_input(pair)])
	client.send_ping()
	_pump_until(func() -> bool: return _got_input and client.ping_ms > 0, server, client, 1500)
	_chk(_got_input and client.ping_ms > 0, "SEND_INPUT 上行 + PING→PONG 更新 ping_ms(input=%s ping=%d)" % [str(_got_input), client.ping_ms])

	# ⑥ 握手不符的连接必须被拒:错 magic 的裸 ENet 连接不进 peer 表。
	# ★ rogue 自己的 host 也得 service:connect 请求只有 service/flush 才上路 —— 只泵 server
	#   的话请求躺在 rogue 队列里,这条断言会退化成空转绿(2026-10-29 变异验证抓出)。
	var rogue := ENetConnection.new()
	if rogue.create_host(1, 4, 0, 0) == OK:
		rogue.connect_to_host("127.0.0.1", port, 4, 0xDEADBEEF)
		var t6 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t6 < 400:
			server.pump()
			client.pump()
			rogue.service(0)   # 事件忽略:只关心服务端有没有把它登进来
			OS.delay_msec(8)
		rogue.destroy()
	_chk(server.peer_ids().size() == 1, "错 magic 的连接被拒(未入 peer 表;实得 %d 个 peer)" % server.peer_ids().size())

	# ⑦ kick:立即出表 + peer_left 当场发。
	server.kick(_join_caller)
	_chk(server.peer_ids().is_empty() and _left_ids.has(_join_caller),
			"kick 即离场 + peer_left(表 %s,事件 %s)" % [str(server.peer_ids()), str(_left_ids)])

	_finish(server, client)


func _finish(server: Node, client: Node) -> void:
	server.stop()
	client.stop()
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("WIRE CONN OK(%d 条断言):握手 magic · 上下行 · 二进制三链 · 拒错连 · kick" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("WIRE CONN FAILED: %d 处" % _fails.size())
		quit(1)


# 手动泵两端的同一份轮询/派发逻辑(wire.gd 的 pump 不另抄;真机由 _process 驱动)。
func _pump_until(cond: Callable, a: Node, b: Node, timeout_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		a.pump()
		b.pump()
		if cond.call():
			return true
		OS.delay_msec(8)
	return cond.call()




func _fixture_world() -> Dictionary:
	var e1 := {
		"pos": Vector2(1234.567, -678.901), "vel": Vector2(300.25, -42.125),
		"facing": -1, "pose": 4, "type_id": 7, "hp": 49, "waterproof": 10,
		"downed": true, "aim": Vector2(0.6, -0.8),
		"previewing": true, "haste": false, "rewind": true,
		"trail": [[100.0, 200.0], [101.5, 201.5]],
	}
	var e2 := e1.duplicate(true)
	e2["pos"] = Vector2(5.5, 6.75)
	e2["downed"] = false
	e2["trail"] = []
	return {"tick": 123456, "players": {"1": e1, "2": e2}}
