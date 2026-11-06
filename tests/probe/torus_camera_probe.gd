extends Node
const EXPECTED_CHECKS := 8
const MAP_W := 9600.0
const MAP_H := 6400.0

var _cam: Camera2D = null
var _target: Node2D = null
var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("[torus-camera]   ✗ %s" % msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	GameParameters.MAP_WIDTH = int(MAP_W)
	GameParameters.MAP_HEIGHT = int(MAP_H)

	var cam_script: Script = load("res://core/present/camera_2d.gd")
	if cam_script == null:
		_chk(false, "★ 空载守卫:load(core/present/camera_2d.gd) 为 null")
		_finish()
		return
	_target = Node2D.new()
	_target.global_position = Vector2(5.0, 3000.0)
	add_child(_target)

	_cam = Camera2D.new()
	_cam.set_script(cam_script)
	add_child(_cam)
	_cam.set("target", _target)

	await get_tree().process_frame
	await get_tree().process_frame
	var bias: float = PlayerParams.cam_y_bias
	var dz: float = PlayerParams.cam_deadzone
	_chk(_near(_off().x, 0.0, 0.5) and _near(_off().y, bias, 0.5),
			"⑪ 初始:镜头 = 玩家 + cam_y_bias(实得 %s / bias %.1f)" % [str(_off()), bias])

	var cam_x0 := _cam.global_position.x
	_target.global_position.x += 8.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.x, cam_x0, 0.05),
			"⑫ 死区:横向 8px(< deadzone %.0f)镜头不动(位移 %.3f)" % [dz, _cam.global_position.x - cam_x0])

	var cam_y0 := _cam.global_position.y
	_target.global_position.y -= 16.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.y, cam_y0, 0.05),
			"⑬ 死区:上 1 格台阶(y−16)镜头不动(位移 %.3f)" % (_cam.global_position.y - cam_y0))
	_chk(_near(_off().y, bias + 16.0, 0.5),
			"⑬b 台阶抬升只进偏移:偏移 y = bias+16(实得 %.1f)" % _off().y)

	var before := _cam.global_position - _target.global_position
	_target.global_position.x = MAP_W - 5.0
	await get_tree().process_frame
	await get_tree().process_frame
	var after := _cam.global_position - _target.global_position
	_chk(_len_at_most(after, dz + absf(bias) + 40.0),
			"★ ⑭ 跨接缝后镜头与玩家的原始距离必须仍然很小(实得 %s;差一整张图就是露馅/瞬移)" % str(after))
	_chk(_near(after.x, before.x, 40.0) and _near(after.y, before.y, 40.0),
			"★ ⑭b 跨接缝前后「镜头−玩家」偏移连续(前 %s / 后 %s)" % [str(before), str(after)])

	var cam_x1 := _cam.global_position.x
	_target.global_position.x -= 6.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.x, cam_x1, 0.05),
			"⑮ 接缝后死区仍生效:横向 6px 镜头不动(位移 %.3f)" % (_cam.global_position.x - cam_x1))

	_target.global_position = Vector2(1500.0, 2200.0)
	await get_tree().process_frame
	var after_tp := _cam.global_position - _target.global_position
	_chk(_len_at_most(after_tp, dz + absf(bias) + 40.0),
			"★ ⑯ 真传送后镜头仍贴着玩家(实得 %s)" % str(after_tp))

	_finish()


func _off() -> Vector2:
	return _cam.global_position - _target.global_position


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _len_at_most(v: Vector2, lim: float) -> bool:
	return v.length() <= lim


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("TORUS CAMERA PROBE: ALL-OK(%d 条断言:初始对齐 · 死区不吃小位移 · 台阶不推镜头 · 跨接缝不露馅 · 接缝后死区 · 真传送贴合)" % _checks)
		get_tree().quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TORUS CAMERA PROBE: FAIL(%d 处)" % _fails.size())
		get_tree().quit(1)
