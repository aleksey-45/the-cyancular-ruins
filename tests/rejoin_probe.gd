extends Node

# 「回大厅后回局」(阶段 2-B)的**真链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法(用户侧):
#   timeout 900 bash tests/rejoin_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 36000 res://tests/rejoin_probe.tscn
# 判据:**文本 `REJOIN PROBE: ALL-OK`**(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# ★ `--quit-after 36000`(=600s @60fps)的**推导**:本跑的量级 = 进局 ~8s + PLAYING 静置 ~3s
#   + 离场/主菜单/回局各 ~2s + c2 的观察窗 40s + c3 的 40s 窗口 + 收尾 ~5s ≈ **60~100s**;
#   取 600s = 6~10 倍余量。★ 本仓教训:安全网给薄了会把"跑得慢"读成"功能坏了"
#   (`tests/brawl_rollback_probe.tscn` 就是被 3600 误判过的那一个,实测要 30000),故这里按量级
#   给足而不是照抄别处的数。
#
# ═══ 拓扑(自当**服务端**/裁判;全部子进程由本进程 `OS.create_process` 直接拉起)═══
#   本进程 = **真服务端**(`NetBus.start_server(LOBBY_PORT)` + `RoomManager`):大厅与对局
#            **同一个进程、同一个端口**(单进程形态),对局是 `RoomManager` 在进程内
#            `add_child(MatchSession)` 出来的一个节点 —— **没有任何 worker 子进程**。
#   c1/c2/c3 = 3 个 headless 客户端,各自跑**真** `matchmaking` → **真** `pvp_game`
#   ★ 探针**不再**给 RoomManager 拨什么"起投端口":端口池(`WorkerLauncher`)已随子进程形态
#     一起删除;要保的只剩一件事 —— **只用自己挑的端口,不碰 7777**(见 `LOBBY_PORT`)。
#
# ═══ 前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本探针不占 7777,也别杀掉用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 每个子进程都带
#   `--log-file`;失败时把每份引擎日志的尾部一起打印。收尾**按 PID 杀**全部子进程。
#
# ═══ ★ 与 task-8-brief.md 的偏离(逐条;理由都在实现处再写一遍)═══
#   ① `_clean()` 的返回值**必须看**(brief 的 `_run_orchestrator` 忽略了它):删不掉上一跑的产物
#      只可能因为"上一跑的客户端还活着",而残留的 `.result` 会被 `_results_ready()` 当成**这一跑**
#      的结果下判决(而且是绿的)。照 team_match_probe 的先例:清不掉就整段收工。
#      另:brief 的 `_clean` 漏删**引擎日志**(`_godot_log_path` 是 `..._client_c1.godotlog`,
#      而它删的是 `..._c1.godotlog`)→ 陈旧日志会被 `_dump()` 当本跑的现场打出来。
#   ② 收尾原本要"按端口兜底杀 worker(杀 `_worker_port` 而不是起投点)" —— 单进程之后
#      **没有 worker 可杀**(服务端就是本进程),那一条随之删除;留下的是它真正要保的禁令:
#      **绝不按端口杀 `LOBBY_PORT`**(大厅在本进程里,那一刀会把自己杀了,见 `_kill_children`)。
#   ③ **断言计数**(`MIN_CHECKS`):本探针是这条路唯一的观测者,一段被截断的跑不许打印 ALL-OK。
#   ④ 每条判词都带断言条数(`ALL-OK(N 条断言)`),与仓内既有探针同款。

const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0
# 一条**绿**的跑至少要跑到的断言数:相① 端口 1 条 + 相② 4 条(行在不在 / in_match / 名单 /
# match_id+session 活着)+ 三端结果 0 条(结果不合格时走的是 `_check(false, …)`,那本来就已经是红的)。
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
	# ★★ 端口**必须**传给 RoomManager:单进程单端口之后它发给客户端的 `go_match`(以及回局应答)
	#   带的就是这个端口,而客户端全程连着同一台 —— 传默认值(7777)会让 c1 回局时被指向
	#   **用户自己的服务端**(探针的既有禁令),而症状只是"回局永远超时"。
	_rm = RoomManager.new(LOBBY_PORT)
	add_child(_rm)
	# ★★ 清理失败**必须整段收工**(brief 忽略了返回值):残留的 `.result` 会被当成本跑的读数下判决。
	if not _clean():
		print("PROBE: 清理失败(多半是上一跑的进程还活着)—— 不拉起客户端,直接退出")
		get_tree().quit(1)
		return
	print("PROBE: 服务端就绪(大厅+对局同进程,端口 %d;不碰 7777)" % LOBBY_PORT)
	_spawn_client("c1")
	_spawn_client("c2")
	_spawn_client("c3")


func _spawn_client(who: String) -> void:
	var argv := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who),
			"res://tests/rejoin_probe.tscn", "--", "--who=" + who])
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


