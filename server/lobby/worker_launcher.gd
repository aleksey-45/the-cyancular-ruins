class_name WorkerLauncher
extends RefCounted

# 每局 worker 子进程的**端口池 + 进程管理**:分配端口、拉起 headless worker、按端口杀、日志落盘。
#
# ★ 为什么单独成文件(2026-09-14):这四件事都是"进程与端口",与"房间"无关,原先挤在
#   server/room_manager.gd(RoomManager)里让它长到 745 行。搬出后 RoomManager 只留房间与拆除编排。
#
# ★ 端口分配必须是「唯一递增 + 占用集合」(理由见下方 WORKER_PORT_BASE 上方的原注释):
#   **不要**改成在本进程 bind 探测空闲 —— worker 是独立进程,大厅探测看不到别的进程已占端口,
#   并发会把同一端口发给两个 worker。
#
# ★ release_now() 只是原来那句 `_worker_ports.erase(port)` 的新名字。**纯搬迁,语义未变**:
#   失败分支里"立刻归还端口"的既有行为(含 room_manager.gd 里那条已知缺陷 —— 失败分支不清
#   `room.worker_port`,房间留在注册表,后续清扫可能按陈旧端口误杀)原样保留,本次不修。

# 对局 worker 端口分配:每次 spawn 发**不重复**的端口。注意不能用本进程 bind 探测"空闲"
# —— worker 是独立进程,大厅本进程绑定测试看不到其它进程已占的 socket(并发时会把同端口
# 发给两个 worker,后者绑定失败退出)。唯一递增 + 占用集合即可保证并发零冲突。
const WORKER_PORT_BASE := 7800
const WORKER_PORT_SPAN := 500
# ★★ 端口归还延迟的**职责变了**(2026-09-21,显示方案落地后),但**取值没动**:
#   今天承重的**不是**这个延迟,而是「**worker 进程活着 ⇒ 房对象与它占的端口都还在**」——
#   房不再在"客户端转连 worker"那一刻被拆,它活到 worker 退出
#   (`RoomManager._reclaim_finished_matches`),而端口只在 `teardown_room` 里归还。
#   于是宽限期一定落在 worker 的存活期内(大乱斗/3v3 的 worker 判据里明确要求
#   `_grace.size() == 0` 才退),**宽限期内重连的客户端手里那个端口一定还有效**,
#   与这个常量取多少无关。回局侧"这个端口还是不是我的局"另由凭据里的 `worker_pid`
#   精确回答(`RejoinRegistry.decision` 的 worker_alive 入参)。
# ★ 那本常量现在管什么:只兜「worker 刚退出、别立刻把它的端口发给新 worker」这一小段
#   (给进程收尾与 UDP socket 释放留时间)。30 → 120 的历史教训(30 == 30 是**相等**而不是
#   "短于",相等同样不安全)留档在此,但那条不等式的**承重地位**已由上面那段取代
#   —— 守卫只剩 `tests/smoke/grace_window_smoke` ⑧ 的一条 belt。
const WORKER_PORT_REUSE_DELAY := 120.0
# 大乱斗 worker 的端口归还延迟:按**默认**一局时长(RoyaleHost.MATCH_TIME=300)+ 收尾估,
# 沿用 30s 会让对局中途端口被发给新 worker(串线/bind 冲突)——自检 M2。
# (房主可用建房页的「一局限时」改本局时长:Settings.royale_match_min → player_options 的
#  match_time → RoyaleHost。)
# ★ 已知边界(照实登记,本次不放宽):房主可用建房页把一局配到 30 分钟。★ 现在这条延迟
#   **不再是**"端口会不会被提前复用"的界了(房活到 worker 退出 ⇒ 端口一直被占着)——
#   而 `_sweep_stale_rooms` 的在局宽限**已按模式分两档**:大乱斗取**可证上界**
#   `ROYALE_MATCH_TIME_CEILING`(2026-09-28 修,故那一处**不再是**估的),3v3 仍取
#   `TEAM_MATCH_ESTIMATE`(**估值**,那一档的边界照旧),见该函数注释。
const ROYALE_PORT_REUSE_DELAY := 360.0
# 3v3 worker 的端口归还延迟:一局最长 = 三局两胜 × 9 杀(比 1v1 长得多),与大乱斗同档。
# ★ 2026-09-21 起,"计时起点"这句话不再适用:房只在**对局结束**(worker 退出)后被拆,
#   所以本值只兜"worker 刚退"那一小段(与另两档同一条职责)。
# ★ 别把它单独并回一个更小的数:三档一起动、一起复核(理由见 WORKER_PORT_REUSE_DELAY 上方)。
const TEAM_PORT_REUSE_DELAY := 360.0
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口
var _worker_pids: Dictionary = {}   # port(int) -> pid(int):回收要判"这一局还在不在"


