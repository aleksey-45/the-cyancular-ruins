extends SceneTree
# 玩家公开接口契约守卫:拆分重构期间保证公开 API 不被改名/删掉。
# 源码级检查(player.gd 在 -s 阶段因 autoload 无法实例化,见 CLAUDE.md 冒烟注释)。

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/player/player.gd")
	var lsrc := FileAccess.get_file_as_string("res://scenes/player/climb_component.gd")
	var ssrc := FileAccess.get_file_as_string("res://scenes/player/swim_component.gd")
	var csrc := FileAccess.get_file_as_string("res://scenes/player/combat_component.gd")
	var wsrc := FileAccess.get_file_as_string("res://scenes/player/weapon_component.gd")
	# 根公开方法(外部调用方依赖,签名必须保持)
	for sig in [
		"func take_hit(",
		"func get_facing(",
		"func set_facing(",
		"func is_downed(",
		"func apply_recoil(",
		"signal hp_changed(",
		"add_to_group(\"player\")",
	]:
		_check(src.contains(sig), "player.gd 含 " + sig)
	# 公开只读属性(HUD 直接读,见 hud.gd:37/39)
	_check(src.contains("var hp: int:"), "player.gd 公开 hp 属性")
	_check(src.contains("var max_hp: int:"), "player.gd 公开 max_hp 属性")
	# 输入源抽象(行为不变重构):根不再直接读全局 Input,且可注入
	_check(src.contains("input_source.get_axis"), "player.gd 输入走 input_source")
	_check(src.contains("func set_input_source("), "player.gd 输入可注入")
	# 三个组件文件 + class_name
	var comps: Array = [
		[lsrc, "climb_component.gd", "class_name ClimbComponent"],
		[csrc, "combat_component.gd", "class_name CombatComponent"],
		[wsrc, "weapon_component.gd", "class_name WeaponComponent"],
	]
	for pair in comps:
		_check(str(pair[0]).length() > 0 and str(pair[0]).contains(str(pair[2])),
				"含 " + str(pair[1]) + " 的 " + str(pair[2]))
	# 武器类型来自**注册表的单一来源**(2026-09-26 改写)。
	# ★ 旧断言查的是 `weapon_component.gd` 里 `"1"`..`"5"` 这几个**字符串键** —— 那是当年
	#   那份硬编码表(`WEAPONS`/`DISPLAY_NAMES`/`TIERS`)的形状。注册表那批**把那三张表整体删除**
	#   (见 docs/eng/weapons.md),于是这条断言**恒红**(`"1"` 还碰巧在别处出现,`"2"`..`"5"` 不在)
	#   —— 而它现在**断言的是新不变量的反面**:`enemy_logic_smoke` 的 ⑤b **反向**要求那三个标识符
	#   在生产目录里**零命中**(防半途迁移)。⇒ 按本仓纪律"探针因重构变红时改探针认新入口":
	#   契约改成当前形态 —— 组件的武器类型必须**取自注册表**,而不是自己再抄一份清单。
	_check(wsrc.contains("WeaponRegistry"),
			"weapon_component.gd 的武器类型取自 WeaponRegistry(单一来源)")
	# ★ 判据走 `code_only`(**剥注释**)而不是裸 `contains`:本仓爱留墓碑注释,而墓碑里很可能
	#   提到被删标识符的名字 —— 裸 contains 会**假红**,而假红的下场历来是"把断言改松"
	#   (本仓明文禁忌)。与 `enemy_logic_smoke` ⑤b 同口径。
	# ★ 用 `load()` 而不是静态引用 `ScanUtil`:`-s` 阶段静态引用测试库**没有先例**
	#   (注册表那批登记过这条未验证项),`load()` 绕开它;取不到就退化成裸源码视图,
	#   并在报告里说明(不静默弱化)。
	var su: Variant = load("res://tests/lib/scan_util.gd")
	var wcode: String = wsrc
	if su != null and su.has_method("code_only"):
		wcode = su.code_only(wsrc)
	else:
		printerr("  (注意:ScanUtil 取不到,本条退化为未剥注释的源码视图)")
	for k in ["WEAPONS", "DISPLAY_NAMES", "TIERS"]:
		_check(not wcode.contains(k),
				"weapon_component.gd 不得再有旧表 %s(半迁移守卫;与 enemy_logic_smoke ⑤b 同口径)" % k)

	# ★ 2026-10-04(审计 §2.6 的**第 4 处**):游泳组件与武器那三处**同款**的兜底已收掉。
	#   原先 `update(..., src := null)` 会在 src 缺省时**自己 new 一个**「读真实 Input」的
	#   本地输入源 —— 于是组件能从全局输入总线偷读,而且**完全不报错**。在权威服务器 /
	#   回放 / 预测下那是错的来源(headless 服务器读到的是**宿主机桌面**的按键状态)。
	#   收口后:缺 src ⇒ 点名报错 + 安全返回,组件**只**读注入进来的 src。
	#
	# ★★ 为什么这条必须是**源码守卫**(不能只靠行为):只在探针里直接调用、不传 src 时,
	#    旧兜底在 headless 下读到的轴恒 0、按键恒假 —— 与"安全返回"在**一部分**读数上
	#    重合(武器那三处更极端:只返回布尔,两版逐帧恒等 = 天生无牙)。
	#    ★ 本组件的返回值**有**鉴别力(旧兜底会返回 true 并写 parent.velocity)⇒
	#      `tests/probe/water_probe.gd` 里另有一条**行为**守卫钉同一件事,两条互补。
	# ★ 判据用 `code_only`(**剥注释**)视图:本仓爱留墓碑/解释性注释,里面一旦提到那个
	#   被禁的类名,裸 contains 会把守卫**永远喂红**(假红的下场历来是"把断言改松")。
	#   ★★ 与 `code_only` 配套的纪律(写法税):改 `swim_component.gd` 时**注释里也别写**
	#      那个类名/`Input.` 字面量 —— 本守卫在 ScanUtil 取不到时退化成**裸视图**,
	#      那时注释里的字样会真的把它喂红(见上方 `su` 那段)。
	var scode: String = ssrc
	if su != null and su.has_method("code_only"):
		scode = su.code_only(ssrc)
	# ★ 先钉"读得到源":读不到时 scode 为空串,下面三条**否定**断言全部恒真(静默假绿)。
	_check(scode.length() > 0, "读得到 swim_component.gd 源码(读不到 ⇒ 下面三条否定断言恒真)")
	_check(not scode.contains("LocalInputSource"),
			"swim_component.gd 又长出全局输入兜底(只许读注入的 src;缺 src 要点名报错,不是自己造本地输入源)")
	_check(not scode.contains("Input.is_action"),
			"swim_component.gd 在直接读全局输入(is_action_*);输入只许走注入的 src")
	_check(not scode.contains("Input.get_axis"),
			"swim_component.gd 在直接读全局输入(get_axis);输入只许走注入的 src")

	# 根每物理帧显式驱动三个组件(+ 游泳组件:它同样由根驱动,漏了就是"没人喂它输入")
	_check(src.contains("climb.update("), "根驱动 climb.update")
	_check(src.contains("swim.update("), "根驱动 swim.update")
	_check(src.contains("combat.apply_knock("), "根驱动 combat.apply_knock")
	_check(src.contains("weapons.movement_multiplier()"), "根驱动 weapons.movement_multiplier")

	if _failures.is_empty():
		print("\nCONTRACT OK")
		quit(0)
	else:
		printerr("\nCONTRACT FAIL: %d 项" % _failures.size())
		quit(1)
