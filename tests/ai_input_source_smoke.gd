extends SceneTree

# AIInputSource 契约冒烟:①是 InputSource 子类 ②is_network_driven() 必须为 true
# ③基类所有读口都真被覆写(不会被基类默认实现悄悄接管)
# 为什么钉死第 ② 条:main 的 WeaponBase.reload_active() 第二判据是 player.input_is_network()
# → 若 AI 被判成"本地单机",AI 打空弹夹后会进换弹、静默停火 reload_time 秒(霰弹 2.2s/榴弹 2.8s)。
# 无报错、无客户端分歧,只是 AI 手感莫名变差 —— 只有断言能拦住这种静默退化。

var _fail := 0


func _initialize() -> void:
	# -s 阶段 autoload 未实例化 → 这里只 load 不静态引用任何 autoload 标识符
	var ai_script: GDScript = load("res://core/ai_input_source.gd")
	var base_script: GDScript = load("res://core/input_source.gd")
	_check(ai_script != null, "ai_input_source.gd 可加载")
	if ai_script == null:
		print("AI INPUT SMOKE: FAIL")
		quit(1)
		return
	var src: InputSource = ai_script.new()

	_check(src is InputSource, "AIInputSource 是 InputSource 的子类")
	_check(src.is_network_driven(), "★ is_network_driven() 必须为 true(否则 AI 会静默进换弹)")

	# 覆写的行为断言(逐条对基类可区分):基类会把读口委托给真实 Input,headless 下恒为
	# 中性值 → 下面每条"写进去再读出来"都能把"未覆写"照出来。
	# ⚠ 不要改回 "GDScript.has_method(m)" 那种写法:对 **脚本资源** 调用 has_method 只报
	#   GDScript 类自身的 ClassDB 方法与 static func,不报脚本的实例方法 → 该写法恒为 false,
	#   任何断言都过不了(已实测)。也不能改用 get_script_method_list():子类会列出**继承来的**
	#   全部基类方法 → 有无覆写都通过,属空转(已实测)。
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
	_check(not src.is_action_just_pressed("up"), "跳跃是**边沿**不是电平(第二次读为假)")
	# 不逐条断言那些"在基类与覆写里都是同一个常量"的读口(is_action_pressed 恒 false、
	# is_action_just_released 恒 false、is_attack_just_released 恒 false、
	# get_weapon_slot_pressed 恒 0)—— 那种断言无论覆写与否都通过,是空转。

	# AINavigator:只建实例断言成员与接口(不入树 → _physics_process/_ready 都不会跑,
	# 故读 host 的那行不会被触发;T2 的 AI 生成块按这几个成员名赋值,名错即静默失效)
	var nav_script: GDScript = load("res://server/ai_player.gd")
	_check(nav_script != null, "server/ai_player.gd 可加载")
	if nav_script != null:
		var nav: Node = nav_script.new()
		var props: Array = []
		for p in nav.get_property_list():
			props.append(p["name"])
		for m in ["host", "role", "src"]:
			_check(props.has(m), "AINavigator 有成员 %s" % m)
		_check(nav.has_method("_physics_process"), "AINavigator 有 _physics_process")
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
