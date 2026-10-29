class_name LobbyRooms
extends Node

# 大厅的房间账本与生命周期(端口 7777 进程内):房间 → 玩家;1v1 两人就绪、大乱斗 N 人等待。
# ★ 2026-10-22 起本类是**门面**:三张表搬进 RoomRegistry、三种房型类合并进 RoomTypes,这里只剩
#   RPC handler、等待室广播与拆除收口。公开符号尽量逐字保留(外部调用点:room_manager / lobby_snapshot /
#   rejoin_probe / team_match_probe / 服务端面板)。★ 它仍是 Node:要用 multiplayer(is_peer_online 判
#   peer 真能收包)与 get_tree()(_release_port_later 等一帧)。依赖方向单向:本类用 launcher,反之不知道本类。
# ★「两人凑齐 → 开局」跨了边界(房间的事 + 拉 worker 的事),故用 pairing_ready 信号通知 RoomManager。
# ★ 拆除必须走单一收口 teardown_room:本层为「端口泄漏」这同一个失败模式补过三次;收口 = 清账本 + 广播,
#   端口归还只是借 launcher。

signal pairing_ready(room)   # 1v1 房凑齐两人 → RoomManager 接住去拉 worker + 发 go_match

const ROYALE_MIN_PLAYERS := 2
# 大乱斗人数上限:2026-10-09 由 8 提到 16(仓主裁定「上限按 16 人做」;依据:16 人实测服务器上行 143.85 KB/s,见 docs/eng/netcode-at-16-players.md)。
# ★ ROYALE_DEFAULT_MAX(4)与 ROYALE_MIN_PLAYERS(2)不动 —— 变的是上限。★★ 改这个数必须同时看另外两处(它们各自也是 8):
# ① scenes/mp_lobby.tscn 的 MaxPlayersSlider.max_value(不改它房主最多只能选到 8);② scenes/royale_game.gd 的 ROLE_COLORS(固定色板按 % size() 取色,只有 8 色时第 9 人与第 1 人同色)。
const ROYALE_MAX_PLAYERS := 16
const ROYALE_DEFAULT_MAX := 4

# 3v3:无 AI 补位、无降级 —— 满 6 人才开(用户裁定)。两条闸门都是硬上界:TEAM_ROLES = 房间容量,TEAM_SIZE = 每队人数。
const TEAM_SIZE := 3     # 每队人数
const TEAM_ROLES := 6    # 两队合计(满员才开局,无 AI 补位、无降级)

# 三个旧房型名 = 同一个统一类的别名(零转换):外部标注 LobbyRooms.Room / RoyaleRoom / TeamRoom 逐字不变。
const Room = RoomTypes.Room
const RoyaleRoom = RoomTypes.Room
const TeamRoom = RoomTypes.Room

var launcher: WorkerLauncher = null
var rejoin := RejoinRegistry.new()   # 回局凭据表:★ 独立于房对象(查询要活过 teardown_room)
var _registry := RoomRegistry.new()

# 三张表 → registry 的只读视图(1v1 / 大乱斗 / 3v3)。★ 别在这里增删:只走 _registry.add / _registry.erase
# (tools/room_sweep_lint.gd 钉住:表内删除与端口归还只许出现在收口里)。
var rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_PVP)
var royale_rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_ROYALE)
var team_rooms: Dictionary:
	get:
		return _registry.of(ModeDefs.MODE_TEAM)

# 昵称表(与 registry 同一份,不是第二份真相):读走它,写走 _registry.set_name / drop_name。
var _peer_names: Dictionary:
	get:
		return _registry.peer_names


# ── 3v3 的纯判据(静态:-s 可测;RPC handler 与 RoomManager 都调它们,判据只有这一份)── 入参形状统一是 {1: [role, …], 2: [role, …]}。──

# 两队是否都满员(满 6 人才允许开局)。★ 4v2 也算 6 人,但那不是 3v3。
static func team_ready(by_team: Dictionary, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(1, []) as Array).size() == size \
			and (by_team.get(2, []) as Array).size() == size


static func team_can_join(by_team: Dictionary, team: int, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(team, []) as Array).size() < size

# 最小空闲 role 号(有人退房留下的空洞会被复用)。★ 不能写成「人数 + 1」:那是「编号恒连续」的假设 —— 房里有 {1,3} 时按人数推会算出 3,撞上仍在房里的高号玩家、同一个 role 双份占用。
static func team_next_role(used_roles: Array) -> int:
	var role := 1
	while used_roles.has(role):
		role += 1
	return role


func _enter_tree() -> void:
	Wire.room_create_requested.connect(create_room)
	Wire.room_join_requested.connect(join_room)
	Wire.room_list_requested.connect(on_list_rooms)
	Wire.lobby_name_set.connect(on_lobby_name)
	Wire.peer_left.connect(on_peer_left)
	Wire.royale_create_requested.connect(royale_create)
	Wire.royale_join_requested.connect(royale_join)
	Wire.royale_leave_requested.connect(royale_leave)
	Wire.royale_list_requested.connect(royale_list)
