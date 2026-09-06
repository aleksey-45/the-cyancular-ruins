extends Node
# B2 loopback 冒烟客户端:建房后发送固定输入(移动 + 开火),断言:
#  create: 收到快照且自己位置发生变化(输入→服务器权威模拟→快照→客户端)
#  join:   收到快照 + 收到对手子弹 spawn 广播(开火→服务器→broadcast→对手)
# 命中/掉血不在此冒烟覆盖(出生点相距远,无法确定性命中);留用户手动端到端。
# 用法: godot --headless --path . Tests/pvp_match_smoke.tscn -- --role create
#       godot --headless --path . Tests/pvp_match_smoke.tscn -- --role join --code 0000

var role: String = ""
var code: String = ""
var my_role: int = 0
var _match_started := false   # 收到对局 worker 的 match_start 后才算开局(此前只连大厅)
var _frames := 0
var _last_pos := Vector2(-999999, -999999)
var _moved := false
var _got_snapshot := false
var _got_bullet_spawn := false
var _got_round_state := false   # 回合制:收到 round_state(初始 COUNTDOWN 广播)
# C2 rollback(阶段3):create 端发带 seq 的输入包,断言服务器 1/tick 消费、ack 随 tick 前进、
# 快照带权威整态(c2)且其 pos 与散字段 pos 一致(证明全态快照在链路上可用)。
var _sent_seq := 0
var _max_ack := -1
var _ack_sane := false     # create:ack 已推进到 ≥30
var _full_state_ok := false  # create:快照 c2 整态携带且 pos 与散字段一致

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
		_frames = 0   # 计数从开局(worker 的 match_start)起算
	)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_bullet_spawn.connect(func(_d: Dictionary) -> void: _got_bullet_spawn = true)
	NetBus.local_round_state.connect(func(_d: Dictionary) -> void: _got_round_state = true)
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

func _on_snapshot(snap: Dictionary) -> void:
	_got_snapshot = true
	if my_role == 0:
		return
	var players: Dictionary = snap["players"]
	if not players.has(str(my_role)):
		return
	var p: Dictionary = players[str(my_role)]
	var pos: Vector2 = p["pos"]
	if _last_pos.x < -99999.0:
		_last_pos = pos
	elif pos.distance_to(_last_pos) > 1.0:
		_moved = true
	# C2 阶段3断言(仅发送输入的 create 端才见 ack 推进)
	var ack: int = int(p.get("ack_seq", -1))
	if ack > _max_ack:
		_max_ack = ack
		if _max_ack >= 30:
			_ack_sane = true
	var c2: Dictionary = p.get("c2", {})
	if not c2.is_empty() and c2.has("pos"):
		var c2pos: Vector2 = c2["pos"]
		if c2pos.distance_to(pos) < 0.5:
			_full_state_ok = true

# 大厅配对完成:断大厅 → 转连对局 worker → claim 角色
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
	NetBus.rpc_id(1, "claim_role", role_assign, PvpSession.player_name)

func _physics_process(_delta: float) -> void:
	if not _match_started:
		return   # 连大厅阶段不发输入、不计帧
	_frames += 1
	# create:先右移(1..240帧),再开火(241帧起)。join:站着不动。
	if role == "create":
		var held := 0
		var pressed := 0
		var ax := 1.0
		if _frames > 240:
			held = NetworkInputSource.BIT_ATTACK
			pressed = NetworkInputSource.BIT_ATTACK
		_sent_seq += 1
		var pkt := {
			"seq": _sent_seq,   # C2:单调输入序号(服务器 ack 依据)
			"ax": ax,
			"held": held,
			"pressed": pressed,
			"released": 0,
			"weapon": 0,
			"aim": Vector2(1, 0),
		}
		NetBus.rpc_id(1, "send_input", pkt)
	# 成功判定
	if role == "create":
		# 多打一会儿(到 ~480 帧)再退:帧>240 只够开火但不够 bullet 广播到 join 端,
		# 提前 quit 会触发"中途断线拆房"→ join 永远等不到 bullet_spawn。
		if _got_snapshot and _got_round_state and _moved and _ack_sane and _full_state_ok and _frames > 480:
			print("SMOKE_MATCH OK create: snapshot+round_state+moved+ack(seq)%d>=30+fullstate" % _max_ack)
			get_tree().quit(0)
	else:
		if _got_snapshot and _got_round_state and _got_bullet_spawn and _frames > 240:
			print("SMOKE_MATCH OK join: snapshot+round_state+bullet_spawn received")
			get_tree().quit(0)
	# 超时
	if _frames > 600:
		printerr("SMOKE_MATCH FAIL: 超时 role=%s snapshot=%s round=%s moved=%s bullet_spawn=%s" % [
			role, _got_snapshot, _got_round_state, _moved, _got_bullet_spawn])
		get_tree().quit(1)
