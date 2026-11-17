extends SceneTree

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

	var r1 := ServerStatus.host_and_roster(true, false, 0, 0, [], [10, 11], {10: 1, 11: 2}, names)
	_chk(str(r1["host"]) == "A" and (r1["names"] as Array) == ["A", "B"],
			"1v1 等待中:房主 = players[0](实得 %s / %s)" % [str(r1["host"]), str(r1["names"])])

	var r2 := ServerStatus.host_and_roster(true, true, 0, 0, frozen, [], {10: 1, 11: 2}, names)
	_chk(str(r2["host"]) == "A" and (r2["names"] as Array) == ["A", "B"],
			"1v1 局中:房主取冻结名单第一条(实得 %s)" % str(r2["host"]))

	var r3 := ServerStatus.host_and_roster(false, false, 11, 2, [], [10, 11], {10: 1, 11: 2}, names)
	_chk(str(r3["host"]) == "B" and (r3["names"] as Array) == ["A", "B"],
			"大乱斗等待中:房主 = host_peer(实得 %s)" % str(r3["host"]))

	var r4 := ServerStatus.host_and_roster(false, true, 11, 2, frozen, [], {10: 1, 11: 2}, names)
	_chk(str(r4["host"]) == "B" and (r4["names"] as Array) == ["A", "B"],
			"大乱斗局中:房主按 host_role 查冻结名单(实得 %s)" % str(r4["host"]))

	var room: RoomTypes.Room = RoomTypes.Room.new()
	room.team_of = {1: 1, 2: 2, 3: 1, 6: 2}
	var bt := RoomTypes.by_team(room)
	_chk((bt[1] as Array) == [1, 3] and (bt[2] as Array) == [2, 6],
			"RoomTypes.by_team 按队号分组(实得 %s)" % str(bt))

	_chk(RoomTypes.team_ready({1: [1, 2, 3], 2: [4, 5, 6]})
			and RoomTypes.team_ready({1: [1], 2: [4]})
			and RoomTypes.team_ready({1: [1, 2, 3, 4], 2: [5]})
			and not RoomTypes.team_ready({1: [1, 2, 3], 2: []}),
			"team_ready 认「两队各 ≥1」,单边空不算(3v3 的满员语义已废止)")

	var cnt_room: RoomTypes.Room = RoomTypes.Room.new()
	cnt_room.player_role = {10: 1, 11: 2, 12: 6, 13: 3}
	cnt_room.team_of = {1: 1, 2: 2, 6: 1, 3: 0}
	var cts := RoomTypes.team_counts_of(cnt_room)
	_chk(RoomTypes.team_next_role([1, 3, 4]) == 2
			and not RoomTypes.team_can_join({1: [1, 2, 3, 4, 5], 2: []}, 1)
			and RoomTypes.team_can_join({1: [1], 2: []}, 1)
			and cts["1"] == 2 and cts["2"] == 1 and cts["0"] == 1,
			"最小空闲号/可加入(每队上限 5)/三档人数(实得 %s)" % str(cts))

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("ROOM VIEW OK(%d 条断言):房主+名单单一来源 · 对抗纯判据(分组/开局闸门/最小空闲号/三档人数)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("ROOM VIEW FAILED: %d 处" % _fails.size())
		quit(1)