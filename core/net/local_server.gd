class_name LocalServer
extends RefCounted

# 本机服务端的一键启动(房主点「创建房间/启动本机服务器」时走这条路)。
#
# ── 一个进程、一个端口 ──
# 服务端是**单进程**的:大厅与对局同进程,配对完成后 `RoomManager` 直接 `add_child(MatchHost)`,
# 不换端口、不转连。于是"启动服务端"这件事只剩下三件必须做对的事:
#   ① 挑一个**没被占用**的端口;
#   ② 把端口通过 argv 交给服务端(`--port P`);
#   ③ 探活确认它真的起来了,起不来就换个端口重来。
#
# ── 为什么端口由客户端挑,而不是服务端 bind(0) 后回传 ──
# `IP.get_local_port()` 在 `create_server(0)` 之后是**立刻**可读的(getsockname),
# 但那句代码跑在**子进程**里 —— 子进程的 stdout 父进程收不到(Windows CreateProcess 不继承
# 句柄),要回传就得写文件/开管道。而 argv 是天然向下的通道:**客户端挑、服务端用**,
# 一步到位,不需要任何文件往返。(父进程自己 `bind(0)` 拿号再 close 传下去**更差**:竞态没少,
# 而那段窗口是**进程冷启动**,更长。)
#
# ── 端口区间 ──
# ★ 取哪个范围**不重要**,别在这上面加任何机制(2026-09-30 用户裁定)。
#   重试已经把"挑到已被占的号"兜住了,而那种失败的代价只是换个号重来(子进程 bind 失败
#   当场退,探活 1 秒内发现,见 `_probe`)。
#   ★ 也**不需要**避开 Windows 的动态端口段(49152–65535):那条"空闲号可能被出站连接抢走"
#     的顾虑,被同一个重试兜住 —— 为它收窄范围和为它加机制,都是过度设计(本文件曾为此
#     写过一整段论证并把上限收到 49151,已删)。
# 2026-09-29 实测:第一次尝试 1.5 秒成功(开发态)。

const SERVER_EXE := "Cyancular Ruins Server.exe"
const PORT_LO := 20000
const PORT_HI := 59999
const PICK_TRIES := 8
## 探活的**放弃**预算(秒),不是"通常要等多久":连上就立刻返回,子进程一死也立刻失败(见 `_probe`)。
## ★ 2026-09-29 **实测(导出产物)**:服务端从启动到 bind 只 **0.41~0.63 秒**(四测),
##   发布形态下整条 `launch_and_connect()` **0.52 秒**首次尝试成功。取 10 秒 ≈ 20 倍余量:
##   既容得下冷启动/安全软件扫描,又不会让"真卡住"时白等太久。
##   (仓库旧注记"冷启动要 6~30 秒"在当前导出产物上**复现不出来** —— 那是旧形态 + netstat 轮询的数字。)
const PROBE_TIMEOUT := 10.0

static var restarting := false   # 启动进行中:客户端吞掉期间「服务器断开」等预期噪音
static var _owned_pid := 0       # 本客户端拉起的服务端(退出时只杀它,不碰别人开的服)
static var _owned_port := 0      # 它监听的那个端口(0 = 没拉起过;只用于日志)


## 与客户端同目录的 `Cyancular Ruins Server.exe`(导出产物)。找不到返回 ""。
## ★ 它**只认导出产物**:从源码跑时没有这个文件,那时请手动起一台服务端(仓库根
##   `start_server.bat`,或 `godot --headless --path . res://server/server_main.tscn`),
##   再把地址框填成 `127.0.0.1:7777` 连过去 —— 建房/隧道/整条玩家流程照常工作。
##   **不要**在这里加"开发态用 Godot 本体起一个"的回退:那条分支在导出产物里是死代码,
##   在开发态只是省掉上面这一步,净增复杂度。
static func find_server_exe() -> String:
	var p := OS.get_executable_path().get_base_dir().path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	p = ProjectSettings.globalize_path("res://").path_join(SERVER_EXE)
	if FileAccess.file_exists(p):
		return p
	return ""


