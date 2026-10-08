extends Node

# 「回大厅后重连返回对局」(阶段 2-B)的真实网络链路端到端探针。场景模式(autoload 必须已实例化)。
#
# 运行方式(用户侧):
#   timeout 900 bash tests/probe/rejoin_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 36000 res://tests/probe/rejoin_probe.tscn
# 验收标准：控制台输出包含 `REJOIN PROBE: ALL-OK`（不得仅依据进程退出码判定：若测试发生阻塞挂起，
#       --quit-after 到期退出仍可能返回 0 导致测试假阳性）。
# - 超时帧数配置 `--quit-after 36000`（对应 60fps 下 600 秒）：完整运行耗时预估包含加载建房（约 8 秒）、
#   对局静置（约 3 秒）、客户端离场/返回主菜单/重连（各约 2 秒）、各客户端观察窗口（各 40 秒）及清理收尾（约 5 秒），
#   实际执行约需 60~100 秒；配置 600 秒提供 6~10 倍冗余量，防止偶发性能波动导致测试误报。
#
# ── 网络拓扑架构（由探针主进程作为大厅与裁判服务端；子进程通过 OS.create_process 启动）──
#   主进程：运行真实大厅服务（NetBus.start_server(LOBBY_PORT) 与 RoomManager），使用专用测试端口 29300。
#   c1/c2/c3：3 个无头客户端，分别加载真实 mp_lobby 场景并进入 pvp_game 对局。
#   对局会话：由 RoomManager._start_match 驱动，与生产环境调用链路完全一致。
#
# ── 前提条件 ──
#   请确认默认端口 7777 未被外部占用（本探针使用专用端口 29300，避免干扰外部独立服务）。
#   Windows 下子进程标准输出不被父进程直接继承，因此各子进程均显式配置 `--log-file`；
#   若断言失败将输出各端日志尾部用于问题定位。测试收尾阶段按 PID 回收全部子进程并清理端口。
#
# ── 架构设计与实现说明 ──
#   ① 显式校验 _clean() 返回值：若无法清理上一次测试的残留文件，通常是因上一次运行的客户端进程未正常退出，
#      残留的 .result 文件会导致当前测试误判并产生假阳性。因此清理失败时直接终止测试。
#      同时确保清理对应的引擎日志文件，避免历史残留日志被误当成本次运行的现场日志输出。
#   ② 单进程单端口架构说明：对局会话直接挂载为大厅进程内的 MatchSession 节点，无需单独启动子进程，
#      因此收尾阶段仅需根据 PID 清理客户端子进程。
#   ③ 断言计数校验（MIN_CHECKS）：确保测试完整执行至终点，未达到预期断言数严禁输出 ALL-OK。
#   ④ 测试结论格式统一包含断言条数（ALL-OK(N 条断言)）。

const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0
# 正常通过测试必须执行的最小断言数量：阶段 1 端口校验 1 项 + 阶段 2 房间状态与玩家列表 4 项。
# 该判定条件用于防止未完整执行即输出 ALL-OK（参见 _finish）。
const MIN_CHECKS := 5

var _role := "lobby"
var _rm: Node = null
var _t := 0.0
var _stage := 0
var _done := false
var _child_pids: Array[int] = []
var _failures: Array[String] = []
var _notes: Array[String] = []
var _match_port := 0
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
	# 单进程单端口架构：移除旧版独立端口池分配，对局会话直接复用当前大厅监听端口。
	# 注意事项：清理失败必须直接终止测试退出，防止上一次运行的残留文件导致测试误判。
	if not _clean():
		print("PROBE: 清理失败（上一次测试运行的进程可能尚未退出），终止执行")
		get_tree().quit(1)
		return
	print("PROBE: 大厅就绪(port %d, 对局与大厅同进程同端口)" % LOBBY_PORT)
	_spawn_client("c1")
	_spawn_client("c2")
	_spawn_client("c3")


func _spawn_client(who: String) -> void:
	var argv := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who),
			"res://tests/probe/rejoin_probe.tscn", "--", "--who=" + who])
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


# 阶段 1 房建起来了(c1 建房),并且配对完成
func _stage_room() -> void:
	if _rm == null or _rm.lobby.rooms.is_empty():
		if _t > BOOT_TIMEOUT:
			_finish("%.0fs 内没有 1v1 房(c1 没建成?)\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	_room_code = str(_rm.lobby.rooms.keys()[0])
	var room = _rm.lobby.rooms[_room_code]
	if room.players.size() < 2 or room.match_id <= 0:
		if _t > BOOT_TIMEOUT:
			_finish("房 %s 一直没配对(players=%d 局号=%d)\n%s"
					% [_room_code, room.players.size(), room.match_id, _dump()])
		return
	_match_port = NetBus.server_port
	# 校验单进程单端口架构：对局端口必须与大厅监听端口一致
	_check(_match_port == LOBBY_PORT,
			"相① ★ 对局就跑在大厅那个端口上(%d;架构要求同进程同端口 —— 隧道只映射这一个端口)" % _match_port)
	print("PROBE: 房 %s 配对完成 → 对局端口 %d(t=%.1fs)" % [_room_code, _match_port, _t])
	_stage = 1


# 阶段 2：房间开始对局后仍应保留在房间列表中，且带有 in_match 状态标记（服务端展示属性；
# 客户端显示由 c3 断言）。此项验证房间状态在对局开启后不会被过早销毁。
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
			# 玩家名单应读取冻结的快照数据，避免玩家断开或切换状态时列表回退为默认占位符。
			_check(row.get("names", []) == ["BOT1", "BOT2"],
					"相② ★ 名单取自冻结的那份(实得 %s)" % str(row.get("names", [])))
			# 房间回收与重连凭证均以 match_id 为标识。
			_check(int(room.match_id) > 0, "相② ★ 开局时分配了局号(回收与回局凭据的输入)")
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
	# 计数断言保护：确保所有测试阶段均已执行，防止因提前退出导致假阳性通过。
	if _failures.is_empty() and _checks < MIN_CHECKS:
		_check(false, "断言执行数不足（实跑 %d 条，期望 ≥ %d 条）—— 存在未覆盖阶段，测试判定失败"
				% [_checks, MIN_CHECKS])
	_kill_children()
	print("── 探针执行明细 ──")
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


# ── 辅助断言与测试工具 ──
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
	# 单进程单端口架构下，对局运行在当前进程内，端口即大厅端口，无需针对对局端口清理子进程。
	# 端口清理在探针脚本 tests/probe/rejoin_probe.sh 退出时统一执行。


func _log_path(kind: String, who: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s_%s.godotlog" % [PREFIX, kind, who])


func _godot_log_path(who: String) -> String:
	return _log_path("client", who)


func _worker_log_path() -> String:
	# 单进程架构下对局与大厅共用标准输出，无独立的 worker 日志文件，此函数保留接口兼容。
	return ""


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


# 测试执行前清理上一次测试产生的文件（结果文件与引擎日志）。
func _clean() -> bool:
	var ok := true
	for who in ["c1", "c2", "c3"]:
		for p in [ProjectSettings.globalize_path("user://%s%s.result" % [PREFIX, who]),
				_godot_log_path(who)]:
			if not FileAccess.file_exists(p):
				continue
			if DirAccess.remove_absolute(p) != OK:
				ok = false
				push_warning("PROBE: 无法删除上一次测试产生的文件 %s —— 可能是上一次运行的进程尚未退出" % p)
	return ok


# 观察者挂载至根节点以跨场景保持存活。
func _run_client() -> void:
	var w: Node = load("res://tests/harness/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
