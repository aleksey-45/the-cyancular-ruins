extends ProbeBase

# 「作废回局凭据 —— 键是 **局号(match_id)**,不是房间号」的守卫(场景模式;真 `LobbyRooms`
# + 真 `end_match` / 真 `teardown_room`,不是只测那个纯函数)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/rejoin_keying_probe.tscn
# 判据: 末行 `KH REJOIN-KEY PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 它守的是什么 ═══
# 凭据的作废(`RejoinRegistry.end_match(match_id)`)按**局号**匹配。两条历史教训都指向这里:
#   · 房号:三张注册表(`rooms` / `royale_rooms` / `team_rooms`)的房号空间**重叠**(共用
#     `LobbyRooms._generate_code()`,且各查各的 `has(code)`)⇒ 按房号作废会误伤**同号**的另一间
#     房里那位玩家的凭据。损坏有界(那位玩家只会看到「凭据已失效」),但它是错的,而且**一行日志都没有**;
#   · worker 端口:那是"每局一个 worker 子进程"时代的键(`drop_port`),单进程单端口之后
#     端口不再标识任何一局。
#   局号由 `RoomManager` 唯一递增分配、**永不复用**,在任何一张表上都唯一。
# ★ `teardown_room` 自己那段注释早就写着"别拿 `room.code` 去三张表里撞库"(它用 `is` 判房型
#   正是为了躲这个坑),而它**不碰凭据**:"房记录被摘掉"与"对局结束"是两件事(AI 对战就是房摘了、
#   局还活着)。凭据的生死只由 `end_match` 决定(唯一调用点 = `RoomManager._on_session_finished`)。
#   ★ 故本探针按生产那两步各调一次,而病态输入仍是"两间**同号**的房"。
#
# ★★ 两个方向都要(缺任一条,就有一整类坏实现能全绿):
#   ① 被结束的那一局**自己的**凭据必须作废(`alive` 翻 false)—— 只断言"没误伤"会让"什么都不做"
#      的实现全绿,而那正是这份凭据存在的一半意义(否则回局被送进一局已经结束的对局);
#   ② **同号**的另一局的凭据必须还在、且 `alive` 仍为 true —— 只断言①会让**按 code 作键**的实现
#      全绿(那正是本探针落地时要修的那个缺陷);
#   ③ 表的条数是①②的**合计**读数:它同时兜住"清多了"与"清少了"(`end_match` 只翻 alive、
#      不删条目 ⇒ 条数不该变)。
const SHARED_CODE := "48207"
const MATCH_A := 4101
const MATCH_B := 4102
const EXPECTED_CHECKS := 5

var _ran := 0


func probe_id() -> String:
	return "REJOIN-KEY"


func _ready() -> void:
	var rm := RoomManager.new()
	add_child(rm)
	# 手工驱动:大厅那两条梯(600s 超龄清扫 / 30s 凭据 GC)会把下面刚摆好的房收掉 ——
	# 与 `lobby_visibility_probe` 关梯同款。★ 本探针不开 socket、也不拉任何会话/子进程。
	rm.set_process(false)

	var now := Time.get_ticks_msec()

	# 两间**同号**的房,分属两张不同的注册表(1v1 与大乱斗)。★ 这不是"不该发生的输入":
	# 三处建房各自只查自己那张表的 `has(code)`,同号共存是**允许**的。
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

	# 两局各有一份凭据(局号分别是 MATCH_A / MATCH_B,房号**相同**)
	rm.lobby.rejoin.grant("tk_a", SHARED_CODE, 1, MATCH_A, now)
	rm.lobby.rejoin.grant("tk_b", SHARED_CODE, 2, MATCH_B, now)

	# 结束 **B 局**(它就是"这一局打完了"的那一间)。★ 次序与生产同款
	# (`RoomManager._on_session_finished`:先作废该局凭据、再拆房)。
	rm.lobby.rejoin.end_match(MATCH_B)
	rm.lobby.teardown_room(b)

	var b_alive := bool(rm.lobby.rejoin.lookup("tk_b", now).get("alive", true))
	var a_alive := bool(rm.lobby.rejoin.lookup("tk_a", now).get("alive", false))
	_ran += 1
	_check(not b_alive, "被结束的那一局**自己的**凭据必须作废(alive 翻 false;否则回局被送进一局已经结束的对局)")
	_ran += 1
	_check(a_alive, "★ 同号的另一局的凭据**不得**被误伤(按 code 作键时它会在这里当场被翻掉)")
	_ran += 1
	_check(rm.lobby.rejoin.size() == 2,
			"凭据表应仍是 2 条(end_match 只翻 alive、不删条目),实得 %d" % rm.lobby.rejoin.size())
	_ran += 1
	_check(not rm.lobby.royale_rooms.has(SHARED_CODE),
			"★ 被拆的那间房必须从注册表里消失(房记录与凭据是两件事,但拆除本身仍要生效)")
	# ★ 最后一条是"本探针确实跑到了这里"的自检:没有它,上面几条被静默跳过时(脚本错误只让
	#   出错的函数当场结束,调用方照常继续)verdict 照样 ALL-OK —— 探针必须自己数条数
	#   (见 tests/lib/probe_base.gd 文件头)。
	_ran += 1
	_check(_ran >= EXPECTED_CHECKS,
			"★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数" % [_ran, EXPECTED_CHECKS])
	_finish()
