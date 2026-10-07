class_name Tunnel
extends RefCounted

# 远程联机的**隧道编排**:把 EasyTier(no-tun 用户态协议栈)当成一块"软件网卡"用,
# 让两台互不可见的机器上出现一个虚拟网段(10.126.126.0/24),再把游戏那一个 UDP 端口穿过去。
#
# ── 为什么是 no-tun ──
# 装 TUN 虚拟网卡要管理员权限(WinTun 驱动),而本项目的硬约束是**双击即玩、不弹 UAC**。
# EasyTier 的 `--no-tun` 走内嵌 smoltcp,在用户态把虚拟网段的包接进本机 socket,
# 于是"虚拟网 IP:端口 ↔ 127.0.0.1:端口"的映射不需要任何驱动。代价是没有 ICMP/广播。
# - 入站那一侧**不需要**任何参数:EasyTier 自带用户态 NAT 代理,按 NAT 条目把虚拟网上发往
#   本机虚拟 IP 的包交给本机对应端口(细节与出处见下面「端口方向」一节)。
#
# ── 端口方向(极易写反,故写在这里)──
#   - 房主**不需要任何转发参数**:无 TUN 模式下 EasyTier 自带用户态 NAT 代理
#     (`easytier-core/src/gateway/proxy/udp_proxy_engine.rs` 的 `UdpNatEntry`),把虚拟网上
#     发往本机虚拟 IP 的包按 NAT 条目代收给本机对应端口,回包原路改写送回。
#     - 每个来源 socket 一条 NAT 条目、**每条目一个本机 socket**
#       (源码里的测试名:`reuses_one_host_socket_per_nat_entry_and_recreates_after_close`)
#        ->  N 个客机在服务端看来是 N 个不同的本机来源,不会混淆。
#     - 主机头的 P 必须是**客户端挑的那个随机端口**(服务端绑的那个),不是别的数。
#   - `port-forward add udp 127.0.0.1:Q <房主IP>:P`(客机)= **出站**代理:本机 `127.0.0.1:Q`
#     → 虚拟网 `<房主IP>:P`。故客机的游戏客户端连的是 `127.0.0.1:Q`,不需要认识虚拟网。
#     - Q 与 P **不是一个数**:Q 是本机临时挑的空闲口(见 `_pick_free_port`)。曾经让 Q=P,
#       结果同一台机器上开两个游戏互连时,房主的服务端正占着 `127.0.0.1:P`  ->  客机的转发
#       绑定冲突、起不来(2026-10-01 用户实测)。
#     - 绑回环而不是全接口:只有**本机**的游戏客户端会拨它(手填地址那条路已整体删除),
#       而绑 `0.0.0.0` 会让同局域网的人绕过隧道直接灌房主服务端。
#   - 房主原先带过一个 `--udp-whitelist P`、客机带过 `--udp-whitelist 0 --tcp-whitelist 0`。
#     注意： 查源码后确认**都要删**(2026-09-30 设计约定):
#       - 它们生成的是一条**入站 ACL**(`config/peers.rs::generate_acl_from_whitelists`:
#         放行列出的端口 + 其余 Drop;不配时入站默认就是放行,见 `acl/processor.rs` 的
#         `unwrap_or(Action::Allow)`);
#       - 而这条 ACL **只被 TCP 那条代理路径消费**(`gateway/proxy/proxy_acl.rs` 只出现在
#         `wrapped_tcp_proxy.rs` 与 `wrapped_transport_destination.rs`);
#       - **UDP 数据面完全不查 ACL** —— `udp_proxy_engine.rs` / `udp_socket_runtime.rs`
#         里没有任何 ACL 代码,唯一的拒绝判据是 `should_deny_udp_proxy`(只拦"目标端口上
#         正好有 EasyTier 自己的监听器",防自我回环)。
#        ->  **我们这套的报文全是 UDP,`--udp-whitelist` 从来没起过作用**(房主那条也白写);
#         客机的 `--tcp-whitelist 0` 倒是真的在拒 TCP 入站,现已一并删除。
#       - 代价如实记:删掉后,同网络里的人可以通过虚拟 IP 访问到两台机器本机的 UDP 端口。
#
# ── 端口是怎么从房主传到客机的 ──
# 房间码只决定网络名/密钥,**不含端口**。端口走 **hostname**:房主把自己那个 P 拼进主机名
# (`cyr-host-<P>`,见 TunnelMeta.HOST_PREFIX),客机在 peer 列表里找这条、从尾部切出 P。
# - 这条通道不是"顺手用一下":EasyTier 的 peer 列表本来就是**对端可读的元数据**,
#   复用它就不必自己造一条带外的交换协议(造了就得解决"客机怎么知道去哪问"这个先有鸡还是先有蛋)。
# - 改前缀 = 改协议,两端必须同一个 build。
#
# ── 本模块纯逻辑接口 ──
# 字符串与列表处理函数（如 generate_room、is_valid_room、room_credentials、host_port_of、
# pick_host_peer）均为纯函数实现，便于独立进行单元测试；进程与系统调用逻辑集中在运行期方法中。

