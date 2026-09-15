extends ProbeBase

# KH 合并 L3 验收探针(场景模式:autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 600 res://tests/kh_l3_probe.tscn
# 期望:打印 "KH L3 PROBE: ALL-OK" 且退出码 0。
#
# 存在理由:L3(换弹玩法 + 五把枪弹夹数值 + 武器槽位闸门 + 滚轮切枪 + 残弹记忆)落地后,
# 上述新行为在 enemy_logic_smoke 里只覆盖到 equip/切枪/继承冷却,**实际装填、闸门拒绝、
# 滚轮跳过禁用槽、_mag_state 语义一条断言都没有**。本探针就是来补这个洞的。
#
# --quit-after 是安全网:本脚本引用 Settings/Level0/Sfx 等 autoload 标识符;若某个 autoload
# 被删掉,脚本编译失败 → 场景根节点无脚本 → 一行都不打印、命令挂死。有它最坏只是超时退出。
#
# ⚠️ CI 判据必须是 **grep 文本 `KH L3 PROBE: ALL-OK`**,不能只看退出码:
#    探针中途脚本报错(解析失败/函数中断)时,--quit-after 仍会以 **exit 0** 退出,
#    且**不会**打印 ALL-OK(也不打 FAIL)——只看退出码会把"没跑完"读成"通过"。

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const WEAPON_BASE_SRC := "res://scenes/weapons/weapon_base.gd"
const WEAPON_COMPONENT_SRC := "res://scenes/player/weapon_component.gd"
const PLAYER_SRC := "res://scenes/player/player.gd"
const LEVEL0_SRC := "res://scenes/level_0.gd"

# 每把枪的期望数值(验收值;改 tscn 数值而不改本表 = 红)。
# 激光枪(槽6)按规格**不带**弹夹数值:tscn 里没有 mag_size/reload_time → 走 WeaponBase 默认(12 / 1.2)。
const EXPECTED := [
	{"slot": 1, "path": "res://scenes/weapons/pistol_test.tscn", "name": "Pistol", "mag": 12, "reload": 1.0, "live": 0},
	{"slot": 2, "path": "res://scenes/weapons/rifle_test.tscn", "name": "Rifle", "mag": 30, "reload": 1.8, "live": 0},
	{"slot": 3, "path": "res://scenes/weapons/m82a1.tscn", "name": "M82A1", "mag": 5, "reload": 2.6, "live": 0},
	{"slot": 4, "path": "res://scenes/weapons/s686.tscn", "name": "S686", "mag": 2, "reload": 2.2, "live": 0},
	{"slot": 5, "path": "res://scenes/weapons/grenade_launcher.tscn", "name": "Grenade Launcher", "mag": 4, "reload": 2.8, "live": 3},
	{"slot": 6, "path": "res://scenes/weapons/laser_gun.tscn", "name": "Laser Gun", "mag": 12, "reload": 1.2, "live": 0},
]


# 换弹测试用的**桩玩家**:只需要 weapon_base 关心的三个口(倒地/朝向/后坐)。
# 用桩而不用真实 Player 的原因:真实 Player 每物理帧会 weapons.tick() → 自动推进 _reload_t,
# 换弹状态机就不可复现了;桩装备的枪只由本探针显式 tick(dt) 推进 —— 帧率无关。
class StubPlayer extends Node2D:
	func is_downed() -> bool: return false
	func get_facing() -> int: return 1
	func apply_recoil(_push: float) -> void: pass


# 只回「按住 R」的输入源桩(4b 换弹链路用):验**编码端**把换弹位真的写进输入包。
# 用桩而不是模拟真实按键:探针不该依赖 Input 全局状态(headless 下也一样),而且要确定性。
# 其余读口**必须**逐个覆写 —— pack_record 会把轴/四个动作/切枪挨个问一遍,漏一个就会撞上
# 基类的 push_error 兜底,刷一屏假报错把真断言淹掉。
class ReloadSrc extends PlayerInput:
	func source_kind() -> int: return Kind.LOCAL
	func _axis_raw(_neg: String, _pos: String) -> float: return 0.0
	func _action_pressed_raw(action: String) -> bool: return action == "R"
	func _action_just_pressed_raw(action: String) -> bool: return action == "R"
	func _action_just_released_raw(_action: String) -> bool: return false
	func _weapon_slot_raw() -> int: return 0


