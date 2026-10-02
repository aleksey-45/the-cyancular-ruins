class_name LobbyRooms
extends Node

# 大厅的**房间账本与生命周期**(端口 7777 进程内)。房间号 → 玩家;1v1 两人就绪、大乱斗 N 人等待。
#
# ★ 职责边界(2026-09-14 拆分,方案 a:做成 Node):
#   · 本类 = **房间状态本身** + 房间侧 RPC handler + 房间拆除收口。它是 Node,因为要用
#     `multiplayer`(`is_peer_online` 判 peer 真能收包)与 `get_tree()`(`_release_port_later` 等一帧)。
#     ——当初它留在大厅房间文件里搬不出去,正是因为这两样;做成节点后不再需要 back-reference。
#   · `RoomManager` = **进程编排**(拉 worker 子进程 + 让玩家转连)+ 定时清扫,并**持有并注入**
#     `launcher`(端口池/worker 进程)。依赖方向单向:本类用 `launcher`,launcher 不知道本类。
#   · 「两人凑齐 → 开局」这一步跨了边界(房间的事 + 拉 worker 的事),故用信号
#     `pairing_ready` 由本类通知 RoomManager 去拉 worker —— 避免反向引用。
#
# ★ 拆除必须走**单一收口** `teardown_room`(理由见该函数头):本层为「端口泄漏」这同一个失败
#   模式补过三次。收口随账本走 —— 它主要是清账本 + 广播,端口归还只是借 launcher。

signal pairing_ready(room)   # 1v1 房凑齐两人 → RoomManager 接住去拉 worker + 发 go_match

const ROYALE_MIN_PLAYERS := 2
const ROYALE_MAX_PLAYERS := 8
const ROYALE_DEFAULT_MAX := 4

# 3v3:**无 AI 补位、无降级** —— 满 6 人才开(用户裁定)。两条闸门都是硬上界:
# `TEAM_ROLES` = 房间容量(第 7 个 join 直接拒),`TEAM_SIZE` = 每队人数(选边闸门)。
const TEAM_SIZE := 3     # 每队人数
const TEAM_ROLES := 6    # 两队合计(满员才开局,无 AI 补位、无降级)

# worker 端口池/子进程(由 RoomManager 装配时注入;本类只用 release_now / kill_worker)
var launcher: WorkerLauncher = null


class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> 1/2
	var started := false                 # 已拉起 worker/已配对:拒绝再次加入
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
	# worker 进程的 pid(拉起成功后由 RoomManager 登记)。★ 它是"这一局还在不在"的唯一精确判据:
	# 三种模式的 worker 都在对局结束时自己退;0 = 还没登记(拉起中)→ 一律判**没结束**。
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)
	# 开局那一刻冻结的名单 [{role:int, name:String}]。★ 成员转连 worker 后会陆续断开大厅:
	# `players` 会空掉、`_peer_names` 会被擦掉 —— 对局中房间的列表渲染**只能**读这一份
	# (否则第三人看到的是"玩家, 玩家")。冻结点在 RoomManager 的四处开局。
	var roster: Array = []

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
	# 时间玩法(Beta,2026-09-28):beta 房与普通房**互不可进/互不可见**(创建带标,加入校验,列表过滤);
	# time_rules = TimeRules.to_dict()(服务器开局前 from_dict+clamp 再消费,上报值不可信)
	var beta := false
	var time_rules: Dictionary = {}
	var in_match := false                 # 已开局(拒绝加入;成员转连 worker 后房**仍保留**,见 on_peer_left)
	var worker_port: int = 0              # 本房拉起的大乱斗 worker 端口(关房时归还)
	# worker 进程的 pid(拉起成功后由 RoomManager 登记;0 = 拉起中 → 判"没结束")。理由见 Room.worker_pid
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超龄清理用,与 Room.created_at 同形)
	# 开局那一刻冻结的名单 [{role:int, name:String}](理由见 Room.roster 的注释)
	var roster: Array = []

var royale_rooms: Dictionary = {}   # code -> RoyaleRoom


