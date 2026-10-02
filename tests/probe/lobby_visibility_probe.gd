extends Node

# 大厅侧「对局中的房:看得见、进不去」的服务端面场景探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
# 判据: 文本 `LOBBY VISIBILITY PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍
#       exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ★ `--quit-after 3600`(=60s @60fps)的取值依据:本探针**全部断言都在 `_ready` 里同步跑完**,
#   跑完自己 `quit()` —— 安全网**只在探针挂住时**才用得上。本仓的教训是"安全网给薄了会把跑得
#   慢读成功能坏了"(`tests/probe/brawl_rollback_probe.tscn` 用 3600 就跑不完,实测要 30000),
#   而这里没有任何等待(不 await、不开 socket、不拉子进程),故 3600 是"绝不可能耗尽"的量级。
#
# ═══ 为什么需要它 ═══
# ★ 本批改的是一组**闭环**:房在"客户端转连 worker"那一刻不再被拆(否则"看得见"无从谈起),
#   于是"房什么时候消失"从"有人断开"变成了"worker 退了"。三张注册表各一处判断,写错任何一处
#   都是**静默**的(房不死 = 端口与列表位永久占用;房早死 = 谁也看不见)。
# ★ 列表可见性与拒绝入房是**同一件事的两半**:房留着才会出现在列表里,而出现之后必须**进不去**。
#   只断言"列表里有它"会让一个"能点进去"的实现全绿 —— 那正是把第三人放进了别人的对局里。
#   ★★ 2026-09-21(回局入口批)把这句话**收窄**成「对局中的房**对无凭据者**一律拒绝」:
#   相①②③ 的断言本体一字不改(它们用的 `P_C` 就是那个无凭据的第三人),变的只是**它表达的那句话**;
#   而**补集那一半**(持凭据的本人那一行可点 ⇒ 点了回局)由相⑧咬住。
#   ★★ 故拒绝那一半用**非满房**造:1v1 房里 1 人 / 大乱斗 2 人(上限 8)/ 3v3 房里 2 人时,
#   唯一的拒绝理由只剩 `started` / `in_match` —— 用满房造会被「房间已满」喂绿(等于没验)。
# ★ 本探针建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径),房记录由探针手工摆:
#   本批的逻辑全在大厅进程内,不需要 socket、也不需要真 worker。
# ★ `NetBus.reply` 在"没有对端"时静默跳过 ⇒ 通过 RPC 应答观测的结果**读不到**;故列表抽成
#   `*_list_payload()` 纯构造(可直调)、拒绝看**副作用**(调用方没被 append 进 players)。
#   发送那一半由真链路探针覆盖(见设计 §6.4)。

const ROOM_1V1 := "9001"
const ROOM_ROYALE := "9002"
const ROOM_TEAM := "9003"
# 私密房那两间(相⑨;B1 甲案)。★ 房号与上面三间**不重号**是有意的:三张注册表的房号空间
# 本来就是重叠的(见 RejoinRegistry.drop_port 的注释),本相要判的是"谁的凭据",不是房号。
const ROOM_PRIV_ROYALE := "9004"
const ROOM_PRIV_TEAM := "9005"
# 相⑨ 用的假凭据(房号 = 它自己那一间的 code;`owns` 判的就是这个)
const TK_MINE := "tk-mine"       # → 大乱斗私密房
const TK_MINE_T := "tk-mine-t"   # → 3v3 私密房
const TK_OTHER := "tk-other"     # → **公开**房 9002(一份合法但不属于私密房的凭据)
const TK_STALE := "tk-stale"     # → 大乱斗私密房,但**已过期**
const P_A := 101     # 假 peer id:本探针不开 socket,这些数字只用来占位
const P_B := 102
const P_C := 103