# ★ 3v3 只接五条:team_create/join/pick/leave/list 是房间账本的事;team_start_requested(第六条)归 RoomManager(它要拉 worker)—— 接进来就等于同一件事有两处实现。
	Wire.team_create_requested.connect(team_create)
	Wire.team_join_requested.connect(team_join)
	Wire.team_pick_requested.connect(team_pick)
	Wire.team_leave_requested.connect(team_leave)
	Wire.team_list_requested.connect(team_list)
# 回局:上行是「我这间房还让我回吗」—— 判据与答复都在本类(它持有凭据表)。
	Wire.rejoin_requested.connect(on_rejoin_request)

func _exit_tree() -> void:
	Wire.room_create_requested.disconnect(create_room)
	Wire.room_join_requested.disconnect(join_room)
	Wire.room_list_requested.disconnect(on_list_rooms)
	Wire.lobby_name_set.disconnect(on_lobby_name)
	Wire.peer_left.disconnect(on_peer_left)
	Wire.royale_create_requested.disconnect(royale_create)
	Wire.royale_join_requested.disconnect(royale_join)
	Wire.royale_leave_requested.disconnect(royale_leave)
	Wire.royale_list_requested.disconnect(royale_list)
	Wire.team_create_requested.disconnect(team_create)
	Wire.team_join_requested.disconnect(team_join)
	Wire.team_pick_requested.disconnect(team_pick)
	Wire.team_leave_requested.disconnect(team_leave)
	Wire.team_list_requested.disconnect(team_list)
	Wire.rejoin_requested.disconnect(on_rejoin_request)

func on_lobby_name(caller: int, name: String) -> void:
	_registry.set_name(caller, name if not name.is_empty() else "Anon")

# 房间列表的纯构造(不含发送)。★ 抽出来是为了可测:探针没有对端,Wire.reply 会静默跳过 ⇒ 列表内容观测不到。
# ★ 对局中的房照列:第三人要看得见它,而「进不去」由 join_room 那侧的 in_match 守卫保证;那一行的名单取冻结的那份。
func room_list_payload() -> Array:
	return _registry.list_payload(ModeDefs.MODE_PVP)


func on_list_rooms(caller: int) -> void:
	Wire.send_to(caller, WireKind.ROOM_LIST, [room_list_payload()])

# 把「开局那一刻在房里的名单」冻进房记录(role + 昵称快照)。★ 谁调:RoomManager 在每一处开局调一次(_start_match / royale_start /
# royale_start_ai / team_start)—— 那是「这一局有哪些人」唯一确定的时刻。★ 名单错了不报错,只会让第三人看到「玩家, 玩家」。
func freeze_roster(room) -> void:
	_registry.freeze_roster(room)

# 一次性会话令牌(16 位 hex)。★ 旧 Godot 的 randi() 是 32 位,拼两次取 16 hex 得 64 位熵 —— 够防「误顶替」,不防恶意爆破(本设计不承担反作弊)。
# ★ 必须是两段 %08x,不能写成 "%016x" % ((randi() << 32) | randi()):后者会越过 int64 正半区,而 %x 对负数是带符号打印(实测 12 次抽样 8 次落在负半区,长度与字符都不符契约)。
static func new_token() -> String:
	return "%08x%08x" % [randi(), randi()]

# 该 peer 现在真的能收包吗?★ 判据是 ENet peer 自己的 state(Wire.is_peer_live):以前读 multiplayer.get_peers(),实测它把
# 「ENet 层已断、peer_map 还没收敛」的 peer 仍报在线(晚一拍)⇒ 判早了等于没判。v5 起直接读 Wire(非服务端恒 false)。
func is_peer_online(peer_id: int) -> bool:
	return Wire.is_peer_live(peer_id)

func create_room(caller: int) -> void:
# ★ 三路互斥(1v1 / 大乱斗 / 3v3):同一个客户端同时挂两种房会收到双重 go_match 互相覆盖,而旧房无人认领 → 幽灵房(端口永不归还)。
# ★ 互斥必须双向:四个建/加入入口每一个都要判另外两种 —— 只加一头就是「从 1v1 房直接开 3v3 房」,漏掉 join 那半边等于把洞留在 join 上。
	if _in_team_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间,请先退出再创建 1v1 房间"])
		return
	if royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在大乱斗房间,请先退出再创建 1v1 房间"])
		return
	if _in_1v1_room(caller):

		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已经在房间里了"])
		return
	var code := _registry.next_code(ModeDefs.MODE_PVP)
	var room := RoomTypes.Room.new()
	room.mode = ModeDefs.MODE_PVP
	room.code = code
	room.host_peer = caller
	room.max_players = 2
	room.players.append(caller)
	room.player_role[caller] = 1
	room.created_at = Time.get_unix_time_from_system()
	_registry.add(room)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_PVP, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家"))})
	Wire.send_to(caller, WireKind.ROOM_CREATED, [code])
	_flush_pvp_state.call_deferred(room)   # 1v1 等待室状态(2026-10-24:开局改由房主点开始)

func join_room(caller: int, code: String) -> void:
	var room: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_PVP)
	if room == null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间不存在"])
		return
	if _in_1v1_room(caller):
# 已在某个 1v1 房里就拒绝加入(含「加入自己刚建的房」:房主本就在 players 里,不拦会被 append 第二遍、并把 player_role[caller]
# 从 1 覆盖成 2 → 同一个 peer 同时占两个 role 的退化对局)。也顺带堵住「在 A 房还去加 B 房」留下的幽灵房。
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已经在房间里了"])
		return
	if room.in_match:
