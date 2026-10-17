class_name LobbyRooms
extends Node

# 大厅的房间账本与生命周期(端口 7777 进程内):房间号 → 玩家;1v1 两人就绪、大乱斗 N 人等待。★ 它是 Node,因为要用 multiplayer
# (is_peer_online 判 peer 真能收包)与 get_tree()(_release_port_later 等一帧)。依赖方向单向:本类用 launcher,launcher 不知道本类。
# ★「两人凑齐 → 开局」跨了边界(房间的事 + 拉 worker 的事),故用 pairing_ready 信号通知 RoomManager,避免 back-reference。
# ★ 拆除必须走单一收口 teardown_room:本层为「端口泄漏」这同一个失败模式补过三次;收口主要是清账本 + 广播,端口归还只是借 launcher。

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


var launcher: WorkerLauncher = null


class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> 1/2
	var started := false                 # 已拉起 worker/已配对:拒绝再次加入
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
# worker 进程的 pid:「这一局还在不在」的唯一精确判据(三种模式的 worker 都在对局结束时自己退);0 = 还没登记(拉起中)→ 一律判没结束。
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)
# 开局那一刻冻结的名单 [{role, name}]。★ 成员转连 worker 后会陆续断开大厅(players 会空、_peer_names 会被擦),对局中房间的列表
# 渲染只能读这一份(否则第三人看到的是「玩家, 玩家」)。冻结点在 RoomManager 的四处开局。
	var roster: Array = []
# 房主上报的地图(仅用于列表展示),空串 = 随机/未上报。★ 它与真正定图的 player_options.map(报到那一刻 worker 取 role1 那份)
# 是两个真值:房主建房后改设置会让两者不一致(设计 §6 第 3 条,已知边界)。
	var map := ""

var rooms: Dictionary = {}   # code -> Room
var _peer_names: Dictionary = {}   # peer id -> 昵称(客户端连上大厅时上报,列表/建房展示)


class RoyaleRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(房内成员,**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..N,大乱斗角色号)
	var is_public := true
	var invite_code := ""                 # 私密房凭此码进入
	var max_players := ROYALE_DEFAULT_MAX
	var options: Dictionary = {}          # 房主对局选项(禁武器/回合回血),开局随房主生效
# Beta 房与普通房互不可进/互不可见(创建带标、加入校验、列表过滤);time_rules 是 TimeRules.to_dict(),开局前 from_dict + clamp 再消费(上报值不可信)。
	var beta := false
	var time_rules: Dictionary = {}
	var in_match := false                 # 已开局(拒绝加入;成员转连 worker 后房**仍保留**,见 on_peer_left)
	var worker_port: int = 0              # 本房拉起的大乱斗 worker 端口(关房时归还)

	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超龄清理用,与 Room.created_at 同形)

	var roster: Array = []
	var map := ""

	var match_time := 0

var royale_rooms: Dictionary = {}   # code -> RoyaleRoom


# 3v3 房:与 Room / RoyaleRoom 并列的第三种房,三张表并存且互相拒斥。★ 队伍不由服务器推导 —— role 号因「退出留空洞、最小空闲号
# 复用」而不连续,玩家自己点选边;未选边的 role 不在表里(不在任何一队,也不能开局)。
class TeamRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..6,最小空闲号)
	var team_of: Dictionary = {}          # role(int) -> 1/2(**选边前不在表里**)
	var beta := false                     # 时间玩法(Beta):与 RoyaleRoom.beta 同义
	var time_rules: Dictionary = {}
	var is_public := true
	var invite_code := ""
	var in_match := false
	var worker_port: int = 0

	var worker_pid: int = 0
	var created_at := 0.0

	var roster: Array = []
	var map := ""

var team_rooms: Dictionary = {}   # code -> TeamRoom

# 回局凭据表:★ 它独立于房对象 —— 房被拆除时凭据要不要跟着消失,由 teardown_room 显式决定(rejoin.drop_port),
# 而不是由「房对象还在不在」隐式决定(回局的查询要在大厅侧活过拆除)。三个房类原先各有一份 tokens 字段,已随同一批删除。
var rejoin := RejoinRegistry.new()


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
	NetBus.room_create_requested.connect(create_room)
	NetBus.room_join_requested.connect(join_room)
	NetBus.room_list_requested.connect(on_list_rooms)
	NetBus.lobby_name_set.connect(on_lobby_name)
	NetBus.peer_left.connect(on_peer_left)
	NetBusExt.royale_create_requested.connect(royale_create)
	NetBusExt.royale_join_requested.connect(royale_join)
	NetBusExt.royale_leave_requested.connect(royale_leave)
	NetBusExt.royale_list_requested.connect(royale_list)