# ★★ 断言计数:ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"** ——
#   helper/lambda 里出错会让调用方照常继续、判词照打(见 tests/lib/probe_base.gd 文件头)。
#   少跑一条就红 —— 这正是"ALL-OK 不等于全都跑过"那条纪律的落点。
#   ★ 改探针**必须**同步改这个数(每个任务的步骤里都写明当次的值)。
# ★ 本值随相的增加而变(Task 3 加 ②③ 共 16 条 → 24;Task 4 加 ④ 共 3 条 → 27;
#   阶段 2-B Task 5 加 ⑤⑥ 共 **4** 条 → **31**;阶段 2-B Task 6 加 ⑦ 共 **6** 条 → **37**;
#   阶段 2-B Task 7 加 ⑧ 共 **1** 条 → **38**)。
#   ★ 比 brief 的 30 多一条:第 ④ 条(走信号那条**接线**断言)—— brief 只列了三条直调 handler
#     的断言,而"connect 那行被删"这一档**三条都照绿**(见 `_phase_rejoin` 的函数头)。
#   ★ ⑧ 是**一条聚合**断言(内部三页逐页核对、失败时逐页点名),**不是三条** —— 相⑧要断的是
#     三页共用的**同一个**判据次序,而本探针的断言条数在本批约定为 38(见 Step 5)。
#   ★ 相⑨(B1 甲案:私密房只对本人列出,2026-09-29)加 **7** 条 → **45**。
#   ★ 相⑦c(大厅合一 Task 2:凭据自带模式,2026-10-03)加 **2** 条 → **47**。
const EXPECTED_CHECKS := 47

var _rm: Node = null
var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_rm = RoomManager.new()
	add_child(_rm)
	# ★ 关掉大厅自己的两条梯:本探针手工驱动(与 `match_host_hygiene_probe` 关 `_physics_process`
	#   同款)。不关的话跑到 30s 时回收梯会自动触发,把探针刚摆好的房收掉 —— 断言会在
	#   "什么错都没有"的情况下变红。
	_rm.set_process(false)
	_phase_1v1()
	_phase_royale()
	_phase_team()
	_phase_reclaim()
	_phase_rejoin()
	_phase_session_flags()
	_phase_own_row_clickable()
	_phase_private_own_room()
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY VISIBILITY PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY VISIBILITY PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# ── ① 1v1:房活过"全员转连 worker",且第三人**看得见、进不去** ──
func _phase_1v1() -> void:
	var r := LobbyRooms.Room.new()
	r.code = ROOM_1V1
	r.players = [P_A, P_B]
	r.player_role = {P_A: 1, P_B: 2}
	r.started = true
	r.worker_port = 29901
	r.worker_pid = 0        # 本相不涉及回收(相④才摆 pid)
	_rm.lobby.rooms[r.code] = r
	# ★ 名单必须在**开局那一刻**冻结:成员转连 worker 后会陆续断开大厅,`players` 会空、
	#   `_peer_names` 会被擦掉 —— 靠它们渲染的列表会退化成"玩家/玩家"。
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(r)
	_check(r.roster.size() == 2, "① 开局时名单被冻进房记录(2 条)")

	# 转连:两个成员都断开大厅
	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.rooms.has(ROOM_1V1), "① ★ 全员断开大厅后房**仍在**(看得见的前提)")
	_check(r.players.is_empty(), "① 房内在线名单已空(players 的语义仍是「此刻还连在大厅这个房里的人」)")

	# C 看列表:房照列、带 in_match 标记、名字来自**冻结的那份**
	var row := _find_row(_rm.lobby.room_list_payload(), ROOM_1V1)
	_check(not row.is_empty(), "① ★ 第三人能在列表里**看到**这个房(今天它会整个消失)")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "① 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"],
			"① ★ 名单取自冻结的那份(players/_peer_names 都已空),实得 %s" % str(row.get("names", [])))
	_check(not row.is_empty() and int(row.get("players", 0)) == 2,
			"① 列表显示 2 人(取自 roster,不是取值 0 的空 players)")

	# C 试图进房:必须被拒。★ 房里只放 1 人,让**唯一**可能的拒绝理由只剩 started
	r.players = [P_A]
	var before := r.players.size()
	_rm.lobby.join_room(P_C, ROOM_1V1)
	_check(r.players.size() == before and not r.players.has(P_C),
			"① ★ 第三人(**无凭据**)join_room 被拒(房里 1 人:唯一能拒它的就是 started)—— 补集那一半见相⑧")