const Meta := preload("res://core/config/tunnel_meta.gd")

# 房间码:恰好 5 位十进制(含前导 0),`00000` 合法。
const ROOM_DIGITS := 5
const ROOM_MAX := 99999
# 客机等房主出现的上限(秒)。EasyTier 建网 + 打洞通常在数秒内,60s 是"网络确实不通"的量级。
const CLIENT_WAIT := 60.0
# 房主侧等本机 RPC 门户可用(秒):只是等 easytier-core 起来,不需要等任何人。
const HOST_WAIT := 20.0
# CLI 轮询间隔(秒)。每次 CLI 调用本身要 0.1~1s,故这是下限而非实际周期。
const POLL_INTERVAL := 1.0
# `port-forward add` 的重试次数(下发失败多半是 RPC 门户还没就绪)。
const FORWARD_TRIES := 3

static var _pid := 0            # easytier-core 的进程 id(0 = 没起)
static var _rpc_port := 0       # 本端 RPC 门户端口
static var _role := ""          # "host" / "guest"(排错用)
# 本端转发绑在本机的哪个端口(0 = 没有转发 = 本端是房主)。见 `forward_port()`。
static var _forward_port := 0
# 本端内核当前运行的网络房间号。空表示未启动网络。
# 网络名称由房间号派生（cyr-<码>），切换房间需重启网络。
static var _code := ""          # 本端内核当前所在的网名来源(5 位房号)
static var _core_path := ""     # 缓存的可执行文件绝对路径
static var _cli_path := ""
static var _reaped := false     # 标记当前进程是否已执行残留进程清理（单进程只执行一次）


# ── 房间码 ──

## 5 位房间码。-  用 `randi_range` 而不是 `randi() % 100000`:后者在 2^32 不是 10 万的整数倍时
## 有约 2e-5 的偏置(`randi_range` 内部走拒绝采样,无偏)。
## - 格式串必须**写死位数**(`%05d`):GDScript 的 `%` 不支持 C 那样的 `*` 动态宽度,
##   写成 `"%0*d"` 只会得到字面量输出或报错 —— 而"房间码变成 %0*d"这种事不会崩,只会静默错。
static func generate_room() -> String:
	return "%05d" % randi_range(0, ROOM_MAX)


## 恰好 5 位十进制数字才算合法。-  `00000` 合法(前导 0 是**格式**不是"没填")。
static func is_valid_room(s: String) -> bool:
	if s.length() != ROOM_DIGITS:
		return false
	for i in range(s.length()):
		var c := s[i]
		if c < "0" or c > "9":
			return false
	return true


## 房间码 → EasyTier 的网络名/密钥。直接拼接,不做哈希 —— 两端各算一次必须逐字相同。
static func room_credentials(code: String) -> Dictionary:
	return {
		"network_name": Meta.NET_PREFIX + code,
		"network_secret": code,
	}


## 房主主机名 → 端口。不是房主条目 / 尾部不是数字 → -1(调用方据此判"这条不是我要的")。
static func host_port_of(hostname: String) -> int:
	if not hostname.begins_with(Meta.HOST_PREFIX):
		return -1
	var tail := hostname.substr(Meta.HOST_PREFIX.length())
	if tail.is_empty() or not tail.is_valid_int():
		return -1
	var p := int(tail)
	return p if p > 0 and p < 65536 else -1