# 对局中(worker 已拉起):成员已转连对局,照列在列表里但进不去。★ 文案不能再说「房间已满」—— 房里可能只剩 1 人在线(对手掉线 /
# 自己还没转连),那是假话;而且它会命中大厅页 mp_lobby 的自动刷新分支,而刷新对这个房毫无意义。三模式文案逐字统一。
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["该房间的对局已进行中,无法加入"])
		return
	if room.started:
		# 开局瞬间(worker 已在拉、in_match 还没翻)的窗口:1v1 从 2026-10-24 起由房主触发,这个窗口可能被第三人撞上。
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["该房间的对局已进行中,无法加入"])
		return
	if room.players.size() >= 2:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间已满"])
		return
	if royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在大乱斗房间,请先退出再加入 1v1 房间"])
		return
	if _in_team_room(caller):

		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间,请先退出再加入 1v1 房间"])
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_PVP, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "players": room.players.size()})
	Wire.send_to(caller, WireKind.ROOM_JOINED, [2])

	# ★ 2026-10-24:不再自动开局 —— 两人齐后广播等待室状态,由房主点「开始游戏」触发 pairing_ready。
	_flush_pvp_state.call_deferred(room)

# 掉线 / 退出:三种房型逐条同款(摘人 → 3v3 顺带清空出的队位 → 局中不拆 → 空房拆 → 房主转移 + 广播)。
# ★★ 对局中(in_match)的房不拆:客户端转连 worker 时会全部断开大厅,拆了就再也不会出现在列表里 ——「看得见」与「回局」
# 都要求它活到对局结束;回收改由 RoomManager._reclaim_finished_matches 按 worker 进程还在不在判。
func on_peer_left(peer_id: int) -> void:
	_registry.drop_name(peer_id)
	for mode in ModeDefs.MODE_IDS:
		for code in _registry.of(mode).keys():
			var room: RoomTypes.Room = _registry.of(mode)[code]
			if not room.players.has(peer_id):
				continue
			var n_before := room.players.size()
			room.players.erase(peer_id)
			room.player_role.erase(peer_id)
			if room.in_match:   # 开局后客户端 Wire.stop() 转连 worker:不是"离开房间",单列 player_detach
				NetDiag.audit("player_detach", {"room": str(code), "mode": mode, "peer": peer_id})
			else:
				NetDiag.audit("player_leave", {"room": str(code), "mode": mode, "peer": peer_id,
						"players": n_before - 1})
			if room.is_team():
				_prune_team_of(room)
			if room.in_match:
				continue
			if room.players.is_empty():
				teardown_room(room, LobbyRooms.TEARDOWN_DELAYED, "", false, "empty")   # 延迟归还端口(worker 会自己退)
				continue
			if room.is_duel():
				# 1v1(2026-10-24 起有等待室状态):房主 = players[0],退出后自动顺位;刷新两边等待室(对手离开 / 换房主)。
				_flush_pvp_state.call_deferred(room)
				continue
			if room.host_peer == peer_id:
				room.host_peer = room.players[0]
				NetDiag.audit("host_transfer", {"room": str(code), "mode": mode,
						"from_peer": peer_id, "to_peer": room.host_peer})
# ★ 已开局的房不广播等待室状态(成员正在转连 worker,发给它们必然踩 max channels: 0 且包丢)。这一条 if 现在永远为真
# (in_match 已在上面 continue),但保留它:它是那件事的守卫,不是死代码 —— 删了会让后来者以为「开局后也可以广播」。
			if not room.in_match:
				_broadcast_state(room)

# 3v3 选边表里「role 已不在房内」的残留项(最小空闲号复用后,旧 role 的队号必须跟着消失)。
func _prune_team_of(room: RoomTypes.Room) -> void:
	for r in room.team_of.keys():
		if not room.player_role.values().has(int(r)):
			room.team_of.erase(r)


# 等待室状态广播的分派(原先是三处各调自己那份)。
func _broadcast_state(room: RoomTypes.Room) -> void:
	if room.is_royale():
		_broadcast_royale_state(room)
	elif room.is_team():
		_broadcast_team_state(room)
	elif room.is_duel():
		_flush_pvp_state.call_deferred(room)


# 房内全员广播实时状态(等待室 UI 刷新)。★ 延到帧末再发:调用点常在「刚有人断开」的路径上,此时其余成员的连接状态可能还没收敛。
func _broadcast_royale_state(rr: RoomTypes.Room) -> void:
	_flush_royale_state.call_deferred(rr)   # 体内再等一帧,见该函数的注释


func _flush_royale_state(rr: RoomTypes.Room) -> void:
# ★ 等下一帧再发(而非本帧末):调用点几乎都在「刚有人断开」的路径上,而此时其余成员的断开信号可能还没被 MultiplayerAPI 处理 ——
# get_peers() 仍把已断的 peer 报为在线(实测滞后超过一帧),同步发/帧末发都会踩 max channels: 0 且包会丢。
	await get_tree().process_frame
