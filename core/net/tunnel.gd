class_name Tunnel
extends RefCounted

# 加入房间时从 EasyTier 的节点列表读取房主地址和游戏端口，然后将本地 UDP 数据转发到房主。
const Meta := preload("res://core/config/tunnel_meta.gd")

# 查询节点列表和重试 UDP 转发的间隔（秒）。
const POLL_INTERVAL := 1.0
# 建立 UDP 转发规则的尝试次数上限。
const FORWARD_TRIES := 3

var _pid := 0            # 记录当前 EasyTier 进程的 ID。未启动或已清除状态时为 0。
var _rpc_port := 0       # 本地 EasyTier 命令使用的 RPC 端口。
var _config_dir: DirAccess
var _code := ""
var _forward_port := 0
var _cli_path := ""
var _processes := OwnedProcessGroup.new()
var _commands: Array[CliCommand] = []


static func host_port_of(hostname: String) -> int:
	if not hostname.begins_with(Meta.HOST_PREFIX):
		return -1
	var tail := hostname.substr(Meta.HOST_PREFIX.length())
	if not tail.is_valid_int():
		return -1
	var p := int(tail)
	return p if p > 0 and p < 65536 else -1


## 按节点列表的顺序查找，返回第一条具有有效地址及游戏端口的房主记录。没有符合条件的节点时返回空字典。
static func pick_host_peer(peers: Array) -> Dictionary:
	for e in peers:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var hn := str(d.get("hostname", ""))
		var port := host_port_of(hn)
		if port <= 0:
			continue
		var ip := str(d.get("ipv4", "")).strip_edges()
		if not ip.is_valid_ip_address():
			continue
		return {"ipv4": ip, "port": port}
	return {}

func start_host(port: int, code: String) -> String:
	return _launch(code, port)


func start_client(code: String, deadline: int) -> Dictionary:
	if _forward_port > 0 and code == _code and _processes.running(_pid):
		return {"port": _forward_port}
	var error := _launch(code, 0)
	if not error.is_empty():
		return {"error": error}
	var pid := _pid
	var found := await _await_host_peer(deadline)
	if pid != _pid:
		return {}
	var route := found if found.has("error") else await _forward_to(found.port, found.ipv4)
	if pid != _pid: return {}
	if route.has("error"): stop()
	return route


func _launch(code: String, host_port: int) -> String:
	stop()
	ensure_relay_file()
	var dir := AppPaths.easytier_dir()
	var files := Meta.required_files()
	for name in files:
		if not FileAccess.file_exists(dir.path_join(name)):
			return "未找到 EasyTier 组件 %s，请检查 %s" % [name, dir]
	var relays := relay_list()
	if relays.is_empty():
		return "请在 %s 中按行填写房主与客机共用的初始节点" % relay_file()

	_rpc_port = _pick_rpc_port()
	if _rpc_port == 0:
		return "无法分配 EasyTier 的本机 RPC 端口"
	if not _write_config(code, host_port, relays):
		stop()
		return "无法写入 EasyTier 临时配置"
	_cli_path = dir.path_join(Meta.files.cli)
	var core := dir.path_join(Meta.files.core)
	_pid = _processes.launch(core, ["--config-dir", _config_dir.get_current_dir(), "--rpc-portal", _rpc_address()], false)
	if _pid <= 0:
		stop()
		return "无法启动 EasyTier，程序路径为 %s" % core
	_code = code
	return ""


func _forward_to(port: int, host_ip: String) -> Dictionary:
	var pid := _pid
	var bind_port := NetBus.pick_free_port()
	if bind_port <= 0:
		return {"error": "已找到房主，无法分配本机 UDP 转发端口"}
	var bind := "127.0.0.1:%d" % bind_port
	var dst := "%s:%d" % [host_ip, port]
	var last := ""
	for i in range(FORWARD_TRIES):
		if pid != _pid:
			break
		var r := await _cli(["port-forward", "add", "udp", bind, dst])
		if pid != _pid:
			break
		if int(r[0]) == 0:
			_forward_port = bind_port
			return {"port": bind_port}
		last = str(r[1]).strip_edges()
		if i < FORWARD_TRIES - 1:
			await _sleep()
	var detail := "（%s）" % last if not last.is_empty() else ""
	return {"error": "已找到房主，UDP 转发配置失败%s" % detail}


func stop() -> void:
	for command in _commands:
		command.cancel.post()
		WorkerThreadPool.wait_for_task_completion(command.task)
	_commands.clear()
	_processes.stop_all()
	_pid = 0
	_forward_port = 0
	_config_dir = null


func _await_host_peer(deadline: int) -> Dictionary:
	var pid := _pid
	var error := ""
	while pid == _pid and _processes.running(pid) and Time.get_ticks_msec() < deadline:
		var r := await _cli(["-o", "json", "peer"])
		if pid != _pid:
			return {}
		if int(r[0]) == 0:
			var peers: Variant = parse_peers_json(str(r[1]))
			if peers != null:
				var found := pick_host_peer(peers)
				if not found.is_empty():
					return found
			error = "EasyTier 返回了无效的节点列表" if peers == null else ""
		else:
			error = "无法查询 EasyTier 节点（%s）" % str(r[1]).strip_edges()
		await _sleep()
	if not _processes.running(pid):
		error = "EasyTier 进程已退出"
	if error.is_empty():
		error = "未发现房间 %s 的房主，请检查房间码和双方的初始节点" % _code
	return {"error": error}


