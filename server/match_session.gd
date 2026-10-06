class_name MatchSession
extends Node

# **一局对局的编排**(替代原来的 `--worker` 子进程)。
#
# ── 为什么是"一局一个节点",而不是把这些状态挂在大厅上 ──
# 原先每局是一个独立进程,于是 `_claims` / `_host` / `_grace` 这些"本局"的状态写在进程全局
# 是**安全**的 —— 进程里只有这一局。改成单进程之后它们不再是全局量:同一个服务端进程里
# 可能并存多个房(1v1 一间、大乱斗一间),而它们共用**同一个 UDP 端口**、靠 peer id 区分。
# 把 `_claims` 挂在大厅上 = 两间房的玩家互相顶掉对方的 role。故本类的所有字段都是**每局私有**。
#
# 单端口下,任何连上来的 peer 均可能发送 `claim_role`。在单进程架构下,
# 需进行显式校验:不在本局名册内的连接一律拒绝并断开(防止跨房间请求混淆)。
#
# ── 生命周期 ──
# 建:RoomManager 在开局那一刻 `add_child`(此时才订阅 RPC —— 早订阅会收到别局的包)。
# 终:`_finish()` 发 `finished` 信号 → RoomManager 拆房 + `queue_free`。
# ★ 服务端**不再退进程**:大厅还要继续服务,所以"这局没了"必须由本类**主动**告诉客户端
#   (那条 `opponent_left`)。靠"服务器断开"通知的年代随 worker 一起结束了。

signal finished(session)

enum Mode { DUEL, ROYALE, TEAM }

# 开局前可用玩家不足(大乱斗 <2)的容忍时长;3v3 未满员同理(超时即结束,绝不降级开局)。
const ROYALE_UNDERSTAFFED_WAIT := 10.0
const TEAM_UNDERSTAFFED_WAIT := 30.0
# 大乱斗"有人报到但收不齐"的上限,到点按已到人数(≥2)开局。
const ROYALE_CLAIM_WAIT := 20.0

var mode := Mode.DUEL
var room_code := ""
var match_id := 0
var roster: Array[int] = []        # 本局参与的 peer(不在名册里的 claim 一律踢)
var role_set: Array[int] = []      # 本局全部参战 role(含 AI 补位号)
var ai_roles: Array = []
var team_of_role: Dictionary = {}  # role(int) -> 队号(1/2);3v3 专用

var host: Node = null              # MatchHost / RoyaleHost / TeamHost
var started := false
var claims: Dictionary = {}        # role(int) -> peer_id
var claim_names: Dictionary = {}   # role(int) -> 昵称
var claim_opts: Dictionary = {}    # role(int) -> 本端选项(颜色/规则偏好)
var tokens: Dictionary = {}        # role(int) -> token(String)

var _grace := GraceWindow.new()
var _grace_timer := 0.0
var _claim_wait := 0.0
var _understaffed_wait := 0.0
var _done := false


func _init(p_mode: int, p_room_code: String, p_match_id: int, p_roster: Array,
		p_roles: Array, p_ai: Array = [], p_teams: Dictionary = {}) -> void:
	mode = p_mode
	room_code = p_room_code
	match_id = p_match_id
	for r in p_roster:
		roster.append(int(r))
	for r in p_roles:
		role_set.append(int(r))
	ai_roles = p_ai.duplicate()
	team_of_role = p_teams.duplicate()


func _enter_tree() -> void:
	NetBus.role_claimed.connect(_on_role_claimed)
	NetBusExt.player_options_received.connect(_on_player_options)
	NetBus.peer_left.connect(_on_peer_left)
	NetBusExt.suicide_requested.connect(_on_suicide_request)
	NetBus.match_sync_received.connect(_on_match_sync)
	NetBusExt.token_reported.connect(_on_token_reported)
	NetBusExt.reclaim_requested.connect(_on_reclaim)


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


# 需要**真人** claim 的 role 数 = 参战集合 − AI 补位号。收齐判据与提示都用它。
func human_role_count() -> int:
	var n := 0
	for r in role_set:
		if not ai_roles.has(int(r)):
			n += 1
	return n