# ★ 3v3 只接五条:team_create/join/pick/leave/list 是房间账本的事;team_start_requested(第六条)归 RoomManager(它要拉 worker)—— 接进来就等于同一件事有两处实现。
	NetBusExt.team_create_requested.connect(team_create)
	NetBusExt.team_join_requested.connect(team_join)
	NetBusExt.team_pick_requested.connect(team_pick)
	NetBusExt.team_leave_requested.connect(team_leave)
	NetBusExt.team_list_requested.connect(team_list)
# 回局:上行是「我这间房还让我回吗」—— 判据与答复都在本类(它持有凭据表)。
	NetBusExt.rejoin_requested.connect(on_rejoin_request)

func _exit_tree() -> void:
	NetBus.room_create_requested.disconnect(create_room)
	NetBus.room_join_requested.disconnect(join_room)
	NetBus.room_list_requested.disconnect(on_list_rooms)
	NetBus.lobby_name_set.disconnect(on_lobby_name)
	NetBus.peer_left.disconnect(on_peer_left)
	NetBusExt.royale_create_requested.disconnect(royale_create)
	NetBusExt.royale_join_requested.disconnect(royale_join)
	NetBusExt.royale_leave_requested.disconnect(royale_leave)
	NetBusExt.royale_list_requested.disconnect(royale_list)
	NetBusExt.team_create_requested.disconnect(team_create)
	NetBusExt.team_join_requested.disconnect(team_join)
	NetBusExt.team_pick_requested.disconnect(team_pick)
	NetBusExt.team_leave_requested.disconnect(team_leave)
	NetBusExt.team_list_requested.disconnect(team_list)
	NetBusExt.rejoin_requested.disconnect(on_rejoin_request)

func on_lobby_name(caller: int, name: String) -> void:
	_peer_names[caller] = name if not name.is_empty() else "Anon"

# 房间列表的纯构造(不含发送)。★ 抽出来是为了可测:探针没有对端,NetBus.reply 会静默跳过 ⇒ 列表内容观测不到。
# ★ started(对局中)的房照列:第三人要看得见它,而「进不去」由 join_room 那侧的 started 守卫保证。★ 对局中那一行的名单取冻结的那份。
func room_list_payload() -> Array:
	var arr: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if room.players.is_empty() and not room.started:
			continue
		var names: Array = []
		var count := 0
		if room.started:
			for e in room.roster:
				names.append(str((e as Dictionary).get("name", "玩家")))
			count = room.roster.size()
		else:
			for peer_id in room.players:
				names.append(_peer_names.get(peer_id, "玩家"))
			count = room.players.size()
# host 取 players[0](create_room 的 caller = 建房者);已开局 players 已空,退回 roster 第一条。is_public 恒 true(1v1 没有私密房这条路径)。
		var host_name := "玩家"
		if not room.players.is_empty():
			host_name = str(_peer_names.get(room.players[0], "玩家"))
		elif not room.roster.is_empty():
			host_name = str((room.roster[0] as Dictionary).get("name", "玩家"))
		arr.append({"code": code, "players": count, "names": names, "in_match": room.started,
				"is_public": true, "host": host_name, "map": room.map})
	return arr



func on_list_rooms(caller: int) -> void:
	NetBus.reply(caller, "room_list", room_list_payload())

func _generate_code() -> String:
	return "%04d" % (randi() % 10000)

# 把「开局那一刻在房里的名单」冻进房记录(role + 昵称快照)。★ 谁调:RoomManager 在每一处开局调一次(_start_match / royale_start /
# royale_start_ai / team_start)—— 那是「这一局有哪些人」唯一确定的时刻。★ 名单错了不报错,只会让第三人看到「玩家, 玩家」。
func freeze_roster(room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)),
				"name": str(_peer_names.get(pid, "玩家"))})
	room.roster = out

# 一次性会话令牌(16 位 hex)。★ 旧 Godot 的 randi() 是 32 位,拼两次取 16 hex 得 64 位熵 —— 够防「误顶替」,不防恶意爆破(本设计不承担反作弊)。
# ★ 必须是两段 %08x,不能写成 "%016x" % ((randi() << 32) | randi()):后者会越过 int64 正半区,而 %x 对负数是带符号打印(实测 12 次抽样 8 次落在负半区,长度与字符都不符契约)。
static func new_token() -> String:
	return "%08x%08x" % [randi(), randi()]

# 该 peer 现在真的能收包吗?★ 判据是 ENet peer 自己的 state(NetBus.is_peer_live):以前读 multiplayer.get_peers(),实测它把
# 「ENet 层已断、peer_map 还没收敛」的 peer 仍报在线(晚一拍)⇒ 判早了等于没判。这才是那条 channel 0 错误的正解。
func is_peer_online(peer_id: int) -> bool:
	return multiplayer.has_multiplayer_peer() and NetBus.is_peer_live(peer_id)

