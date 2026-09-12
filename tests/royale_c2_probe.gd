extends Node

# 大乱斗 C2(客户端预测 + 权威锚定重放)的**运行时验收探针**。场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
#   (无参 = 大厅/裁判进程;它自己拉起两个客户端子进程。**跑前先确认 7777 空闲**。)
# 判据:裁判进程末行 `PROBE: ALL-OK` + 两个结果文件都是 OK(不能只看退出码)。
#
# ═══ 为什么需要它(批次 5 的验收线)═══
# 设计 §5 批次 5 的验收是「大乱斗客户端的 rollback_count() 斜率与 1v1 同量级」,而**读数必须来自
# 真链路** —— 只有真大厅 + 真 worker + 真 `royale_game` 客户端才跑得到 reconcile 那一段。
# 光靠源码级扫描(「royale_game.gd 里有没有那几行」)是本仓被抓过四次的「假绿」形态:
# 接线写对了但没生效时,扫描器照样绿。
#
# ═══ 分歧怎么**确定性**地造出来(本探针的关键设计)═══
# C2 的分歧来自「服务器外部事件」——客户端不可预测的那一类。大乱斗里**必然发生**的一次是:
#   c1 按 K 自杀 → 服务器校验通过后执行 force_down → 2s 后**复活并瞬移回出生点**。
# 这次瞬移客户端不可预测,于是:
#   · reconcile 正常 → 本地玩家被 restore+重放拉回出生点,与权威快照收敛(断言绿);
#   · reconcile 被删/没接 → 本地玩家永远停在倒地处、永远 downed(断言红)。
# 这就是设计里那条反证「删掉 reconcile() → 分歧不收敛,读数可见」的可执行形式。
#
# ⚠ 关于「K 自杀是不是广播的」(本探针设计的前提,见 royale_c2_watcher.gd 的 A②):
#   自杀的**请求**不广播(定向发给 worker,无回执);但**"谁死了/谁活着"确实广播**
#   (倒地边沿 → round_state,载荷带 alive)。C2 下**不许**消费它 —— 理由写在 A② 那条断言的注释里。
#
# 结果文件:user://royale_c2_probe_c{1,2}.result(客户端写)、user://royale_c2_probe_go.txt(房号)。
# 客户端子进程的 stdout 父进程看不到(Windows 不继承句柄)→ 各自落一份 .log,失败时打印。

const RESULT_PREFIX := "royale_c2_probe_"
const GO_FILE := "user://royale_c2_probe_go.txt"
const ORCH_DEADLINE := 90.0

var _role := "lobby"
var _c1_peer := 0
var _code := ""
var _stage := 0
var _created_t := -1.0
var _t := 0.0
var _room_mgr: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
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
		var p := "user://%s%s.result" % [RESULT_PREFIX, f]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(GO_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GO_FILE))
	NetBusExt.royale_create_requested.connect(_on_room_created)
	var exe := OS.get_executable_path()
	for role in ["c1", "c2"]:
		OS.create_process(exe, PackedStringArray(["--headless", "--path",
				ProjectSettings.globalize_path("res://"), "res://tests/royale_c2_probe.tscn",
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
				return   # 等 c2 加入(ROYALE_MIN_PLAYERS=2)
			_rm().royale_start(_c1_peer)   # 等价于房主点「开始游戏」→ 拉起 worker
			print("PROBE: 房内 2 人,已发起开局(拉起 worker 子进程)")
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


func _rm() -> Node:
	return _room_mgr


func _room_players() -> int:
	var rr = _rm().royale_rooms.get(_code)
	return rr.players.size() if rr != null else 0


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


# ── 客户端子进程:挂观察者 + 挂**真大厅场景**,再把它驱动起来 ──
# 观察者挂 root(不是探针场景里):真大厅 → 真 royale_game 的那次换场不会把它带走。
func _run_client() -> void:
	var lp := "user://%s%s.log" % [RESULT_PREFIX, _role]
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	var watcher: Node = load("res://tests/royale_c2_watcher.gd").new()
	watcher.who = _role
	watcher.lobby = load("res://scenes/royale_lobby.tscn").instantiate()
	# 本节点还在自己的 _ready 里(父级 root 正忙于装载子节点)→ 两处 add_child 都得推迟到帧末
	get_tree().root.add_child.call_deferred(watcher)
	add_child.call_deferred(watcher.lobby)
	print("PROBE[%s]: 真大厅场景已挂载,等待连接 127.0.0.1" % _role)