# 3v3 房。与 `Room`/`RoyaleRoom` **并列的第三种房**,三张表并存且**互相拒斥**(见 team_create 的守卫)。
# 多出来的是 `team_of`(role → 队号):队伍**不由服务器推导** —— role 号因"退出留空洞、最小空闲号
# 复用"而不连续,玩家自己点选边;未选边的 role **不在表里**(不在任何一队,也不能开局)。
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
	# worker 进程的 pid(拉起成功后由 RoomManager 登记;0 = 拉起中 → 判"没结束")。理由见 Room.worker_pid
	var worker_pid: int = 0
	var created_at := 0.0
	# 开局那一刻冻结的名单 [{role:int, name:string}](理由见 Room.roster 的注释)
	var roster: Array = []

var team_rooms: Dictionary = {}   # code -> TeamRoom

# 回局凭据表(阶段 2-B)。★ 它**独立于房对象**:房被拆除时凭据要不要跟着消失,由
# `teardown_room` **显式**决定(`rejoin.drop_port`),而不是由"房对象还在不在"隐式决定
# —— 回局的查询要在大厅侧活过拆除(见 RejoinRegistry 的类头)。三个房类原先各有一份
# `tokens` 字段,随 Task 4 一起删除:同一件事只留一处记录。
var rejoin := RejoinRegistry.new()


# ── 3v3 的**纯判据**(静态:`-s` 可测;RPC handler 与 RoomManager 都调它们,判据只有这一份)──
# 入参形状统一是 `{1: [role, …], 2: [role, …]}`(`_by_team()` 造),别在别处另算一遍。

# 两队是否都满员(满 6 人才允许开局)。★ 4v2 也算 6 人,但那不是 3v3。
static func team_ready(by_team: Dictionary, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(1, []) as Array).size() == size \
			and (by_team.get(2, []) as Array).size() == size

# 该队还能不能再进人
static func team_can_join(by_team: Dictionary, team: int, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(team, []) as Array).size() < size

# 最小空闲 role 号(有人退房留下的空洞会被**复用**,与 royale 的分配同款)。
# ★ 不能写成"人数 + 1":那是"编号恒连续"的假设,房里有 {1,3} 时按人数推会算出 3 —— 撞上仍在房里
#   的高号玩家,同一个 role 双份占用(自检 B1 就是这一脚)。判据收在这里,`team_join` 只调它。
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
	# ★ 3v3 **只接五条**:`team_create/join/pick/leave/list` 是房间账本的事;
	#   `team_start_requested`(**第六条**)归 RoomManager(它要拉 worker)—— 与大乱斗逐字同款的分工
	#   (royale_list 在本类、royale_start 在 RoomManager)。接进来 = 同一件事有两处实现。
	NetBusExt.team_create_requested.connect(team_create)
	NetBusExt.team_join_requested.connect(team_join)
	NetBusExt.team_pick_requested.connect(team_pick)
	NetBusExt.team_leave_requested.connect(team_leave)
	NetBusExt.team_list_requested.connect(team_list)
	# 回局(阶段 2-B):上行是"我这间房还让我回吗" —— 判据与答复都在本类(它持有凭据表)。
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

# 房间列表的**纯构造**(不含发送)。★ 抽出来是为了可测:探针没有对端,`NetBus.reply` 会静默
# 跳过 → 列表内容**观测不到**(与"拒绝为什么看副作用"同一个理由)。
# ★ `started`(= 对局中)的房**照列**:第三人要看得见它(用户裁定),而"进不去"由 `join_room`
#   那一侧的 `started` 守卫保证 —— 可见性与拒绝入房是同一件事的两半,缺一条就是"看不见"或"进得去"。
# ★ 对局中那一行的名单取**冻结的那份**:`players` 已空、`_peer_names` 已擦,读它们只会得到
#   "玩家/玩家"这种退化读数。
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
		arr.append({"code": code, "players": count, "names": names, "in_match": room.started})
	return arr


# 刷新房间列表:回当前所有非空房间(号码 + 人数 + 在房玩家昵称;人数≥2 为已满,客户端据此禁用/排序)。
func on_list_rooms(caller: int) -> void:
	NetBus.reply(caller, "room_list", room_list_payload())

func _generate_code() -> String:
	return "%04d" % (randi() % 10000)