## 从 `easytier-cli -o json peer` 的解析结果里挑出房主那一条:{ipv4, hostname, port}。
## 找不到 → 空字典。-  本机那条(`cost == "Local"`)的 ipv4 是房主自己,客机必须**跳过**它 ——
## 客机上本机条目不会以 `cyr-host-` 开头,故前缀判据天然把它排除,这里只显式挡一次。
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


# ── 可执行文件 ──

static func ensure_downloaded() -> bool:
	if available():
		return true
	push_error("Tunnel: 找不到 EasyTier 的 %s / %s / %s。请运行 tools/fetch_easytier.py 下载(%s,%s),"
			% [Meta.CORE_EXE, Meta.CLI_EXE, Meta.CORE_DLLS[0], Meta.release_url(), Meta.LICENSE_NAME]
			+ "或手动把**整包**里的文件放进 %s" % AppPaths.easytier_dir())
	return false


## 可执行文件齐了吗?**不报错、不打印** —— 给"要不要走这条路"的调用方问路用。
## 与 `ensure_downloaded()` 的分工:那个是"我要用了,没有就吵",这个是"有吗?"。
## - 未安装**不阻塞建房**(房间照样开得出来),但它意味着**这个房谁也进不来** ——
##   2026-09-29 起手填地址那条路已删,没有"退回局域网直连"这一说。故调用方要在界面上
##   给出明确错误提示楚(见 `matchmaking._on_room_created` 的 note),而不是只弹一条无害的红字。
## 注意： **必须连 `Packet.dll` 一起查**(见 TunnelMeta.CORE_DLLS):少了它的表现不是"隧道起不来"
##   而是 `easytier-core.exe` **根本加载不了**(0xC0000135、零输出),而那种失败在客户端侧看起来
##   与"打洞失败"一模一样 —— 一个字的区别都没有。把它算进"齐不齐"是唯一能在**动手之前**
##   分辨这两件事的地方。
## - 只看**一个**目录:`<游戏目录>/easytier/`(见 AppPaths)。四件套只有这一个家 ——
##   发布包里这样摆,`tools/fetch_easytier.py` 也下到这里,开发态相同(仓库根 + `/easytier`)。
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


## 未安装时给玩家看的一句话(界面文案的唯一来源:别在 UI 里再拼一遍文件名与脚本名)。
## - 文案里点明"**整包**"是有来历的:只挑两个 exe 复制过去会得到一个**加载不了的** easytier-core
##   (缺 `Packet.dll`),而那看起来和"打洞失败"一模一样。见 TunnelMeta.CORE_DLLS。
static func missing_hint() -> String:
	return "未找到 EasyTier(%s / %s / %s)—— 运行 tools/fetch_easytier.py 下载,或把**整包**里的文件放进 %s" % [
			Meta.CORE_EXE, Meta.CLI_EXE, Meta.CORE_DLLS[0], AppPaths.easytier_dir()]

static func cli_exe() -> String:
	return _cli_path


static func rpc_port() -> int:
	return _rpc_port


# ── 房主 ──

## 起房主隧道:入站代理 UDP `port`。**不等任何对端** —— 房主自己就是那个对端,它的游戏客户端
## 连的是 127.0.0.1,与隧道无关,故这里同步返回即可。
## 返回 true 只代表"进程起来了",不代表客机已经能连上;真正的判据是客机那边解析出房主条目。
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
		# - 端口传给客机的**唯一**通道(见文件头)
		"--hostname", Meta.HOST_PREFIX + str(port),
		"--rpc-portal", "127.0.0.1:%d" % _rpc_port,
		"--private-mode", "true",
		# - 2026-10-03 全走 UDP:监听**只留 UDP**(随机端口),删掉 tcp 监听  ->  对端之间
		#   物理上无法建立 TCP 直连。依据:ENet 数据报被塞进 TCP mesh 会队头阻塞
		#   (实测 511ms 尖峰 + 本机 TCP-only 复现实验,字节计数器逐字节穿过)。
		#   --default-protocol udp:出站默认 UDP;--disable-tcp-hole-punching:不做 TCP 打洞;
		#   --latency-first:多条 UDP 路径(直连/中继)间自动挑延迟最低的。
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


