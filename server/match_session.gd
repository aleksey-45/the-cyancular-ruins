class_name MatchSession
extends Node

# 对局会话管理器 MatchSession：
# 统一管理单场 PvP 对局（1v1、大乱斗、3v3）的生命周期与网络交互。
#
# 架构设计说明：
# 1. 单进程单端口架构：
#    对局不再作为独立的子进程运行，而是作为大厅进程中的 MatchSession 子节点挂载。
#    避免了子进程独立端口无法穿透 NAT/隧道端口映射的问题；客户端在整个对局过程中复用同一 ENet 连接。
# 2. 开局名册 roster 准入校验：
#    在单端口模式下，所有客户端均向同一端口发送 RPC。本类在初始化时接收参与对局的 peer 名册，
#    非名册内的客户端发送角色认领请求时将被直接拦截并断开，防止跨房间未授权连接与非法占位。
# 3. 确定性生命周期：
#    - 创建：由 RoomManager._open_match 实例化并添加至场景树（进入场景树时订阅对局相关 RPC）。
#    - 终止：对局结束时调用 _finish()，触发 finished 信号通知 RoomManager 注销重连凭据并回收房间，
#      随后安全释放本节点。服务端大厅进程持续运行，不退出进程。
# 4. 统一模式与参数校验：
#    提供静态方法 validate() 统一校验模式、角色集合与队伍分配，供 RoomManager 开局与命令行启动共同调用。

signal finished(session)

enum Mode { DUEL, ROYALE, TEAM }

var mode := Mode.DUEL
var room_code := ""
var match_id := 0
var roster: Array[int] = []        # 本局参与对局的客户端 peer_id 列表
var _done := false


# 参数合法性自检（供 RoomManager 开局与命令行启动独立服务端共用）。
# 返回空字符串表示合法；否则返回具体的错误原因。
static func validate(p_mode: int, roles: Array, teams: Dictionary) -> String:
	if p_mode == Mode.ROYALE and roles.is_empty():
		return "大乱斗缺参战 role 集合(不能从人数推导 —— 编号会留空洞)"
	if p_mode == Mode.TEAM:
		if roles.is_empty() or roles.size() != teams.size():
			return "3v3 的 roles 与 teams 必须等长且非空(%d vs %d)" % [roles.size(), teams.size()]
		for r in roles:
			var t := int(teams.get(int(r), 0))
			if t != 1 and t != 2:
				return "3v3 队号越界(role %d -> %d,只接受 1/2)" % [int(r), t]
	return ""


func _init(p_mode: int, p_room_code: String, p_match_id: int, p_roster: Array,
		p_roles: Array, p_ai: Array = [], p_teams: Dictionary = {}) -> void:
	mode = p_mode
	room_code = p_room_code
	match_id = p_match_id
	for r in p_roster:
		roster.append(int(r))
	_royale = p_mode == Mode.ROYALE
	_team_mode = p_mode == Mode.TEAM
	# 参战角色集合包含由 AI 接管的角色编号；_ai_roles 用于无需等待真人认领的角色
	_role_set.clear()
	for r in p_roles:
		_role_set.append(int(r))
	_ai_roles = p_ai.duplicate()
	# 队伍映射表：键为角色编号，值为对应队伍（1 或 2）
	_team_of_role = p_teams.duplicate()
	# 标记当前节点处于对局托管状态
	_worker = true


# 订阅对局网络 RPC 信号。推迟至 _enter_tree 时订阅，避免在节点进入场景树前误接收其他信号。
func _enter_tree() -> void:
	NetBus.role_claimed.connect(_on_role_claimed)
	NetBusExt.player_options_received.connect(_on_player_options)
	NetBus.peer_left.connect(_on_peer_left)
	NetBusExt.suicide_requested.connect(_on_suicide_request)
	NetBus.match_sync_received.connect(_on_match_sync)
	NetBusExt.token_reported.connect(_on_token_reported)
	NetBusExt.reclaim_requested.connect(_on_reclaim)


# 对称退订网络 RPC 信号。确保幂等性（退订前先判断 is_connected）。
func _exit_tree() -> void:
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	if NetBusExt.player_options_received.is_connected(_on_player_options):
		NetBusExt.player_options_received.disconnect(_on_player_options)
	if NetBus.peer_left.is_connected(_on_peer_left):
		NetBus.peer_left.disconnect(_on_peer_left)
	if NetBusExt.suicide_requested.is_connected(_on_suicide_request):
		NetBusExt.suicide_requested.disconnect(_on_suicide_request)
	if NetBus.match_sync_received.is_connected(_on_match_sync):
		NetBus.match_sync_received.disconnect(_on_match_sync)
	if NetBusExt.token_reported.is_connected(_on_token_reported):
		NetBusExt.token_reported.disconnect(_on_token_reported)
	if NetBusExt.reclaim_requested.is_connected(_on_reclaim):
		NetBusExt.reclaim_requested.disconnect(_on_reclaim)


