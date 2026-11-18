class_name Tunnel
extends RefCounted

# EasyTier 在虚拟网络内转发 UDP；房主通过主机名公布游戏端口。
const Meta := preload("res://core/config/tunnel_meta.gd")

# 房间码规格：固定 8 位十进制数字，允许前导零
const ROOM_DIGITS := 8
# 客机等待房主在虚拟网络中就绪的超时时限（秒）
const CLIENT_WAIT_MS := 60000
# CLI 轮询间隔（秒）
const POLL_INTERVAL := 1.0
# 端口转发规则添加重试次数
const FORWARD_TRIES := 3

static var _pid := 0            # 核心进程 PID，0 表示未启动
static var _rpc_port := 0       # 本端 RPC 门户监听端口
static var _config_dir: DirAccess
static var _forward_host := ""
static var _forward_target := 0
static var _forward_port := 0   # 本端本地转发端口（客机使用，0 表示未转发或房主模式）
static var _code := ""          # 当前加入的 8 位房间码
static var _cli_path := ""      # 命令行工具可执行文件路径


## 校验房间码格式是否为合法的 8 位纯数字字符串。
static func is_valid_room(s: String) -> bool:
	if s.length() != ROOM_DIGITS:
		return false
	for i in range(s.length()):
		var c := s[i]
		if c < "0" or c > "9":
			return false
	return true


## 从主机名中解析房主的服务端端口号，非房主条目或无效格式返回 -1。
static func host_port_of(hostname: String) -> int:
	if not hostname.begins_with(Meta.HOST_PREFIX):
		return -1
	var tail := hostname.substr(Meta.HOST_PREFIX.length())
	if not tail.is_valid_int():
		return -1
	var p := int(tail)
	return p if p > 0 and p < 65536 else -1


## 从对等节点列表中筛选房主条目，返回包含 ipv4、hostname 与 port 的字典。未找到返回空字典。
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

static func start_host(port: int, code: String) -> String:
	if port <= 0 or port > 65535:
		return "服务端端口无效"
	return _launch(code, port)


static func start_client(code: String, deadline := 0) -> Dictionary:
	var error := _launch(code, 0)
	if not error.is_empty():
		return {"error": error}
	var pid := _pid
	var found := await _await_host_peer(deadline if deadline > 0 else Time.get_ticks_msec() + CLIENT_WAIT_MS)
	if pid != _pid:
		return {}
	error = found.get("error", "")
	if error.is_empty():
		error = await _forward_to(found["port"], found["ipv4"])
	if pid != _pid:
		return {}
	if not error.is_empty():
		stop()
		return {"error": error}
	return {"port": _forward_port, "host_ip": _forward_host}


static func _launch(code: String, host_port: int) -> String:
	if not is_valid_room(code):
		return "房间码须为 8 位数字"
	var dir := AppPaths.easytier_dir()
	var files := Meta.required_files()
	for name in files:
		if not FileAccess.file_exists(dir.path_join(name)):
			return "未找到 EasyTier 组件 %s，请检查 %s" % [name, dir]
	var relays := relay_list()
	if relays.is_empty():
		return "请在 %s 中按行填写房主与客机共用的初始节点" % relay_file()

	if host_port == 0:
		NetBus.stop()
		LocalServer.stop_owned()
	stop()
	_rpc_port = _pick_rpc_port()
	if _rpc_port == 0:
		return "无法分配 EasyTier 的本机 RPC 端口"
	if not _write_config(code, host_port, relays):
		reset()
		return "无法写入 EasyTier 临时配置"
	_cli_path = dir.path_join(Meta.cli_name())
	var core := dir.path_join(Meta.core_name())
	_pid = NetSession.launch(core, ["--config-dir", _config_dir.get_current_dir(), "--rpc-portal", _rpc_address()])
	if _pid <= 0:
		reset()
		return "无法启动 EasyTier，程序路径为 %s" % core
	_code = code
	return ""


static func _forward_to(port: int, host_ip: String) -> String:
	var pid := _pid
	var bind_port := NetBus.pick_free_port()
	if bind_port <= 0:
		return "已找到房主，无法分配本机 UDP 转发端口"
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
			_forward_host = host_ip
			_forward_target = port
			return ""
		last = str(r[1]).strip_edges()
		if i < FORWARD_TRIES - 1:
			await _sleep()
	var detail := "（%s）" % last if not last.is_empty() else ""
	return "已找到房主，UDP 转发配置失败%s" % detail


