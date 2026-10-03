class_name Tunnel
extends RefCounted

# 远程联机的**隧道编排**:把 EasyTier(no-tun 用户态协议栈)当成一块"软件网卡"用,
# 让两台互不可见的机器上出现一个虚拟网段(10.126.126.0/24),再把游戏那一个 UDP 端口穿过去。
#
# ── 为什么是 no-tun ──
# 装 TUN 虚拟网卡要管理员权限(WinTun 驱动),而本项目的硬约束是**双击即玩、不弹 UAC**。
# EasyTier 的 `--no-tun` 走内嵌 smoltcp,在用户态把虚拟网段的包接进本机 socket,
# 于是"虚拟网 IP:端口 ↔ 127.0.0.1:端口"的映射不需要任何驱动。代价是没有 ICMP/广播。
# ★ 入站那一侧**不需要**任何参数:EasyTier 自带用户态 NAT 代理,按 NAT 条目把虚拟网上发往
#   本机虚拟 IP 的包交给本机对应端口(细节与出处见下面「端口方向」一节)。
#
# ── 端口方向(极易写反,故写在这里)──
#   · 房主**不需要任何转发参数**:无 TUN 模式下 EasyTier 自带用户态 NAT 代理
#     (`easytier-core/src/gateway/proxy/udp_proxy_engine.rs` 的 `UdpNatEntry`),把虚拟网上
#     发往本机虚拟 IP 的包按 NAT 条目代收给本机对应端口,回包原路改写送回。
#     ★ 每个来源 socket 一条 NAT 条目、**每条目一个本机 socket**
#       (源码里的测试名:`reuses_one_host_socket_per_nat_entry_and_recreates_after_close`)
#       ⇒ N 个客机在服务端看来是 N 个不同的本机来源,不会串。
#     ★ 主机头的 P 必须是**客户端挑的那个随机端口**(服务端绑的那个),不是别的数。
#   · `port-forward add udp 127.0.0.1:Q <房主IP>:P`(客机)= **出站**代理:本机 `127.0.0.1:Q`
#     → 虚拟网 `<房主IP>:P`。故客机的游戏客户端连的是 `127.0.0.1:Q`,不需要认识虚拟网。
#     ★ Q 与 P **不是一个数**:Q 是本机临时挑的空闲口(见 `_pick_free_port`)。曾经让 Q=P,
#       结果同一台机器上开两个游戏互连时,房主的服务端正占着 `127.0.0.1:P` ⇒ 客机的转发
#       绑定冲突、起不来(2026-10-01 用户实测)。
#     ★ 绑回环而不是全接口:只有**本机**的游戏客户端会拨它(手填地址那条路已整体删除),
#       而绑 `0.0.0.0` 会让同局域网的人绕过隧道直接灌房主服务端。
#   · 房主原先带过一个 `--udp-whitelist P`、客机带过 `--udp-whitelist 0 --tcp-whitelist 0`。
#     ★★ 查源码后确认**都要删**(2026-09-30 用户裁定):
#       · 它们生成的是一条**入站 ACL**(`config/peers.rs::generate_acl_from_whitelists`:
#         放行列出的端口 + 其余 Drop;不配时入站默认就是放行,见 `acl/processor.rs` 的
#         `unwrap_or(Action::Allow)`);
#       · 而这条 ACL **只被 TCP 那条代理路径消费**(`gateway/proxy/proxy_acl.rs` 只出现在
#         `wrapped_tcp_proxy.rs` 与 `wrapped_transport_destination.rs`);
#       · **UDP 数据面完全不查 ACL** —— `udp_proxy_engine.rs` / `udp_socket_runtime.rs`
#         里没有任何 ACL 代码,唯一的拒绝判据是 `should_deny_udp_proxy`(只拦"目标端口上
#         正好有 EasyTier 自己的监听器",防自我回环)。
#       ⇒ **我们这套的报文全是 UDP,`--udp-whitelist` 从来没起过作用**(房主那条也白写);
#         客机的 `--tcp-whitelist 0` 倒是真的在拒 TCP 入站,现已一并删除。
#       ★ 代价如实记:删掉后,同网络里的人可以通过虚拟 IP 访问到两台机器本机的 UDP 端口。
#
# ── 端口是怎么从房主传到客机的 ──
# 房间码只决定网络名/密钥,**不含端口**。端口走 **hostname**:房主把自己那个 P 拼进主机名
# (`cyr-host-<P>`,见 TunnelMeta.HOST_PREFIX),客机在 peer 列表里找这条、从尾部切出 P。
# ★ 这条通道不是"顺手用一下":EasyTier 的 peer 列表本来就是**对端可读的元数据**,
#   复用它就不必自己造一条带外的交换协议(造了就得解决"客机怎么知道去哪问"这个先有鸡还是先有蛋)。
# ★ 改前缀 = 改协议,两端必须同一个 build。
#
# ── 本文件的可测面 ──
# 纯字符串/列表处理(`generate_room` / `is_valid_room` / `room_credentials` / `host_port_of` /
# `pick_host_peer`)全做成**静态无副作用**函数,`-s` 探针逐个钉住;起进程与跑 CLI 的部分
# 才碰 `OS`。

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
# 客机转发**绑定口**的取值范围与挑号次数(见 `_pick_free_port`)。
const FORWARD_PORT_LO := 20000
const FORWARD_PORT_HI := 59999
const FORWARD_PICK_TRIES := 8

