extends SceneTree

# 远程联机的**纯逻辑**冒烟:房间码 / 地址解析 / 隧道输出解析 + 本次改造的三条核心契约。
# 跑法:`"$GODOT" --headless --path . -s res://tests/netplay_probe.gd`,成功打印 NETPLAY PROBE OK。
#
# ★ 为什么要有它:房间码的生成与派生是**两端各算一次**的东西(房主的网络名 = 客机要加入的网络名),
#   算错不会有任何运行时报错 —— 表现只是"客机一直找不到房主"。同理,客机从 `easytier-cli`
#   的输出里抠端口,抠错也只是"连不上"。这两处都是纯字符串函数,故在这里逐个钉死。
#
# ★ 反面教材(2026-09 参考 PCL-CE 的联机码实现时实测到的):它的 `Generate()` 算了
#   `validValue = randomValue - remainder` 却去编码 `randomValue` 本身,于是自己生成的码
#   **有 6/7 过不了自己的 TryParse**。所以本探针不测"看起来对",只测**往返**:生成的每一个码
#   都必须通过 `is_valid_room`,且 `room_credentials` 的输入输出一一对应。
#
# ★ 本探针**不起任何进程、不连任何端口** —— 它只读源码与跑纯函数,故可以随时跑、跑多少次都行。
#   真链路的隧道验收(两台机器打洞)是手工项,不在自动化里假装。

const Tunnel := preload("res://core/net/tunnel.gd")
const Meta := preload("res://core/config/tunnel_meta.gd")
const PvpSessionScript := preload("res://core/net/pvp_session.gd")

# 房间码均匀性抽样次数。10 万 = 每个首位数字期望 1 万次,足够把"前导 0 被吃掉"照出来。
const SAMPLES := 100000

var _fails: Array = []


func _check(cond: bool, what: String) -> void:
	if cond:
		print("ok - %s" % what)
	else:
		_fails.append(what)
		print("FAILED - %s" % what)


func _initialize() -> void:
	randomize()
	_phase_room_code()
	_phase_credentials()
	_phase_host_port()
	_phase_peer_parse()
	_phase_addr()
	_phase_meta()
	_phase_network_identity()
	_phase_paths()
	_phase_source_contracts()
	if _fails.is_empty():
		print("NETPLAY PROBE OK")
		quit(0)
	else:
		print("NETPLAY PROBE FAILED(%d 条)" % _fails.size())
		for f in _fails:
			print("  - %s" % f)
		quit(1)


# ── ① 房间码:恒 5 位数字,前导 0 不被吃掉 ──
func _phase_room_code() -> void:
	var first_digit := {}
	var distinct := {}
	var zero_lead := 0
	var bad_len := 0
	var bad_char := 0
	var round_trip_fail := 0
	for i in range(SAMPLES):
		var c := Tunnel.generate_room()
		if c.length() != Tunnel.ROOM_DIGITS:
			bad_len += 1
			continue
		if not Tunnel.is_valid_room(c):
			round_trip_fail += 1
		for j in range(c.length()):
			var ch := c[j]
			if ch < "0" or ch > "9":
				bad_char += 1
		first_digit[c[0]] = int(first_digit.get(c[0], 0)) + 1
		if c[0] == "0":
			zero_lead += 1
		distinct[c] = true
	_check(bad_len == 0, "generate_room() 恒为 %d 位(%d 次抽样里 %d 次长度不对)"
			% [Tunnel.ROOM_DIGITS, SAMPLES, bad_len])
	_check(bad_char == 0, "generate_room() 输出全是十进制数字(%d 个非法字符)" % bad_char)
	_check(round_trip_fail == 0,
			"generate_room() 的每个结果都能通过 is_valid_room(%d 次不一致)" % round_trip_fail)
	_check(zero_lead > 0, "抽样里出现以 0 开头的码 —— 前导 0 没被格式串吃掉")
	# 首位分布:每个数字期望 SAMPLES/10 次。二项分布 sd≈95,±3.5sd≈±330,这里放到 ±1500 仍然很紧,
	# 足够拦住"用了 %d 而不是 %05d"(那会让首位永远不是 0)与"用了低位取模"(会有明显偏置)。
	var lo := SAMPLES / 10 - 1500
	var hi := SAMPLES / 10 + 1500
	var worst := ""
	for d in range(10):
		var n := int(first_digit.get(str(d), 0))
		if n < lo or n > hi:
			worst = "首位 %d 出现 %d 次(期望 ~%d,允许 %d~%d)" % [d, n, SAMPLES / 10, lo, hi]
	_check(worst.is_empty(), "首位分布均匀%s" % ("" if worst.is_empty() else ":" + worst))
	# 生日问题:10 万次从 10 万个值里抽,期望约 6.32 万个不同值。低于 6 万说明取值空间变小了。
	_check(distinct.size() > 60000, "10 万次抽样得到 %d 个不同的码(期望 ~63200,>60000)"
			% distinct.size())

	# 合法/非法判据(逐条点名,失败时能一眼看出是哪一条)
	for bad in ["", "1234", "123456", "12a45", " 1234", "1234 ", "-1234", "１２３４５", "1234\n"]:
		_check(not Tunnel.is_valid_room(bad), "is_valid_room 拒绝 %s" % JSON.stringify(bad))
	for good in ["00731", "00000", "99999", "48213"]:
		_check(Tunnel.is_valid_room(good), "is_valid_room 接受 \"%s\"" % good)