# ── ② 大乱斗:同 ①(门控是 in_match,不是 started)──
func _phase_royale() -> void:
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = ROOM_ROYALE
	rr.host_peer = P_A
	rr.players = [P_A, P_B]
	rr.player_role = {P_A: 1, P_B: 2}
	rr.max_players = 8
	rr.in_match = true
	rr.worker_port = 29902
	rr.worker_pid = 0
	_rm.lobby.royale_rooms[rr.code] = rr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(rr)
	_check(rr.roster.size() == 2, "② 开局时名单被冻进房记录(2 条)")

	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.royale_rooms.has(ROOM_ROYALE), "② ★ 全员断开大厅后大乱斗房仍在")
	_check(rr.players.is_empty(), "② 房内在线名单已空")

	var row := _find_row(_rm.lobby.royale_list_payload(), ROOM_ROYALE)
	_check(not row.is_empty(), "② ★ 第三人能在列表里看到这个房")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "② 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"], "② 名单取自冻结的那份")
	_check(not row.is_empty() and int(row.get("players", 0)) == 2, "② 列表显示 2 人(取自 roster)")

	# ★ 非满房:2/8 —— 唯一能拒的理由就是 in_match
	rr.players = [P_A]
	var before := rr.players.size()
	_rm.lobby.royale_join(P_C, ROOM_ROYALE, "", false)
	_check(rr.players.size() == before and not rr.players.has(P_C),
			"② ★ 第三人(**无凭据**)royale_join 被拒(2/8 非满房:唯一能拒它的是 in_match)")


# ── ③ 3v3:同上(与大乱斗逐字同款,门控也是 in_match)──
func _phase_team() -> void:
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = ROOM_TEAM
	tr.host_peer = P_A
	tr.players = [P_A, P_B]
	tr.player_role = {P_A: 1, P_B: 2}
	tr.team_of = {1: 1, 2: 2}
	tr.in_match = true
	tr.worker_port = 29903
	tr.worker_pid = 0
	_rm.lobby.team_rooms[tr.code] = tr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(tr)
	_check(tr.roster.size() == 2, "③ 开局时名单被冻进房记录(2 条)")

	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.team_rooms.has(ROOM_TEAM), "③ ★ 全员断开大厅后 3v3 房仍在")
	_check(tr.players.is_empty(), "③ 房内在线名单已空")

	var row := _find_row(_rm.lobby.team_list_payload(), ROOM_TEAM)
	_check(not row.is_empty(), "③ ★ 第三人能在列表里看到这个房")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "③ 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"], "③ 名单取自冻结的那份")
	_check(not row.is_empty() and int(row.get("players", 0)) == 2, "③ 列表显示 2 人(取自 roster)")

	# ★ 非满房:2/6 —— 唯一能拒的理由就是 in_match
	tr.players = [P_A]
	tr.team_of = {1: 1}
	var before := tr.players.size()
	_rm.lobby.team_join(P_C, ROOM_TEAM, "", false)
	_check(tr.players.size() == before and not tr.players.has(P_C),
			"③ ★ 第三人(**无凭据**)team_join 被拒(2/6 非满房:唯一能拒它的是 in_match)")


# ── ④ 对局结束即回收:worker 进程还在 → 房不许动;worker 退了 → 房必须被回收 ──
# ★ 判据是"**worker 进程还在不在**":三种模式的 worker 都在对局结束时自己退,而任何按
#   "一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口与列表位)。
# ★ 反向那一半(**活的 pid 不回收**)不能省:只断言"死的会收"会让一个"见谁收谁"的实现全绿,
#   而那会把正在进行的对局连端口一起端掉。
# ★ 第三条(pid 还没登记)**同样不能省**:`worker_pid` 的登记发生在 `create_process` 成功
#   **之后**,把 0 判成"结束"会让开局那一瞬被自己的回收梯拆掉。
func _phase_reclaim() -> void:
	# 活的 pid:用**本进程自己** —— 它一定活着,不需要拉起任何子进程
	var live := OS.get_process_id()
	var r := LobbyRooms.Room.new()
	r.code = "9011"
	r.started = true
	r.worker_port = 29911
	r.worker_pid = live
	_rm.lobby.rooms[r.code] = r
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = "9012"
	rr.in_match = true
	rr.worker_port = 29912
	rr.worker_pid = 999999        # 本机上不该存在的 pid
	_rm.lobby.royale_rooms[rr.code] = rr
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = "9013"
	tr.in_match = true
	tr.worker_port = 29913
	tr.worker_pid = 0             # ★ 还没登记 pid(拉起中)→ **不得**被判成结束
	_rm.lobby.team_rooms[tr.code] = tr

	_rm._reclaim_finished_matches()
	_check(_rm.lobby.rooms.has("9011"), "④ ★ worker pid 活着(本进程)→ 房**不许**被回收")
	_check(not _rm.lobby.royale_rooms.has("9012"), "④ worker pid 已退 → 大乱斗房必须被回收")
	_check(_rm.lobby.team_rooms.has("9013"), "④ ★ pid 还没登记(拉起中)→ 不得判成结束")


