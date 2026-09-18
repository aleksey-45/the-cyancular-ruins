extends Node2D
# 服务器入口(headless 运行)。角色由命令行 user args(位于 `--` 之后)区分:
#  - 无参数:大厅(默认,7777)——只做建房/配对;配对完成后为每局拉起一个 --worker 子进程。
#  - `--worker --port P`:1v1 对局 worker——独占 UDP 端口 P,等两名客户端 claim_role 后
#    MatchBootstrap.start_on 建权威 MatchHost,任一方离开即拆局退出(释放端口)。
#  - `--worker --royale --port P [--roles 1,3] [--ai-roles r,r]`:大乱斗 worker——限时死斗(RoyaleHost),
#    收齐全部人类 role(或 20s 超时按已到人数 ≥2)开局;单个掉线移出对局,全员走光才退出。
#    `--roles` = **本局全部参战 role**(真人已分配号 + AI 补位号),由大厅显式传入。
#  - `--worker --team --port P --roles r,... --teams t,...`:3v3 worker——团队对抗(TeamHost),
#    **满员才开**(不降级),收不齐就超时退出释放端口;单个掉线进宽限期,到点移出对局(整队走光才终局)。
#    `--roles` 与 `--teams` **同序等长**:第 i 个 role 的队号就是 teams[i](队号不从 role 号推 —— 同 --roles 的理由)。
#    ★ 与 --royale 的方向**相反**:那边是自由混战(N 人可打),故能按已到人数降级开局;这边两队人数必须相等才成立。
#    ★ 不再传「人数 + role 上界」两个整数:role 由大厅的「最小空闲号」分配,有人退出后会留空洞
#    (如房里 {1,3} 而只有 2 人),**从人数推导必然出错** → 持 3 号的真客户端会被当串线踢掉
#    (历史自检 B1)。集合传过来则精确,不需要任何"上界该放宽多少"的特例函数。

var _host: Node = null
var _claims: Dictionary = {}   # role(int) -> peer_id(worker 视角)
var _claim_names: Dictionary = {}   # role(int) -> 昵称(开局 peer_info 回传两端)
var _claim_opts: Dictionary = {}   # role(int) -> 本端选项(颜色/规则偏好)
var _wait_timer := 0.0
# ── 大乱斗 worker(--royale --players N --max-role R):限时死斗 ──
var _royale := false
# 本局的**全部参战 role**(含 AI 补位号),由大厅经 --roles 显式传入 —— 见文件头注释:
# 从"人数"推导 role 集合必然出错(编号会留空洞),历史 B1 就是这么踢掉真客户端的。
var _role_set: Array[int] = []
var _ai_roles: Array = []    # AI 补位的 role 列表(实验性;这些 role 不等 claim,由服务端 AI 驱动)
var _claim_wait := 0.0
var _understaffed_wait := 0.0   # 开局前可用玩家 <2(大乱斗)/未满员(3v3)的持续时长(超时退出释放端口)
# ── 3v3 worker(--team --roles r,r --teams t,t):团队对抗 ──
var _team_mode := false
var _team_of_role: Dictionary = {}   # role(int) -> 队号(1/2);由 --teams 与 --roles **同序**解析
# --teams 的原始 token(与 `_role_set` 同序的下标配对在 `_ready` 里做;这里只收 1..2 的合法值)
var _team_teams_raw: Array[int] = []
var _lan_ip_text := ""          # 局域网 IP 串(写 local_ip.txt 用;公网 IP 到手后一并补写)
var _match_started := false
# ── 断线宽限期(2026-09-17,断线重连)──
# 掉线的 role 先进 `_grace`,不立刻移出(大乱斗)/不立刻退进程(1v1);宽限内可被 reclaim_role
# 认领回来。到点仍未回来 → 走既有的"移出对局 / 收场退出"语义。
# ★ 时长唯一入口是 `GraceWindow.DEFAULT_SECONDS`。
var _grace := GraceWindow.new()
var _grace_check_timer := 0.0
var _tokens: Dictionary = {}   # role(int) -> token(String),客户端经 report_token 报来