# ── ② 凭据派生:两端各算一次,必须逐字相同且一一对应 ──
func _phase_credentials() -> void:
	var a := Tunnel.room_credentials("48213")
	_check(str(a.get("network_name", "")) == "cyr-48213",
			"network-name = NET_PREFIX + 码(\"cyr-48213\")")
	_check(str(a.get("network_secret", "")) == "48213", "network-secret = 码本身")
	var b := Tunnel.room_credentials("00000")
	_check(str(b.get("network_name", "")) == "cyr-00000",
			"前导 0 的码原样进网络名(不被 int 化吃掉:\"cyr-00000\")")
	# 一一对应:不同码必须得到不同网络名(拼接不会把两组合并)
	var seen := {}
	var dup := 0
	for i in range(2000):
		var c := Tunnel.generate_room()
		var n := str(Tunnel.room_credentials(c)["network_name"])
		if seen.has(n) and int(seen[n]) != int(c):
			dup += 1
		seen[n] = int(c)
	_check(dup == 0, "不同房间码的网络名互不相同(%d 次冲突)" % dup)


# ── ③ 主机名 → 端口(端口从房主传到客机的唯一通道)──
func _phase_host_port() -> void:
	_check(Tunnel.host_port_of("cyr-host-23117") == 23117, "cyr-host-23117 → 23117")
	_check(Tunnel.host_port_of("cyr-host-1") == 1, "cyr-host-1 → 1(边界)")
	_check(Tunnel.host_port_of("cyr-host-65535") == 65535, "cyr-host-65535 → 65535(上界)")
	for bad in ["cyr-host-", "cyr-host-0", "cyr-host-70000", "cyr-host--1", "cyr-host-ab",
			"cyr-guest-23117", "host-23117", ""]:
		_check(Tunnel.host_port_of(bad) == -1, "host_port_of 拒绝 \"%s\"" % bad)


# ── ④ easytier-cli -o json peer 的解析与挑选 ──
# 样例照**真输出**的形状写:每个对象带 cidr/ipv4/hostname/cost/lat_ms/loss_rate/…,
# 且本机那条排在最前(cost == "Local",lat_ms/loss_rate 是 "-" 而不是数字 —— 这是文档里
# 明确记过的一处:把它当成"房主"会让客机去连自己)。
const PEER_JSON := """[
  {
    "cidr": "10.126.126.3/24",
    "ipv4": "10.126.126.3",
    "hostname": "cyr-guest-1a2b3c4d",
    "cost": "Local",
    "lat_ms": "-",
    "loss_rate": "-",
    "id": "00000000-0000-0000-0000-000000000001",
    "version": "2.7.0"
  },
  {
    "cidr": "10.126.126.1/24",
    "ipv4": "10.126.126.1",
    "hostname": "cyr-host-23117",
    "cost": "p2p",
    "lat_ms": "3.10",
    "loss_rate": "0.0%",
    "id": "00000000-0000-0000-0000-000000000002",
    "version": "2.7.0"
  }
]"""


func _phase_peer_parse() -> void:
	var peers := Tunnel.parse_peers_json(PEER_JSON)
	_check(peers.size() == 2, "parse_peers_json 解出 2 条 peer(实得 %d)" % peers.size())
	var host := Tunnel.pick_host_peer(peers)
	_check(str(host.get("ipv4", "")) == "10.126.126.1",
			"pick_host_peer 跳过本机那条(cost=Local),挑到房主 10.126.126.1")
	_check(int(host.get("port", 0)) == 23117, "pick_host_peer 从主机名切出端口 23117")
	_check(str(host.get("hostname", "")) == "cyr-host-23117", "pick_host_peer 原样带回主机名")
	# 只有本机那条 → 找不到房主(返回值必须是空字典,不能猜一个)
	_check(Tunnel.pick_host_peer([peers[0]]).is_empty(), "只有本机条目时返回空(不猜端口)")
	# 房主条目缺 ipv4 → 同样不算找到(否则会去连一个空地址)
	_check(Tunnel.pick_host_peer([{"hostname": "cyr-host-23117", "ipv4": ""}]).is_empty(),
			"房主条目缺 ipv4 时返回空")
	# 坏输入一律空数组,不炸:轮询期间 CLI 可能打出半截 JSON,那是正常中间态
	for bad in ["", "   ", "not json", "{}", "[]", "[1,2,3]"]:
		var r := Tunnel.parse_peers_json(bad)
		_check(typeof(r) == TYPE_ARRAY, "parse_peers_json(%s) 返回数组而不是 null"
				% JSON.stringify(bad))
	_check(Tunnel.parse_peers_json("[1,2,3]").size() == 3, "非字典元素原样留着(挑选时跳过)")