static var _pid := 0            # easytier-core 的进程 id(0 = 没起)
static var _rpc_port := 0       # 本端 RPC 门户端口
static var _role := ""          # "host" / "guest"(排错用)
# 本端转发绑在本机的哪个端口(0 = 没有转发 = 本端是房主)。见 `forward_port()`。
static var _forward_port := 0
# ★★ 本端内核**正在跑的那张网**是哪个房号的(2026-09-30 加)。空 = 没起网。
#   ★ 必须记它,不能靠"有没有在跑"来判断 —— **网名是从房号派生的**(`cyr-<码>`)⇒
#     "换了一间房"就等于"要换一张网",而 `is_running()` 分不出"同一个码"和"另一个码"。
#     两个真 bug 都出在这个区分上:
#       ① 房主退出房间再建一间 → 旧闸 `not is_running()` 为假 ⇒ 网名**留在旧码上**
#          ⇒ 房主手里的新码对外**完全失效**(朋友拿新码进的是 `cyr-<新码>`,那网上没人);
#       ② 客户端已连着 A 时输 B 的码 → 见 `LobbyPage._join_with_code` 的判据。
static var _code := ""          # 本端内核当前所在的网名来源(5 位房号)
static var _core_path := ""     # 缓存的可执行文件绝对路径
static var _cli_path := ""


# ── 房间码 ──

## 5 位房间码。★ 用 `randi_range` 而不是 `randi() % 100000`:后者在 2^32 不是 10 万的整数倍时
## 有约 2e-5 的偏置(`randi_range` 内部走拒绝采样,无偏)。
## ★ 格式串必须**写死位数**(`%05d`):GDScript 的 `%` 不支持 C 那样的 `*` 动态宽度,
##   写成 `"%0*d"` 只会得到字面量输出或报错 —— 而"房间码变成 %0*d"这种事不会崩,只会静默错。
static func generate_room() -> String:
	return "%05d" % randi_range(0, ROOM_MAX)


## 恰好 5 位十进制数字才算合法。★ `00000` 合法(前导 0 是**格式**不是"没填")。
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
## 找不到 → 空字典。★ 本机那条(`cost == "Local"`)的 ipv4 是房主自己,客机必须**跳过**它 ——
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
			+ "或手动把**整包**里的文件放到游戏 exe 同目录。")
	return false


