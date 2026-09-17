extends Node

# 局内「捡枪 / 丢枪」的**真链路**探针(场景模式:真大厅 + 真 worker + 两个真 royale_game 客户端)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport
#   (无参 = 大厅/裁判进程;它自己拉起两个客户端子进程。**跑前先确认 7777 空闲**。)
#
# ⚠ `-- --test-ground-teleport` **要带上**:它经大厅转发给 worker,让服务器每帧保证
#   "每个站着的玩家脚下 64px 内有一把**捡得动**的枪"(见 MatchGround.test_ground_teleport)。
#   不带的话探针仍能跑,但机器人必须自己走过去 —— 实测那条路在两轮里都没跑满轮数:
#   只会"水平走 + 卡住跳"的机器人在随机地图的窄台上会永久卡死。**开关必须写在 `--` 之后**
#   (worker_launcher 读的是 `OS.get_cmdline_user_args()`;写在前面会被 Godot 丢掉、静默失效)。
# 判据:裁判进程末行 `PROBE: ALL-OK` + 两个结果文件都是 OK(不能只看退出码)。
#
# ═══ 为什么非要有它 ═══
# 用户 2026-09-16 报「1v1 / 大乱斗里捡武器会崩溃」。把链路摊开,每一段各自都有单元级覆盖:
#   · 服务器权威裁决 / 地面表增删 → `tests/ground_action_probe.tscn`(绿)
#   · 客户端删节点 / 权威背包变化后 restore → `tests/ground_client_probe.tscn`(绿)
# 而**崩溃发生在把这两半接起来的那条真链路上** —— 上行 F/Q 边沿 → worker 裁决 →
# `weapon_spawned`/`weapon_removed` 回传 → 客户端删/建节点 → 快照 c2 改背包 →
# C2 reconcile 重放。这条只有真大厅 + 真 worker + 真 royale_game 跑得到。
#
# ═══ 「丢 → 走过去 → 捡」为什么是确定性的 ═══
# 开局服务器给**每个玩家发一把枪**(`MatchGround._setup_ground_weapons`),所以第一个周期
# 一定有东西可丢;丢弃落点由 `PlayerParams` 的固定初速决定(约在身前 150px,超出 64px 的
# 拾取半径,所以要走过去)。观察者按**客户端自己的地面武器表**导航,不依赖任何地图假设。
# 每个动作的成败都由**真事件**判定(weapon_spawned / weapon_removed 到达),不靠"没报错"。
# 详见 tests/ground_net_watcher.gd 的文件头。
#
# ⚠ 客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 各自写一份
#   `--log-file`,失败时连同观察者日志一起打印。

const RESULT_PREFIX := "ground_net_probe_"
const GO_FILE := "user://ground_net_probe_go.txt"
const ORCH_DEADLINE := 120.0

var _role := "lobby"
var _mode := "royale"            # "royale" / "duel"(见 ground_net_watcher.MODES)
var _scene := "L1"               # 剧本名(见 tests/ground_scenarios.gd)
var _c1_peer := 0
var _code := ""
var _stage := 0
var _created_t := -1.0
var _t := 0.0
var _room_mgr: Node = null


func _ready() -> void:
	# ★ 本探针自己的开关写成 `=` 形式(与既有的 `--role=` 一致);**服务器 worker 的开关**
	#   (`--port P` / `--roles a,b` / `--test-*`)是空格分词 —— 两处风格不同是现状,别"统一"。
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--mode="):
			_mode = a.trim_prefix("--mode=")
		elif a.begins_with("--scene="):
			_scene = a.trim_prefix("--scene=")
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


# ── 裁判:起大厅 + 拉起 c1/c2 子进程 + 等两人进房后开局 + 收结果 ──
func _run_orchestrator() -> void:
	var err := NetBus.start_server()
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(7777 被占?)" % err)
		get_tree().quit(1)
		return
	_room_mgr = RoomManager.new()
	add_child(_room_mgr)
	for f in ["c1", "c2"]:
		for suffix in ["result", "log", "godotlog"]:
			var p := "user://%s%s.%s" % [RESULT_PREFIX, f, suffix]
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(GO_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GO_FILE))
	if _mode == "royale":
		NetBusExt.royale_create_requested.connect(_on_room_created)
	var exe := OS.get_executable_path()
	if OS.get_cmdline_user_args().has("--nospawn"):
		print("PROBE: --nospawn:不拉子进程,请另起两个 `-- --role=c1` / `-- --role=c2`")
		return
	# `-- --render`:客户端子进程**不带 --headless**(真开窗、真渲染)。用户报的崩溃出现在
	# **导出 exe**(有窗口)上,而 headless 跑的是"无渲染"的那半条管线 —— 渲染侧(RID/贴图/
	# SubViewport 析构)那类问题只有这一档照得出来。默认关(CI/无显示环境用)。
	var render := OS.get_cmdline_user_args().has("--render")
	for role in ["c1", "c2"]:
		# ★ `--log-file` 不能省:客户端子进程的 stdout/stderr 父进程看不到(Windows
		#   CreateProcess 不继承句柄),没有它就只能看到"进程没了、结果文件也没写"。
		var args := PackedStringArray()
		if not render:
			args.append("--headless")
		args.append_array(["--path", ProjectSettings.globalize_path("res://"),
				"--log-file", _godot_log_path(role),
				"res://tests/ground_net_probe.tscn", "--", "--role=" + role,
				"--mode=" + _mode, "--scene=" + _scene])
		OS.create_process(exe, args)
	print("PROBE: 大厅就绪(%s / %s),c1/c2 已拉起" % [_mode, _scene])
	# ★ 1v1 是**配对即开局**:没有「开始游戏」按钮、没有 `royale_create_requested`,
	#   也不需要 GO 文件(c2 自己从大厅房间列表里找)。所以阶段 0/1 整段跳过。
	if _mode == "duel":
		_stage = 2