func mode_name() -> String:
	match mode:
		Mode.ROYALE:
			return "大乱斗"
		Mode.TEAM:
			return "3v3"
		_:
			return "1v1"


# 对局正常收尾并退出：释放对局宿主对象、清理局内缓存状态，并触发 finished 信号通知 RoomManager 回收房间。
func _finish() -> void:
	if _done:
		return
	_done = true
	set_process(false)
	if _host != null:
		if is_instance_valid(_host):
			_host.queue_free()
		_host = null
	_claims.clear()
	_claim_names.clear()
	_claim_opts.clear()
	_tokens.clear()
	_grace = GraceWindow.new()
	_grace_check_timer = 0.0
	_match_started = false
	_understaffed_wait = 0.0
	_claim_wait = 0.0
	print("%s %s 对局结束" % [mode_name(), room_code])
	finished.emit(self)

# ── 本局私有状态 ──
var _host: Node = null
var _claims: Dictionary = {}        # role(int) -> peer_id(int)
var _claim_names: Dictionary = {}   # role(int) -> 玩家昵称
var _claim_opts: Dictionary = {}    # role(int) -> 玩家客户端选项（偏好设置、颜色等）
var _wait_timer := 0.0

# ── 大乱斗模式状态 ──
var _royale := false
var _role_set: Array[int] = []      # 本局全部参战角色编号（含真人与 AI）
var _ai_roles: Array = []           # AI 补位角色列表（由服务端 AI 控制，无需等待 claim）
var _claim_wait := 0.0
var _understaffed_wait := 0.0       # 人数不足等待计时器（超时则终止对局并释放资源）

# ── 3v3 模式状态 ──
var _team_mode := false
var _team_of_role: Dictionary = {}  # role(int) -> 队号(1/2)
var _team_teams_raw: Array[int] = []

# ── 节点运行门控 ──
# 标记当前节点是否作为对局执行节点运行
var _worker := false
var _match_started := false

# ── 断线宽限期管理 ──
# 掉线角色的状态保留在 GraceWindow 中；在宽限期内可通过 reclaim_role 恢复，超时则按模式规则结算。
var _grace := GraceWindow.new()
var _grace_check_timer := 0.0
var _tokens: Dictionary = {}        # role(int) -> token(String)，由客户端经 report_token 上报


# 计算需要真人认领的角色数量（总参战角色数减去 AI 补位数量）
func _human_role_count() -> int:
	return count_humans(_role_set, _ai_roles)


# 静态辅助方法：计算真人角色数量（供单局独立服务端在启动阶段调用）
static func count_humans(role_set: Array, ai_roles: Array) -> int:
	var n := 0
	for r in role_set:
		if not ai_roles.has(int(r)):
			n += 1
	return n


# 将宽限期状态快照同步至对局宿主对象（供 round_state 广播载荷使用）
func _sync_grace_snapshot() -> void:
	if _host != null:
		_host.grace_snapshot = _grace.remaining(Time.get_ticks_msec())


# 将角色置入断线宽限期：重置其输入源状态并清空未消费输入，避免掉线后沿用最后一帧的操作指令
func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if _host != null:
		var src = _host.input_sources.get(role, null)
		if src != null and src.has_method("reset_state"):
			src.reset_state()
		# 清空待消费输入队列，确保掉线瞬间缓存的操作不会在下一物理帧被意外执行
		_host._pending_input[role] = []
		# 记录角色断开时的局号，作为 ACS 统计的分母基准
		_host.note_disconnect_round(role)
		_host.peer_by_role.erase(role)
		if _host.has_method("_broadcast_round_state"):
			_sync_grace_snapshot()
			_host._broadcast_round_state()


# 处理已过期的宽限期角色：根据游戏模式执行移出对局或对局结束判定
func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		_sync_grace_snapshot()
		if GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE:
			# 大乱斗 / 3v3 模式：移出离开的角色，其他玩家继续对局；3v3 整队离开时由 TeamHost 判定终局
			if _host != null and _host.has_method("mark_disconnected"):
				_host.mark_disconnected(role)
		else:
			# 1v1 模式：对手在宽限期内未重连，通知存活玩家后终止本局
			_notify_opponent_left()
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			_finish()
	# 大乱斗 / 3v3 模式：若所有玩家均已离开且宽限期已排空，正常终止对局会话
	if (_royale or _team_mode) and _match_started and _claims.is_empty() and _grace.size() == 0:
		print("worker: 全体玩家已离开，%s对局结束" % ("大乱斗" if _royale else "3v3"))
		_finish()


