extends Node2D
# 服务器入口(headless)。角色由命令行 user args 决定 —— ★ 开关必须写在 -- 之后(写在前面会被 Godot 丢掉、静默跑错分支):
#  无参数 = 大厅(默认,7777):只做建房/配对,配对完成后为每局拉起一个 --worker 子进程;--worker --port P = 1v1(独占端口等两名客户端 claim_role)。
#  --worker --royale --port P [--roles 1,3] [--ai-roles r,r] = 大乱斗(限时死斗,收齐全部人类 role 或 20s 超时按已到人数 ≥2 开局,全员走光才退出)。
#  --worker --team --port P --roles r,... --teams t,... = 3v3(满员才开、不降级,收不齐就超时退出释放端口,整队走光才终局)。
# ★ 两种模式收人方向相反:大乱斗可按已到人数降级开局,3v3 两队人数必须相等 ⇒ --roles 与 --teams 同序等长(队号不从 role 号推);也不再传「人数 + role 上界」两个整数 —— 有人退出会留 role 空洞,从人数推导必然出错。

var _host: Node = null
var _claims: Dictionary = {}   # role(int) -> peer_id(worker 视角)
var _claim_names: Dictionary = {}   # role(int) -> 昵称(开局 peer_info 回传两端)
var _claim_opts: Dictionary = {}   # role(int) -> 本端选项(颜色/规则偏好)
var _wait_timer := 0.0
var _royale := false
# 本局全部参战 role(含 AI 补位号),由大厅经 --roles 显式传入 —— 从人数推导必然出错(编号会留空洞,持 3 号的真客户端会被当串线踢掉)。
var _role_set: Array[int] = []
var _ai_roles: Array = []    # AI 补位的 role 列表(实验性;这些 role 不等 claim,由服务端 AI 驱动)
var _claim_wait := 0.0
var _understaffed_wait := 0.0   # 开局前可用玩家 <2(大乱斗)/未满员(3v3)的持续时长(超时退出释放端口)
var _team_mode := false
var _team_of_role: Dictionary = {}   # role(int) -> 队号(1/2);由 --teams 与 --roles 同序解析
var _team_teams_raw: Array[int] = []
var _lan_ip_text := ""          # 局域网 IP 串(写 local_ip.txt 用;公网 IP 到手后一并补写)
# ★★ _worker 是唯一可靠的我是不是 worker 标志:本脚本一个入口兼两种角色,而 _ready 里的 is_worker 只是局部量、出不了函数。
#   报到梯必须以正的它为门 —— 写成 worker-only 标志的否定时,大厅里那些合取项全部成立,大厅会在开机 30 秒后自己 quit(0),7777 上的建房/配对/转连全死(实测发生过)。
#   ★ 自大厅分支末尾落了 set_process(false) 起,非 worker 进程进梯整类封死(与各条梯的极性无关)。
var _worker := false
var _match_started := false
# 断线宽限期:掉线的 role 先进 _grace,不立刻移出(大乱斗)/ 不立刻退进程(1v1),宽限内可被 reclaim_role 认领回来;
# 到点仍未回来 → 走既有的移出对局 / 收场退出语义。★ 时长唯一入口是 GraceWindow.DEFAULT_SECONDS。
var _grace := GraceWindow.new()
var _grace_check_timer := 0.0
var _tokens: Dictionary = {}   # role(int) -> token(String),客户端经 report_token 报来