func _ready() -> void:
	# 开局先自报版本:服务端是控制台子系统,这条是运维/联调时"我这跑的是哪一版"的唯一依据
	# (发布版的版本号+构建时间由 tools/build_release.py 烘焙进 core/build_info.gd)
	print("[server] 版本 %s  pid=%d" % [preload("res://core/config/build_info.gd").display(), OS.get_process_id()])
	var args := OS.get_cmdline_user_args()
	var is_worker := false
	var port := NetBus.DEFAULT_PORT
	for i in range(args.size()):
		match args[i]:
			"--worker":
				is_worker = true
			"--royale":
				_royale = true
			"--team":
				_team_mode = true
			"--teams":
				# 队号集合(与 --roles **同序**)。越界值**静默丢弃**是**有意**的:长度不等会在下面
				# 的校验里当场拒绝启动(fail fast)—— 猜一个默认队号会把整局分成错的队,而且**不报错**
				# (两队人数还可能是 3:3,从人数上看不出来)。
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var t := int(tok.strip_edges())
						if t >= 1 and t <= 2:
							_team_teams_raw.append(t)
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
			"--roles":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var r := int(tok.strip_edges())
						if r >= 1 and r <= 8:
							_role_set.append(r)
			"--test-ground-teleport":
				# 仅测试用:见 MatchGround.test_ground_teleport。默认关,生产路径不带这个开关。
				MatchGround.test_ground_teleport = true
			"--test-destroy-tile":
				# 仅测试用:见 MatchState.test_destroy_cell。默认关,生产路径不带这个开关。
				# 值形如 "136,64,3.0";delay 可省 → 3.0(★ 必须给个非零默认:省掉时若留 0.0,
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
							_ai_roles.append(r)
	if is_worker:
		# ★ 模式开关**互斥**(Task 9 评审 M4):三处判据的优先级此前并不一致 —— 本函数里
		#   `--royale` 先判、而 `_on_role_claimed` / `_begin_match` 里 `_team_mode` 先判。
		#   手敲 `--royale --team` 时后果是:走 royale 那支开局,`_team_of_role` **永不填充**,
		#   而 `_begin_match` 却按 `_team_mode` 去建 TeamHost → 空 teams → `spawns[role]` 全员缺键。
		#   生产不可达(生成端是两个各自独立的函数),但它与本册"绝不静默"的纪律不一致:
		#   解析到两个都真就当场拒绝启动,别让它落进"哪一支先判"的隐式优先级里。
		if _royale and _team_mode:
			push_error("worker: --royale 与 --team 不能同时为真(模式开关互斥),拒绝启动")
			get_tree().quit(1)
			return
		if _royale:
			if _role_set.is_empty():
				# 大厅拉起时**总会**带 --roles;空集合只可能是手工命令行漏了。
				# 不猜一个集合出来开局(猜错 = 静默踢真客户端,正是 B1),直接拒绝启动。
				push_error("大乱斗 worker: 缺 --roles(本局参战 role 集合),拒绝启动")
				get_tree().quit(1)
				return
		elif _team_mode:
			# --roles 与 --teams 必须等长且非空(队号按**同序**配对)。不等 = 拒绝启动:
			# 猜一个默认队号会把整局分成错的队,而且**不报错**(两队人数还可能是 3:3,看不出来)。
			# ★ 这也保证了 `teams` 的键覆盖本局全部参战 role:TeamHost 的摆位表按 `teams.keys()`
			#   出键,而 `_init` 摆位摆的是 role_peers —— 某个 role 在 --roles 里却不在 --teams 里
			#   时它会静默生在 (-1,-1)(地图外),`start_on` 那侧则是 `spawns[role]` 缺键。
			if _role_set.is_empty() or _role_set.size() != _team_teams_raw.size():
				push_error("3v3 worker: --roles 与 --teams 必须等长且非空(%d vs %d),拒绝启动" % [
						_role_set.size(), _team_teams_raw.size()])
				get_tree().quit(1)
				return
			for idx in range(_role_set.size()):
				_team_of_role[_role_set[idx]] = _team_teams_raw[idx]
		elif _role_set.is_empty():
			_role_set = [1, 2]   # 1v1 形态(手工调用兜底;大厅路径不带 --roles)
		_run_worker(port)
		return
	# ── 大厅 ──
	# 先杀掉还占着 7777 的旧服务端(上次没关干净会 bind 失败→闪退),再监听
	ProcUtil.kill_udp_port(NetBus.DEFAULT_PORT)
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

