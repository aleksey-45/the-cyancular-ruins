class_name Tunnel
extends RefCounted

# 远程联机隧道编排：基于 EasyTier 应用层网络协议栈，
# 在对战双方之间建立虚拟子网，实现 UDP 数据包的应用层透明转发。
#
# 架构原理：
# - 免驱动与免提权：采用应用层协议栈，无需安装系统级虚拟网卡驱动，不触发管理员提权。
# - 服务端（房主）：EasyTier 自动建立应用层端口映射，将虚拟子网目标端口转发至本机服务端端口。
# - 客户端（客机）：通过命令行接口添加出站转发规则，将本机动态分配端口映射至房主虚拟 IP 端口。
#   客户端直接连接本地回环地址，底层虚拟网络拓扑完全透明。
# - 端口同步与元数据协商：房间码决定虚拟网络名称与通信密钥；端口号通过主机名在对等节点间同步。

const Meta := preload("res://core/config/tunnel_meta.gd")

# 房间码规格：固定 5 位十进制数字，允许前导零
const ROOM_DIGITS := 5
const ROOM_MAX := 99999
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
static var _forward_port := 0   # 本端本地转发端口（客机使用，0 表示未转发或房主模式）
static var _code := ""          # 当前加入的 5 位房间码
static var _core_path := ""     # 核心程序可执行文件路径
static var _cli_path := ""      # 命令行工具可执行文件路径
static var _reaped := false     # 标记是否已执行过残留孤儿进程清理


## 生成随机 5 位房间码字符串。
static func generate_room() -> String:
	return "%05d" % randi_range(0, ROOM_MAX)


## 校验房间码格式是否为合法的 5 位纯数字字符串。
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
	push_error("Tunnel: 缺少 EasyTier 组件(%s / %s / %s)，请运行 tools/fetch_easytier.py 下载或将完整包放入 %s"
			% [Meta.CORE_EXE, Meta.CLI_EXE, Meta.CORE_DLLS[0], AppPaths.easytier_dir()])
	return false


## 检查核心程序、命令行工具与依赖动态链接库是否完整就绪。
static func available() -> bool:
	var dir := AppPaths.easytier_dir()
	var c := dir.path_join(Meta.CORE_EXE)
	var l := dir.path_join(Meta.CLI_EXE)
	if not (FileAccess.file_exists(c) and FileAccess.file_exists(l)):
		return false
	for dll in Meta.CORE_DLLS:
		if not FileAccess.file_exists(dir.path_join(dll)):
			return false
	_core_path = c
	_cli_path = l
	return true


static func core_exe() -> String:
	return _core_path