## 可执行文件齐了吗?**不报错、不打印** —— 给"要不要走这条路"的调用方问路用。
## 与 `ensure_downloaded()` 的分工:那个是"我要用了,没有就吵",这个是"有吗?"。
## ★ 未安装**不阻塞建房**(房间照样开得出来),但它意味着**这个房谁也进不来** ——
##   2026-09-29 起手填地址那条路已删,没有"退回局域网直连"这一说。故调用方要在界面上
##   把话说清楚(见 `matchmaking._on_room_created` 的 note),而不是只弹一条无害的红字。
## ★★ **必须连 `Packet.dll` 一起查**(见 TunnelMeta.CORE_DLLS):少了它的表现不是"隧道起不来"
##   而是 `easytier-core.exe` **根本加载不了**(0xC0000135、零输出),而那种失败在客户端侧看起来
##   与"打洞失败"一模一样 —— 一个字的区别都没有。把它算进"齐不齐"是唯一能在**动手之前**
##   分辨这两件事的地方。
static func available() -> bool:
	var dirs: Array = [OS.get_executable_path().get_base_dir()]
	if not OS.has_feature("template"):
		dirs.append(ProjectSettings.globalize_path("res://").path_join("tools/easytier"))
	dirs.append(ProjectSettings.globalize_path(Meta.USER_DIR))
	for d in dirs:
		var c := str(d).path_join(Meta.CORE_EXE)
		var l := str(d).path_join(Meta.CLI_EXE)
		var ok := FileAccess.file_exists(c) and FileAccess.file_exists(l)
		for dll in Meta.CORE_DLLS:
			if not FileAccess.file_exists(str(d).path_join(dll)):
				ok = false
		if ok:
			_core_path = c
			_cli_path = l
			return true
	return false


static func core_exe() -> String:
	return _core_path


## 未安装时给玩家看的一句话(界面文案的唯一来源:别在 UI 里再拼一遍文件名与脚本名)。
## ★ 文案里点明"**整包**"是有来历的:只挑两个 exe 复制过去会得到一个**加载不了的** easytier-core
##   (缺 `Packet.dll`),而那看起来和"打洞失败"一模一样。见 TunnelMeta.CORE_DLLS。
static func missing_hint() -> String:
	return "未找到 EasyTier(%s / %s / %s)—— 运行 tools/fetch_easytier.py 下载,或把**整包**里的文件放到游戏目录" % [
			Meta.CORE_EXE, Meta.CLI_EXE, Meta.CORE_DLLS[0]]

static func cli_exe() -> String:
	return _cli_path


static func rpc_port() -> int:
	return _rpc_port


# ── 房主 ──

## 起房主隧道:入站代理 UDP `port`。**不等任何对端** —— 房主自己就是那个对端,它的游戏客户端
## 连的是 127.0.0.1,与隧道无关,故这里同步返回即可。
## 返回 true 只代表"进程起来了",不代表客人已经能连上;真正的判据是客机那边解析出房主条目。
static func start_host(port: int, code: String) -> bool:
	if port <= 0 or not is_valid_room(code):
		push_error("Tunnel: 房主参数不合法(port=%d code=%s)" % [port, code])
		return false
	if not ensure_downloaded():
		return false
	_reap_stale()
	stop()
	var creds := room_credentials(code)
	_rpc_port = _pick_rpc_port()
	_role = "host"
	var args := PackedStringArray([
		"--no-tun",
		"-i", Meta.VIP_HOST,
		"--network-name", str(creds["network_name"]),
		"--network-secret", str(creds["network_secret"]),
		# ★ 端口传给客机的**唯一**通道(见文件头)
		"--hostname", Meta.HOST_PREFIX + str(port),
		"--rpc-portal", "127.0.0.1:%d" % _rpc_port,
		"--private-mode", "true",
		"-l", "udp://0.0.0.0:0",
		"-l", "tcp://0.0.0.0:0",
	])
	_append_relay(args)
	var pid := OS.create_process(_core_path, args)
	if pid <= 0:
		push_error("Tunnel: easytier-core 启动失败(%s)" % _core_path)
		_role = ""
		return false
	_pid = pid
	_code = code
	_write_pidfile(pid)
	print("[tunnel] 房主隧道启动 pid=%d 端口 %d 房间码 %s(rpc %d)" % [pid, port, code, _rpc_port])
	return true


