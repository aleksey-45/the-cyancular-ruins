extends Node2D
# 服务器入口（headless 运行模式）。角色由命令行参数（位于 `--` 之后）区分：
#  - 无参数：大厅模式（默认端口 7777），负责房间生命周期管理、匹配组队以及将对局会话挂载为子节点。
#  - `--worker --port P`：单局独立服务端（1v1 对局模式），监听 UDP 端口 P，角色认领完成后启动权威 MatchHost。
#  - `--worker --royale --port P [--roles 1,3] [--ai-roles r,r]`：单局独立服务端（大乱斗模式，RoyaleHost）。
#  - `--worker --team --port P --roles r,... --teams t,...`：单局独立服务端（3v3 团队对抗模式，TeamHost）。


var _lan_ip_text := ""          # 局域网 IP 串(写 local_ip.txt 用;公网 IP 到手后一并补写)

func _ready() -> void:
	if not OS.has_feature("dedicated_server"):
		GameLog.use_role("server")
	# 开局先自报版本:服务端是控制台子系统,这条是运维/联调时"我这跑的是哪一版"的唯一依据
	# (发布版的版本号+构建时间由 tools/build_release.py 烘焙进 core/build_info.gd)
	print("[server] 版本 %s  pid=%d" % [preload("res://core/config/build_info.gd").display(), OS.get_process_id()])
	var args := OS.get_cmdline_user_args()
	var is_worker := false
	var port := NetBus.DEFAULT_PORT
	var want_royale := false
	var want_team := false
	var role_set: Array = []
	var teams_raw: Array = []
	var ai_roles: Array = []
	for i in range(args.size()):
		match args[i]:
			"--worker":
				is_worker = true
			"--royale":
				want_royale = true
			"--team":
				want_team = true
			"--teams":
				# 队号集合(与 --roles **同序**)。越界值**静默丢弃**是**有意**的:长度不等会在下面
				# 的校验里当场拒绝启动(fail fast)—— 猜一个默认队号会把整局分成错的队,而且**不报错**
				# (两队人数还可能是 3:3,从人数上看不出来)。
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var t := int(tok.strip_edges())
						if t >= 1 and t <= 2:
							teams_raw.append(t)
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
			"--roles":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var r := int(tok.strip_edges())
						if r >= 1 and r <= 8:
							role_set.append(r)
			"--test-ground-teleport":
				# 仅测试用:见 MatchGround.test_ground_teleport。默认关,生产路径不带这个开关。
				MatchGround.test_ground_teleport = true
			"--test-destroy-tile":
				# 仅测试用:见 MatchState.test_destroy_cell。默认关,生产路径不带这个开关。
				# 值形如 "136,64,3.0";delay 可省 → 3.0(-  必须给个非零默认:省掉时若留 0.0,
				# 钩子会在**第一帧**就拆,"对局开始 N 秒后"的语义就没了)
				if i + 1 < args.size():
					var parts := str(args[i + 1]).split(",")
					if parts.size() >= 2:
						MatchState.test_destroy_cell = Vector2i(
								int(parts[0].strip_edges()), int(parts[1].strip_edges()))
					MatchState.test_destroy_after = 3.0
					if parts.size() >= 3:
						MatchState.test_destroy_after = float(parts[2].strip_edges())
			"--ai-roles":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var r := int(tok.strip_edges())
						if r >= 1 and r <= 8:
							ai_roles.append(r)
	# 单进程单端口架构：对局作为 MatchSession 节点直接挂载在大厅进程下。
	# `--worker` 仅用于手动启动单局独立服务端（如发布产物的自动化冒烟测试）。
	if is_worker:
		if want_royale and want_team:
			push_error("worker: --royale 与 --team 不能同时为真(模式开关互斥),拒绝启动")
			get_tree().quit(1)
			return
		var wmode := MatchSession.Mode.DUEL
		if want_royale:
			wmode = MatchSession.Mode.ROYALE
		elif want_team:
			wmode = MatchSession.Mode.TEAM
		# 队号表按 role 出键(roles 与 teams **同序**配对;role 号会留空洞,推不出队号)。
		var teams := {}
		if wmode == MatchSession.Mode.TEAM:
			for idx in range(mini(role_set.size(), teams_raw.size())):
				teams[int(role_set[idx])] = int(teams_raw[idx])
		elif role_set.is_empty():
			role_set = [1, 2]   # 1v1 形态(手工调用保底处理;大厅路径不带 --roles)
		# 判据与大厅那条路**同一份**(见 MatchSession.validate):两处各写一遍迟早只改一边。
		var why: String = MatchSession.validate(wmode, role_set, teams)
		if why != "":
			push_error("worker: %s,拒绝启动" % why)
			get_tree().quit(1)
			return
		var werr := NetBus.start_server(port)
		if werr != OK:
			push_error("worker: 监听失败 %d (port %d)" % [werr, port])
			get_tree().quit(1)
			return
		var sess := MatchSession.new(wmode, "", 0, [], role_set, ai_roles, teams)
		# 单局独立服务端：对局结束时自动退出进程并释放端口
		sess.finished.connect(func(_s) -> void: get_tree().quit(0))
		add_child(sess)
		# 就绪行保持原串:发布产物的冒烟按它判"走对了分支"(见 tools/build_release.py)。
		if wmode == MatchSession.Mode.ROYALE:
			print("大乱斗 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s)" % [
					MatchSession.count_humans(role_set, ai_roles), port, str(role_set)])
		elif wmode == MatchSession.Mode.TEAM:
			print("3v3 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s,队伍 %s)" % [
					MatchSession.count_humans(role_set, ai_roles), port, str(role_set), str(teams)])
		else:
			print("worker 就绪,等待两名玩家……(port %d)" % port)
		_print_local_ips()
		return
	# ── 大厅 ──
	if port == NetBus.DEFAULT_PORT:
		ProcUtil.kill_udp_port(NetBus.DEFAULT_PORT)
	var err := NetBus.start_server(port)
	if err != OK:
		push_error("服务器: 监听失败 %d (port %d)" % [err, port])
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	print("服务器就绪,等待玩家……(端口 %d)" % port)
	_print_local_ips()
	_fetch_public_ip()
	# 大厅模式不执行主进程物理帧轮询，全部业务逻辑由 RoomManager 及其子节点驱动。
	# 使用 set_process(false) 仅停止当前主节点的 _process，不影响子节点。
	set_process(false)

# ── 本机 IP 展示：服务启动后展示，便于调试与连接 ──
# 局域网 IP 同步输出；公网 IP 异步查询。


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
	# 私有网段排前
	ips.sort_custom(func(a: String, b: String) -> bool: return _priv_score(a) > _priv_score(b))
	_lan_ip_text = ", ".join(ips)
	print("本机局域网 IP: " + _lan_ip_text)
	_write_ip_file("本机局域网 IP: %s
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

# 查询并输出公网出口 IP（异步查询，仅供服务器管理员参考）。
# 在当前单进程单端口及 EasyTier P2P 隧道架构下，远程联机通过虚拟内网穿透进行，无需路由器手动端口转发。
func _fetch_public_ip() -> void:
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if code == 200:
			var ip := body.get_string_from_utf8().strip_edges()
			if ip.length() > 0 and ip.length() <= 45 and not ip.contains("<"):
				print("本机公网 IP: " + ip)
				_write_ip_file("本机局域网 IP: %s
本机公网 IP: %s
" % [_lan_ip_text, ip])
		http.queue_free())
	http.request("http://ip-api.com/line/?fields=query")