# ★★ 真正发送前再判一次开局(调用点那层的 in_match 守卫只挡住「排队时已开局」的情况):本函数是 call_deferred + 再等一帧,从排队到
# 发送之间房间完全可能已经开局,而那一刻正是成员集体转连 worker、陆续断开大厅的窗口(实测 6 人局开局后瞬间 5 条 max channels: 0)。
	if rr.in_match:
		return
	var plist: Array = []
	for peer_id in rr.players:
		plist.append({"role": rr.player_role[peer_id], "name": _peer_names.get(peer_id, "玩家")})
	var state := {
		"code": rr.code, "is_public": rr.is_public, "invite_code": rr.invite_code,
		"max_players": rr.max_players, "host_role": rr.player_role.get(rr.host_peer, 0),
		"players": plist, "in_match": rr.in_match,
	}
	for peer_id in rr.players:
		if is_peer_online(peer_id):
# ★ 每个 peer 送他自己那一份(多带 your_role):等待室 UI 靠它判「(我)/(房主)」—— 原先让客户端按昵称反查,两人同名(默认都叫 Anon)
# 时必然匹配到先出现的那个 → 高亮错行、房主看不到开局按钮。role 本来就是服务器权威分配的,不必让客户端猜。
			var mine := state.duplicate()
			mine["your_role"] = rr.player_role[peer_id]
			Wire.send_to(peer_id, WireKind.ROYALE_ROOM_STATE, [mine])

func royale_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_ROYALE, caller)


func _in_1v1_room(caller: int) -> bool:
	return _registry.room_of_peer(ModeDefs.MODE_PVP, caller) != null


func pvp_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_PVP, caller)


# 1v1 房主开局(2026-10-24:两人凑齐不再自动开,由房主点「开始游戏」)。门禁全在房间层:
# 房主 = players[0](1v1 没有 host_peer 语义)、必须 2 人、未开局。通过后仍走 pairing_ready → RoomManager 拉 worker。
func pvp_start(caller: int) -> void:
	var room := pvp_room_of(caller)
	if room == null:
		return
	if room.started or room.in_match:
		return   # 已开局(重复请求防重入:不会双开 worker)
	if room.players.is_empty() or room.players[0] != caller:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["只有房主能开始游戏"])
		return
	if room.players.size() < 2:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["等待对手加入"])
		return
	pairing_ready.emit(room)


# 1v1 等待室状态:{code, players:[{role,name}], host_role, in_match} + 每人一份 your_role。
# ★ 延帧再发、发送前再判开局:理由与 _flush_royale_state 逐字相同(断开信号未收敛会踩 max channels: 0 并丢包)。
func _flush_pvp_state(room: RoomTypes.Room) -> void:
	await get_tree().process_frame
	if room.in_match or room.started:
		return
	var plist: Array = []
	for peer_id in room.players:
		plist.append({"role": room.player_role[peer_id], "name": _peer_names.get(peer_id, "玩家")})
	var host_role := 0
	if not room.players.is_empty():
		host_role = int(room.player_role.get(room.players[0], 0))
	var state := {"code": room.code, "players": plist, "host_role": host_role, "in_match": room.in_match}
	for peer_id in room.players:
		if is_peer_online(peer_id):
			var mine := state.duplicate()
			mine["your_role"] = room.player_role[peer_id]
			Wire.send_to(peer_id, WireKind.PVP_ROOM_STATE, [mine])

func royale_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间,请先退出再创建大乱斗房间"])
		return
	if royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在大乱斗房间中"])
		return
	if _in_1v1_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 1v1 房间,请先退出再创建大乱斗房间"])
		return
	var code := _registry.next_code(ModeDefs.MODE_ROYALE)
	var rr := RoomTypes.Room.new()
	rr.mode = ModeDefs.MODE_ROYALE
	rr.code = code
	rr.host_peer = caller
	rr.players.append(caller)
	rr.player_role[caller] = 1
	rr.created_at = Time.get_unix_time_from_system()
	rr.is_public = bool(opts.get("is_public", true))
	rr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not rr.is_public and rr.invite_code.is_empty():
		rr.invite_code = _registry.generate_code()   # 私密未填码 → 自动生成
	var n := int(opts.get("max_players", ROYALE_DEFAULT_MAX))
	rr.max_players = clampi(n, ROYALE_MIN_PLAYERS, ROYALE_MAX_PLAYERS)
# 列表要显示限时 ⇒ 建房这一刻就得知道它。★ 与 _player_options 那份是两个真值(权威仍是报到时 role1 那份),见 Room.map 的注释。
	rr.match_time = int(opts.get("match_time", 0))
	rr.options = {
		"round_full_heal": bool(opts.get("round_full_heal", false)),
		"disabled_weapons": opts.get("disabled_weapons", []),
	}
	rr.beta = bool(opts.get("beta", false))
	rr.time_rules = opts.get("time", {}) if rr.beta else {}
	_registry.add(rr)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "cap": rr.max_players,
			"public": rr.is_public, "beta": rr.beta})
	_broadcast_royale_state(rr)