# 相① 房建起来了(c1 建房),并且配对完成 → `RoomManager` 在**进程内**开局。
# ★ 判据从"worker 端口 > 0"换成"房记录拿到局号 + 会话节点非空":单进程之后**没有 worker**,
#   而"这一局开起来了"这件事由 `Room._open_match` 落的两个字段直接回答(`match_id` / `session`)。
func _stage_room() -> void:
	if _rm == null or _rm.lobby.rooms.is_empty():
		if _t > BOOT_TIMEOUT:
			_finish("%.0fs 内没有 1v1 房(c1 没建成?)\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	_room_code = str(_rm.lobby.rooms.keys()[0])
	var room = _rm.lobby.rooms[_room_code]
	if room.players.size() < 2 or int(room.match_id) <= 0 or room.session == null:
		if _t > BOOT_TIMEOUT:
			_finish("房 %s 一直没配对/没开局(players=%d match_id=%d session=%s)\n%s"
					% [_room_code, room.players.size(), int(room.match_id),
						str(room.session != null), _dump()])
		return
	# ★ 端口护栏:旧形态是"worker 端口必须落在真大厅的端口池之外"(池随 `WorkerLauncher` 删除)。
	#   现在要保的是**同一件事的另一面**:探针只用自己挑的端口,且那个端口真的被写进了
	#   `RoomManager`(它经 `go_match` / 回局应答下发给客户端 —— 传错就是"客户端被指向 7777")。
	_check(_rm.port == LOBBY_PORT and LOBBY_PORT != NetBus.DEFAULT_PORT,
			"相① 服务端端口 = 探针自己挑的 %d(不碰默认 %d)" % [_rm.port, NetBus.DEFAULT_PORT])
	print("PROBE: 房 %s 配对完成 → 局号 %d、会话节点已建(t=%.1fs)"
			% [_room_code, int(room.match_id), _t])
	_stage = 1


# 相② 房开局后**仍然在列表里**、且带 in_match(这是"C 看得见"的服务端那一半;
# 客户端那一半由 c3 自己断言)。★ 这一相同时是**显示方案**的回归(房活过开局)。
func _stage_started() -> void:
	if _room_code == "" or not _rm.lobby.rooms.has(_room_code):
		_finish("房 %s 消失了(开局那一刻不该被拆 —— 那正是显示方案要改掉的旧行为)" % _room_code)
		return
	var room = _rm.lobby.rooms[_room_code]
	if not room.started:
		if _t > BOOT_TIMEOUT + 10.0:
			_finish("房 %s 一直没开局(会话没建起来?)\n%s" % [_room_code, _dump()])
		return
	if not _room_seen:
		_room_seen = true
		_start_t = _t
		var row := _find_row(_rm.lobby.room_list_payload(), _room_code)
		_check(not row.is_empty(), "相② ★ 开局后房**仍在**房间列表里(旧实现此刻已拆房 → C 什么都看不见)")
		if not row.is_empty():
			_check(bool(row.get("in_match", false)), "相② 列表行带 in_match=true")
			# ★ 名单取**冻结的那份**(`freeze_roster` 在 `_open_match` 里落):对局中房的
			#   `players` 会随掉线变化、`_peer_names` 会被擦 → 只有快照还在;不是快照就会退化成
			#   「玩家, 玩家」。
			_check(row.get("names", []) == ["BOT1", "BOT2"],
					"相② ★ 名单取自冻结的那份(实得 %s)" % str(row.get("names", [])))
		# ★ "这一局还在不在"的判据(旧形态问的是 `worker_pid > 0` = "worker 进程还在吗"):
		#   单进程之后由**会话节点**回答 —— 局号是回局凭据表上的键,`session` 就是那一局本身,
		#   而 `is_inside_tree()` 保证它不是一具已拆的壳(`_on_session_finished` 会 `queue_free`)。
		_check(int(room.match_id) > 0 and is_instance_valid(room.session) \
				and (room.session as Node).is_inside_tree(),
				"相② ★ 房记录拿到 match_id(%d)且 session 非空、在树上(会话真的活着)"
				% int(room.match_id))
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
	# ★★ **绝不许按端口杀 `LOBBY_PORT`**:大厅就在**本进程**里(`NetBus.start_server(LOBBY_PORT)`),
	#   `ProcUtil.kill_udp_port` 按 UDP 端口找属主 = 找到本进程的 pid → `Stop-Process -Force` 自杀。
	#   症状极具迷惑性:探针在 `_finish` 里打完"按 PID 收尾 N/M 个子进程"就**当场消失**,后面那几行
	#   明细与 `REJOIN PROBE: …` 一个字都打不出来(退出码 255),而三端的 `.result` 全是 OK ——
	#   读日志的人会以为"探针挂了",实际只是它把自己杀了。
	#   大厅端口由 `tests/rejoin_probe.sh` 在**探针进程退出之后**兜底清理(那时才没有自杀问题)。
	# ★ 旧形态这里还有一刀"按 `_worker_port` 杀 worker"(worker 由 `WorkerLauncher` 拉起、pid 不在
	#   本进程的表里)—— 单进程之后**没有 worker 可杀**,那一刀随 `WorkerLauncher` 一起删除。


func _log_path(kind: String, who: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s_%s.godotlog" % [PREFIX, kind, who])


func _godot_log_path(who: String) -> String:
	return _log_path("client", who)


# 服务端现场(**本进程内**,故没有"worker 日志"可读 —— 那一整条路径
# `_rm.get("_launcher").call("log_path", …)` 随 `WorkerLauncher` 一起删除)。
# 失败时它是"服务端那边到底怎么了"的唯一读数:房记录(配对/开局/局号/会话)+ 凭据表 + 连接数。
func _server_dump() -> String:
	if _rm == null:
		return "  (RoomManager 未装配)"
	var peers: Array = multiplayer.get_peers() if multiplayer.has_multiplayer_peer() else []
	var out := "  端口 %d / 1v1 房 %d 间 / 回局凭据 %d 条 / peers %s\n" % [_rm.port,
			_rm.lobby.rooms.size(), _rm.lobby.rejoin.size(), str(peers)]
	for code in _rm.lobby.rooms:
		var r = _rm.lobby.rooms[code]
		out += "  · 房 %s:started=%s match_id=%d session=%s players=%d roster=%s\n" % [code,
				str(r.started), int(r.match_id), str(is_instance_valid(r.session)),
				r.players.size(), str(r.roster)]
	return out


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
	out += "  [服务端现场:就在本进程里]\n%s\n" % _server_dump()
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
	var w: Node = load("res://tests/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
