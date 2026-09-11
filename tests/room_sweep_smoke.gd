extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke):锁住 room_manager.gd 关键结构——
#  1) 存在 SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;
#  2) create_room 里给 room.created_at 赋了时间戳;
#  3) _process 每 SWEEP_INTERVAL 调 _sweep_stale_rooms;
#  4) _sweep_stale_rooms 对超龄房间调 _kill_worker + erase;
#  5) 大乱斗在局宽限谓词同时引用 RoyaleHost.MATCH_TIME 与 rr.in_match,且 1v1 仍是裸 MAX_ROOM_AGE。
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
	# 去掉注释行后的代码视图(注释里出现同名字符串不算数)
	var src_lines: Array = []
	for line in body.split("\n"):
		var t: String = line.strip_edges()
		if not t.is_empty() and not t.begins_with("#"):
			src_lines.append(t)
	# 上面那条 created_at > MAX_ROOM_AGE 只被 1v1 裸行满足,宽限被删掉它照样通过,故另立断言。
	# 断言只在**谓词那两行**(宽限声明 + 比较)上做,不查整个 body:body 里别的代码行(清理日志)
	# 也含同样的常量名,查全 body 会被它喂饱 —— 实测把宽限改回「只加一局时长」仍能通过。
	var code_lines := PackedStringArray(src_lines)
	var code := "\n".join(code_lines)
	var pred := ""
	for i in range(code_lines.size()):
		if code_lines[i].contains("rr.created_at > MAX_ROOM_AGE"):
			pred = code_lines[i]
			if i > 0:
				pred = code_lines[i - 1] + "\n" + pred
			break
	if pred.is_empty():
		_fail = "找不到大乱斗超龄判定(谓词行)"; return
	if not pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限缺 RoyaleHost.MATCH_TIME(宽限被删/被写死?)"; return
	if not pred.contains("rr.in_match"):
		_fail = "大乱斗在局宽限缺 rr.in_match 门控"; return
	if not pred.contains("SWEEP_INTERVAL"):
		_fail = "大乱斗在局宽限未含 SWEEP_INTERVAL(界被改回只加一局,挡不住下一次 tick?)"; return
	# 反过来:1v1 的超龄判断必须保持裸 MAX_ROOM_AGE,宽限不得泄漏进 1v1 分支
	if not code.contains("room.created_at > MAX_ROOM_AGE:"):
		_fail = "1v1 超龄判断不再是裸 MAX_ROOM_AGE(宽限泄漏?)"; return
	if not body.contains("_kill_worker"):
		_fail = "_sweep_stale_rooms 未调 _kill_worker"; return
	if not body.contains("rooms.erase"):
		_fail = "_sweep_stale_rooms 未删房"; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备(含大乱斗在局宽限界钉死)")
	quit(0)