# ── 主循环:宽限期轮询 + 三条开局/收场超时梯 ──
func _process(delta: float) -> void:
	if _done:
		return
	_grace_timer += delta
	if _grace_timer >= 1.0:
		_grace_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
		if _done:
			return
	# 3v3:满 6 人才开,人没到齐就干等没有意义 → 超时结束(不降级开局)。
	# ★ 与 --royale 那条"20s 按已到人数开局"是**相反**的决定:那边是自由混战(N 人可打),
	#   这边两队人数必须相等才成立。别顺手把两条统一。
	if mode == Mode.TEAM and not started and host == null:
		_understaffed_wait += delta
		if _understaffed_wait > TEAM_UNDERSTAFFED_WAIT:
			print("对局 %s:3v3 报到超时(%d/%d),结束" % [room_code, claims.size(),
					team_of_role.size()])
			_finish()
	# 大乱斗:有人报到但收不齐 → 按已到人数(≥2)直接开局(缺席角色不入局)
	elif mode == Mode.ROYALE and not started and host == null and claims.size() >= 2:
		_claim_wait += delta
		if _claim_wait > ROYALE_CLAIM_WAIT:
			print("对局 %s:报到超时(%d/%d),按已到人数开局" % [room_code, claims.size(),
					human_role_count()])
			_begin_match()
	# 大乱斗:可用玩家不足 2 人(开局前全部掉线)→ 结束这一局
	elif mode == Mode.ROYALE and not started and host == null and claims.size() < 2:
		_understaffed_wait += delta
		if _understaffed_wait > ROYALE_UNDERSTAFFED_WAIT:
			print("对局 %s:可用玩家 %d/2,超时结束" % [room_code, claims.size()])
			_finish()


# ── 收场 ──

# 结束这一局:**通知还在的人** → 释放宿主 → 发 finished(RoomManager 据此拆房)。
# ★ 只发一次(`_done` 闸):本函数有多个调用点(宽限到期 / 报到超时 / 全员走光),重复发
#   会让大厅把同一间房拆两遍。
func _finish() -> void:
	if _done:
		return
	_done = true
	for r in claims:
		var peer_id := int(claims[r])
		if NetBus.is_peer_live(peer_id):
			NetBus.reply(peer_id, "opponent_left")
	if is_instance_valid(host):
		host.queue_free()
	host = null
	print("对局 %s 结束(%s)" % [room_code, mode_name()])
	finished.emit(self)


## 外部(大厅)要求收掉这一局:僵尸清扫走这里。
## ★ 语义与 `_finish()` 完全相同,只是**从外面叫**它 —— 谁都可以叫,重复叫什么都不做
##   (幂等闸在 `_done`)。大厅的拆除可能由多条梯子到达,不幂等的话同一间房会被拆两遍。
func abort() -> void:
	_finish()


# ── claim / 选项 / 令牌 ──

func _on_role_claimed(caller: int, role: int, player_name: String) -> void:
	# 会话隔离与身份合法性校验。四项判定条件缺一不可:
	#   ① 已经开局 —— 迟到的 claim 没有收件人(下面会 disconnect 本 handler),这里兜住帧内窗口;
	#   ② role 不在本局参战集合 —— 放进来会让"收齐"提前满足,而宿主那侧没有它的摆位;
	#   ③ 名册外的 caller —— **单端口新增的那一款**:没有端口/进程隔离之后,别的房的玩家
	#      也连在同一个服务端上,不判就会把他的 role 写进这一局的表;
	#   ④ 该 role 已被别的 peer 占 —— 同一个 role 双份占用。
	if _done or host != null or started \
			or not role_set.has(role) or not roster.has(caller) \
			or (claims.has(role) and claims[role] != caller):
		print("对局 %s:拒绝串线连接 peer=%d(role=%d)" % [room_code, caller, role])
		if multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if claims.has(role):
		return
	claims[role] = caller
	claim_names[role] = player_name
	print("对局 %s:%s角色 %d = peer %d(%d/%d 人)" % [room_code, mode_name(), role, caller,
			claims.size(), human_role_count()])
	if mode == Mode.TEAM:
		# ★ 满员才开:用户裁定「满 6 人才开」,没有降级开局这一档。
		# ★ 判据取 `team_of_role.size()` 而**不是** `role_set.size()`:`team_of_role` 按 role
		#   去重,而 `role_set` 是逐 token 列表 —— 拿后者当满员界可能**永远到不了**。
		if claims.size() >= team_of_role.size():
			_defer_begin_match()
	elif mode == Mode.ROYALE:
		if claims.size() >= human_role_count():
			_defer_begin_match()
	else:
		if claims.size() >= 2 - ai_roles.size():
			_defer_begin_match()