## 挑端口 → 拉起服务端 → 探活。返回可连端口,全失败返回 -1。
## 成功时**连接保持建立** —— 调用方直接当作"已连上大厅"。
## ★ 这是协程(内部有等待与轮询),调用方必须 await。
static func launch_and_connect() -> int:
	var exe := find_server_exe()
	if exe == "":
		push_error("LocalServer: 未找到 %s —— 请把它和客户端放在同一目录" % SERVER_EXE)
		return -1
	restarting = true
	stop_owned()
	for i in range(PICK_TRIES):
		var port := randi_range(PORT_LO, PORT_HI)
		var pid := OS.create_process(exe, PackedStringArray(["--", "--port", str(port)]))
		if pid <= 0:
			# ★ 立即返回,**不能 `break`**:break 会掉到循环后面那句"N 次随机端口全被占用",
			#   于是日志里同时出现"创建进程失败"和"端口全被占用"两条,**后者是错的** ——
			#   一次都没创建成功,根本轮不到端口的事。2026-09-29 实测踩到过这个误导。
			push_error("LocalServer: 创建进程失败(%s)" % exe)
			restarting = false
			return -1
		# ★★ `PvpSession` 必须**在探活之前**写好,不能在 `launch_and_connect()` 返回之后由调用方补:
		#   探活成功那一刻 `connected_to_server` 就会触发,而大厅页的 `_on_lobby_connected` 会读
		#   `PvpSession.server_address/server_port` 去记"我连的是哪一台"。此刻若还是**旧值**,
		#   那一记账就是错的 —— 紧接着的"连上即刷新列表"会拿地址框的文本与它比,不等就走
		#   **重连**分支:`NetBus.stop()` + `start_client(旧地址)`,把刚建好的连接当场拆掉
		#   (表现:本机服务端起来了,可客户端连不上、界面刷不出房间)。
		PvpSession.server_address = "127.0.0.1"
		PvpSession.server_port = port
		if await _probe(pid, port):
			_owned_pid = pid
			_owned_port = port
			restarting = false
			print("[LocalServer] 服务端就绪 pid=%d port=%d(第 %d 次尝试)" % [pid, port, i + 1])
			return port
		NetBus.stop()
		# ★ 重试**只治"端口被占"这一种失败** —— 那一种的子进程会当场退(bind 失败 → `quit(1)`)。
		#   子进程**还活着**却始终不监听 ⇒ 换个端口再试毫无用处(同一个原因会让第二次、第八次
		#   一样卡住),只会把预算白耗八遍 ⇒ 收手报错。
		#   ★ 这一判据不需要给 `_probe` 加第三态返回值:它返回 false 之后再问一次"进程还在吗"
		#     就分得开(它自己只在进程死时才提前返回)。
		if OS.is_process_running(pid):
			OS.kill(pid)
			restarting = false
			push_error("LocalServer: 服务端起来了却在 %.0f 秒内没监听端口 %d —— 多半是安全软件/"
					% [PROBE_TIMEOUT, port] + "防火墙拦了它,或这台机器负载过高;换端口重试没有意义。")
			return -1
		print("[LocalServer] 端口 %d 不可用(第 %d 次),换一个重试" % [port, i + 1])
	restarting = false
	push_error("LocalServer: %d 次随机端口全被占用(极罕见)—— 换台机器或稍后再试" % PICK_TRIES)
	return -1


## 探活:连上 127.0.0.1:port 并等 ENet 握手完成。
## ★ 判据用 `NetBus.can_send_to_server()` 而**不是** `connected_to_server` 信号:
##   服务端是专用服务器(冷启动要几秒),而 `create_client` 是即时的 —— 信号版要自己接
##   一次性连接,还得处理"上一次探活失败留下的连接"。轮询判据没有这些历史包袱。
## ★ 子进程提前退出(端口被别人占 → 服务端打印 `监听失败 20` 并 `quit(1)`)时**立刻**返回,
##   不空等满预算 —— 那是最常见的失败,让它每次白等满预算会把"换端口重试"拖成几分钟。
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


## 收掉**本客户端拉起的**那个服务端。★ 只杀自己记过 pid 的那个:玩家可能同时在跑一个
## 自己双击开的服务端,按映像名杀会把别人正在用的那台一起带走。
static func stop_owned() -> void:
	if _owned_pid > 0 and OS.is_process_running(_owned_pid):
		OS.kill(_owned_pid)
		print("[LocalServer] 已停止本机服务端 pid=%d port=%d" % [_owned_pid, _owned_port])
	_owned_pid = 0
	_owned_port = 0