# ── ⑤⑥ 回局判据在**生产 handler** 上的行为(不是只测那个纯函数)──
# ★ 为什么两半都要:纯函数测过了(`tests/smoke/rejoin_registry_smoke`),而 handler 里
#   "查 → 判 → 发"这三步的**接线**没测 —— 把 `lookup` 写成 `lookup(token, now + 一个很大的数)`
#   或把 `code` 传错,纯函数照样全绿。
# ★ 本探针**观测不到 go_match**(没有对端 → `NetBus.reply` 静默跳过),故这里能断言的是
#   拒绝路径的**副作用**(死 worker 时凭据被清)。**放行路径的真实发送**由真链路探针覆盖
#   (`tests/probe/rejoin_probe`),这条边界照实登记。
# ★★ ④ 那一条**不是**多余的:`NetBusExt.rejoin_requested → on_rejoin_request` 这一行**接线**
#   此前**零覆盖** —— 上面三条都是**直调 handler**,把 `_enter_tree` 里那行 connect 删掉,
#   它们照样全绿(handler 本体没问题),而生产里回局**永远失败且一行报错都没有**
#   (净的静默 no-op,与"RPC 挂错节点"同一类)。故第 ④ 条**走信号**(emit)而不直调:
#   能观测到副作用(凭据被清)就说明那行 connect 在。同款纪律的先例:`team_room_smoke` ⑥
#   「判据函数测对了 ≠ 生产调的是它」。
# ★ 拆除那一侧的归键(端口而非房间号)另有一个专属守卫:`tests/probe/rejoin_keying_probe.tscn`
#   ——「两间同号的房」那个病态输入在**真 teardown_room** 上跑,本相不重复造。
func _phase_rejoin() -> void:
	var now := Time.get_ticks_msec()
	# ① 房间号不符:拒绝,且凭据**不被**清(worker 还活着,值得让玩家重试一次)
	_rm.lobby.rejoin.grant("tk_x", "9021", 1, 29921, OS.get_process_id(), now)
	_rm.lobby.on_rejoin_request(P_C, "9999", "tk_x")
	_check(not _rm.lobby.rejoin.lookup("tk_x", now).is_empty(),
			"⑤ 房间号不符:拒绝但**不清**凭据(worker 还活着,能重试)")
	# ② worker 已退:拒绝 + **清掉**凭据(它再也不会成立)
	_rm.lobby.rejoin.grant("tk_y", "9021", 1, 29922, 999999, now)
	_rm.lobby.on_rejoin_request(P_C, "9021", "tk_y")
	_check(_rm.lobby.rejoin.lookup("tk_y", now).is_empty(),
			"⑥ ★ worker 已退:拒绝并把这份凭据当场作废(留着只会骗下一个请求)")
	# ③ 凭据根本不存在:拒绝,且不得凭空造出凭据
	_rm.lobby.on_rejoin_request(P_C, "9021", "tk_not_exist")
	_check(_rm.lobby.rejoin.lookup("tk_not_exist", now).is_empty(),
			"⑥ 未知 token:拒绝且不登记任何东西")
	# ④ 接线:同一件事**走信号**(emit)再验一次 —— 只直调 handler 时,`_enter_tree` 里那行
	#    `NetBusExt.rejoin_requested.connect(on_rejoin_request)` 被删也全绿(见函数头)。
	#    用"死 worker"那一档造可观测的副作用(与②同一手法)。
	_rm.lobby.rejoin.grant("tk_w", "9021", 1, 29923, 999999, now)
	NetBusExt.rejoin_requested.emit(P_C, "9021", "tk_w")
	_check(_rm.lobby.rejoin.lookup("tk_w", now).is_empty(),
			"⑥ ★ 信号接线在位(emit rejoin_requested 能落到生产 handler:connect 被删就红)")