func create_room(caller: int) -> void:
# ★ 三路互斥(1v1 / 大乱斗 / 3v3):同一个客户端同时挂两种房会收到双重 go_match 互相覆盖,而旧房无人认领 → 幽灵房(端口永不归还)。
# ★ 互斥必须双向:四个建/加入入口每一个都要判另外两种 —— 只加一头就是「从 1v1 房直接开 3v3 房」,漏掉 join 那半边等于把洞留在 join 上。
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再创建 1v1 房间")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再创建 1v1 房间")
		return
	if _in_1v1_room(caller):

		NetBus.reply(caller, "server_message", "你已经在房间里了")
		return
	var code := _generate_code()
	while rooms.has(code):
		code = _generate_code()
	var room := Room.new()
	room.code = code
	room.players.append(caller)
	room.player_role[caller] = 1
	room.created_at = Time.get_unix_time_from_system()
	rooms[code] = room
	print("房间 %s 创建(房主 peer=%d)" % [code, caller])
	NetBus.reply(caller, "room_created", code)

func join_room(caller: int, code: String) -> void:
	if not rooms.has(code):
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	if _in_1v1_room(caller):
# 已在某个 1v1 房里就拒绝加入(含「加入自己刚建的房」:房主本就在 players 里,不拦会被 append 第二遍、并把 player_role[caller]
# 从 1 覆盖成 2 → 同一个 peer 同时占两个 role 的退化对局)。也顺带堵住「在 A 房还去加 B 房」留下的幽灵房。
		NetBus.reply(caller, "server_message", "你已经在房间里了")
		return
	var room: Room = rooms[code]
	if room.started:
# 对局中(worker 已拉起):成员已转连对局,照列在列表里但进不去。★ 文案不能再说「房间已满」—— 房里可能只剩 1 人在线(对手掉线 /
# 自己还没转连),那是假话;而且它会命中大厅页 mp_lobby 的自动刷新分支,而刷新对这个房毫无意义。三模式文案逐字统一。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if room.players.size() >= 2:
		NetBus.reply(caller, "server_message", "房间已满")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再加入 1v1 房间")
		return
	if _in_team_room(caller):

		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再加入 1v1 房间")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	print("房间 %s 加入(peer=%d)" % [code, caller])
	NetBus.reply(caller, "room_joined", 2)

	pairing_ready.emit(room)

func on_peer_left(peer_id: int) -> void:
	_peer_names.erase(peer_id)
	for code in rooms.keys():
		var room: Room = rooms[code]
		if not room.players.has(peer_id):
			continue
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
# 关房条件:只有「还没开局」的房才因空而关。★★ 对局中(started)的房不拆:客户端转连 worker 时会全部断开大厅,拆了就再也不会
# 出现在列表里 —— 「看得见」与「回局」都要求它活到对局结束;回收改由 RoomManager._reclaim_finished_matches 按 worker 进程还在不在判。
# ★ 这里不再发「配对已取消」那句提示(房没有被取消,那句话会是假的)。★ 代价照实登记(设计 §2.4):双方都在 go_match 后立刻消失时,
# 那一个 worker 与端口会白占到 2h 超龄清扫为止;玩家不会卡住。
		if room.started:
			continue
		if room.players.is_empty():
			teardown_room(room)   # 延迟归还端口(worker 会自己退;见 WORKER_PORT_REUSE_DELAY)

	for rcode in royale_rooms.keys():
		var rr: RoyaleRoom = royale_rooms[rcode]
		if not rr.players.has(peer_id):
			continue
		rr.players.erase(peer_id)
		rr.player_role.erase(peer_id)
# ★ 对局中(in_match)的房不拆(理由同 1v1),回收改由 _reclaim_finished_matches 按 worker 进程还在不在判;这里也不发「配对已取消」式提示。
		if rr.in_match:
			continue
		if rr.players.is_empty():
# 大乱斗按默认一局时长给更长的回收延迟(远长于 1v1);已知边界见 WorkerLauncher.ROYALE_PORT_REUSE_DELAY 的常量注释。
			teardown_room(rr)
		else:
			if rr.host_peer == peer_id:
				rr.host_peer = rr.players[0]
				print("大乱斗房 %s 房主转移 → peer %d" % [rcode, rr.host_peer])
# ★ 已开局的房不广播等待室状态(成员正在转连 worker,发给它们必然踩 max channels: 0 且包丢)。这一条 if 现在永远为真(in_match 已在上面
# continue),但保留它:它是那件事的守卫,不是死代码 —— 删了会让后来者以为「开局后也可以广播」。
			if not rr.in_match:
				_broadcast_royale_state(rr)