## 获取客机本地转发绑定的端口号（0 表示当前为房主或未建立转发）。
static func forward_port() -> int:
	return _forward_port


## 停止当前网络隧道子进程并重置状态。
static func stop() -> void:
	if _pid > 0:
		NetSession.stop(_pid)
	reset()

static func reset() -> void:
	_config_dir = null
	_pid = 0
	_rpc_port = 0
	_code = ""
	_forward_port = 0
	_forward_host = ""
	_forward_target = 0


## 获取当前网络所属的房间码，未启动时返回空字符串。
static func current_code() -> String:
	return _code


## 检查当前隧道是否已连入指定房间码对应的虚拟网络中。
static func on_network(code: String) -> bool:
	return code != "" and _code == code and is_running()

static func is_running() -> bool:
	return _pid > 0 and NetSession.running(_pid)


static func _await_host_peer(deadline: int) -> Dictionary:
	var pid := _pid
	var error := ""
	while pid == _pid and NetSession.running(pid) and Time.get_ticks_msec() < deadline:
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
	if not NetSession.running(pid):
		error = "EasyTier 进程已退出"
	if error.is_empty():
		error = "未发现房间 %s 的房主，请检查房间码和双方的初始节点" % _code
	return {"error": error}


static func parse_peers_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK and json.data is Array else null


static func _rpc_address() -> String:
	return "127.0.0.1:%d" % _rpc_port


static func _cli(args: PackedStringArray) -> Array:
	var command := PackedStringArray(["--rpc-portal", _rpc_address()])
	command.append_array(args)
	return await NetSession.execute(_cli_path, command)


static func _sleep() -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(POLL_INTERVAL).timeout


## 读取公共初始节点配置文件中的节点列表。
static func relay_list() -> Array[String]:
	var path := relay_file()
	if FileAccess.file_exists(path):
		return parse_relay_lines(FileAccess.get_file_as_string(path))
	return Meta.DEFAULT_RELAYS.duplicate()


## 解析公共节点文本行，忽略注释与空行，规范化协议前缀。
static func parse_relay_lines(text: String) -> Array[String]:
	var out: Array[String] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		out.append(line if line.contains("://") else "udp://" + line)
	return out


## 返回公共节点列表配置文件路径。
static func relay_file() -> String:
	if OS.has_feature("macos") and OS.has_feature("template"):
		return OS.get_user_data_dir().path_join(Meta.RELAY_FILE_NAME)
	return AppPaths.easytier_dir().path_join(Meta.RELAY_FILE_NAME)


## 大厅入口补齐公共节点配置，保留已有文件。
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


static func _write_config(code: String, port: int, relays: Array[String]) -> bool:
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
	# EasyTier 只允许 CLI 修改由 --config-dir 加载的实例。
	_config_dir = DirAccess.create_temp("cyr-easytier")
	if _config_dir == null:
		return false
	var path := _config_dir.get_current_dir().path_join("instance.toml")
	var config := FileAccess.open(path, FileAccess.WRITE)
	return config != null and config.store_string("\n".join(lines) + "\n")


# 动态分配一个本机空闲的 TCP 端口作为 RPC 门户监听端口。
static func _pick_rpc_port() -> int:
	var srv := TCPServer.new()
	if srv.listen(0, "127.0.0.1") != OK:
		return 0
	var port := srv.get_local_port()
	srv.stop()
	return port

static func refresh_forward(code: String, deadline: int) -> int:
	if _code != code or _forward_host.is_empty() or not is_running():
		var route := await start_client(code, deadline)
		return route.get("port", 0)
	if _forward_port > 0:
		var pid := _pid
		var local_port := _forward_port
		_forward_port = 0
		var result := await _cli(["port-forward", "remove", "udp", "127.0.0.1:%d" % local_port])
		if pid != _pid:
			return 0
		if result[0] != 0:
			stop()
			return 0
	return _forward_port if (await _forward_to(_forward_target, _forward_host)).is_empty() else 0