# 把"开局那一刻在房里的名单"冻进房记录(role + 昵称快照)。
# ★ 谁调:RoomManager 在**每一处开局**调一次(`_start_match` / `royale_start` /
#   `royale_start_ai` / `team_start`)—— 那是"这一局有哪些人"唯一确定的时刻。
# ★ 为什么是快照而不是"读时现算":成员转连 worker 时会**陆续断开大厅**(`on_peer_left`),
#   而那时 `players` 会被清空、`_peer_names` 会被擦掉;对局中的房要在列表里显示名单,
#   就只能靠这份冻结的副本。名单错了不报错,只会让第三人看到"玩家, 玩家"。
func freeze_roster(room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)),
				"name": str(_peer_names.get(pid, "玩家"))})
	room.roster = out

# 一次性会话令牌(16 位 hex)。★ 旧 Godot 的 `randi()` 是 32 位,拼两次取 16 hex 得 64 位熵 ——
# 够防"误顶替"(同网段知道房号的人猜不中),**不防**恶意爆破(本设计不承担反作弊,见 spec §2)。
# ★ 必须是**两段 `%08x`**,不能写成 `"%016x" % ((randi() << 32) | randi())`:后者拼出的 64 位数
#   会**越过 int64 正半区**,而 Godot 的 `%x` 对负数是带符号打印(首个 digit 前多一个 `-`、只印
#   15 位 hex)。实测 12 次抽样里 8 次落在负半区(其中 7 次长度 17,另 1 次长度 16 但带 `-`)——
#   既不符"16 位 hex"的契约,又多出一个非 hex 字符(熵也少 1 位)。`randi()` 的返回值恒在
#   [0, 2^32) 内,两段 `%08x` 各自补零到 8 位,拼起来恒为 16 位 hex
#   (2 万次抽样:长度全 16、字符全在 [0-9a-f]、无重复)。
static func new_token() -> String:
	return "%08x%08x" % [randi(), randi()]

# 该 peer 现在**真的**能收包吗?
# ★ 2026-09-17 换了判据:以前读 `multiplayer.get_peers()`,实测它把"ENet 层已断、peer_map 还没
#   收敛"的 peer 仍报为在线(随连接/断开信号更新,比 ENet 的真实状态晚一拍)→ 判早了等于没判,
#   于是只能靠"延后一帧/再等一帧"躲窗口(那些 call_deferred/await 仍保留:它们同时还兜住
#   「刚连上、还没 CONNECT」那一档)。现在改读 **ENet peer 自己的 state**(`NetBus.is_peer_live`),
#   拆 peer 时它当场就变,不滞后 —— 这才是那条 `Unable to send packet on channel 0` 的正解。
func is_peer_online(peer_id: int) -> bool:
	return multiplayer.has_multiplayer_peer() and NetBus.is_peer_live(peer_id)

func create_room(caller: int) -> void:
	# 三路互斥(自检 L5;3v3 于 2026-09-18 成为第三种房):同一个客户端同时挂两种房会收到
	# **双重 go_match** 互相覆盖,而旧房无人认领 → 幽灵房(**端口永不归还**)。
	# ★ 互斥必须**双向**:本函数(1v1 入口)判 team;`team_create`/`team_join` 反判 1v1 —— 只加
	#   一头就是"从 1v1 房直接开 3v3 房"。四个建/加入入口(1v1 create/join、royale create/join、
	#   team create/join)每一个都要判另外两种,**漏掉 join 那半边等于把洞留在了 join 上**。
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再创建 1v1 房间")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再创建 1v1 房间")
		return
	if _in_1v1_room(caller):
		# 同 join_room:已在 1v1 房里不许再建,否则旧房无人认领变幽灵房(且玩家会收到双重 room_created)。
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
		# 已在某个 1v1 房里就拒绝加入(含「加入自己刚建的房」:房主本就在 room.players 里,
		# 不拦会被 append 第二遍、并把 player_role[caller] 从 1 覆盖成 2 → 同一个 peer 同时占
		# 两个 role 的退化对局,worker 侧 peer_by_role 两个 role 指同一 peer,输入只喂得到 role 1)。
		# 也顺带堵住「在 A 房还去加 B 房」留下的幽灵房。
		# 正常流程不受影响:大厅页的「返回」与所有超时兜底都走 NetBus.stop() 断连,
		# 断开即触发 on_peer_left 清房,重连后已不在任何房里。
		NetBus.reply(caller, "server_message", "你已经在房间里了")
		return
	var room: Room = rooms[code]
	if room.started:
		# 对局中(worker 已拉起):成员已转连对局,**照列在列表里但进不去**。
		# ★ 文案不能再说"房间已满":房里可能只剩 1 人在线(对手掉线 / 自己还没转连),那是假话,
		#   而且「房间已满」会命中大厅页 `matchmaking._on_server_message` 的**自动刷新**分支 ——
		#   刷新对这一个房毫无意义(它本来就该一直在列表里)。三模式文案**逐字统一**。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if room.players.size() >= 2:
		NetBus.reply(caller, "server_message", "房间已满")
		return
	if royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在大乱斗房间,请先退出再加入 1v1 房间")
		return
	if _in_team_room(caller):
		# 与 create_room 同一理由,只是发生在**加入**这一半:在 3v3 房里的人去加 1v1 房会同时挂两张表
		NetBus.reply(caller, "server_message", "你已在 3v3 房间,请先退出再加入 1v1 房间")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	print("房间 %s 加入(peer=%d)" % [code, caller])
	NetBus.reply(caller, "room_joined", 2)
	# 配对完成:交给 RoomManager 拉 worker + 发 go_match(它持有 launcher)。用信号而非直调 ——
	# 那是本类与 RoomManager 之间唯一的「反向」需求,信号把它变成单向。
	pairing_ready.emit(room)