# 3v3 房与大乱斗逐字同款(掉线即离房;空房关闭;房主掉线转移)。★ 没有这一段 3v3 会漏两处:① 等待期有人关掉客户端 ⇒ 该 peer 永久留在
# players 里(幽灵人数、host_peer 可能指向死人,这个房再也不可能凑齐 6 人);② 开局后 6 人转连 worker 会全部触发本函数。本循环剩下的职责是摘人/转移房主。
	for tcode in team_rooms.keys():
		var tr: TeamRoom = team_rooms[tcode]
		if not tr.players.has(peer_id):
			continue
		tr.players.erase(peer_id)
		tr.player_role.erase(peer_id)

		for r in tr.team_of.keys():
			if not tr.player_role.values().has(int(r)):
				tr.team_of.erase(r)
		if tr.in_match:
			continue   # 对局中:房活到 worker 退出(理由与大乱斗逐字同款)
		if tr.players.is_empty():
			teardown_room(tr)
		else:
			if tr.host_peer == peer_id:
				tr.host_peer = tr.players[0]
				print("3v3 房 %s 房主转移 → peer %d" % [tcode, tr.host_peer])

			if not tr.in_match:
				_broadcast_team_state(tr)



# 房内全员广播实时状态(等待室 UI 刷新)。★ 延到帧末再发:调用点常在「刚有人断开」的路径上,此时其余成员的连接状态可能还没收敛。
func _broadcast_royale_state(rr: RoyaleRoom) -> void:
	_flush_royale_state.call_deferred(rr)   # 体内再等一帧,见该函数的注释


func _flush_royale_state(rr: RoyaleRoom) -> void:
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
			NetBusExt.rpc_id(peer_id, "royale_room_state", mine)

func royale_room_of(caller: int) -> RoyaleRoom:
	for r in royale_rooms:
		if (royale_rooms[r] as RoyaleRoom).players.has(caller):
			return royale_rooms[r]
	return null


func _in_1v1_room(caller: int) -> bool:
	for code in rooms:
		if (rooms[code] as Room).players.has(caller):
			return true
	return false

func royale_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再创建大乱斗房间")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.reply(caller, "server_message", "你已在 1v1 房间,请先退出再创建大乱斗房间")
		return
	var code := _generate_code()
	while royale_rooms.has(code):
		code = _generate_code()
	var rr := RoyaleRoom.new()
	rr.code = code
	rr.host_peer = caller
	rr.players.append(caller)
	rr.player_role[caller] = 1
	rr.created_at = Time.get_unix_time_from_system()
	rr.is_public = bool(opts.get("is_public", true))
	rr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not rr.is_public and rr.invite_code.is_empty():
		rr.invite_code = _generate_code()   # 私密未填码 → 自动生成
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
	royale_rooms[code] = rr
	print("大乱斗房 %s 创建(房主 peer=%d,%s,上限 %d%s)" % [code, caller,
			"公开" if rr.is_public else "私密", rr.max_players, ",Beta 时间玩法" if rr.beta else ""])
	_broadcast_royale_state(rr)

func royale_join(caller: int, code: String, invite: String, beta: bool) -> void:
	if not royale_rooms.has(code):
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	# Beta 房与普通房互不可进(独立房间池的判据;两个方向各一条文案,别共用)
	if royale_rooms[code].beta and not beta:
		NetBus.reply(caller, "server_message", "这是时间玩法(Beta)房间,请从主菜单 Beta 页进入")
		return
	if not royale_rooms[code].beta and beta:
		NetBus.reply(caller, "server_message", "这是普通大乱斗房间,请从主菜单「大乱斗」进入")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间中")
		return
	if _in_1v1_room(caller):
		NetBus.reply(caller, "server_message", "你已在 1v1 房间,请先退出再加入大乱斗房间")
		return
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再加入大乱斗房间")
		return
	var rr: RoyaleRoom = royale_rooms[code]
	if rr.in_match:

		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if rr.players.size() >= rr.max_players:
		NetBus.reply(caller, "server_message", "房间已满")
		return
	if not rr.is_public and invite.strip_edges() != rr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
	var role := 1
	while rr.player_role.values().has(role):
		role += 1
	rr.players.append(caller)
	rr.player_role[caller] = role
	print("大乱斗房 %s 加入(peer=%d,role=%d,%d/%d)" % [code, caller, role,
			rr.players.size(), rr.max_players])
	_broadcast_royale_state(rr)

func royale_leave(caller: int) -> void:
	var rr := royale_room_of(caller)
	if rr == null:
		return
	rr.players.erase(caller)
	rr.player_role.erase(caller)
	if rr.players.is_empty() and not rr.in_match:
