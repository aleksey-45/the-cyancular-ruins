class_name LocalServer
extends RefCounted

# 本地服务端启动与生命周期管理（房主创建房间或启动本地服务器时调用）。
#
# 单进程单端口架构设计：
# 服务端采用单进程设计：大厅服务与对局服务运行在同一进程内，房间配对完成后 RoomManager 直接将对局节点挂载加入场景树，
# 无需切换端口，亦无需跨进程转接。启动流程主要包含：
#   1. 选择当前空闲端口；
#   2. 通过命令行参数传入服务端（--port P）；
#   3. 存活探测检测服务就绪状态，若失败则自动重试选择其他端口。

const SERVER_EXE := "Cyancular Ruins Server.exe"
const PICK_TRIES := 8
## 存活探测超时时限（秒）：成功连入后立即返回，子进程异常退出亦会立即判定失败。
const PROBE_TIMEOUT := 10.0

static var restarting := false   # 标记是否处于重启启动中（避免此阶段产生预期内的断开提示噪音）
static var _owned_pid := 0       # 当前客户端启动的服务端进程 PID（退出时仅回收本实例启动的进程）
static var _owned_port := 0      # 服务端监听端口（用于日志追踪）



## 挑一个本机空闲的 UDP 端口给服务端用：直接向操作系统要（bind 127.0.0.1:0，由系统从动态口池
## 分配一个当前空闲的号），拿到立刻释放传给命令行。结构上不会撞任何已绑端口。
static func _pick_free_port() -> int:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		return 0
	var p := probe.get_local_port()
	probe.close()
	return p


## 查找与客户端处于同一目录的服务端可执行程序路径。未找到时返回空字符串。
static func find_server_exe() -> String:
	var p := OS.get_executable_path().get_base_dir().path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	p = ProjectSettings.globalize_path("res://").path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	return ""


## 动态分配空闲端口并启动服务端进程，随后执行存活探测。
## 探测成功后保持连接并返回端口号；若尝试耗尽仍未就绪则返回 -1。
## 包含异步轮询等待，调用方需 await 本方法。
static func launch_and_connect() -> int:
	var exe := find_server_exe()
	if exe == "":
		push_error("LocalServer: 未找到 %s —— 请把它和客户端放在同一目录" % SERVER_EXE)
		return -1
	restarting = true
	stop_owned()
	for i in range(PICK_TRIES):
		var port := _pick_free_port()
		if port <= 0:
			push_error("LocalServer: 操作系统分配空闲端口失败")
			restarting = false
			return -1
		var sargs := PackedStringArray(["--", "--port", str(port)])
		# 将网络诊断参数（--netstat / --netstat-trace）透传给本地服务端子进程。
		# 服务端据此输出待消费输入队列等性能指标，用于定位延迟瓶颈来源于网络传输还是服务端处理积压。
		# 仅在调试/基准测试时显式启用，默认关闭。
		for a in OS.get_cmdline_user_args():
			if a == "--netstat" or a == "--netstat-trace":
				sargs.append(a)
		var pid := OS.create_process(exe, sargs)
		if pid <= 0:
			# 创建进程失败立即返回，避免落入端口重试分支
			push_error("LocalServer: 创建进程失败(%s)" % exe)
			restarting = false
			return -1
		# 预先更新当前目标服务器地址与端口，确保连接回调触发时读取到正确的对局信息
		PvpSession.server_address = "127.0.0.1"
		PvpSession.server_port = port
		if await _probe(pid, port):
			_owned_pid = pid
			_owned_port = port
			restarting = false
			print("[LocalServer] 服务端就绪 pid=%d port=%d(第 %d 次尝试)" % [pid, port, i + 1])
			return port
		NetBus.stop()
		# 若进程仍存活但在超时时间内未监听，可能受系统防火墙或安全软件拦截，不再重复重试
		if OS.is_process_running(pid):
			OS.kill(pid)
			restarting = false
			push_error("LocalServer: 服务端进程已启动，但在 %.0f 秒内未能成功监听端口 %d（可能被安全软件或防火墙拦截，或系统资源过载，更换端口重试无效）。"
					% [PROBE_TIMEOUT, port])
			return -1
		print("[LocalServer] 端口 %d 不可用(第 %d 次尝试)，正在更换端口重试..." % [port, i + 1])
	restarting = false
	push_error("LocalServer: 连续 %d 次分配随机端口均被占用，请检查系统端口占用情况或稍后重试" % PICK_TRIES)
	return -1


## 存活探测：发起客户端连接并等待通道握手完成。
## 通过 NetBus.can_send_to_server() 轮询就绪状态；若子进程提前退出则立即终止等待。
static func _probe(pid: int, port: int) -> bool:
	if NetBus.start_client("127.0.0.1", port) != OK:
		return false
	var deadline := Time.get_ticks_msec() + int(PROBE_TIMEOUT * 1000.0)
	var tree := Engine.get_main_loop() as SceneTree
	while Time.get_ticks_msec() < deadline:
		if NetBus.can_send_to_server():
			return true
		if not OS.is_process_running(pid):
			return false
		if tree != null:
			await tree.create_timer(0.05).timeout
		else:
			OS.delay_msec(50)
	return NetBus.can_send_to_server()


## 本客户端启动的服务端是否正在运行。
static func is_owned_running() -> bool:
	return _owned_pid > 0 and OS.is_process_running(_owned_pid)


## 停止本客户端启动的服务端进程。仅终止记录了 PID 的实例，避免误伤外部手动启动的服务。
static func stop_owned() -> void:
	if _owned_pid > 0 and OS.is_process_running(_owned_pid):
		OS.kill(_owned_pid)
		print("[LocalServer] 已停止本机服务端 pid=%d port=%d" % [_owned_pid, _owned_port])
	_owned_pid = 0
	_owned_port = 0