func on_peer_left(peer_id: int) -> void:
	_peer_names.erase(peer_id)
	for code in rooms.keys():
		var room: Room = rooms[code]
		if not room.players.has(peer_id):
			continue
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
		# 关房条件:**只有"还没开局"的房才因空而关**。
		# ★★ 对局中(`started`)的房**不拆**(2026-09-21):客户端转连 worker 时会**全部**断开
		#   大厅,拆了它就再也不会出现在列表里 —— "看得见"与"回局"两件事都要求它活到对局结束。
		#   回收改由 `RoomManager._reclaim_finished_matches` 按"**worker 进程还在不在**"判(精确)。
		# ★ 这里**不再发**"配对已取消(对手离开)"那句提示:房没有被取消,那句话会是假的。
		#   真出问题(对手根本没连上 worker)由客户端自己的 12s 转连兜底 / 25s claim 兜底收尾。
		# ★ 代价照实登记(见设计 §2.4):双方都在 go_match 后立刻消失时,那一个 worker 与那一个
		#   端口会白占到 2h 超龄清扫为止;玩家不会卡住。
		if room.started:
			continue
		if room.players.is_empty():
			teardown_room(room)   # 延迟归还端口(worker 会自己退;见 WORKER_PORT_REUSE_DELAY)
	# 大乱斗房:掉线即离房(未开局的空房才关闭;房主掉线转移;开局后成员转连 worker 断开大厅属正常流转)
	for rcode in royale_rooms.keys():
		var rr: RoyaleRoom = royale_rooms[rcode]
		if not rr.players.has(peer_id):
			continue
		rr.players.erase(peer_id)
		rr.player_role.erase(peer_id)
		# ★ 对局中(`in_match`)的房**不拆**(2026-09-21):成员转连 worker 时会全部断开大厅,
		#   拆了就再也不会出现在列表里。回收改由 `_reclaim_finished_matches` 按"worker 进程还在不在"判。
		#   ★ 这里**不再发**那句"配对已取消"式的提示(与 1v1 同款理由:房没有被取消)。
		if rr.in_match:
			continue
		if rr.players.is_empty():
			# 大乱斗按默认一局时长给更长的回收延迟(远长于 1v1,自检 M2);已知边界见
			# WorkerLauncher.ROYALE_PORT_REUSE_DELAY 的常量注释
			teardown_room(rr)
		else:
			if rr.host_peer == peer_id:
				rr.host_peer = rr.players[0]
				print("大乱斗房 %s 房主转移 → peer %d" % [rcode, rr.host_peer])
			# ★ 已开局的房**不广播等待室状态**(既有理由:成员正在转连 worker,发给它们必然踩
			#   "max channels: 0" 且包丢)。这一条 `if` 现在永远为真(in_match 已在上面 continue),
			#   但**保留**它:它是那件事的守卫,不是死代码 —— 删了会让后来者以为"开局后也可以广播"。
			if not rr.in_match:
				_broadcast_royale_state(rr)
	# 3v3 房:与大乱斗逐字同款(掉线即离房;空房关闭;房主掉线转移;开局后成员转连 worker 断开大厅
	# 属正常流转)。★ **这一段不在 brief 的代码块里,但没有它 3v3 房会漏两处**:
	#   ① 等待期有人关掉客户端(或踢网线)→ 该 peer 永久留在 `players` 里,房间列表显示幽灵人数、
	#      `host_peer` 可能指向死人 → **这个房再也不可能凑齐 6 人开局**,也没人认领;
	#   ② 开局后 6 人转连 worker 会**全部**触发本函数 → 那时若不摘人,`players` 会一直显示 6 个
	#      早已不在大厅的 peer(列表人数造假),`host_peer` 也可能指向死人。
	# ★ 2026-09-21 订正:本条原先写的是「若这里不摘房,worker_port 直到 sweep 的 2h 超龄才归还」
	#   —— 房现在是**刻意不拆**的(对局中的房必须活到对局结束,见下面那条 `if tr.in_match`,
	#   否则"看得见"与"回局"都无从谈起),端口归还改由回收梯按 **worker 进程活性**判(设计 §2.4)。
	#   本循环剩下的职责是 ①② 里的"摘人/转移房主",不是"拆房"。
	for tcode in team_rooms.keys():
		var tr: TeamRoom = team_rooms[tcode]
		if not tr.players.has(peer_id):
			continue
		tr.players.erase(peer_id)
		tr.player_role.erase(peer_id)
		# 该 role 从队伍表里摘掉(与 team_leave 同款:role 号会被下一个加入者复用)
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
			# 已开局的房不广播等待室状态(与 royale 同一理由:成员正在转连 worker,发给它们
			# 只会踩 "max channels: 0" 并丢包,等待室界面也已不存在)
			if not tr.in_match:
				_broadcast_team_state(tr)