func royale_join(caller: int, code: String, invite: String, beta: bool) -> void:
	var rr: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_ROYALE)
	if rr == null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间不存在"])
		return
	# Beta 房与普通房互不可进(独立房间池的判据;两个方向各一条文案,别共用)
	if rr.beta and not beta:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["这是时间玩法(Beta)房间,请从主菜单 Beta 页进入"])
		return
	if not rr.beta and beta:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["这是普通大乱斗房间,请从主菜单「大乱斗」进入"])
		return
	if royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在大乱斗房间中"])
		return
	if _in_1v1_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 1v1 房间,请先退出再加入大乱斗房间"])
		return
	if _in_team_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间,请先退出再加入大乱斗房间"])
		return
	if rr.in_match:

		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["该房间的对局已进行中,无法加入"])
		return
	if rr.players.size() >= rr.max_players:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间已满"])
		return
	if not rr.is_public and invite.strip_edges() != rr.invite_code:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["邀请码错误"])
		return
	var role := 1
	while rr.player_role.values().has(role):
		role += 1
	rr.players.append(caller)
	rr.player_role[caller] = role
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "role": role,
			"players": rr.players.size(), "cap": rr.max_players})
	_broadcast_royale_state(rr)

func royale_leave(caller: int) -> void:
	var rr := royale_room_of(caller)
	if rr == null:
		return
	rr.players.erase(caller)
	rr.player_role.erase(caller)
	NetDiag.audit("player_leave", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE, "peer": caller,
			"players": rr.players.size(), "explicit": true})
	if rr.players.is_empty() and not rr.in_match:
# 「退出房间」按钮不断开大厅 peer ⇒ on_peer_left 不会为它触发;房间随即从注册表摘除,而 sweep / on_peer_left 都只遍历注册表 ⇒
# 之后再无任何路径能归还本房端口。故与其他拆除路径同法归还,并同样走大乱斗那条更长的复用延迟。★ 对局中不拆(否则「看得见」与「回局」都没了)。
		teardown_room(rr, LobbyRooms.TEARDOWN_DELAYED, "", false, "left")
	else:
# ★ 房主转移那一行必须带 not rr.players.is_empty():对局中的房可能一个人都不在线(全体转连走了),而 rr.players[0] 在空数组上会越界报错。
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]
			NetDiag.audit("host_transfer", {"room": rr.code, "mode": ModeDefs.MODE_ROYALE,
					"from_peer": caller, "to_peer": rr.host_peer, "explicit": true})

		if not rr.in_match:
			_broadcast_royale_state(rr)

# 房间列表的纯构造(理由同 room_list_payload:无对端时 reply 静默跳过 ⇒ 不抽出来探针观测不到)。★ 只列公开房;in_match 的房照列
# (第三人要看得见),未开局的空房仍不列(那是幽灵房)。★★ token(未认领欠账 B1,用户裁定甲案):私密房只对本人列出 —— 此前私密房一律
# continue ⇒ 在私密房里打到一半按 ESC 回主菜单的玩家列表里没有那一行,回局入口整个不存在。判据 = 凭据正是这一间房(RejoinRegistry.owns)。
# ★ 默认 "" ⇒ 不传 = 与从前逐字相同的行为(第三人、既有探针/冒烟调用点)。
func royale_list_payload(token: String = "") -> Array:
	return _registry.list_payload(ModeDefs.MODE_ROYALE, token, rejoin)


func royale_list(caller: int, token: String = "") -> void:
# 判活同 Wire.reply:请求与断开可能挤在同一次 poll 里。本节点(NetBusExt)没有自己的 reply 助手 —— 判据是跨节点的单一来源(Wire.is_peer_live)。
	if Wire.is_peer_live(caller):
		Wire.send_to(caller, WireKind.ROYALE_ROOMS, [royale_list_payload(token)])


# AI 补位用的 role 号:取 1..max_players 内人类未占用的最小空闲号。★ 不能用「成员数 + 1 + i」——那是「编号恒连续」的假设:有人退出
# 留空洞时(如真人 {1,3}),按人数推出来的 AI 号会撞上仍在房里的高号真人 ⇒ 同 role 双份玩家,worker 侧「人类 claim 数」算术跟着失真。
func royale_free_roles(rr: RoomTypes.Room, count: int) -> Array:
	var used := {}
	for r in rr.player_role.values():
		used[int(r)] = true
	var out: Array = []
	for r in range(1, rr.max_players + 1):
		if out.size() >= count:
			break
		if not used.has(r):
			out.append(r)
			used[r] = true
	return out


func _team_of(tr: RoomTypes.Room, role: int) -> int:
	return int(tr.team_of.get(role, 0))

# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)。
func _by_team(tr: RoomTypes.Room) -> Dictionary:
	var out := {1: [], 2: []}
	for role in tr.team_of:
		var t := int(tr.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


# 这个房能不能开局(RoomManager.team_start 调;对外的公开口 —— 别让它去读 _by_team)。
func team_room_ready(tr: RoomTypes.Room) -> bool:
	return team_ready(_by_team(tr))


func team_room_of(caller: int) -> RoomTypes.Room:
	return _registry.room_of_peer(ModeDefs.MODE_TEAM, caller)


func _in_team_room(caller: int) -> bool:
	return team_room_of(caller) != null


func team_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间中"])
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在其他房间,请先退出"])
		return
	var code := _registry.next_code(ModeDefs.MODE_TEAM)
	var tr := RoomTypes.Room.new()
	tr.mode = ModeDefs.MODE_TEAM
	tr.code = code
	tr.host_peer = caller
	tr.max_players = TEAM_ROLES
	tr.players.append(caller)
	tr.player_role[caller] = 1
	tr.created_at = Time.get_unix_time_from_system()
	tr.beta = bool(opts.get("beta", false))
	tr.time_rules = opts.get("time", {}) if tr.beta else {}
	tr.is_public = bool(opts.get("is_public", true))
	tr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not tr.is_public and tr.invite_code.is_empty():
		tr.invite_code = _registry.generate_code()
	_registry.add(tr)
	NetDiag.audit("room_created", {"room": code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "public": tr.is_public, "beta": tr.beta})
	_broadcast_team_state(tr)


func team_join(caller: int, code: String, invite: String, beta: bool) -> void:
	var tr: RoomTypes.Room = _registry.find(code, ModeDefs.MODE_TEAM)
	if tr == null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间不存在"])
		return
	# Beta 房与普通房互不可进(独立房间池的判据,与 royale_join 同款)
	if tr.beta and not beta:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["这是时间玩法(Beta)房间,请从主菜单 Beta 页进入"])
		return
	if not tr.beta and beta:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["这是普通 3v3 房间,请从主菜单「3 v 3 团 队」进入"])
		return
	if _in_team_room(caller):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在 3v3 房间中"])
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["你已在其他房间,请先退出"])
		return
	if tr.in_match:

		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["该房间的对局已进行中,无法加入"])
		return
	if tr.players.size() >= TEAM_ROLES:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["房间已满(6 人)"])
		return
	if not tr.is_public and invite.strip_edges() != tr.invite_code:
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["邀请码错误"])
		return
# role = 最小空闲号(与 royale 同款:不重排,有人退会留空洞 → 队伍表必须显式下发)。判据在 team_next_role(按人数推的写法在「有人退过」的房里必错)。
	var role := team_next_role(tr.player_role.values())
	tr.players.append(caller)
	tr.player_role[caller] = role
# ★ 进房不自动分队:3v3 的规则是玩家自己选边(用户裁定)。未选边 = team_of 里没有该 role,等待室会把他列在「未选边」那一档。
	NetDiag.audit("player_join", {"room": code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"nick": str(_peer_names.get(caller, "玩家")), "role": role,
			"players": tr.players.size()})
	_broadcast_team_state(tr)


# 选边。该队满 3 人 → 拒绝(回 server_message);已在别的队 → 改投(留空出的位置)。
func team_pick(caller: int, team: int) -> void:
	var tr := team_room_of(caller)
	if tr == null or tr.in_match:
		return
	if team != 1 and team != 2:
		return
	var role := int(tr.player_role.get(caller, 0))
	if role == 0:
		return
	var by_team := _by_team(tr)
	if not team_can_join(by_team, team):
		Wire.send_to(caller, WireKind.SERVER_MESSAGE, ["该队已满 3 人"])
		return
	tr.team_of[role] = team
	_broadcast_team_state(tr)


func team_leave(caller: int) -> void:
	var tr := team_room_of(caller)
	if tr == null:
		return
	tr.players.erase(caller)
	tr.player_role.erase(caller)
	NetDiag.audit("player_leave", {"room": tr.code, "mode": ModeDefs.MODE_TEAM, "peer": caller,
			"players": tr.players.size(), "explicit": true})

	_prune_team_of(tr)
	if tr.players.is_empty() and not tr.in_match:
# ★ 「退出房间」按钮不断开大厅 peer ⇒ on_peer_left 不会为它触发;房间随即摘除,而 sweep / on_peer_left 只遍历注册表 ⇒ 之后再无路径归还端口。
		teardown_room(tr, LobbyRooms.TEARDOWN_DELAYED, "", false, "left")
	else:

		if tr.host_peer == caller and not tr.players.is_empty():
			tr.host_peer = tr.players[0]
			NetDiag.audit("host_transfer", {"room": tr.code, "mode": ModeDefs.MODE_TEAM,
					"from_peer": caller, "to_peer": tr.host_peer, "explicit": true})
		if not tr.in_match:
			_broadcast_team_state(tr)


# 3v3 房间列表的纯构造(与 royale_list_payload 逐字同款,max_players 取房上的 TEAM_ROLES;token 那一档的来历与理由也见它)。
func team_list_payload(token: String = "") -> Array:
	return _registry.list_payload(ModeDefs.MODE_TEAM, token, rejoin)


func team_list(caller: int, token: String = "") -> void:
	# 判活同 royale_list:请求与断开可能挤在同一次 poll 里(见 Wire.reply 的注释)。
	if Wire.is_peer_live(caller):
		Wire.send_to(caller, WireKind.TEAM_ROOMS, [team_list_payload(token)])


# 客户端 → 大厅:房主上报本房的地图(仅用于列表展示)。★ 静默丢弃的两种情况都不回话、不踢人:找不到房 / caller 不是房主 —— 回话没有
# 意义(客户端无从处理),踢人更没道理(可能只是建完房还没同步完)。★ 刻意不判空房:写一个展示字段无害,多一个分支就多一条没人测的路径。
func on_room_map(caller: int, code: String, path: String) -> void:
	var r := _registry.find(code)
	if r == null:
		return
	if not _is_room_host(r, caller):
		return
	r.map = path


