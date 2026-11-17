extends Node

var role: String = ""
var code: String = ""
var my_role: int = 0
var _match_started := false
var _frames := 0
var _last_pos := Vector2(-999999, -999999)
var _moved := false
var _got_snapshot := false
var _world_pos := Vector2.INF
var _got_bullet_spawn := false
var _got_round_state := false
var _sent_seq := 0
var _max_ack := -1
var _ack_sane := false
var _full_state_ok := false
var _start_sent := false
var _last_snap_tick := 0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role": role = args[i + 1]
			"--code": code = args[i + 1]
	if role.is_empty():
		printerr("SMOKE_MATCH FAIL: 缺 --role")
		get_tree().quit(1)
		return
	NetBus.local_match_start.connect(func(r: int, _s: Vector2i, _m: String) -> void:
		my_role = r
		_match_started = true
		_frames = 0
	)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(func(_d: Dictionary) -> void: _got_bullet_spawn = true)
	NetBus.local_round_state.connect(func(_d: Dictionary) -> void: _got_round_state = true)
	NetBusExt.local_pvp_room_state.connect(_on_pvp_room_state)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_MATCH FAIL: 连接失败")
		get_tree().quit(1))
	var err := NetBus.start_client("127.0.0.1")
	if err != OK:
		printerr("SMOKE_MATCH FAIL: start_client %d" % err)
		get_tree().quit(1)

func _on_connected() -> void:
	match role:
		"create":
			NetBus.rpc_id(1, "create_room")
		"join":
			NetBus.rpc_id(1, "join_room", code)
		_:
			printerr("SMOKE_MATCH FAIL: 非法 role %s" % role)
			get_tree().quit(1)

func _on_pvp_room_state(state: Dictionary) -> void:
	if role == "create" and not _start_sent:
		print("SMOKE_ROOM_CODE=%s" % str(state.get("code", "")))
	if role != "create" or _start_sent:
		return
	var players: Array = state.get("players", [])
	if players.size() >= 2 and int(state.get("your_role", 0)) == int(state.get("host_role", -1)):
		_start_sent = true
		NetBusExt.rpc_id(1, "pvp_start")

func _on_snapshot_world(world: Dictionary) -> void:
	_got_snapshot = true
	# G-04:记下最近一个世界包的 tick —— 上行输入包的 `st`(命中回放时间基准)就是它。
	#   没有快照前保持初值 0;此后每个世界包都会刷新(与真客户端 scenes/pvp_match_client.gd 同源)。
	_last_snap_tick = int(world.get("tick", 0))
	var players_snap: Dictionary = world.get("players", {})
	var me: Dictionary = players_snap.get(str(PvpSession.role), {})
	if not me.is_empty():
		var pos_now: Vector2 = me.get("pos", Vector2.ZERO)
		if _world_pos != Vector2.INF and pos_now.distance_to(_world_pos) > 1.0:
			_moved = true
		_world_pos = pos_now


func _on_snapshot_own(own: Dictionary) -> void:
	var ack: int = int(own.get("ack_seq", -1))
	if ack > _max_ack:
		_max_ack = ack
	if ack >= 30:
		_ack_sane = true
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty() and c2.has("pos") and _world_pos != Vector2.INF:
		var c2pos: Vector2 = c2["pos"]
		var vel: Vector2 = c2.get("vel", Vector2.ZERO)
		var tol: float = 0.5 if vel.length() < 1.0 else 8.0 + vel.length() / 30.0
		if c2pos.distance_to(_world_pos) <= tol:
			_full_state_ok = true

func _on_go_match(role_assign: int, port: int) -> void:
	multiplayer.connected_to_server.connect(_claim_worker.bind(role_assign), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_MATCH FAIL: 连接对局 worker 失败")
		get_tree().quit(1), CONNECT_ONE_SHOT)
	NetBus.stop()
	var err := NetBus.start_client("127.0.0.1", port)
	if err != OK:
		printerr("SMOKE_MATCH FAIL: start_client(worker) %d" % err)
		get_tree().quit(1)

func _claim_worker(role_assign: int) -> void:
	NetBus.rpc_id(1, "claim_role", role_assign, PvpSession.player_name, NetCodec.PROTO_VERSION)

func _physics_process(_delta: float) -> void:
	if not _match_started:
		return
	_frames += 1
	if role == "create":
		var held := 0
		var pressed := 0
		var released := 0
		var ax := 1.0
		if _frames > 240:
			var cyc := (_frames - 240) % 30
			if cyc < 20:
				held = PacketInputSource.BIT_ATTACK
				if cyc == 0:
					pressed = PacketInputSource.BIT_ATTACK
			elif cyc == 20:
				released = PacketInputSource.BIT_ATTACK
		_sent_seq += 1
		var rec := {
			"seq": _sent_seq,
			"ax": ax,
			"held": held,
			"pressed": pressed,
			"released": released,
			"winst": 0,
			"aim": Vector2(1, 0),
			"st": _last_snap_tick,
			"ct": 0,
		}
		NetBus.rpc_id(1, "send_input", NetCodec.encode_input(rec))
	if role == "create":
		# 多打一会儿(到 ~480 帧)再退:帧>240 只够开火但不够 bullet 广播到 join 端,提前 quit 会触发「中途断线拆房」→ join 永远等不到 bullet_spawn。
		if _got_snapshot and _got_round_state and _moved and _ack_sane and _full_state_ok and _frames > 480:
			print("SMOKE_MATCH OK create: snapshot+round_state+moved+ack(seq)%d>=30+fullstate" % _max_ack)
			get_tree().quit(0)
	else:
		if _got_snapshot and _got_round_state and _got_bullet_spawn and _frames > 240:
			print("SMOKE_MATCH OK join: snapshot+round_state+bullet_spawn received")
			get_tree().quit(0)
	if _frames > 600:
		printerr("SMOKE_MATCH FAIL: 超时 role=%s snapshot=%s round=%s moved=%s bullet_spawn=%s" % [
			role, _got_snapshot, _got_round_state, _moved, _got_bullet_spawn])
		get_tree().quit(1)
