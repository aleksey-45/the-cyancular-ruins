extends Node2D
# 服务器入口(headless 运行)。角色由命令行 user args(位于 `--` 之后)区分:
#  - 无参数:大厅(默认,7777)——1v1 配对 + 大乱斗房间(公开/私密/邀请码/人数上限);
#    两种局各拉起一个 --worker 子进程。
#  - `--worker --port P`:1v1 对局 worker——等两名客户端 claim_role 后建权威 MatchHost,
#    任一方离开即拆局退出(释放端口)。
#  - `--worker --royale --port P --players N`:大乱斗 worker——N 人限时死斗(RoyaleHost),
#    收齐 N 个角色(或 20s 超时按已到人数 ≥2)开局;单个掉线移出对局,全员走光才退出。

var _host: Node = null
var _claims: Dictionary = {}   # role(int) -> peer_id(worker 视角)
var _claim_names: Dictionary = {}   # role(int) -> 昵称(开局 peer_info 回传两端)
var _claim_opts: Dictionary = {}   # role(int) -> 本端选项(颜色/规则偏好)
var _wait_timer := 0.0
# ── 大乱斗 worker(--royale --players N):N 人限时死斗 ──
var _royale := false
var _expected_players := 2
var _ai_roles: Array = []    # AI 补位的 role 列表(实验性;这些 role 不等 claim,由服务端 AI 驱动)
var _claim_wait := 0.0
var _understaffed_wait := 0.0   # 开局前可用玩家 <2 的持续时长(超时退出释放端口)
var _lan_ip_text := ""          # 局域网 IP 串(写 local_ip.txt 用;公网 IP 到手后一并补写)
var _match_started := false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var is_worker := false
	var port := NetBus.DEFAULT_PORT
	for i in range(args.size()):
		match args[i]:
			"--worker":
				is_worker = true
			"--royale":
				_royale = true
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
			"--players":
				if i + 1 < args.size():
					_expected_players = clampi(int(args[i + 1]), 2, 8)
			"--ai-roles":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var r := int(tok.strip_edges())
						if r >= 1 and r <= 8:
							_ai_roles.append(r)
	if is_worker:
		_run_worker(port)
		return
	# ── 大厅 ──
	# 先杀掉还占着 7777 的旧服务端(上次没关干净会 bind 失败→闪退),再监听
	_kill_port_holder(NetBus.DEFAULT_PORT)
	var err := NetBus.start_server()
	if err != OK:
		push_error("服务器: 监听失败 %d" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	print("服务器就绪,等待玩家……(大厅 7777;配对后自动拉起对局 worker)")
	_print_local_ips()
	_fetch_public_ip()

# ── 本机 IP 展示:服主开服即见,不用再手动 ipconfig ──
# 局域网 IP 同步打印(朋友在「多人对战→服务器地址」里填它);公网 IP 异步拉一次(离线/超时静默)。
func _print_local_ips() -> void:
	var ips: Array = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if ":" in s or s.begins_with("127.") or s.begins_with("169.254."):
			continue   # 跳过 IPv6/回环/链路本地
		ips.append(s)
	if ips.is_empty():
		print("本机 IP: 未检测到(网络未连接?)")
		return
	# 私有网段排前(局域网朋友填它)
	ips.sort_custom(func(a: String, b: String) -> bool: return _priv_score(a) > _priv_score(b))
	_lan_ip_text = ", ".join(ips)
	print("本机局域网 IP: " + _lan_ip_text + "(把第一个填进「服务器地址」,端口 7777)")
	_write_ip_file("本机局域网 IP: %s
(朋友在「多人对战→服务器地址」里填第一个;端口 7777)
" % _lan_ip_text)

func _priv_score(ip: String) -> int:
	if ip.begins_with("192.168."):
		return 3
	if ip.begins_with("10."):
		return 2
	if ip.begins_with("172."):
		var parts := ip.split(".")
		if parts.size() > 1:
			var o2 := int(parts[1])
			if o2 >= 16 and o2 <= 31:
				return 2
	return 1

## IP 写文件:Dedicated Server 导出是无控制台 GUI exe,print 看不见 → 落盘 exe 旁 local_ip.txt。
func _write_ip_file(text: String) -> void:
	var dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("template"):
		dir = ProjectSettings.globalize_path("res://")   # 开发态别往引擎目录写
	var f := FileAccess.open(dir + "/local_ip.txt", FileAccess.WRITE)
	if f == null:
		f = FileAccess.open("user://local_ip.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

# 公网出口 IP(尽力而为):自建房要给公网朋友连时,除这个 IP 外还须路由器转发 UDP 7777 与 7800~7910。
func _fetch_public_ip() -> void:
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if code == 200:
			var ip := body.get_string_from_utf8().strip_edges()
			if ip.length() > 0 and ip.length() <= 45 and not ip.contains("<"):
				print("本机公网 IP: " + ip + "(公网联机需路由器转发 UDP 7777、7800~7910)")
				_write_ip_file("本机局域网 IP: %s
本机公网 IP: %s
(公网联机需路由器转发 UDP 7777、7800~7910)
" % [_lan_ip_text, ip])
		http.queue_free())
	http.request("http://ip-api.com/line/?fields=query")

# 杀掉还监听该 UDP 端口的旧进程(Windows:PowerShell 取 UDP 端点属主进程→Stop-Process)。
# 供大厅启动前用,避免旧服务端没关导致新实例 bind 失败瞬间退出(双击 exe 闪退)。
func _kill_port_holder(port: int) -> void:
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" | % OwningProcess | sort -u; if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, false)

# ── worker:独占端口等客户端 claim_role;1v1 收齐 2 人开局,大乱斗收齐 N 人(或 20s 超时)开局 ──
func _run_worker(port: int) -> void:
	var err := NetBus.start_server(port)
	if err != OK:
		push_error("worker: 监听失败 %d (port %d)" % [err, port])
		get_tree().quit(1)
		return
	NetBus.role_claimed.connect(_on_role_claimed)
	NetBusExt.player_options_received.connect(_on_player_options)
	NetBus.peer_left.connect(_on_peer_left)
	NetBusExt.suicide_requested.connect(_on_suicide_request)
	if _royale:
		print("大乱斗 worker 就绪,等待 %d 名玩家……(port %d)" % [_expected_players, port])
	else:
		print("worker 就绪,等待两名玩家……(port %d)" % port)
	_print_local_ips()

func _process(delta: float) -> void:
	# 大乱斗:有人报到但 20s 仍未收齐 → 按已到人数(≥2)直接开局(缺席角色不入局)
	if _royale and not _match_started and _host == null and _claims.size() >= 2:
		_claim_wait += delta
		if _claim_wait > 20.0:
			print("worker: 报到超时(%d/%d),按已到人数开局" % [_claims.size(), _expected_players])
			_begin_match()
	# 大乱斗:可用玩家不足 2 人(开局前全部掉线)→ 宽限后退出释放端口
	# (原 M1:只重置计时继续等 → worker 僵死占端口,大厅 30s 回收后撞车新对局)
	elif _royale and not _match_started and _host == null and _claims.size() < 2:
		_understaffed_wait += delta
		if _understaffed_wait > 10.0:
			print("worker: 可用玩家 %d/2,超时退出释放端口" % _claims.size())
			get_tree().quit(0)

# 本端选项(颜色等)经扩展节点上报,可能先于/晚于 claim 到达,按 caller 归档
func _on_player_options(caller: int, opts: Dictionary) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_claim_opts[r] = opts
			return

# 自杀脱困(大乱斗):caller → role → RoyaleHost(存活/对局中校验在那边)
func _on_suicide_request(caller: int) -> void:
	if not _royale or _host == null:
		return
	for r in _claims:
		if _claims[r] == caller:
			if _host.has_method("request_suicide_role"):
				_host.request_suicide_role(int(r))
			return

func _on_role_claimed(caller: int, role: int, player_name: String) -> void:
	# 防串线:对局已开始、role 越界、或该 role 已被其他 peer 占用 → 这个连接不属于本局,直接踢。
	# (端口复用竞态下,迟到的客户端可能连到旧 worker;不能让它静默留在局里收快照/子弹。)
	if _host != null or _match_started \
			or (_royale and (role < 1 or role > _expected_players)) \
			or (_claims.has(role) and _claims[role] != caller):
		print("worker: 拒绝串线连接 peer=%d(role=%d)" % [caller, role])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if _claims.has(role):
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	if _royale:
		print("worker: 大乱斗角色 %d = peer %d (%d/%d 人,另有 %d 个 AI)" % [role, caller,
				_claims.size(), _expected_players - _ai_roles.size(), _ai_roles.size()])
		# 收齐全部人类(其余角色由 AI 补位)即开局
		if _claims.size() >= _expected_players - _ai_roles.size():
			_begin_match()
	else:
		print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
		if _claims.size() >= 2 - _ai_roles.size():
			_begin_match()

func _begin_match() -> void:
	if _match_started or _host != null or _claims.size() + _ai_roles.size() < 2:
		return
	_match_started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	if _royale:
		# 房主(role1)规则项随 claim 上报生效; RoyaleHost.start_on 负责散点出生 + match_start
		_host = RoyaleHost.start_on(_claims, RoomManager.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
	else:
		# 服务器权威规则项以房主(role1)选项为准(经 NetBusExt 上报;缺省=全默认)
		_host = RoomManager.start_match_on(_claims, RoomManager.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
	add_child(_host)
	# AI 补位昵称:唯一名 + -computer 后缀(排行榜/头顶显示,地位与真人等同)
	for ai_r in _ai_roles:
		_claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	# 昵称走原版 peer_info(兼容);颜色走扩展 peer_hues
	for r in _claims:
		NetBus.rpc_id(_claims[r], "peer_info", _claim_names)
		NetBusExt.rpc_id(_claims[r], "peer_hues", _claim_hues())
	if _royale and _host.has_method("set_display_names"):
		_host.set_display_names(_claim_names)   # 排行榜昵称表
	print("worker: 对局开始%s" % ("(大乱斗 %d 人,其中 AI %d)" % [_claims.size() + _ai_roles.size(), _ai_roles.size()] if _royale else ""))

# 各 role 自选的角色颜色(色相旋转度数;缺省 0)
func _claim_hues() -> Dictionary:
	var hues := {}
	for r in _claim_opts:
		hues[r] = float(_claim_opts[r].get("hue", 0.0)) if typeof(_claim_opts[r]) == TYPE_DICTIONARY else 0.0
	return hues

func _on_peer_left(peer_id: int) -> void:
	var is_participant := _claims.values().has(peer_id)
	if _host != null:
		if not is_participant:
			return   # 被踢的串线连接断开不影响对局
		if _royale:
			# 大乱斗:单个参与者掉线 = 移出对局继续;全员走光才拆局
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			_claims.erase(role)
			if _host.has_method("mark_disconnected") and role != 0:
				_host.mark_disconnected(role)
			if _claims.is_empty():
				print("worker: 全员离开,大乱斗结束")
				get_tree().quit(0)
			else:
				print("worker: 玩家离开(剩 %d 人继续)" % _claims.size())
			return
		if is_instance_valid(_host):
			_host.queue_free()
		print("worker: 玩家离开,对局结束")
		get_tree().quit(0)
	elif is_participant:
		if _royale:
			# 尚未开局的缺席:从收人表摘除,继续等(超时兜底按已到人数开局)
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			_claims.erase(role)
			_claim_names.erase(role)
			_claim_opts.erase(role)
			print("worker: 报到角色 %d 掉线,继续等待(%d/%d)" % [role, _claims.size(), _expected_players])
			if _claims.is_empty():
				_claim_wait = 0.0
		else:
			# 尚未满员就有 claimed 玩家掉线 → 别占着端口干等,退出
			print("worker: 角色报到后掉线,退出")
			get_tree().quit(0)
