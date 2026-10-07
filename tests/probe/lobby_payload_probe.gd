extends Node

# 大厅**列表载荷形状**与 `room_map` 房主校验的服务端面探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
# 判据: 文本 `LOBBY PAYLOAD PROBE: ALL-OK`(不看退出码)。
#
# - 为什么需要它:房卡要吃 is_public / host / map / match_time / team_counts 五个键,
#   而"服务端给了但客户端没渲染"和"客户端渲染了但服务端没给"**都不报错** —— 只表现为
#   卡片上那一行空着。本探针钉服务端那一半。
# - 建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径);房记录由探针手工摆,
#   不需要 socket、不需要 worker(与 lobby_visibility_probe 相同机制)。
# - 断言计数:ALL-OK 只证明"没有一条断言失败",不证明"该跑的都跑过"(见 tests/lib/probe_base.gd
#   文件头)。少跑一条就红 —— 改本探针必须同步改这个数。
const EXPECTED_CHECKS := 24

const P_HOST := 201
const P_OTHER := 202

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


func _find(arr: Array, code: String) -> Dictionary:
	for r in arr:
		if typeof(r) == TYPE_DICTIONARY and str(r.get("code", "")) == code:
			return r
	return {}


func _ready() -> void:
	_rm = RoomManager.new()
	add_child(_rm)
	_rm.set_process(false)   # 关掉回收梯:不关的话跑到 30s 它会收掉探针刚摆好的房
	var lobby = _rm.lobby

	# 昵称只有经 `_peer_names` 才有 —— 探针直接塞(生产里由 on_lobby_name 写)
	lobby._peer_names[P_HOST] = "房主甲"

	# ── 1v1 ──
	var r1: LobbyRooms.Room = LobbyRooms.Room.new()
	r1.code = "9101"
	# - 用 append 而不是 `= [P_HOST] as Array[int]`:后者不是合法的 GDScript 转型写法,
	#   `players` 是 `Array[int]`,赋值一个裸 Array 会在运行时被拒。
	r1.players.append(P_HOST)
	r1.player_role[P_HOST] = 1
	lobby.rooms["9101"] = r1
	var p1 := _find(lobby.room_list_payload(), "9101")
	_check(int(p1.get("players", -1)) == 1, "1v1 载荷 players 仍是人数")
	_check(p1.get("is_public", null) == true, "1v1 载荷 is_public 恒 true(1v1 没有私密房)")
	_check(str(p1.get("host", "")) == "房主甲", "1v1 载荷 host = 建房者昵称(实得「%s」)" % str(p1.get("host", "")))
	_check(p1.has("map") and str(p1["map"]) == "", "1v1 载荷带 map 键且初值为空串")

	# ── 大乱斗 ──
	var rr: LobbyRooms.RoyaleRoom = LobbyRooms.RoyaleRoom.new()
	rr.code = "9102"
	rr.host_peer = P_HOST
	rr.players.append(P_HOST)
	rr.player_role[P_HOST] = 1
	rr.max_players = 6
	rr.is_public = false
	rr.match_time = 300
	lobby.royale_rooms["9102"] = rr
	var pr := _find(lobby.royale_list_payload(""), "9102")
	_check(pr.is_empty(), "私密房对无凭据者不列出(既有语义没被破坏)")
	# - 签名是 grant(token, code, role, worker_port, worker_pid, now_ms) —— 六个参数。
	#   worker_pid 传 0 = "启动中",与 `owns()` 无关(它只看 TTL,不看 worker 活性)。
	lobby.rejoin.grant("tk-probe", "9102", 1, 0, 0, Time.get_ticks_msec())
	var pr2 := _find(lobby.royale_list_payload("tk-probe"), "9102")
	_check(not pr2.is_empty(), "私密房对持凭据者列出")
	_check(pr2.get("is_public", null) == false, "大乱斗载荷 is_public 透出 false")
	_check(int(pr2.get("match_time", -1)) == 300, "大乱斗载荷 match_time 透出房间上的值")
	_check(str(pr2.get("host", "")) == "房主甲", "大乱斗载荷 host = host_peer 的昵称")

	# ── 3v3 ──
	var tr: LobbyRooms.TeamRoom = LobbyRooms.TeamRoom.new()
	tr.code = "9103"
	tr.host_peer = P_HOST
	tr.players.append(P_HOST)
	tr.players.append(P_OTHER)
	tr.player_role[P_HOST] = 1
	tr.player_role[P_OTHER] = 3
	tr.team_of[1] = 1
	lobby.team_rooms["9103"] = tr
	var pt := _find(lobby.team_list_payload(""), "9103")
	_check(pt.get("is_public", null) == true, "3v3 载荷 is_public 透出 true")
	_check(int(pt.get("max_players", -1)) == LobbyRooms.TEAM_ROLES, "3v3 载荷 max_players 仍是 TEAM_ROLES")
	var tc: Dictionary = pt.get("team_counts", {})
	_check(int(tc.get("1", -1)) == 1 and int(tc.get("2", -1)) == 0 and int(tc.get("0", -1)) == 1,
			"3v3 载荷 team_counts 数对了(A=1 / B=0 / 未选边=1;实得 %s)" % str(tc))

	# ── 已开局(in_match)的房:host 走开局那一刻冻结的 roster(2026-10-03 ③)──
	# - 为什么必须常驻:已开局的房**成员已转连 worker**,`players` 空、`_peer_names` 被擦
	#    ->  `host` 只能从 `roster` 里按 role 找(`_host_name_of(_room_host_role(房), roster)`)。
	#   此前**没有任何夹具**把 `in_match` 设成 true  ->  那条分支的 role 查错会**静默**
	#   (卡片显示「房主 玩家」),而"对局中的房照列"这条也一并没被验过。
	# - 房主 role **刻意非 1**、名单名**刻意与 `_peer_names` 不同**:host 若读错来源
	#   (读 `_peer_names` / 查错 role)必得「玩家」或「房主甲」,与期望的 roster 名不同  ->  红。
	var rrm: LobbyRooms.RoyaleRoom = LobbyRooms.RoyaleRoom.new()
	rrm.code = "9104"
	rrm.host_peer = P_HOST
	rrm.player_role[P_HOST] = 2          # 房主 role 非 1:逼着 host 去查 roster 里的**这个** role
	rrm.in_match = true
	rrm.roster.append({"role": 2, "name": "R开局名单甲"})
	rrm.roster.append({"role": 5, "name": "R开局名单乙"})
	lobby.royale_rooms["9104"] = rrm
	var prm := _find(lobby.royale_list_payload(""), "9104")
	_check(not prm.is_empty() and bool(prm.get("in_match", false)),
			"大乱斗:已开局的房**照列**(in_match=true 不被 continue 掉)")
	_check(str(prm.get("host", "")) == "R开局名单甲",
			"★ 大乱斗已开局房的 host 取自 roster 里该 role 的名字(实得「%s」)" % str(prm.get("host", "")))

	var trm: LobbyRooms.TeamRoom = LobbyRooms.TeamRoom.new()
	trm.code = "9105"
	trm.host_peer = P_HOST
	trm.player_role[P_HOST] = 4
	trm.in_match = true
	trm.roster.append({"role": 4, "name": "T开局名单甲"})
	lobby.team_rooms["9105"] = trm
	var ptm := _find(lobby.team_list_payload(""), "9105")
	_check(not ptm.is_empty() and bool(ptm.get("in_match", false)),
			"3v3:已开局的房**照列**(in_match=true 不被 continue 掉)")
	_check(str(ptm.get("host", "")) == "T开局名单甲",
			"★ 3v3 已开局房的 host 取自 roster 里该 role 的名字(实得「%s」)" % str(ptm.get("host", "")))

	# ── room_map:房主可写 ──
	lobby.on_room_map(P_HOST, "9102", "maps/demo.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "房主上报地图 → 写进房记录")
	var pr3 := _find(lobby.royale_list_payload("tk-probe"), "9102")
	_check(str(pr3.get("map", "")) == "maps/demo.cyrm", "再拉列表能看到这张图")

	# ── room_map:非房主一律不写 ──
	lobby.on_room_map(P_OTHER, "9102", "maps/hack.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "★ 非房主上报被拒(房记录一字不动)")

	# ── room_map:1v1 与 3v3 各走一遍 ──
	# - 这几条不是凑数:`_room_any` 的 `rooms` / `team_rooms` 两个分支、以及 `_is_room_host`
	#   的 `Room`(1v1)分支**只有这里**能覆盖 —— 而把 1v1 写成"一律读 host_peer"会让它的上报
	#   **永远被拒且不报错**(1v1 的房主是 `players[0]`,根本没有 host_peer 字段)。见 `_is_room_host`。
	lobby.on_room_map(P_HOST, "9101", "maps/duel.cyrm")
	var p1b := _find(lobby.room_list_payload(), "9101")
	_check(str(r1.map) == "maps/duel.cyrm" and str(p1b.get("map", "")) == "maps/duel.cyrm",
			"★ 1v1 房主上报 → 写进房记录且列表能看到(实得记录「%s」/列表「%s」)"
			% [str(r1.map), str(p1b.get("map", ""))])
	# - 非房主那两条用**哨兵**(调用前后自比)而不是绝对值:这样它只判"没被写"这一件事,
	#   不依赖上面那条房主写入是否成功 —— 于是变异打在 1v1 分支上时**只红房主那一条**,
	#   两件事不至于混在一起(绝对值写法会让它们一起红,失去单点定位)。
	var m1 := str(r1.map)
	lobby.on_room_map(P_OTHER, "9101", "maps/hack1.cyrm")
	_check(str(r1.map) == m1, "★ 1v1 非房主上报被拒(房记录一字不动,仍「%s」)" % str(r1.map))
	lobby.on_room_map(P_HOST, "9103", "maps/team.cyrm")
	var pt2 := _find(lobby.team_list_payload(""), "9103")
	_check(str(tr.map) == "maps/team.cyrm" and str(pt2.get("map", "")) == "maps/team.cyrm",
			"★ 3v3 房主上报 → 写进房记录且列表能看到(实得记录「%s」/列表「%s」)"
			% [str(tr.map), str(pt2.get("map", ""))])
	var m3 := str(tr.map)
	lobby.on_room_map(P_OTHER, "9103", "maps/hack3.cyrm")
	_check(str(tr.map) == m3, "★ 3v3 非房主上报被拒(房记录一字不动,仍「%s」)" % str(tr.map))

	# ── room_map:未知房号 —— 不崩、也不误写别人 ──
	# - 判据**不是**"没崩":`_check(true, "不崩")` 恒真、什么也断言不了(简报原稿就是那样)。
	#   真判据 = 这次调用前后,三间房的 `map` 逐字不变(既没崩、也没把别人写坏)。
	#   此刻三间房的 map 互不相同  ->  "写错了一间"必然被这一条抓住。
	var before := str([str(r1.map), str(rr.map), str(tr.map)])
	lobby.on_room_map(P_HOST, "9999", "maps/x.cyrm")
	var after := str([str(r1.map), str(rr.map), str(tr.map)])
	_check(before == after, "未知房号上报:不崩也不误写任何一间(前后 map 一致;实得 %s)" % after)

	_finish()


func _finish() -> void:
	# - 条数闸用 `!=`:少了 = 有断言没跑到,多了 = **多跑了一条没登记的断言**(2026-10-03 最终
	#   整体评审 Minor① 把这一族从 `<` 统一过来)。两种都是账目对不上,都不算 ALL-OK。
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望恰好 %d 条,多了少了都算账目对不上)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY PAYLOAD PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY PAYLOAD PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
