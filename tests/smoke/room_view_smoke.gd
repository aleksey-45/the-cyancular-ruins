extends SceneTree
# 房列表「房主 + 名单」守卫(01 审查 S-12:同一段判据原先在 RoomRegistry.list_payload 与
#   LobbyRooms.host_name_of 各写一遍 ⇒ 收进 ServerStatus.host_and_roster 单一来源后由本文件钉住)。
# 覆盖四种组合:1v1 等待中(房主 = players[0])/ 1v1 局中(players 空 ⇒ 冻结名单第一条)/
#   大乱斗·3v3 等待中(房主 = host_peer)/ 局中(host_peer 的 role 命中冻结名单)。
# 测不到什么:list_payload 与面板的实际渲染(真链路/人眼);本文件只测纯判据。
# 变异验证:把 is_duel 分支对调 ⇒ ① 红(1v1 等待中取不到 players[0]);roster_of 局中不读冻结名单 ⇒ ②④ 红。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/room_view_smoke.gd;通过 = ROOM VIEW OK(n 条断言)。

const EXPECTED_CHECKS := 7

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var names := {10: "A", 11: "B"}
	var frozen: Array = [{"role": 1, "name": "A"}, {"role": 2, "name": "B"}]

	# ① 1v1 等待中:房主 = players[0];名单 = players 顺序
	var r1 := ServerStatus.host_and_roster(true, false, 0, 0, [], [10, 11], {10: 1, 11: 2}, names)
	_chk(str(r1["host"]) == "A" and (r1["names"] as Array) == ["A", "B"],
			"1v1 等待中:房主 = players[0](实得 %s / %s)" % [str(r1["host"]), str(r1["names"])])

	# ② 1v1 局中:players 已空 ⇒ 房主退回冻结名单第一条
	var r2 := ServerStatus.host_and_roster(true, true, 0, 0, frozen, [], {10: 1, 11: 2}, names)
	_chk(str(r2["host"]) == "A" and (r2["names"] as Array) == ["A", "B"],
			"1v1 局中:房主取冻结名单第一条(实得 %s)" % str(r2["host"]))

	# ③ 大乱斗等待中:房主 = host_peer 的昵称
	var r3 := ServerStatus.host_and_roster(false, false, 11, 2, [], [10, 11], {10: 1, 11: 2}, names)
	_chk(str(r3["host"]) == "B" and (r3["names"] as Array) == ["A", "B"],
			"大乱斗等待中:房主 = host_peer(实得 %s)" % str(r3["host"]))

	# ④ 大乱斗局中:host_peer 的 role 命中冻结名单
	var r4 := ServerStatus.host_and_roster(false, true, 11, 2, frozen, [], {10: 1, 11: 2}, names)
	_chk(str(r4["host"]) == "B" and (r4["names"] as Array) == ["A", "B"],
			"大乱斗局中:房主按 host_role 查冻结名单(实得 %s)" % str(r4["host"]))

	# ⑤ 3v3 分组(S-09:从 LobbyRooms 挪进 RoomTypes.static 后的纯函数)
	var room: RoomTypes.Room = RoomTypes.Room.new()
	room.team_of = {1: 1, 2: 2, 3: 1, 6: 2}
	var bt := RoomTypes.by_team(room)
	_chk((bt[1] as Array) == [1, 3] and (bt[2] as Array) == [2, 6],
			"RoomTypes.by_team 按队号分组(实得 %s)" % str(bt))

	# ⑥ 满员判据:4v2 也算 6 人,但不是 3v3
	_chk(RoomTypes.team_ready({1: [1, 2, 3], 2: [4, 5, 6]})
			and not RoomTypes.team_ready({1: [1, 2, 3, 4], 2: [5, 6]}),
			"team_ready 只认 3+3(4v2 不算满员)")

	# ⑦ 最小空闲号(空洞复用) + 可加入 + 三档人数(字符串键)
	var cnt_room: RoomTypes.Room = RoomTypes.Room.new()
	cnt_room.player_role = {10: 1, 11: 2, 12: 6, 13: 3}
	cnt_room.team_of = {1: 1, 2: 2, 6: 1, 3: 0}
	var cts := RoomTypes.team_counts_of(cnt_room)
	_chk(RoomTypes.team_next_role([1, 3, 4]) == 2
			and not RoomTypes.team_can_join({1: [1, 2, 3], 2: []}, 1)
			and RoomTypes.team_can_join({1: [1], 2: []}, 1)
			and cts["1"] == 2 and cts["2"] == 1 and cts["0"] == 1,
			"最小空闲号/可加入/三档人数(实得 %s)" % str(cts))

	# 判词:计数闸(条数不符也红)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("ROOM VIEW OK(%d 条断言):房主+名单单一来源 · 3v3 纯判据(分组/满员/最小空闲号/三档人数)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("ROOM VIEW FAILED: %d 处" % _fails.size())
		quit(1)