static func parse_peers_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK and json.data is Array else null


func _rpc_address() -> String:
	return "127.0.0.1:%d" % _rpc_port


# CLI 启动和读取留在线程池。进程组在超时或取消时回收子进程。
class CliCommand:
	var task: int
	var cancel := Semaphore.new()
	var result := [-1, "CLI 已取消或超时"]

	func run(path: String, args: PackedStringArray) -> void:
		var processes := OwnedProcessGroup.new()
		var pid := processes.launch(path, args, true)
		if pid <= 0:
			result = [-1, "CLI 启动失败"]
			return
		var output := PackedByteArray()
		var deadline := Time.get_ticks_msec() + 5000
		while not cancel.try_wait() and Time.get_ticks_msec() < deadline:
			var sample := processes.poll(pid)
			output.append_array(sample[2])
			if not sample[0]:
				result = [sample[1], output.get_string_from_utf8()]
				return
			OS.delay_msec(2)

func _cli(args: PackedStringArray) -> Array:
	var argv := PackedStringArray(["--rpc-portal", _rpc_address()])
	argv.append_array(args)
	var command := CliCommand.new()
	command.task = WorkerThreadPool.add_task(command.run.bind(_cli_path, argv))
	_commands.append(command)
	var tree := Engine.get_main_loop() as SceneTree
	while _commands.has(command) and not WorkerThreadPool.is_task_completed(command.task):
		await tree.process_frame
	if _commands.has(command):
		WorkerThreadPool.wait_for_task_completion(command.task)
		_commands.erase(command)
	return command.result


static func _sleep() -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(POLL_INTERVAL).timeout


## 优先读取本地配置中的初始节点。仅在配置文件不存在时回退到内置列表。
static func relay_list() -> Array[String]:
	var path := relay_file()
	if FileAccess.file_exists(path):
		return parse_relay_lines(FileAccess.get_file_as_string(path))
	return Meta.DEFAULT_RELAYS.duplicate()


## 每行一个节点地址。忽略空行和以 # 开头的行，省略协议的地址按 UDP 处理。
static func parse_relay_lines(text: String) -> Array[String]:
	var out: Array[String] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		out.append(line if line.contains("://") else "udp://" + line)
	return out


## macOS 应用包的初始节点列表位于用户数据目录，其余运行方式使用 EasyTier 组件目录。
static func relay_file() -> String:
	if OS.has_feature("macos") and OS.has_feature("template"):
		return OS.get_user_data_dir().path_join(Meta.RELAY_FILE_NAME)
	return AppPaths.easytier_dir().path_join(Meta.RELAY_FILE_NAME)


## 第一次启动隧道时写出默认初始节点，供玩家编辑。
static func ensure_relay_file() -> void:
	var path := relay_file()
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(PackedStringArray(Meta.DEFAULT_RELAYS)) + "\n")
	f.close()
	print("[tunnel] 已生成公共节点列表 %s" % path)


func _write_config(code: String, port: int, relays: Array[String]) -> bool:
	var host := port > 0
	var hostname := Meta.HOST_PREFIX + str(port) if host else Meta.GUEST_PREFIX + ("%08x" % randi())
	var lines := PackedStringArray([
		"hostname = " + JSON.stringify(hostname),
		"listeners = [\"udp://0.0.0.0:0\"]",
		"ipv4 = " + JSON.stringify(Meta.VIP_HOST) if host else "dhcp = true",
	])
	for relay in relays:
		lines.append("[[peer]]")
		lines.append("uri = " + JSON.stringify(relay))
	lines.append_array([
		"[network_identity]",
		"network_name = " + JSON.stringify(Meta.NET_PREFIX + code),
		"network_secret = " + JSON.stringify(code),
		"[flags]",
		"no_tun = true",
		"bind_device = false",
		"default_protocol = \"udp\"",
		"disable_tcp_hole_punching = true",
		"latency_first = true",
		"private_mode = true",
		"data_compress_algo = \"None\"",
	])
	# 启动时会把临时目录的路径交给 EasyTier，让它读取这一房间的 instance.toml。
	_config_dir = DirAccess.create_temp("cyr-easytier")
	if _config_dir == null:
		return false
	var path := _config_dir.get_current_dir().path_join("instance.toml")
	var config := FileAccess.open(path, FileAccess.WRITE)
	return config != null and config.store_string("\n".join(lines) + "\n")


# 让系统为临时监听套接字分配一个 TCP 端口，取得端口号后关闭监听。
static func _pick_rpc_port() -> int:
	var srv := TCPServer.new()
	if srv.listen(0, "127.0.0.1") != OK:
		return 0
	var port := srv.get_local_port()
	srv.stop()
	return port
