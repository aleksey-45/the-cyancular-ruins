extends Node

# 大乱斗 **B1(role 空洞导致 claim 被踢)+ B2(开局三载荷跨场景丢失)** 的可证伪探针。
# 场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . res://tests/probe/royale_bound_probe.tscn
#   (无参 = 大厅/裁判进程;它自己启动两个客户端子进程。**跑前先确认 7777 空闲**。)
# 期望:末行 `PROBE: ALL-OK` + 两个客户端结果文件都是 OK;任一断言失败 → FAIL + 退出码 1。
#
# 与 tests/probe/royale_probe.gd 的差别(本探针存在的理由):
#   - 它构造**带 role 空洞的房**:c1(role 1)→ 一个只在本进程存在的假 peer(role 2)→
#     c2(role 3)→ 假 peer 退出。房内成员数 2,而 c2 手持 **role 3** —— 正是 B1 的复现条件
#     (worker 早先用「成员数」当 role 上界,会把 c2 当串线剔除断开,只剩 1 个 claim,超时梯走完
#     退出,两名客户端永久卡在「连接对局服务器超时」且无恢复路径)。
#   - 两个客户端进程驱动的是**真 mp_lobby.tscn**(真 `_on_match_start` 的帧末切场景、
#     真缓存/交接),换场后消费者是**真 royale_game.tscn** —— B2 的复现条件(那三条载荷
#     与 match_start 同一次 poll 到达时,新场景还不存在)。断言在换场**之后**读新场景的状态。
#   观察者常驻 root、跨换场存活,见 royale_bound_watcher.gd。
#
# 两种跑法:
#   1) 全链路(默认,无参):同一次 poll 由 ENet 是否合包决定,实测本机三条载荷落在 match_start
#      **下一帧**(新场景已建好,它自己的订阅也收得到)→ 该跑法证明的是"链路端到端通",
#      不能证伪"同一次 poll 会丢"。
#   2) 同一次 poll(确定性):`--payload`。在触发换场**之前**把三条载荷写入真实大厅缓存
#      handler,再调真大厅的 _on_match_start → 载荷只能经 PvpSession 交接过去,没有第二次机会。
#      这一跑法才是 B2 的**可证伪**演示(关掉交接即红)。
#
# ── §B2 结论(2026-10-03 定案;此前长期记为"客户端收不到 match_sync 应答")──
#   **载荷没丢。** 自然模式(纯生产路径、零插桩)实测 2/2 客户端都收得到 `match_sync_data`,
#   只是**晚**:换场 → 应答落地的**墙钟**间隔 = c1 5906ms / c2 3900ms(另两次跑 2.5s / 3.9s)。
#   成因两段:① 客户端换场那一刻要建整个 `royale_game`(Level0 世界 + 4527 个碰撞形状 + HUD),
#   主循环**卡住 ~8 秒**(f 走 30 帧而墙钟走 8.4 秒;探针环境里大厅 + worker + 两个客户端
#   共 4 个 Godot 抢 CPU,该值被放大);② 卡顿期内客户端不排空 UDP 收缓冲  ->  包被内核丢,
#   **可靠包靠 ENet 退避重传**  ->  客户端一恢复就整批涌进来(同一瞬间 `round_state` 计数
#   9→20,是同一现象的另一半证据)。worker 侧全程健康:收到请求即回、`rpc_id` 返回 0。
#    ->  旧写法 `const SETTLE := 2.0`(**探针的等待形状**)会在载荷到达之前就断言  ->  红。
#     已改成"等载荷落地 + 截止线"(见 royale_bound_watcher.gd 的 `SETTLE_AFTER_PAYLOAD`)。
#   ⚠ **前一轮"SERVER 回了 9 次、客户端 0 次收到"那个读数不可采信**:那一跑的主进程在
#     ~10s 就被杀了(编排器日志停在 f=539/t=9891ms),而本机上应答要 ~22s 才到  ->  读出 0 是
#     **观测窗太短**,不是丢包。-  教训:真链路探针的被杀与"真丢包"在读数上长得一样。
#   ⚠ **未测**:单客户端(生产形态)下那次卡顿有多长。本机读数(8s)含 4 进程争抢,生产应短得多;
#     但"换场卡顿会让可靠事件晚到数秒"这条**机制**本身是真的,别当成只存在于探针里。
# 中间/结果文件:user://royale_b12_probe_go.txt(房号)、user://royale_b12_probe_c{1,2}/payload.result。
# 用法: Godot_console --headless --path . res://tests/probe/royale_bound_probe.tscn [--role=c1|c2 | --payload]

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
var _full_t := -1.0
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
# 本模式把那条路径**确定性地**造出来:在触发换场**之前**(同一次 poll 内)把三条载荷传入
# 真大厅的缓存 handler,再调用真大厅的 _on_match_start(它帧末切场景)→ 载荷只能靠
# PvpSession 交接过去;若交接断了,消费者拿不到任何一条(无第二次机会)。
func _run_payload_case() -> void:
	var w: Node = load("res://tests/harness/royale_bound_watcher.gd").new()
	w.who = "payload"
	w.mode = "wait"
	get_tree().root.add_child.call_deferred(w)
	# 同 `_run_client`:真大厅 `_ready` 会按 `PvpSession.server_address` 自动连(云服默认)——
	# 本模式没有本地大厅,拨到 127.0.0.1 让那次连接**失败**即可,别去碰生产服务器。
	PvpSession.server_address = "127.0.0.1"
	_lobby = load("res://scenes/mp_lobby.tscn").instantiate()
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
	# - 批次 3 改法(按"教探针认新入口、别回退重构"的纪律):本条变体原先靠"**推**在切场景的
	#   同一次 poll 里到达 → 只能靠 PvpSession 交接活到新场景"来取得测试有效性。交接已删,那个
	#   时序前提也就不存在了 —— 现在测的是**拉**这一侧:先切场景(新场景 _ready 里会发请求),
	#   **再**把应答投给它。这正是拉与推的根本差别:推是"趁你在切场景时推过去"(订阅方还不存在),
	#   拉是"你建好了才要"(应答只会更晚到,时序不敏感)。
	#   ⚠ 覆盖边界(照实登记):这一条只验「新场景能把收到的 match_sync 应答应用上」;
	#     **请求那一半**(客户端确实发得出去、服务器确实应答)由 `royale_probe` 的真大厅+真 worker
	#     全链路覆盖 —— 那条**没有**轻量化,别把本变体当成它的替代。
	# 注意： 为什么必须在这里设 `_current_mode`:本变体**直接调**真大厅的 `_on_match_start`,
	#   而 `mp_lobby._enter_match_scene()` 现在**按 `_current_mode` 分派**场景
	#   ("" 那一支只 `push_error`、**不切场景** —— 那是刻意的加固,见该函数注释)。
	#   不设 = 模式停在空串  ->  只打一条红、永远等不到换场(旧 royale_lobby 是无条件切
	#   royale_game 的,所以这里从前不需要设)。
	_lobby.set("_current_mode", PvpSession.MODE_ROYALE)
	_lobby.call("_on_match_start", 1, Vector2i(70, 66), "res://maps/newfactory.cyrm")
	# - 应答不在这里发:本节点**就是 current scene**,换场会把它 free 掉,协程随之而死(实测踩过:
	#   应答一条都没发出去)。改由 watcher 发 —— 它挂在 root 上,换场带不走它(那正是它存在的理由)。