# 1v1 模式下在对局终止前通知在线玩家对手已离开
func _notify_opponent_left() -> void:
	for role in _claims:
		var peer := int(_claims[role])
		if NetBus.reply(peer, "opponent_left"):
			print("worker: 1v1 对局终止前通知在线玩家(opponent_left, role=%d peer=%d)" % [int(role), peer])


func _process(delta: float) -> void:
	# 宽限期轮询检查（每秒执行一次）
	_grace_check_timer += delta
	if _grace_check_timer >= 1.0:
		_grace_check_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
		_sync_grace_snapshot()
	# 3v3 模式：必须满员才开局；30 秒内未满员则超时退出并释放资源
	if _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 3v3 角色认领超时(%d/%d)，对局结束并释放资源" % [_claims.size(), _team_of_role.size()])
			_finish()
	# 大乱斗模式：达到最小人数（>=2）但 20 秒仍未收齐所有玩家，按已到人数开局
	elif _royale and not _match_started and _host == null and _claims.size() >= 2:
		_claim_wait += delta
		if _claim_wait > 20.0:
			print("worker: 角色认领超时(%d/%d)，按当前已连接人数开启对局" % [_claims.size(), _human_role_count()])
			_begin_match()
	# 大乱斗模式：可用玩家少于 2 人持续 10 秒以上，超时退出并释放资源
	elif _royale and not _match_started and _host == null and _claims.size() < 2:
		_understaffed_wait += delta
		if _understaffed_wait > 10.0:
			print("worker: 在线玩家 %d/2，等待超时退出并释放端口" % _claims.size())
			_finish()
	# 1v1 模式：30 秒内未收齐两位玩家认领角色，超时退出并释放资源
	elif _worker and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 1v1 报到超时(%d/2)，退出并释放端口" % _claims.size())
			_finish()

# 玩家选项上报回调（颜色、偏好等）
func _on_player_options(caller: int, opts: Dictionary) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_claim_opts[r] = opts
			return

# 客户端角色认领后上报的重连一次性令牌
func _on_token_reported(caller: int, token: String) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_tokens[int(r)] = token
			return

