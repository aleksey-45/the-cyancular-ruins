extends Node2D
# 服务器入口(headless)。角色由命令行 user args 决定 —— ★ 开关必须写在 -- 之后(写在前面会被 Godot 丢掉、静默跑错分支):

var _room_manager: RoomManager = null
var _host: Node = null
var _pending_match_sync: Array[int] = []
var _claims: Dictionary = {}
var _claim_names: Dictionary = {}
var _claim_opts: Dictionary = {}
var _wait_timer := 0.0
var _royale := false
var _role_set: Array[int] = []
var _ai_roles: Array = []
var _claim_wait := 0.0
var _understaffed_wait := 0.0
var _team_mode := false
var _team_of_role: Dictionary = {}
var _team_teams_raw: Array[int] = []
var _lan_ip_text := ""
var _worker := false
var _match_started := false
var _grace := GraceWindow.new()
var _grace_check_timer := 0.0
const MATCH_OVER_LINGER := 60.0
var _mo_linger := 0.0
var _tokens: Dictionary = {}
var _stop_logged := false

func _ready() -> void:
	print("[server] 版本 %s  pid=%d" % [preload("res://core/config/build_info.gd").display(), OS.get_process_id()])
	var args := OS.get_cmdline_user_args()
	var ctx := ModeContext.from_args(args, NetBus.DEFAULT_PORT)
	if not bool(ctx["ok"]):
		push_error("worker: 启动参数无效 —— %s" % str(ctx["error"]))
		get_tree().quit(1)
		return
	var is_worker := bool(ctx["worker"])
	_worker = is_worker
	NetDiag.set_role("server")
	print("[server] 日志目录: %s" % NetDiag.log_dir())
	_royale = bool(ctx["royale"])
	_team_mode = bool(ctx["team"])
	_role_set.assign(ctx["roles"])
	_ai_roles = ctx["ai_roles"]
	_team_teams_raw.assign(ctx["teams"])
	_team_of_role = ctx["team_of"]
	var port := int(ctx["port"])
	_apply_test_flags(args)
	NetDiag.log_event("server_boot", {"worker": is_worker, "port": port,
			"royale": _royale, "team": _team_mode, "roles": _role_set})
	NetDiag.audit("server_boot", {"worker": is_worker, "port": port})
	if is_worker:
		_run_worker(port)
		return
	ProcUtil.kill_udp_port(NetBus.DEFAULT_PORT)
	var err := NetBus.start_server()
	if err != OK:
		push_error("服务器: 监听失败 %d" % err)
		get_tree().quit(1)
		return
	_room_manager = RoomManager.new()
	add_child(_room_manager)
	print("服务器就绪,等待玩家……(大厅 7777;配对后自动拉起对局 worker)")
	NetDiag.audit("lobby_start", {"version": preload("res://core/config/build_info.gd").display(), "port": NetBus.DEFAULT_PORT})
	get_tree().auto_accept_quit = false
	_print_local_ips()
	_add_console_panel()
	_fetch_public_ip()
	set_process(false)

func _apply_test_flags(args: PackedStringArray) -> void:
	for i in args.size():
		match args[i]:
			"--test-ground-teleport":
				GroundSystem.test_ground_teleport = true
			"--test-destroy-tile":
				if i + 1 < args.size():
					var parts := str(args[i + 1]).split(",")
					if parts.size() >= 2:
						MatchState.test_destroy_cell = Vector2i(
								int(parts[0].strip_edges()), int(parts[1].strip_edges()))
					MatchState.test_destroy_after = 3.0
					if parts.size() >= 3:
						MatchState.test_destroy_after = float(parts[2].strip_edges())