## 房主侧"隧道就绪":本机 RPC 门户能应答。只证明 easytier-core 活着,不证明打洞成功
## (那要等有客机进来;房主界面不需要因此拦住玩家)。
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


# ── 客机 ──

## 起客机隧道并**自动下发转发**。返回 `{port, host_ip}`(port = 房主那个游戏端口),
## 失败返回空字典(调用方据此提示,不要猜一个端口出来)。
## 全程约 3~10s;上限 `CLIENT_WAIT` 秒。
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
		# 全走 UDP,同 start_host(注释在那边):只留 UDP 监听,禁 TCP 打洞。
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


## 客机主机名后缀。它只是给人看的标识(排错时能分清谁是谁),不参与任何判据。
static func guest_suffix() -> String:
	return "%08x" % randi()


## 下发 UDP 出站转发:本机 `127.0.0.1:P` → 虚拟网 `<host_ip>:P`。
## - 2026-09-30 由 `0.0.0.0` 收成 `127.0.0.1`:原注释写的理由是"游戏客户端要连的地址
##   由玩家/大厅页给(可能是局域网里另一台跑着同一套隧道的机器)"—— 而**那个手填地址的
##   功能早已整体删除**(见 `LobbyPage._join_with_code`:客机路径恒把 `server_address`
##   设成 `127.0.0.1`,房主路径本来就是本机), ->  没有任何调用方会去拨局域网地址,
##   那条理由随之消失。绑全接口的两个坏处还在:同局域网的人可以**直接往这个口灌包**
##   (等于绕过隧道直连房主的服务端),以及更容易撞上本机别的程序占用的端口。
##   - 服务端的回包沿同一条映射回来,客机**不需要**接受任何入站  ->  收窄没有副作用。
static func add_udp_forward(port: int, host_ip: String) -> bool:
	# 注意： 本机绑一个**自己挑的**空闲口 Q,不复用房主那个端口号(2026-10-01 设计约定)。
	#   复用时"一台机器开两个游戏互连"必失败:房主那台服务端正占着 `127.0.0.1:P`,
	#   客机的转发再要绑同一个地址  ->  EasyTier 绑定冲突,转发根本起不来。
	#   解耦之后跨机行为不变(房主看不见 Q),同机也能自测。
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


# 挑一个本机空闲的 UDP 端口给转发绑定用:直接向 OS 要(bind 127.0.0.1:0,由系统从动态口池
# 发一个**当前空闲**的号),拿到立刻释放 —— 号本身没有语义。此前在 20000~59999 里随机选取再逐个
# 试绑,探测与真绑之间整段都是竞态;OS 发号结构上不会撞任何已绑端口,只剩"释放→内核真绑"
# 的启动窗口(PCL-CE `NewTcpPort` 相同实现方式,2026-10-04 设计约定)。失败返回 0,调用方按致命错处理。
static func _pick_free_port() -> int:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		return 0
	var p := probe.get_local_port()
	probe.close()
	return p


## 本端转发绑在本机的哪个端口(0 = 没有转发  ->  本端是房主)。
## - 客机的游戏客户端连的**就是它**(不再是房主那个端口号)。
static func forward_port() -> int:
	return _forward_port


# ── 生命周期 ──

## 停止当前对等隧道。退出游戏时调用以确保后台独立进程被正常关闭；
## 若遇异常退出，则由 _reap_orphans 在下次启动时自动保底处理清理。
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


## 本端内核当前所在的那张网是哪个房号("" = 没起网)。见 `_code` 的注释:网名派生自房号,
## 所以这一个字段同时回答"有没有网"和"是哪张网"。
static func current_code() -> String:
	return _code


## 本端是否**已经在这串码对应的那张网上**。调用方拿它替代裸 `is_running()`:
## 房主换房要重起(码变了),而同一间房的状态反复刷新不能重起(码没变)。
static func on_network(code: String) -> bool:
	return code != "" and _code == code and is_running()


static func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


