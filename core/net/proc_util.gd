class_name ProcUtil
extends RefCounted



const SYS32 := "C:/Windows/System32"


static func kill_udp_port(port: int) -> void:
	_kill_udp_port_blocking(port)


static var _kill_threads: Array[Thread] = []


static func kill_udp_port_async(port: int) -> void:
	if OS.get_name() != "Windows":
		return
	var t := Thread.new()
	t.start(func() -> void: _kill_udp_port_blocking(port))
	_kill_threads.append(t)


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
		return
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


static func _pid_of_udp_line(line: String, port: int) -> int:
	var cols := line.strip_edges().split(" ", false)
	if cols.size() < 4 or cols[0] != "UDP":
		return -1
	if not _addr_has_port(cols[1], port):
		return -1
	var pid := int(cols[cols.size() - 1])
	return pid if pid > 0 else -1


static func _addr_has_port(addr: String, port: int) -> bool:
	var at := addr.rfind(":")
	if at < 0 or at + 1 >= addr.length():
		return false
	var tail := addr.substr(at + 1)
	return tail.is_valid_int() and int(tail) == port
