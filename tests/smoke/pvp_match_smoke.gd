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
var _world_pos := Vector2.INF   # 世界包里的本端 pos(与本人包的 c2.pos 跨包比对)
var _got_bullet_spawn := false
var _got_round_state := false   # 回合制:收到 round_state(初始 COUNTDOWN 广播)
# C2 rollback(阶段3):create 端发带 seq 的输入包,断言服务器 1/tick 消费、ack 随 tick 前进、
# 快照带权威整态(c2)且其 pos 与散字段 pos 一致(证明全态快照在链路上可用)。
var _sent_seq := 0
var _prev_rec: Dictionary = {}   # U1:上一 tick 的记录(流水线:本包发 [上一 tick, 本 tick])
var _max_ack := -1
var _ack_sane := false     # create:ack 已推进到 ≥30
var _full_state_ok := false  # create:快照 c2 整态携带且 pos 与散字段一致
var _start_sent := false   # create:1v1 开局改由房主点「开始游戏」(2026-10-24),本探针代按一次

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

# 1v1 从 2026-10-24 起由房主点「开始游戏」:create 端看到 2/2 且自己是房主就代按一次(join 端不动)。
func _on_pvp_room_state(state: Dictionary) -> void:
	if role == "create" and not _start_sent:
		print("SMOKE_ROOM_CODE=%s" % str(state.get("code", "")))   # 编排脚本(ps1/sh)从这里取房间号
	if role != "create" or _start_sent:
		return
	var players: Array = state.get("players", [])
	if players.size() >= 2 and int(state.get("your_role", 0)) == int(state.get("host_role", -1)):
		_start_sent = true
		NetBusExt.rpc_id(1, "pvp_start")

func _on_snapshot_world(world: Dictionary) -> void:
	_got_snapshot = true
	var players_snap: Dictionary = world.get("players", {})
	var me: Dictionary = players_snap.get(str(PvpSession.role), {})
	if not me.is_empty():
		var pos_now: Vector2 = me.get("pos", Vector2.ZERO)
		# 位移跟踪:相邻世界包之间位置变了 = 服务器确实在模拟我们这一端
		if _world_pos != Vector2.INF and pos_now.distance_to(_world_pos) > 1.0:
			_moved = true
		_world_pos = pos_now


# 本人包:只有自己需要的 ack_seq + 权威整态 c2。
# ★ S1(2026-10-24):本人包在玩家步进之后发(c2 = 第 T tick 状态),世界包仍在步进前发(自己那份 pos = T-1)⇒
#   移动中两者天然差 1~2 tick 位移。断言从"<0.5px 同拍"放宽为"静止时仍 <0.5px;移动时 ≤ 一 tick 位移 + 8px 余量",
#   仍然能抓"c2 丢了 / 位置完全对不上 / 解码错位"这类真错。
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
	NetBus.rpc_id(1, "claim_role", role_assign, PvpSession.player_name)

func _physics_process(_delta: float) -> void:
	if not _match_started:
		return   # 连大厅阶段不发输入、不计帧
	_frames += 1
	# create:先右移(1..240帧),再开火(241帧起)。join:站着不动。
	if role == "create":
		var held := 0
		var pressed := 0
		var released := 0
		var ax := 1.0
		if _frames > 240:
			# ★ 开火必须能覆盖**任何**武器。服务器发给这个角色的是**随机**一把,而
			#   `m82a1` 与榴弹发射器是 **heavy_aim**(按住预瞄、**松开**才发射)——
			#   只发 held/pressed、从不发 released 的话,拿到这两把就**一枪都不开**,
			#   join 端永远等不到 bullet_spawn。实测:强制发 m82a1 → 必红,发手枪 → 必绿。
			#   按下 20 帧 / 松开 10 帧的循环同时对三种武器都成立:
			#   full_auto 连发、半自动吃 pressed 边沿、heavy_aim 吃 released 边沿。
			var cyc := (_frames - 240) % 30
			if cyc < 20:
				held = PacketInputSource.BIT_ATTACK
				if cyc == 0:
					pressed = PacketInputSource.BIT_ATTACK
			elif cyc == 20:
				released = PacketInputSource.BIT_ATTACK
		_sent_seq += 1
		var rec := {
			"seq": _sent_seq,   # C2:单调输入序号(服务器 ack 依据;一条记录 = 1 tick)
			"ax": ax,
			"held": held,
			"pressed": pressed,
			"released": released,
			"winst": 0,
			"aim": Vector2(1, 0),
			# 两个只落位的扩展字段(本批无消费者);冒烟手工组包,给 0 即可。
			"st": 0,
			"ct": 0,
		}
		# U1:30Hz 一包两条 tick 记录(流水线:上一 tick + 本 tick);服务器每 tick 消费一条。
		if _frames % 2 == 0 and not _prev_rec.is_empty():
			var pair := PacketInputSource.pack_pair(_prev_rec, rec, Vector2(1, 0), 0, 0)
			NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pair))
		_prev_rec = rec
	# 成功判定
	if role == "create":
		# 多打一会儿(到 ~480 帧)再退:帧>240 只够开火但不够 bullet 广播到 join 端,提前 quit 会触发「中途断线拆房」→ join 永远等不到 bullet_spawn。
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