# ── 大乱斗房间:建房/加入(邀请码)/离开/列表/房主开局 ──

# 房内全员广播实时状态(等待室 UI 刷新)。
# 延到帧末再发:调用点常在「刚有人断开」的路径上(on_peer_left),此时其余成员的连接状态
# 可能还没收敛 —— 同步发会踩 is_peer_online 注释里那个窗口(报 channel 错误 + 丢包)。
func _broadcast_royale_state(rr: RoyaleRoom) -> void:
	_flush_royale_state.call_deferred(rr)   # 体内再等一帧,见该函数的注释


func _flush_royale_state(rr: RoyaleRoom) -> void:
	# ★ 等**下一帧**再发(而非本帧末):本函数的调用点几乎都在"刚有人断开"的路径上(on_peer_left),
	#   而此时其余成员的断开信号可能还没被 MultiplayerAPI 处理 —— get_peers() 仍把已断的 peer
	#   报为在线(实测滞后超过一帧),同步发/帧末发都会踩 "max channels: 0" 且**包会丢**。
	#   多等一帧只是等待室名单刷新晚一帧,无副作用。
	await get_tree().process_frame
	# ★★ 真正发送前**再判一次开局**(调用点那层的 in_match 守卫只挡住"排队时已开局"的情况):
	#    本函数是 call_deferred + 再等一帧,从"排队"到"发送"之间房间完全可能已经开局 ——
	#    开局那一刻正是成员集体转连 worker、陆续断开大厅的窗口,发给他们必然打
	#    "max channels: 0" 且包丢(实测:6 人局开局后瞬间 5 条)。等待室此刻也已不存在,
	#    这份状态广播本来就没人要了。
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
			# ★ 每个 peer 送**他自己那一份**:多带一个 `your_role`。等待室 UI 靠它判
			#   「(我)/(房主)」—— 原先让客户端按**昵称**反查,两人同名(默认都叫 Anon)时
			#   必然匹配到先出现的那个 → 高亮错行、房主看不到开局按钮。
			#   role 本来就是服务器权威分配的,不必让客户端去猜。
			var mine := state.duplicate()
			mine["your_role"] = rr.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "royale_room_state", mine)

func royale_room_of(caller: int) -> RoyaleRoom:
	for r in royale_rooms:
		if (royale_rooms[r] as RoyaleRoom).players.has(caller):
			return royale_rooms[r]
	return null

