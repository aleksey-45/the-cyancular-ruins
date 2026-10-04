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

# 值相等的断言：红的时候把 got/want 一起打出来（§2.6 那几处"安全返回"是**值**契约，
# 只报"某条失败了"看不出它退化成了什么）。
func _check_eq(a, b, name: String) -> void:
	if a == b:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL: %s (got %s want %s)" % [name, a, b])

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

	# ★ 2026-10-04(审计 §2.6 的**第 5 处** —— 审计那句"4 处"本身漏了它):攀爬组件里那处兜底与
	#   武器三处 / 游泳那处**逐字同款**(连注释都是同一句),已在本次收掉。原先 `update(..., src := null)`
	#   缺 src 时**自己 new 一个**「读真实 Input」的本地输入源 ⇒ 组件能从全局输入总线偷读,
	#   而且**完全不报错**;权威服务器 / 回放 / 预测下那是错的来源(headless 服务器读到的是
	#   **宿主机桌面**的按键状态)。收口后:缺 src ⇒ 点名报错 + 按「没在攀爬」安全返回,
	#   组件**只**读注入进来的 src。
	# ★ 判据与上面游泳那段同口径:`code_only`(剥注释)视图 + 先钉"读得到源"(读不到时
	#   下面三条**否定**断言全部恒真 ⇒ 删掉/读不到该文件反而"变绿")。
	var lcode: String = lsrc
	if su != null and su.has_method("code_only"):
		lcode = su.code_only(lsrc)
	_check(lcode.length() > 0, "读得到 climb_component.gd 源码(读不到 ⇒ 下面三条否定断言恒真)")
	_check(not lcode.contains("LocalInputSource"),
			"climb_component.gd 又长出全局输入兜底(只许读注入的 src;缺 src 要点名报错,不是自己造本地输入源)")
	_check(not lcode.contains("Input.is_action"),
			"climb_component.gd 在直接读全局输入(is_action_*);输入只许走注入的 src")
	_check(not lcode.contains("Input.get_axis"),
			"climb_component.gd 在直接读全局输入(get_axis);输入只许走注入的 src")

	# 根每物理帧显式驱动三个组件(+ 游泳组件:它同样由根驱动,漏了就是"没人喂它输入")
	_check(src.contains("climb.update("), "根驱动 climb.update")
	_check(src.contains("swim.update("), "根驱动 swim.update")
	_check(src.contains("combat.apply_knock("), "根驱动 combat.apply_knock")
	_check(src.contains("weapons.movement_multiplier()"), "根驱动 weapons.movement_multiplier")

	# ── 攀爬组件:缺 src 的**行为**契约(2026-10-04,审计 §2.6 的**第 5 处**)────────────────
	# ★★ 先回答"本处的行为守卫有没有牙"(动手前必须答的那个问题):**有** —— 与武器那三处不同。
	#   · 武器那三处**无牙**:兜底只决定**返回哪个布尔**,而 headless 下全局总线读出来恒空
	#     ⇒ "自造本地源"与"安全返回 false"逐帧恒等、行为上不可分(只能靠源码守卫)。
	#   · 本处**有牙**,两条理由:① 旧兜底**不只决定返回值** —— 它会继续走完攀爬分支,
	#     写 `body.velocity.y` 并置 `_latched`;② "headless 全局总线恒空"这个前提**在探针里不成立**：
	#     探针可以 `Input.action_press("up")` 驱动全局总线(`climb_probe` 就是这么爬梯子的)
	#     ⇒ 旧兜底会**真的抓住梯子往上爬**。所以下面三条断言**能红**(见报告里的改前原文)。
	#   ★ 源码形状那一半在上面 `lcode` 那段;两条互补,不是替代。
	# ⚠ 本相**故意**触发一条 push_error(缺 src 就是要点名报错)⇒ 绿灯运行时 stderr 里也会有
	#   一行 ERROR,那是**预期输出**;本冒烟的判据是文本 `CONTRACT OK`,不是"stderr 无 ERROR"。
	TileDefs.load_defs()
	MazeGenerator.current_grid = _climb_grid()
	var cl_host := ClimbHost.new()
	cl_host.position = Vector2(96.0, 96.0)     # 合成图格 (1,1) 正中(全图都是梯子格)
	var cl := ClimbComponent.new()
	# ★ 这里**显式**接 body(而不是 `root.add_child` + 等 `_ready`):`-s` 阶段在 `_initialize` 里
	#   往 `root` 挂节点**不会**立刻触发 `_ready`(实测:body 是 null ⇒ 函数在 `body.global_position`
	#   那一行中途炸掉,于是"红"的原因变成 nil 访问 = 假红)。这一行就是 `ClimbComponent._ready` 里那一行的同款赋值。
	cl.body = cl_host
	Input.action_press("up")
	var probe_src := LocalInputSource.new()
	# ★ 前提断言**必须放最前**:全局总线上"上"没被按到时,旧兜底同样不会爬 ⇒ 下面三条恒真(静默假绿)。
	_check(probe_src.get_axis("up", "down") < 0.0 and probe_src.is_action_just_pressed("up"),
			"缺 src 相前提:此刻全局总线上的 up 应是「刚按下」(不然旧兜底也不会爬,下面三条恒真)")
	# 正向对照:同一场景**给** src 时确实会攀附 ⇒ 证明本相够得着攀爬分支(它红了,下面那条"绿"就不算数)。
	cl._latched = false
	cl_host.velocity = Vector2.ZERO
	_check(cl.update(Vector2.ONE, 1.0 / 60.0, false, probe_src) and cl.is_latched()
			and cl_host.velocity.y < 0.0,
			"正向对照:注入 src + 全局按上 ⇒ 该抓梯上爬并写负的 velocity.y(本相够得着攀爬分支)")
	# 缺 src:点名报错 + 按「没在攀爬」返回 + `_latched` 归位 + **不碰** body 物理。
	# ★ `_latched` 归位是**本任务新增的语义**(旧兜底那条路会把它置真):根在 `player.gd:261`
	#   读的正是 `is_latched()`(不是返回值),留着上一帧的攀附态 = 让根继续跳过重力把玩家挂在半空。
	cl._latched = true
	cl_host.velocity = Vector2(0.0, 123.0)
	var got: bool = cl.update(Vector2.ONE, 1.0 / 60.0, false)
	_check_eq(got, false, "攀爬组件缺 src 必须安全返回 false(旧兜底自造本地输入源 ⇒ 抓梯上爬并返回 true)")
	_check_eq(cl.is_latched(), false, "攀爬组件缺 src 时 _latched 必须归位(旧兜底会把它置真/留在真)")
	_check_eq(cl_host.velocity, Vector2(0.0, 123.0), "攀爬组件缺 src 时不得写 body.velocity(旧兜底会写成 -576 一带)")
	Input.action_release("up")
	cl.free()
	cl_host.free()

	if _failures.is_empty():
		print("\nCONTRACT OK")
		quit(0)
	else:
		printerr("\nCONTRACT FAIL: %d 项" % _failures.size())
		quit(1)


# 缺 src 相用的裸宿主:攀爬组件只碰 global_position / velocity,外加时间场那条判据要读的
# `pvp_haste_mult`(TimeField.current 在 -s 阶段恒 null ⇒ 走 `body.get("pvp_haste_mult")`)。
# ★ 必须给这个字段:没有它 `float(null)` 会让**旧兜底那版**在函数中途报错,
#   于是"红"的原因变成类型转换而不是我们要钉的契约(假红,证据不可用)。
class ClimbHost extends CharacterBody2D:
	var pvp_haste_mult := 1.0


# 4×4 合成图,全是梯子格(tex 11,`data/tile_defs.json` 里 climb_speed=1.6)。
# 为什么全图都是梯子:这一相只问"缺 src 时会不会去读全局输入",不需要梯顶/锁链那类边界;
# 全图通道保证中心格与脚底格**都在通道里** ⇒ 旧兜底若真去读全局输入,一定走"上爬"那一支。
func _climb_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(4):
		var row: Array[int] = []
		for x in range(4):
			row.append(MazeGenerator.pack(11, 15))
		grid.append(row)
	return grid
