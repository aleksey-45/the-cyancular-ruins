extends Node2D

# 服务器入口(headless)。**一个进程、一个端口**:
#   · 大厅与对局**同进程** —— 配对完成后 `RoomManager` 直接 `add_child(MatchSession)`,
#     不拉子进程、不换端口、不让客户端转连;
#   · 监听端口由**客户端**挑好经 `--port P` 传进来(为什么是客户端挑,见 core/net/local_server.gd);
#   · 不带参数手跑时回落 `NetBus.DEFAULT_PORT`(开发/联调用)。
#
# 命令行(user args,**必须落在 `--` 之后**,写在前面会被 Godot 当自己的参数丢掉):
#   --port <n>                     监听端口(缺省 7777)
#   --test-ground-teleport         仅测试用:见 MatchGround.test_ground_teleport
#   --test-destroy-tile <c,r[,s]>  仅测试用:见 MatchState.test_destroy_cell
#   --tunnel --room <5 位码>       自检模式:起一条房主隧道,打印「隧道就绪」后退出
#                                  (产物冒烟用;证明 easytier-core/cli 真的随包发出去了)
#
# ★ 这里**不再**有 `--worker` / `--royale` / `--team` / `--roles` / `--teams`:那些参数属于
#   "每局一个子进程"的旧形态。对局的参战 role 集合与队伍表现在由**房记录**给出
#   (`RoomManager` 建 `MatchSession` 时传),不再需要经过命令行 —— 而那条命令行的存在
#   本身就是"大厅要知道 worker 该怎么起"的耦合,随子进程一起消失。
# ★ 也**不再**在启动前杀占用端口的进程:端口是客户端挑的空闲号,而"按端口杀进程"在一个
#   单机可以同时开两个实例的世界里是**主动破坏**(它会把另一台正在跑的服务端打死)。

const Tunnel := preload("res://core/net/tunnel.gd")

var _port := NetBus.DEFAULT_PORT
var _tunnel_selftest := false
var _room := ""


func _ready() -> void:
	# 开局先自报版本:服务端是控制台子系统,这条是运维/联调时"我这跑的是哪一版"的唯一依据
	# (发布版的版本号+构建时间由 tools/build_release.py 烘焙进 core/config/build_info.gd)
	print("[server] 版本 %s  pid=%d" % [preload("res://core/config/build_info.gd").display(),
			OS.get_process_id()])
	_parse_args(OS.get_cmdline_user_args())
	if _tunnel_selftest:
		_run_tunnel_selftest()
		return
	var err := NetBus.start_server(_port)
	if err != OK:
		push_error("服务器: 监听失败 %d (port %d)" % [err, _port])
		get_tree().quit(1)
		return
	add_child(RoomManager.new(_port))
	print("服务器就绪,等待玩家……(端口 %d)" % _port)
	_print_local_ips()


func _parse_args(args: PackedStringArray) -> void:
	for i in range(args.size()):
		match args[i]:
			"--port":
				if i + 1 < args.size():
					_port = int(args[i + 1])
			"--tunnel":
				_tunnel_selftest = true
			"--room":
				if i + 1 < args.size():
					_room = str(args[i + 1]).strip_edges()
			"--test-ground-teleport":
				# 仅测试用:见 MatchGround.test_ground_teleport。默认关,生产路径不带这个开关。
				MatchGround.test_ground_teleport = true
			"--test-destroy-tile":
				# 仅测试用:见 MatchState.test_destroy_cell。值形如 "136,64,3.0";delay 可省 → 3.0
				# (★ 必须给个非零默认:省掉时若留 0.0,钩子会在**第一帧**就拆,"对局开始 N 秒后"
				#   的语义就没了)
				if i + 1 < args.size():
					var parts := str(args[i + 1]).split(",")
					if parts.size() >= 2:
						MatchState.test_destroy_cell = Vector2i(
								int(parts[0].strip_edges()), int(parts[1].strip_edges()))
					MatchState.test_destroy_after = 3.0
					if parts.size() >= 3:
						MatchState.test_destroy_after = float(parts[2].strip_edges())


# ── 自检模式(产物冒烟)──
# 起一条**房主**隧道并等它真的应答 RPC 门户,然后退出。
# ★ 它验的是"两个 exe 有没有随包发出去 + 能不能起来",不是"打洞通不通"(那要两台机器)。
#   后者是手工验收项(W0),不要试图在这里做。
func _run_tunnel_selftest() -> void:
	var code := _room if Tunnel.is_valid_room(_room) else Tunnel.generate_room()
	print("[server] 隧道自检:room=%s port=%d" % [code, _port])
	if not Tunnel.start_host(_port, code):
		push_error("隧道自检失败:EasyTier 未就绪(见上面那条路径提示)")
		get_tree().quit(1)
		return
	var ok: bool = await Tunnel.wait_ready()
	Tunnel.stop()
	if ok:
		print("隧道就绪(room=%s port=%d)" % [code, _port])
		get_tree().quit(0)
	else:
		push_error("隧道自检失败:easytier-core 起来了但 RPC 门户无应答")
		get_tree().quit(1)


# ── 本机 IP 展示:服主开服即见,不用再手动 ipconfig ──
# 这条走的是**直连**那条路(局域网里填 IP + 端口)。远程联机不需要它 —— 那条走隧道 + 房间码。
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
	# 私有网段排前(要人工排查时看得顺眼)
	ips.sort_custom(func(a: String, b: String) -> bool: return _priv_score(a) > _priv_score(b))
	# ★ 2026-09-29:原先这句还带着"直连时把第一个填进「服务器地址」"—— 那个入口已整体删除,
	#   现在它纯粹是**服务端操作者的自查信息**(我在哪台机器上、什么地址)。
	print("本机局域网 IP: %s(端口 %d)" % [", ".join(ips), _port])


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
