extends SceneTree
# LAN IP 纯解析守卫:S-07 把局域网 IP 发现从 local_server.gd 拆到 core/net/lan_ip.gd。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/lan_ip.gd") == null:
		print("LAN IP FAILED: load(lan_ip.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return
	if load("res://core/net/local_server.gd") == null:
		print("LAN IP FAILED: load(local_server.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 默认路由行:只认 0.0.0.0 双列 + 5 列以上 + 点分 IPv4 网卡,同卡去重。去掉任一条 ⇒ 噪行/重复行被收进来 ⇒ 红;带一条 26.* 证明 parse 不按私有段过滤。
	var netstat_text := (
			"IPv4 Route Table\n"
			+ "Network Destination   Netmask   Gateway   Interface   Metric\n"
			+ "          0.0.0.0   0.0.0.0   10.10.10.1   10.10.10.166   25\n"
			+ "          0.0.0.0   0.0.0.0   10.10.10.1   10.10.10.166   25\n"
			+ "        127.0.0.0   255.0.0.0   On-link          127.0.0.1   331\n"
			+ "        224.0.0.0   240.0.0.0   On-link          127.0.0.1   331\n"
			+ "          0.0.0.0   0.0.0.0   192.168.1.1   192.168.1.50   60\n"
			+ "          0.0.0.0   0.0.0.0   26.26.26.1   26.26.26.2   50\n"
			+ "          0.0.0.0   0.0.0.0   10.0.0.1\n"
			+ "          0.0.0.0   0.0.0.0   10.0.0.1   not-an-ip   40\n")
	var routes := LanIp.parse_default_routes(netstat_text)
	_chk(routes.size() == 3 and routes.has("10.10.10.166") and routes.has("192.168.1.50")
			and routes.has("26.26.26.2"),
			"默认路由行只留 0.0.0.0/0.0.0.0 + 点分 IPv4 + 去重(实得 %s)" % [routes])

	# ② metric 升序:三行故意按 50,10,30 的顺序写。去掉排序 / 把比较方向反过来 ⇒ 实得行序 50,10,30 ⇒ 红。
	var order := LanIp.parse_default_routes(
			"0.0.0.0 0.0.0.0 10.0.0.1 10.0.0.5 50\n"
			+ "0.0.0.0 0.0.0.0 10.0.0.1 10.0.0.7 10\n"
			+ "0.0.0.0 0.0.0.0 10.0.0.1 10.0.0.9 30\n")
	_chk(order == ["10.0.0.7", "10.0.0.9", "10.0.0.5"],
			"默认路由没按 metric 升序(实得 %s)" % [order])

	# ③ local_ip.txt 首行(样例 = server_main 实际落盘格式「本机局域网 IP: <ip><其它候选…>」):括号 / 英文逗号 / 中文逗号 / 空格都要抽出 IP,缺 IP: 前缀 / 非 IPv4 / 空行 ⇒ ""。
	_chk(LanIp.parse_ip_file_line("本机局域网 IP: 10.10.10.166(其它候选: 192.168.1.5,第一候选不通就换)") == "10.10.10.166"
			and LanIp.parse_ip_file_line("IP: 192.168.1.7,第一候选不通就换") == "192.168.1.7"
			and LanIp.parse_ip_file_line("IP: 172.16.3.9，中文逗号") == "172.16.3.9"
			and LanIp.parse_ip_file_line("IP: 10.0.0.5 空格分隔") == "10.0.0.5"
			and LanIp.parse_ip_file_line("没有前缀 10.0.0.5") == ""
			and LanIp.parse_ip_file_line("IP: 10.0.0.999") == ""
			and LanIp.parse_ip_file_line("") == "",
			"local_ip.txt 行解析错(合法 / 分隔符 / 非法 / 空)")

	# ④ 私有网段 192.168 > 10 > 172.16~31 > 其它,同档保序。把 10.* 与 172.* 并成一档 / 去掉同档保序 ⇒ 顺序错 ⇒ 红。
	var ranked := LanIp.rank_private(["26.26.26.2", "172.20.1.1", "10.2.2.2", "192.168.0.3",
			"172.32.0.1", "10.2.2.9"])
	_chk(ranked == ["192.168.0.3", "10.2.2.2", "10.2.2.9", "172.20.1.1", "26.26.26.2",
			"172.32.0.1"],
			"私有地址排序优先级错(实得 %s)" % [ranked])

	# ⑤ 转发壳 LocalServer.lan_ip_* 必须存在且与 LanIp 同源(同一次缓存一致);无候选时提示回落固定文案。壳返回空 / 自算一份 ⇒ 不等 ⇒ 红。
	var via_lan := LanIp.lan_ip_candidates()
	var via_shell := LocalServer.lan_ip_candidates()
	_chk(via_shell == via_lan
			and LocalServer.lan_ip_hint() == LanIp.lan_ip_hint()
			and (not via_lan.is_empty() or LanIp.lan_ip_hint() == "未检测到局域网 IP(网络未连接?)"),
			"转发壳与 LanIp 不同源(实得 %s / %s)" % [via_shell, via_lan])

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LAN IP OK(%d 条断言):默认路由去重+metric 升序 · local_ip.txt 行解析 · 私有地址优先级 · 转发壳同源"
				% _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("LAN IP FAILED: %d 处" % _fails.size())
		quit(1)