func _print_local_ips() -> void:
	var ips: Array = LocalServer.lan_ip_candidates()
	if ips.is_empty():
		print("本机 IP: 未检测到(网络未连接?)")
		return
	_lan_ip_text = str(ips[0])
	var others := ""
	if ips.size() > 1:
		others = "(其它候选: " + ", ".join(ips.slice(1)) + ",第一候选不通就换)"
	print("本机局域网 IP: %s%s —— 朋友在「服务器地址」里填这个" % [_lan_ip_text, others])
	print("局域网联机: 防火墙需放行 UDP 7777 与 %s;两端必须同一版本客户端/服务端" % _worker_port_span_text())
	_write_ip_file("本机局域网 IP: %s%s
(朋友在「1v1→服务器地址」里填它;防火墙放行 UDP 7777 与 %s;两端同一版本)
" % [_lan_ip_text, others, _worker_port_span_text()])

func _write_ip_file(text: String) -> void:
	var dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("template"):
		dir = ProjectSettings.globalize_path("res://")
	var f := FileAccess.open(dir + "/local_ip.txt", FileAccess.WRITE)
	if f == null:
		f = FileAccess.open("user://local_ip.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

func _add_console_panel() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# ★ 面板 2Hz 刷新,不需要 60fps:实测 60fps 稳态 17.4% 单核 → 15fps 7.2%(headless 1.0%);代价 = 大厅 RPC 最坏 +67ms(worker 是 headless 进程,不受影响)。
	Engine.max_fps = 15
	var panel = preload("res://server/gui/server_panel.tscn").instantiate()
	add_child(panel)
	panel.setup(_room_manager, _lan_ip_text)


# worker 端口段文案;★ 单一来源 = WorkerLauncher 的 WORKER_PORT_BASE / WORKER_PORT_SPAN,勿在提示串里另写死数字(曾写 7800~7910 与实际池不符,照它放行防火墙会漏掉半个池子)。
static func _worker_port_span_text() -> String:
	return WorkerLauncher.port_span_text()

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
		NetDiag.audit("abort", {"mode": _mode_id(), "reason": "bind_failed"})
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
		print("3v3 worker 就绪,等待 %d 名玩家……(port %d,role 集合 %s,队伍 %s)" % [
				_human_role_count(), port, str(_role_set), str(_team_of_role)])
	else:
		print("worker 就绪,等待两名玩家……(port %d)" % port)
	NetDiag.audit("match_boot", {"port": port, "mode": _mode_id(),
			"roles": str(_role_set), "teams": str(_team_of_role)})
	_print_local_ips()

func _human_role_count() -> int:
	var n := 0
	for r in _role_set:
		if not _ai_roles.has(int(r)):
			n += 1
	return n


func _sync_grace_snapshot() -> void:
	if _host != null:
		_host.grace_snapshot = _grace.remaining(Time.get_ticks_msec())


func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if _host != null:
		var src = _host.state.input_sources.get(role, null)
		if src != null and src.has_method("reset_state"):
			src.reset_state()
		_host.reset_input_queue(role)
		_host.note_disconnect_round(role)
		_host.state.peer_by_role.erase(role)
		if _host.has_method("_broadcast_round_state"):
			_sync_grace_snapshot()
			_host._broadcast_round_state()


func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		_sync_grace_snapshot()
		if GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE:
			if _host != null and _host.has_method("mark_disconnected"):
				_host.mark_disconnected(role)
		else:
			_notify_opponent_left()
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			NetDiag.audit("match_over", {"mode": ModeDefs.MODE_PVP, "reason": "grace_expired"})
			get_tree().quit(0)
	if (_royale or _team_mode) and _match_started and _claims.is_empty() and _grace.size() == 0:
		print("worker: 全员离开,%s结束" % ("大乱斗" if _royale else "3v3"))
		NetDiag.audit("match_over", {"mode": _mode_id(), "reason": "all_left"})
		get_tree().quit(0)


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
		_sync_grace_snapshot()
	if _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 3v3 报到超时(%d/%d),退出释放端口" % [_claims.size(), _team_of_role.size()])
			NetDiag.audit("abort", {"mode": ModeDefs.MODE_TEAM, "reason": "report_timeout"})
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
			NetDiag.audit("abort", {"mode": ModeDefs.MODE_ROYALE, "reason": "understaffed_timeout"})
			get_tree().quit(0)
	elif _worker and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 1v1 报到超时(%d/2),退出释放端口" % _claims.size())
			NetDiag.audit("abort", {"mode": ModeDefs.MODE_PVP, "reason": "report_timeout"})
			get_tree().quit(0)
	if _worker and _match_started and _host != null and _host.has_method("is_match_over") and bool(_host.call("is_match_over")):
		_mo_linger += delta
		if _mo_linger > MATCH_OVER_LINGER:
			print("worker: 终局滞留 %.0fs 到点,收场退出(交回房与端口)" % MATCH_OVER_LINGER)
			NetDiag.audit("match_over", {"mode": _mode_id(), "reason": "linger_timeout"})
			get_tree().quit(0)
	else:
		_mo_linger = 0.0

func _on_player_options(caller: int, opts: Dictionary) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_claim_opts[r] = opts
			return

func _on_token_reported(caller: int, token: String) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_tokens[int(r)] = token
			return

func _proto_matches(caller: int, proto: int, stage: String) -> bool:
	if proto == NetCodec.PROTO_VERSION:
		return true
	var msg := "客户端与服务端版本不一致(%s:客户端 v%d / 服务端 v%d)—— 两端必须同一个发布包" % [
			stage, proto, NetCodec.PROTO_VERSION]
	print("worker: %s(peer=%d)" % [msg, caller])
	NetBus.reply(caller, "server_message", msg)
	multiplayer.multiplayer_peer.disconnect_peer(caller)
	return false


func _on_reclaim(caller: int, role: int, token: String, proto: int) -> void:
	if not _proto_matches(caller, proto, "reclaim"):
		return
	var host_ready := _host != null
	var role_in_grace := _grace.has(role)
	var token_ok := ReclaimRules.token_matches(str(_tokens.get(role, "")), token)
	var why := ReclaimRules.reject_reason(_match_started, host_ready, role_in_grace, token_ok)
	if why != "":
		print("worker: 拒绝 reclaim(role=%d,peer=%d):%s" % [role, caller, why])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	_claims[role] = caller
	_host.state.peer_by_role[role] = caller
	var src := PacketInputSource.new()
	(_host.state.players[role] as Node2D).set_input_source(src)
	_host.state.input_sources[role] = src
	_host.reset_input_queue(role)
	_host.state._ack_seq[role] = 0
	_host.state._stepped_seq[role] = 0
	_grace.leave(role)
	# 回一条 match_start 让客户端重进对局场景(载荷与首次开局同源);★ 走 NetBus.reply 而不是 rpc_id —— 它是答复 caller 的收口,内部先判活。
	#   这个窗口可达:客户端发完 reclaim_role 是等这条应答,被踢/链路断时下一拍会 _retry_connect() → NetBus.stop(),那个 stop 与本次应答可能挤在同一次 poll,ENet 当场把通道数清零 ⇒ 不判活必打 max channels: 0。
	var sp: Vector2i = _host.role_spawns().get(role, Vector2i(-1, -1)) \
			if _host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.reply(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if _host.has_method("_broadcast_round_state"):
		_sync_grace_snapshot()
		_host._broadcast_round_state()
	print("worker: role %d 重连成功(peer=%d)" % [role, caller])

# 进场拉取:对局场景建好后主动要一次昵称/色相/生效选项/出生点/role 集合;★ 它取代原先服务器推三载荷那条路径(同一次 poll 里推 4 条,而那一刻新场景的订阅方还不存在 → 静默丢失)。
func _on_match_sync(caller: int) -> void:
	var role := 0
	for r in _claims:
		if _claims[r] == caller:
			role = int(r)
			break
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 收到 match_sync: caller=%d role=%d _claims.has(caller)=%s _claims 键=%s 值=%s is_peer_live(caller)=%s role_claimed 已连=%s" % [
				caller, role, str(_claims.has(caller)), str(_claims.keys()), str(_claims.values()),
				str(NetBus.is_peer_live(caller)),
				str(NetBus.role_claimed.is_connected(_on_role_claimed))])
	if role == 0:
		# 报到可能早于 claim 归档:按 peer 排队,claim 成功/宿主建好后重试(静默丢掉 ⇒ 该端整局没队伍表/出生点)。
		if not _pending_match_sync.has(caller):
			_pending_match_sync.append(caller)
		return
	if _host == null:
		if not _pending_match_sync.has(caller):
			_pending_match_sync.append(caller)
		return
	if _host != null and _host.has_method("mark_client_ready"):
		_host.mark_client_ready(role)
	var spawns := {}
	# 地面武器必须随这条拉取一并给,不走 weapon_spawned 推送:推送会撞上客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失那类事故。
	var ground: Array = []
	if _host != null and _host.has_method("ground_weapons_payload"):
		ground = _host.ground_weapons_payload()
	if _host != null and _host.has_method("role_spawns"):
		spawns = _host.role_spawns()
	else:
		# 理论上到不了(match_start 与 _host 赋值在同一帧,报文往返只可能更晚);真到这说明时序变了 —— 不静默,留一条痕。
		push_warning("match_sync: role %d 报到时对局宿主还没建好,spawns 回空" % role)
	var destroyed: Array = []
	if _host != null and _host.has_method("destroyed_cells"):
		destroyed = _host.destroyed_cells()
	var destroyed_subs: Array = []
	if _host != null and _host.has_method("damaged_partial_subs"):
		destroyed_subs = _host.damaged_partial_subs()
	var teams: Dictionary = {}
	if _host != null and _host.has_method("team_map"):
		teams = _host.team_map()
	if not NetBus.is_peer_live(caller):
		return
	var data := {
		"names": _claim_names,
		"options": _claim_opts.get(1, {}),
		"roles": _role_set,
		"spawns": spawns,
		"ground_weapons": ground,
	}
	if not destroyed.is_empty():
		data["destroyed"] = destroyed
	if not destroyed_subs.is_empty():
		data["destroyed_subs"] = destroyed_subs
	if not teams.is_empty():
		data["teams"] = teams
	_pending_match_sync.erase(caller)
	var _rpc_err := NetBus.rpc_id(caller, "match_sync_data", data)
	if OS.get_cmdline_user_args().has("--matchsync-diag"):
		print("[matchsync-diag] 已发 match_sync_data → caller=%d data 键=%s rpc_id 返回=%d 在线 peers=%s" % [
				caller, str(data.keys()), _rpc_err, str(multiplayer.get_peers())])


func _on_suicide_request(caller: int) -> void:
	if not (_royale or _team_mode) or _host == null:
		return
	for r in _claims:
		if _claims[r] == caller:
			if _host.has_method("request_suicide_role"):
				_host.request_suicide_role(int(r))
			return

func _on_role_claimed(caller: int, role: int, player_name: String, proto: int) -> void:
	if not _proto_matches(caller, proto, "claim"):
		return
	if _host != null or _match_started \
			or not _role_set.has(role) \
			or (_claims.has(role) and _claims[role] != caller):
		print("worker: 拒绝串线连接 peer=%d(role=%d)" % [caller, role])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if _claims.has(role):
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	if _pending_match_sync.has(caller):
		_retry_pending_match_sync()
	if _team_mode:
		print("worker: 3v3 角色 %d = peer %d (%d/%d 人)" % [role, caller,
				_claims.size(), _team_of_role.size()])
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

func _retry_pending_match_sync() -> void:
	for pending_caller in _pending_match_sync.duplicate():
		_on_match_sync(int(pending_caller))


func _defer_begin_match() -> void:
	_begin_match.call_deferred()

func _begin_match() -> void:
	if _match_started or _host != null or _claims.size() + _ai_roles.size() < 2:
		return
	if _team_mode and _claims.size() < _team_of_role.size():
		print("worker: 3v3 帧末复核未满员(%d/%d),不开局 —— 交 30s 超时梯"
				% [_claims.size(), _team_of_role.size()])
		return
	_match_started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	var match_map := MapCatalog.resolve_pvp_map(str(_claim_opts.get(1, {}).get("map", "")))
	if match_map == "":
		match_map = MatchBootstrap.PVP_MAP
	NetDiag.audit("match_begin", {"mode": _mode_id(), "map": match_map,
			"players": _claims.size(), "ai": _ai_roles.size()})
	if _team_mode:
		_host = TeamHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _team_of_role)
	elif _royale:
		_host = RoyaleHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	else:
		_host = MatchBootstrap.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	add_child(_host)
	for ai_r in _ai_roles:
		_claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	if _royale and _host.has_method("set_display_names"):
		_host.set_display_names(_claim_names)
	_retry_pending_match_sync()
	var mode_note := ""
	if _royale:
		mode_note = "(大乱斗 %d 人,其中 AI %d)" % [_claims.size() + _ai_roles.size(), _ai_roles.size()]
	elif _team_mode:
		mode_note = "(3v3 %d 人,队伍 %s)" % [_claims.size(), str(_team_of_role)]
	print("worker: 对局开始%s" % mode_note)

