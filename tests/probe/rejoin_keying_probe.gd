extends ProbeBase

# 重连凭据注销键精准性探针：
# 验证重连凭据以对局局号（match_id）而非房间号作为唯一标识，确保同名房间的凭据互不干扰。
#
# 运行方式: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/rejoin_keying_probe.tscn
# 判定标准: 末行输出包含 "KH REJOIN-KEY PROBE: ALL-OK"
#
# 测试要点：
# 1. 跨模式房间号可能重叠（1v1 / 大乱斗 / 3v3 均基于 4 位随机码且分表存储）。
# 2. 凭据以全局唯一的局号 match_id 进行索引和注销。
# 3. 校验双向边界：
#    - 目标对局的凭据必须正确失效；
#    - 同房间号但不同局号的凭据状态保持不变。
const SHARED_CODE := "1234"
const MATCH_A := 29001
const MATCH_B := 29002
const EXPECTED_CHECKS := 4

var _ran := 0


func probe_id() -> String:
	return "REJOIN-KEY"


func _ready() -> void:
	var rm := RoomManager.new()
	add_child(rm)
	# 禁用自动轮询，由测试用例手动驱动
	rm.set_process(false)

	var now := Time.get_ticks_msec()

	# 模拟两间同房间号但分属不同模式（1v1 与大乱斗）的房间
	var a := LobbyRooms.Room.new()
	a.code = SHARED_CODE
	a.started = true
	a.match_id = MATCH_A
	rm.lobby.rooms[a.code] = a
	var b := LobbyRooms.RoyaleRoom.new()
	b.code = SHARED_CODE
	b.in_match = true
	b.match_id = MATCH_B
	rm.lobby.royale_rooms[b.code] = b

	# 分别为两间房间签发重连凭据（局号分别为 MATCH_A 与 MATCH_B）
	rm.lobby.rejoin.grant("tk_a", SHARED_CODE, 1, MATCH_A, now)
	rm.lobby.rejoin.grant("tk_b", SHARED_CODE, 2, MATCH_B, now)

	# 模拟 B 房间对局会话结束，注销其凭据
	rm.lobby.rejoin.end_match(MATCH_B)

	var b_dead := not bool(rm.lobby.rejoin.lookup("tk_b", now).get("alive", true))
	var a_alive := bool(rm.lobby.rejoin.lookup("tk_a", now).get("alive", false))
	_ran += 1
	_check(b_dead, "结束的那一局**自己的**凭据必须被作废(否则回局被送到一个已经没有对局的房)")
	_ran += 1
	_check(a_alive, "★ 同号的另一间房的凭据**不得**被误伤(按 code 键作废时它会在这里当场失活)")
	_ran += 1
	# end_match 仅将 alive 置为 false 而不从表中删除条目，以便客户端查询到“对局已结束”状态
	var alive_n := 0
	for tk in ["tk_a", "tk_b"]:
		if bool(rm.lobby.rejoin.lookup(tk, now).get("alive", false)):
			alive_n += 1
	_check(alive_n == 1 and rm.lobby.rejoin.size() == 2,
			"应恰有 1 条凭据还活着(同号那间的);表里条数仍是 2(end_match 不删条目)。实得 活着 %d / 共 %d"
			% [alive_n, rm.lobby.rejoin.size()])
	_ran += 1
	_check(_ran >= EXPECTED_CHECKS,
			"★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数" % [_ran, EXPECTED_CHECKS])
	_finish()