## 房主侧"隧道就绪":本机 RPC 门户能应答。只证明 easytier-core 活着,不证明打洞成功
## (那要等有客人进来;房主界面不需要因此拦住玩家)。
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
	_reap_stale()
	stop()
	var creds := room_credentials(code)
	_rpc_port = _pick_rpc_port()
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
		"-l", "tcp://0.0.0.0:0",
	])
	_append_relay(args)
	var pid := OS.create_process(_core_path, args)
	if pid <= 0:
		push_error("Tunnel: easytier-core 启动失败(%s)" % _core_path)
		_role = ""
		return {}
	_pid = pid
	_code = code
	_write_pidfile(pid)
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
## ★ 2026-09-30 由 `0.0.0.0` 收成 `127.0.0.1`:原注释写的理由是"游戏客户端要连的地址
##   由玩家/大厅页给(可能是局域网里另一台跑着同一套隧道的机器)"—— 而**那个手填地址的
##   功能早已整体删除**(见 `LobbyPage._join_with_code`:客机路径恒把 `server_address`
##   设成 `127.0.0.1`,房主路径本来就是本机),⇒ 没有任何调用方会去拨局域网地址,
##   那条理由随之消失。绑全接口的两个坏处还在:同局域网的人可以**直接往这个口灌包**
##   (等于绕过隧道直连房主的服务端),以及更容易撞上本机别的程序占用的端口。
##   ★ 服务端的回包沿同一条映射回来,客机**不需要**接受任何入站 ⇒ 收窄没有副作用。
static func add_udp_forward(port: int, host_ip: String) -> bool:
	# ★★ 本机绑一个**自己挑的**空闲口 Q,不复用房主那个端口号(2026-10-01 用户裁定)。
	#   复用时"一台机器开两个游戏互连"必失败:房主那台服务端正占着 `127.0.0.1:P`,
	#   客机的转发再要绑同一个地址 ⇒ EasyTier 绑定冲突,转发根本起不来。
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


# 挑一个本机空闲的 UDP 端口给转发绑定用(试绑成功即认定可用、随后立刻释放 —— 这个号本身没有
# 语义,谁抢到算谁;真被抢了 `add_udp_forward` 的重试会再挑一个)。
# ★ 试绑用 ENetMultiplayerPeer 而不是 PacketPeerUDP:裁剪版导出模板里 PacketPeerUDP 类
#   被裁掉了(导出包里 Parse Error,整条 NetBus 编译失败——发布冒烟拦到过);ENet 是
#   联机本体的依赖,模板必带。
static func _pick_free_port() -> int:
	for i in range(FORWARD_PICK_TRIES):
		var p := randi_range(FORWARD_PORT_LO, FORWARD_PORT_HI)
		var probe := ENetMultiplayerPeer.new()
		if probe.create_server(p, 1) == OK:
			probe.close()
			return p
	return 0


## 本端转发绑在本机的哪个端口(0 = 没有转发 ⇒ 本端是房主)。
## ★ 客机的游戏客户端连的**就是它**(不再是房主那个端口号)。
static func forward_port() -> int:
	return _forward_port


# ── 生命周期 ──

## 接管上局残留的隧道:游戏崩溃/被强杀时 _exit_tree 不会跑,easytier-core 会变成孤儿
## (占着虚拟网 IP、旧的 5 位房号还在网上活着)。每次起隧道前先按 pidfile 收掉它。
## ★ 按 pidfile 而不是映像名杀:玩家手动开的 EasyTier GUI/MCTier 不受影响。
## ★ 杀之前用 tasklist 核对映像名 —— PID 会被系统复用,裸 pid 直杀可能误伤无关进程。
const PIDFILE := "user://tunnel.pid"

static func _reap_stale() -> void:
	var f := FileAccess.open(PIDFILE, FileAccess.READ)
	if f == null:
		return
	var pid := int(f.get_as_text().strip_edges())
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PIDFILE))
	if pid <= 0 or not OS.is_process_running(pid):
		return
	var out: Array = []
	OS.execute("C:/Windows/System32/tasklist.exe",
			PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]), out, false, false)
	var row := "\n".join(PackedStringArray(out))
	if not row.to_lower().contains("easytier-core"):
		return   # pid 已被系统复用给别的程序,不能碰
	OS.kill(pid)
	print("[tunnel] 已收掉上局残留的隧道 pid=%d" % pid)


