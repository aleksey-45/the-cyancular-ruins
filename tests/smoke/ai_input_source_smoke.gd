extends SceneTree

# AI 补位输入源冒烟测试：
# 验证 AiInputSource 的纯逻辑行为，包括随机初始武器持有规则、避开换弹逻辑、
# 目标追踪与输入向量生成（纯数据级测试，不依赖 Autoload 与真实场景）。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/ai_input_source_smoke.gd

var _fail := 0


class StubHost extends Node:
	var players: Dictionary = {}

class StubBody extends Node2D:
	var _downed := false
	func is_downed() -> bool: return _downed


func _initialize() -> void:
	# -s 阶段 autoload 未实例化 -> 这里只 load 不静态引用任何 autoload 标识符
	var ai_script: GDScript = load("res://core/net/ai_input_source.gd")
	var base_script: GDScript = load("res://core/net/player_input.gd")
	_check(base_script != null, "player_input.gd(接口)可加载")
	_check(ai_script != null, "ai_input_source.gd 可加载")
	if ai_script == null:
		print("AI INPUT SMOKE: FAIL")
		quit(1)
		return
	var src: PlayerInput = ai_script.new()

	_check(src is PlayerInput, "AiInputSource 是 PlayerInput 的子类")
	_check(src.is_network_driven(), "★ is_network_driven() 必须为 true(否则 AI 会静默进换弹)")

	# 覆写的行为断言(逐条对基类可区分):基类会把读取接口委托给真实 Input,headless 下恒为
	# 中性值 -> 下面每条"写进去再读出来"都能把"未覆写"检测暴露。
	# - 不要改回 "GDScript.has_method(m)" 那种写法:对 脚本资源 调用 has_method 只报
	#   GDScript 类自身的 ClassDB 方法与 static func,不报脚本的实例方法 -> 该写法恒为 false,
	#   任何断言都过不了(已实测)。也不能改用 get_script_method_list():子类会列出继承来的
	#   全部基类方法 -> 有无覆写都通过,属无效操作(已实测)。
	src.aim = Vector2.UP
	_check(src.get_aim_dir_override() == Vector2.UP,
			"get_aim_dir_override() 回放写入的 aim(基类返回 ZERO)")
	src.axis = -1.0
	_check(is_equal_approx(src.get_axis("left", "right"), -1.0),
			"get_axis('left') 回放写入的 axis(基类读真实 Input,headless 恒 0)")
	src.fire = true
	_check(src.is_attack_pressed(), "is_attack_pressed() 跟随 fire(基类读真实 Input,恒 false)")
	_check(src.is_attack_just_pressed(), "is_attack_just_pressed() 跟随 fire")
	src.press_jump()
	_check(src.is_action_just_pressed("up"), "press_jump() 后 just_pressed('up') 为真")
	_check(not src.is_action_just_pressed("up"), "跳跃为单帧边沿触发（第二次读取为假）")

	src.aim = Vector2.UP
	src.axis = -1.0
	src.fire = true
	src.press_jump()
	src.frozen = true
	_check(is_zero_approx(src.get_axis("left", "right")), "frozen:get_axis 为 0")
	_check(not src.is_action_pressed("up"), "frozen:is_action_pressed 为 false")
	_check(not src.is_action_just_pressed("up"), "frozen:is_action_just_pressed 为 false")
	_check(not src.is_action_just_released("up"), "frozen:is_action_just_released 为 false")
	_check(not src.is_attack_pressed(), "frozen:is_attack_pressed 为 false")
	_check(not src.is_attack_just_pressed(), "frozen:is_attack_just_pressed 为 false")
	_check(not src.is_attack_just_released(), "frozen:is_attack_just_released 为 false")
	_check(src.get_switch_index_pressed() == 0, "frozen:get_switch_index_pressed 为 0")
	_check(not src.is_pickup_pressed(), "frozen:is_pickup_pressed 为 false")
	_check(not src.is_drop_pressed(), "frozen:is_drop_pressed 为 false")
	# 瞄准是刻意不冻的:冻结期武器仍要按注入方向摆枪
	_check(src.get_aim_dir_override() == Vector2.UP, "frozen:瞄准刻意不冻(武器仍按注入方向摆枪)")
	src.frozen = false
	# 不逐条断言那些"在基类与覆写里都是同一个常量"的读取接口(is_action_pressed 恒 false、
	# is_action_just_released 恒 false、is_attack_just_released 恒 false、
	# get_switch_index_pressed 恒 0)—— 那种断言无论覆写与否都通过,为无效操作。

	# AiNavigator:只建实例断言成员与接口(不加入场景树 -> _physics_process/_ready 都不会跑,
	# 故读 host 的那行不会被触发;T2 的 AI 生成块按这几个成员名赋值,名错即静默失效)
	var nav_script: GDScript = load("res://server/ai/ai_navigator.gd")
	_check(nav_script != null, "server/ai/ai_navigator.gd 可加载")
	if nav_script != null:
		var nav: Node = nav_script.new()
		var props: Array = []
		for p in nav.get_property_list():
			props.append(p["name"])
		for m in ["host", "role", "src"]:
			_check(props.has(m), "AiNavigator 有成员 %s" % m)
		_check(nav.has_method("_physics_process"), "AiNavigator 有 _physics_process")

		var h := StubHost.new()
		nav.host = h
		nav.role = 1
		var me := StubBody.new()
		me.position = Vector2.ZERO
		var foe := StubBody.new()
		foe.position = Vector2(400, 0)     # 对手在我右侧 -> 正确的 dir.x 必须 > 0
		h.players = {1: me, 2: foe}
		nav.set("_target_role", 0)         # ① 重选「最近的对手」分支
		var r1: Dictionary = nav.call("_pick_target", me)
		_check((r1["dir"] as Vector2).x > 0.0,
				"AI 重选目标:对手在右 → dir.x > 0(我→对手;<=0 说明取负漏了或写反了)")
		nav.set("_target_role", 2)         # ② 黏滞锁定分支(漏取负就死在这一条)
		var r2: Dictionary = nav.call("_pick_target", me)
		_check((r2["dir"] as Vector2).x > 0.0,
				"AI 黏滞锁定:对手在右 → dir.x > 0(★ 2026-09-14 修的正是这条)")

		nav.free()

	if _fail == 0:
		print("AI INPUT SMOKE: OK")
		quit(0)
	else:
		print("AI INPUT SMOKE: FAIL(%d 条)" % _fail)
		quit(1)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)
