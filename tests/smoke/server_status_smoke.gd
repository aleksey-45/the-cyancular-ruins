extends SceneTree
# 服务端控制台数据层冒烟:WorkerLauncher.classify 的三种端口占法 + (Task 2) server_status.build 的判据。
# ★ autoload-free:本文件不许引用 NetBus / LobbyRooms(/ -s 下编译期就解析不到)。
# 用法: "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd(外层套 timeout)

const WL := preload("res://server/lobby/worker_launcher.gd")
const SS := preload("res://server/gui/server_status.gd")


func _initialize() -> void:
	var fail := 0

	# ① 已分配、还没 spawn:pid 表里没有它
	var a: Array = WL.classify([7800], {})
	fail += _check("已分配未 spawn: 出现在结果里", a.size() == 1)
	fail += _check("已分配未 spawn: pid = 0", a.size() == 1 and int(a[0]["pid"]) == 0)
	fail += _check("已分配未 spawn: alive = false", a.size() == 1 and bool(a[0]["alive"]) == false)

	# ② 已 spawn 且活着 —— ★ 夹具必须是**真实存在的 pid**:用本进程自己的 pid,
	#    写死一个数字(曾写 12345)会撞上"本机没这个进程"⇒ 断言假红。
	var live := OS.get_process_id()
	var b: Array = WL.classify([7800], {7800: live})
	fail += _check("已 spawn: pid 带回", b.size() == 1 and int(b[0]["pid"]) == live)
	fail += _check("已 spawn: alive = true", b.size() == 1 and bool(b[0]["alive"]) == true)

	# ③ 已 spawn 但已退出:pid 登记了、进程不在(用一个大到不可能存在的 pid 模拟)
	#    判据 = WorkerLauncher.pid_alive(pid) 为假 ⇒ alive=false,但 pid 本身要原样带回(面板要显示它)
	var c: Array = WL.classify([7800], {7800: 999999999})
	fail += _check("已 spawn 已退出: pid 仍带回", c.size() == 1 and int(c[0]["pid"]) == 999999999)
	fail += _check("已 spawn 已退出: alive = false", c.size() == 1 and bool(c[0]["alive"]) == false)

	# ④ 空池
	fail += _check("空池 → 空数组", WL.classify([], {}).is_empty())

	# ⑤ 确定性有序:面板每 0.5s 刷新一次,无序输出会让端口列表在屏幕上跳
	var d: Array = WL.classify([7802, 7800], {})
	fail += _check("按端口升序", d.size() == 2 and int(d[0]["port"]) == 7800 and int(d[1]["port"]) == 7802)

	# ── server_status.build 的判据 ──
	# ★ 夹具里的"活着的 pid"必须用真实进程(见上面 ② 的同一条理由);`live` 已在上文取过。
	var now := 1000.0
	# ① 局中房间:players 空是**正常**的(成员已转连 worker),人数必须按 roster 算
	var waiting := {"kind": "1v1", "code": "3310", "players": 1, "cap": 2, "in_match": false,
			"host": "阿伟", "map": "demo.cyrm", "worker_port": 0, "worker_pid": 0,
			"created_at": now - 30.0, "roster": []}
	var playing := {"kind": "royale", "code": "4821", "players": 0, "cap": 4, "in_match": true,
			"host": "阿伟", "map": "newfactory.cyrm", "worker_port": 7821, "worker_pid": live,
			"created_at": now - 100.0,
			"roster": [{"role": 1, "name": "阿伟"}, {"role": 2, "name": "玩家"}]}
	var stale := {"kind": "team", "code": "7734", "players": 0, "cap": 6, "in_match": true,
			"host": "玩家", "map": "newfactory.cyrm", "worker_port": 7822, "worker_pid": 999999999,
			"created_at": now - 50.0, "roster": [{"role": 1, "name": "玩家"}]}
	var ports := WL.classify([7821, 7822, 7899], {7821: live, 7822: 999999999})
	# ★ build() 的形参是**类型化数组**;GDScript 不接受把无类型字面量喂给 Array[Dictionary],
	#   故这里必须显式声明(裁决见 ledger)。
	var rooms_in: Array[Dictionary] = [waiting, playing, stale]
	var out: Dictionary = SS.build(rooms_in, ports, now)

	fail += _check("counts.rooms = 3", int(out["counts"]["rooms"]) == 3)
	fail += _check("counts.waiting = 1", int(out["counts"]["waiting"]) == 1)
	fail += _check("counts.in_match = 2", int(out["counts"]["in_match"]) == 2)
	fail += _check("counts.ports_used = 3", int(out["counts"]["ports_used"]) == 3)
	fail += _check("counts.workers_alive = 1", int(out["counts"]["workers_alive"]) == 1)
	fail += _check("counts.lobby_players = 1", int(out["counts"]["lobby_players"]) == 1)

	var r0: Dictionary = out["rooms"][0]
	var r1: Dictionary = out["rooms"][1]
	var r2: Dictionary = out["rooms"][2]
	# ★★ 局中房间人数按 roster(2),不是 players(0)
	fail += _check("局中房间人数按 roster = 2", int(r1["players"]) == 2)
	fail += _check("局中 state = in_match", str(r1["state"]) == "in_match")
	fail += _check("局中 online_known = false", bool(r1["online_known"]) == false)
	fail += _check("等待 state = waiting 且 online_known = true",
			str(r0["state"]) == "waiting" and bool(r0["online_known"]) == true)
	# ★★ worker 已退出必须 stale,不能显示成"对局中"
	fail += _check("worker 已退出 ⇒ state = stale", str(r2["state"]) == "stale")
	fail += _check("worker 已退出 ⇒ worker_alive = false", bool(r2["worker_alive"]) == false)
	fail += _check("房龄 = now - created_at", is_equal_approx(float(r0["age_sec"]), 30.0))

	if fail == 0:
		print("SERVER_STATUS_OK: classify 三种占法可区分 + build 判据(局中按 roster / stale / 房龄)")
		quit(0)
	else:
		printerr("SERVER_STATUS_FAIL: %d 项断言失败" % fail)
		quit(1)


func _check(name: String, cond: bool) -> int:
	if cond:
		print("  ok  - " + name)
		return 0
	printerr("  FAIL- " + name)
	return 1