# 「退出房间」按钮不断开大厅 peer ⇒ on_peer_left 不会为它触发;房间随即从注册表摘除,而 sweep / on_peer_left 都只遍历注册表 ⇒
# 之后再无任何路径能归还本房端口。故与其他拆除路径同法归还,并同样走大乱斗那条更长的复用延迟。★ 对局中不拆(否则「看得见」与「回局」都没了)。
		teardown_room(rr)
	else:
# ★ 房主转移那一行必须带 not rr.players.is_empty():对局中的房可能一个人都不在线(全体转连走了),而 rr.players[0] 在空数组上会越界报错。
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]

		if not rr.in_match:
			_broadcast_royale_state(rr)

# 房间列表的纯构造(理由同 room_list_payload:无对端时 reply 静默跳过 ⇒ 不抽出来探针观测不到)。★ 只列公开房;in_match 的房照列
# (第三人要看得见),未开局的空房仍不列(那是幽灵房)。★★ token(未认领欠账 B1,用户裁定甲案):私密房只对本人列出 —— 此前私密房一律
# continue ⇒ 在私密房里打到一半按 ESC 回主菜单的玩家列表里没有那一行,回局入口整个不存在。判据 = 凭据正是这一间房(RejoinRegistry.owns)。
# ★ 默认 "" ⇒ 不传 = 与从前逐字相同的行为(第三人、既有探针/冒烟调用点)。
func royale_list_payload(token: String = "") -> Array:
	var now := Time.get_ticks_msec()
	var arr: Array = []
	for code in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[code]
		if not rr.is_public and not rejoin.owns(token, code, now):
			continue
		if rr.in_match:
			var dn: Array = []
			for e in rr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": code, "players": rr.roster.size(), "max_players": rr.max_players,
					"names": dn, "in_match": true, "beta": rr.beta,
					"is_public": rr.is_public, "host": _host_name_of(_room_host_role(rr), rr.roster),
					"map": rr.map, "match_time": rr.match_time})
			continue
		if rr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in rr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names, "in_match": false, "beta": rr.beta,
				"is_public": rr.is_public, "host": str(_peer_names.get(rr.host_peer, "玩家")),
				"map": rr.map, "match_time": rr.match_time})
	return arr


func royale_list(caller: int, token: String = "") -> void:
# 判活同 NetBus.reply:请求与断开可能挤在同一次 poll 里。本节点(NetBusExt)没有自己的 reply 助手 —— 判据是跨节点的单一来源(NetBus.is_peer_live)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload(token))



# AI 补位用的 role 号:取 1..max_players 内人类未占用的最小空闲号。★ 不能用「成员数 + 1 + i」——那是「编号恒连续」的假设:有人退出
# 留空洞时(如真人 {1,3}),按人数推出来的 AI 号会撞上仍在房里的高号真人 ⇒ 同 role 双份玩家,worker 侧「人类 claim 数」算术跟着失真。
func royale_free_roles(rr: RoyaleRoom, count: int) -> Array:
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




func _team_of(tr: TeamRoom, role: int) -> int:
	return int(tr.team_of.get(role, 0))

# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)。
func _by_team(tr: TeamRoom) -> Dictionary:
	var out := {1: [], 2: []}
	for role in tr.team_of:
		var t := int(tr.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


# 这个房能不能开局(RoomManager.team_start 调;对外的公开口 —— 别让它去读 _by_team)。
func team_room_ready(tr: TeamRoom) -> bool:
	return team_ready(_by_team(tr))


func team_room_of(caller: int) -> TeamRoom:
	for c in team_rooms:
		if (team_rooms[c] as TeamRoom).players.has(caller):
			return team_rooms[c]
	return null



func _in_team_room(caller: int) -> bool:
	return team_room_of(caller) != null


func team_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	var code := _generate_code()
	while team_rooms.has(code):
		code = _generate_code()
	var tr := TeamRoom.new()
	tr.code = code
	tr.host_peer = caller
	tr.players.append(caller)
	tr.player_role[caller] = 1
	tr.created_at = Time.get_unix_time_from_system()
	tr.beta = bool(opts.get("beta", false))
	tr.time_rules = opts.get("time", {}) if tr.beta else {}
	tr.is_public = bool(opts.get("is_public", true))
	tr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not tr.is_public and tr.invite_code.is_empty():
		tr.invite_code = _generate_code()
	team_rooms[code] = tr
	print("3v3 房 %s 创建(房主 peer=%d,%s%s)" % [code, caller, "公开" if tr.is_public else "私密",
			",Beta 时间玩法" if tr.beta else ""])
	_broadcast_team_state(tr)


func team_join(caller: int, code: String, invite: String, beta: bool) -> void:
	if not team_rooms.has(code):
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	# Beta 房与普通房互不可进(独立房间池的判据,与 royale_join 同款)
	if team_rooms[code].beta and not beta:
		NetBus.reply(caller, "server_message", "这是时间玩法(Beta)房间,请从主菜单 Beta 页进入")
		return
	if not team_rooms[code].beta and beta:
		NetBus.reply(caller, "server_message", "这是普通 3v3 房间,请从主菜单「3 v 3 团 队」进入")
		return
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	var tr: TeamRoom = team_rooms[code]
	if tr.in_match:

		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if tr.players.size() >= TEAM_ROLES:
		NetBus.reply(caller, "server_message", "房间已满(6 人)")
		return
	if not tr.is_public and invite.strip_edges() != tr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
# role = 最小空闲号(与 royale 同款:不重排,有人退会留空洞 → 队伍表必须显式下发)。判据在 team_next_role(按人数推的写法在「有人退过」的房里必错)。
	var role := team_next_role(tr.player_role.values())
	tr.players.append(caller)
	tr.player_role[caller] = role
# ★ 进房不自动分队:3v3 的规则是玩家自己选边(用户裁定)。未选边 = team_of 里没有该 role,等待室会把他列在「未选边」那一档。
	print("3v3 房 %s 加入(peer=%d,role=%d,%d/%d)" % [code, caller, role, tr.players.size(), TEAM_ROLES])
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
		NetBus.reply(caller, "server_message", "该队已满 3 人")
		return
	tr.team_of[role] = team
	_broadcast_team_state(tr)


func team_leave(caller: int) -> void:
	var tr := team_room_of(caller)
	if tr == null:
		return
	tr.players.erase(caller)
	tr.player_role.erase(caller)

	for r in tr.team_of.keys():
		if not tr.player_role.values().has(int(r)):
			tr.team_of.erase(r)
	if tr.players.is_empty() and not tr.in_match:
# ★ 「退出房间」按钮不断开大厅 peer ⇒ on_peer_left 不会为它触发;房间随即摘除,而 sweep / on_peer_left 只遍历注册表 ⇒ 之后再无路径归还端口。
		teardown_room(tr)
	else:

		if tr.host_peer == caller and not tr.players.is_empty():
			tr.host_peer = tr.players[0]
		if not tr.in_match:
			_broadcast_team_state(tr)


# 已开局的房:host_role 由 player_role[host_peer] 得来,再从 roster 里按 role 取名。★ roster 是开局那一刻冻结的 [{role, name}]:成员转连 worker
# 后 players / _peer_names 都会空,对局中的房只能读这一份。
func _room_host_role(rr) -> int:
	if rr is RoyaleRoom or rr is TeamRoom:
		return int(rr.player_role.get(rr.host_peer, 0))
	return 0


func _host_name_of(role: int, roster: Array) -> String:
	for e in roster:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("role", 0)) == role:
			return str((e as Dictionary).get("name", "玩家"))
	return "玩家"



# 3v3 的三档人数:{1: A 队, 2: B 队, 0: 未选边}。★ 键用字符串是刻意的约定 —— 不是因为类型会丢(本仓 RPC 走二进制 Variant 编码,int 键能活下来)。
func _team_counts_of(tr: TeamRoom) -> Dictionary:
	var counts := {"1": 0, "2": 0, "0": 0}
	for role in tr.player_role.values():
		var t := int(tr.team_of.get(int(role), 0))
		var k := str(t if t == 1 or t == 2 else 0)
		counts[k] = int(counts[k]) + 1
	return counts


# 3v3 房间列表的纯构造(与 royale_list_payload 逐字同款,max_players 取 TEAM_ROLES;token 那一档的来历与理由也见它)。
func team_list_payload(token: String = "") -> Array:
	var now := Time.get_ticks_msec()
	var arr: Array = []
	for c in team_rooms:
		var tr: TeamRoom = team_rooms[c]
		if not tr.is_public and not rejoin.owns(token, c, now):
			continue
		if tr.in_match:
			var dn: Array = []
			for e in tr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": c, "players": tr.roster.size(), "max_players": TEAM_ROLES,
					"names": dn, "in_match": true, "beta": tr.beta,
					"is_public": tr.is_public, "host": _host_name_of(_room_host_role(tr), tr.roster),
					"map": tr.map, "team_counts": _team_counts_of(tr)})
			continue
		if tr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in tr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": c, "players": tr.players.size(),
				"max_players": TEAM_ROLES, "names": names, "in_match": false, "beta": tr.beta,
				"is_public": tr.is_public, "host": str(_peer_names.get(tr.host_peer, "玩家")),
				"map": tr.map, "team_counts": _team_counts_of(tr)})
	return arr