# 这个 caller 是不是这间房的房主?★ 1v1 没有 host 字段的语义不变(房主 = players[0]),另两种读 host_peer ——
# 写成「一律读 host_peer」会让 1v1 的上报永远被拒且不报错。
func _is_room_host(r: RoomTypes.Room, caller: int) -> bool:
	if r.is_duel():
		return r.players.size() > 0 and r.players[0] == caller
	return r.host_peer == caller


# 服务端控制台(server/gui/)用:这间房的房主昵称。只读,判据在 ServerStatus.host_of(可冒烟)。
# ★ 1v1 的房主表示与另两种不同(players[0] vs host_peer ⇒ 按 role 查名单),所以查表这一步在本类;
#   "该读哪一边"的判据必须是纯函数。
func host_name_of(room: Variant) -> String:
	if room is RoomTypes.Room and not (room as RoomTypes.Room).is_duel():
		var rr: RoomTypes.Room = room
		return ServerStatus.host_of(bool(rr.in_match), int(rr.host_peer),
				int(rr.player_role.get(rr.host_peer, 0)), rr.roster, _peer_names)
	if room is RoomTypes.Room:
		var r: RoomTypes.Room = room
		if not r.players.is_empty():
			return str(_peer_names.get(r.players[0], "玩家"))
		if not r.roster.is_empty():
			return str((r.roster[0] as Dictionary).get("name", "玩家"))
	return "玩家"


# 服务端控制台用:按 (房号, 种类) 精确取房对象;只读,找不到返回 null。
# ★ 房号空间跨模式重叠(都是 4 位号)⇒ 只按 code 查会查到另一模式的同号房,故必须带 kind。
# ★ 拆除仍必须走 teardown_room 单一收口 —— 本函数不改变任何状态。
func room_for_panel(code: String, kind: String) -> Variant:
	match kind:
		"1v1":
			return _registry.find(code, ModeDefs.MODE_PVP)
		"royale":
			return _registry.find(code, ModeDefs.MODE_ROYALE)
		"team":
			return _registry.find(code, ModeDefs.MODE_TEAM)
	return null


# 服务端控制台用:名单侧的展示数据(只读)。返回 [{role, name}]。判据在 ServerStatus.roster_of。
# ★ 不能直接读 roster:它开局那一刻才冻结 —— 等待中的房 roster 是空的(名字只在 players + _peer_names 里);
#   局中的房 players 已空(成员转连 worker),只能读冻结快照。
func display_roster_of(room: Variant) -> Array:
	var r: RoomTypes.Room = room as RoomTypes.Room
	if r == null:
		return []
	return ServerStatus.roster_of(r.in_match, r.roster, r.players, r.player_role, _peer_names)


# ── 回大厅后回局 ── 客户端在自己的大厅页上点自己那间房(对局中的房照常列在列表里,别人点它只会被「该房间的对局已进行中」拒掉)。
# ★ 应答复用 go_match(方法表一个字不动)⇒ 客户端那条「连 worker → 认领 role → 进对局」的路与首次进场逐字同一条。
# ★ 这里不判对局状态(「你还在宽限期吗」只有 worker 手里的 _grace 知道),只判两件事:凭据对不对得上、以及这一局的 worker 还在不在
# (后者防止把客户端送到一个已经结束、端口可能已被复用给别的对局的地址上)。★ 判据本体是纯函数 RejoinRegistry.decision,本函数只做
# 「查 → 判 → 发」,不在这里再写一遍 if/else(那正是漂的成因)。
func on_rejoin_request(caller: int, code: String, token: String) -> void:
	var now := Time.get_ticks_msec()
	var e := rejoin.lookup(token, now)
	var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))
	var why := RejoinRegistry.decision(e, code, alive)
	if why != "":
# ★ worker 已经退了 → 这份凭据再也不会成立,当场清掉:留着它只会让下一个请求再走一遍同样的拒绝。
		if not e.is_empty() and not alive:
			rejoin.drop_token(token)
		print("[lobby] 拒绝回局(peer=%d):%s" % [caller, why])
		if Wire.is_peer_live(caller):
			Wire.send_to(caller, WireKind.REJOIN_DENIED, [why])
		return
	print("[lobby] 回局:房间 %s role %d → worker 端口 %d" % [
			code, int(e.get("role", 0)), int(e.get("worker_port", 0))])
	# 复用原版 go_match:签名与首次进场完全相同(role, port)
	Wire.send_to(caller, WireKind.GO_MATCH, [int(e.get("role", 0)), int(e.get("worker_port", 0))])


# 房间状态广播(等待室/选边)。与 royale 那两条同款:call_deferred + 帧末再等一帧 + 开局后不再发。
func _broadcast_team_state(tr: RoomTypes.Room) -> void:
	_flush_team_state.call_deferred(tr)