# ── ⑤ 连接参数只剩 `PvpSession` 一处 ──
# ★ 2026-09-29:原先这里验的是"地址框 `host[:port]` 的切分/拼装"(`split_addr` / `join_addr`)。
#   手填地址那条路已整体删除 ⇒ 那两个函数也没了,本相改成钉**剩下的那条约束**:
#   ① 默认端口仍与 `NetBus.DEFAULT_PORT` 同值;② 全仓不得再出现那两个函数名
#   (反向断言,防止有人"顺手"把地址框加回来)。
func _phase_addr() -> void:
	# 与 NetBus 的默认端口同值:两个常量分居两个文件,漂了会让"手跑服务端(7777)"连不上。
	# ★ `-s` 探针里**没有 autoload**(这是本仓明文:见 CLAUDE.md §测试),故不能读 `NetBus.DEFAULT_PORT`;
	#   改成从**源码**里抠出那个字面量比对 —— 判据一样硬,且不依赖运行环境。
	var nb := _read("res://core/net/net_bus.gd")
	var m := RegEx.create_from_string("const\\s+DEFAULT_PORT\\s*:=\\s*(\\d+)").search(nb)
	_check(m != null, "能从 net_bus.gd 里读到 DEFAULT_PORT(判据本身的前置)")
	if m != null:
		_check(PvpSessionScript.DEFAULT_PORT == int(m.get_string(1)),
				"PvpSession.DEFAULT_PORT(%d)== NetBus.DEFAULT_PORT(%s)"
				% [PvpSessionScript.DEFAULT_PORT, m.get_string(1)])
	# 主菜单/大厅那三页都不得再出现地址框(它们曾经各有一份)
	# ★ 只查**代码行**:各文件里都留着"这里原先有什么"的历史注释,那是该留的 ——
	#   判据盯的是"还会不会被建出来/被读到",不是散文里提没提过这个名字。
	for f in ["res://scenes/lobby_page.gd", "res://scenes/matchmaking.gd",
			"res://scenes/royale_lobby.gd", "res://scenes/team_lobby.gd"]:
		var code := _code_only(_read(f))
		_check(not code.contains("_addr_edit"), "%s 不再有地址框" % f.get_file())
		_check(not code.contains("_connected_addr"), "%s 不再有地址比对" % f.get_file())
	var ps := _code_only(_read("res://core/net/pvp_session.gd"))
	_check(not ps.contains("split_addr") and not ps.contains("join_addr"),
			"pvp_session.gd 不再有地址解析/拼装(手填地址那条路已删)")
	var ls := _code_only(_read("res://core/net/local_server.gd"))
	_check(not ls.contains("lan_ip_hint"), "local_server.gd 不再有局域网 IP 提示")


## 去掉整行注释后的源码:反向断言只该盯代码,不该被历史注释误伤。
func _code_only(src: String) -> String:
	var out := PackedStringArray()
	for line in src.split("\n"):
		if not line.strip_edges().begins_with("#"):
			out.append(line)
	return "\n".join(out)


# ── ⑥ 元数据自洽 ──
func _phase_meta() -> void:
	_check(Meta.RELEASE_URL.count("%s") == 2,
			"RELEASE_URL 恰好两个 %s 占位(版本号出现两次)")
	_check(Meta.release_url().contains(Meta.ET_VERSION), "release_url() 里含当前版本号")
	_check(Meta.HOST_PREFIX.begins_with(Meta.NET_PREFIX),
			"主机名前缀以网络名前缀开头(同一套命名空间)")
	_check(Meta.HOST_PREFIX != Meta.GUEST_PREFIX, "房主/客机主机名前缀不同(否则两边互相认错)")
	_check(Meta.VIP_HOST.begins_with("10.126.126."), "房主固定 IP 落在虚拟网段内")
	_check(Tunnel.ROOM_DIGITS == 5, "房间码位数 = 5")


