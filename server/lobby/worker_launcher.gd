class_name WorkerLauncher
extends RefCounted

# 每局 worker 子进程的端口池 + 进程管理:分配端口、拉起 headless worker、按端口杀、日志落盘(与「房间」无关,故独立于 RoomManager)。
# ★ 端口分配必须是「唯一递增 + 占用集合」:不要改成在大厅本进程 bind 探测空闲 —— worker 是独立进程,大厅
# 探测看不到别的进程已占的端口,并发时会把同一端口发给两个 worker(后者绑定失败退出)。


const WORKER_PORT_BASE := 7800
const WORKER_PORT_SPAN := 500
# ★★ 今天承重的不是这个延迟,而是「worker 进程活着 ⇒ 房对象与它占的端口都还在」:房活到 worker 退出、
# 端口只在 teardown_room 归还 ⇒ 宽限期一定落在 worker 存活期内。本常量只兜「worker 刚退出、别立刻把它
# 的端口发给新 worker」;30 → 120 的教训是「30 == 30 是相等、同样不安全」。⚠ 零守卫:grace_window_smoke 已删(2026-10-09)。
const WORKER_PORT_REUSE_DELAY := 120.0
# 大乱斗 worker 的端口归还延迟:按默认一局时长(RoyaleHost.MATCH_TIME)+ 收尾估;★ 已知边界(登记不修):
# 房主可用建房页把一局配到 30 分钟。今天它不再是「端口会不会被提前复用」的界 —— 房活到 worker 退出。
const ROYALE_PORT_REUSE_DELAY := 360.0
# 3v3 worker 的端口归还延迟:一局最长 = 三局两胜 × 9 杀,与大乱斗同档。★ 三档一起动、一起复核,别单独把它并回一个更小的数。
const TEAM_PORT_REUSE_DELAY := 360.0
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口
var _worker_pids: Dictionary = {}   # port(int) -> pid(int):回收要判"这一局还在不在"


# 端口段文案的单一来源(提示串与面板都用它):手写死数字曾与真实池不符,照它放行防火墙会漏掉半个池子。
static func port_span_text() -> String:
	return "%d~%d" % [WORKER_PORT_BASE, WORKER_PORT_BASE + WORKER_PORT_SPAN - 1]


# 立刻把端口还给池子(不等 worker 退出);调用方语义见 room_manager 的 TEARDOWN_* 三档。
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)
# ★ 必须与端口一起清:pid 与「端口在不在用」是同一份事实 —— 只清一半,回收梯会把已结束(甚至端口已被复用)的对局判成「还在」,房永不回收。
	_worker_pids.erase(port)



func pick_port() -> int:
	for _tries in range(WORKER_PORT_SPAN):
		var p := _next_port
		_next_port += 1
		if _next_port >= WORKER_PORT_BASE + WORKER_PORT_SPAN:
			_next_port = WORKER_PORT_BASE
		if not _worker_ports.has(p):
			_worker_ports[p] = true
			return p
	return -1



func pid_of(port: int) -> int:
	return int(_worker_pids.get(port, 0))


# ★ pid <= 0 一律 false(「不在」):pid 登记在 OS.create_process 成功之后,而 started/in_match 在它之前 —— 那个窗口里判「活着」会让开局一瞬被自己的回收梯拆掉。
static func pid_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)


# 端口池快照:三种占法可区分。★ 活着必须走 pid_alive(别另写一份);按端口升序(面板 0.5s 刷新,无序会跳)。
static func classify(ports: Array, pids: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in ports:
		var port := int(p)
		var pid := int(pids.get(port, 0))
		out.append({"port": port, "pid": pid, "alive": pid_alive(pid)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["port"]) < int(b["port"]))
	return out


func busy_ports() -> Array[Dictionary]:
	return classify(_worker_ports.keys(), _worker_pids)


# ── worker 的引擎日志落盘(两个 spawn 共用)── worker 是独立进程,stdout 父进程看不到(Windows CreateProcess
# 不继承句柄)⇒ 它崩了/报错/提前退出,大厅这边一个字都收不到。⚠ --log-file 是引擎选项,必须排在 -- 之前(之后会被当用户参数吞掉)。
func log_path(port: int) -> String:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("worker_%d.log" % port)


# ── 每局归档(端口复用不许覆盖上一局崩溃现场)────────────────────────────────
const WORKER_LOG_KEEP := 20


static func archive_name(path: String, stamp: String) -> String:
	return path.get_base_dir().path_join("%s_%s.log" % [path.get_file().get_basename(), stamp])


static func prune_worker_logs(names: PackedStringArray, port: int, keep: int) -> PackedStringArray:
	var prefix := "worker_%d_" % port
	var hits: Array[String] = []
	for n in names:
		if n.begins_with(prefix) and n.ends_with(".log"):
			hits.append(n)
	hits.sort()
	hits.reverse()
	var out := PackedStringArray()
	for i in mini(keep, hits.size()):
		out.append(hits[i])
	return out


func _archive_log(port: int) -> void:
	var live := log_path(port)
	if not FileAccess.file_exists(live):
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_").substr(9)
	DirAccess.rename_absolute(live, archive_name(live, stamp))
	var dir := live.get_base_dir()
	var names := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			names.append(f)
		f = d.get_next()
	d.list_dir_end()
	var keep := prune_worker_logs(names, port, WORKER_LOG_KEEP)
	var prefix := "worker_%d_" % port
	for n in names:
		if n.begins_with(prefix) and n.ends_with(".log") and not keep.has(n):
			DirAccess.remove_absolute(dir.path_join(n))


# 拉起 headless worker(同一可执行文件 + --worker):editor / template_debug 要带 --path 与场景,导出 exe 靠 run/main_scene.serverui 的主场景覆盖(不再用 dedicated_server 标记 —— 那会让引擎强制空显示驱动);ai_roles 非空则透传 --ai-roles(这些 role 由服务端 AI 驱动,不等 claim)。
func spawn_worker(port: int, ai_roles: Array = []) -> bool:
	_archive_log(port)
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--port", str(port)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--port", str(port)])
	if not ai_roles.is_empty():
		var roles := []
		for r in ai_roles:
			roles.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(roles))
	var pid := OS.create_process(exe, args)
	if pid > 0:
		_worker_pids[port] = pid
	print("[lobby] spawn worker pid=%d port=%d editor=%s ai=%s 日志=%s" % [pid, port,
			str(OS.has_feature("editor")), str(ai_roles), log_path(port)])
	if pid <= 0:
		NetDiag.audit("worker_spawn_failed", {"port": port})
	return pid > 0