# ── 客户端子进程:挂观察者 + 挂**真大厅场景**,再把它驱动起来 ──
# 本端选项(Settings)必须在**实例化真大厅之前**写好:建房页的武器勾选状态、role 上报的
# player_options(match_time/色相/禁用武器)都从 Settings 读。
func _run_client() -> void:
	Settings.pvp_disabled_weapons = [DISABLED_SLOT]
	Settings.pvp_color_hue = HUE_C1 if _role == "c1" else HUE_C2
	# 注意： **必须把地址拨到本探针的大厅**(与 team_match_watcher / royale_c2_probe 相同机制)。
	#   生产默认是**云服**(`PvpSession.server_address` 初值 120.53.107.140),而真大厅页的
	#   地址框初值取的就是它、`_ready` 会自动连 —— 不拨这一行,两个客户端会**静默连云**
	#   (还在云上真建房),本进程的编排大厅一条 `玩家连入` 都收不到,只剩 75s 超时。
	#   症状与"c2 连不上"完全一样(实测:c1 连上云服并建房,c2 对云服连接失败)。
	PvpSession.server_address = "127.0.0.1"
	var lp := "user://%s%s.log" % [RESULT_PREFIX, _role]
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	var watcher: Node = load("res://tests/harness/royale_bound_watcher.gd").new()
	watcher.who = _role
	# 本节点还在自己的 _ready 里(父级 root 正忙于装载子节点)→ 两处 add_child 都得推迟到帧末
	get_tree().root.add_child.call_deferred(watcher)   # 挂 root:换场不会把它带走
	watcher.lobby = load("res://scenes/mp_lobby.tscn").instantiate()
	add_child.call_deferred(watcher.lobby)   # 真大厅进树 → 它的 _ready 订阅/连接全是真路径
	print("PROBE[%s]: 真大厅场景已挂载,等待连接 127.0.0.1" % _role)


