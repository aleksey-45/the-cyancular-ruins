extends Node

# 「回大厅后回局」(阶段 2-B)的**真链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法(用户侧):
#   timeout 900 bash tests/probe/rejoin_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 36000 res://tests/probe/rejoin_probe.tscn
# 判据:**文本 `REJOIN PROBE: ALL-OK`**(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# ★ `--quit-after 36000`(=600s @60fps)的**推导**:本跑的量级 = 进局 ~8s + PLAYING 静置 ~3s
#   + 离场/主菜单/回局各 ~2s + c2 的观察窗 40s + c3 的 40s 窗口 + 收尾 ~5s ≈ **60~100s**;
#   取 600s = 6~10 倍余量。★ 本仓教训:安全网给薄了会把"跑得慢"读成"功能坏了"
#   (`tests/probe/brawl_rollback_probe.tscn` 就是被 3600 误判过的那一个,实测要 30000),故这里按量级
#   给足而不是照抄别处的数。
#
# ═══ 拓扑(自当大厅/裁判;全部子进程由本进程 `OS.create_process` 直接拉起)═══
#   本进程 = **真大厅**(`NetBus.start_server(LOBBY_PORT)` + `RoomManager`),不进 7777
#   c1/c2/c3 = 3 个 headless 客户端,各自跑**真** `mp_lobby` → **真** `pvp_game`
#   worker = 由**真** `RoomManager._start_match` 经 `WorkerLauncher.spawn_worker` 拉起
#            (与生产逐字同一条路径;探针只把起投端口拨到池外)
#
# ═══ 前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本探针不占 7777,也别杀掉用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 每个子进程都带
#   `--log-file`;失败时把每份引擎日志的尾部一起打印。收尾**按 PID 杀**全部子进程 + 按端口兜底。
#
# ═══ ★ 与 task-8-brief.md 的偏离(逐条;理由都在实现处再写一遍)═══
#   ① `_clean()` 的返回值**必须看**(brief 的 `_run_orchestrator` 忽略了它):删不掉上一跑的产物
#      只可能因为"上一跑的客户端还活着",而残留的 `.result` 会被 `_results_ready()` 当成**这一跑**
#      的结果下判决(而且是绿的)。照 team_match_probe 的先例:清不掉就整段收工。
#      另:brief 的 `_clean` 漏删**引擎日志**(`_godot_log_path` 是 `..._client_c1.godotlog`,
#      而它删的是 `..._c1.godotlog`)→ 陈旧日志会被 `_dump()` 当本跑的现场打出来。
#   ② 收尾按端口兜底时 brief 杀的是**起投点** `WORKER_PORT_OUT`,而真正的 worker 端口是
#      `pick_port()` 发出来的那一个(同一跑里通常相等,但不是同一个概念)→ 改杀 `_worker_port`。
#   ③ **断言计数**(`MIN_CHECKS`):本探针是这条路唯一的观测者,一段被截断的跑不许打印 ALL-OK。
#   ④ 每条判词都带断言条数(`ALL-OK(N 条断言)`),与仓内既有探针同款。

const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const WORKER_PORT_OUT := 29350
const POOL_LOW := 7800
const POOL_HIGH := 8300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0
# 一条**绿**的跑至少要跑到的断言数:相① 端口 1 条 + 相② 4 条(行在不在 / in_match / 名单 / pid)
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
	# ★ worker 起投拨到池外(理由同 team_match_probe:本机可能同时跑着用户自己的大厅,
	#   它往池 7800~8299 里发端口,而本探针收尾会按端口杀 worker —— 撞上就是误杀别人的对局)。
	_rm.get("_launcher").set("_next_port", WORKER_PORT_OUT)
	# ★★ 清理失败**必须整段收工**(brief 忽略了返回值):残留的 `.result` 会被当成本跑的读数下判决。
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


# 相① 房建起来了(c1 建房),并且配对完成
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


# 相② 房开局后**仍然在列表里**、且带 in_match(这是"C 看得见"的服务端那一半;
# 客户端那一半由 c3 自己断言)。★ 这一相同时是**显示方案**的回归(房活过转连)。
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
			# ★ 名单取**冻结的那份**(成员转连 worker 后会全部断开大厅:players 会空、
			#   _peer_names 会被擦 → 只有快照还在;不是快照就会退化成「玩家, 玩家」)。
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
	# ★★ 计数守卫:只对"否则会打印 ALL-OK"的那一跑生效(已经有红时不叠加噪音)。
	#   理由:本探针是回局这条路**唯一的**观测者,而"某一段没跑到"与"跑到了且没事"在输出上
	#   长得一样(`--quit-after` 到期、阶段梯断掉、客户端早退都会走到这里)。
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


# ── 小组手(与 team_match_probe 同款)──
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
	# ★ 兜底按端口杀:**worker 不是本进程记过 pid 的子进程**(它由 `WorkerLauncher` 拉起、
	#   pid 只在 launcher 的表里),故 PID 那一轮杀不到它。杀的是**本跑真正分配到的那个端口**
	#   (`_worker_port`,来自 `pick_port()`),不是起投点 —— 两者通常相等,但不是同一个概念。
	# ★★ **绝不许杀 `LOBBY_PORT`**(brief 的逐字代码里有这一行,实测把**探针自己**杀了):
	#   大厅就在**本进程**里(`NetBus.start_server(LOBBY_PORT)`),`ProcUtil.kill_udp_port` 按
	#   UDP 端口找属主 = 找到本进程的 pid → `Stop-Process -Force` 自杀。症状极具迷惑性:
	#   探针在 `_finish` 里打完"按 PID 收尾 N/M 个子进程"就**当场消失**,后面那几行明细与
	#   `REJOIN PROBE: …` 一个字都打不出来(退出码 255),而三端的 `.result` 全是 OK ——
	#   读日志的人会以为"探针挂了",实际只是它把自己杀了。
	#   大厅端口由 `tests/probe/rejoin_probe.sh` 在**探针进程退出之后**兜底清理(那时才没有自杀问题)。
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


# 开工前清掉上一跑的产物(结果文件 **与引擎日志** —— brief 漏了后者)。★ 删除**必须看返回值**
# (理由见 reconnect_probe 的同名函数:残留进程攥着同名文件时删除会失败,而失败被忽略的后果是
# "新进程截断、残留进程按旧偏移续写" → 日志里出现空洞与陈旧行,人会照着这些行做错误归因)。
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


# 观察者挂 `root`(不是本场景):大厅页 → `pvp_game` → 主菜单 → 再进 `pvp_game` 这一串换场
# 都不会把它带走。
func _run_client() -> void:
	var w: Node = load("res://tests/harness/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