# 本端选项(颜色等)经扩展节点上报,可能先于/晚于 claim 到达,按 caller 归档
func _on_player_options(caller: int, opts: Dictionary) -> void:
	for r in claims:
		if claims[r] == caller:
			claim_opts[r] = opts
			return


# 客户端 claim 之后立刻报来的一次性令牌(claim 与它同一次 poll 到达)。按 caller 反查 role 归档。
# ★ 只归档,不在这里校验 —— 校验发生在宽限期里的 reclaim_role(那时才有"该不该放行"的问题)。
func _on_token_reported(caller: int, token: String) -> void:
	for r in claims:
		if claims[r] == caller:
			tokens[int(r)] = token
			return


# 开局**延到帧末**再执行:每个客户端都是「claim_role 紧接 player_options」两条包(同一帧 flush →
# 同一次 poll 到达),而收齐判据由**最后一个** claim 满足 → 同步开局会在同一次 poll 里抢先建局,
# 那个客户端的本端选项(角色颜色)还没归档;它恰是 role1 时,整局规则项(禁武器等)也拿不到。
# 延到帧末 = 同一次 poll 内的 player_options 先全部归档,再取快照建局。
func _defer_begin_match() -> void:
	call_deferred("_begin_match")


func _begin_match() -> void:
	if _done or started or host != null:
		return
	if claims.size() + ai_roles.size() < 2:
		return
	# ★ 3v3:帧末再核一次满员。收齐判据由**最后一个** claim 满足 → 开局延到帧末,而这一帧里
	#   claim 集可能**缩小**(有人刚 claim 完就掉线)。不核的话 5 个人也能开,而本模式的纪律是
	#   **满员才开、不降级** —— 3v3 少一个人 = 一边 3 打 2,整局的胜负从第一秒就是假的。
	# ★ 位置必须在 `started = true` 之前:早退不置真,3v3 超时梯照旧从建局起算。
	if mode == Mode.TEAM and claims.size() < team_of_role.size():
		print("对局 %s:3v3 帧末复核未满员(%d/%d),不开局" % [room_code, claims.size(),
				team_of_role.size()])
		return
	started = true
	if NetBus.role_claimed.is_connected(_on_role_claimed):
		NetBus.role_claimed.disconnect(_on_role_claimed)
	# ★ 房主选的地图(KH 线 B14 的地图选择 UI,随 player_options 上报):**客户端路径不可信** →
	#   过 `MapCatalog.resolve_pvp_map` 校验(只认仓内 `res://maps/*.cyrm`、拒绝 `..`、
	#   必须有双出生点)。不合规一律回落默认 PvP 图 —— 绝不让"上报了一个本机才有的 exe 旁地图"
	#   变成一端加载失败。★ 2026-09-30 合并两线时从 KH 的 `server_main._begin_match` 搬到这里
	#   (本仓的开局点已随单进程化移进 MatchSession,那边整段删除)。
	var match_map := MapCatalog.resolve_pvp_map(str(claim_opts.get(1, {}).get("map", "")))
	if match_map == "":
		match_map = MatchBootstrap.PVP_MAP
	if mode == Mode.TEAM:
		host = TeamHost.start_on(claims, match_map, claim_opts.get(1, {}), team_of_role)
	elif mode == Mode.ROYALE:
		host = RoyaleHost.start_on(claims, match_map, claim_opts.get(1, {}), ai_roles)
	else:
		# 服务器权威规则项以房主(role1)选项为准(经 NetBusExt 上报;缺省=全默认)
		host = MatchBootstrap.start_on(claims, match_map, claim_opts.get(1, {}), ai_roles)
	add_child(host)
	# AI 补位昵称:唯一名 + -computer 后缀(排行榜/头顶显示,地位与真人等同)
	for ai_r in ai_roles:
		claim_names[int(ai_r)] = "电脑玩家%d-computer" % int(ai_r)
	if mode == Mode.ROYALE and host.has_method("set_display_names"):
		host.set_display_names(claim_names)
	var note := ""
	if mode == Mode.ROYALE:
		note = "(大乱斗 %d 人,其中 AI %d)" % [claims.size() + ai_roles.size(), ai_roles.size()]
	elif mode == Mode.TEAM:
		note = "(3v3 %d 人,队伍 %s)" % [claims.size(), str(team_of_role)]
	print("对局 %s 开始%s" % [room_code, note])