# ── 裁判:大厅服 + 假 peer 造空洞 + 启动两个客户端子进程 + 收结果 ──
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
		# 诊断开关**转发**(与 worker_launcher 同一款):编排器带了 `--matchsync-diag` 才给
		# 客户端子进程也带 —— 否则客户端侧那处诊断打印不会亮(默认关、生产不带)。
		var diag := PackedStringArray()
		if OS.get_cmdline_user_args().has("--matchsync-diag"):
			diag.append("--matchsync-diag")
		# 子进程 stdout 父进程看不见(Windows 不继承句柄)→ 给客户端也落一份引擎日志,
		# 否则那条客户端侧诊断打印(`[matchsync-diag] 客户端收到…`)**无处可读**
		# (与 worker_launcher 落 `worker_<port>.log` 相同机制)。
		var logdir := ProjectSettings.globalize_path("user://logs")
		DirAccess.make_dir_recursive_absolute(logdir)
		for role in ["c1", "c2"]:
			var a := PackedStringArray(["--headless",
					"--log-file", logdir.path_join("probe_cli_%s.log" % role),
					"--path", ProjectSettings.globalize_path("res://"),
					"res://tests/probe/royale_bound_probe.tscn", "--", "--role=" + role])
			a.append_array(diag)
			OS.create_process(exe, a)
	print("PROBE: 大厅就绪,c1/c2 已拉起")


func _on_room_created(caller: int, _opts: Dictionary) -> void:
	# 真大厅建完房:记下房主 peer 与房号,稍后(帧内不做事,避免在 poll 栈里改房态)
	_c1_peer = caller
	for code in _rm().lobby.royale_rooms:
		var rr = _rm().lobby.royale_rooms[code]
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
			_rm().lobby.royale_join(FAKE_PEER, _code, INVITE, false)
			print("PROBE: 假 peer %d 加入为 role 2(房 %s),c2 将拿到 role 3" % [FAKE_PEER, _code])
			var f := FileAccess.open(GO_FILE, FileAccess.WRITE)
			f.store_string(_code)
			f.close()
			_stage = 1
		1:
			if _room_players() < 3:
				return   # 等 c2 加入(c1 + 假 peer + c2)
			# 注意： 先等**等待室状态广播**落地,再开局 —— 让时序更宽裕(真人房主不会在 c2 加入的
			#   同一帧就点「开始」):`LobbyRooms._flush_royale_state` 是 `call_deferred` 且发送前
			#   `await process_frame`,再判 `if rr.in_match: return`。
			#   - **订正(2026-10-03 实测):这条退路**不是**必需的** —— 把它改成 `wait=0`(直接开局)
			#   时,等待室广播**仍会在加入后约 1 帧到达**,`_on_room_state_royale` 照跑、
			#   `_current_mode` 照设。原先写的"否则 `_current_mode` 永远停在空串"是**虚的**,
			#   不是这条 0.6s 的真实成因。保留它只是让时序更宽裕,不修任何东西。
			#   (旧记录里"未加时 c2 日志 `_current_mode=「」`"未能复现,故按实测如实改写。)
			if _full_t < 0.0:
				_full_t = _t
				return
			if _t - _full_t < 0.6:
				return
			# 中间那位(role 2)退出 → 房里是 {1,3},成员数 2 < 最高 role 3(B1 的复现条件)
			_rm().lobby.royale_leave(FAKE_PEER)
			print("PROBE: 假 peer 退出 → 房内 role = %s(成员数 %d,最高 role %d)" % [
					str(_roles()), _room_players(), _max_role()])
			if _rm().lobby.royale_rooms.get(_code) == null:
				print("PROBE: 房 %s 不存在(假 peer 退出时被误关?)" % _code)
				get_tree().quit(1)
				return
			_rm().royale_start(_c1_peer)   # 等价于房主点「开始游戏」→ 启动 worker
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
	var rr = _rm().lobby.royale_rooms.get(_code)
	return rr.players.size() if rr != null else 0

func _roles() -> Array:
	var rr = _rm().lobby.royale_rooms.get(_code)
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


# 客户端子进程的 stdout 父进程看不到(Windows 不继承句柄)→ 读它们落盘的日志并打印输出
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