# ── 残留后台进程清理（异常退出的保底处理）──

## 启动隧道前执行（start_host / start_client 均会调用，每个游戏进程仅执行一次）。
## 由于 easytier-core 是独立系统进程，在游戏异常崩溃或被强制结束时无法正常执行 stop()，
## 残留的后台进程会持续占用本地端口与虚拟网地址。在此处进行残留进程的检测与回收：
##   - 清理残留内核：根据命令行中包含的本游戏日志路径识别由本游戏启动的进程；
##     从日志目录名称中解析父进程 PID，若该游戏进程已不存在，则终止该残留进程。
##     若父进程仍在运行（如本地双开互连）则保持原样，不干扰其他实例；外部手动启动的进程亦不作处理。
##   - 清理旧日志目录：对于父进程已退出的日志目录，按修改时间倒序保留最新的 Meta.ET_LOG_KEEP 份，
##     清理超期日志，既保留现场供排查又避免占用过多磁盘空间。
## 进程活跃检测使用 OS.is_process_running。
static func _reap_orphans() -> void:
	if _reaped:
		return
	_reaped = true
	var killed := _reap_orphan_cores()
	var pruned := _prune_log_dirs()
	if killed > 0 or pruned > 0:
		print("[tunnel] 孤儿清扫:终结 %d 个残留内核,删掉 %d 份过期日志(保留最近 %d 份)"
				% [killed, pruned, Meta.ET_LOG_KEEP])


## 本游戏启动过的 easytier-core 在命令行里的共同特征:`--file-log-dir` 落在本游戏的 log/ 下、
## 以 `easytier-` 开头(见 `_append_file_logging`);别的 easytier 进程都没有这段路径。
## - 两处必须用同一套 path_join 拼法,这个前缀(含分隔符)才逐字一致。
static func _et_log_marker() -> String:
	return AppPaths.log_dir().path_join(Meta.ET_LOG_DIR_PREFIX)


## 终止归属进程已退出的残留后台核心进程，返回成功终止的数量。
## 通过 PowerShell Win32_Process 查询进程命令行，准确提取所属父进程 PID 进行判定。
## 查询失败时不作处理，确保安全性（只允许漏删，严禁误杀其他正常进程）。
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
		# 三重校验：确认是由本游戏启动、可正确解析父进程 PID、且对应父进程已不存在（且非当前进程）。
		if et_pid <= 0 or not cmd.contains(marker):
			continue
		var owner := _owner_pid_of(cmd)
		if owner <= 0 or owner == my_pid or OS.is_process_running(owner):
			continue
		if OS.kill(et_pid) == OK:
			killed += 1
			print("[tunnel] 已终结残留内核 pid=%d(拉起它的游戏 pid=%d 已退出)" % [et_pid, owner])
	return killed


## 从 easytier-core 的命令行里解出启动它的游戏 pid(日志目录名的尾段),0 = 解不出。
## 命令行里 `easytier-` 会先撞上内核自己的名字(easytier-core.exe),所以要逐处扫、
## 只认 `easytier-(host|guest)-<数字>` 这一种形状。
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


## 旧日志目录截断:只动 `easytier-(host|guest)-<pid>` 形状、且 owner 已死的目录;
## 按 mtime 从旧到新删,保底最近 `Meta.ET_LOG_KEEP` 份。返回删除个数。
## - 目录的 owner pid 就写在名字里,基于纯 GDScript 实现存活检测,**不依赖**上面那次 PowerShell 查询。
static func _prune_log_dirs() -> int:
	var root := AppPaths.log_dir()
	var da := DirAccess.open(root)
	if da == null:
		return 0
	var my_pid := OS.get_process_id()
	var dead: Array = []          # [mtime, 绝对路径],按 mtime 升序排
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


## 目录的"最后活动"时间:取内核日志文件的 mtime(目录本体在 Windows 上不一定给得出)。
## 取不到 → 0,按最旧处理 —— 没有日志的死目录没有留的价值。
static func _dir_mtime(dir: String) -> int:
	var t := FileAccess.get_modified_time(dir.path_join("easytier.log"))
	if t > 0:
		return t
	return FileAccess.get_modified_time(dir)