func team_list(caller: int, token: String = "") -> void:
	# 判活同 royale_list:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "team_rooms", team_list_payload(token))


# 客户端 → 大厅:房主上报本房的地图(仅用于列表展示)。★ 静默丢弃的两种情况都不回话、不踢人:找不到房 / caller 不是房主 —— 回话没有
# 意义(客户端无从处理),踢人更没道理(可能只是建完房还没同步完)。★ 刻意不判空房:写一个展示字段无害,多一个分支就多一条没人测的路径。
func on_room_map(caller: int, code: String, path: String) -> void:
	var r: Variant = _room_any(code)
	if r == null:
		return
	if not _is_room_host(r, caller):
		return
	r.map = path


# 三张表按 code 找房(顺序固定:1v1 → 大乱斗 → 3v3)。★ 房号空间三张表共用 ⇒ 同号共存是允许的,故这条查法只对「上报地图」这种
# 幂等写入安全;要拆房请走 teardown_room 的 room is RoyaleRoom 判定(那里错拆是静默的)。
func _room_any(code: String) -> Variant:
	if rooms.has(code):
		return rooms[code]
	if royale_rooms.has(code):
		return royale_rooms[code]
	if team_rooms.has(code):
		return team_rooms[code]
	return null


# 这个 caller 是不是这间房的房主?★ 三张表的房主表示不同:Room(1v1)没有 host 字段(建房者 = players[0]),另两张有 host_peer ——
# 写成「一律读 host_peer」会让 1v1 的上报永远被拒且不报错。
func _is_room_host(r: Variant, caller: int) -> bool:
	if r is RoyaleRoom or r is TeamRoom:
		return r.host_peer == caller
	if r is Room:
		return r.players.size() > 0 and r.players[0] == caller
	return false


# 服务端控制台(server/gui/)用:这间房的房主昵称。**只读**,判据在 ServerStatus.host_of(可冒烟)。
# ★ 三张表的房主表示不同(1v1 = players[0],另两张 = host_peer ⇒ 再按 role 查名单),
#   所以查表这一步只能住在本类;但"该读哪一边"的判据必须是纯函数。
func host_name_of(room: Variant) -> String:
	if room is RoyaleRoom or room is TeamRoom:
		return ServerStatus.host_of(bool(room.in_match), int(room.host_peer),
				_room_host_role(room), room.roster, _peer_names)
	if room is Room:
		var r: Room = room
		if not r.players.is_empty():
			return str(_peer_names.get(r.players[0], "玩家"))
		if not r.roster.is_empty():
			return str((r.roster[0] as Dictionary).get("name", "玩家"))
	return "玩家"


# 服务端控制台用:按 (房号, 种类) **精确**取房对象;只读,找不到返回 null。
# ★ 三张表的房号空间重叠(都是 _generate_code() 的 4 位号)⇒ 只按 code 查会查到另一张表的同号房。
# ★ 拆除仍必须走 teardown_room 单一收口 —— 本函数不改变任何状态。
func room_for_panel(code: String, kind: String) -> Variant:
	match kind:
		"1v1":
			return rooms.get(code, null)
		"royale":
			return royale_rooms.get(code, null)
		"team":
			return team_rooms.get(code, null)
	return null


# 服务端控制台用:**名单侧**的展示数据(只读)。返回 [{role, name}]。判据在 ServerStatus.roster_of。
# ★ 为什么不能直接读 `roster`:它**开局那一刻**才冻结 —— 等待中的房 roster 是空的
#   (名字只在 players + _peer_names 里);局中的房 players 已空(成员转连 worker),只能读冻结快照。
func display_roster_of(room: Variant) -> Array:
	var in_match := false
	var frozen: Array = []
	var players: Array = []
	var roles: Dictionary = {}
	if room is RoyaleRoom:
		in_match = room.in_match
		frozen = room.roster
		players = room.players
		roles = room.player_role
	elif room is TeamRoom:
		in_match = room.in_match
		frozen = room.roster
		players = room.players
		roles = room.player_role
	elif room is Room:
		in_match = room.started
		frozen = room.roster
		players = room.players
		roles = room.player_role
	else:
		return []
	return ServerStatus.roster_of(in_match, frozen, players, roles, _peer_names)


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
		if NetBus.is_peer_live(caller):
			NetBusExt.rpc_id(caller, "rejoin_denied", why)
		return
	print("[lobby] 回局:房间 %s role %d → worker 端口 %d" % [
			code, int(e.get("role", 0)), int(e.get("worker_port", 0))])
	# 复用原版 go_match:签名与首次进场完全相同(role, port)
	NetBus.reply(caller, "go_match", int(e.get("role", 0)), int(e.get("worker_port", 0)))


