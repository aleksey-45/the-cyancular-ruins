extends Node

# 大厅侧「对局中的房:看得见、进不去」的服务端面场景探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn
# 判据: 文本 `LOBBY VISIBILITY PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍
#       exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ★ `--quit-after 3600`(=60s @60fps)的取值依据:本探针**全部断言都在 `_ready` 里同步跑完**,
#   跑完自己 `quit()` —— 安全网**只在探针挂住时**才用得上。本仓的教训是"安全网给薄了会把跑得
#   慢读成功能坏了"(`tests/brawl_rollback_probe.tscn` 用 3600 就跑不完,实测要 30000),
#   而这里没有任何等待(不 await、不开 socket、不拉子进程),故 3600 是"绝不可能耗尽"的量级。
#
# ═══ 为什么需要它 ═══
# ★ 本批改的是一组**闭环**:房在"客户端转连 worker"那一刻不再被拆(否则"看得见"无从谈起),
#   于是"房什么时候消失"从"有人断开"变成了"worker 退了"。三张注册表各一处判断,写错任何一处
#   都是**静默**的(房不死 = 端口与列表位永久占用;房早死 = 谁也看不见)。
# ★ 列表可见性与拒绝入房是**同一件事的两半**:房留着才会出现在列表里,而出现之后必须**进不去**。
#   只断言"列表里有它"会让一个"能点进去"的实现全绿 —— 那正是把第三人放进了别人的对局里。
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
const P_A := 101     # 假 peer id:本探针不开 socket,这些数字只用来占位
const P_B := 102
const P_C := 103

# ★★ 断言计数:ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"** ——
#   helper/lambda 里出错会让调用方照常继续、判词照打(见 tests/lib/probe_base.gd 文件头)。
#   少跑一条就红 —— 这正是"ALL-OK 不等于全都跑过"那条纪律的落点。
#   ★ 改探针**必须**同步改这个数(每个任务的步骤里都写明当次的值)。
# ★ 本值随相的增加而变(Task 3 加 ②③ 共 16 条 → 24;Task 4 加 ④ 共 3 条 → 27)。
const EXPECTED_CHECKS := 27

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
			"① ★ 第三人 join_room 被拒(房里 1 人:唯一能拒它的就是 started)")


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
	_rm.lobby.royale_join(P_C, ROOM_ROYALE, "")
	_check(rr.players.size() == before and not rr.players.has(P_C),
			"② ★ 第三人 royale_join 被拒(2/8 非满房:唯一能拒它的是 in_match)")


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
	_rm.lobby.team_join(P_C, ROOM_TEAM, "")
	_check(tr.players.size() == before and not tr.players.has(P_C),
			"③ ★ 第三人 team_join 被拒(2/6 非满房:唯一能拒它的是 in_match)")


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


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}