## 递归删目录(引擎 4.x 没有把 3.x 的 remove_recursive 带过来)。删不掉的(文件还被进程
## 占着之类)就留着,不报错 —— 下次清扫再试。
static func _remove_dir_recursive(path: String) -> void:
	var da := DirAccess.open(path)
	if da != null:
		for f in da.get_files():
			da.remove(f)
		for d in da.get_directories():
			_remove_dir_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)


# ── 内部:CLI ──

## 轮询直到 peer 列表里出现房主条目。
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


## `-o json peer` 的 stdout → Array。-  解析失败一律返回**空数组**而不是报错:
## 轮询期间 CLI 可能因为 RPC 门户还没起来而输出不完整的 JSON 数据,那是正常的中间态。
## - 用 `JSON.new().parse()` 而不是静态的 `JSON.parse_string()`:后者会把解析失败**输出至控制台**
##   (`Parse JSON failed...`),而"轮询期间打了几十条这种红字"会让真问题淹没在里面。
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
	# 某些版本会把结果包一层(旧版/多实例输出)→ 尝试兼容解析，若仍失败则放弃
	if typeof(parsed) == TYPE_DICTIONARY:
		for k in ["peers", "peer_routes", "data"]:
			var v = (parsed as Dictionary).get(k, null)
			if typeof(v) == TYPE_ARRAY:
				return v
	return []


## 跑一次 easytier-cli,返回 `[exit_code, stdout]`。
## - 走线程:`OS.execute` 是**阻塞**的,而客机要轮询最多 60s —— 同步跑会让大厅页整个冻住
##   (每次 0.1~1s,看起来像卡死)。线程起不来时退回同步(宁可卡也不能不出结果)。
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


# ── 内部:命令行拼装 ──

