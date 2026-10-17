extends SceneTree
# 服务端控制台数据层冒烟:WorkerLauncher.classify 的三种端口占法 + (Task 2) server_status.build 的判据。
# ★ autoload-free:本文件不许引用 NetBus / LobbyRooms(/ -s 下编译期就解析不到)。
# 用法: "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd(外层套 timeout)

const WL := preload("res://server/lobby/worker_launcher.gd")


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

	if fail == 0:
		print("SERVER_STATUS_OK: classify 三种占法可区分")
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