# ── ⑦ 凭据判据的真值表(`PvpSession.can_rejoin_to()` / `clear_rejoin()`)──
# ★ 放在这个**场景**探针里而不是 `-s` 冒烟:`-s` 阶段 autoload 尚未实例化,而本仓已有教训
#   ——`-s` 脚本碰全局类要走 load()/get_script_constant_map() 那套绕法,为一个真值表不值得。
# ★ 这一条防的是"那一行看着可点、点了没用":`can_rejoin_to()` 少判一个字段(比如漏了房号),
#   列表里**别人那间对局中的房**也会变可点 —— 点下去发的是回局请求,而凭据里的房号对不上,
#   玩家看到的是"回局被拒"(一句与眼前那间房无关的话)。房号那一条就是为它立的。
# ★ `PvpSession` 的静态字段是**全局**的:本函数结束时必须**还原**自己摆过的值,
#   否则同一进程里后面的相会读到脏值(本探针是独立进程,但同仓的纪律如此)。
func _phase_session_flags() -> void:
	var keep := [PvpSession.token, PvpSession.worker_port, PvpSession.room_code, PvpSession.room_mode]
	PvpSession.token = "tk"; PvpSession.worker_port = 29901; PvpSession.room_code = "9021"
	PvpSession.room_mode = PvpSession.MODE_PVP
	_check(PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP), "⑦ 凭据齐 + 房号对上 → 这一行可点(回局)")
	_check(not PvpSession.can_rejoin_to("9999", PvpSession.MODE_PVP),
			"⑦ ★ 房号不符 → 不可点(防的是「别人那间对局中的房」也变可点,点下去只会收到一句无关的拒绝)")
	PvpSession.token = ""
	_check(not PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP), "⑦ token 缺 → 不可点")
	PvpSession.token = "tk"; PvpSession.worker_port = 0
	_check(not PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP), "⑦ worker_port 缺 → 不可点(连不回那一局)")
	PvpSession.worker_port = 29901; PvpSession.room_code = ""
	_check(not PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP), "⑦ room_code 缺 → 不可点(回局请求带不上房号)")
	PvpSession.room_code = "9021"
	# ⑦c(本批新增):**模式不同 ⇒ 不可点**。三张注册表的房号空间共用(同号共存是允许的),
	#   只看房号会让"我在 1v1 攒的凭据"把**同号的 3v3 房**判成"我的房" —— 点下去是回局请求,
	#   而大厅按凭据里的模式一查就知道不对,玩家收到一句与眼前那间房无关的拒绝。
	#   ★ 反向对照就在上面两条:**模式相同**时它必须仍然是可点的。
	_check(not PvpSession.can_rejoin_to("9021", PvpSession.MODE_TEAM),
			"⑦c 模式不同 ⇒ 不可点(同号房分属两张注册表)")
	_check(PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP),
			"⑦c 正向对照:模式相同 ⇒ 仍可点")
	PvpSession.rejoin = true
	PvpSession.clear_rejoin()
	_check(PvpSession.token == "" and PvpSession.worker_port == 0 \
			and PvpSession.room_code == "" and not PvpSession.rejoin,
			"⑦ ★ clear_rejoin() 必须把四个字段一起清(漏一个就是「那一行永远可点」)")
	PvpSession.token = keep[0]; PvpSession.worker_port = keep[1]; PvpSession.room_code = keep[2]
	PvpSession.room_mode = keep[3]