# 拉起大乱斗 worker:roles = 本局全部参战 role(真人已分配号 + AI 补位号)。★ 不再传「人数 + role 上界」—— role 由「最小空闲号」分配、退出后不重排,编号会留空洞({1,3} 而 2 人),从人数推导必错;解析侧与 server_main.gd 的 argv 逐字对应,两边改一处必须同步改另一处。
func spawn_royale_worker(port: int, roles: Array, ai_roles: Array = []) -> bool:
	_archive_log(port)
	var role_strs := []
	for r in roles:
		role_strs.append(str(int(r)))
	var exe := OS.get_executable_path()
	var args: PackedStringArray

	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--royale",
				"--port", str(port), "--roles", ",".join(role_strs)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--royale",
				"--port", str(port), "--roles", ",".join(role_strs)])
	if not ai_roles.is_empty():
		var ai_strs := []
		for r in ai_roles:
			ai_strs.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(ai_strs))

	if OS.get_cmdline_user_args().has("--test-ground-teleport"):
		args.append("--test-ground-teleport")

	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		args.append("--matchsync-diag")
	var pid := OS.create_process(exe, args)
	if pid > 0:
		_worker_pids[port] = pid
	print("[lobby] spawn royale worker pid=%d port=%d roles=%s ai=%s 日志=%s" % [pid, port,
			str(roles), str(ai_roles), log_path(port)])
	if pid <= 0:
		NetDiag.audit("worker_spawn_failed", {"port": port})
	return pid > 0


# 拉起 3v3 worker(--team --roles r,r,... --teams t,t,...):roles 与 teams 同序、等长,第 i 个 role 的队号就是 teams[i]。
# ★ 队号必须显式传、不能从 role 号推(同上:编号留空洞);与 server_main.gd 的 argv 逐字对应,守卫 = tools/room_sweep_lint.gd 的双向断言。
func spawn_team_worker(port: int, roles: Array, teams: Array) -> bool:
	_archive_log(port)
	if roles.size() != teams.size():
		push_error("spawn_team_worker: roles 与 teams 长度不等(%d vs %d),拒绝拉起" % [roles.size(), teams.size()])
		return false
# ★ 队号取值也必须在这里挡住:解析端只收 1..2、越界静默丢弃 ⇒ 只校验长度的实现会在 [1,1,3,2,2,2] 上放行,
# worker 收到 5 个队号配 6 个 role、开机即 quit(1),而本函数返回 pid > 0 ⇒ 对局永不开始且大厅一行报错都没有。
	for t in teams:
		if int(t) != 1 and int(t) != 2:
			push_error("spawn_team_worker: 队号 %s 越界(只接受 1/2),拒绝拉起" % str(t))
			return false
	var role_strs := []
	for r in roles:
		role_strs.append(str(int(r)))
	var team_strs := []
	for t in teams:
		team_strs.append(str(int(t)))
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--team",
				"--port", str(port), "--roles", ",".join(role_strs),
				"--teams", ",".join(team_strs)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--team",
				"--port", str(port), "--roles", ",".join(role_strs),
				"--teams", ",".join(team_strs)])
	var pid := OS.create_process(exe, args)
	if pid > 0:
		_worker_pids[port] = pid
	print("[lobby] spawn team worker pid=%d port=%d roles=%s teams=%s 日志=%s" % [pid, port,
			str(roles), str(teams), log_path(port)])
	if pid <= 0:
		NetDiag.audit("worker_spawn_failed", {"port": port})
	return pid > 0


# 杀指定 UDP 端口的进程(worker)。★ 不能只靠 OS.create_process 返回的 pid(跨进程需查端口);「Select -ExpandProperty OwningProcess」那条写法的坑见 core/proc_util.gd(实现收在那里)。
func kill_worker(port: int) -> void:
	ProcUtil.kill_udp_port(port)
