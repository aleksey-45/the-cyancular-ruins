class_name LocalServer
extends RefCounted

# 本机服务器一键启动/重启(客户端大乱斗大厅 / 1v1 页的按钮用):按映像名强杀旧服务端 + 清掉占用大厅端口的
# 残留进程(含 bat 起的旧 Godot 大厅),再从客户端同目录拉起新实例 ⇒ 按一次按钮必然回到"全新空大厅"状态。
# 服务端 exe = 与客户端同目录的 "Cyancular Ruins Server.exe"(打包脚本保证成对生成);仅 Windows(taskkill/netstat),找不到 exe 返回明确提示。
# ★ restart() 是协程(内部有等待),调用方必须 await。

const SERVER_EXE := "Cyancular Ruins Server.exe"
const LOBBY_PORT := 7777
const SYS32 := "C:/Windows/System32"

static var restarting := false   # 重启进行中:客户端吞掉期间「服务器断开」等预期噪音


static func find_server_exe() -> String:
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
	var exe := find_server_exe()
	if exe == "":
		return "未找到 %s —— 请把它和客户端放在同一目录" % SERVER_EXE
	print("[LocalServer] 重启本机服务器…")
	OS.execute(SYS32 + "/taskkill.exe", PackedStringArray(["/F", "/IM", SERVER_EXE]))
	# 兜底:清掉占用大厅端口的任意残留进程(旧 bat 大厅 / 僵尸实例),否则新实例 bind 失败会静默退出
	for pid in _pids_on_port(LOBBY_PORT):
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
	for _i in range(45):
		await _sleep(1.0)
		if not _pids_on_port(LOBBY_PORT).is_empty():
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


# 局域网候选 IP(给「朋友填哪个」用):优先取**有默认路由的网卡**的 IPv4(解析 `netstat -rn` 的默认路由行、按 metric 升序),
# 这样能排除 WSL / Hyper-V / Docker / VMware / Radmin 等虚拟网卡的地址 —— 它们的地址常常是 192.168.227.1 / 172.18.0.1 / 26.x
# 这种"看着像局域网、但同学根本不可达"的地址。2026-10-24 实测:旧实现按私有网段排序,把 192.168.227.1(WSL/Hyper-V)
# 排在真实网卡 10.10.10.166 前面 ⇒ 服务端窗口叫朋友"填第一个",朋友必然连不上。
# ★ 用 netstat 而不是 PowerShell(实测 PowerShell 那版冷启动 2.5 秒,会把大厅页卡住);netstat -rn 只要几十毫秒。
# ★ 查询失败/非 Windows 时回落全部私有地址(排序只保证网段优先级,不保证第一个是真实网卡)。
static var _lan_cache: Array = []

static func lan_ip_candidates() -> Array:
	if not _lan_cache.is_empty():
		return _lan_cache.duplicate()
	var out: Array = []
	# ⓪ 同机服务端刚写的 local_ip.txt:它已按默认路由算好(见 server_main._print_local_ips)⇒ 秒回,
	#    免得每次开大厅都查一次路由表(实测 netstat -rn 约 0.4~0.5s)。★ 必须校验该 IP 仍是本机地址,防陈旧文件。
	var from_file := _read_ip_file_best()
	if from_file != "":
		out.append(from_file)
	# ① 默认路由网卡:`netstat -rn` 里形如 "0.0.0.0 0.0.0.0 <网关> <本机IP> <metric>" 的行,按 metric 升序。
	if out.is_empty():
		var raw: Array = []
		OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-rn"]), raw, false, false)
		var hits: Array = []   # [metric:int, iface:String]
		for chunk in raw:
			for line in str(chunk).split("\n"):
				var cols := line.strip_edges().split(" ", false)
				if cols.size() < 5 or cols[0] != "0.0.0.0" or cols[1] != "0.0.0.0":
					continue
				var iface := cols[3]
				if not _is_dotted_ipv4(iface):
					continue
				var dup := false
				for h in hits:
					if str(h[1]) == iface:
						dup = true
						break
				if not dup:
					hits.append([int(cols[cols.size() - 1]), iface])
		hits.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
		for h in hits:
			var s: String = str(h[1])
			if _priv_score(s) >= 2 and not out.has(s):
				out.append(s)
	# ② 补充:其余私有地址(只用于"第一候选不通时换一个试")
	var rest: Array = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if ":" in s or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		if _priv_score(s) >= 2 and not out.has(s) and not rest.has(s):
			rest.append(s)
	rest.sort_custom(func(a: String, b: String) -> bool: return _priv_score(a) > _priv_score(b))
	out.append_array(rest)
	_lan_cache = out
	return out.duplicate()


# 读同机服务端写的 local_ip.txt 里"本机局域网 IP: X"(与 server_main._write_ip_file 的落盘位置一致:导出版 = exe 同目录,开发态 = res://),
# 并校验 X 仍是本机当前地址(防网络切换后的陈旧文件)。读不到/失效返回 ""。
static func _read_ip_file_best() -> String:
	var dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("template"):
		dir = ProjectSettings.globalize_path("res://")
	var f := FileAccess.open(dir + "/local_ip.txt", FileAccess.READ)
	if f == null:
		f = FileAccess.open("user://local_ip.txt", FileAccess.READ)
	if f == null:
		return ""
	var first := f.get_line()
	f.close()
	var idx := first.find("IP:")
	if idx < 0:
		return ""
	var rest := first.substr(idx + 3)
	# 值后面可能跟 "(其它候选…" / "(朋友…" / 逗号 —— 截到第一个分隔符
	for sep in ["(", ",", " ", "，"]:
		var at := rest.find(sep)
		if at >= 0:
			rest = rest.substr(0, at)
	var ip := rest.strip_edges()
	if not _is_dotted_ipv4(ip):
		return ""
	for a in IP.get_local_addresses():
		if str(a) == ip:
			return ip
	return ""


# 点分十进制 IPv4 判定(不用 RegEx:本文件会进导出包,裁剪模板删掉了 RegEx 模块)。
static func _is_dotted_ipv4(s: String) -> bool:
	var parts := s.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if p == "" or not p.is_valid_int():
			return false
		var v := int(p)
		if v < 0 or v > 255:
			return false
	return true


# 本机 IP 提示:服务器与客户端同机,直接展示客户端自己的地址,免手动 ipconfig。多个候选时把"不通就换"也印出来。
static func lan_ip_hint() -> String:
	var ips := lan_ip_candidates()
	if ips.is_empty():
		return "未检测到局域网 IP(网络未连接?)"
	var text := "本机局域网 IP: %s(朋友在「服务器地址」里填它)" % str(ips[0])
	if ips.size() > 1:
		text += "(不通就换: %s)" % ", ".join(ips.slice(1, mini(ips.size(), 3)))
	return text


# 异步版已删:工作线程里查路由表在进程退出时会偶发原生访问违例(实测 0xC0000005);
# 大厅页改用 `lan_ip_hint()` + call_deferred(有服务端 local_ip.txt 时是毫秒级,没有时晚一帧付一次 netstat 成本)。

static func _priv_score(ip: String) -> int:
	if ip.begins_with("192.168."):
		return 3
	if ip.begins_with("10."):
		return 2
	if ip.begins_with("172."):
		var parts := ip.split(".")
		if parts.size() > 1:
			var o2 := int(parts[1])
			if o2 >= 16 and o2 <= 31:
				return 2
	return 1


static func _pids_on_port(port: int) -> Array[int]:
	var out: Array = []
	var pids: Array[int] = []
	OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-ano"]), out, false, false)
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
