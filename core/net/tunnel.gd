class_name Tunnel
extends RefCounted

# EasyTier P2P 网络隧道管理：基于 EasyTier 应用层协议栈，
# 在对战双方之间建立虚拟网络，实现 UDP 数据包的应用层透明转发。
#
# 架构原理：
# - 免驱动运行：采用应用层协议栈（--no-tun），无需安装虚拟网卡驱动或管理员权限。
# - 服务端（房主）：EasyTier 自动映射端口，将虚拟网目标端口转发至本机服务端端口。
# - 客户端（客机）：通过 CLI 工具添加出站转发规则，将本机动态分配端口映射至房主虚拟 IP 端口，
#   客户端直接连接本地回环地址即可进行对局。
# - 端口同步与房间凭据：房间码决定虚拟网络名称与通信密钥；端口号通过主机名在对等节点间同步。

const Meta := preload("res://core/config/tunnel_meta.gd")

# 房间码规格：固定 8 位十进制数字，允许前导零
const ROOM_DIGITS := 8
const ROOM_MAX := 99999999
# 客机等待房主在虚拟网络中就绪的超时时限（秒）
const CLIENT_WAIT := 60.0
# 房主等待本机 RPC 门户就绪的超时时限（秒）
const HOST_WAIT := 20.0
# CLI 轮询间隔（秒）
const POLL_INTERVAL := 1.0
# 端口转发规则添加重试次数
const FORWARD_TRIES := 3

static var _pid := 0            # 核心进程 PID，0 表示未启动
static var _rpc_port := 0       # 本端 RPC 门户监听端口
static var _role := ""          # 角色标识（host 或 guest）
static var _forward_host := ""
static var _forward_target := 0
static var _forward_port := 0   # 本端本地转发端口（客机使用，0 表示未转发或房主模式）
static var _code := ""          # 当前加入的 8 位房间码
static var _core_path := ""     # 核心程序可执行文件路径
static var _cli_path := ""      # 命令行工具可执行文件路径


## 生成随机 8 位房间码字符串。
static func generate_room() -> String:
	return "%08d" % randi_range(0, ROOM_MAX)


## 校验房间码格式是否为合法的 8 位纯数字字符串。
static func is_valid_room(s: String) -> bool:
	if s.length() != ROOM_DIGITS:
		return false
	for i in range(s.length()):
		var c := s[i]
		if c < "0" or c > "9":
			return false
	return true


## 根据房间码生成虚拟网络凭据字典（包含网络名称与通信密钥）。
static func room_credentials(code: String) -> Dictionary:
	return {
		"network_name": Meta.NET_PREFIX + code,
		"network_secret": code,
	}


## 从主机名中解析房主的服务端端口号，非房主条目或无效格式返回 -1。
static func host_port_of(hostname: String) -> int:
	if not hostname.begins_with(Meta.HOST_PREFIX):
		return -1
	var tail := hostname.substr(Meta.HOST_PREFIX.length())
	if tail.is_empty() or not tail.is_valid_int():
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
		if ip.is_empty():
			continue
		return {"ipv4": ip, "hostname": hn, "port": port}
	return {}


static func ensure_downloaded() -> bool:
	if available():
		return true
	push_error(missing_hint())
	return false


## 检查核心程序、命令行工具与依赖动态链接库是否完整就绪。
static func available() -> bool:
	var dir := AppPaths.easytier_dir()
	for name in Meta.required_files():
		if not FileAccess.file_exists(dir.path_join(name)):
			return false
	_core_path = dir.path_join(Meta.core_name())
	_cli_path = dir.path_join(Meta.cli_name())
	return true


static func core_exe() -> String:
	return _core_path


## 返回组件缺失时的界面提示文案。
static func missing_hint() -> String:
	return "未找到 EasyTier 组件(%s)，请将运行组件放入 %s" % [
			" / ".join(Meta.required_files()), AppPaths.easytier_dir()]

static func cli_exe() -> String:
	return _cli_path


static func rpc_port() -> int:
	return _rpc_port


## 启动房主网络隧道进程，将游戏服务端端口暴露于虚拟网络中。
static func start_host(port: int, code: String) -> bool:
	if port <= 0 or not is_valid_room(code):
		push_error("Tunnel: 房主参数不合法(port=%d code=%s)" % [port, code])
		return false
	if not ensure_downloaded():
		return false
	stop()
	_rpc_port = _pick_rpc_port()
	if _rpc_port <= 0:
		push_error("Tunnel: RPC 门户分配不到本机端口(bind 127.0.0.1:0 失败)")
		return false
	_role = "host"
	var args := _core_args("host", code, port)
	var pid := NetSession.launch(_core_path, args)
	if pid <= 0:
		push_error("Tunnel: easytier-core 启动失败(%s)" % _core_path)
		_role = ""
		return false
	_pid = pid
	_code = code
	print("[tunnel] 房主隧道启动 pid=%d 端口 %d 房间码 %s(rpc %d)" % [pid, port, code, _rpc_port])
	return true


