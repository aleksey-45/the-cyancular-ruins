extends Node

# 1v1 Bot 真链路探针:
#   裁判(lobby)= 本进程起真大厅(NetBus.start_server + RoomManager,池外端口),拉起 2 个客户端子进程;
#   客户端(c1/c2)= 真 mp_lobby → 真 pvp_game,由 bot_watcher 驱动。
# 判据:两个客户端结果文件都含 `BOT_1V1 OK`,裁判打印 `BOT 1V1 PROBE: ALL-OK`。
# 跑法:bash tests/probe/bot_1v1_probe.sh(或人工 --role=lobby + 另起 c1/c2)。

const LOBBY_PORT := 29400
const WORKER_PORT_OUT := 29450
const CLIENT_COUNT := 2
const FINAL_TIMEOUT := 240.0
const CHILD_QUIT_AFTER := "30000"

var _role := "lobby"
var _who := ""
var _idx := 1
var _rm: Node = null
var _child_pids: Array[int] = []
var _t := 0.0
var _done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--who="):
			_who = a.trim_prefix("--who=")
	_idx = int(_who.trim_prefix("c")) if _who.begins_with("c") else 1
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


func _run_orchestrator() -> void:
	var err := NetBus.start_server(LOBBY_PORT)
	if err != OK:
		print("BOT PROBE: 大厅监听失败 err=%d port=%d" % [err, LOBBY_PORT])
		get_tree().quit(1)
		return
	_rm = RoomManager.new()
	add_child(_rm)
	_rm.get("_launcher").set("_next_port", WORKER_PORT_OUT)
	_clean_results()
	print("BOT PROBE: 大厅就绪 port=%d(池外);拉起 %d 个客户端" % [LOBBY_PORT, CLIENT_COUNT])
	for i in range(1, CLIENT_COUNT + 1):
		_spawn_client(i)


func _spawn_client(i: int) -> void:
	var who := "c%d" % i
	var argv := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--quit-after", CHILD_QUIT_AFTER,
		"--log-file", ProjectSettings.globalize_path("user://bot_1v1_%s.log" % who),
		"res://tests/probe/bot_1v1_probe.tscn",
		"--", "--role=%s" % who, "--who=%s" % who, "--lobby-port=%d" % LOBBY_PORT,
	])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	if pid > 0:
		_child_pids.append(pid)
	print("BOT PROBE: 拉起 %s pid=%d" % [who, pid])


func _run_client() -> void:
	var w: Node = load("res://tests/harness/bot/bot_watcher.gd").new()
	w.set("who", _who)
	w.set("idx", _idx)
	w.set("lobby_port", LOBBY_PORT)
	get_tree().root.add_child.call_deferred(w)
	print("BOT PROBE[%s]: 客户端就绪" % _who)


func _process(delta: float) -> void:
	if _role != "lobby" or _done:
		return
	_t += delta
	if _results_ready() >= CLIENT_COUNT:
		_finish("")
		return
	if _t > FINAL_TIMEOUT:
		_finish("超时 %.0fs" % FINAL_TIMEOUT)


func _result_lines(who: String) -> Array:
	var path := "user://bot_1v1_%s.txt" % who
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out: Array = []
	while not f.eof_reached():
		var l := f.get_line()
		if not l.is_empty():
			out.append(l)
	return out


func _results_ready() -> int:
	var n := 0
	for i in range(1, CLIENT_COUNT + 1):
		if not _result_lines("c%d" % i).is_empty():
			n += 1
	return n


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	var ok := true
	var notes: Array[String] = []
	for i in range(1, CLIENT_COUNT + 1):
		var who := "c%d" % i
		var lines := _result_lines(who)
		if lines.is_empty():
			ok = false
			notes.append("%s: 无结果文件" % who)
			continue
		var client_ok := false
		for l in lines:
			if l.begins_with("BOT_1V1 OK"):
				client_ok = true
			if l.begins_with("BOT_1V1 "):
				notes.append("%s: %s" % [who, l])
		if not client_ok:
			ok = false
	print("BOT PROBE: 收尾 %s" % ("失败" if why != "" else "完成"))
	for n in notes:
		print("BOT PROBE: " + n)
	if ok and why == "":
		print("BOT 1V1 PROBE: ALL-OK")
	else:
		var head := why if why != "" else "客户端失败"
		print("BOT 1V1 PROBE: FAIL " + head)
	_kill_children()
	get_tree().quit(0 if ok and why == "" else 1)


func _kill_children() -> void:
	var killed := 0
	for pid in _child_pids:
		if OS.kill(pid):
			killed += 1
	_child_pids.clear()
	print("BOT PROBE: 按 PID 收尾 %d 个子进程" % killed)


func _clean_results() -> void:
	for i in range(1, CLIENT_COUNT + 1):
		var path := ProjectSettings.globalize_path("user://bot_1v1_c%d.txt" % i)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