# 探针短名:拼 ALL-OK / FAIL / 汇总行的方括号前缀用(ProbeBase 的必需覆写项)。
func probe_id() -> String:
	return "L3"


func _ready() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户开着 pvp。
	Level0.pvp_mode = false

	await _check_weapon_numbers()

	# 真实 player.tscn(闸门/滚轮/残弹记忆都用它)
	var player_scene: PackedScene = load(PLAYER_SCENE)
	if player_scene == null:
		_failures.append("player.tscn 载入失败,闸门/滚轮/残弹记忆无法验证")
		_finish()
		return
	var player: Node = player_scene.instantiate()
	add_child(player)
	# 关掉玩家物理:本探针只验武器子系统,不要被重力/落地/自动 tick 干扰
	player.set_physics_process(false)
	await _frames(3)
	var wep: WeaponComponent = player.weapons
	if wep == null:
		_failures.append("player.tscn 上没有 Weapons 组件")
		_finish()
		return

	await _check_gate(wep)
	await _check_cycle(wep)
	await _check_mag_memory(wep)
	await _check_same_frame_cycle(wep)
	await _check_reload_state_machine(player, wep)
	_check_tick_guards(player, wep)

	_finish()


# ── 1) 弹夹数值落位(逐把真实 tscn 实例)──────────────────────────────
func _check_weapon_numbers() -> void:
	for spec in EXPECTED:
		var scene: PackedScene = load(spec["path"])
		var tag := "槽%d %s" % [spec["slot"], spec["name"]]
		if scene == null:
			_failures.append("%s: 场景载入失败 %s" % [tag, spec["path"]])
			continue
		# as WeaponBase 而非 `var w: WeaponBase = ...`:**根节点类型不对时**静态赋值会中断
		# 本函数(后面的断言一条都不跑 = 静默假绿);`as` 转换失败只返回 null,能被断言抓到。
		var w := scene.instantiate() as WeaponBase
		_check(w != null, "%s: 场景根节点不是 WeaponBase(instantiate/as 转换失败,%s)" % [tag, spec["path"]])
		if w != null:
			add_child(w)
			await get_tree().process_frame
			_check(w.weapon_name == spec["name"],
					"%s: weapon_name=%s(期望 %s)" % [tag, w.weapon_name, spec["name"]])
			_check(w.mag_size == spec["mag"],
					"%s: mag_size=%d(期望 %d)" % [tag, w.mag_size, spec["mag"]])
			_check(is_equal_approx(w.reload_time, spec["reload"]),
					"%s: reload_time=%.2f(期望 %.2f)" % [tag, w.reload_time, spec["reload"]])
			_check(w.max_live_projectiles == spec["live"],
					"%s: max_live_projectiles=%d(期望 %d)" % [tag, w.max_live_projectiles, spec["live"]])
			# 入树(_ready)即上满弹夹 —— 否则开局第一枪是空枪
			_check(w.mag_ammo == spec["mag"],
					"%s: 入树后 mag_ammo=%d(应 = mag_size %d)" % [tag, w.mag_ammo, spec["mag"]])
			w.queue_free()
		await get_tree().process_frame


# ── 2) 槽位闸门(真实 Player 上的 WeaponComponent)────────────────────
func _check_gate(wep: WeaponComponent) -> void:
	# 入参是「被禁用」的槽位表(set_enabled_slots(disabled))
	wep.set_enabled_slots([1, 2])
	await _frames(3)
	_check(not wep.is_slot_enabled(1), "set_enabled_slots([1,2]) 后槽1 仍启用(过滤器失效)")
	_check(not wep.is_slot_enabled(2), "set_enabled_slots([1,2]) 后槽2 仍启用(过滤器失效)")
	_check(wep.is_slot_enabled(3), "set_enabled_slots([1,2]) 后槽3 应仍启用")
	_check(wep.enabled_slots.size() == 4, "set_enabled_slots([1,2]) 后启用表应剩 4 项(实际 %s)" % str(wep.enabled_slots))

	var d := wep.default_slot()
	_check(d != "1" and d != "2", "默认槽位落在被禁槽位:%s" % d)
	# 当前拿着的枪(槽1)被禁 → set_enabled_slots 内应自动切到默认槽
	var slot_after_gate := wep.current_slot_int()
	_check(slot_after_gate == 3,
			"当前枪被禁后未自动切到默认槽(实际槽位 %d,期望 3)" % slot_after_gate)

	# equip 被闸门拒绝:槽位不变
	wep.equip("1")
	await _frames(2)
	_check(wep.current_slot_int() == slot_after_gate,
			"equip(\"1\") 未被闸门拒绝(槽位 %d → %d)" % [slot_after_gate, wep.current_slot_int()])
	# 反向锚:同样调用一次**允许**的槽位,必须真的切过去(证明"不切"不是 equip 整体坏掉)
	wep.equip("4")
	await _frames(3)
	_check(wep.current_slot_int() == 4, "equip(\"4\") 应正常切换到槽4(实际 %d)" % wep.current_slot_int())

	# 全禁 → 兜底非空(KH 的兜底是 [1]),否则出生即空手
	wep.set_enabled_slots([1, 2, 3, 4, 5, 6])
	await _frames(3)
	_check(not wep.enabled_slots.is_empty(), "全禁后 enabled_slots 为空(兜底缺失)")
	_check(wep.is_slot_enabled(1), "全禁后兜底不是 [1](实际启用表 %s)" % str(wep.enabled_slots))
	_check(wep.enabled_slots.size() == 1, "全禁后应兜底为恰好一把(实际 %s)" % str(wep.enabled_slots))

	wep.set_enabled_slots([])   # 恢复全开
	await _frames(3)