## 等待房主本地 RPC 门户响应就绪。
static func wait_ready() -> bool:
	if _pid <= 0:
		return false
	var pid := _pid
	var deadline := Time.get_ticks_msec() + int(HOST_WAIT * 1000.0)
	while pid == _pid and NetSession.running(pid) and Time.get_ticks_msec() < deadline:
		var r := await _cli_async(PackedStringArray([
			"--rpc-portal", "127.0.0.1:%d" % _rpc_port, "-o", "json", "peer"]))
		if pid == _pid and int(r[0]) == 0 and not parse_peers_json(str(r[1])).is_empty():
			return true
		await _sleep(POLL_INTERVAL)
	return false


## 启动客机网络隧道并配置本地转发规则。
## 成功返回包含 port 与 host_ip 的字典，失败返回空字典。
static func start_client(code: String) -> Dictionary:
	if not is_valid_room(code):
		push_error("Tunnel: 房间码不合法(%s)" % code)
		return {}
	if not ensure_downloaded():
		return {}
	stop()
	_rpc_port = _pick_rpc_port()
	if _rpc_port <= 0:
		push_error("Tunnel: RPC 门户分配不到本机端口(bind 127.0.0.1:0 失败)")
		return {}
	_role = "guest"
	var args := _core_args("guest", code, 0)
	var pid := NetSession.launch(_core_path, args)
	if pid <= 0:
		push_error("Tunnel: easytier-core 启动失败(%s)" % _core_path)
		_role = ""
		return {}
	_pid = pid
	_code = code
	print("[tunnel] 客机隧道启动 pid=%d 房间码 %s(rpc %d)" % [pid, code, _rpc_port])
	var found := await _await_host_peer()
	if pid != _pid: return {}
	if found.is_empty():
		push_error("Tunnel: %d 秒内没在虚拟网络里发现房主(房间码 %s)" % [int(CLIENT_WAIT), code])
		stop()
		return {}
	var host_ip := str(found["ipv4"])
	var port := int(found["port"])
	var forwarded := await add_udp_forward(port, host_ip)
	if pid != _pid: return {}
	if not forwarded:
		push_error("Tunnel: 配置转发失败(%s:%d)" % [host_ip, port])
		stop()
		return {}
	print("[tunnel] 客机就绪:房主 %s 端口 %d" % [host_ip, port])
	return {"port": port, "host_ip": host_ip}


## 生成客机唯一主机名后缀。
static func guest_suffix() -> String:
	return "%08x" % randi()


## 配置 UDP 出站端口转发规则：将本机动态回环端口映射至目标虚拟 IP 与端口。
static func add_udp_forward(port: int, host_ip: String) -> bool:
	var pid := _pid
	var bind_port := _pick_free_port()
	if bind_port <= 0:
		push_error("Tunnel: 找不到可用的本机绑定端口,port-forward 无法下发")
		return false
	var bind := "127.0.0.1:%d" % bind_port
	var dst := "%s:%d" % [host_ip, port]
	var last := ""
	for i in range(FORWARD_TRIES):
		var r := await _cli_async(PackedStringArray([
			"--rpc-portal", "127.0.0.1:%d" % _rpc_port,
			"port-forward", "add", "udp", bind, dst]))
		if pid != _pid: return false
		if int(r[0]) == 0:
			_forward_port = bind_port
			_forward_host = host_ip
			_forward_target = port
			print("[tunnel] 已下发转发 udp %s → %s" % [bind, dst])
			return true
		last = str(r[1])
		if i < FORWARD_TRIES - 1:
			await _sleep(POLL_INTERVAL)
	push_error("Tunnel: port-forward add 连续 %d 次失败(%s → %s):%s"
			% [FORWARD_TRIES, bind, dst, last.strip_edges()])
	return false


# 动态分配一个本机空闲的 UDP 端口供出站转发绑定使用。
static func _pick_free_port() -> int:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		return 0
	var p := probe.get_local_port()
	probe.close()
	return p


## 获取客机本地转发绑定的端口号（0 表示当前为房主或未建立转发）。
static func forward_port() -> int:
	return _forward_port


## 停止当前网络隧道子进程并重置状态。
static func stop() -> void:
	if _pid > 0:
		NetSession.stop(_pid)
		print("[tunnel] 已停止隧道 pid=%d(%s)" % [_pid, _role])
	reset()