func _on_room_created(caller: int, _opts: Dictionary) -> void:
	_c1_peer = caller
	for code in _rm().lobby.royale_rooms:
		var rr = _rm().lobby.royale_rooms[code]
		if rr.host_peer == caller:
			_code = code
			break
	_created_t = _t


func _process(delta: float) -> void:
	if _role != "lobby":
		return
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
			var f := FileAccess.open(GO_FILE, FileAccess.WRITE)
			f.store_string(_code)
			f.close()
			print("PROBE: 房 %s 已建(c1 peer=%d),等 c2 进房" % [_code, _c1_peer])
			_stage = 1
		1:
			if _room_players() < 2:
				return
			_rm().royale_start(_c1_peer)
			print("PROBE: 房内 2 人,已发起开局(拉起 worker 子进程)")
			_stage = 2
		2:
			var r1: String = _read_result("c1")
			var r2: String = _read_result("c2")
			# ★ 必须**两边都出结果**才收工:两个客户端是并发的,任何一个先退都会改变另一个的
			#   处境(大乱斗「剩余 <2 人即终局」会把对面的循环当场掐掉)。一见到 FAIL 就 quit
			#   = 让先失败的那个把还没跑完的那个带下水,报告里只留一个 `(未完成)`。
			if _has_result(r1) and _has_result(r2):
				var ok := r1.begins_with("OK") and r2.begins_with("OK")
				print(("PROBE: ALL-OK" if ok else "PROBE: FAIL") + "\n  c1: %s\n  c2: %s" % [r1, r2])
				if not ok:
					print(_client_logs())
				get_tree().quit(0 if ok else 1)


func _rm() -> Node:
	return _room_mgr


func _godot_log_path(role: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s.godotlog" % [RESULT_PREFIX, role])


func _room_players() -> int:
	var rr = _rm().lobby.royale_rooms.get(_code)
	return rr.players.size() if rr != null else 0


func _read_result(who: String) -> String:
	var p := "user://%s%s.result" % [RESULT_PREFIX, who]
	if not FileAccess.file_exists(p):
		return "(未完成)"
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else "(读取失败)"


func _has_result(r: String) -> bool:
	return r.begins_with("OK") or r.begins_with("FAIL")


# 客户端子进程的 stdout 父进程看不到 → 读两样落盘的东西打出来:
# ① 观察者自己写的 .log(阶段轨迹);② 引擎的 .godotlog(print + 所有 ERROR/SCRIPT ERROR)。
func _client_logs() -> String:
	var out := ""
	for who in ["c1", "c2"]:
		for suffix in ["log", "godotlog"]:
			var p := "user://%s%s.%s" % [RESULT_PREFIX, who, suffix]
			var head := "[%s 观察者日志]" % who if suffix == "log" else "[%s 引擎日志]" % who
			if not FileAccess.file_exists(p):
				out += "  %s (无)\n" % head
				continue
			var f := FileAccess.open(p, FileAccess.READ)
			var body: String = f.get_as_text().strip_edges() if f != null else "(读取失败)"
			if suffix == "godotlog":
				body = _tail_lines(body, 30)
			out += "  %s\n%s\n" % [head, body]
	return out


func _tail_lines(text: String, n: int) -> String:
	var lines := text.split("\n")
	if lines.size() <= n:
		return text
	return "…(前 %d 行省略)\n" % (lines.size() - n) + "\n".join(lines.slice(lines.size() - n))


# ── 客户端子进程:挂观察者 + 挂真大厅场景,再把它驱动起来 ──
func _run_client() -> void:
	var lp := "user://%s%s.log" % [RESULT_PREFIX, _role]
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	var watcher_script = load("res://tests/ground_net_watcher.gd")
	var watcher: Node = watcher_script.new()
	watcher.who = _role
	watcher.mode = _mode
	watcher.scene = _scene
	get_tree().root.add_child.call_deferred(watcher)
	# ★ 大厅走**游戏自己的换场景栈**(`change_scene_to_file`),不是 `add_child` 到探针场景下。
	#   两条理由:
	#   ① 与生产/导出形态同一条路 —— 那条通道(`-- --autotest-*`)本来就没有裁判进程,
	#      客户端只能自己切场景;让探针/导出两种形态共用一套驱动,才谈得上"同一把尺子"。
	#   ② 实测:`add_child` 那条路在 1v1 下会让 `NetBus` 的大厅 RPC 全部栽在
	#      "rpc node checksum failed"(房间建不出来),而大乱斗侧不受影响 —— 原因未定,
	#      但换回游戏自己的栈之后这条差异整个消失。
	#   ★ 观察者仍挂在 `root` 上(跨换场存活),它靠 `get_tree().current_scene` 认这份大厅。
	get_tree().call_deferred("change_scene_to_file", str(watcher_script.MODES[_mode]["lobby_scene"]))
	print("PROBE[%s]: 切到大厅场景(%s),等待连接 127.0.0.1" % [_role, _mode])