# 房间状态广播(等待室/选边)。与 royale 那两条同款:call_deferred + 帧末再等一帧 + 开局后不再发。
func _broadcast_team_state(tr: TeamRoom) -> void:
	_flush_team_state.call_deferred(tr)


func _flush_team_state(tr: TeamRoom) -> void:
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
			NetBusExt.rpc_id(peer_id, "team_room_state", mine)


# ── 房间拆除的单一收口 ── 三种形态:TEARDOWN_DELAYED(正常关房,延迟归还)/ TEARDOWN_KILL(僵尸清扫,强杀 + 立即回收)/
# TEARDOWN_ABORT(拉起失败,立即归还)。──
const TEARDOWN_DELAYED := 0   # 正常关房:worker 会自己退 → **延迟**归还端口(防立刻复用撞车)
const TEARDOWN_KILL := 1      # 僵尸清扫:worker 还活着占着端口 → 强杀 + **立即**回收
const TEARDOWN_ABORT := 2     # 拉起失败:worker 根本没起来 → **立即**归还(不必延迟,也无从杀)

# 全部拆除路径都必须走它。理由不是「整洁」:本层为「端口泄漏」这同一个失败模式补过三次(on_peer_left 空房分支 / royale_leave 空房
# 分支 / ai_duel 摘房前的手动释放),散着写就还会漏第四次。★ tools/room_sweep_lint 有断言钉住:端口归还与注册表删除只能出现在本函数体内。
# mode 三种形态见 TEARDOWN_* 常量(默认 DELAYED);msg 空串 = 不发;disconnect_peers = true 时立刻断开房内玩家(清扫路径要,正常关房由 peer_left 自然收尾)。
# ★ 端口延迟三档:1v1 = WORKER_PORT_REUSE_DELAY(120s,≥ 断线宽限期)、大乱斗 = 360s、3v3 = 360s。★ 别把 3v3 并回 120s:
# 「短于或等于断线宽限期会让重连的客户端连到别的局」是 1v1 从 30 → 120 的老坑。
func teardown_room(room, mode: int = TEARDOWN_DELAYED, msg: String = "",
		disconnect_peers: bool = false) -> void:
# ★ 三态:原先只有 is_royale 二分,3v3 是第三个模式 ⇒ 端口延迟与注册表各多一档。★ 判据用 is 而不是 room.code 撞库:三张表的房号
# 空间重叠(都是 _generate_code() 的 4 位号),按号码反查是「同一个号在三张表里各有一份」的静默错拆。
	var is_royale: bool = room is RoyaleRoom
	var is_team: bool = room is TeamRoom
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
				var delay := WorkerLauncher.WORKER_PORT_REUSE_DELAY
				if is_royale:
					delay = WorkerLauncher.ROYALE_PORT_REUSE_DELAY
				elif is_team:
					delay = WorkerLauncher.TEAM_PORT_REUSE_DELAY
				_release_port_later(port, delay)
	if not msg.is_empty():
		for peer_id in peers:
			if is_peer_online(peer_id):
				NetBus.reply(peer_id, "server_message", msg)
	if is_royale:
		royale_rooms.erase(room.code)
	elif is_team:
		team_rooms.erase(room.code)
	else:
		rooms.erase(room.code)
	var how := "将于延迟后回收"
	if mode == TEARDOWN_KILL:
		how = "已强杀并立即回收"
	elif mode == TEARDOWN_ABORT:
		how = "立即归还(worker 未起来)"
	var kind := "大乱斗房" if is_royale else ("3v3 房" if is_team else "房间")
	print("%s %s 拆除(端口 %d %s)" % [kind, room.code, port, how])
# ★ 这一局的凭据随房一起作废(房都拆了,worker 要么已退要么马上被杀;留着凭据只会让回局把客户端送到一个已经不属于它的端口上,
# 而且没有一行报错)。★★ 键是 worker 端口、不是 room.code:三张注册表的房号空间重叠,按 code 作废会误伤同号的另一间房 —— 与上面那行 is 判定是同一个坑。
	var ntk := rejoin.drop_port(port)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
	if disconnect_peers:
		for peer_id in peers:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)

# 延迟归还 worker 端口:给旧 worker 留足退出时间,防止端口被立刻复用导致串线。delay 由 teardown_room 按房型给三档
# (默认值是 1v1 那一档)。★ 本方法留在 RoomManager 是因为它要 await get_tree() —— RefCounted 没有树(见 WorkerLauncher 类头)。
func _release_port_later(port: int, delay: float = WorkerLauncher.WORKER_PORT_REUSE_DELAY) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(delay).timeout
	launcher.release_now(port)
