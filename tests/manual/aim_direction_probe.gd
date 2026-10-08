extends SceneTree

# 复现/验证 "开火时向反方向行走弹道出问题":
# 玩家走路会把 facing_direction 覆盖为移动方向,而直接开火路径(_unhandled_input 在
# input 阶段派发,先于 _process 的 _auto_aim)读到的是被覆盖的 facing。
# _clamped_aim_dir 用 get_facing() 折叠 clamp_pitch,若 facing 与鼠标反侧 → 子弹翻折到另一侧。
# 本探针:停掉武器 _process(模拟 input 阶段直接开火),用相机位置控制瞄准方向(headless
# 下 Input.warp_mouse 不可靠),让 facing 与瞄准反侧,fire() 后断言子弹必须朝瞄准侧。

var fails := 0
func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: " + msg)
	else:
		fails += 1
		printerr("  FAIL: " + msg)

class StubPlayer extends Node2D:
	var facing: int = 1
	func get_facing() -> int:
		return facing
	func set_facing(v: int) -> void:
		facing = 1 if v >= 0 else -1
	func is_downed() -> bool:
		return false

func _initialize() -> void:
	var cam := Camera2D.new()
	root.add_child(cam)
	await physics_frame   # 让相机入树后 make_current 才生效(root 在 _initialize 早期未入树)
	cam.make_current()
	cam.global_position = Vector2.ZERO
	await physics_frame

	var stub := StubPlayer.new()
	stub.global_position = Vector2.ZERO
	root.add_child(stub)
	await physics_frame

	var pistol: PackedScene = load("res://scenes/weapons/pistol_test.tscn")
	var w = pistol.instantiate()
	stub.add_child(w)
	w.equip(stub)
	w.set_process(false)   # 停掉每帧 _auto_aim,只测 fire() 本体路径
	await physics_frame

	var bullet_script := load("res://scenes/weapons/bullet_base.gd")

	# 场景1: 走路把朝向覆盖为左(-1),瞄准方向在右(相机右移) → 子弹必须朝右
	stub.facing = -1
	cam.global_position = Vector2(4000, 0)
	await physics_frame
	_run_case(w, root, bullet_script, stub, "走路朝左/瞄右侧", +1.0)

	# 场景2: 走路把朝向覆盖为右(+1),瞄准方向在左(相机左移) → 子弹必须朝左
	stub.facing = 1
	cam.global_position = Vector2(-4000, 0)
	await physics_frame
	_run_case(w, root, bullet_script, stub, "走路朝右/瞄左侧", -1.0)

	print("== %s, failures=%d" % ["FAIL" if fails > 0 else "PASS", fails])
	quit(1 if fails > 0 else 0)

func _run_case(w, node: Node, bullet_script: Script, stub, tag: String, expect_sign: float) -> void:
	var aim: Vector2 = w._aim_world_dir()
	print("%s: facing=%d aim=%s (x=%+.2f)" % [tag, stub.facing, aim, aim.x])
	_check(signf(aim.x) == expect_sign, "%s: 瞄准映射到期望侧" % tag)
	if signf(aim.x) != expect_sign:
		return   # 瞄准没控制住,跳过后续断言(避免误报)
	var before := _count_bullets(node, bullet_script)
	w.fire()
	var b := _find_new_bullet(node, bullet_script, before)
	_check(b != null, "%s: 开火生成子弹" % tag)
	if b != null:
		var dir: Vector2 = b.velocity_vec.normalized()
		print("  子弹方向 %s (x=%+.2f)" % [dir, dir.x])
		_check(signf(dir.x) == signf(aim.x), "%s: 子弹朝瞄准侧,不被走路 facing 翻折" % tag)

func _count_bullets(node: Node, script: Script) -> int:
	var n := 0
	for c in node.get_children():
		if c.get_script() == script:
			n += 1
	return n

func _find_new_bullet(node: Node, script: Script, before: int) -> Node:
	for c in node.get_children():
		if c.get_script() == script:
			if before > 0:
				before -= 1
			else:
				return c
	return null
