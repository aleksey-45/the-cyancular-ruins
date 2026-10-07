extends Node

# 「回大厅后回局」(阶段 2-B)的**真实网络链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法(用户侧):
#   timeout 900 bash tests/probe/rejoin_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 36000 res://tests/probe/rejoin_probe.tscn
# 判据:**文本 `REJOIN PROBE: ALL-OK`**(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# - `--quit-after 36000`(=600s @60fps)的**推导**:本跑的量级 = 进局 ~8s + PLAYING 静置 ~3s
#   + 离场/主菜单/回局各 ~2s + c2 的观察窗 40s + c3 的 40s 窗口 + 收尾 ~5s ≈ **60~100s**;
#   取 600s = 6~10 倍余量。-  本仓教训:安全网给薄了会把"跑得慢"读成"功能坏了"
#   (`tests/probe/brawl_rollback_probe.tscn` 就是被 3600 误判过的那一个,实测要 30000),故这里按量级
#   给足而不是照抄别处的数。
#
# ═══ 拓扑(自当大厅/裁判;全部子进程由本进程 `OS.create_process` 直接启动)═══
#   本进程 = **实际大厅**(`NetBus.start_server(LOBBY_PORT)` + `RoomManager`),不进 7777
#   c1/c2/c3 = 3 个 headless 客户端,各自跑**真** `mp_lobby` → **真** `pvp_game`
#   worker = 由**真** `RoomManager._start_match` 经 `WorkerLauncher.spawn_worker` 启动
#            (与生产逐字同一条路径;探针只把起投端口拨到池外)
#
# ═══ 前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本探针不占 7777,也别终止用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 每个子进程都带
#   `--log-file`;失败时把每份引擎日志的尾部一起打印。收尾**按 PID 杀**全部子进程 + 按端口保底处理。
#
# ═══ -  与 task-8-brief.md 的偏离(逐条;理由都在实现处再写一遍)═══
#   ① `_clean()` 的返回值**必须看**(brief 的 `_run_orchestrator` 忽略了它):删不掉上一跑的产物
#      只可能因为"上一跑的客户端还活着",而残留的 `.result` 会被 `_results_ready()` 当成**这一跑**
#      的结果下判决(而且是绿的)。照 team_match_probe 的先例:清不掉就整段收工。
#      另:brief 的 `_clean` 漏删**引擎日志**(`_godot_log_path` 是 `..._client_c1.godotlog`,
#      而它删的是 `..._c1.godotlog`)→ 陈旧日志会被 `_dump()` 当本跑的现场打印输出。
#   ② (2026-10-07 作废)原先收尾要按**对局 worker 的端口**杀那个子进程。单进程单端口之后
#      对局是大厅进程里的一个 `MatchSession` 节点 —— 没有子进程,而"对局那个端口"**就是大厅
#      自己那个端口**,按它杀等于把本探针自己杀掉。故收尾只按 PID 杀客户端子进程。
#   ③ **断言计数**(`MIN_CHECKS`):本探针是这条路唯一的观测者,一段被截断的跑不许打印 ALL-OK。
#   ④ 每条判词都带断言条数(`ALL-OK(N 条断言)`),与仓内既有探针相同机制。

const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0
# 一条**绿**的跑至少要跑到的断言数:阶段 1 端口 1 条 + 阶段 2 4 条(行在不在 / in_match / 名单 / pid)
# + 三端结果 0 条(结果不合格时走的是 `_check(false, …)`,那本来就已经是红的)。
# 判据只对"否则会打印 ALL-OK"的那一跑生效(见 `_finish`)。
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
	# - 2026-10-07:原先这里要把 worker 端口起投拨到池外 7800~8299(免得与用户自己大厅发的端口
	#   撞上、收尾误杀别人的对局)。没有端口池了 —— 对局就跑在本探针自己这个大端口上。
	# 注意： 清理失败**必须整段收工**(brief 忽略了返回值):残留的 `.result` 会被当成本跑的读数下判决。
	if not _clean():
		print("PROBE: 清理失败(多半是上一跑的进程还活着)—— 不拉起客户端,直接退出")
		get_tree().quit(1)
		return
	print("PROBE: 大厅就绪(port %d,池外;对局与它**同进程同端口**)" % LOBBY_PORT)
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
				push_warning("PROBE: 删不掉上一跑的 %s —— 多半是上一跑的进程还活着" % p)
	return ok


# 观察者挂载至根节点以跨场景保持存活。
func _run_client() -> void:
	var w: Node = load("res://tests/harness/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