func _flush_team_state(tr: RoomTypes.Room) -> void:
# ★ 等下一帧再发、真正发送前再判一次 in_match(理由与 _flush_royale_state 逐字相同:断开信号未收敛会踩 max channels: 0 并丢包)。
	await get_tree().process_frame
	if tr.in_match:
		return
	var plist: Array = []
	for peer_id in tr.players:
		var role := int(tr.player_role[peer_id])
		plist.append({"role": role, "name": _peer_names.get(peer_id, "玩家"),
				"team": _team_of(tr, role)})
	var state := {
		"code": tr.code, "is_public": tr.is_public, "invite_code": tr.invite_code,
		"host_role": tr.player_role.get(tr.host_peer, 0), "team_size": TEAM_SIZE,
		"players": plist, "in_match": tr.in_match,
	}
	for peer_id in tr.players:
		if is_peer_online(peer_id):
			# 每个 peer 送**他自己那一份**(多带 `your_role`):等待室靠它标"(我)",按昵称反查在
			# 同名玩家(默认都叫 Anon)上必然高亮错行 —— 与 royale 同款。
			var mine := state.duplicate()
			mine["your_role"] = tr.player_role[peer_id]
			Wire.send_to(peer_id, WireKind.TEAM_ROOM_STATE, [mine])


# ── 房间拆除的单一收口 ── 三种形态:TEARDOWN_DELAYED(正常关房,延迟归还)/ TEARDOWN_KILL(僵尸清扫,强杀 + 立即回收)/
# TEARDOWN_ABORT(拉起失败,立即归还)。──
const TEARDOWN_DELAYED := 0   # 正常关房:worker 会自己退 → **延迟**归还端口(防立刻复用撞车)
const TEARDOWN_KILL := 1      # 僵尸清扫:worker 还活着占着端口 → 强杀 + **立即**回收
const TEARDOWN_ABORT := 2     # 拉起失败:worker 根本没起来 → **立即**归还(不必延迟,也无从杀)

# 全部拆除路径都必须走它。理由不是「整洁」:本层为「端口泄漏」这同一个失败模式补过三次(on_peer_left 空房分支 / royale_leave 空房
# 分支 / ai_duel 摘房前的手动释放),散着写就还会漏第四次。★ tools/room_sweep_lint 有断言钉住:端口归还与注册表删除只能出现在本函数体内。
# mode 三种形态见 TEARDOWN_* 常量(默认 DELAYED);msg 空串 = 不发;disconnect_peers = true 时立刻断开房内玩家(清扫路径要,正常关房由 peer_left 自然收尾)。
# ★ 端口延迟三档由 room.mode 决定(1v1 120s / 大乱斗 360s / 3v3 360s),数值唯一来源是
#   RoomRegistry.port_return_delay → ModeRoomRules → WorkerLauncher.*_PORT_REUSE_DELAY。
# ★ 别把 3v3 并回 120s:「短于或等于断线宽限期会让重连的客户端连到别的局」是 1v1 从 30 → 120 的老坑。
func teardown_room(room, mode: int = TEARDOWN_DELAYED, msg: String = "",
		disconnect_peers: bool = false, reason: String = "") -> void:
# ★ 三态判定读 room.mode(is_duel/is_royale/is_team)。旧写法用 `room is RoyaleRoom` 二分 —— 三张表的房号空间重叠,
# 按号码反查是「同一个号在三张表里各有一份」的静默错拆,故判定必须落在**这个房对象自己**的模式上。
	var port: int = room.worker_port
	var peers: Array = room.players.duplicate()   # 先拷:下面要删注册表/可能改动它
	if port > 0:
		match mode:
			TEARDOWN_KILL:
				launcher.kill_worker(port)      # worker 还活着占着端口 → 先杀,杀完端口可直接回收
				launcher.release_now(port)
			TEARDOWN_ABORT:
				launcher.release_now(port)   # worker 根本没起来 → 立刻归还(不必延迟,也不必杀)
			_:
				_release_port_later(port, _registry.port_return_delay(room.mode))
	if not msg.is_empty():
		for peer_id in peers:
			if is_peer_online(peer_id):
				Wire.send_to(peer_id, WireKind.SERVER_MESSAGE, [msg])
	_registry.erase(room)
	var why := reason
	if why.is_empty():
		why = "closed" if mode == TEARDOWN_KILL else ("abort" if mode == TEARDOWN_ABORT else "delayed")
	NetDiag.audit("room_closed", {"room": str(room.code), "mode": room.mode, "reason": why,
			"port": port, "players": peers.size(),
			"uptime_sec": int(Time.get_unix_time_from_system() - float(room.created_at))})
# ★ 这一局的凭据随房一起作废(房都拆了,worker 要么已退要么马上被杀;留着凭据只会让回局把客户端送到一个已经不属于它的端口上,
# 而且没有一行报错)。★★ 键是 worker 端口、不是 room.code:房号空间跨模式重叠,按 code 作废会误伤同号的另一间房。
	var ntk := rejoin.drop_port(port)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
	if disconnect_peers:
		for peer_id in peers:
			if Wire.is_peer_live(peer_id):
				Wire.kick(peer_id)

# 延迟归还 worker 端口:给旧 worker 留足退出时间,防止端口被立刻复用导致串线。delay 由 teardown_room 按房型给三档
# (默认值是 1v1 那一档)。★ 本方法留在 LobbyRooms 是因为它要 await get_tree() —— RefCounted 没有树(见 WorkerLauncher 类头)。
func _release_port_later(port: int, delay: float = WorkerLauncher.WORKER_PORT_REUSE_DELAY) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(delay).timeout
	launcher.release_now(port)