# 各 role 自选的角色颜色(色相旋转度数;缺省 0)
func claim_hues() -> Dictionary:
	var hues := {}
	for r in claim_opts:
		var o = claim_opts[r]
		hues[r] = float(o.get("hue", 0.0)) if typeof(o) == TYPE_DICTIONARY else 0.0
	return hues


# ── 掉线宽限与重连 ──

# 把一个 role 放进宽限期。★ 必须**置空它的输入源 + 清掉它的待消费输入队列**(两件缺一不可):
# `PacketInputSource` 在队列空时沿用上一包(held),不置空的话掉线者的身体会保持他断开前最后一帧
# 的输入 —— 一直朝那个方向跑、或一直开枪。
func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if host == null:
		return
	var src = host.input_sources.get(role, null)
	if src != null and src.has_method("reset_state"):
		src.reset_state()
	# ★★ 清输入源**不够,必须连队列一起清**:掉线瞬间队列里可能还压着一条**已经到达**的包,
	#   而 `apply_packet()` 是**整体覆盖** `_held`/`_axis` —— 那条包会在 `reset_state()` **之后**
	#   被执行,把 `_held` 原样写回去;之后队列空了,而 `clear_edges()` **不含 `_held`**
	#   → 掉线前按着的键被重新武装、并保持整个宽限期。这一行是"掉线者的身体留在场上不动"的全部内容。
	host._pending_input[role] = []
	host.peer_by_role.erase(role)
	if host.has_method("_broadcast_round_state"):
		host._broadcast_round_state()


func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		# ★ 到点做什么 = **纯分派**(`GraceWindow.expire_action`),三个模式的答案由
		#   tests/grace_window_smoke 逐个钉住 —— 别在这里再写一遍 if/else。
		if GraceWindow.expire_action(mode == Mode.ROYALE, mode == Mode.TEAM) == GraceWindow.ACTION_REMOVE:
			# 大乱斗 / 3v3:移出对局(身体销毁),其余人继续打;整队走光才终局(3v3 在 TeamHost 里判)
			if host != null and host.has_method("mark_disconnected"):
				host.mark_disconnected(role)
		else:
			# 1v1:宽限内没回来 → 收场(原行为,只是从"退进程"变成"结束这一局")
			print("对局 %s:1v1 宽限期到,对手未归,对局结束" % room_code)
			_finish()
			return
	# 大乱斗/3v3:全员走光且宽限期已空(一个都没回来)→ 收场。
	# ★★ `started` 这个前置**不能省**:本函数每秒无条件跑,"开机等玩家"同样满足
	#   `claims` 空 + 宽限期空 —— 少了它,一建局就判"全员离开"自杀。
	# ★★ 时间梯的判据同理:只有**开过局**的会话才会因为"人全走光"结束。
	if (mode == Mode.ROYALE or mode == Mode.TEAM) and started \
			and claims.is_empty() and _grace.size() == 0:
		print("对局 %s:全员离开,%s结束" % [room_code, mode_name()])
		_finish()