## 返回组件缺失时的界面提示文案。
static func missing_hint() -> String:
	return "未找到 EasyTier 组件(%s / %s / %s)，请运行 tools/fetch_easytier.py 下载或将完整包放入 %s" % [
			Meta.CORE_EXE, Meta.CLI_EXE, Meta.CORE_DLLS[0], AppPaths.easytier_dir()]

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
	_reap_orphans()
	stop()
	var creds := room_credentials(code)
	_rpc_port = _pick_rpc_port()
	if _rpc_port <= 0:
		push_error("Tunnel: RPC 门户分配不到本机端口(bind 127.0.0.1:0 失败)")
		return false
	_role = "host"
	var args := PackedStringArray([
		"--no-tun",
		"-i", Meta.VIP_HOST,
		"--network-name", str(creds["network_name"]),
		"--network-secret", str(creds["network_secret"]),
		"--hostname", Meta.HOST_PREFIX + str(port),
		"--rpc-portal", "127.0.0.1:%d" % _rpc_port,
		"--private-mode", "true",
		"-l", "udp://0.0.0.0:0",
		"--default-protocol", "udp",
		"--disable-tcp-hole-punching",
		"--latency-first",
		"--enable-bbr",
		"--close-redundant-conns-when-disguised", "true",
	])
	_append_file_logging(args, "host")
	ensure_relay_file()
	_append_relay(args)
	var pid := OS.create_process(_core_path, args)
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
	var deadline := Time.get_ticks_msec() + int(HOST_WAIT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var r := await _cli_async(PackedStringArray([
			"--rpc-portal", "127.0.0.1:%d" % _rpc_port, "-o", "json", "peer"]))
		if int(r[0]) == 0 and not parse_peers_json(str(r[1])).is_empty():
			return true
		await _sleep(POLL_INTERVAL)
	return false


## 启动客机网络隧道并下发本地转发规则。
## 成功返回包含 port 与 host_ip 的字典，失败返回空字典。
static func start_client(code: String) -> Dictionary:
	if not is_valid_room(code):
		push_error("Tunnel: 房间码不合法(%s)" % code)
		return {}
	if not ensure_downloaded():
		return {}
	_reap_orphans()
	stop()
	var creds := room_credentials(code)
	_rpc_port = _pick_rpc_port()
	if _rpc_port <= 0:
		push_error("Tunnel: RPC 门户分配不到本机端口(bind 127.0.0.1:0 失败)")
		return {}
	_role = "guest"
	var args := PackedStringArray([
		"--no-tun",
		"--dhcp",
		"--network-name", str(creds["network_name"]),
		"--network-secret", str(creds["network_secret"]),
		"--hostname", Meta.GUEST_PREFIX + guest_suffix(),
		"--rpc-portal", "127.0.0.1:%d" % _rpc_port,
		"--private-mode", "true",
		"-l", "udp://0.0.0.0:0",
		"--default-protocol", "udp",
		"--disable-tcp-hole-punching",
		"--latency-first",
		"--enable-bbr",
		"--close-redundant-conns-when-disguised", "true",
	])
	_append_file_logging(args, "guest")
	ensure_relay_file()
	_append_relay(args)
	var pid := OS.create_process(_core_path, args)
	if pid <= 0:
		push_error("Tunnel: easytier-core 启动失败(%s)" % _core_path)
		_role = ""
		return {}
	_pid = pid
	_code = code
	print("[tunnel] 客机隧道启动 pid=%d 房间码 %s(rpc %d)" % [pid, code, _rpc_port])
	var found := await _await_host_peer()
	if found.is_empty():
		push_error("Tunnel: %d 秒内没在虚拟网络里发现房主(房间码 %s)" % [int(CLIENT_WAIT), code])
		stop()
		return {}
	var host_ip := str(found["ipv4"])
	var port := int(found["port"])
	if not await add_udp_forward(port, host_ip):
		push_error("Tunnel: 下发转发失败(%s:%d)" % [host_ip, port])
		stop()
		return {}
	print("[tunnel] 客机就绪:房主 %s 端口 %d" % [host_ip, port])
	return {"port": port, "host_ip": host_ip}


## 生成客机唯一主机名后缀。
static func guest_suffix() -> String:
	return "%08x" % randi()


## 下发 UDP 出站端口转发规则：将本机动态回环端口映射至目标虚拟 IP 与端口。
static func add_udp_forward(port: int, host_ip: String) -> bool:
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
		if int(r[0]) == 0:
			_forward_port = bind_port
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
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		print("[tunnel] 已停止隧道 pid=%d(%s)" % [_pid, _role])
	_pid = 0
	_role = ""
	_rpc_port = 0
	_code = ""
	_forward_port = 0


## 获取当前网络所属的房间码，未启动时返回空字符串。
static func current_code() -> String:
	return _code


## 检查当前隧道是否已连入指定房间码对应的虚拟网络中。
static func on_network(code: String) -> bool:
	return code != "" and _code == code and is_running()


static func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


# 清理异常崩溃残留的孤儿核心进程与过期日志。
static func _reap_orphans() -> void:
	if _reaped:
		return
	_reaped = true
	var killed := _reap_orphan_cores()
	var pruned := _prune_log_dirs()
	if killed > 0 or pruned > 0:
		print("[tunnel] 孤儿清扫:终结 %d 个残留内核,删掉 %d 份过期日志(保留最近 %d 份)"
				% [killed, pruned, Meta.ET_LOG_KEEP])


# 返回当前游戏日志路径下的 EasyTier 日志标记前缀。
static func _et_log_marker() -> String:
	return AppPaths.log_dir().path_join(Meta.ET_LOG_DIR_PREFIX)


# 终止归属游戏进程已退出的残留核心进程。
static func _reap_orphan_cores() -> int:
	var ps := "Get-CimInstance Win32_Process | Where-Object Name -eq easytier-core.exe" \
			+ " | ForEach-Object { Write-Output ($_.ProcessId.ToString() + [char]9 + $_.CommandLine) }"
	var out: Array = []
	if OS.execute("powershell", PackedStringArray(["-NoProfile", "-Command", ps]), out) != 0:
		return 0
	var marker := _et_log_marker()
	var my_pid := OS.get_process_id()
	var killed := 0
	for raw in "\n".join(PackedStringArray(out)).split("\n"):
		var line := raw.strip_edges()
		var parts := line.split("\t", true, 1)
		if parts.size() != 2:
			continue
		var et_pid := int(parts[0])
		var cmd := parts[1]
		if et_pid <= 0 or not cmd.contains(marker):
			continue
		var owner := _owner_pid_of(cmd)
		if owner <= 0 or owner == my_pid or OS.is_process_running(owner):
			continue
		if OS.kill(et_pid) == OK:
			killed += 1
			print("[tunnel] 已终结残留内核 pid=%d(拉起它的游戏 pid=%d 已退出)" % [et_pid, owner])
	return killed


# 从命令行参数中解析启动该核心进程的游戏进程 PID。
static func _owner_pid_of(cmd: String) -> int:
	var from := 0
	while true:
		var i := cmd.find(Meta.ET_LOG_DIR_PREFIX, from)
		if i < 0:
			return 0
		from = i + Meta.ET_LOG_DIR_PREFIX.length()
		var role := ""
		if cmd.substr(from).begins_with(Meta.ROLE_HOST + "-"):
			role = Meta.ROLE_HOST
		elif cmd.substr(from).begins_with(Meta.ROLE_GUEST + "-"):
			role = Meta.ROLE_GUEST
		if role.is_empty():
			continue
		var rest := cmd.substr(from + role.length() + 1)
		var digits := ""
		for c in rest:
			if c < "0" or c > "9":
				break
			digits += c
		if not digits.is_empty():
			return int(digits)
	return 0


# 清理过期日志目录，按修改时间排序保留最新记录。
static func _prune_log_dirs() -> int:
	var root := AppPaths.log_dir()
	var da := DirAccess.open(root)
	if da == null:
		return 0
	var my_pid := OS.get_process_id()
	var dead: Array = []
	for dir_name in da.get_directories():
		var owner := Meta.et_log_dir_owner(dir_name)
		if owner <= 0 or owner == my_pid or OS.is_process_running(owner):
			continue
		dead.append([_dir_mtime(root.path_join(dir_name)), root.path_join(dir_name)])
	var excess := dead.size() - Meta.ET_LOG_KEEP
	if excess <= 0:
		return 0
	dead.sort()
	for e in dead.slice(0, excess):
		_remove_dir_recursive(e[1])
	return excess


# 获取日志目录的最近修改时间戳。
static func _dir_mtime(dir: String) -> int:
	var t := FileAccess.get_modified_time(dir.path_join("easytier.log"))
	if t > 0:
		return t
	return FileAccess.get_modified_time(dir)


# 递归删除指定目录及其内容。
static func _remove_dir_recursive(path: String) -> void:
	var da := DirAccess.open(path)
	if da != null:
		for f in da.get_files():
			da.remove(f)
		for d in da.get_directories():
			_remove_dir_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)


