class_name LocalServer
extends RefCounted

# 本机服务器一键启动/重启(客户端 大乱斗大厅 / 多人对战 页的按钮用):
# - 服务端 exe = 与客户端同目录的 "Cyancular Ruins Server.exe"(打包脚本保证成对生成);
# - 重启 = 按映像名强杀旧服务端实例 + 清掉占用大厅端口的任意残留进程(含 bat 起的旧 Godot 大厅),
#   再从客户端同目录拉起新实例 → 保证按一次按钮必然回到"全新空大厅"状态;
# - 仅 Windows 有效(taskkill/netstat);找不到 exe 时返回明确提示。
# 注意:restart() 是协程(内部有等待),调用方必须 await。

const SERVER_EXE := "Cyancular Ruins Server.exe"
const LOBBY_PORT := 7777
const SYS32 := "C:/Windows/System32"


static func find_server_exe() -> String:
	var p := OS.get_executable_path().get_base_dir().path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	p = ProjectSettings.globalize_path("res://").path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	return ""


# 启动/重启本机服务器;返回给 UI 状态栏的提示文本。
static func restart() -> String:
	var exe := find_server_exe()
	if exe == "":
		return "未找到 %s —— 请把它和客户端放在同一目录" % SERVER_EXE
	print("[LocalServer] 重启本机服务器…")
	# 1) 按映像名杀旧服务端(可能双击开了多个)
	OS.execute(SYS32 + "/taskkill.exe", PackedStringArray(["/F", "/IM", SERVER_EXE]))
	# 2) 兜底:清掉占用大厅端口的任意进程(旧 bat 大厅/僵尸实例),否则新实例 bind 失败静默退出
	for pid in _pids_on_port(LOBBY_PORT):
		if pid != OS.get_process_id():
			OS.execute(SYS32 + "/taskkill.exe", PackedStringArray(["/F", "/PID", str(pid)]))
	# 3) 等端口释放(强杀后立刻复用偶发失败)
	await _sleep(0.8)
	# 4) 拉起新实例
	var pid := OS.create_process(exe, PackedStringArray())
	if pid <= 0:
		return "服务器启动失败(创建进程失败)"
	print("[LocalServer] 已启动 pid=%d %s" % [pid, exe])
	# 5) 轮询等大厅端口就绪。实测:专用服务器引擎冷启动+bind 要 6~30 秒(磁盘/安全软件扫描),
	#    netstat 本身也吃时间 → 每秒探一次、最多约 45 秒;就绪后才让 UI 去连。
	for _i in range(45):
		await _sleep(1.0)
		if not _pids_on_port(LOBBY_PORT).is_empty():
			return "本机服务器已(重)启动"
	return "服务器进程已启动,但 %d 端口 45 秒未就绪(检查安全软件/防火墙,或稍后手动刷新列表)" % LOBBY_PORT


static func _pids_on_port(port: int) -> Array[int]:
	var out: Array = []
	var pids: Array[int] = []
	OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-ano"]), out, false, true)
	for chunk in out:
		for line in str(chunk).split("\n"):
			if not line.contains(":%d " % port):
				continue
			var cols := line.strip_edges().split(" ", false)
			if cols.size() >= 5:
				var pid := int(cols[cols.size() - 1])
				if pid > 0 and not pids.has(pid):
					pids.append(pid)
	return pids


static func _sleep(sec: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(sec).timeout
