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
# 端口归还延迟(秒)。不能在房间清空时立刻归还:玩家转连 worker 的瞬间大厅就关房,
# 而旧 worker 要等客户端真正断开(对局结束/退菜单)才退出,窗口期可达数分钟;
# 立刻复用会把同端口发给新 worker → bind 冲突,或旧 worker 抢到新局的客户端(跨房间串线)。
# 30s 足够旧 worker 走完收尾;极端情况(客户端僵死不断开)由 500 端口轮回兜底。
const WORKER_PORT_REUSE_DELAY := 30.0
# 大乱斗 worker 的端口归还延迟:按**默认**一局时长(RoyaleHost.MATCH_TIME=300)+ 收尾估,
# 沿用 30s 会让对局中途端口被发给新 worker(串线/bind 冲突)——自检 M2。
# ★ 已知边界(照实登记,本次不放宽):房主可用建房页的「一局限时」把一局配到 30 分钟
# (Settings.royale_match_min → player_options 的 match_time → RoyaleHost),此时本延迟短于
# 一局,端口可能在**旧 worker 还在跑**时就被复用。与 sweep 在局宽限同一根因(都拿默认时长
# 当上界),修法同样要让界读**本局实际时长**(只在 worker 里)——见 _sweep_stale_rooms 的注释。
const ROYALE_PORT_REUSE_DELAY := 360.0
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口


# 立刻把端口还给池子(不等 worker 退出)。调用方语义见 room_manager 的 TEARDOWN_* 三档。
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)


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
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn royale worker pid=%d port=%d roles=%s ai=%s 日志=%s" % [pid, port,
			str(roles), str(ai_roles), log_path(port)])
	return pid > 0


# 杀指定 UDP 端口的进程(worker)。Windows:PowerShell 取该端口属主进程 → Stop-Process。
# 与 server_main._kill_port_holder 同法;不能只靠 OS.create_process 返回的 pid(跨进程需查端口)。
func kill_worker(port: int) -> void:
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)