# worker 端口段文案(供服主提示:要转发的就是这个区间)。
# 单一来源 = WorkerLauncher 的 WORKER_PORT_BASE / WORKER_PORT_SPAN,勿在提示串里另写死数字:
# 曾写 "7800~7910" 与实际池(7800~8299)不符,照它放行防火墙会漏掉半个池子(自检 D2)。
static func _worker_port_span_text() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]

# 公网出口 IP(尽力而为):自建房要给公网朋友连时,除这个 IP 外还须路由器转发 UDP 7777 与 worker 端口段
# (区间取自 _worker_port_span_text,勿手写数字)。
func _fetch_public_ip() -> void:
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if code == 200:
			var ip := body.get_string_from_utf8().strip_edges()
			if ip.length() > 0 and ip.length() <= 45 and not ip.contains("<"):
				print("本机公网 IP: " + ip + "(公网联机需路由器转发 UDP 7777、" + _worker_port_span_text() + ")")
				_write_ip_file("本机局域网 IP: %s
本机公网 IP: %s
(公网联机需路由器转发 UDP 7777、%s)
" % [_lan_ip_text, ip, _worker_port_span_text()])
		http.queue_free())
	http.request("http://ip-api.com/line/?fields=query")

# (原 _kill_port_holder 已搬进 core/proc_util.gd → ProcUtil.kill_udp_port:那段 PowerShell
#  与 server/worker_launcher.gd 的 kill_worker **逐字相同**,而那条 `Select -ExpandProperty
#  OwningProcess` 的写法是踩坑才修对的(2026-09-06)—— 收成一处,别再给第二次抄的机会。
#  守卫:kh_l5_probe 第 3 条。)

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
	NetBus.match_sync_received.connect(_on_match_sync)
	NetBusExt.token_reported.connect(_on_token_reported)
	NetBusExt.reclaim_requested.connect(_on_reclaim)
	if _royale:
		print("大乱斗 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s)" % [
				_human_role_count(), port, str(_role_set)])
	elif _team_mode:
		# ★ 提示串里同时打 role 集合与队伍表:这两者**同序配对**是 3v3 最容易被改坏的一处,
		#   联调时一眼能看出"谁是哪一队"(探针也按 role/队号核对摆位)。
		print("3v3 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s,队伍 %s)" % [
				_human_role_count(), port, str(_role_set), str(_team_of_role)])
	else:
		print("worker 就绪,等待两名玩家……(port %d)" % port)
	_print_local_ips()

# 需要真人 claim 的 role 数 = 参战集合 − AI 补位号。收齐判据与提示都用它。
func _human_role_count() -> int:
	var n := 0
	for r in _role_set:
		if not _ai_roles.has(int(r)):
			n += 1
	return n


# 把一个 role 放进宽限期。★ 必须**置空它的输入源 + 清掉它的待消费输入队列**(两件缺一不可):
# `PacketInputSource` 在队列空时沿用上一包(held,见 match_host 的每 tick 消费注释),
# 不置空的话掉线者的身体会保持他断开前最后一帧的输入 —— 一直朝那个方向跑、或一直开枪。
func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if _host != null:
		var src = _host.input_sources.get(role, null)
		if src != null and src.has_method("reset_state"):
			src.reset_state()
		# ★★ 清输入源**不够,必须连队列一起清**(与 `_on_reclaim` 接受路径那一行同一件事):
		#   掉线瞬间队列里可能还压着一条**已经到达**的包,而 `MatchHost` 每物理 tick 消费一包、
		#   `PacketInputSource.apply_packet()` 是**整体覆盖** `_held`/`_axis` —— 那条包会在
		#   `reset_state()` **之后**被执行,把 `_held` 原样写回去;之后队列空了,而
		#   `clear_edges()` **不含 `_held`** → 掉线前按着的键被重新武装、并保持整个宽限期
		#   (身体继续走/蹲/开火)。这一行是"掉线者的身体留在场上不动"的全部内容,别删。
		_host._pending_input[role] = []
		_host.peer_by_role.erase(role)
		if _host.has_method("_broadcast_round_state"):
			# ★ 这次广播**目前不表达掉线态**:宽限期内该载荷逐字段不变(`names` 由
			#   `peer_by_role`+`players` 兜底、`alive` 只读 `players`、`left` 只读 `_left`,
			#   三者在宽限期内一个都没动),发出去和上一帧是同一份。
			#   保留它只为跟住 `_broadcast_round_state` 的既有节流节奏(掉线是状态转折点,
			#   顺带把那一刻的载荷推齐);"某人掉线中"这类**可见提示要等阶段 3** ——
			#   届时才往 `round_state` 里加 `grace` 字段,**现在别加**。
			_host._broadcast_round_state()