# ── ⑦ 网络身份:`current_code()` / `on_network()` 的语义(2026-09-30 加)──
# ★ 这两个口是为修两个真 bug 加的,而它们**都是纯语义**、错了不会崩,只会静默串网:
#   ① 房主退出房间再建一间 —— 旧闸 `not is_running()` 分不出"同一个码"与"另一个码"
#      ⇒ 网名留在旧码上 ⇒ **新码对外完全失效**(朋友拿新码进的是 `cyr-<新码>`,那网上没人);
#   ② 客户端已连着 A 时输 B 的码 —— 旧判据 `_connected and can_send_to_server()` 同样分不出
#      ⇒ B 的码被发去 **A 的服务器**,回一句把人引向"码敲错了"的「房间不存在」。
#   两处都靠"这串码是不是我当前所在的网"来判 ⇒ 那个判据本身必须有守卫。
func _phase_network_identity() -> void:
	# 没起网时:码为空、`on_network(任何码)` 一律假(含空串)。
	_check(Tunnel.current_code() == "", "未起网时 current_code() 为空")
	_check(not Tunnel.on_network("48213"), "未起网时 on_network(48213) 为假")
	_check(not Tunnel.on_network(""), "on_network(\"\") 恒假(空码不是一张网)")
	# `stop()` 必须把码也清掉,否则"停了还自称在某张网上"
	var tn := _strip_comments(_read("res://core/net/tunnel.gd"))
	_check(tn.contains("_code = \"\""), "Tunnel.stop() 清掉 _code")
	# 客机那跳转发只许绑本机回环(绑 0.0.0.0 = 同局域网可绕过隧道直连房主服务端);
	# ★ 且绑的是**自己挑的空闲口**(`_pick_free_port`),不复用房主端口号 —— 复用时同机两个
	#   实例必然绑定冲突(房主服务端占着那个号),这正是"一台机器开两个游戏互连"失败的原因。
	_check(tn.contains("\"127.0.0.1:%d\" % bind_port"), "客机转发绑 127.0.0.1 且用自选端口")
	_check(tn.contains("static func _pick_free_port()"), "自选端口来自 _pick_free_port()")
	_check(tn.contains("static func forward_port()"), "对外暴露 forward_port()(客机连它)")
	_check(not tn.contains("\"0.0.0.0:%d\" % port"), "客机转发不再绑 0.0.0.0")
	# 挑号写法(2026-10-04 裁定):两个本机口都由 **OS 发号**(bind :0 → 读回 → 释放),
	# 不再区间盲选 —— 盲选与 EasyTier 自家默认门户池(15888..15900)重叠,撞上即内核秒死
	# (exit 1、file log 零痕迹,2026-10-04 实测)。锁的是**写法**:探测类型必须与用途同族
	# (门户是 TCP ⇒ TCPServer;转发绑定是 UDP ⇒ PacketPeerUDP),以及不许回到区间盲选。
	_check(tn.contains("TCPServer.new()") and tn.contains("srv.listen(0, \"127.0.0.1\")"),
			"RPC 口 = TCP socket 向 OS 要(bind :0)")
	_check(tn.contains("probe.bind(0, \"127.0.0.1\")"), "转发绑定口 = UDP socket 向 OS 要(bind :0)")
	_check(not tn.contains("RPC_PORT_LO") and not tn.contains("FORWARD_PORT_LO"),
			"两个挑号都不再回到区间盲选")
	# 孤儿清扫(2026-10-04):游戏异常退出时 stop() 没机会跑,easytier-core 残留成孤儿。
	# 认领判据必须足够窄:命令行带本游戏日志根 + 目录名尾部的游戏 pid 已死,二者缺一不可 ——
	# 宽了会误杀同机另一局(双开互连)与玩家手动跑的内核,窄得只剩"杀进程"也会漏掉 ghost 房间。
	_check(tn.count("_reap_orphans()") >= 3, "start_host / start_client 起进程前各调一次孤儿清扫")
	_check(tn.contains("cmd.contains(marker)"), "内核认领只认命令行里的本游戏日志根路径")
	_check(tn.contains("OS.is_process_running(owner)"), "只终结 owner 已死的内核(双开互连不误杀)")
	_check(tn.contains("Meta.ET_LOG_KEEP"), "旧日志目录按保留份数截断(崩溃现场留给排查)")
	_check(tn.contains("Meta.et_log_dir_name(role)"), "et 日志目录名带游戏 pid(所有权标记)")
	var dn := Meta.et_log_dir_name("guest")
	_check(Meta.et_log_dir_owner(dn) == OS.get_process_id(), "目录名 ↔ owner pid 解析往返一致")
	_check(Meta.et_log_dir_owner("easytier-host") == 0, "旧格式目录(无 pid)不认领、不碰")
	_check(Meta.et_log_dir_owner("easytier-guest-12345") == 12345, "guest 目录同样解得出 owner")
	_check(Meta.et_log_dir_owner("easytier-别的-12345") == 0, "陌生名字一律不算本游戏的")
	# 客机把 `server_port` 取成自己的转发口;房主那边不许被 `go_match` 覆盖掉
	var lp2 := _strip_comments(_read("res://scenes/lobby_page.gd"))
	_check(lp2.contains("var fwd := Tunnel.forward_port()"), "加入时端口取本机转发口")
	_check(lp2.contains("and Tunnel.forward_port() <= 0:"),
			"go_match 只在没有转发的那一端(房主)才覆盖 server_port")
	# 判据落点:`_join_with_code` 的短路必须按**码**判,不许退回裸 `_connected`
	var lp := _strip_comments(_read("res://scenes/lobby_page.gd"))
	var jb := _func_body(lp, "_join_with_code")
	_check(jb.contains("Tunnel.on_network(code) and NetBus.can_send_to_server()"),
			"_join_with_code 的短路判据按码判(on_network)")
	_check(not jb.contains("if _connected and NetBus.can_send_to_server():"),
			"_join_with_code 里不再有\"已连着就直接用当前连接\"那条旧判据")
	_check(jb.contains("LocalServer.stop_owned()"),
			"_join_with_code 换网时收掉本机服务端(否则留下一台别人看得见、却开不了局的服务器)")
	# 房主起网闸门:三页都必须按码判(换了房号要重起、同码不重起)
	for f in ["res://scenes/royale_lobby.gd", "res://scenes/team_lobby.gd"]:
		_check(_strip_comments(_read(f)).contains("not Tunnel.on_network(code)"),
				"%s 的房主起网闸门按码判" % f.get_file())
	var mm := _func_body(_strip_comments(_read("res://scenes/matchmaking.gd")), "_on_room_created")
	_check(mm.contains("not Tunnel.on_network(code)"), "matchmaking 建房后起网闸门按码判")

	# ── 建房 = 在自己这台机器上开服(2026-09-30 用户裁定:"根本没有在别人电脑上建房的说法")──
	# ★ 判据必须是"连着的是不是我那台",不是"有没有连着"。后者会让**客机点建房**把建房 RPC
	#   发给房主的服务器,开出一间"房主是访客"的死房(外面进不来),而且客户端随后会去
	#   `Tunnel.start_host(…, 新房号)` —— 它此刻跑的是客机内核,`start_host` 开头就 `stop()`,
	#   于是**把自己到房主服务器的转发杀掉**、连接断掉,新起的房主隧道又指向本机
	#   那个端口(而服务端在房主那边)⇒ 白丢一条连接 + 一间谁也进不来的死房。
	var ls := _strip_comments(_read("res://core/net/local_server.gd"))
	_check(not ls.contains("owns_running"),
			"LocalServer 不再有 owns_running()(建房不再复用已有服务端)")
	var own := _func_body(lp, "_ensure_own_server")
	_check(not own.is_empty(), "LobbyPage._ensure_own_server 存在(三页共用的建房前置)")
	_check(own.contains("NetBus.stop()") and own.contains("Tunnel.stop()")
			and own.contains("LocalServer.stop_owned()"),
			"_ensure_own_server 无条件清理:旧连接 + 旧隧道 + 旧服务端")
	_check(own.contains("launch_and_connect()"),
			"_ensure_own_server 每次都从零启动服务端(不复用已连着的那台)")
	_check(not own.contains("owns_running"),
			"_ensure_own_server 不含「是否本机那台」的判断(建房 = 整套全新)")
	# 三页的建房都必须走这个前置,且不得再自己抄一份"拉服务端"的逻辑
	for f in ["res://scenes/matchmaking.gd", "res://scenes/royale_lobby.gd", "res://scenes/team_lobby.gd"]:
		var page := _strip_comments(_read(f))
		var cb := _func_body(page, "_on_create_pressed")
		_check(cb.contains("await _ensure_own_server()"), "%s 的建房走共用前置" % f.get_file())
		# ★ 顺序:准入检查必须在 `_ensure_own_server()` **之前** —— 后者是无条件"拆旧起新",
		#   在房里按建房会先把当前那局的服务端/隧道拆掉,随后才被 `_with_lobby` 拒绝。
		var gate := cb.find("_lobby_action_allowed()")
		_check(gate != -1 and gate < cb.find("_ensure_own_server()"),
				"%s 的建房先过准入检查、再动服务端与隧道" % f.get_file())
		_check(not cb.contains("launch_and_connect()"),
				"%s 的建房不再自己拉服务端(收在基类一处)" % f.get_file())
		_check(not cb.contains("if not _connected or not NetBus.can_send_to_server():"),
				"%s 的建房不再用「有没有连着」当判据" % f.get_file())

	# ── 倒计时的起点必须由服务器锚定(三模式都要重播)──
	# 客户端要切场景 + 建世界 + 建 HUD 才订阅得上,只广播一次会漏收(或迟到),
	# 两端各自本地走秒 ⇒ 起跑线差一整段场景加载时间。重播让"每次收到都重设"成立。
	var mr := _strip_comments(_read("res://server/match_round.gd"))
	_check(mr.contains("func _tick_countdown_sync"), "倒计时重播的共用实现在 MatchRound")
	for hf in ["res://server/match_round.gd", "res://server/royale_host.gd", "res://server/team_host.gd"]:
		var hsrc := _strip_comments(_read(hf))
		_check(hsrc.contains("_tick_countdown_sync(delta)"),
				"%s 的倒计时分支调了重播" % hf.get_file())
	for uf in ["res://ui/pvp_hud.gd", "res://ui/royale_hud.gd", "res://ui/team_hud.gd"]:
		var usrc := _strip_comments(_read(uf))
		var resets := usrc.contains("_countdown = float(data.get")
		_check(resets and usrc.contains("_countdown -= delta"),
				"%s 收到即重设剩余秒数、其后再本地走秒" % uf.get_file())

	# ── 入口按钮在"房里"时必须**置灰**(三页一致,2026-09-30 用户裁定:不隐藏)──
	# ★ 置灰的两个引用(`_create_btn` / `_join_btn`)与开关函数都在基类一处。
	var mmk := _strip_comments(_read("res://scenes/matchmaking.gd"))
	_check(mmk.contains('_create_btn = _page_button("建房"') and mmk.contains('_join_btn = _page_button("加入"'),
			"matchmaking 把建房/加入两颗按钮都记了引用")
	var srv := _func_body(mmk, "_set_in_room")
	_check(srv.contains("_set_entry_buttons_enabled(not in_room)"),
			"_set_in_room 按入房态切入口按钮的可用性")
	_check(not mmk.contains("_create_btn.visible"),
			"matchmaking 不再用「隐藏」表达在房里(改为置灰)")
	for pair in [["_on_room_created", "true"], ["_on_room_joined", "true"],
			["_on_return_to_lobby", "false"], ["_on_lobby_reconnect", "false"]]:
		var body := _func_body(mmk, str(pair[0]))
		_check(body.contains("_set_in_room(%s)" % str(pair[1])),
				"%s 调 _set_in_room(%s)" % [str(pair[0]), str(pair[1])])

	# ── 「刷新」/「刷新列表」按钮已删(2026-09-30 用户裁定:没用)──
	# ★ 反向断言,但**同时**钉死"干活的那个口还在"(`_request_list`)——
	#   否则把整个刷新机制删掉也能让下面这条绿,那是判据退化。
	var base := _strip_comments(_read("res://scenes/lobby_page.gd"))
	_check(base.contains("func _request_list("), "_request_list 仍在(刷新机制本身没被删)")
	_check(not base.contains("func _on_refresh_pressed("), "基类不再有 _on_refresh_pressed")
	for f in ["res://scenes/matchmaking.gd", "res://scenes/royale_lobby.gd", "res://scenes/team_lobby.gd"]:
		var src := _strip_comments(_read(f))
		_check(not src.contains("_on_refresh_pressed"),
				"%s 不再引用已删的 _on_refresh_pressed" % f.get_file())
		_check(not src.contains("_button(\"刷新"),
				"%s 不再有「刷新」按钮" % f.get_file())
	# 探针侧那几处"催刷新"也必须改走 `_request_list`(否则 `.call()` 打不存在的函数,静默失效)
	for f in ["res://tests/ground_net_watcher.gd", "res://tests/rejoin_watcher.gd",
			"res://tests/team_match_watcher.gd"]:
		_check(_strip_comments(_read(f)).contains("call(\"_request_list\""),
				"%s 的催刷新改走 _request_list" % f.get_file())