# ── 3) 滚轮切枪跳过禁用槽 ────────────────────────────────────────────
func _check_cycle(wep: WeaponComponent) -> void:
	wep.set_enabled_slots([])
	wep.equip("1")
	await _frames(3)
	_check(wep.current_slot_int() == 1, "滚轮前置:未切到槽1(实际 %d)" % wep.current_slot_int())

	# 只禁槽2 → 启用表 [1,3,4,5,6];正向滚轮从 1 出发必须**跳过 2** 落到 3
	wep.set_enabled_slots([2])
	await _frames(3)
	_check(wep.current_slot_int() == 1, "只禁槽2 时不应改变当前槽(实际 %d)" % wep.current_slot_int())
	wep.cycle_slot(1)
	await _frames(3)
	_check(wep.current_slot_int() == 3,
			"正向滚轮从槽1 应跳过被禁的槽2 落到槽3(实际 %d;=2 说明没跳过禁用槽)" % wep.current_slot_int())
	# 反向:从 3 往回也必须跳过被禁的 2
	wep.cycle_slot(-1)
	await _frames(3)
	_check(wep.current_slot_int() == 1,
			"反向滚轮从槽3 应跳过被禁的槽2 回到槽1(实际 %d)" % wep.current_slot_int())

	# 只启用一把枪:滚轮不应改变槽位(且不崩)
	# 注:本段两次 cycle_slot 之间 await 一帧,测的是**跨帧的普通路径**(滚轮一跳一帧)。
	# 同帧连切两次的 deferred 竞态另有一条真断言,见 _check_same_frame_cycle()。
	wep.set_enabled_slots([1, 3, 4, 5, 6])   # 只留槽 2 启用
	await _frames(3)
	_check(wep.current_slot_int() == 2,
			"只启用槽2 时当前槽位应自动落到 2(实际 %d)" % wep.current_slot_int())
	wep.cycle_slot(1)
	await _frames(3)
	_check(wep.current_slot_int() == 2,
			"只有一把启用枪时正向滚轮不应改变槽位(实际 %d)" % wep.current_slot_int())
	wep.cycle_slot(-1)
	await _frames(3)
	_check(wep.current_slot_int() == 2,
			"只有一把启用枪时反向滚轮不应改变槽位(实际 %d)" % wep.current_slot_int())

	wep.set_enabled_slots([])
	await _frames(3)


# ── 4) 换弹状态机(真实武器实例 + 桩玩家;手动 tick 推进,帧率无关)+ 网络输入源闸门 ──
# player/wep 两个参数仅供「网络输入源 → 不换弹」这条真实链路断言用(必修 1 回归钉)。

# hoisted from locals when __check_reload_state_machine was split (first assignment kept in place).
var w: WeaponBase = null
var stub: Node = null
var _aborted: bool = false
func _check_reload_state_machine(player: Node, wep: WeaponComponent) -> void:
	# 每段后查 _aborted:段内原来的 `return` 退出的是**整个函数**,拆完只退出该段。
	await _check_reload_core(player, wep)
	if _aborted:
		return
	await _check_network_gate(player, wep)
	if _aborted:
		return

