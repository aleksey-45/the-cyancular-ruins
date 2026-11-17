extends Node


const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const WORKER_PORT_OUT := 29350
const POOL_LOW := 7800
const POOL_HIGH := 8300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0
const MIN_CHECKS := 5

var _role := "lobby"
var _rm: Node = null
var _t := 0.0
var _stage := 0
var _done := false
var _child_pids: Array[int] = []
var _failures: Array[String] = []
var _notes: Array[String] = []
var _worker_port := 0
var _room_code := ""
var _start_t := 0.0
var _room_seen := false
var _checks := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--who="):
			_role = a.trim_prefix("--who=")
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


func _run_orchestrator() -> void:
	var err := NetBus.start_server(LOBBY_PORT)
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(端口 %d 被占?本探针不占 7777)" % [err, LOBBY_PORT])
		get_tree().quit(1)
		return
	_rm = RoomManager.new()
	add_child(_rm)
	_rm.get("_launcher").set("_next_port", WORKER_PORT_OUT)
	if not _clean():
		print("PROBE: 清理失败(多半是上一跑的进程还活着)—— 不拉起客户端,直接退出")
		get_tree().quit(1)
		return
	print("PROBE: 大厅就绪(port %d,池外);worker 起投 %d" % [LOBBY_PORT, WORKER_PORT_OUT])
	_spawn_client("c1")
	_spawn_client("c2")
	_spawn_client("c3")


func _spawn_client(who: String) -> void:
	var argv := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who),
			"res://tests/e2e/rejoin_probe.tscn", "--", "--who=" + who])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	if pid > 0:
		_child_pids.append(pid)
	print("PROBE: 拉起客户端 %s(pid=%d)" % [who, pid])


func _process(delta: float) -> void:
	if _role != "lobby" or _done:
		return
	_t += delta
	if _t > FINAL_TIMEOUT:
		_finish("超时(%.0fs;阶段 %d)\n%s" % [FINAL_TIMEOUT, _stage, _dump()])
		return
	match _stage:
		0:
			_stage_room()
		1:
			_stage_started()
		2:
			_stage_collect()


func _stage_room() -> void:
	if _rm == null or _rm.lobby.rooms.is_empty():
		if _t > BOOT_TIMEOUT:
			_finish("%.0fs 内没有 1v1 房(c1 没建成?)\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	_room_code = str(_rm.lobby.rooms.keys()[0])
	var room = _rm.lobby.rooms[_room_code]
	if room.players.size() < 2 or room.worker_port <= 0:
		if _t > BOOT_TIMEOUT:
			_finish("房 %s 一直没配对(players=%d port=%d)\n%s"
					% [_room_code, room.players.size(), room.worker_port, _dump()])
		return
	_worker_port = int(room.worker_port)
	_check(_worker_port < POOL_LOW or _worker_port >= POOL_HIGH,
			"相① worker 端口 %d 落在真大厅的端口池 [%d,%d) 之外" % [_worker_port, POOL_LOW, POOL_HIGH])
	print("PROBE: 房 %s 配对完成 → worker 端口 %d(t=%.1fs)" % [_room_code, _worker_port, _t])
	_stage = 1


func _stage_started() -> void:
	if _room_code == "" or not _rm.lobby.rooms.has(_room_code):
		_finish("房 %s 消失了(开局那一刻不该被拆 —— 那正是显示方案要改掉的旧行为)" % _room_code)
		return
	var room = _rm.lobby.rooms[_room_code]
	if not room.started:
		if _t > BOOT_TIMEOUT + 10.0:
			_finish("房 %s 一直没开局(worker 没起来?)\n%s" % [_room_code, _dump()])
		return
	if not _room_seen:
		_room_seen = true
		_start_t = _t
		var row := _find_row(_rm.lobby.room_list_payload(), _room_code)
		_check(not row.is_empty(), "相② ★ 开局后房**仍在**房间列表里(旧实现此刻已拆房 → C 什么都看不见)")
		if not row.is_empty():
			_check(bool(row.get("in_match", false)), "相② 列表行带 in_match=true")
			_check(row.get("names", []) == ["BOT1", "BOT2"],
					"相② ★ 名单取自冻结的那份(实得 %s)" % str(row.get("names", [])))
			_check(int(room.worker_pid) > 0, "相② ★ spawn 成功后登记了 worker pid(回收判据的输入)")
		print("PROBE: 房 %s 已开局(t=%.1fs),等三端结果" % [_room_code, _t])
	_stage = 2


func _stage_collect() -> void:
	if _results_ready() >= 3 or _t - _start_t > RESULT_WAIT:
		_finish("" if _results_ready() >= 3 else "只收到 %d/3 份客户端结果" % _results_ready())


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if _child_pids.is_empty():
		_check(false, "没有子进程 → 跨端断言一条都没跑(这一跑不判通过)")
	for who in ["c1", "c2", "c3"]:
		var txt := _read_result(who)
		if txt == "":
			_check(false, "%s 没写出结果文件" % who)
		elif txt.begins_with("OK"):
			_notes.append("%s: %s" % [who, txt.split("\n")[0]])
		else:
			_check(false, "%s: %s" % [who, txt.split("\n")[0]])
	if why != "":
		_check(false, why)
	if _failures.is_empty() and _checks < MIN_CHECKS:
		_check(false, "只跑了 %d 条断言(期望 ≥ %d)—— 有阶段没跑到,这个 ALL-OK 不算数"
				% [_checks, MIN_CHECKS])
	_kill_children()
	print("═══ 探针明细 ═══")
	for n in _notes:
		print("  · " + n)
	for f in _failures:
		print("  ✗ " + f)
	if _failures.is_empty():
		print("REJOIN PROBE: ALL-OK(%d 条断言)" % _checks)
	else:
		print("REJOIN PROBE: %d 条失败(跑了 %d 条断言)" % [_failures.size(), _checks])
		print(_dump())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  OK  %s" % msg)
	else:
		_failures.append(msg)
		print("  FAIL %s" % msg)


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}