func _on_peer_left(peer_id: int) -> void:
	var is_participant := _claims.values().has(peer_id)
	if _host != null:
		if not is_participant:
			return
		if _host_match_over():
			var mo_role := _role_of_peer(peer_id)
			if mo_role == 0:
				return
			_claims.erase(mo_role)
			if MatchExitRules.after_peer_left(true, _claims.size()) == MatchExitRules.ACTION_QUIT:
				print("worker: 对局已结束且全员离开 —— 收场退出(交回房与端口)")
				NetDiag.audit("match_over", {"mode": _mode_id(), "reason": "all_left_after_match"})
				get_tree().quit(0)
			return
		if _royale or _team_mode:
			var role := _role_of_peer(peer_id)
			if role == 0:
				return
			_claims.erase(role)
			_enter_grace(role)
			if _claims.is_empty():
				print("worker: 全员离开,进宽限等待重连")
			else:
				print("worker: 玩家掉线进宽限(剩 %d 人在线)" % _claims.size())
			return
		var role1 := _role_of_peer(peer_id)
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
			NetDiag.audit("abort", {"mode": ModeDefs.MODE_PVP, "reason": "claim_left"})
			get_tree().quit(0)


func _role_of_peer(peer_id: int) -> int:
	for r in _claims:
		if _claims[r] == peer_id:
			return int(r)
	return 0


func _host_match_over() -> bool:
	return _host != null and is_instance_valid(_host) and _host.has_method("is_match_over") \
			and bool(_host.call("is_match_over"))


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST or _worker or _stop_logged:
		return
	_stop_lobby("close_request")
	get_tree().quit()


func _exit_tree() -> void:
	if _worker or _stop_logged:
		return
	_stop_lobby("quit")


func _stop_lobby(reason: String) -> void:
	if _stop_logged:
		return
	_stop_logged = true
	var had := 0
	if _room_manager != null and _room_manager.lobby != null:
		var lobby := _room_manager.lobby
		for table in [lobby.rooms, lobby.royale_rooms, lobby.team_rooms]:
			var shot: Dictionary = (table as Dictionary).duplicate()
			for code in shot:
				had += 1
				lobby.teardown_room(shot[code], LobbyRooms.TEARDOWN_KILL, "", false, "lobby_shutdown")
	NetDiag.audit("lobby_stop", {"reason": reason, "rooms_left": had})

func _mode_id() -> String:
	if _royale:
		return ModeDefs.MODE_ROYALE
	if _team_mode:
		return ModeDefs.MODE_TEAM
	return ModeDefs.MODE_PVP