# 立刻把端口还给池子(不等 worker 退出)。调用方语义见 room_manager 的 TEARDOWN_* 三档。
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)
	# ★ 必须一起清:pid 与"端口在不在用"是同一份事实。只清一半的后果是回收梯把一个
	#   已经结束(甚至端口已被复用给别的局)的对局判成"还在" → 房永不被回收,一直挂在列表里。
	_worker_pids.erase(port)


# 分配一个当前未占用的 worker 端口(唯一递增 + 占用集合;见类头注释,勿用 bind 探测)。
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


# 本端口上那具 worker 的 pid(没拉起过 / 已归还 → 0)。
# ★ 谁需要它:大厅的「这一局结束了吗」判据(`RoomManager._reclaim_finished_matches`)——
#   三种模式的 worker 都在对局结束时自己退,"进程还在吗"是唯一的精确答案;任何按
#   "一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口与列表位)。
func pid_of(port: int) -> int:
	return int(_worker_pids.get(port, 0))


# 这个 pid 还在跑吗?★ **pid <= 0 一律 false**(= "不在")。理由:pid 的登记发生在
# `OS.create_process` 成功**之后**,而 `started/in_match = true` 在它之前 —— 中间那个窗口
# 里 pid 还是 0;判"活着"会让"开局那一瞬被自己的回收梯拆掉"成为可能,判"不在"最多让那一局
# 晚一个梯周期(30s)才被发现(那时它已经有 pid 了)。
static func pid_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)


# ── worker 的引擎日志落盘(两个 spawn 共用)──
# worker 是**独立进程**,它的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 服务端侧
# 出问题时(worker 崩了/报错/提前退出)大厅这边**一个字都收不到**,只能从客户端的表象反推。
# 2026-09-12 排查「大乱斗击杀后对手崩溃」时就卡在这个盲区上:大厅日志从头到尾是干净的,
# 而真正跑对局的 worker 说了什么**没人知道**。故给每个 worker 一份引擎日志。
# ⚠ `--log-file` 是**引擎选项**,必须排在 `--` 之前 —— 那之后是 server_main._ready 自己解析的
#   用户参数(`--worker`/`--port`/`--roles`),顺序错了会被当用户参数吞掉。
func log_path(port: int) -> String:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("worker_%d.log" % port)


# 拉起 headless worker 子进程(同一可执行文件 + --worker)。editor(开发)要带 --path 与场景;
# 导出的专用服务端 exe(disable_path_overrides)靠 main_scene.dedicated_server 起 server_main。
# ai_roles 非空 → 透传 --ai-roles(worker 侧这些 role 由服务端 AI 驱动,不等 claim)。
func spawn_worker(port: int, ai_roles: Array = []) -> bool:
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
	return pid > 0