# ── 5) 残弹记忆语义(切走记住、切回恢复,**不回满**)──────────────────
func _check_mag_memory(wep: WeaponComponent) -> void:
	wep.set_enabled_slots([])
	wep.equip("1")
	await _frames(3)
	var w: WeaponBase = wep.current_weapon()
	if w == null or w.mag_size != 12:
		_failures.append("残弹记忆前置:槽1 未拿到手枪(weapon=%s)" % str(w))
		return
	_check(w.mag_ammo == 12, "残弹记忆前置:满弹应为 12(实际 %d)" % w.mag_ammo)

	w.mag_ammo = 5              # 模拟打了 7 发
	wep.equip("2")              # 切走 → 应记住槽1 的 5
	await _frames(3)
	_check(wep.current_slot_int() == 2, "残弹记忆:未切到槽2(实际 %d)" % wep.current_slot_int())
	var rifle: WeaponBase = wep.current_weapon()
	_check(rifle != null and rifle.mag_size == 30, "残弹记忆:槽2 未拿到步枪")
	_check(rifle != null and rifle.mag_ammo == 30, "残弹记忆:步枪入树应为满弹 30(实际 %s)" % str(rifle.mag_ammo))

	wep.equip("1")              # 切回 → 必须是 5,不是 12
	await _frames(3)
	_check(wep.current_slot_int() == 1, "残弹记忆:未切回槽1(实际 %d)" % wep.current_slot_int())
	var back: WeaponBase = wep.current_weapon()
	if back == null:
		_failures.append("残弹记忆:切回槽1 未拿到武器")
		return
	_check(back.mag_ammo == 5,
			"切回槽1 残弹未恢复为切走时的值(实际 %d,期望 5;=12 即「切枪回满弹」漏洞)" % back.mag_ammo)


# ── 5b) ★ 同帧两次 equip:未入树的枪不得被记账(残弹被抹成 0)────────────
# 竞态(修前为真 bug):equip() 用 call_deferred("add_child", 新枪) 入树,**_ready 要到帧末才跑**,
# 而 mag_ammo 满弹是在 _ready 里设的 → 新枪在入树前 mag_ammo 恒为 0。若同帧再 equip 一次,
# 第二次的「旧武器」正是这把未入树的枪,照记 `_mag_state[old_slot] = _weapon.mag_ammo`
# 就把**被略过的那个中间槽**记成 0;之后切回该槽 → 只拿到 0 残弹(不是回满),fire() 靠
# start_reload() 自愈 = 交火中白交一次 1.0~2.8s 装填。它坏掉的正是 L3 要交付的「残弹记忆」。
# 真机可达路径:滚轮走 player.gd 的 _unhandled_input(事件驱动,每个 InputEventMouseButton
# 一次 cycle_slot),Godot 一帧内会把缓冲的 OS 事件一次性泵完 → 快拨/惯性滚轮/精密触控板
# 能在一帧里发两次 cycle_slot。(「真机滚轮天然跨帧」的说法不成立,不要据此放宽。)
# 本函数**刻意不插 await**:如实制造同帧场景,让 CI 真的看得见这个 bug。
func _check_same_frame_cycle(wep: WeaponComponent) -> void:
	wep.set_enabled_slots([])   # 全开
	wep.equip("1")
	await _frames(3)
	if wep.current_slot_int() != 1:
		_failures.append("同帧切枪前置:未到槽1(实际 %d)" % wep.current_slot_int())
		return

	# 前置:先把槽2 的残弹记成**非满值** 17 —— 否则被抹掉的是 0、断言恒真抓不到 bug
	wep.equip("2")
	await _frames(3)
	var rifle: WeaponBase = wep.current_weapon()
	if rifle == null or rifle.mag_size != 30:
		_failures.append("同帧切枪前置:槽2 未拿到步枪(weapon=%s)" % str(rifle))
		return
	rifle.mag_ammo = 17
	wep.equip("3")              # 切走 → _mag_state[2] = 17
	await _frames(3)
	wep.equip("1")              # 回槽1,准备同帧连切
	await _frames(3)
	_check(wep.current_slot_int() == 1, "同帧切枪前置:未回到槽1(实际 %d)" % wep.current_slot_int())

	# ★ 同帧两次 cycle_slot(1):1 → 2 → 3,槽2 是被"略过"的中间槽。
	# 两次调用之间**没有 await** → 第二次 equip 看到的旧武器(槽2 的步枪)还没入树。
	wep.cycle_slot(1)
	wep.cycle_slot(1)
	await _frames(3)
	_check(wep.current_slot_int() == 3,
			"同帧两次滚轮应从槽1 经槽2 落到槽3(实际 %d)" % wep.current_slot_int())

	# 切回槽2:残弹必须仍是切走时的 17 —— =0 即未入树的枪被记账抹掉了(=30 即残弹记忆整体失效)
	wep.equip("2")
	await _frames(3)
	var back: WeaponBase = wep.current_weapon()
	if back == null:
		_failures.append("同帧切枪:切回槽2 未拿到武器")
		return
	_check(back.mag_ammo == 17,
			"同帧两次滚轮把被略过的槽2 残弹抹掉了(实际 %d,期望 17;=0 即未入树的枪被记进 _mag_state,=30 即残弹记忆失效)" % back.mag_ammo)