# 宽限期内重新认领角色（断线重连）：
# 校验对局是否已开始、角色是否处于宽限期内以及重连令牌是否一致；不满足则断开连接。
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
	# 校验通过：重置 peer_id 映射与输入源，保留场上现存的角色实体节点
	_claims[role] = caller
	_host.peer_by_role[role] = caller
	var src := PacketInputSource.new()
	(_host.players[role] as Node2D).set_input_source(src)
	_host.input_sources[role] = src
	_host._pending_input[role] = []
	_host._ack_seq[role] = 0
	_grace.leave(role)
	# 向客户端回传 match_start 触发重进对局场景
	var sp: Vector2i = _host.role_spawns().get(role, Vector2i(-1, -1)) \
			if _host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.reply(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if _host.has_method("_broadcast_round_state"):
		_sync_grace_snapshot()
		_host._broadcast_round_state()
	print("worker: 角色 %d 重连成功(peer=%d)" % [role, caller])

# 客户端进场数据拉取：对局场景初始化完成后向服务端主动请求昵称、色相、选项、出生点及瓦片破坏状态。
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
		return
	var spawns := {}
	var ground: Array = []
	if _host != null and _host.has_method("ground_weapons_payload"):
		ground = _host.ground_weapons_payload()
	if _host != null and _host.has_method("role_spawns"):
		spawns = _host.role_spawns()
	else:
		push_warning("match_sync: role %d 报到时对局宿主还没建好,spawns 回空" % role)
	var destroyed: Array = []
	if _host != null and _host.has_method("destroyed_cells"):
		destroyed = _host.destroyed_cells()
	var teams: Dictionary = {}
	if _host != null and _host.has_method("team_map"):
		teams = _host.team_map()
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


# 玩家自杀脱困请求处理（大乱斗 / 3v3 模式）
func _on_suicide_request(caller: int) -> void:
	if not (_royale or _team_mode) or _host == null:
		return
	for r in _claims:
		if _claims[r] == caller:
			if _host.has_method("request_suicide_role"):
				_host.request_suicide_role(int(r))
			return

func _on_role_claimed(caller: int, role: int, player_name: String) -> void:
	# 客户端准入白名单与权限校验：
	# 对局已开始、角色不在本局参战集合内、调用者不在本局名册中，或该角色已被其他 peer 认领，均直接拒绝并断开。
	if _host != null or _match_started \
			or ((_royale or _team_mode) and not _role_set.has(role)) \
			or (not roster.is_empty() and not roster.has(caller)) \
			or (_claims.has(role) and _claims[role] != caller):
		print("worker: 拒绝未在准入名单中的连接 peer=%d(role=%d)" % [caller, role])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if _claims.has(role):
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	if _team_mode:
		print("worker: 3v3 角色 %d = peer %d (%d/%d 人)" % [role, caller,
				_claims.size(), _team_of_role.size()])
		# 3v3 模式必须全员满员才可开局
		if _claims.size() >= _team_of_role.size():
			_defer_begin_match()
	elif _royale:
		print("worker: 大乱斗角色 %d = peer %d (%d/%d 人,另有 %d 个 AI)" % [role, caller,
				_claims.size(), _human_role_count(), _ai_roles.size()])
		# 大乱斗模式收齐全部真人玩家后开局（其余空缺由 AI 补位）
		if _claims.size() >= _human_role_count():
			_defer_begin_match()
	else:
		print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
		if _claims.size() >= 2 - _ai_roles.size():
			_defer_begin_match()

# 延迟至帧末开局，确保同一网络轮询中到达的玩家选项（player_options）已全部归档完毕
func _defer_begin_match() -> void:
	call_deferred("_begin_match")

func _begin_match() -> void:
	if _match_started or _host != null or _claims.size() + _ai_roles.size() < 2:
		return
	# 3v3 模式在帧末再次复核满员状态，若期间有玩家掉线则交由超时计时器处理
	if _team_mode and _claims.size() < _team_of_role.size():
		print("worker: 3v3 帧末复核未满员(%d/%d)，暂不开局，转入 30s 超时判定流程"
				% [_claims.size(), _team_of_role.size()])
		return
	_match_started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	# 校验房主选择的地图路径合法性，若不合法则回退至默认 PvP 地图
	var match_map := MapCatalog.resolve_pvp_map(str(_claim_opts.get(1, {}).get("map", "")))
	if match_map == "":
		match_map = MatchBootstrap.PVP_MAP
	if _team_mode:
		_host = TeamHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _team_of_role)
	elif _royale:
		_host = RoyaleHost.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	else:
		_host = MatchBootstrap.start_on(_claims, match_map, _claim_opts.get(1, {}), _ai_roles)
	add_child(_host)
	# 为 AI 补位角色分配展示昵称
	for ai_r in _ai_roles:
		_claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	if _royale and _host.has_method("set_display_names"):
		_host.set_display_names(_claim_names)
	var mode_note := ""
	if _royale:
		mode_note = "(大乱斗 %d 人,其中 AI %d)" % [_claims.size() + _ai_roles.size(), _ai_roles.size()]
	elif _team_mode:
		mode_note = "(3v3 %d 人,队伍 %s)" % [_claims.size(), str(_team_of_role)]
	print("worker: 对局开始%s" % mode_note)

# 各角色自选的角色颜色（色相旋转度数，缺省为 0.0）
func _claim_hues() -> Dictionary:
	var hues := {}
	for r in _claim_opts:
		hues[r] = float(_claim_opts[r].get("hue", 0.0)) if typeof(_claim_opts[r]) == TYPE_DICTIONARY else 0.0
	return hues

func _on_peer_left(peer_id: int) -> void:
	var is_participant := _claims.values().has(peer_id)
	if _host != null:
		if not is_participant:
			return
		if _royale or _team_mode:
			# 大乱斗 / 3v3 模式：已开局玩家掉线后先置入宽限期保留角色实体，供断线重连恢复
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
				print("worker: 全员离开,进宽限等待重连")
			else:
				print("worker: 玩家掉线进宽限(剩 %d 人在线)" % _claims.size())
			return
		# 1v1 模式：一方掉线进入宽限期等待重连，不再直接终止进程
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
			# 尚未开局时有玩家断开：从认领表中移除并继续等待其他玩家
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			_claims.erase(role)
			_claim_names.erase(role)
			_claim_opts.erase(role)
			print("worker: 已认领角色 %d 掉线，继续等待其余玩家(%d/%d)" % [role, _claims.size(), _human_role_count()])
			if _claims.is_empty():
				_claim_wait = 0.0
		else:
			# 1v1 模式开局前已有玩家断开，终止本局会话
			print("worker: 已认领角色掉线，对局终止")
			_finish()