# ── ⑧ 本次改造的三条源码级契约 ──
# 这几条只有源码读得出来(它们是"结构"而不是"行为"),而三条各自对应一个**静默失效**:
func _phase_source_contracts() -> void:
	# ① `go_match` 不再断开/转连。写回去 = 客户端在大厅页把刚建好的连接拆掉再连一次,
	#    而单进程单端口下"另一个端口"根本不存在 ⇒ 表现是转连到一个没人监听的端口。
	var lp := _strip_comments(_read("res://scenes/lobby_page.gd"))
	var body := _func_body(lp, "_do_go_match")
	_check(not body.is_empty(), "lobby_page._do_go_match 存在")
	_check(not body.contains("NetBus.stop()"), "lobby_page._do_go_match 不再 NetBus.stop()(不转连)")
	_check(not body.contains("start_client"), "lobby_page._do_go_match 不再 start_client(不转连)")

	# ② 单端口下**任何连上来的 peer 都能发 claim_role**,隔离只剩"名册"这一道。
	#    漏了它 = 另一间房的玩家能被写进这一局的表(两间房的 role 互相顶掉,且不报错)。
	var ms := _strip_comments(_read("res://server/match_session.gd"))
	var claimed := _func_body(ms, "_on_role_claimed")
	_check(claimed.contains("roster.has(caller)"),
			"MatchSession._on_role_claimed 按名册挡串线(roster.has(caller))")

	# ③ 凭据的生死必须在"对局结束"那一刻收口。漏了它 = 凭据永远 alive,
	#    玩家点自己那间房会被送回一局早已不存在的对局(卡在等待配对)。
	var rm := _strip_comments(_read("res://server/room_manager.gd"))
	var fin := _func_body(rm, "_on_session_finished")
	_check(fin.contains("end_match("), "RoomManager._on_session_finished 作废该局凭据(end_match)")

	# ④ 每局一个子进程的形态不许偷偷回来
	_check(not FileAccess.file_exists("res://server/worker_launcher.gd"),
			"server/worker_launcher.gd 已删除(单进程形态)")
	var main_src := _strip_comments(_read("res://server/server_main.gd"))
	for flag in ["\"--worker\"", "\"--royale\"", "\"--team\"", "\"--roles\"", "\"--teams\""]:
		_check(not main_src.contains(flag), "server_main 不再解析 %s" % flag)


