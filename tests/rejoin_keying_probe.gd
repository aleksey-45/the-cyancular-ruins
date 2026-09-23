extends ProbeBase

# 「拆除时作废回局凭据 —— 键是 **worker 端口**,不是房间号」的守卫(场景模式;真 `LobbyRooms`
# + 真 `teardown_room`,不是只测那个纯函数)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/rejoin_keying_probe.tscn
# 判据: 末行 `KH REJOIN-KEY PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 它守的是什么 ═══
# `teardown_room` 原先拿 `room.code` 去作废凭据,而**三张注册表的房号空间是重叠的**
# (1v1 / 大乱斗 / 3v3 都用 `LobbyRooms._generate_code()` 的 4 位号,且各查各的 `has(code)`)
# ⇒ 拆掉**无关**的一间房会把另一间**同号**房里那位玩家的凭据一起清掉。损坏有界(那位玩家只会
# 看到「凭据已失效」),但它是错的,而且**一行日志都没有**。
# ★ `teardown_room` 自己那段注释早就写着"别拿 `room.code` 去三张表里撞库"(它用 `is` 判房型
#   正是为了躲这个坑),而它下面作废凭据那一行踩的**就是同一个坑** —— 故本探针的病态输入就是
#   "两间同号的房"。
# ★ 端口是那张表上**唯一可用**的键:`WorkerLauncher.pick_port` 的唯一递增 + 占用集合保证每间房
#   独占一个端口;房号不保证(上面那条)。
#
# ★★ 两个方向都要(缺任一条,就有一整类坏实现能全绿):
#   ① 拆掉的那间房**自己的**凭据必须被清掉 —— 只断言"没误伤"会让"什么都不清"的实现全绿,
#      而那正是这份凭据存在的一半意义(否则回局被送到一个已经不属于它的端口);
#   ② **同号**的另一间房的凭据必须还在 —— 只断言①会让**按 code 键**的实现全绿(那正是本探针
#      落地时要修的那个缺陷)。
#   ③ 表的条数是①②的**合计**读数:它同时兜住"清多了"与"清少了"。
const SHARED_CODE := "1234"
const PORT_A := 29001
const PORT_B := 29002
const EXPECTED_CHECKS := 4

var _ran := 0


func probe_id() -> String:
	return "REJOIN-KEY"


func _ready() -> void:
	var rm := RoomManager.new()
	add_child(rm)
	# 手工驱动:大厅那两条梯(600s 超龄清扫 / 30s 回收)会把下面刚摆好的房收掉 ——
	# 与 `lobby_visibility_probe` 关梯同款。★ `teardown_room` 的延迟归还端口是个协程
	# (要 `get_tree()`),本探针不等它 —— 它只是在给"worker 刚退"留时间,quit 时随进程结束。
	rm.set_process(false)

	var now := Time.get_ticks_msec()
	var live := OS.get_process_id()   # 本进程自己 —— 一定活着,不必拉起任何子进程

	# 两间**同号**的房,分属两张不同的注册表(1v1 与大乱斗)。★ 这不是"不该发生的输入":
	# 三处建房各自只查自己那张表的 `has(code)`,同号共存是**允许**的。
	var a := LobbyRooms.Room.new()
	a.code = SHARED_CODE
	a.started = true
	a.worker_port = PORT_A
	a.worker_pid = live
	rm.lobby.rooms[a.code] = a
	var b := LobbyRooms.RoyaleRoom.new()
	b.code = SHARED_CODE
	b.in_match = true
	b.worker_port = PORT_B
	b.worker_pid = live
	rm.lobby.royale_rooms[b.code] = b

	# 两间房各有一份凭据(端口分别是 PORT_A / PORT_B)
	rm.lobby.rejoin.grant("tk_a", SHARED_CODE, 1, PORT_A, live, now)
	rm.lobby.rejoin.grant("tk_b", SHARED_CODE, 2, PORT_B, live, now)

	# 拆 **B 房**(它就是"这一局结束了"的那一间 —— 与回收梯判出来的那一档同形)
	rm.lobby.teardown_room(b, LobbyRooms.TEARDOWN_DELAYED)

	var b_gone := rm.lobby.rejoin.lookup("tk_b", now).is_empty()
	var a_alive := not rm.lobby.rejoin.lookup("tk_a", now).is_empty()
	_ran += 1
	_check(b_gone, "拆掉的那间房**自己的**凭据必须被作废(否则回局被送到一个已不属于它的端口)")
	_ran += 1
	_check(a_alive, "★ 同号的另一间房的凭据**不得**被误伤(按 code 键作废时它会在这里当场消失)")
	_ran += 1
	_check(rm.lobby.rejoin.size() == 1,
			"凭据表应剩 1 条(同一间房自己的清了、同号那间的没动),实得 %d" % rm.lobby.rejoin.size())
	# ★ 最后一条是"本探针确实跑到了这里"的自检:没有它,上面三条被静默跳过时(脚本错误只让
	#   出错的函数当场结束,调用方照常继续)verdict 照样 ALL-OK —— 探针必须自己数条数
	#   (见 tests/lib/probe_base.gd 文件头)。
	_ran += 1
	_check(_ran >= EXPECTED_CHECKS,
			"★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数" % [_ran, EXPECTED_CHECKS])
	_finish()
