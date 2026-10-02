extends Node

# 大厅**列表载荷形状**与 `room_map` 房主校验的服务端面探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
# 判据: 文本 `LOBBY PAYLOAD PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:房卡要吃 is_public / host / map / match_time / team_counts 五个键,
#   而"服务端给了但客户端没渲染"和"客户端渲染了但服务端没给"**都不报错** —— 只表现为
#   卡片上那一行空着。本探针钉服务端那一半。
# ★ 建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径);房记录由探针手工摆,
#   不需要 socket、不需要 worker(与 lobby_visibility_probe 同款)。
# ★ 断言计数:ALL-OK 只证明"没有一条断言失败",不证明"该跑的都跑过"(见 tests/lib/probe_base.gd
#   文件头)。少跑一条就红 —— 改本探针必须同步改这个数。
const EXPECTED_CHECKS := 14

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
	# ★ 用 append 而不是 `= [P_HOST] as Array[int]`:后者不是合法的 GDScript 转型写法,
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
	# ★ 签名是 grant(token, code, role, worker_port, worker_pid, now_ms) —— 六个参数。
	#   worker_pid 传 0 = "拉起中",与 `owns()` 无关(它只看 TTL,不看 worker 活性)。
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

	# ── room_map:房主可写 ──
	lobby.on_room_map(P_HOST, "9102", "maps/demo.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "房主上报地图 → 写进房记录")
	var pr3 := _find(lobby.royale_list_payload("tk-probe"), "9102")
	_check(str(pr3.get("map", "")) == "maps/demo.cyrm", "再拉列表能看到这张图")

	# ── room_map:非房主一律不写 ──
	lobby.on_room_map(P_OTHER, "9102", "maps/hack.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "★ 非房主上报被拒(房记录一字不动)")
	lobby.on_room_map(P_HOST, "9999", "maps/x.cyrm")
	_check(true, "未知房号不崩(静默丢弃)")

	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY PAYLOAD PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY PAYLOAD PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