# 到期仍未回来的 role → 走既有语义。每秒轮询一次即可(精度无关,宽限期以秒计)。
func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		# ★ 到点做什么 = **纯分派**(`GraceWindow.expire_action`),三个模式的答案由
		#   tests/grace_window_smoke 逐个钉住 —— 别在这里再写一遍 if/else:
		#   原先的 `else` 把"1v1 **以及** team"一起吞了,3v3 第一个宽限到期的人会**带着整局退进程**
		#   (用户裁定是"该队少人继续打"),而那段代码今天不可达只因大厅还没有起 team worker 的入口。
		#   ★ 真链路验证(6 人局里真掉线 → 宽限到期 → 其余人继续打)归 **B 册的真链路探针**;
		#     本处只保证"分派本身"可测(纯函数 + room_sweep_smoke 的双向断言)。
		if GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE:
			# 大乱斗 / 3v3:移出对局(身体销毁),其余人继续打;整队走光才终局(3v3 在 TeamHost 里判)
			if _host != null and _host.has_method("mark_disconnected"):
				_host.mark_disconnected(role)
		else:
			# 1v1:宽限内没回来 → 收场退进程(原行为,只是晚了几十秒)
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			get_tree().quit(0)
	# 大乱斗/3v3:全员走光且宽限期已空(一个都没回来)→ 收场退出。
	# ★ 这就是原 `_on_peer_left` 里那条「全员离开,大乱斗结束」,只是**移到宽限期到点才判** ——
	#   刚 `_enter_grace` 完表里必然非空,原位置那条 `_grace.size() == 0` 恒假(死分支),
	#   而它是大乱斗 worker 唯一的正常退出口(royale_host.gd:428),丢了会让每局都留下僵尸进程。
	# ★★ `_match_started` 这个前置**不能省**:本函数现在由 `_process` 每秒无条件调用,
	#   而"开机等玩家"这个状态同样满足 `_claims` 空 + 宽限期空 —— 少了它,worker 一开机
	#   就判"全员离开"自杀(实测 ~2s 退 0,一个玩家都没连过)。
	#   它同时是**语义上正确**的那个界:这条判据要表达的是"本局开过、且人全走光了",
	#   而不是"此刻表里没人"。`_begin_match` 是唯一写入点且置真后**从不复位**
	#   (`mark_disconnected` 只释放玩家、不释放 host),故开局后的收场行为与原位置逐字一致。
	# ★★ `_team_mode` 必须一起收进来(与上面那条 `else` 分支是**两条**判据,别只改一条):
	#   3v3 局里所有人走光后,worker 也得退 —— 漏了 = 永驻占着 UDP 端口到超时清扫。
	#   ★ royale 的文案一字未动(`reconnect_probe` 相⑥按整串核对它),3v3 另起一句。
	if (_royale or _team_mode) and _match_started and _claims.is_empty() and _grace.size() == 0:
		print("worker: 全员离开,%s结束" % ("大乱斗" if _royale else "3v3"))
		get_tree().quit(0)


func _process(delta: float) -> void:
	# 宽限期到期轮询(每秒一次足够;不与下面两条大乱斗的报到梯纠缠)
	_grace_check_timer += delta
	if _grace_check_timer >= 1.0:
		_grace_check_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
	# 3v3:人没到齐就干等没有意义(满 6 人才开)→ 超时**退出释放端口**,绝不降级开局。
	# ★ 与 --royale 那条"20s 按已到人数开局"是**相反**的决定:那边是自由混战(N 人可打),
	#   这边两队人数必须相等才成立。别顺手把两条统一。
	# ★ 计时从 worker 启动起算、不因有人报到/离开而复位(掉光也一样) —— 这就是"干等到 30s 就退"。
	if _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			# 分母与上面那条满员判据**同源**(`_team_of_role.size()`):两处不一致时这句读数会说谎
			print("worker: 3v3 报到超时(%d/%d),退出释放端口" % [_claims.size(), _team_of_role.size()])
			get_tree().quit(0)
	# 大乱斗:有人报到但 20s 仍未收齐 → 按已到人数(≥2)直接开局(缺席角色不入局)
	elif _royale and not _match_started and _host == null and _claims.size() >= 2:
		_claim_wait += delta
		if _claim_wait > 20.0:
			print("worker: 报到超时(%d/%d),按已到人数开局" % [_claims.size(), _human_role_count()])
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