static func _write_pidfile(pid: int) -> void:
	var f := FileAccess.open(PIDFILE, FileAccess.WRITE)
	if f != null:
		f.store_string(str(pid))
		f.close()


## 收掉本端隧道。★ 退出游戏时必须调(NetBus._exit_tree 已接);崩溃/强杀走不到这里
## 的场景由 `_reap_stale` 在**下一次**起隧道时兜底。
static func stop() -> void:
	if _pid > 0:
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		print("[tunnel] 已停止隧道 pid=%d(%s)" % [_pid, _role])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PIDFILE))
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


## `-o json peer` 的 stdout → Array。★ 解析失败一律返回**空数组**而不是报错:
## 轮询期间 CLI 可能因为 RPC 门户还没起来而打出半截 JSON,那是正常的中间态。
## ★ 用 `JSON.new().parse()` 而不是静态的 `JSON.parse_string()`:后者会把解析失败**打进控制台**
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
	# 某些版本会把结果包一层(旧版/多实例输出)→ 认一下再放弃
	if typeof(parsed) == TYPE_DICTIONARY:
		for k in ["peers", "peer_routes", "data"]:
			var v = (parsed as Dictionary).get(k, null)
			if typeof(v) == TYPE_ARRAY:
				return v
	return []


## 跑一次 easytier-cli,返回 `[exit_code, stdout]`。
## ★ 走线程:`OS.execute` 是**阻塞**的,而客机要轮询最多 60s —— 同步跑会让大厅页整个冻住
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

## 初始节点列表(每个都变成一条 `-p`)。
## 优先读 `user://easytier-relay.txt`(每行一个,`#` 注释),没有就用 `TunnelMeta.RELAYS`。
## ★ 做成**可配置**而不是编译期常量:初始节点是个部署事实(自建共享节点的地址),不该为了换它重新导出。
static func relay_list() -> Array[String]:
	var out: Array[String] = []
	var f := FileAccess.open(Meta.RELAY_FILE, FileAccess.READ)
	if f != null:
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.is_empty() or line.begins_with("#"):
				continue
			out.append(_normalize_relay(line))
		f.close()
	else:
		for r in Meta.RELAYS:
			out.append(_normalize_relay(str(r)))
	return out


## `host:port` → `tcp://host:port`;已经是 URL 的原样返回。
## ★ 只自动补 tcp:实测 `udp://` 形式的 `-p` 连不上(见 TunnelMeta 那段)。
static func _normalize_relay(s: String) -> String:
	var t := s.strip_edges()
	if t.contains("://"):
		return t
	return "tcp://" + t


## 配了初始节点吗?**没配 = 客机不可能找到房主**(见 TunnelMeta 的实测订正)。
## 调用方据此给一句能看懂的提示,而不是让它退化成"找不到房间"。
static func has_initial_peers() -> bool:
	return not relay_list().is_empty()


static func _append_relay(args: PackedStringArray) -> void:
	for r in relay_list():
		args.append("-p")
		args.append(r)


## 挑本机空闲的 TCP 口给 RPC 门户。★ 必须探活:区间下沿 15888 恰是 EasyTier 系工具
## (官方 GUI/MCTier)的默认门户,这台机器装着它们的概率不低 —— 撞上的表现是
## easytier-core 起来了但 RPC 不可用,客机端只剩一句"port-forward 连续失败"。
## 试绑用 TCPServer(RPC 门户本来就是 TCP);全部试绑失败则退回纯随机(老行为)。
static func _pick_rpc_port() -> int:
	var fallback := randi_range(Meta.RPC_PORT_LO, Meta.RPC_PORT_HI)
	for i in range(FORWARD_PICK_TRIES):
		var p := randi_range(Meta.RPC_PORT_LO, Meta.RPC_PORT_HI)
		var probe := TCPServer.new()
		if probe.listen(p, "127.0.0.1") == OK:
			probe.stop()
			return p
	return fallback