# ── 6) ★ 守卫点:帧逻辑必须走 tick(),不许回到 _process ──────────────
# 源码读进来先剥纯注释行(_code_only):下面全是纯文本 contains(),不过滤的话
# 「注释里写出来的字面量」既会误绿(`# weapons.tick(delta)` 被注释掉照样命中),
# 也会误红(weapon_base.gd 的注释里出现过裸 `_process` 字样)。
func _check_tick_guards(player: Node, wep: WeaponComponent) -> void:
	var wb_src := _code_only(_read(WEAPON_BASE_SRC))
	var wc_src := _code_only(_read(WEAPON_COMPONENT_SRC))
	var pl_src := _code_only(_read(PLAYER_SRC))
	var lv_src := _code_only(_read(LEVEL0_SRC))
	_check(wb_src != "", "读不到 %s" % WEAPON_BASE_SRC)
	_check(wc_src != "", "读不到 %s" % WEAPON_COMPONENT_SRC)
	_check(pl_src != "", "读不到 %s" % PLAYER_SRC)

	_check(wb_src.contains("func tick("), "weapon_base.gd 的 tick() 被删了(帧逻辑必须由 Player 显式驱动)")
	_check(wc_src.contains("func tick("), "weapon_component.gd 的 tick() 被删了")
	_check(not wb_src.contains("func _process"), "weapon_base.gd 又长出 _process(帧逻辑必须走 tick,rollback 需要确定性)")
	_check(not wc_src.contains("func _process"), "weapon_component.gd 又长出 _process")
	_check(pl_src.contains("weapons.tick(delta)"), "player.gd 不再每物理帧驱动 weapons.tick(delta)")

	# 运行时口:实例上真的能调到 tick
	var inst: WeaponBase = wep.current_weapon()
	_check(inst != null, "守卫点:当前没有武器实例可供 has_method 检查")
	if inst != null:
		_check(inst.has_method("tick"), "WeaponBase 实例上没有 tick 方法")
	_check(wep.has_method("tick"), "WeaponComponent 实例上没有 tick 方法")
	_check(player.has_method("get_aim_dir_override"),
			"player.gd 的注入输入钩子 get_aim_dir_override() 丢了(守卫点 = L3 头号不变量表 #4–10 的 player.gd 行;丢了服务器瞄准会去读宿主鼠标)")

	# L3 接线:开局选项禁用的武器必须真的落到武器组件上(否则选项形同虚设)
	_check(lv_src.contains("set_enabled_slots(RunOptions.disabled_weapons)"),
			"level_0.gd 未把 RunOptions.disabled_weapons 应用给武器组件")