## 初始节点列表(每个都变成一条 `-p`)。**只读 `easytier/relay.txt`**(游戏目录下,
## 每行一个,`#` 注释)—— 代码里没有内置表(2026-10-02 设计约定):初始节点是部署事实,
## 随发布包分发(`tools/archive_build.py`)+ 玩家可编辑,不进代码。
## - 文件缺失或全是注释 → 空列表  ->  `has_initial_peers()` 为假:客机侧 `_join_with_code`
##   的门控前置校验会拦下来给出明确错误提示,房主侧由 `no_relay_hint()` 在建房反馈里明确提示 ——
##   别让它退化成「找不到房间」那种把人引向错误方向的话。
static func relay_list() -> Array[String]:
	var f := FileAccess.open(relay_file(), FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	return parse_relay_lines(text)


## relay 行解析(纯函数,`-s` 可测):跳过空行与 `#` 注释,裸 `host:port` 自动补 `tcp://`。
## - 单独抽出来就是为了严格约束它 —— 节点表是两端各读一次的共享契约,解析错了的表现只是
##   "连不上",不会有任何报错(与 `pick_host_peer` 同一待遇)。
static func parse_relay_lines(text: String) -> Array[String]:
	var out: Array[String] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		out.append(_normalize_relay(line))
	return out


## 公共节点列表文件的绝对路径(`<游戏目录>/easytier/relay.txt`)。
## 界面要告诉玩家"去哪儿改节点",所以这个路径得有个**对外**的口 —— 别在 UI 里再拼一遍。
static func relay_file() -> String:
	return AppPaths.easytier_dir().path_join(Meta.RELAY_FILE_NAME)


## 列表文件不存在时,生成一份**空文件**(占位,一个节点都没有)。
## - 节点从哪来是部署事实:发布包随包分发一份带节点的 `relay.txt`(`tools/archive_build.py`);
##   开发态缺它就把地址写进这份文件再建房。
## - 已经存在就一个字都不动 —— 它是玩家的文件,不是我们的。**不写任何注释**:
##   玩家的文件保持保持原始格式，不追加额外注释,说明性文字归文档(2026-10-03 设计约定)。
static func ensure_relay_file() -> void:
	var path := relay_file()
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(AppPaths.easytier_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return                      # 目录只读之类:没有文件也不致命,照旧按"无节点"走
	f.close()
	print("[tunnel] 已生成空的公共节点列表 %s(里面还没有节点)" % path)


## `host:port` → `tcp://host:port`;已经是 URL 的原样返回。
## - 裸地址只自动补 tcp(2026-10-02 旧实测,当时 `udp://` 形式连不上;2026-10-03 换
##   2.7.0-custom 后 `udp://` 实测可用 —— relay.txt 已全量 udp://,真机日志确认连接成功)。
static func _normalize_relay(s: String) -> String:
	var t := s.strip_edges()
	if t.contains("://"):
		return t
	return "tcp://" + t


## 配了初始节点吗?**没配 = 客机不可能找到房主**(见 TunnelMeta 的实测订正)。
## 调用方据此给一句能看懂的提示,而不是让它退化成"找不到房间"。
static func has_initial_peers() -> bool:
	return not relay_list().is_empty()


## relay.txt 里一个节点都没有时给玩家看的一句话(与 `missing_hint()` 相同分工:界面文案的
## 唯一来源,别在 UI 里再拼一遍);返回空 = 有节点,界面不用多说。
## - 内置表删除(2026-10-02)之后,"隧道起来了但别人进不来"成了建房成功路径上**真实存在**
##   的一档 —— 三页都必须把它说出口,否则房主把码发出去,避免因缺少中继配置而直接报错“找不到房间”，导致用户无法排查具体原因。
static func no_relay_hint() -> String:
	if has_initial_peers():
		return ""
	return "%s 里一个初始节点都没有 —— 别人远程进不来(每行一个地址,改完重进房间生效)" % relay_file()


# 内核自己的文件日志(落在**游戏目录的 `log/`** 下):EasyTier 是 Rust 写的,
# 输出到管道时会缓冲,进程被杀时缓冲就丢了 —— 于是"两边为什么没遇上"在日志里一个字都看不到
# (2026-10-01 实测)。
# 用内核自带的 `--file-log-dir` 而不是套一层 cmd:套 cmd 会让 `OS.kill(_pid)` 杀到 cmd 而把内核
# 留成孤儿(残留内核会一直占着虚拟网 IP、把死房间挂在共享节点上,见 `_reap_orphans`)。
# - 目录名 = 角色 + 游戏进程 pid(`Meta.et_log_dir_name`):同机两条隧道(用户就是这么测同机
#   互联的)不会写同一个文件;尾部 pid 同时是**所有权标记** —— 孤儿清扫据此把"本游戏启动过的
#   内核"从命令行里识别解析。命名与解析是 TunnelMeta 里的一对函数,改必须两边同改。
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
		# - 内置表已删(2026-10-02):文件里没有节点就不带 `-p`。EasyTier 没有默认对等节点、
		#   也没有局域网发现  ->  这条内核在虚拟网上永远只有本机一条(后果按角色:房主=客机
		#   找不到你;客机=等满 60 秒也找不到房主)。真正拦人的话在 UI(`LobbyPage._join_with_code`
		#   的 `has_initial_peers` 闸 / 三页建房反馈的 `no_relay_hint`),这里是最后一道响,
		#   防"静默地起了一条没人能到的网"。
		push_warning("Tunnel: %s 里一个节点都没有 —— 两端无法互相发现" % relay_file())
	for r in relays:
		args.append("-p")
		args.append(r)


# RPC 门户端口:**用 TCP socket 向 OS 要一个当时空闲的口**(bind 127.0.0.1:0 → 读回 → 释放),
# 再以具体端口号传给内核。门户是 TCP 监听,探测类型必须同为 TCP —— UDP 空闲不代表 TCP 空闲,
# 故这里不能用 PacketPeerUDP(`_pick_free_port` 那个是 UDP 转发口,两者各用各的类型)。
# 动态分配 RPC 端口：通过操作系统绑定临时端口（OS ephemeral port）获取空闲端口，
# 避免与默认端口池重叠引起的绑定冲突。
# 失败返回 0，调用方作异常处理。
static func _pick_rpc_port() -> int:
	var srv := TCPServer.new()
	if srv.listen(0, "127.0.0.1") != OK:
		return 0
	var port := srv.get_local_port()
	srv.stop()
	return port
