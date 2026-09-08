extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke):锁住 room_manager.gd 关键结构——
#  1) 存在 SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;
#  2) create_room 里给 room.created_at 赋了时间戳;
#  3) _process 每 SWEEP_INTERVAL 调 _sweep_stale_rooms;
#  4) _sweep_stale_rooms 对超龄房间调 _kill_worker + erase。
# 跑法:用户自跑(room_sweep_smoke.sh)。通过 = SMOKE_ROOM_SWEEP OK。

var _fail := ""

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://server/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		_finish()
		return
	_check(src)
	_finish()

func _check(src: String) -> void:
	if not src.contains("const SWEEP_INTERVAL := 600.0"):
		_fail = "缺 SWEEP_INTERVAL=600(10min)常量"; return
	if not src.contains("const MAX_ROOM_AGE := 7200.0"):
		_fail = "缺 MAX_ROOM_AGE=7200(2h)常量"; return
	if not src.contains("room.created_at = Time.get_unix_time_from_system()"):
		_fail = "create_room 未记录 created_at"; return
	if not src.contains("func _process"):
		_fail = "缺定时 _process"; return
	if not src.contains("func _sweep_stale_rooms"):
		_fail = "缺 _sweep_stale_rooms"; return
	if not src.contains("func _kill_worker"):
		_fail = "缺 _kill_worker"; return
	# _sweep_stale_rooms 体内必须出现:超龄判断、杀 worker、erase 房间
	var fn := src.find("func _sweep_stale_rooms")
	var body_end := src.find("\nfunc ", fn + 10)
	if body_end < 0:
		body_end = src.length()
	var body := src.substr(fn, body_end - fn)
	if not body.contains("created_at > MAX_ROOM_AGE"):
		_fail = "_sweep_stale_rooms 缺超龄判断"; return
	if not body.contains("_kill_worker"):
		_fail = "_sweep_stale_rooms 未调 _kill_worker"; return
	if not body.contains("rooms.erase"):
		_fail = "_sweep_stale_rooms 未删房"; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备")
	quit(0)