func _bullets() -> int:
	return get_tree().get_nodes_in_group("bullet").size()


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check_reload_core(player: Node, wep: WeaponComponent) -> void:
	stub = StubPlayer.new()
	add_child(stub)
	var scene: PackedScene = load("res://scenes/weapons/pistol_test.tscn")
	if scene == null:
		_failures.append("换弹测试:手枪场景载入失败")
		_aborted = true
		return
	w = scene.instantiate()
	add_child(w)
	await get_tree().process_frame
	w.equip(stub)

	# (原先这里断言 `w.reload_active()` —— 那道闸门 2026-09-15 已删,换弹恒开。改成断言
	#  "开局是满弹":它才是下面"装填中不出弹/不扣弹"那条对照的前提。)
	_check(w.mag_ammo == w.mag_size,
			"换弹玩法前置:入树后应是满弹(mag_ammo=%d / %d)" % [w.mag_ammo, w.mag_size])

	# 对照(反恒真):非装填态 fire() 必须真的出弹 + 扣弹 —— 证明下面的"装填中不出弹"有意义
	var n0 := _bullets()
	w.fire()
	var n1 := _bullets()
	_check(n1 == n0 + 1, "对照:非装填态 fire() 未出弹(场上弹数 %d → %d)" % [n0, n1])
	_check(w.mag_ammo == w.mag_size - 1,
			"对照:非装填态 fire() 未扣弹(mag_ammo=%d,应 %d)" % [w.mag_ammo, w.mag_size - 1])

	# 进入装填
	w.fire_cd_timer = 0.0
	w.mag_ammo = 3
	w.start_reload()
	_check(w.is_reloading(), "start_reload() 后 is_reloading() 仍为假")
	# 起步进度必须 ≈0 —— 闭区间 [0,1] 判据抓不到「倒着走(起步 1.0)」与「恒值 0.5」两种坏实现
	var p0 := w.reload_progress()
	_check(p0 < 1e-3, "reload_progress() 起步应≈0(实际 %.3f;≈1 即进度倒着走,≈0.5 即恒值)" % p0)

	# 装填中开火:不出弹、不扣弹、不烧冷却
	var n2 := _bullets()
	w.fire_cd_timer = 0.0
	w.fire()
	_check(w.mag_ammo == 3, "装填中 fire() 消耗了弹药(mag_ammo=%d,应仍为 3)" % w.mag_ammo)
	_check(_bullets() == n2, "装填中 fire() 出了弹(场上弹数 %d → %d)" % [n2, _bullets()])
	_check(w.fire_cd_timer == 0.0, "装填中 fire() 烧了冷却(fire_cd_timer=%.3f)" % w.fire_cd_timer)

	# 手动推进到中段:进度严格在 (0,1) 且**方向/速率正确**
	_check(is_equal_approx(w.reload_time, 1.0),
			"换弹进度断言依赖手枪 reload_time=1.0(实际 %.3f;改了弹夹表就要同步改本断言)" % w.reload_time)
	w.tick(0.5)
	var pm := w.reload_progress()
	_check(pm > 0.0 and pm < 1.0, "tick(0.5) 后 reload_progress=%.3f 不在 (0,1) 开区间" % pm)
	# 0.5s / reload_time 1.0 → 进度必须≈0.5(自指的「两边取同一个函数」抓不到恒值/倒走,这条抓得到)
	_check(absf(pm - 0.5) < 0.02, "tick(0.5) 后 reload_progress=%.3f 偏离 0.5(应 0.5±0.02)" % pm)
	_check(w.is_reloading(), "推进到中段后 is_reloading() 变假了")

	# 推进到完成(手动 tick,不依赖真实时间)
	var guard := 0
	while w.is_reloading() and guard < 200:
		w.tick(0.05)
		guard += 1
	_check(not w.is_reloading(), "tick 推进 %d 次后仍在装填" % guard)
	_check(w.mag_ammo == w.mag_size, "装填完成未补满弹夹(mag_ammo=%d / %d)" % [w.mag_ammo, w.mag_size])
	_check(w.reload_progress() < 0.0,
			"装填完成后 reload_progress() 应返回 -1(实际 %.3f)" % w.reload_progress())

