extends Node
# 环面相机探针(2026-11-01):相机加死区后,最容易回归的就是"跨接缝露馅/瞬移"。
# 报的缺陷形态:玩家坐标是取模的,跨接缝那一帧会差一整张图;若相机在取模坐标上做死区/平滑,
# 这一帧会被当成横穿地图的大位移 ⇒ 要么平滑出 9600px 平移,要么靠 snap 硬跳一帧(看起来像瞬移)。
# 本探针钉住的不变量:**任何一帧,镜头节点与玩家节点在原始坐标上的距离都必须很小**
# (≤ 死区 + cam_y_bias + 余量),跨接缝与真传送都不例外;同时死区本身要真的吃掉 1 格台阶。
# 去掉什么才红:去掉 wrapf 连续化(直接在取模坐标上平滑)⇒ ⑭ 跨接缝后原始距离 ≈ 一整张图 ⇒ 红;
#   cam_deadzone 改回 0/4 ⇒ ⑫⑬(死区不动)红;去掉"玩家取模坐标 + 连续偏移"的输出改回取模镜头位置 ⇒ ⑭ 红。
# 测不到什么:平滑手感、镜头滞后好不好看(只能试玩);相机在 PvP 客户端(预测位置)的观感。
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
	# 相机读这两个量做"最短取模差"与"玩家取模坐标" —— 探针里直接钉成本图尺寸(不依赖当前加载的地图)。
	GameParameters.MAP_WIDTH = int(MAP_W)
	GameParameters.MAP_HEIGHT = int(MAP_H)

	var cam_script: Script = load("res://core/present/camera_2d.gd")
	if cam_script == null:
		_chk(false, "★ 空载守卫:load(core/present/camera_2d.gd) 为 null")
		_finish()
		return
	_target = Node2D.new()
	_target.global_position = Vector2(5.0, 3000.0)   # 起点就放在接缝旁边,后面的"跨接缝"才是小位移
	add_child(_target)

	_cam = Camera2D.new()
	_cam.set_script(cam_script)
	add_child(_cam)
	_cam.set("target", _target)
	# 与游戏里一致:镜头节点是 WorldViewport 的子节点(世界坐标),这里挂在探针根上等价。

	await get_tree().process_frame
	await get_tree().process_frame
	var bias: float = PlayerParams.cam_y_bias
	var dz: float = PlayerParams.cam_deadzone
	# ⑪ 初始对齐:镜头 = 玩家 + (0, bias)(无横向前瞻:target 不是 CharacterBody2D)
	_chk(_near(_off().x, 0.0, 0.5) and _near(_off().y, bias, 0.5),
			"⑪ 初始:镜头 = 玩家 + cam_y_bias(实得 %s / bias %.1f)" % [str(_off()), bias])

	# ⑫ 死区:玩家横向挪 8px(小于死区)⇒ 镜头**不动**(只是偏移变大)
	var cam_x0 := _cam.global_position.x
	_target.global_position.x += 8.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.x, cam_x0, 0.05),
			"⑫ 死区:横向 8px(< deadzone %.0f)镜头不动(位移 %.3f)" % [dz, _cam.global_position.x - cam_x0])

	# ⑬ 死区:爬上 1 格台阶(y −16)⇒ 镜头竖直方向不动;这是用户报的"上楼梯画面抖"的直接判据
	var cam_y0 := _cam.global_position.y
	_target.global_position.y -= 16.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.y, cam_y0, 0.05),
			"⑬ 死区:上 1 格台阶(y−16)镜头不动(位移 %.3f)" % (_cam.global_position.y - cam_y0))
	_chk(_near(_off().y, bias + 16.0, 0.5),
			"⑬b 台阶抬升只进偏移:偏移 y = bias+16(实得 %.1f)" % _off().y)

	# ⑭ 跨接缝(核心):玩家连续跨过接缝(x≈13 → x=W−5,连续位移 ≈ −18)⇒ 原始坐标差 ≈ 整张图
	var before := _cam.global_position - _target.global_position
	_target.global_position.x = MAP_W - 5.0
	await get_tree().process_frame
	await get_tree().process_frame
	var after := _cam.global_position - _target.global_position
	_chk(_len_at_most(after, dz + absf(bias) + 40.0),
			"★ ⑭ 跨接缝后镜头与玩家的原始距离必须仍然很小(实得 %s;差一整张图就是露馅/瞬移)" % str(after))
	_chk(_near(after.x, before.x, 40.0) and _near(after.y, before.y, 40.0),
			"★ ⑭b 跨接缝前后「镜头−玩家」偏移连续(前 %s / 后 %s)" % [str(before), str(after)])

	# ⑮ 接缝之后死区仍生效(连续化没有把死区弄丢)
	var cam_x1 := _cam.global_position.x
	_target.global_position.x -= 6.0
	await get_tree().process_frame
	_chk(_near(_cam.global_position.x, cam_x1, 0.05),
			"⑮ 接缝后死区仍生效:横向 6px 镜头不动(位移 %.3f)" % (_cam.global_position.x - cam_x1))

	# ⑯ 真传送(复活/回退):玩家瞬移 3000px ⇒ 镜头同帧贴过去(原始距离仍小),不许演成跨图平移
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