static func reset() -> void:
	_pid = 0
	_role = ""
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


## 轮询对端列表直到检测到房主条目。
static func _await_host_peer() -> Dictionary:
	var pid := _pid
	var deadline := Time.get_ticks_msec() + int(CLIENT_WAIT * 1000.0)
	var last_err := ""
	while pid == _pid and NetSession.running(pid) and Time.get_ticks_msec() < deadline:
		var r := await _cli_async(PackedStringArray([
			"--rpc-portal", "127.0.0.1:%d" % _rpc_port, "-o", "json", "peer"]))
		if pid != _pid: return {}
		if int(r[0]) == 0:
			var peers := parse_peers_json(str(r[1]))
			var found := pick_host_peer(peers)
			if not found.is_empty():
				return found
		else:
			last_err = str(r[1])
		await _sleep(POLL_INTERVAL)
	if not last_err.is_empty():
		push_warning("Tunnel: 最后一次 CLI 调用失败:%s" % last_err.strip_edges())
	return {}


## 官方固定版本的 CLI 直接返回 JSON 数组。
static func parse_peers_json(text: String) -> Array:
	return JSON.parse_string(text)


## CLI 和内核共用进程所有权，退出会话时一起回收。
static func _cli_async(args: PackedStringArray) -> Array:
	return await NetSession.execute(_cli_path, args)


static func _sleep(sec: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(sec).timeout
	else:
		OS.delay_msec(int(sec * 1000.0))


## 读取公共初始节点配置文件中的节点列表。
static func relay_list() -> Array[String]:
	var f := FileAccess.open(relay_file(), FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	return parse_relay_lines(text)


## 解析公共节点文本行，忽略注释与空行，规范化协议前缀。
static func parse_relay_lines(text: String) -> Array[String]:
	var out: Array[String] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		out.append(_normalize_relay(line))
	return out


## 返回公共节点列表配置文件路径。
static func relay_file() -> String:
	if OS.has_feature("macos") and OS.has_feature("template"):
		return OS.get_user_data_dir().path_join(Meta.RELAY_FILE_NAME)
	return AppPaths.easytier_dir().path_join(Meta.RELAY_FILE_NAME)


## 缺少公共节点配置时写入默认 UDP 节点列表。
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


# 规范化节点地址协议头，无协议头时默认添加 udp:// 前缀。
static func _normalize_relay(s: String) -> String:
	var t := s.strip_edges()
	if t.contains("://"):
		return t
	return "udp://" + t


## 检查是否配置了可用的初始公共节点。
static func has_initial_peers() -> bool:
	return not relay_list().is_empty()


## 未配置公共节点时的界面提示文案。
static func no_relay_hint() -> String:
	if has_initial_peers():
		return ""
	return "%s 里一个初始节点都没有 —— 别人远程进不来(每行一个地址,改完重进房间生效)" % relay_file()


# 所有网络选项写入配置；只有 RPC 监听地址留在启动参数中。
# 官方内核混用配置文件和网络命令行选项时，会把配置标成只读。
static func _core_args(role: String, code: String, port: int) -> PackedStringArray:
	var lines := PackedStringArray([
		"hostname = " + JSON.stringify(Meta.HOST_PREFIX + str(port) if role == "host" else Meta.GUEST_PREFIX + guest_suffix()),
		"listeners = [\"udp://0.0.0.0:0\"]",
	])
	lines.append("ipv4 = " + JSON.stringify(Meta.VIP_HOST) if role == "host" else "dhcp = true")
	ensure_relay_file()
	for relay in relay_list():
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
	var path := OS.get_temp_dir().path_join("cyr-easytier-%d.toml" % _rpc_port)
	var config := FileAccess.open(path, FileAccess.WRITE)
	config.store_string("\n".join(lines) + "\n")
	config.close()
	return PackedStringArray(["--config-file", path, "--rpc-portal", "127.0.0.1:%d" % _rpc_port])


# 动态分配一个本机空闲的 TCP 端口作为 RPC 门户监听端口。
static func _pick_rpc_port() -> int:
	var srv := TCPServer.new()
	if srv.listen(0, "127.0.0.1") != OK:
		return 0
	var port := srv.get_local_port()
	srv.stop()
	return port
static func refresh_forward() -> bool:
	var code := _code
	if not NetSession.running(_pid):
		return not (await start_client(code)).is_empty()
	var host := _forward_host
	var port := _forward_target
	await _cli_async(PackedStringArray(["--rpc-portal", "127.0.0.1:%d" % _rpc_port,
			"port-forward", "remove", "udp", "127.0.0.1:%d" % _forward_port]))
	return await add_udp_forward(port, host)