# 该 caller 是否已在某个 1v1 房间(大乱斗/1v1 互斥,自检 L5)
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
		# 同 join_room:对局中照列但进不去;文案三模式逐字统一(见那里为什么不能说"房间已满")。
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
		# 「退出房间」按钮**不断开大厅 peer** → on_peer_left 不会为它触发;房间随即从注册表摘除,
		# 而 sweep / on_peer_left 都只遍历注册表 → 之后**再无任何路径**能归还本房端口。
		# 故与其他大乱斗拆除路径同法归还,并同样走大乱斗那条更长的复用延迟。
		# ★ 对局中不拆(与 on_peer_left 同款):否则"看得见"与"回局"都没了。
		teardown_room(rr)
	else:
		# ★ 房主转移那一行必须带 `not rr.players.is_empty()`:对局中的房可能**一个人都不在线**
		#   (全体转连走了),而 `rr.players[0]` 在空数组上会**越界报错**(静默改行为的典型)。
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]
		# 已开局的房不广播等待室状态(与 on_peer_left 同一理由)
		if not rr.in_match:
			_broadcast_royale_state(rr)

# 公开房间列表的**纯构造**(理由同 room_list_payload:无对端时 reply 静默跳过 ⇒ 不抽出来
# 探针观测不到)。★ 只列**公开**房;`in_match` 的房**照列**(第三人要看得见),未开局的空房
# 仍不列(那是幽灵房)。
func royale_list_payload() -> Array:
	var arr: Array = []
	for code in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[code]
		if not rr.is_public:
			continue
		if rr.in_match:
			var dn: Array = []
			for e in rr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": code, "players": rr.roster.size(), "max_players": rr.max_players,
					"names": dn, "in_match": true, "beta": rr.beta})
			continue
		if rr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in rr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names, "in_match": false, "beta": rr.beta})
	return arr


func royale_list(caller: int) -> void:
	# 判活同 NetBus.reply:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	# 本节点(NetBusExt)没有自己的 reply 助手 —— 判据是**跨节点的单一来源**(NetBus.is_peer_live),
	# 所以这里显式判一次;大厅里其余 NetBusExt 站定走的是 `is_peer_online` 包一层。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload())

#  精确且不需要任何特例函数。见 server_main.gd 文件头。)

# AI 补位用的 role 号:取 1..max_players 内**人类未占用**的最小空闲号。
# 不能用「成员数 + 1 + i」——那是「编号恒连续」的假设;有人退出留空洞时(如真人 {1,3}),
# 按人数推出来的 AI 号会撞上仍在房里的高号真人(3 号既是真人又是 AI)→ 同 role 双份玩家、
# 且 worker 侧的「人类 claim 数」算术跟着失真(自检 B1)。
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

# ── 3v3 房间:建房/加入/选边/离开/列表(与 1v1、大乱斗**三路互斥**)──

# 某 role 的队号;未选边 → 0
func _team_of(tr: TeamRoom, role: int) -> int:
	return int(tr.team_of.get(role, 0))

# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)
func _by_team(tr: TeamRoom) -> Dictionary:
	var out := {1: [], 2: []}
	for role in tr.team_of:
		var t := int(tr.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


# 这个房能不能开局(RoomManager.team_start 调;**对外的公开口** —— 别让它去读 `_by_team`)。
func team_room_ready(tr: TeamRoom) -> bool:
	return team_ready(_by_team(tr))


func team_room_of(caller: int) -> TeamRoom:
	for c in team_rooms:
		if (team_rooms[c] as TeamRoom).players.has(caller):
			return team_rooms[c]
	return null


# 该 caller 是否已在 3v3 房间里。★ 三条路径互斥要**双向**判:本函数给 1v1/大乱斗的建/加入入口用,
# `_in_1v1_room` / `royale_room_of` 给本节的入口用 —— 只加一头会出现"从 1v1 房直接开 3v3 房"。
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
		# 同 join_room / royale_join:文案三模式逐字统一。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
	if tr.players.size() >= TEAM_ROLES:
		NetBus.reply(caller, "server_message", "房间已满(6 人)")
		return
	if not tr.is_public and invite.strip_edges() != tr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
	# role = 最小空闲号(与 royale 同款:**不重排**,有人退会留空洞 → 队伍表必须显式下发)。
	# 判据在 `team_next_role`(静态,`-s` 可测;按人数推的写法在"有人退过"的房里必错)。
	var role := team_next_role(tr.player_role.values())
	tr.players.append(caller)
	tr.player_role[caller] = role
	# ★ 进房**不自动分队**:3v3 的规则是玩家自己选边(用户裁定)。未选边 = team_of 里没有该 role,
	#   等待室会把他列在"未选边"那一档。
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
	# 把该 peer 的 role 从队伍表里摘掉(role 号会被下一个加入者复用)
	for r in tr.team_of.keys():
		if not tr.player_role.values().has(int(r)):
			tr.team_of.erase(r)
	if tr.players.is_empty() and not tr.in_match:
		# ★ 「退出房间」按钮**不断开大厅 peer** → on_peer_left 不会为它触发;房间随即摘除,
		#   而 sweep / on_peer_left 只遍历注册表 → 之后再无路径归还端口(与 royale_leave 同款坑)。
		teardown_room(tr)
	else:
		# ★ 同 royale_leave:对局中的房可能一个人都不在线,`tr.players[0]` 之前必须判空。
		if tr.host_peer == caller and not tr.players.is_empty():
			tr.host_peer = tr.players[0]
		if not tr.in_match:
			_broadcast_team_state(tr)


# 公开 3v3 房间列表的**纯构造**(与 royale_list_payload 逐字同款,`max_players` 取 TEAM_ROLES)
func team_list_payload() -> Array:
	var arr: Array = []
	for c in team_rooms:
		var tr: TeamRoom = team_rooms[c]
		if not tr.is_public:
			continue
		if tr.in_match:
			var dn: Array = []
			for e in tr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": c, "players": tr.roster.size(), "max_players": TEAM_ROLES,
					"names": dn, "in_match": true, "beta": tr.beta})
			continue
		if tr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in tr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": c, "players": tr.players.size(),
				"max_players": TEAM_ROLES, "names": names, "in_match": false, "beta": tr.beta})
	return arr


func team_list(caller: int) -> void:
	# 判活同 royale_list:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "team_rooms", team_list_payload())


# ── 回大厅后回局(spec §3.4 路径乙)──
# 客户端在自己的大厅页上**点自己那间房**(对局中的房照常列在列表里,对别人点它只会被
# `join_room`/`*_join` 那句「该房间的对局已进行中,无法加入」拒掉)。**应答复用 `go_match`**
# (方法表一个字不动),于是客户端那条"连 worker → 认领 role → 进对局场景"的路与首次进场
# **逐字同一条**。
# ★ 这里**不判对局状态**("你还在宽限期吗"只有 worker 手里的 `_grace` 知道),只判两件事:
#   凭据对不对得上、以及**这一局的 worker 还在不在** —— 后者防止把一个客户端送到一个已经结束、
#   端口可能已被复用给别的对局的地址上。★ "晚了"的那一档(认领时该 role 已不在宽限期)由
#   worker 的 `_on_reclaim` 判并踢连接,客户端会回到大厅页并看到失败提示(路径乙的已知边界)。
# ★ 判据本体是**纯函数**(`RejoinRegistry.decision`):四种组合在 `-s` 冒烟里逐个钉住,
#   本函数只做"查 → 判 → 发",不在这里再写一遍 if/else(那正是漂的成因)。
func on_rejoin_request(caller: int, code: String, token: String) -> void:
	var now := Time.get_ticks_msec()
	var e := rejoin.lookup(token, now)
	var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))
	var why := RejoinRegistry.decision(e, code, alive)
	if why != "":
		# ★ worker 已经退了 → 这份凭据再也不会成立,当场清掉:留着它只会让**下一个**请求
		#   再走一遍同样的拒绝。
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
	# ★ 等**下一帧**再发(理由与 _flush_royale_state 逐字相同):调用点几乎都在"刚有人断开"的路径上,
	#   此刻其余成员的 ENet 状态可能还没收敛 —— 同步发/帧末发都会踩 "max channels: 0" 且包会丢。
	# ★ 真正发送前再判一次 `in_match`:从"排队"到"发送"之间房间完全可能已经开局,而开局那一刻
	#   正是成员集体转连 worker、陆续断开大厅的窗口(等待室此刻也已不存在)。
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


