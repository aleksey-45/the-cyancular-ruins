class_name ProcUtil
extends RefCounted

# 进程 / 端口相关的平台工具(**仅 Windows 有效**:taskkill 与 PowerShell)。纯静态、不引 autoload。


const SYS32 := "C:/Windows/System32"


# 杀掉持有该 UDP 端口的进程(**仅当属主是"我们这一族"**)。
static func kill_udp_port(port: int) -> void:
	_kill_udp_port_blocking(port)


# 异步形态:放上后台线程跑同一段 PowerShell(输出照打)。★ 线程由 reap_kill_threads() 在主线程收尸;
#   房间侧的端口归还**不能**依赖"杀完立刻恢复" —— 杀是异步的,归还口径见 lobby_rooms.TEARDOWN_KILL 的延迟。
static var _kill_threads: Array[Thread] = []


static func kill_udp_port_async(port: int) -> void:
	if OS.get_name() != "Windows":
		return
	var t := Thread.new()
	t.start(func() -> void: _kill_udp_port_blocking(port))
	_kill_threads.append(t)


# 主线程收尸(由大厅 tick 调):已结束的线程 join 掉,没结束的留到下一轮。★ 不 join 会泄漏线程句柄。
static func reap_kill_threads() -> void:
	if _kill_threads.is_empty():
		return
	var keep: Array[Thread] = []
	for t in _kill_threads:
		if t.is_alive():
			keep.append(t)
		else:
			t.wait_to_finish()
	_kill_threads = keep


static func _kill_udp_port_blocking(port: int) -> void:
	if OS.get_name() != "Windows":
		return   # PowerShell 串只在 Windows 有意义;别在其它平台白起一个进程
	# ★ 保守护栏(见文件头):`Select -ExpandProperty` 那条修正写法照旧在,只是**不再无条件
	var self_pat := ""
	var self_name: String = OS.get_executable_path().get_file().get_basename()
	if self_name != "" and not self_name.contains("'"):
		self_pat = " -or $n -eq '" + self_name + "'"
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"foreach($id in $p){$n=(Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName; " + \
			"if($n -like 'Godot*' -or $n -like 'Cyancular*' -or $n -like 'The Cyancular*'" + \
			self_pat + "){" + \
			"Stop-Process -Id $id -Force -ErrorAction SilentlyContinue}" + \
			"else{Write-Output ('[ProcUtil] UDP " + str(port) + " held by ' + $n + " + \
			"' -- not ours, not killing it')}}"
	# ★ 必须**捕获输出**:这条 `-not ours` 警告是「证不出是自己人就不杀」取向的唯一可见反馈(见文件头)。
	#   旧写法是 `OS.execute(..., [], false, true)`(不捕获 + 自开控制台)⇒ 警告一闪即逝/根本进不了日志。
	var out: Array = []
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], out, false, false)
	for line in out:
		var s := str(line).strip_edges()
		if not s.is_empty():
			print(s)


# ── 按 UDP 端口查属主 PID(netstat 版;静默、只要 pid)────────────────────────────
static func pids_on_udp_port(port: int) -> Array[int]:
	var pids: Array[int] = []
	if OS.get_name() != "Windows":
		return pids
	var out: Array = []
	OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-ano"]), out, false, false)
	for chunk in out:
		for line in str(chunk).split("\n"):
			var pid := _pid_of_udp_line(line, port)
			if pid > 0 and not pids.has(pid):
				pids.append(pid)
	return pids


# netstat -ano 的一行 → 该行的属主 pid(UDP 且本地端口命中);否则 -1。纯函数(不碰 OS),`-s` 可测。
static func _pid_of_udp_line(line: String, port: int) -> int:
	var cols := line.strip_edges().split(" ", false)
	if cols.size() < 4 or cols[0] != "UDP":
		return -1
	# cols[1] = 本地地址,形如 `0.0.0.0:7777` / `[::]:7777` / `127.0.0.1:7777`
	if not _addr_has_port(cols[1], port):
		return -1
	# UDP 行的最后一列就是 pid(没有 State 列)。TCP 行即使列数够也不进这里(上面已经挡掉)。
	var pid := int(cols[cols.size() - 1])
	return pid if pid > 0 else -1


# 地址串的**端口**是否等于 port。★ 必须按冒号后整段解析,不能 `contains(":7777")`:
# 后者会被 `:17777` / `:77770` 这类前缀串命中;也不能 `contains(":7777 ")`(行尾无空格时会漏)。
static func _addr_has_port(addr: String, port: int) -> bool:
	var at := addr.rfind(":")
	if at < 0 or at + 1 >= addr.length():
		return false
	var tail := addr.substr(at + 1)
	return tail.is_valid_int() and int(tail) == port