# ── ⑨ 私密房:**只对本人**列出(B1 甲案,2026-09-29)──
# 守的是什么:私密房此前一律 `continue` ⇒ 在私密房里打到一半按 ESC 回主菜单的玩家
# **列表里没有那一行**,回局入口整个不存在(而凭据其实还在他手里、大厅也会放行)。
# 现在改成「不是公开房 ⇒ 再看这份 token 的凭据是不是**这一间房**的」。
#
# ★★ 为什么必须有本相:这一条改动**只在「私密房 + 持凭据的本人」这个组合上**与从前不同,
#   而**既有每一相用的都是公开房与无凭据的第三人** ⇒ 判据写错时它们**全都照绿**。
#   四种真实错法各有各的假绿:
#     · 把门槛写成 `not is_public or not owns`(私密房永远不列)—— 相①②③ 照绿;
#     · 干脆去掉 `is_public` 那一句(私密房对**所有人**列出 = "私密"没了)—— 相①②③ 照绿;
#     · `owns` 恒真(谁的凭据都放行)—— 相①②③ 照绿;
#     · 只改了大乱斗、漏了 3v3 —— 相②③ 照绿(它们各测各的)。
#   ⇒ 下面 7 条把这几档逐个分开:无凭据 / 别人的凭据 / 本人的凭据 / 过期凭据 /
#     **正向对照**(公开房对无凭据者照列)/ 3v3 同款。
# ★ 正向对照那一条不是客套:没有它,一个"把两份载荷都改成 return []"的实现能过前五条。
func _phase_private_own_room() -> void:
	var now := Time.get_ticks_msec()
	# 两间私密房都设成**对局中**:凭据只在开局(worker 拉起成功)那一刻才发得出来,
	# 而"私密房 + 回局"这个组合本身就意味着这一局已经开打了。
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = ROOM_PRIV_ROYALE
	rr.is_public = false
	rr.max_players = 8
	rr.in_match = true
	rr.worker_port = 29904
	rr.roster = [{"role": 1, "name": "阿甲"}]
	_rm.lobby.royale_rooms[rr.code] = rr

	var tr := LobbyRooms.TeamRoom.new()
	tr.code = ROOM_PRIV_TEAM
	tr.is_public = false
	tr.in_match = true
	tr.worker_port = 29905
	tr.roster = [{"role": 1, "name": "阿甲"}]
	_rm.lobby.team_rooms[tr.code] = tr

	# 凭据:`owns` 只看 TTL,故过期那一份要把 `now_ms` 推到 TTL 之外(用真常量算,不写死数字)
	_rm.lobby.rejoin.grant(TK_MINE, ROOM_PRIV_ROYALE, 1, 29904, 12345, now)
	_rm.lobby.rejoin.grant(TK_MINE_T, ROOM_PRIV_TEAM, 1, 29905, 12345, now)
	_rm.lobby.rejoin.grant(TK_OTHER, ROOM_ROYALE, 1, 29902, 12345, now)
	_rm.lobby.rejoin.grant(TK_STALE, ROOM_PRIV_ROYALE, 1, 29904, 12345,
			now - int(RejoinRegistry.TOKEN_TTL_SECONDS * 1000.0) - 1)

	_check(_find_row(_rm.lobby.royale_list_payload(), ROOM_PRIV_ROYALE).is_empty(),
			"⑨ 私密房对**无凭据者**不列(第三人看不到 —— 「私密」这个语义本身)")
	_check(_find_row(_rm.lobby.royale_list_payload(TK_OTHER), ROOM_PRIV_ROYALE).is_empty(),
			"⑨ 私密房对**别人的**凭据不列(一份合法但不属于这一间的凭据;`owns` 的房号那半)")
	var mine := _find_row(_rm.lobby.royale_list_payload(TK_MINE), ROOM_PRIV_ROYALE)
	_check(not mine.is_empty(),
			"⑨ ★★ 私密房对**本人的**凭据**要列出来**(就是本条欠账:B1 之前一律不列 ⇒"
			+ " 私密房玩家按 ESC 回主菜单后没有那一行可点,回局入口整个不存在)")
	_check(not mine.is_empty() and bool(mine.get("in_match", false))
			and mine.get("names", []) == ["阿甲"],
			"⑨ 本人那一行与公开房同款(in_match=true、名单取自冻结的 roster)")
	_check(_find_row(_rm.lobby.royale_list_payload(TK_STALE), ROOM_PRIV_ROYALE).is_empty(),
			"⑨ 过期凭据不列(owns 走 lookup ⇒ 过期当不存在;凭据表的 GC 上界是"
			+ " RejoinRegistry.TOKEN_TTL_SECONDS)")
	_check(not _find_row(_rm.lobby.royale_list_payload(), ROOM_ROYALE).is_empty(),
			"⑨ 正向对照:**公开**房对无凭据者照列(没有这一条,一个『两份载荷都 return []』"
			+ "的实现能过上面五条)")
	_check(not _find_row(_rm.lobby.team_list_payload(TK_MINE_T), ROOM_PRIV_TEAM).is_empty()
			and _find_row(_rm.lobby.team_list_payload(), ROOM_PRIV_TEAM).is_empty(),
			"⑨ ★ 3v3 同款:私密房只对本人列出(只改大乱斗、漏改 3v3 = 静默半边)")

	# 收尾:本相往凭据表里塞了四份,后面的相/别的探针不该看见它们(表是共享的)
	for tk in [TK_MINE, TK_MINE_T, TK_OTHER, TK_STALE]:
		_rm.lobby.rejoin.drop_token(tk)


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}