# ── 房间拆除的**单一收口** ──
# 三种形态:
const TEARDOWN_DELAYED := 0   # 正常关房:worker 会自己退 → **延迟**归还端口(防立刻复用撞车)
const TEARDOWN_KILL := 1      # 僵尸清扫:worker 还活着占着端口 → 强杀 + **立即**回收
const TEARDOWN_ABORT := 2     # 拉起失败:worker 根本没起来 → **立即**归还(不必延迟,也无从杀)

# 全部拆除路径都必须走它。理由不是"整洁":本层为「端口泄漏」这**同一个**失败模式补过三次
# (on_peer_left 空房分支 / royale_leave 空房分支 / ai_duel 摘房前的手动释放),散着写就还会漏
# 第四次。收口后"新加一条拆除路径"这件事本身不可能漏 —— 没有第二条路可走。
# `tests/room_sweep_smoke` 有断言钉住:端口归还与注册表删除只能出现在本函数体内。
#
# mode               三种形态,见下方 TEARDOWN_* 常量(默认 DELAYED)
# msg                发给房内玩家的 server_message(空串=不发)
# disconnect_peers   true=立刻断开房内玩家(清扫路径要;正常关房由 peer_left 自然收尾)
# 端口延迟分**三档**(2026-09-18 3v3 落地,由二分改三态):
#   1v1=WORKER_PORT_REUSE_DELAY(120s,≥ 断线宽限期);大乱斗=ROYALE_PORT_REUSE_DELAY(360s);
#   3v3=TEAM_PORT_REUSE_DELAY(360s,一局比 1v1 长得多 —— 三局两胜 × 9 杀,与大乱斗同档)。
# ★ 别把 3v3 并回 120s:那条线是"**短于或等于**断线宽限期会让重连的客户端连到**别的局**"的老坑
#   (1v1 从 30 → 120 的教训,见 WorkerLauncher 顶部的常量注释)。
func teardown_room(room, mode: int = TEARDOWN_DELAYED, msg: String = "",
		disconnect_peers: bool = false) -> void:
	# ★ 三态(2026-09-18):原先是 `is_royale` 二分,3v3 是第三个模式 → 端口延迟与注册表各多一档。
	#   ★ 判据用 `is` 而不是 `room.code` 撞库:三张表的房号空间**重叠**(都是 `_generate_code()`
	#   的 4 位号),按号码反查是"同一个号在三张表里各有一份"的静默错拆。
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
	# ★ 这一局的凭据随房一起作废:房都拆了,worker 要么已经退了、要么马上会被杀,留着凭据
	#   只会让回局把客户端送到一个已经不属于它的端口上(而且**没有一行报错**)。
	# ★★ 键是 **worker 端口**(`port`,上面刚从 `room.worker_port` 取的那一份),**不是
	#   `room.code`**(2026-09-21 修):三张注册表的房号空间重叠,按 code 作废会误伤**同号**的
	#   另一间房里那位玩家的凭据 —— 与上面那一行 `is` 判定是**同一个坑**(同一段注释里就写着
	#   "别拿 room.code 去三张表里撞库",这里原先自己踩的就是它)。详见 RejoinRegistry.drop_port。
	var ntk := rejoin.drop_port(port)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
	if disconnect_peers:
		for peer_id in peers:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)

# 延迟归还 worker 端口:给旧 worker 留足退出时间,防止端口被立刻复用导致串线。
# delay 由 `teardown_room` 按房型给,三档(与那里同一份口径,别只列两档):
#   1v1=WORKER_PORT_REUSE_DELAY(120s)/ 大乱斗=ROYALE_PORT_REUSE_DELAY(360s)/
#   3v3=TEAM_PORT_REUSE_DELAY(360s);默认值是 1v1 那一档。
# ★ 本方法留在 RoomManager 是因为它要 `await get_tree()` —— RefCounted 没有树(见 WorkerLauncher
#   类头);端口池本身在 launcher 里,这里只做"等够了再还"。
func _release_port_later(port: int, delay: float = WorkerLauncher.WORKER_PORT_REUSE_DELAY) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(delay).timeout
	launcher.release_now(port)