func _results_ready() -> int:
	var n := 0
	for who in ["c1", "c2", "c3"]:
		if _read_result(who) != "":
			n += 1
	return n


func _kill_children() -> void:
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	if _worker_port > 0:
		ProcUtil.kill_udp_port(_worker_port)


func _log_path(kind: String, who: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s_%s.godotlog" % [PREFIX, kind, who])


func _godot_log_path(who: String) -> String:
	return _log_path("client", who)


func _worker_log_path() -> String:
	if _rm == null or _worker_port <= 0:
		return ""
	return str(_rm.get("_launcher").call("log_path", _worker_port))


func _read(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _read_result(who: String) -> String:
	return _read(ProjectSettings.globalize_path("user://%s%s.result" % [PREFIX, who])).strip_edges()


func _tail(path: String, n: int = 20) -> String:
	var lines := _read(path).split("\n")
	if lines.size() <= n:
		return "\n".join(lines)
	return "…(前 %d 行省略)\n" % (lines.size() - n) + "\n".join(lines.slice(lines.size() - n))


func _dump() -> String:
	var out := ""
	for who in ["c1", "c2", "c3"]:
		out += "  [%s 引擎日志]\n%s\n" % [who, _tail(_godot_log_path(who))]
	out += "  [worker 日志]\n%s\n" % _tail(_worker_log_path())
	return out


# 开工前清掉上一跑的产物(结果文件与引擎日志)。★ 删除必须看返回值(理由见 reconnect_probe 的同名函数:残留进程攥着同名文件时删除会失败,
#   而失败被忽略的后果是「新进程截断、残留进程按旧偏移续写」→ 日志里出现空洞与陈旧行,人会照着这些行做错误归因)。
func _clean() -> bool:
	var ok := true
	for who in ["c1", "c2", "c3"]:
		for p in [ProjectSettings.globalize_path("user://%s%s.result" % [PREFIX, who]),
				_godot_log_path(who)]:
			if not FileAccess.file_exists(p):
				continue
			if DirAccess.remove_absolute(p) != OK:
				ok = false
				push_warning("PROBE: 删不掉上一跑的 %s —— 多半是上一跑的进程还活着" % p)
	return ok


func _run_client() -> void:
	var w: Node = load("res://tests/harness/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
