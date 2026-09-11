extends Node

# 大乱斗 **B1(role 空洞导致 claim 被踢)+ B2(开局三载荷跨场景丢失)** 的可证伪探针。
# 场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . res://tests/royale_bound_probe.tscn
#   (无参 = 大厅/裁判进程;它自己拉起两个客户端子进程。**跑前先确认 7777 空闲**。)
# 期望:末行 `PROBE: ALL-OK` + 两个客户端结果文件都是 OK;任一断言失败 → FAIL + 退出码 1。
#
# 与 tests/royale_probe.gd 的差别(本探针存在的理由):
#   · 它构造**带 role 空洞的房**:c1(role 1)→ 一个只在本进程存在的假 peer(role 2)→
#     c2(role 3)→ 假 peer 退出。房内成员数 2,而 c2 手持 **role 3** —— 正是 B1 的复现条件
#     (worker 早先用「成员数」当 role 上界,会把 c2 当串线踢掉,只剩 1 个 claim,超时梯走完
#     退出,两名客户端永久卡在「连接对局服务器超时」且无恢复路径)。
#   · 两个客户端进程驱动的是**真 royale_lobby.tscn**(真 `_on_match_start` 的帧末切场景、
#     真缓存/交接),换场后消费者是**真 royale_game.tscn** —— B2 的复现条件(那三条载荷
#     与 match_start 同一次 poll 到达时,新场景还不存在)。断言在换场**之后**读新场景的状态。
#   观察者常驻 root、跨换场存活,见 royale_bound_watcher.gd。
#
# 两种跑法:
#   1) 全链路(默认,无参):同一次 poll 由 ENet 是否合包决定,实测本机三条载荷落在 match_start
#      **下一帧**(新场景已建好,它自己的订阅也收得到)→ 该跑法证明的是"链路端到端通",
#      不能证伪"同一次 poll 会丢"。
#   2) 同一次 poll(确定性):`-- --payload`。在触发换场**之前**把三条载荷喂给真大厅的缓存
#      handler,再调真大厅的 _on_match_start → 载荷只能经 PvpSession 交接过去,没有第二次机会。
#      这一跑法才是 B2 的**可证伪**演示(关掉交接即红)。
# 中间/结果文件:user://royale_b12_probe_go.txt(房号)、user://royale_b12_probe_c{1,2}/payload.result。
# 用法: Godot_console --headless --path . res://tests/royale_bound_probe.tscn [-- --role=c1|c2 | --payload]

const RESULT_PREFIX := "royale_b12_probe_"
const GO_FILE := "user://royale_b12_probe_go.txt"
const FAKE_PEER := 4242        # 只在大厅进程内存在的假 peer(构造 role 空洞;它从不连接)
const INVITE := ""             # 公开房,加入不需要邀请码
const HUE_C1 := 90.0           # 两个客户端各自的本端角色色相(经 player_options 上报)
const HUE_C2 := 180.0
const DISABLED_SLOT := 3       # c1 建房时勾掉的武器槽(随房选项 → match_options 下发)
const ORCH_DEADLINE := 75.0

var _role := "lobby"
var _c1_peer := 0
var _code := ""
var _stage := 0
var _created_t := -1.0
var _t := 0.0
var _room_mgr: Node = null   # 大厅进程里那份 RoomManager(直接持有:add_child 返回的实例,不按名字找)
var _lobby: Node = null      # --payload 模式:注入载荷后要触发换场的那份真大厅
var _payload_done := false
var _payload_t := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a == "--payload":
			_role = "payload"
	if _role == "payload":
		_run_payload_case()
	elif _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


