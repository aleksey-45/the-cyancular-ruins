extends SceneTree

# AIInputSource 契约冒烟:①是 InputSource 子类 ②is_network_driven() 必须为 true
# ③基类所有读口都真被覆写(不会被基类默认实现悄悄接管)
# 为什么钉死第 ② 条:main 的 WeaponBase.reload_active() 第二判据是 player.input_is_network()
# → 若 AI 被判成"本地单机",AI 打空弹夹后会进换弹、静默停火 reload_time 秒(霰弹 2.2s/榴弹 2.8s)。
# 无报错、无客户端分歧,只是 AI 手感莫名变差 —— 只有断言能拦住这种静默退化。

var _fail := 0


# ── AINavigator._pick_target 的桩(只为断言方向符号,不模拟任何真实玩法)──
# 为什么必须真调 `_pick_target`:它返回的 `"dir"` 有两个分支(黏滞锁定 / 重选最近),
# 两处都要是「我→对手」。只断言成员存在或方法可调**照不出符号错** —— 2026-09-14 那个
# 「锁死后瞄反」的 bug 正是这么漏过去的(冒烟只查了 host/role/src 三个成员名)。
# 注:`-s` 脚本自身不能引用 autoload(编译期 Identifier not found),但**运行期 load** 进来的
# 脚本可以 —— `_pick_target` 里的 `GameParameters.MAP_WIDTH` 在下面这条路径上是可用的(实测)。
class StubHost extends Node:
	var players: Dictionary = {}

class StubBody extends Node2D:
	var _downed := false
	func is_downed() -> bool: return _downed


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

	# ★ frozen 契约回归(2026-09-14):基类承诺「置 true 后一切输入读口返回中性值」,
	#   而本类此前覆写了**全部**公开读口 → 基类的 if frozen 整个被绕过,
	#   player.set_controls_locked(true) 对 AI/网络输入源是**静默空操作**。
	#   此断言必须打在**子类实例**上:基类自己的实现无法证明子类听话。
	#   口径来自 core/input_source.gd 的类头注释与 player.set_controls_locked 的调用点。
	#   注:本类把 is_action_pressed / is_action_just_released / is_attack_just_released /
	#   get_weapon_slot_pressed 实现成**常量**(与 frozen 无关),故那 4 条不具鉴别力 —— 但
	#   它们仍要断言(修完必须全绿),具鉴别力的是 get_axis / just_pressed / attack_pressed /
	#   attack_just_pressed 这 4 条(它们会回放写入的值,能照出"未短路")。
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
	_check(src.get_weapon_slot_pressed() == 0, "frozen:get_weapon_slot_pressed 为 0")
	# 瞄准是**刻意**不冻的:冻结期武器仍要按注入方向摆枪
	_check(src.get_aim_dir_override() == Vector2.UP, "frozen:瞄准刻意不冻(武器仍按注入方向摆枪)")
	src.frozen = false
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

		# ── ★ AI 目标方向(2026-09-14 修 H1)──
		# `_pick_target` 的 "dir" 约定是 **我→对手**(消费者:`_aim_and_fire` 拿它当开火方向、
		# `_move` 的 `signf(dir.x)` 追人/后拉)。而 `toroidal_delta_px(a,b)` 返回 a→b,传
		# `(对手, 我)` 得到的是「对手→我」**必须取负**。黏滞分支曾漏掉取负 → 锁定后整局
		# 瞄反 + 远则逃近则贴。两条分支都要断言:它们的取负是各写一遍的。
		var h := StubHost.new()
		nav.host = h
		nav.role = 1
		var me := StubBody.new()
		me.position = Vector2.ZERO
		var foe := StubBody.new()
		foe.position = Vector2(400, 0)     # 对手在我**右**侧 → 正确的 dir.x 必须 > 0
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