## 轮询对端列表直到检测到房主条目。
static func _await_host_peer() -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(CLIENT_WAIT * 1000.0)
	var last_err := ""
	while Time.get_ticks_msec() < deadline:
		var r := await _cli_async(PackedStringArray([
			"--rpc-portal", "127.0.0.1:%d" % _rpc_port, "-o", "json", "peer"]))
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


## 解析 CLI 输出的 JSON 对等节点列表，解析失败返回空数组。
static func parse_peers_json(text: String) -> Array:
	var s := text.strip_edges()
	if s.is_empty():
		return []
	var j := JSON.new()
	if j.parse(s) != OK:
		return []
	var parsed = j.data
	if typeof(parsed) == TYPE_ARRAY:
		return parsed
	if typeof(parsed) == TYPE_DICTIONARY:
		for k in ["peers", "peer_routes", "data"]:
			var v = (parsed as Dictionary).get(k, null)
			if typeof(v) == TYPE_ARRAY:
				return v
	return []


## 异步执行命令行工具，避免阻塞主线程。
static func _cli_async(args: PackedStringArray) -> Array:
	if _cli_path.is_empty():
		return [1, "easytier-cli 路径为空"]
	var t := Thread.new()
	if t.start(_exec_sync.bind(_cli_path, args)) != OK:
		return _exec_sync(_cli_path, args)
	while t.is_alive():
		await _sleep(0.05)
	return t.wait_to_finish()