# ── B2 的**同一次 poll** 复现(确定性;不依赖 ENet 是否把四条包合成一个数据报)──
# 自然时序下(默认模式)三条载荷实测落在 match_start 的**下一帧**,那时新场景已建好、
# 它自己的订阅就收得到 —— 于是"同一次 poll 就丢"的路径在实测里不触发(见报告)。
# 本模式把那条路径**确定性地**造出来:在触发换场**之前**(同一次 poll 内)把三条载荷喂给
# 真大厅的缓存 handler,再调用真大厅的 _on_match_start(它帧末切场景)→ 载荷只能靠
# PvpSession 交接过去;若交接断了,消费者拿不到任何一条(无第二次机会)。
func _run_payload_case() -> void:
	var w: Node = load("res://tests/royale_bound_watcher.gd").new()
	w.who = "payload"
	w.mode = "wait"
	get_tree().root.add_child.call_deferred(w)
	_lobby = load("res://scenes/royale_lobby.tscn").instantiate()
	add_child.call_deferred(_lobby)
	print("PROBE: 同一次 poll 模式:载荷注入后立刻触发真大厅换场")


func _process(delta: float) -> void:
	if _role == "payload":
		_payload_step(delta)
	elif _role == "lobby":
		_orchestrator_step(delta)


func _payload_step(delta: float) -> void:
	_payload_t += delta
	if _payload_t > 40.0:
		print("PROBE: FAIL\n  注入阶段超时(大厅未就绪?)")
		get_tree().quit(1)
		return
	if _payload_done or _lobby == null or not is_instance_valid(_lobby) \
			or not _lobby.is_inside_tree():
		return
	_payload_done = true
	# 三条载荷:数值与两端在自然模式里上报的一致(色相/禁武器按 role 分别可见)
	NetBus.local_peer_info.emit({1: "P1", 3: "P3"})
	NetBusExt.local_peer_hues.emit({1: HUE_C1, 3: HUE_C2})
	NetBusExt.local_match_options.emit({"disabled_weapons": [DISABLED_SLOT], "round_full_heal": false})
	# 紧接着(同一次 poll 内)走真大厅的开局处理:它帧末切到真 royale_game
	_lobby.call("_on_match_start", 1, Vector2i(70, 66), "res://maps/factory1v1.cyrm")


# ── 客户端子进程:挂观察者 + 挂**真大厅场景**,再把它驱动起来 ──
# 本端选项(Settings)必须在**实例化真大厅之前**写好:建房页的武器勾选状态、role 上报的
# player_options(match_time/色相/禁用武器)都从 Settings 读。
func _run_client() -> void:
	Settings.pvp_disabled_weapons = [DISABLED_SLOT]
	Settings.pvp_color_hue = HUE_C1 if _role == "c1" else HUE_C2
	var lp := "user://%s%s.log" % [RESULT_PREFIX, _role]
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	var watcher: Node = load("res://tests/royale_bound_watcher.gd").new()
	watcher.who = _role
	# 本节点还在自己的 _ready 里(父级 root 正忙于装载子节点)→ 两处 add_child 都得推迟到帧末
	get_tree().root.add_child.call_deferred(watcher)   # 挂 root:换场不会把它带走
	watcher.lobby = load("res://scenes/royale_lobby.tscn").instantiate()
	add_child.call_deferred(watcher.lobby)   # 真大厅进树 → 它的 _ready 订阅/连接全是真路径
	print("PROBE[%s]: 真大厅场景已挂载,等待连接 127.0.0.1" % _role)


# ── 裁判:大厅服 + 假 peer 造空洞 + 拉起两个客户端子进程 + 收结果 ──
func _run_orchestrator() -> void:
	var err := NetBus.start_server()
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(7777 被占?)" % err)
		get_tree().quit(1)
		return
	_room_mgr = RoomManager.new()
	add_child(_room_mgr)
	for f in ["c1", "c2"]:
		var p := "user://%s%s.result" % [RESULT_PREFIX, f]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(GO_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GO_FILE))
	NetBusExt.royale_create_requested.connect(_on_room_created)
	var exe := OS.get_executable_path()
	if not OS.get_cmdline_user_args().has("--nospawn"):   # 调试用:不拉子进程,自己前台跑 role
		for role in ["c1", "c2"]:
			OS.create_process(exe, PackedStringArray(["--headless", "--path",
					ProjectSettings.globalize_path("res://"), "res://tests/royale_bound_probe.tscn",
					"--", "--role=" + role]))
	print("PROBE: 大厅就绪,c1/c2 已拉起")


