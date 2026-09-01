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
var _frames := 0
var _last_pos := Vector2(-999999, -999999)
var _moved := false
var _got_snapshot := false
var _got_bullet_spawn := false

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
	NetBus.local_match_start.connect(func(r: int, _s: Vector2i, _m: String) -> void: my_role = r)
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_bullet_spawn.connect(func(_d: Dictionary) -> void: _got_bullet_spawn = true)
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

func _physics_process(_delta: float) -> void:
	_frames += 1
	# create:先右移(1..240帧),再开火(241帧起)。join:站着不动。
	if role == "create":
		var held := 0
		var pressed := 0
		var ax := 1.0
		if _frames > 240:
			held = NetworkInputSource.BIT_ATTACK
			pressed = NetworkInputSource.BIT_ATTACK
		var pkt := {
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
		if _got_snapshot and _moved and _frames > 240:
			print("SMOKE_MATCH OK create: snapshot+own pos moved")
			get_tree().quit(0)
	else:
		if _got_snapshot and _got_bullet_spawn and _frames > 240:
			print("SMOKE_MATCH OK join: snapshot+bullet_spawn received")
			get_tree().quit(0)
	# 超时
	if _frames > 600:
		printerr("SMOKE_MATCH FAIL: 超时 role=%s snapshot=%s moved=%s bullet_spawn=%s" % [
			role, _got_snapshot, _moved, _got_bullet_spawn])
		get_tree().quit(1)