func _check_network_gate(player: Node, wep: WeaponComponent) -> void:

	# ── 4b) PvP 换弹链路(2026-09-15 契约反转)────────────────────────────
	# ★ 本函数原先钉的是**相反**的契约:「PvP/网络输入源一律不许换弹」(reload_active() 恒 false)。
	#   那道闸门 2026-09-15 已整个删除,换弹对全模式开放 —— 于是这里的断言必须整段重写,
	#   改钉**新链路的每一环**。为什么每一环都要钉:"哪一环忘了接"的表现全是静默的
	#   (R 没反应 / 服务器不换弹 / 回滚重放飘),没有断言就只能等玩家报"PvP 换弹坏了"。
	# 链路:① 编码端写位 → ② 解码端读位 → ③ 权威玩家真的进装填 → ④ 弹药进整态
	#       → ⑤ 反向:闸门不得复活。
	_check(Level0.pvp_mode == false, "前置:本钉要求 pvp_mode 为 false(实际 %s)" % str(Level0.pvp_mode))

	# ① 编码端:按住 R 必须写进 held/pressed 两个掩码(服务器只认边沿,但 held 供日后长按语义)
	var packed := PacketInputSource.pack_record(ReloadSrc.new(), 1, Vector2.RIGHT)
	_check(int(packed.get("held", 0)) & PacketInputSource.BIT_RELOAD != 0,
			"输入包编码端漏了换弹位:held 里没有 BIT_RELOAD(服务器收不到 R)")
	_check(int(packed.get("pressed", 0)) & PacketInputSource.BIT_RELOAD != 0,
			"输入包编码端漏了换弹边沿:pressed 里没有 BIT_RELOAD(装填只在边沿触发,等于没换弹)")

	# ② 解码端:_bit("R") 必须映射到 BIT_RELOAD(原先它恒返回 0 —— 这正是"服务器没有通路"的那一环)
	var decoded := PacketInputSource.new()
	decoded.apply_packet({"ax": 0.0, "held": 0, "pressed": PacketInputSource.BIT_RELOAD,
			"released": 0, "weapon": 0, "aim": Vector2.RIGHT})
	_check(decoded.is_action_just_pressed("R"),
			"输入包解码端漏了换弹:_bit(\"R\") 未映射到 BIT_RELOAD,pressed 位读不出来")

	# ③ 真链路:真 player.tscn 注入 PacketInputSource + 带 R 边沿的包 → 权威物理帧必须进装填。
	#    这是"权威服务器会换弹"的唯一实证 —— 服务器没有输入事件,全靠这条路径。
	var real_w: WeaponBase = wep.current_weapon()
	if real_w == null:
		_failures.append("PvP 换弹:Player 当前没有武器实例,真实链路无法验证")
	else:
		var prev_src: PlayerInput = player.input_source
		var net_src := PacketInputSource.new()
		net_src.apply_packet({"ax": 0.0, "held": 0, "pressed": PacketInputSource.BIT_RELOAD,
				"released": 0, "weapon": 0, "aim": Vector2.RIGHT})
		player.set_input_source(net_src)
		_check(player.input_is_network(), "注入 PacketInputSource 后 player.input_is_network() 仍为假")
		real_w.mag_ammo = 3        # 不满弹,start_reload() 才有活干
		real_w._reloading = false
		real_w._reload_t = 0.0
		player._physics_process(1.0 / 60.0)
		_check(real_w.is_reloading(),
				"权威链路断了:带 R 边沿的输入包 + 一个物理帧没能让武器进装填(服务器永不换弹)")
		# ④ 整态:弹药/装填必须在 capture_state 里,否则 rollback 重放不是复现而是新历史
		var cap: Dictionary = player.capture_state()
		_check(cap.has("mag") and cap.has("rld") and cap.has("rld_t"),
				"整态漏了换弹字段:capture_state 里没有 mag/rld/rld_t(rollback 重放不确定)")
		# ⑤ (负向对照)非边沿不触发:没有 R 边沿的包不得让武器进装填。
		# ★ 必须先 clear_edges():PacketInputSource 的边沿是**累积**的(|=),靠 MatchHost
		#   每 tick 末 clear_edges() 清空 —— 生产里"上一包的边沿"活不过一个 tick,探针
		#   不照做就会拿上一包的 R 去打自己的负向对照(本探针第一版就是这么假红的)。
		real_w._reloading = false
		real_w.mag_ammo = 3
		net_src.clear_edges()
		net_src.apply_packet({"ax": 0.0, "held": 0, "pressed": 0,
				"released": 0, "weapon": 0, "aim": Vector2.RIGHT})
		player._physics_process(1.0 / 60.0)
		_check(not real_w.is_reloading(), "负向对照失败:没有 R 边沿的包也让武器进了装填")
		player.set_input_source(prev_src)
		_check(not player.input_is_network(), "复原本地输入源后 input_is_network() 应为假")
		real_w._reloading = false   # 别把装填态留给后面的段

	# ⑤ 反向:闸门若复活(源码里又出现 reload_active),上面整条链路的语义就不再是本意 ——
	#    红在这一条比红在任何一条行为断言都更早、更指向原因。(注释行已被 _code_only 剥掉。)
	var wb_src := _code_only(_read(WEAPON_BASE_SRC))
	_check(not wb_src.contains("reload_active"),
			"换弹闸门复活了:weapon_base.gd 里又出现 reload_active()(全模式开放后它不该存在)")

	w.queue_free()
	stub.queue_free()
	await get_tree().process_frame