func _on_room_created(caller: int, _opts: Dictionary) -> void:
	# 真大厅建完房:记下房主 peer 与房号,稍后(帧内不做事,避免在 poll 栈里改房态)
	_c1_peer = caller
	for code in _rm().royale_rooms:
		var rr = _rm().royale_rooms[code]
		if rr.host_peer == caller:
			_code = code
			break
	_created_t = _t

func _rm() -> Node:
	return _room_mgr


func _orchestrator_step(delta: float) -> void:
	_t += delta
	if _t > ORCH_DEADLINE:
		print("PROBE: 超时(%.0fs)FAIL c1=%s c2=%s\n%s" % [ORCH_DEADLINE, _read_result("c1"),
				_read_result("c2"), _client_logs()])
		get_tree().quit(1)
		return
	match _stage:
		0:
			if _created_t < 0.0 or _t - _created_t < 0.3:
				return
			# 假 peer(role 2)插在 c1 与 c2 之间加入 → 它退出后就留下 role 空洞 {1,3}
			_rm().royale_join(FAKE_PEER, _code, INVITE)
			print("PROBE: 假 peer %d 加入为 role 2(房 %s),c2 将拿到 role 3" % [FAKE_PEER, _code])
			var f := FileAccess.open(GO_FILE, FileAccess.WRITE)
			f.store_string(_code)
			f.close()
			_stage = 1
		1:
			if _room_players() < 3:
				return   # 等 c2 加入(c1 + 假 peer + c2)
			# 中间那位(role 2)退出 → 房里是 {1,3},成员数 2 < 最高 role 3(B1 的复现条件)
			_rm().royale_leave(FAKE_PEER)
			print("PROBE: 假 peer 退出 → 房内 role = %s(成员数 %d,最高 role %d)" % [
					str(_roles()), _room_players(), _max_role()])
			if _rm().royale_rooms.get(_code) == null:
				print("PROBE: 房 %s 不存在(假 peer 退出时被误关?)" % _code)
				get_tree().quit(1)
				return
			_rm().royale_start(_c1_peer)   # 等价于房主点「开始游戏」→ 拉起 worker
			_stage = 2
		2:
			var r1: String = _read_result("c1")
			var r2: String = _read_result("c2")
			if r1.begins_with("FAIL") or r2.begins_with("FAIL"):
				print("PROBE: FAIL\n  c1: %s\n  c2: %s\n%s" % [r1, r2, _client_logs()])
				get_tree().quit(1)
				return
			if r1.begins_with("OK") and r2.begins_with("OK"):
				print("PROBE: ALL-OK\n  c1: %s\n  c2: %s" % [r1, r2])
				get_tree().quit(0)
				return


func _room_players() -> int:
	var rr = _rm().royale_rooms.get(_code)
	return rr.players.size() if rr != null else 0

func _roles() -> Array:
	var rr = _rm().royale_rooms.get(_code)
	return rr.player_role.values() if rr != null else []

func _max_role() -> int:
	var m := 0
	for r in _roles():
		m = maxi(m, int(r))
	return m


func _read_result(who: String) -> String:
	var p := "user://%s%s.result" % [RESULT_PREFIX, who]
	if not FileAccess.file_exists(p):
		return "(未完成)"
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else "(读取失败)"


# 客户端子进程的 stdout 父进程看不到(Windows 不继承句柄)→ 读它们落盘的日志并打出来
func _client_logs() -> String:
	var out := ""
	for who in ["c1", "c2"]:
		var p := "user://%s%s.log" % [RESULT_PREFIX, who]
		if not FileAccess.file_exists(p):
			out += "  [%s 无日志]\n" % who
			continue
		var f := FileAccess.open(p, FileAccess.READ)
		out += "  [%s 日志]\n%s\n" % [who, f.get_as_text().strip_edges() if f != null else "(读取失败)"]
	return out