func _ready() -> void:
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
				# 队号集合(与 --roles 同序);越界值静默丢弃是有意的 —— 长度不等会在下面的校验里当场拒绝启动,而猜一个默认队号会把整局分成错的队且不报错。
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
				MatchGround.test_ground_teleport = true
			"--test-destroy-tile":
				# 仅测试用(见 MatchState.test_destroy_cell);★ 必须给个非零默认 3.0 —— 省掉时留 0.0,钩子会在第一帧就拆,对局开始 N 秒后的语义就没了。
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
	# ★ 解析完立刻落进实例标志(报到梯读它);位置紧跟循环、不进任何分支 —— 写进某条分支里迟早会漏掉另一种形态。
	_worker = is_worker
	if is_worker:
		# ★ 模式开关互斥(--royale 与 --team 同时为真就当场拒绝启动):三处判据的优先级此前并不一致,手敲两个开关会走 royale 那支开局,
		#   而 _team_of_role 永不填充、_begin_match 却按 _team_mode 去建 TeamHost → 空 teams → spawns[role] 全员缺键。形态由 tools/room_sweep_lint.gd ⑦ 钉住。
		if _royale and _team_mode:
			push_error("worker: --royale 与 --team 不能同时为真(模式开关互斥),拒绝启动")
			get_tree().quit(1)
			return
		if _royale:
			if _role_set.is_empty():
				# 大厅拉起时总会带 --roles;空集合只可能是手工命令行漏了 —— 不猜一个集合出来开局(猜错 = 静默踢真客户端)。
				push_error("大乱斗 worker: 缺 --roles(本局参战 role 集合),拒绝启动")
				get_tree().quit(1)
				return
		elif _team_mode:
			# --roles 与 --teams 必须等长且非空(队号按同序配对);不等 = 拒绝启动 —— 猜一个默认队号会把整局分成错的队,而且不报错。
			# ★ 这也保证了 teams 的键覆盖本局全部参战 role:TeamHost 的摆位表按 teams.keys() 出键,缺键会让那个 role 静默生在 (-1,-1)。
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
	# 先杀掉还占着 7777 的旧服务端(上次没关干净会 bind 失败→闪退),再监听。
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
	# ★★ 大厅不跑 _process:报到梯与宽限轮询全是 worker 语义,让大厅也 tick 只是敞着一个口子 —— 实测栽过一次(专用大厅开机 30s 后 quit(0) 自杀,7777 上的建房/配对/转连全死)。
	#   ★ 必须用 set_process(false),不能改成 process_mode(后者会沿继承关掉子节点的 _process,而大厅的全部实际工作都在 RoomManager 里);⚠ 这一行同时停掉了 _expire_graces 的唯一调用点 —— 将来大厅一旦自己有了 _grace 条目,那条轮询必须搬出 _process。
	#   ★ ⚠ 位置守卫 duel_spawn_timeout_smoke 已删(2026-10-09)⇒ 今天零守卫:本行须在 _ready 体内、add_child(RoomManager.new()) 之后,且两者之间没有早退。
	set_process(false)

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
	ips.sort_custom(func(a: String, b: String) -> bool: return _priv_score(a) > _priv_score(b))
	_lan_ip_text = ", ".join(ips)
	print("本机局域网 IP: " + _lan_ip_text + "(把第一个填进「服务器地址」,端口 7777)")
	_write_ip_file("本机局域网 IP: %s
(朋友在「1v1→服务器地址」里填第一个;端口 7777)
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

# worker 端口段文案;★ 单一来源 = WorkerLauncher 的 WORKER_PORT_BASE / WORKER_PORT_SPAN,勿在提示串里另写死数字(曾写 7800~7910 与实际池不符,照它放行防火墙会漏掉半个池子)。
static func _worker_port_span_text() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]

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
		# ★ 提示串里同时打 role 集合与队伍表:这两者同序配对是 3v3 最容易被改坏的一处,联调时一眼能看出谁是哪一队。
		print("3v3 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s,队伍 %s)" % [
				_human_role_count(), port, str(_role_set), str(_team_of_role)])
	else:
		print("worker 就绪,等待两名玩家……(port %d)" % port)
	_print_local_ips()

func _human_role_count() -> int:
	var n := 0
	for r in _role_set:
		if not _ai_roles.has(int(r)):
			n += 1
	return n


# 把宽限期读数推给宿主(它是 round_state 的生产者,见 MatchState.grace_snapshot);★ 只在 _host 存在时写,且不广播(广播由调用方决定)。
func _sync_grace_snapshot() -> void:
	if _host != null:
		_host.grace_snapshot = _grace.remaining(Time.get_ticks_msec())