static func _exec_sync(exe: String, args: PackedStringArray) -> Array:
	var out: Array = []
	var code := OS.execute(exe, args, out, true)
	return [code, "\n".join(PackedStringArray(out))]


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
	return AppPaths.easytier_dir().path_join(Meta.RELAY_FILE_NAME)


## 确保公共节点配置文件存在，若缺失则创建空白文件。
static func ensure_relay_file() -> void:
	var path := relay_file()
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(AppPaths.easytier_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.close()
	print("[tunnel] 已生成空的公共节点列表 %s(里面还没有节点)" % path)


# 规范化节点地址协议头，无协议头时默认添加 tcp:// 前缀。
static func _normalize_relay(s: String) -> String:
	var t := s.strip_edges()
	if t.contains("://"):
		return t
	return "tcp://" + t


## 检查是否配置了可用的初始公共节点。
static func has_initial_peers() -> bool:
	return not relay_list().is_empty()


## 未配置公共节点时的界面提示文案。
static func no_relay_hint() -> String:
	if has_initial_peers():
		return ""
	return "%s 里一个初始节点都没有 —— 别人远程进不来(每行一个地址,改完重进房间生效)" % relay_file()


# 配置核心程序文件日志输出路径与轮转参数。
static func _append_file_logging(args: PackedStringArray, role: String) -> void:
	var dir := AppPaths.log_dir().path_join(Meta.et_log_dir_name(role))
	DirAccess.make_dir_recursive_absolute(dir)
	args.append("--file-log-level")
	args.append("info")
	args.append("--file-log-dir")
	args.append(dir)
	args.append("--file-log-size")
	args.append("5")
	args.append("--file-log-count")
	args.append("3")


static func _append_relay(args: PackedStringArray) -> void:
	var relays := relay_list()
	if relays.is_empty():
		push_warning("Tunnel: %s 里一个节点都没有 —— 两端无法互相发现" % relay_file())
	for r in relays:
		args.append("-p")
		args.append(r)


# 动态分配一个本机空闲的 TCP 端口作为 RPC 门户监听端口。
static func _pick_rpc_port() -> int:
	var srv := TCPServer.new()
	if srv.listen(0, "127.0.0.1") != OK:
		return 0
	var port := srv.get_local_port()
	srv.stop()
	return port