# ── ⑧ 目录布局:EasyTier 与三方日志各自的家(2026-10-02 加)──
# 布局是**游戏与发布包之间的口头契约**:包按这个摆、游戏按这个找。漂了不会报错,只会
# "文件明明在,游戏却说找不到"(或日志静静写到别处去),所以在这里钉死。
#   <游戏目录>/easytier/   easytier-core.exe / easytier-cli.exe / Packet.dll / wintun.dll
#                          + relay.txt(公共节点列表;代码里没有内置表,2026-10-02 起)
#   <游戏目录>/log/        client.log / server.log / easytier-{host,guest}/easytier.log
func _phase_paths() -> void:
	# 「游戏目录」在开发态 = 仓库根(`-s` 探针跑不到导出产物,故这里必然走 dev 分支)。
	# ★ 结尾斜杠必须去掉:开发态取自 `globalize_path("res://")`(带斜杠)、发布态取自 exe 目录
	#   (不带)—— 两种形态并存时"拿它俩判等"的地方会莫名其妙地失败。
	_check(not AppPaths.base_dir().ends_with("/"), "游戏目录不带结尾斜杠(两种来源形态一致)")
	_check(FileAccess.file_exists(AppPaths.base_dir().path_join("project.godot")),
			"开发态的游戏目录 = 工程目录(实得 %s)" % AppPaths.base_dir())
	var et := AppPaths.easytier_dir()
	_check(et.get_file() == "easytier", "EasyTier 目录名 = easytier(实得 %s)" % et.get_file())
	_check(AppPaths.log_dir().get_file() == "log",
			"日志目录名 = log(实得 %s)" % AppPaths.log_dir().get_file())
	_check(AppPaths.log_dir().get_base_dir() == AppPaths.base_dir(),
			"日志目录就在游戏目录下(不是 user://)")
	# 四件套:在、且认的就是 easytier/ 那一份
	_check(Tunnel.available(), "四件套齐于 %s" % et)
	_check(Tunnel.core_exe().get_base_dir() == et, "core 路径取自 easytier/")
	_check(Tunnel.cli_exe().get_base_dir() == et, "cli 路径取自 easytier/")
	for dll in Meta.CORE_DLLS:
		_check(FileAccess.file_exists(et.path_join(dll)), "%s 在 easytier/ 下" % dll)
	# 公共节点列表:同一目录。★ 节点**只**来自文件 —— 本机 relay.txt 里有没有节点是环境事实
	# (它不在 git 里),不钉"非空";代码级契约(不许有内置表/节点字面量)在下面 tn/tm 两段。
	_check(Tunnel.relay_file() == et.path_join(Meta.RELAY_FILE_NAME),
			"公共节点列表 = easytier/%s" % Meta.RELAY_FILE_NAME)
	# 解析纯函数:注释/空行丢弃、裸 host:port 自动补 tcp://、完整 URL 原样(它是两端各读一次
	# 的共享契约,错了只是"连不上",见 tunnel.gd 的 parse_relay_lines)。
	var pl := Tunnel.parse_relay_lines("# 注释\n\ntcp://a.b:1\n  host2:2  \nudp://c.d:3")
	_check(pl.size() == 3, "parse_relay_lines 丢掉注释与空行(实得 %d 条)" % pl.size())
	_check(pl[0] == "tcp://a.b:1", "完整 URL 原样保留")
	_check(pl[1] == "tcp://host2:2", "裸 host:port 自动补 tcp://")
	_check(pl[2] == "udp://c.d:3", "udp:// URL 原样保留")
	_check(Tunnel.parse_relay_lines("# 只有注释\n\n# 再一条").is_empty(),
			"纯注释文件 → 空列表(⇒ has_initial_peers 为假,UI 会把话说清)")
	# 内核日志按角色分目录(内核的日志文件名固定,同机两条隧道共用一个目录会互相截断)
	var tn := _strip_comments(_read("res://core/net/tunnel.gd"))
	_check(tn.contains("Meta.et_log_dir_name(role)"), "内核日志目录 = 前缀 + 角色 + 游戏 pid")
	# ★ 2026-10-02:内置初始节点表 RELAYS 已删,节点只来自 relay.txt。
	#   正向 = relay_list 只读文件(parse_relay_lines 行为断言在上面);反向 = 内置表不许复活,
	#   节点地址也不许再进代码 —— 把初始节点写死回代码里的每一次都会在这里红。
	_check(not tn.contains("RELAYS"), "tunnel.gd 不再引用内置节点表 RELAYS")
	var tm := _strip_comments(_read("res://core/config/tunnel_meta.gd"))
	_check(not tm.contains("RELAYS"), "tunnel_meta.gd 不再有内置节点表 RELAYS")
	_check(not tn.contains("dreamlife") and not tm.contains("dreamlife"),
			"代码与常量表里没有初始节点地址字面量")
	_check(tn.contains("no_relay_hint"),
			"tunnel.gd 保留 no_relay_hint(建房/加入两侧对\"无节点\"都要把话说清)")
	# 反向断言:路径只许有一个来源 —— 这几条串再出现就说明有人又写了一份路径出来
	_check(not tn.contains("user://"), "tunnel.gd 不再往 user:// 写(节点列表与日志都在游戏目录)")
	_check(not tn.contains("tools/easytier"), "tunnel.gd 不再认 tools/easytier")
	_check(tn.contains("AppPaths.easytier_dir()") and tn.contains("AppPaths.log_dir()"),
			"tunnel.gd 的路径全部取自 AppPaths")
	# 自带文件日志必须关掉:它是唯一会把日志写去 %APPDATA% 的东西(客户端与服务端还会同名互覆),
	# 关掉之后才轮到 GameLog 把引擎输出写进 log/。
	var cfg := _read("res://project.godot")
	_check(cfg.contains("file_logging/enable_file_logging=false")
			and cfg.contains("file_logging/enable_file_logging.pc=false"),
			"project.godot 关掉了引擎自带的文件日志(含 .pc 覆盖)")
	_check(cfg.contains("GameLog=\"*res://core/config/game_log.gd\""), "GameLog 已注册为 autoload")
	# GameLog 是 autoload(`-s` 里不存在),这里只加载脚本来问它的静态口。
	var gl: GDScript = load("res://core/config/game_log.gd")
	_check(gl.log_dir() == AppPaths.log_dir(), "GameLog 的落点 = AppPaths.log_dir()")
	_check(gl.log_dir() != ProjectSettings.globalize_path("user://logs"),
			"GameLog 的落点不是 %APPDATA% 下那个")
	# 服务端要能自报家门:发布版靠 `dedicated_server` 特性,开发态靠 server_main 这一句
	_check(_strip_comments(_read("res://server/server_main.gd")).contains("GameLog.use_role"),
			"开发态的服务端自报家门(否则与客户端抢同一个 client.log)")


# ── 小工具 ──
func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 去注释:源码级断言必须看**代码**而不是注释(解释坏写法的注释本身含那个串,算进去会让断言永远红
# —— 本仓在 kh_l5_probe 上踩过这一脚,那里也留了同样的提醒)。
func _strip_comments(src: String) -> String:
	var out := ""
	for line in src.split("\n"):
		var s := str(line)
		var i := s.find("#")
		out += (s if i < 0 else s.substr(0, i)) + "\n"
	return out


# 取 `func <name>(…)` 的函数体(到下一个顶层 `func ` 或文件尾)。缩进无关:按列 0 的 `func` 认。
func _func_body(src: String, name: String) -> String:
	var lines := src.split("\n")
	var start := -1
	for i in range(lines.size()):
		var s := str(lines[i])
		if s.begins_with("func ") and s.contains(name + "("):
			start = i
			break
	if start < 0:
		return ""
	var out := ""
	for i in range(start + 1, lines.size()):
		var s := str(lines[i])
		if s.begins_with("func "):
			break
		out += s + "\n"
	return out