# 把一个 role 放进宽限期。★ 必须置空它的输入源 + 清掉它的待消费输入队列(两件缺一不可):
# PacketInputSource 在队列空时沿用上一包,不置空的话掉线者的身体会保持他断开前最后一帧的输入 —— 一直朝那个方向跑、或一直开枪。
func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if _host != null:
		var src = _host.input_sources.get(role, null)
		if src != null and src.has_method("reset_state"):
			src.reset_state()
		# ★★ 清输入源不够,必须连队列一起清:掉线瞬间队列里可能还压着一条已经到达的包,而 apply_packet() 是整体覆盖 _held/_axis ⇒
		#   那条包会在 reset_state() 之后被执行,把按着的键重新武装并保持整个宽限期(clear_edges() 不含 _held)。这一行是掉线者的身体留在场上不动的全部内容,别删。
		_host.reset_input_queue(role)
		# ACS 分母口径:必须记掉线这一刻的局号 —— 宽限期有 60s,到点的 mark_disconnected 读到的 _round_num 可能已因换局 +1,那会把离开者的 ACS 压低。
		_host.note_disconnect_round(role)
		_host.peer_by_role.erase(role)
		if _host.has_method("_broadcast_round_state"):
			_sync_grace_snapshot()
			_host._broadcast_round_state()


func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		_sync_grace_snapshot()
		# ★ 到点做什么 = 纯分派(GraceWindow.expire_action),别在这里再写一遍 if/else:原先的 else 把 1v1 与 team 一起吞了,3v3 第一个宽限到期的人会带着整局退进程(用户裁定是该队少人继续打)。形态由 tools/room_sweep_lint.gd 钉住,答案本身零守卫(grace_window_smoke 已删·2026-10-09)。
		if GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE:
			if _host != null and _host.has_method("mark_disconnected"):
				_host.mark_disconnected(role)
		else:
			# ★ 先通知还连着的人,顺序不能反 —— 反了先 quit(0),那条可靠的定向包就永远发不出去。
			_notify_opponent_left()
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			get_tree().quit(0)
	# 大乱斗/3v3:全员走光且宽限期已空(一个都没回来)→ 收场退出。★ 这是大乱斗/3v3 worker 唯一的正常退出口(丢了会让每局都留下僵尸进程永驻占端口)。
	# ★ _match_started 不能省(本函数由 _process 每秒无条件调用,开机等玩家同样满足 _claims 空 + 宽限空 ⇒ 少了它 worker 一开机就判全员离开自杀);★ _team_mode 必须一起收进来(与上面那条 else 是两条判据)。
	if (_royale or _team_mode) and _match_started and _claims.is_empty() and _grace.size() == 0:
		print("worker: 全员离开,%s结束" % ("大乱斗" if _royale else "3v3"))
		get_tree().quit(0)


# 1v1 收场之前通知还连着的人(对手不会回来了)。★★ 为什么必须有:NetBus.opponent_left 全仓此前零调用点,而客户端「对手已离开 → 2.5s 回主菜单」一直挂在它上面。
#   不发的话幸存者只看到 server_disconnected、启动重连、耗尽 60s 预算才回主菜单(在已死的静止世界里干等一分钟)。★ 只在 1v1 收场这一处发(宽限期是给对手回来用的窗口);发送走 NetBus.reply(体内首行判活;钉这条的 rpc_liveness_probe 已删 2026-10-09 ⇒ 零守卫)。
func _notify_opponent_left() -> void:
	for role in _claims:
		var peer := int(_claims[role])
		if NetBus.reply(peer, "opponent_left"):
			print("worker: 1v1 收场前通知在线玩家(opponent_left,role=%d peer=%d)" % [int(role), peer])


func _process(delta: float) -> void:
	_grace_check_timer += delta
	if _grace_check_timer >= 1.0:
		_grace_check_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
		# ★ 读数每秒保鲜一次:客户端在两次 round_state 之间自己走秒,不刷的话宽限期里任何一次别的广播都会带上旧值 ⇒ 客户端本地倒计时被拨回(最多 60 秒,看着像重来一轮);本函数不额外广播。
		_sync_grace_snapshot()
	# 3v3:人没到齐就干等没有意义(满 6 人才开)→ 超时退出释放端口,绝不降级开局(与 --royale 的 20s 按已到人数开局方向相反,别顺手统一);★ 计时从 worker 启动起算,不因有人报到/离开而复位。
	if _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 3v3 报到超时(%d/%d),退出释放端口" % [_claims.size(), _team_of_role.size()])
			get_tree().quit(0)
	elif _royale and not _match_started and _host == null and _claims.size() >= 2:
		_claim_wait += delta
		if _claim_wait > 20.0:
			print("worker: 报到超时(%d/%d),按已到人数开局" % [_claims.size(), _human_role_count()])
			_begin_match()
	elif _royale and not _match_started and _host == null and _claims.size() < 2:
		_understaffed_wait += delta
		if _understaffed_wait > 10.0:
			print("worker: 可用玩家 %d/2,超时退出释放端口" % _claims.size())
			get_tree().quit(0)
	# 1v1:一个 claim_role 都没到就干等没有意义(配对早已在大厅完成,报到应在秒级到达);这是三种模式里唯一原先没有报到梯的一支,少了它两个客户端都消失时 worker 永驻、端口白占到 2h 超龄兜底。
	# ★ 30s 是承重的:客户端侧内建兜底是 12s 转连 / 25s claim ⇒ worker 必须晚于它们退,否则客户端还在重试、端口已经没了。判据也覆盖只到一个 claim(1v1 要 2 人齐才开)。
	# ★★ 门控必须是正的 _worker,不能写成 worker-only 标志的否定(大厅里那些合取项全部成立 ⇒ 大厅开机 30s 自杀,实测的回归)。
	elif _worker and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 1v1 报到超时(%d/2),退出释放端口" % _claims.size())
			get_tree().quit(0)