# 拉起大乱斗 worker(--royale --roles 1,2,3 [--ai-roles r,r];其余同 spawn_worker)
# roles = **本局全部参战 role**(真人已分配号 + AI 补位号),由大厅显式传入。
# ★ 不再传「人数 + role 上界」两个整数:role 由 royale_join 的「最小空闲号」分配、有人退出后
#   不重排,编号会留空洞(房里 {1,3} 而成员 2 人)—— 从人数**推导** role 集合必然出错(历史 B1
#   就是这么把持 3 号的真客户端当串线踢掉的)。集合直接传过去则精确,且不需要任何"上界该放宽
#   多少"的特例函数。解析侧逐字对应 server_main.gd 的 argv 解析,两边改一处必须同步改另一处。
func spawn_royale_worker(port: int, roles: Array, ai_roles: Array = []) -> bool:
	var role_strs := []
	for r in roles:
		role_strs.append(str(int(r)))
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	# editor 与 template_debug(调试引擎)都要带 --path+场景;仅导出 exe 可省(dedicated_server 主场景)
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
	# 仅测试用开关**转发**:大厅自己带了这个开关才往下传(生产路径的大厅不带)。
	# ★ 与 server_main.gd 的 argv 解析逐字对应 —— 两边改一处必须同步改另一处(同本函数头注释)。
	if OS.get_cmdline_user_args().has("--test-ground-teleport"):
		args.append("--test-ground-teleport")
	# 诊断开关转发(默认关):`-- --matchsync-diag` —— 大厅进程自己带了才往下传,生产不带。
	# ★ 它纯诊断(server_main._on_match_sync 里那处 print),转发与否**不改生产行为**;
	#   纯布尔开关、无取值,故解析端不需要新增 argv 分支(与 `--registry-report` 同款:
	#   读的时候直接 `OS.get_cmdline_user_args().has(...)`)。
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		args.append("--matchsync-diag")
	var pid := OS.create_process(exe, args)
	if pid > 0:
		_worker_pids[port] = pid
	print("[lobby] spawn royale worker pid=%d port=%d roles=%s ai=%s 日志=%s" % [pid, port,
			str(roles), str(ai_roles), log_path(port)])
	return pid > 0


# 拉起 3v3 worker(--team --roles r,r,... --teams t,t,...;其余同 spawn_royale_worker)。
# roles 与 teams **同序**、**等长**:第 i 个 role 的队号就是 teams[i]。
# ★ 为什么队号要显式传、不从 role 号推:role 由大厅「最小空闲号」分配,有人退出会留空洞
#   ({1,3,5} 而 3 人),奇偶/区间推导必然出错(与 --roles 同一条纪律)。
# ★ 本函数与 server_main.gd 的 argv 解析**逐字对应**,两边改一处必须同步改另一处
#   (守卫见 tests/smoke/room_sweep_smoke.gd 的双向断言)。
func spawn_team_worker(port: int, roles: Array, teams: Array) -> bool:
	if roles.size() != teams.size():
		push_error("spawn_team_worker: roles 与 teams 长度不等(%d vs %d),拒绝拉起" % [roles.size(), teams.size()])
		return false
	# ★ 队号**取值**也必须在这里挡住(Task 9 评审 M2):解析端只收 1..2、越界**静默丢弃** ——
	#   于是只校验长度的实现在 `teams = [1,1,3,2,2,2]` 上会放行(6 与 6 等长),而 worker 收到
	#   5 个队号配 6 个 role ⇒ 解析端长度校验不过 ⇒ 子进程**开机即 quit(1)**,而本函数返回
	#   `pid > 0`、大厅据此判定"拉起成功" ⇒ **对局永不开始,大厅侧一行报错都没有**
	#   (实测复现:子进程的 ERROR 只写在它自己的 `worker_<port>.log` 里,而那份日志没人读;
	#    它死在 bind 之前,所以端口没被占 —— 坏的是"大厅以为成功"这件事本身)。
	#   B 册大厅要从房间数据拼 teams,最容易踩的就是这一脚。
	#   校验集合与解析端接受的 {1, 2} 对齐 —— 两边改一处必须同步改另一处。
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
	return pid > 0


# 杀指定 UDP 端口的进程(worker)。
# 不能只靠 OS.create_process 返回的 pid(跨进程需查端口);`Select -ExpandProperty OwningProcess`
# 那条写法的坑与守卫见 core/proc_util.gd —— 实现收在那里(与 server_main 那份原先逐字重复)。
func kill_worker(port: int) -> void:
	ProcUtil.kill_udp_port(port)
