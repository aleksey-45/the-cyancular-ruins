class_name LocalServer
extends RefCounted

# 本机服务器一键启动/重启(客户端大乱斗大厅 / 1v1 页的按钮用):按映像名强杀旧服务端 + 清掉占用大厅端口的
# 残留进程(含 bat 起的旧 Godot 大厅),再从客户端同目录拉起新实例 ⇒ 按一次按钮必然回到"全新空大厅"状态。
# 服务端 exe = 与客户端同目录的 "Cyancular Ruins Server.exe"(打包脚本保证成对生成);仅 Windows(taskkill/netstat),找不到 exe 返回明确提示。
# ★ restart() 是协程(内部有等待),调用方必须 await。
# ★ 局域网候选 IP / 提示的实现已搬到 core/net/lan_ip.gd(本文件只管进程控制);这里只留同名转发壳,调用点不变。

const SERVER_EXE := "Cyancular Ruins Server.exe"
const LOBBY_PORT := 7777
const SYS32 := "C:/Windows/System32"

static var restarting := false   # 重启进行中:客户端吞掉期间「服务器断开」等预期噪音


static func find_server_exe() -> String:
	# ★ Web:浏览器里没有"同目录 exe",也没有子进程 ⇒ 明确返回空(调用方的提示文案会显示"未找到…")。
	# Web 版本身不暴露联机入口(见 main_menu),这里只是防止任何意外调用去碰 OS 文件系统。
	if OS.has_feature("web"):
		return ""
	var p := OS.get_executable_path().get_base_dir().path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	p = ProjectSettings.globalize_path("res://").path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	return ""


static func restart() -> String:
	restarting = true
	var msg := await _restart_impl()
	restarting = false
	return msg

static func _restart_impl() -> String:
	# Web:浏览器不允许启动本地进程(taskkill/netstat/create_process 全不可用)。
	if OS.has_feature("web"):
		return "Web 版不支持本机服务器(浏览器里无法启动进程)"
	var exe := find_server_exe()
	if exe == "":
		return "未找到 %s —— 请把它和客户端放在同一目录" % SERVER_EXE
	print("[LocalServer] 重启本机服务器…")
	OS.execute(SYS32 + "/taskkill.exe", PackedStringArray(["/F", "/IM", SERVER_EXE]))
	# 兜底:清掉占用大厅端口的任意残留进程(旧 bat 大厅 / 僵尸实例),否则新实例 bind 失败会静默退出。
	# ★ 必须走 ProcUtil.pids_on_udp_port(netstat 的 UDP 行是 4 列;旧实现按 5 列判 ⇒ 一个都找不到、这里成了空操作)。
	for pid in ProcUtil.pids_on_udp_port(LOBBY_PORT):
		if pid != OS.get_process_id():
			OS.execute(SYS32 + "/taskkill.exe", PackedStringArray(["/F", "/PID", str(pid)]))
	# 等端口释放(强杀后立刻复用偶发失败)
	await _sleep(0.8)
	var pid := OS.create_process(exe, PackedStringArray())
	if pid <= 0:
		return "服务器启动失败(创建进程失败)"
	print("[LocalServer] 已启动 pid=%d %s" % [pid, exe])
	# 轮询等端口就绪:实测专用服务器引擎冷启动 + bind 要 6~30 秒(磁盘/安全软件扫描),netstat 本身也吃时间 ⇒ 每秒探一次、最多约 45 秒。
	var tried_headless := false
	for _i in 45:
		await _sleep(1.0)
		if not ProcUtil.pids_on_udp_port(LOBBY_PORT).is_empty():
			return "本机服务器已(重)启动;" + lan_ip_hint()
		# ★ 无显卡机器(虚拟机 / 远程桌面 / Windows Server / 驱动缺失):服务端是普通 Godot 导出,非 headless 启动会在视频驱动
		#   初始化处秒崩(实测报 Unable to initialize video driver)⇒ 进程 1 秒内就没了。自动改 `--headless` 再拉一次(服务端不需要渲染)。
		if not tried_headless and not OS.is_process_running(pid):
			tried_headless = true
			print("[LocalServer] 服务端进程启动后立即退出(无显卡/RDP?),改用 --headless 重启")
			pid = OS.create_process(exe, PackedStringArray(["--headless"]))
			if pid <= 0:
				return "服务器启动失败(创建进程失败);无显卡机器请手动 `%s --headless` 启动" % exe
			print("[LocalServer] 已启动(--headless) pid=%d %s" % [pid, exe])
	return "服务器进程已启动,但 %d 端口 45 秒未就绪(检查安全软件/防火墙,或稍后手动刷新列表);%s" % [LOBBY_PORT, lan_ip_hint()]


# 局域网候选 IP / 提示:实现收在 core/net/lan_ip.gd(纯解析 + netstat 默认路由探测),这里只转发 ——
# 调用点(server_main.gd / scenes/lobby_page.gd / scenes/mp_lobby.gd)一律不用改。
static func lan_ip_candidates() -> Array:
	return LanIp.lan_ip_candidates()


static func lan_ip_hint() -> String:
	return LanIp.lan_ip_hint()


# ★ `_pids_on_port()` 已删(2026-10-30):它按 `cols.size() >= 5` 判 UDP 行,而 netstat 的 UDP 行只有 4 列
#   ⇒ 残留清理是空操作、就绪轮询恒不成立。实现收进 `ProcUtil.pids_on_udp_port()`(UDP 4 列/端口按冒号后整段解析),
#   与 `ProcUtil.kill_udp_port` 同住一处 —— 别再在这里抄第三份。


static func _sleep(sec: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(sec).timeout