func _on_player_options(caller: int, opts: Dictionary) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_claim_opts[r] = opts
			return

# 客户端 claim 之后立刻报来的一次性令牌(与 claim 同一次 poll 到达),按 caller 反查 role 归档;★ 只归档不校验 —— 校验发生在宽限期里的 reclaim_role。
func _on_token_reported(caller: int, token: String) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_tokens[int(r)] = token
			return

# 宽限期内重新认领 role(断线重连)。三条拒绝条件一条都不能少:没开局 / 该 role 不在宽限期 / token 不匹配;任何一条不满足都踢连接,不能让它静默留在局里收快照。
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
	_claims[role] = caller
	_host.peer_by_role[role] = caller
	# ★ 换输入源不是 PacketInputSource.new(role, caller) —— 它不收参数;必须把新源挂回那个还活着的玩家节点,只换表里的引用不够(玩家手里仍攥着旧源)。
	# ★ 直取 players[role] 依赖 _expire_graces 里的次序:只有它会调 mark_disconnected(那里才 erase),且它先 _grace.leave 再 mark。
	var src := PacketInputSource.new()
	(_host.players[role] as Node2D).set_input_source(src)
	_host.input_sources[role] = src
	_host.reset_input_queue(role)
	_host._ack_seq[role] = 0      # C2 锚点重协商:客户端 rollback ring 已失(见 spec §3.4)
	_grace.leave(role)
	# 回一条 match_start 让客户端重进对局场景(载荷与首次开局同源);★ 走 NetBus.reply 而不是 rpc_id —— 它是答复 caller 的收口,内部先判活。
	#   这个窗口可达:客户端发完 reclaim_role 是等这条应答,被踢/链路断时下一拍会 _retry_connect() → NetBus.stop(),那个 stop 与本次应答可能挤在同一次 poll,ENet 当场把通道数清零 ⇒ 不判活必打 max channels: 0。
	var sp: Vector2i = _host.role_spawns().get(role, Vector2i(-1, -1)) \
			if _host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.reply(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if _host.has_method("_broadcast_round_state"):
		# ★★ 读数必须跟着上面那行 _grace.leave(role) 一起变:不刷新的话这一发载荷恰好把这个刚回来的人继续列成「掉线中」;而 1v1/3v3 的 round_state 只在状态跃迁时才发 ⇒ 错值会一直挂到下一次击杀/换局。
		_sync_grace_snapshot()
		_host._broadcast_round_state()
	print("worker: role %d 重连成功(peer=%d)" % [role, caller])

# 进场拉取:对局场景建好后主动要一次昵称/色相/生效选项/出生点/role 集合;★ 它取代原先服务器推三载荷那条路径(同一次 poll 里推 4 条,而那一刻新场景的订阅方还不存在 → 静默丢失)。不在本局(role==0)→ 静默丢弃。
func _on_match_sync(caller: int) -> void:
	var role := 0
	for r in _claims:
		if _claims[r] == caller:
			role = int(r)
			break
	# ── 诊断开关(默认关):-- --matchsync-diag —— 只是诊断,开关关着时本块一行都不打(生产行为逐字不变)。★ 开关必须写在 -- 之后(写在前面会被 Godot 当引擎参数丢掉、静默失效);它把本函数两个静默早退(role==0 / is_peer_live 为假)的全部读数一次打出来。
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 收到 match_sync: caller=%d role=%d _claims.has(caller)=%s _claims 键=%s 值=%s is_peer_live(caller)=%s role_claimed 已连=%s" % [
				caller, role, str(_claims.has(caller)), str(_claims.keys()), str(_claims.values()),
				str(NetBus.is_peer_live(caller)),
				str(NetBus.role_claimed.is_connected(_on_role_claimed))])
	if role == 0:
		return
	var spawns := {}
	# 地面武器必须随这条拉取一并给,不走 weapon_spawned 推送:推送会撞上客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失那类事故。
	var ground: Array = []
	if _host != null and _host.has_method("ground_weapons_payload"):
		ground = _host.ground_weapons_payload()
	if _host != null and _host.has_method("role_spawns"):
		spawns = _host.role_spawns()
		# ★ 换边之后这份表会过期,而这里不补发(控制者裁定,别当 bug 修):出生点表只用于进场那一刻的初始摆放,之后一律由权威快照 + C2 reconcile() 驱动;新鲜度由客户端在「新一轮 COUNTDOWN」时重拉一次 match_sync 解决。
	else:
		# 理论上到不了(match_start 与 _host 赋值在同一帧,报文往返只可能更晚);真到这说明时序变了 —— 不静默,留一条痕。
		push_warning("match_sync: role %d 报到时对局宿主还没建好,spawns 回空" % role)
	# 掉线窗口内被拆的墙:与基线不同才带(空数组不带该键,避免每局固定多几 KB);★ 复用 match_sync 而不新开 RPC = 不碰 NetBus 的方法表,让重连后补态与进场建态走同一条路。
	var destroyed: Array = []
	if _host != null and _host.has_method("destroyed_cells"):
		destroyed = _host.destroyed_cells()
	# 队伍表:必须显式下发(role 号由大厅最小空闲号分配、会留空洞,从 roles 推导必然出错);★ 不进 round_state —— 开局载荷只留一条投递路径。
	var teams: Dictionary = {}
	if _host != null and _host.has_method("team_map"):
		teams = _host.team_map()
	# ★ 判活再回:客户端一进对局场景就发 match_sync,进场景 → 请求 → 退出可能挤在同一两帧里,往 ENet 已拆掉的 peer 发就是 max channels: 0(判据见 NetBus.is_peer_live)。
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
	if not teams.is_empty():
		data["teams"] = teams
	var _rpc_err := NetBus.rpc_id(caller, "match_sync_data", data)
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 已发 match_sync_data → caller=%d data 键=%s rpc_id 返回=%d 在线 peers=%s" % [
				caller, str(data.keys()), _rpc_err, str(multiplayer.get_peers())])