# ── ⑧ 「对局中的房对**无凭据者**一律拒绝」的**补集**:持凭据者那一行**可点** ──
# ★ 相①②③ 断的是**服务端**那一半(无凭据的第三人 `join_room`/`*_join` 进不去),相⑧ 断的是
#   **客户端**那一半(持凭据的本人那一行可点 ⇒ 点它走回局)。两半合起来才是本任务那句
#   「对局中的房照列:自己的房可点(回局),别人的点不动」。
# ★★ 它守的是本任务**唯一的硬约束** —— 两个问句的**次序**:
#     ① 先问 `PvpSession.can_rejoin_to(code, mode)`(这是我的房吗 + 凭据还在吗)→ 可点;
#     ② 不是我的房,才轮到「`in_match` ⇒ disabled」那一档。
#   把次序写反(`btn.disabled = in_match` / `if in_match:` 先问对局中)时,自己那间房那一行被
#   `disabled` + `FOCUS_NONE` 收拾掉 ⇒ 回局这一档**连点都点不到**,而**一行报错都没有**
#   (症状只是"回到大厅后自己那间房是灰的,回不去")。
#   ★ 实测(2026-09-21):次序写反时,本探针**原有 37 条**断言、`lobby_row_probe` 的 24 条、
#     `room_sweep_smoke`、`team_room_smoke`、以及四个场景加载**全部照绿** —— 这一条是唯一咬得住的。
# ★ 页面**不入树**(与 `lobby_row_probe` 同一手法):`_ready` 一跑就会 `_request_list(...)` 去连大厅
#   (1v1 页默认云地址)⇒ 本探针不开任何 socket、也不碰用户的 7777。故手工摆好渲染函数要读的
#   两个成员(`_list_box` / `_status`),再直调那三个渲染函数。
# ★ 判"点不动"用的是 `Button.pressed` 上的**连接数**:`disabled` 只是观感,真正的"点了没有反应"
#   是**没有连任何 handler**(与 `lobby_row_probe` 同款)。
# ★ `PvpSession` 的静态字段是**全局**的:本函数结束时必须**还原**(同相⑦)。
func _phase_own_row_clickable() -> void:
	var keep := [PvpSession.token, PvpSession.worker_port, PvpSession.room_code, PvpSession.rejoin,
			PvpSession.room_mode]
	PvpSession.token = "tk"; PvpSession.worker_port = 29901; PvpSession.room_code = "9001"
	# 三页各喂三行:**9001 = 我的房**(凭据里的房号就是它,载荷仍标 in_match)、
	# **9002 = 别人的对局中的房**(同样是 in_match,凭据不是它的)、9003 = 普通未满房(正向对照)
	var rows_1v1: Array = [
		{"code": "9001", "players": 2, "names": ["阿甲", "bob"], "in_match": true},
		{"code": "9002", "players": 2, "names": ["阿甲", "bob"], "in_match": true},
		{"code": "9003", "players": 1, "names": ["阿甲"], "in_match": false},
	]
	var rows_n: Array = [
		{"code": "9001", "players": 2, "max_players": 8, "names": ["阿甲", "bob"], "in_match": true},
		{"code": "9002", "players": 2, "max_players": 8, "names": ["阿甲", "bob"], "in_match": true},
		{"code": "9003", "players": 1, "max_players": 8, "names": ["阿甲"], "in_match": false},
	]
	var bad: Array[String] = []
	var reasons: Array = [
			_own_row_reason("res://scenes/matchmaking.tscn", "_on_room_list", "1v1", rows_1v1,
					PvpSession.MODE_PVP),
			_own_row_reason("res://scenes/royale_lobby.tscn", "_on_royale_rooms", "大乱斗", rows_n,
					PvpSession.MODE_ROYALE),
			_own_row_reason("res://scenes/team_lobby.tscn", "_on_team_rooms", "3v3", rows_n,
					PvpSession.MODE_TEAM)]
	for r: String in reasons:
		if r != "":
			bad.append(r)
	PvpSession.token = keep[0]; PvpSession.worker_port = keep[1]
	PvpSession.room_code = keep[2]; PvpSession.rejoin = keep[3]
	PvpSession.room_mode = keep[4]
	# ★ 一条聚合断言(三页逐页核对,失败时逐页点名)—— 条数约定见 EXPECTED_CHECKS 的注释
	_check(bad.is_empty(),
			"⑧ ★ 三页:持凭据者自己那间房那一行**可点**(点它走回局)、别人的对局中的房仍点不动 —— 实得:%s"
			% ("三页全对" if bad.is_empty() else " / ".join(bad)))