# 客户端 claim 之后立刻报来的一次性令牌(claim 与它同一次 poll 到达)。按 caller 反查 role 归档。
# ★ 只归档,不在这里校验 —— 校验发生在宽限期里的 reclaim_role(那时才有"该不该放行"的问题)。
func _on_token_reported(caller: int, token: String) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_tokens[int(r)] = token
			return

# 宽限期内重新认领 role(断线重连)。**三条拒绝条件一条都不能少**:
#   ① 没开局 —— 那时走正常 claim_role,不走这里
#   ② 该 role 不在宽限期里 —— 没掉线,或已超时移出(不允许"提前占坑"或"死后回归")
#   ③ token 不匹配 —— 防同网段的人顶替
# 任何一条不满足都**踢连接**(与 `_on_role_claimed` 的防串线同款):不能让它静默留在局里收快照。
func _on_reclaim(caller: int, role: int, token: String) -> void:
	var why := ""
	if not _match_started or _host == null:
		why = "尚未开局"
	elif not _grace.has(role):
		why = "该 role 不在宽限期"
	elif str(_tokens.get(role, "")) != token or token == "":
		why = "令牌不匹配"
	if why != "":
		print("worker: 拒绝 reclaim(role=%d,peer=%d):%s" % [role, caller, why])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	# ── 接受:重绑 peer 与输入源 ──
	# ★ **玩家节点不重建**:身体从未销毁(spec §3.2),所以服务端的对局状态一条都不用恢复。
	_claims[role] = caller
	_host.peer_by_role[role] = caller
	# ★ 换输入源**不是** `PacketInputSource.new(role, caller)` —— 它不收参数(`match_host.gd:34`
	#   的装配方式是 `var src := PacketInputSource.new()` 然后 `p.set_input_source(src)`)。
	#   所以要把新源**挂回那个还活着的玩家节点**,只换表里的引用是不够的(玩家手里仍攥着旧源)。
	# ★ 直取 `players[role]` 依赖 `_expire_graces` 里的次序:只有它会调 `mark_disconnected`(那里才
	#   `players.erase(role)`),且它**先** `_grace.leave` 再 mark → 判据②恰好挡住"节点已被 erase"那一档。
	var src := PacketInputSource.new()
	(_host.players[role] as Node2D).set_input_source(src)
	_host.input_sources[role] = src
	_host._pending_input[role] = []
	_host._ack_seq[role] = 0      # C2 锚点重协商:客户端 rollback ring 已失(见 spec §3.4)
	_grace.leave(role)
	# 回一条 match_start 让客户端重进对局场景(载荷与首次开局同源,不另造一份)。
	# ★ 走 `NetBus.reply` 而不是 `NetBus.rpc_id`:它是本仓"答复 caller"的收口,内部**先判活**
	#   (CLAUDE.md 硬纪律「定向发送前一律先判活」)。这个窗口**可达**,但成因**不是**
	#   (2026-09-17 订正)原先写的"客户端请求完就断开" —— 客户端发完 `reclaim_role` 之后是**等**
	#   这条应答(`pvp_match_client._on_reconnect_retry_tick` 的 `_reclaim_sent and
	#   NetBus.can_send_to_server()` 分支),只有在连接已不可用(`can_send_to_server()` 转 false,
	#   被踢/链路断)时下一拍才 `_retry_connect()` → `NetBus.stop()`。那个 stop 与本次应答可能挤在
	#   **同一次 poll**,ENet 处理 DISCONNECT 时当场把通道数清零 → 不判活的话这一发必打
	#   `Unable to send packet on channel 0, max channels: 0`。三个实参都非 null
	#   (`Vector2i(-1,-1)` 也不等于 null),不会被 `reply` 的 null 截断规则吃掉。
	var sp: Vector2i = _host.role_spawns().get(role, Vector2i(-1, -1)) \
			if _host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.reply(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if _host.has_method("_broadcast_round_state"):
		_host._broadcast_round_state()
	print("worker: role %d 重连成功(peer=%d)" % [role, caller])

# 进场拉取:对局场景建好后主动要一次昵称/色相/生效选项/出生点/role 集合。
# ★ 它**取代**原先"服务器推三载荷"那条路径 —— 那次推的根因问题是「推给一个正在切场景的客户端」:
#   服务器在同一次 poll 里连推 4 条,而那一刻新场景的订阅方一个都不存在 → 静默丢失(自检 B2:
#   对手颜色不生效 / 昵称表空到连自己头顶 ID 都建不出 / 禁武器闸门没上)。拉的时序不敏感。
# 不在本局(role==0)→ 静默丢弃,与 NetBusExt 的旁路语义一致(迟到的旧客户端连到复用端口的
# dispatch 不报错)。
func _on_match_sync(caller: int) -> void:
	var role := 0
	for r in _claims:
		if _claims[r] == caller:
			role = int(r)
			break
	if role == 0:
		return
	var spawns := {}
	# 地面武器:开局那批**必须随这条拉取一并给**,不走 weapon_spawned 推送 ——
	# 推送会撞上"客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失"那类事故
	# (当年三载荷就是这么丢的;反向断言在 match_sync_probe)。
	var ground: Array = []
	if _host != null and _host.has_method("ground_weapons_payload"):
		ground = _host.ground_weapons_payload()
	if _host != null and _host.has_method("role_spawns"):
		spawns = _host.role_spawns()
		# ★ 换边之后这份表会**过期**,而这里**不补发**(控制者裁定,别当 bug 修):3v3 每局整队
		#   对调 `_round_spawns`,而客户端只在进场/重连时拉一次 —— 但出生点表只用于"进场那一刻
		#   的初始摆放",之后一律由权威快照 + C2 `reconcile()` 驱动。往 `round_state` 里塞第二份
		#   是给同一份数据开第二条投递路径(自检 B2 那类事故的形状,本册硬纪律)。
		#   新鲜度由 **B 册客户端在「新一轮 COUNTDOWN」时重拉一次 match_sync** 解决(那一拍它本来
		#   就在清子弹 + `reset_destructibles()`,拉取与它同位置);换局时 `ground_weapons`(服务器
		#   重铺)与 `destroyed`(已还原成基线)也一并因此对齐。
		#   ★ 与 1v1 同源:`957ac69` 已**刻意抑制**了补态那一路的出生点校正(那条既有行为别动)。
	else:
		# 理论上到不了:客户端要收到 match_start 才会进对局场景,而 match_start 是在 `_begin_match`
		# 建宿主那次调用里发出的(同一帧内 `_host` 就赋好值了),报文往返只可能更晚。
		# 真到了这里说明时序变了 —— 不静默,留一条痕(客户端会退回 match_start 带的那份出生点)。
		push_warning("match_sync: role %d 报到时对局宿主还没建好,spawns 回空" % role)
	# 掉线窗口内被拆的墙:与基线不同才带(**空数组不带该键**,避免每局固定多几 KB)。
	# ★ 为什么放在 match_sync 而不是新开一条 RPC:这条本来就是"客户端主动拉取的全量进场载荷",
	#   复用它可以不碰 NetBus 的方法表(硬纪律),也让"重连后补态"与"进场建态"走同一条路。
	var destroyed: Array = []
	if _host != null and _host.has_method("destroyed_cells"):
		destroyed = _host.destroyed_cells()
	# 队伍表:进场/重连各拉一次,客户端据此上色/分组。
	# ★ 必须**显式下发**:role 号由大厅「最小空闲号」分配、有人退出后会留空洞,客户端
	#   从 roles 推导必然出错(这正是 --roles 那条协议当年的教训)。
	# ★ 不进 round_state:开局载荷只留**一条**投递路径(自检 B2 那类事故的形状)。
	var teams: Dictionary = {}
	if _host != null and _host.has_method("team_map"):
		teams = _host.team_map()
	# ★ 判活再回:这是开局窗口里**最容易被踩的一条** —— 客户端一进对局场景就发 match_sync,
	#   而"进场景 → 请求 →(脚本/玩家)退出"可能挤在同一两帧里;回复是定向可靠包,
	#   往 ENet 已拆掉的 peer 发就是 `Unable to send packet on channel 0, max channels: 0`。
	#   判据见 NetBus.is_peer_live(以及 docs/2026-09-17-pvp-weapon-net-fixes.md §1.5)。
	if not NetBus.is_peer_live(caller):
		return
	var data := {
		"names": _claim_names,
		"hues": _claim_hues(),
		"options": _claim_opts.get(1, {}),
		"roles": _role_set,
		"spawns": spawns,
		"ground_weapons": ground,
	}
	if not destroyed.is_empty():
		data["destroyed"] = destroyed
	# ★ 与 `destroyed` 同款纪律:**非空才带**。不带队时(1v1/大乱斗)旧客户端忽略未知键、
	#   新客户端拿到空 → 双向兼容,不需要协商。
	if not teams.is_empty():
		data["teams"] = teams
	NetBus.rpc_id(caller, "match_sync_data", data)


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
	# 越界判据 = 「role 是否在本局参战集合内」(大厅经 --roles 显式传入),**不是**任何从人数
	# 推导出来的界:房内有人退出会留 role 空洞({1,3} 而成员 2 人),拿人数当上界会踢掉真客户端(自检 B1)。
	# ★ 3v3 也走这条越界判据(不只是大乱斗):`_team_of_role` 只覆盖 --roles 里的 role,
	#   放进来一个集合外的 role 会让 `_claims.size()` 提前够数开局,而 `TeamHost.start_on` 那侧
	#   `spawns[role]` 缺键(整局摆位掀掉一半)—— 这条判据正是"teams 的键覆盖全部参战 role"的守卫。
	if _host != null or _match_started \
			or ((_royale or _team_mode) and not _role_set.has(role)) \
			or (_claims.has(role) and _claims[role] != caller):
		print("worker: 拒绝串线连接 peer=%d(role=%d)" % [caller, role])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if _claims.has(role):
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	if _team_mode:
		# 分母与下一条满员判据**同源**(去重后的队伍表)—— 两处不一致时这句读数会说谎
		print("worker: 3v3 角色 %d = peer %d (%d/%d 人)" % [role, caller,
				_claims.size(), _team_of_role.size()])
		# ★ 满员才开:用户裁定「满 6 人才开」,没有降级开局这一档(与 --royale 不同 ——
		#   那边少人可以打,这边两队人数必须相等)。
		# ★ 判据取 `_team_of_role.size()` 而**不是** `_role_set.size()`(Task 9 评审 M5):
		#   `_team_of_role` 按 role **去重**,而 `_role_set` 是 `--roles` 的逐 token 列表 ——
		#   `--roles 1,1,2,2,3,3 --teams 1,1,1,2,2,2` 这种输入长度校验能过,但队伍表只有 3 键
		#   ⇒ 拿 `_role_set.size()`(6)当满员界**永远到不了** ⇒ 干等 30s 超时退出释放端口。
		#   取"驱动摆位的那个集合"才是对的:`TeamHost` 的出生点表正是按 `teams.keys()` 出键
		#   (`_init` 里 `_team_of` 就是它),判据的分母与它同源。正常路径下两值相等,零风险。
		if _claims.size() >= _team_of_role.size():
			_defer_begin_match()
	elif _royale:
		print("worker: 大乱斗角色 %d = peer %d (%d/%d 人,另有 %d 个 AI)" % [role, caller,
				_claims.size(), _human_role_count(), _ai_roles.size()])
		# 收齐全部人类(其余角色由 AI 补位)即开局
		if _claims.size() >= _human_role_count():
			_defer_begin_match()
	else:
		print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
		if _claims.size() >= 2 - _ai_roles.size():
			_defer_begin_match()

# 开局**延到帧末**再执行,不在 _on_role_claimed 里同步开:
# 每个客户端都是「claim_role 紧接 player_options」两条包(同一帧 flush → 同一次 poll 到达),
# 而收齐判据由**最后一个** claim 满足 → 同步开局会在同一次 poll 里抢先建局,那个客户端的
# 本端选项(角色颜色)还没归档;它恰是 role1(2 人局的常态)时,整局规则项(禁武器等)也拿不到
# →「房主勾了禁武器、局里却全武器可用」「有人的颜色不生效」(探针实测:两端的 hue 只有先报到
# 的那份在,role1 的规则项整份丢失)。延到帧末 = 同一次 poll 内的 player_options 先全部归档,
# 再取快照建局。重入由 _begin_match 自身的 `_match_started or _host != null` 守卫兜住。
func _defer_begin_match() -> void:
	call_deferred("_begin_match")

func _begin_match() -> void:
	if _match_started or _host != null or _claims.size() + _ai_roles.size() < 2:
		return
	_match_started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	if _team_mode:
		# 房主(role1)规则项随 claim 上报生效; TeamHost.start_on 负责按队散点出生 + 逐角色 match_start。
		# ★ 第 4 个实参是 `teams`(role→队号),不是 spawns —— 见 TeamHost._init 上方那条注释。
		_host = TeamHost.start_on(_claims, MatchBootstrap.PVP_MAP, _claim_opts.get(1, {}), _team_of_role)
	elif _royale:
		# 房主(role1)规则项随 claim 上报生效; RoyaleHost.start_on 负责散点出生 + match_start
		_host = RoyaleHost.start_on(_claims, MatchBootstrap.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
	else:
		# 服务器权威规则项以房主(role1)选项为准(经 NetBusExt 上报;缺省=全默认)
		_host = MatchBootstrap.start_on(_claims, MatchBootstrap.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
	add_child(_host)
	# AI 补位昵称:唯一名 + -computer 后缀(排行榜/头顶显示,地位与真人等同)
	for ai_r in _ai_roles:
		_claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	# ★ 原先这里**推** peer_info/peer_hues(还有 MatchHost 推的 match_options)—— 已删除:
	#   三者与 match_start 落在同一次客户端 poll 里,而那一刻新场景的订阅方还不存在 → 静默丢失
	#   (自检 B2)。现在由对局场景**进场拉取**(NetBus.match_sync → `_on_match_sync`),本函数只管建局。
	if _royale and _host.has_method("set_display_names"):
		_host.set_display_names(_claim_names)   # 排行榜昵称表
	var mode_note := ""
	if _royale:
		mode_note = "(大乱斗 %d 人,其中 AI %d)" % [_claims.size() + _ai_roles.size(), _ai_roles.size()]
	elif _team_mode:
		mode_note = "(3v3 %d 人,队伍 %s)" % [_claims.size(), str(_team_of_role)]
	print("worker: 对局开始%s" % mode_note)

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
		if _royale or _team_mode:
			# 大乱斗/3v3:单个参与者掉线 = **先进宽限期**(不立刻移出,身体留在场上),
			# 宽限内可被 reclaim_role 认领回来;到点仍未回来才走 mark_disconnected
			# (3v3 那边由 TeamHost 判"整队走光才终局" —— 该队少人继续打)。
			# ★ 身体不销毁是本设计最省的一处:分数/阵亡/血量/背包/位置/世界破坏/地面武器
			#   全在活着的节点与进程内存里,一条都不用恢复(见 spec §4)。
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			if role == 0:
				return
			_claims.erase(role)
			_enter_grace(role)
			if _claims.is_empty():
				# 最后一个真人也走了:仍**先给宽限**(最后一人掉线同样该有机会回来),
				# 到点没人回来才收场退出 —— 收口在 `_expire_graces` 的末尾,
				# 那条判据是**大乱斗/3v3 worker 唯一的正常退出口**(royale_host.gd:428 明说靠它兜底:
				# 丢了它,每局结束都留一个僵尸 worker 永驻并占着已归还的端口)。
				print("worker: 全员离开,进宽限等待重连")
			else:
				print("worker: 玩家掉线进宽限(剩 %d 人在线)" % _claims.size())
			return
		# 1v1:一方掉线**不再拆局退进程** —— 进宽限期等它回来(spec §3.2)。
		# ★ 这是 1v1 能做重连的**前提**:原实现 `_host.queue_free()` + `quit(0)` 会让进程
		#   直接消失,对局状态随之蒸发,重连无从谈起。
		var role1 := 0
		for r in _claims:
			if _claims[r] == peer_id:
				role1 = int(r)
				break
		if role1 == 0:
			return
		_claims.erase(role1)
		_enter_grace(role1)
		print("worker: 玩家掉线进宽限(1v1)")
		return
	elif is_participant:
		if _royale or _team_mode:
			# 尚未开局的缺席:从收人表摘除,继续等
			# (大乱斗:超时兜底按已到人数开局;3v3:人掉光了也没法开,交给 _process 的超时梯退出)
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			_claims.erase(role)
			_claim_names.erase(role)
			_claim_opts.erase(role)
			print("worker: 报到角色 %d 掉线,继续等待(%d/%d)" % [role, _claims.size(), _human_role_count()])
			if _claims.is_empty():
				_claim_wait = 0.0
		else:
			# 尚未满员就有 claimed 玩家掉线 → 别占着端口干等,退出
			print("worker: 角色报到后掉线,退出")
			get_tree().quit(0)