# 自杀脱困(大乱斗 / 3v3):caller → role → 宿主(存活/对局中校验在那边)。
# ★★ 闸里必须有 _team_mode:只认 _royale 时 3v3 worker 把 suicide_request 静默丢掉(K 键毫无反应、一个字日志都没有)。⚠ 守卫 tests/probe/team_host_probe 的 ⑫ 已删(2026-10-09)⇒ 今天零守卫。
func _on_suicide_request(caller: int) -> void:
	if not (_royale or _team_mode) or _host == null:
		return
	for r in _claims:
		if _claims[r] == caller:
			if _host.has_method("request_suicide_role"):
				_host.request_suicide_role(int(r))
			return

func _on_role_claimed(caller: int, role: int, player_name: String) -> void:
	# 防串线:对局已开始、role 越界、或该 role 已被其他 peer 占用 → 这个连接不属于本局,直接踢(端口复用竞态下迟到的客户端可能连到旧 worker);★ 越界判据 = role 是否在本局参战集合内,不是任何从人数推导出来的界(房内有人退出会留 role 空洞,拿人数当上界会踢掉真客户端)。
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
		print("worker: 3v3 角色 %d = peer %d (%d/%d 人)" % [role, caller,
				_claims.size(), _team_of_role.size()])
		# ★ 满员才开(用户裁定满 6 人才开,没有降级开局这一档);判据取 _team_of_role.size() 而不是 _role_set.size() —— 前者按 role 去重,而 --roles 1,1,2,2,3,3 这种输入长度校验能过、队伍表却只有 3 键 ⇒ 拿 6 当满员界永远到不了(干等 30s 超时退出)。
		if _claims.size() >= _team_of_role.size():
			_defer_begin_match()
	elif _royale:
		print("worker: 大乱斗角色 %d = peer %d (%d/%d 人,另有 %d 个 AI)" % [role, caller,
				_claims.size(), _human_role_count(), _ai_roles.size()])
		if _claims.size() >= _human_role_count():
			_defer_begin_match()
	else:
		print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
		if _claims.size() >= 2 - _ai_roles.size():
			_defer_begin_match()