# 宽限期内重新认领 role(断线重连)。**三条拒绝条件一条都不能少**:
#   ① 没开局 —— 那时走正常 claim_role,不走这里
#   ② 该 role 不在宽限期里 —— 没掉线,或已超时移出(不允许"提前占坑"或"死后回归")
#   ③ token 不匹配 —— 防同网段的人顶替
# 任何一条不满足都**踢连接**:不能让它静默留在局里收快照。
func _on_reclaim(caller: int, role: int, token: String) -> void:
	var why := ""
	if not started or host == null:
		why = "尚未开局"
	elif not _grace.has(role):
		why = "该 role 不在宽限期"
	elif str(tokens.get(role, "")) != token or token == "":
		why = "令牌不匹配"
	if why != "":
		print("对局 %s:拒绝 reclaim(role=%d,peer=%d):%s" % [room_code, role, caller, why])
		if multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	# ── 接受:重绑 peer 与输入源 ──
	# ★ **玩家节点不重建**:身体从未销毁,所以服务端的对局状态一条都不用恢复。
	claims[role] = caller
	host.peer_by_role[role] = caller
	# ★ 换输入源**不是** `PacketInputSource.new(role, caller)` —— 它不收参数。所以要把新源
	#   **挂回那个还活着的玩家节点**,只换表里的引用是不够的(玩家手里仍攥着旧源)。
	# ★ 直取 `players[role]` 依赖 `_expire_graces` 里的次序:只有它会调 `mark_disconnected`
	#   (那里才 `players.erase(role)`),且它**先** `_grace.leave` 再 mark → 判据②恰好挡住
	#   "节点已被 erase"那一档。
	var src := PacketInputSource.new()
	(host.players[role] as Node2D).set_input_source(src)
	host.input_sources[role] = src
	host._pending_input[role] = []
	host._ack_seq[role] = 0      # C2 锚点重协商:客户端 rollback ring 已失
	_grace.leave(role)
	# 回一条 match_start 让客户端重进对局场景(载荷与首次开局同源,不另造一份)。
	# ★ 走 `NetBus.reply` 而不是 `NetBus.rpc_id`:它是本仓"答复 caller"的收口,内部**先判活**
	#   (CLAUDE.md 硬纪律「定向发送前一律先判活」)。这个窗口可达:客户端发完 reclaim_role 之后
	#   是**等**这条应答,只有在连接已不可用时才 stop() —— 那个 stop 与本次应答可能挤在
	#   同一次 poll,ENet 处理 DISCONNECT 时当场把通道数清零。
	var sp: Vector2i = host.role_spawns().get(role, Vector2i(-1, -1)) \
			if host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.reply(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if host.has_method("_broadcast_round_state"):
		host._broadcast_round_state()
	print("对局 %s:role %d 重连成功(peer=%d)" % [room_code, role, caller])


func _on_peer_left(peer_id: int) -> void:
	if _done:
		return
	var is_participant := claims.values().has(peer_id)
	if not is_participant:
		return   # 非本局合法参与者的连接断开不影响正常对局
	var role := 0
	for r in claims:
		if claims[r] == peer_id:
			role = int(r)
			break
	if role == 0:
		return
	if host != null:
		# 单个参与者掉线 = **进入宽限期**(不立刻移出,实体保留在场上),宽限期内可被 reclaim_role
		# 重新认领;超时未回才执行 mark_disconnected 或终局清理。
		# ★ 玩家实体保留在场景中:得分、伤亡、血量、背包、位置、环境破坏与地面装备均保留在运行内存中，
		#   无需复杂的状态重建恢复流程。
		claims.erase(role)
		_enter_grace(role)
		if claims.is_empty():
			# 最后一个真人也走了:仍**先给宽限**(最后一人掉线同样该有机会回来),
			# 到点没人回来才收场 —— 收口在 `_expire_graces`。
			print("对局 %s:全员离开,进宽限等待重连" % room_code)
		else:
			print("对局 %s:玩家掉线进宽限(剩 %d 人在线)" % [room_code, claims.size()])
		return
	# 尚未开局
	if mode == Mode.ROYALE or mode == Mode.TEAM:
		# 从收人表摘除,继续等(大乱斗:超时兜底按已到人数开局;3v3:交给超时梯)
		claims.erase(role)
		claim_names.erase(role)
		claim_opts.erase(role)
		print("对局 %s:报到角色 %d 掉线,继续等待(%d/%d)" % [room_code, role, claims.size(),
				human_role_count()])
		if claims.is_empty():
			_claim_wait = 0.0
	else:
		# 1v1:尚未满员就有 claimed 玩家掉线 → 别占着这一局干等,结束
		print("对局 %s:角色报到后掉线,结束" % room_code)
		_finish()


# ── 对局中的服务 ──

# 自杀脱困(大乱斗 / 3v3):caller → role → 宿主(存活/对局中校验在那边)
# ★★ 闸里**必须有 TEAM**:只认大乱斗时 3v3 会把 `suicide_request` **静默丢掉** —— K 键毫无反应、
#   一个字的日志都没有,而卡死的玩家在三局两胜里只能干等对局被别人打完。
func _on_suicide_request(caller: int) -> void:
	if not (mode == Mode.ROYALE or mode == Mode.TEAM) or host == null:
		return
	for r in claims:
		if claims[r] == caller:
			if host.has_method("request_suicide_role"):
				host.request_suicide_role(int(r))
			return


# 进场拉取:对局场景建好后主动要一次昵称/色相/生效选项/出生点/role 集合。
# ★ 它**取代**原先"服务器推三载荷"那条路径 —— 那次推的根因问题是「推给一个正在切场景的客户端」:
#   服务器在同一次 poll 里连推 4 条,而那一刻新场景的订阅方一个都不存在 → 静默丢失。拉的时序不敏感。
func _on_match_sync(caller: int) -> void:
	var role := 0
	for r in claims:
		if claims[r] == caller:
			role = int(r)
			break
	if role == 0:
		return
	var spawns := {}
	# 地面武器:开局那批**必须随这条拉取一并给**,不走 weapon_spawned 推送 ——
	# 推送会撞上"客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失"那类事故。
	var ground: Array = []
	if host != null and host.has_method("ground_weapons_payload"):
		ground = host.ground_weapons_payload()
	if host != null and host.has_method("role_spawns"):
		spawns = host.role_spawns()
	else:
		# 理论上到不了:客户端要收到 match_start 才会进对局场景,而 match_start 是在建宿主那次
		# 调用里发出的。真到了这里说明时序变了 —— 不静默,留一条痕。
		push_warning("match_sync: role %d 报到时对局宿主还没建好,spawns 回空" % role)
	# 掉线窗口内被拆的墙:与基线不同才带(**空数组不带该键**,避免每局固定多几 KB)。
	var destroyed: Array = []
	if host != null and host.has_method("destroyed_cells"):
		destroyed = host.destroyed_cells()
	# 队伍表:进场/重连各拉一次,客户端据此上色/分组。
	# ★ 必须**显式下发**:role 号由大厅「最小空闲号」分配、有人退出后会留空洞,客户端从 roles
	#   推导必然出错。
	var teams: Dictionary = {}
	if host != null and host.has_method("team_map"):
		teams = host.team_map()
	# ★ 判活再回:客户端一进对局场景就发 match_sync,而"进场景 → 请求 →(脚本/玩家)退出"可能
	#   挤在同一两帧里;回复是定向可靠包,往 ENet 已拆掉的 peer 发就是 channel 0 错误。
	if not NetBus.is_peer_live(caller):
		return
	var data := {
		"names": claim_names,
		"hues": claim_hues(),
		"options": claim_opts.get(1, {}),
		"roles": role_set,
		"spawns": spawns,
		"ground_weapons": ground,
	}
	if not destroyed.is_empty():
		data["destroyed"] = destroyed
	# ★ 与 `destroyed` 同款纪律:**非空才带**。不带队时旧客户端忽略未知键、新客户端拿到空 →
	#   双向兼容,不需要协商。
	if not teams.is_empty():
		data["teams"] = teams
	NetBus.rpc_id(caller, "match_sync_data", data)