# 渲染一页的房间列表,只判那一行;返回 "" = 全对,否则返回"页:哪个条件不成立"
# ★ `mode` = 本页所属模式(凭据判据 `can_rejoin_to(code, mode)` 要按页自己的模式过;
#   三张注册表的房号空间共用,不逐页设模式的话"我的房"在三页里都判不出来)。
func _own_row_reason(scene_path: String, fn: String, tag: String, rows: Array, mode: String) -> String:
	var p: Node = (load(scene_path) as PackedScene).instantiate()
	var box := VBoxContainer.new()
	var st := Label.new()
	p.set("_list_box", box)     # 不入树 ⇒ `_ready` 不跑 ⇒ 这两个成员还是 null,得手工摆
	p.set("_status", st)
	PvpSession.room_mode = mode
	p.call(fn, rows)
	var mine := _row_button(box, "9001")     # 我的房(房号与凭据一致)
	var other := _row_button(box, "9002")    # 别人的对局中的房(无凭据)
	var open_ := _row_button(box, "9003")    # 普通未满房(正向对照)
	var why := ""
	if mine == null or other == null or open_ == null:
		why = "行没画出来"
	elif mine.disabled:
		why = "自己那间房被 disabled(次序写反:先问了「对局中」⇒ 回局连点都点不到)"
	elif mine.pressed.get_connections().size() != 1:
		why = "自己那间房没接 handler(disabled 只是观感,不接 handler 才是真的点不动)"
	elif mine.focus_mode != Control.FOCUS_ALL:
		why = "自己那间房不吃键盘焦点"
	elif not other.disabled:
		why = "别人那间对局中的房**可点**了(凭据的房号那半判据漏了)"
	elif not other.pressed.get_connections().is_empty():
		why = "别人那间对局中的房接上了 handler"
	elif open_.disabled or open_.pressed.get_connections().size() != 1:
		why = "普通未满的房变得点不动了(判据写成了 `not mine` 之类 —— 正常加入被弄坏)"
	box.free()   # 两个成员不是 p 的子节点,p.free() 管不到它们(否则退出时报 orphan)
	st.free()
	p.free()
	return "" if why == "" else "%s:%s" % [tag, why]


func _row_button(box: Node, code: String) -> Button:
	for c in box.get_children():
		if c is Button and (c as Button).text.contains(code):
			return c
	return null