# 开局延到帧末再执行,不在 _on_role_claimed 里同步开:每个客户端都是「claim_role 紧接 player_options」两条包(同一次 poll 到达),
#   同步开局会在同一次 poll 里抢先建局,那个客户端的本端选项(角色颜色 / 禁武器规则)还没归档。重入由 _begin_match 自身的守卫兜住。
func _defer_begin_match() -> void:
	call_deferred("_begin_match")

func _begin_match() -> void:
	if _match_started or _host != null or _claims.size() + _ai_roles.size() < 2:
		return
	# ★ 3v3:帧末再核一次满员 —— 收齐判据由最后一个 claim 满足,而这一帧里 claim 集可能缩小(有人刚 claim 完就掉线);不核的话 5 个人也能开,而本模式的纪律是满员才开、不降级。
	# ★ 位置必须在 _match_started = true 之前:早退的函数因此不写 _match_started,30s 超时梯照旧从 worker 启动起算;写在之后会卡死 worker(梯子进不去,而它已置真、从不复位)。
	if _team_mode and _claims.size() < _team_of_role.size():
		print("worker: 3v3 帧末复核未满员(%d/%d),不开局 —— 交 30s 超时梯"
				% [_claims.size(), _team_of_role.size()])
		return
	_match_started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	# 房主选的地图(随 player_options 上报)客户端路径不可信 → 过 MapCatalog 校验(只认仓内 res://maps/*.cyrm、拒绝 ..、必须有双出生点),不合规一律回落默认 PvP 图。
	var match_map := MapCatalog.resolve_pvp_map(str(_claim_opts.get(1, {}).get("map", "")))
	if match_map == "":
		match_map = MatchBootstrap.PVP_MAP
	if _team_mode:
		# 房主(role1)规则项随 claim 上报生效;TeamHost.start_on 负责按队散点出生 + 逐角色 match_start(★ 第 4 个实参是 teams = role→队号,不是 spawns)。
		_host = TeamHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _team_of_role)
	elif _royale:
		_host = RoyaleHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	else:
		_host = MatchBootstrap.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	add_child(_host)
	for ai_r in _ai_roles:
		_claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	if _royale and _host.has_method("set_display_names"):
		_host.set_display_names(_claim_names)   # 排行榜昵称表
	var mode_note := ""
	if _royale:
		mode_note = "(大乱斗 %d 人,其中 AI %d)" % [_claims.size() + _ai_roles.size(), _ai_roles.size()]
	elif _team_mode:
		mode_note = "(3v3 %d 人,队伍 %s)" % [_claims.size(), str(_team_of_role)]
	print("worker: 对局开始%s" % mode_note)

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
			# 大乱斗/3v3:单个参与者掉线 = 先进宽限期(不立刻移出,身体留在场上),宽限内可被 reclaim_role 认领回来;到点仍未回来才走 mark_disconnected(3v3 由 TeamHost 判整队走光才终局)。
			# ★ 身体不销毁是本设计最省的一处:分数/阵亡/血量/背包/位置/世界破坏/地面武器全在活着的节点与进程内存里,一条都不用恢复。
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
				# 最后一个真人也走了:仍先给宽限(最后一人掉线同样该有机会回来),到点没人回来才由 _expire_graces 末尾收场退出。
				print("worker: 全员离开,进宽限等待重连")
			else:
				print("worker: 玩家掉线进宽限(剩 %d 人在线)" % _claims.size())
			return
		# 1v1:一方掉线不再拆局退进程 —— 进宽限期等它回来(这是 1v1 能做重连的前提:原实现的 queue_free() + quit(0) 会让对局状态随之蒸发)。
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
			print("worker: 角色报到后掉线,退出")
			get_tree().quit(0)
