extends Node

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

const PLAYER_SCENE := "res://scenes/player/Player.tscn"
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

var _failures: Array[String] = []


# 换弹测试用的**桩玩家**:只需要 weapon_base 关心的三个口(倒地/朝向/后坐)。
# 用桩而不用真实 Player 的原因:真实 Player 每物理帧会 weapons.tick() → 自动推进 _reload_t,
# 换弹状态机就不可复现了;桩装备的枪只由本探针显式 tick(dt) 推进 —— 帧率无关。
class StubPlayer extends Node2D:
	func is_downed() -> bool: return false
	func get_facing() -> int: return 1
	func apply_recoil(_push: float) -> void: pass


# 网络输入源桩(必修 1 回归钉用):与 StubPlayer 同款,只多一个 input_is_network() -> true,
# 模拟 PvP 权威服务器/远端副本上的玩家(它们由 NetworkInputSource 驱动)。
class NetStubPlayer extends Node2D:
	func is_downed() -> bool: return false
	func get_facing() -> int: return 1
	func apply_recoil(_push: float) -> void: pass
	func input_is_network() -> bool: return true


func _ready() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户关掉换弹/开着 pvp。
	Settings.reload_enabled = true
	Level0.pvp_mode = false

	await _check_weapon_numbers()

	# 真实 Player.tscn(闸门/滚轮/残弹记忆都用它)
	var player_scene: PackedScene = load(PLAYER_SCENE)
	if player_scene == null:
		_failures.append("Player.tscn 载入失败,闸门/滚轮/残弹记忆无法验证")
		_finish()
		return
	var player: Node = player_scene.instantiate()
	add_child(player)
	# 关掉玩家物理:本探针只验武器子系统,不要被重力/落地/自动 tick 干扰
	player.set_physics_process(false)
	await _frames(3)
	var wep: WeaponComponent = player.weapons
	if wep == null:
		_failures.append("Player.tscn 上没有 Weapons 组件")
		_finish()
		return

	await _check_gate(wep)
	await _check_cycle(wep)
	await _check_mag_memory(wep)
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
	# 注:两次 cycle_slot 之间必须 await 一帧。同帧连切两次会踩到 equip 的 deferred 竞态
	# (旧武器还没 add_child/_ready 就被第二次 equip queue_free → 它的 mag_ammo 仍是 0,
	#  被记进 _mag_state 后又 _restore_mag 写回 0 → 残弹归零)。真机上滚轮事件天然跨帧,
	# 本探针不制造这个场景;该竞态已作为发现上报,不在此处当断言。
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
func _check_reload_state_machine(player: Node, wep: WeaponComponent) -> void:
	var stub := StubPlayer.new()
	add_child(stub)
	var scene: PackedScene = load("res://scenes/weapons/pistol_test.tscn")
	if scene == null:
		_failures.append("换弹测试:手枪场景载入失败")
		return
	var w: WeaponBase = scene.instantiate()
	add_child(w)
	await get_tree().process_frame
	w.equip(stub)

	_check(w.reload_active(), "换弹玩法未生效(reload_active()=false;reload_enabled=%s pvp=%s)" % [
			str(Settings.reload_enabled), str(Level0.pvp_mode)])

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

	# 关闭换弹玩法 → reload_active() 为假,start_reload() 不得进入装填
	Settings.reload_enabled = false
	_check(not w.reload_active(), "Settings.reload_enabled=false 时 reload_active() 仍为真")
	w.mag_ammo = 3
	w.start_reload()
	_check(not w.is_reloading(), "关闭换弹玩法后 start_reload() 仍进入装填")
	Settings.reload_enabled = true

	# ── 网络输入源闸门(必修 1 回归钉)──────────────────────────────────
	# 权威服务器进程**不实例化 Level0**(server/ 目录零赋值)→ `Level0.pvp_mode` 恒 false。
	# 只判 pvp_mode 的实现在服务器上会判成"单机":每打空弹夹就 start_reload() 并拒绝出弹
	# reload_time 秒,而客户端预测不受限 → 服务器不广播 bullet_spawn → **PvP 打中不掉血、
	# 无任何报错**;且 mag_ammo/_reloading 不入 capture_state → 分歧永不自愈。
	# 判据只能是输入源(权威模拟与远端副本都由 NetworkInputSource 驱动)。
	_check(Level0.pvp_mode == false, "前置:本钉要求 pvp_mode 为 false(实际 %s)" % str(Level0.pvp_mode))
	# (a) 桩路径:覆盖 weapon_base 的 has_method 守卫 + input_is_network()==true
	var net_stub := NetStubPlayer.new()
	add_child(net_stub)
	w.equip(net_stub)
	_check(not w.reload_active(),
			"网络输入源驱动时 reload_active() 为真(权威服务器会单方面停火 = PvP 伤害静默失效)")
	w.mag_ammo = 3
	w.start_reload()
	_check(not w.is_reloading(), "网络输入源驱动时 start_reload() 仍进入装填(应被 reload_active() 拒绝)")
	# (b) 真实链路:真 Player.tscn + NetworkInputSource → player.gd::input_is_network()
	var real_w: WeaponBase = wep.current_weapon()
	if real_w == null:
		_failures.append("网络闸门:Player 当前没有武器实例,真实链路无法验证")
	else:
		var prev_src: InputSource = player.input_source
		player.set_input_source(NetworkInputSource.new())
		_check(player.input_is_network(), "注入 NetworkInputSource 后 player.input_is_network() 仍为假")
		_check(not real_w.reload_active(),
				"真实 Player 注入 NetworkInputSource 后 reload_active() 仍为真(必修 1 未生效)")
		player.set_input_source(prev_src)
		_check(not player.input_is_network(), "复原本地输入源后 input_is_network() 应为假")

	# (c) PvP **本地客户端**:pvp_mode=true 但输入源是本地的(C2 下引擎自步进读真实鼠标,
	# pvp_client.gd:49 只置 pvp_mode,本地玩家不注入 NetworkInputSource)→ 同样不许换弹。
	# 漏这一条 = 客户端本地预测"装填中不许开火"、服务器无限弹 → 枪哑火但人照死;
	# 也违反 player.gd「PvP 不开换弹(reload_active() 恒 false)」的既有约定。
	w.equip(stub)   # 先复原成本地输入源,再验 PvP 客户端这一格
	net_stub.queue_free()
	Level0.pvp_mode = true
	_check(not w.reload_active(),
			"PvP 客户端(pvp_mode=true + 本地输入源)reload_active() 仍为真(本地预测会单方面哑火)")
	w.mag_ammo = 3
	w.start_reload()
	_check(not w.is_reloading(), "PvP 客户端 start_reload() 仍进入装填")
	Level0.pvp_mode = false
	_check(w.reload_active(), "复位 pvp_mode=false 后单机换弹应恢复(reload_active()=true)")

	w.queue_free()
	stub.queue_free()
	await get_tree().process_frame


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


# ── 6) ★ 守卫点:帧逻辑必须走 tick(),不许回到 _process ──────────────
# 源码读进来先剥纯注释行(_code_only):下面全是纯文本 contains(),不过滤的话
# 「注释里写出来的字面量」既会误绿(`# weapons.tick(delta)` 被注释掉照样命中),
# 也会误红(weapon_base.gd 的注释里出现过裸 `_process` 字样)。
func _check_tick_guards(player: Node, wep: WeaponComponent) -> void:
	var wb_src := _code_only(_read_res(WEAPON_BASE_SRC))
	var wc_src := _code_only(_read_res(WEAPON_COMPONENT_SRC))
	var pl_src := _code_only(_read_res(PLAYER_SRC))
	var lv_src := _code_only(_read_res(LEVEL0_SRC))
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


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


func _read_res(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 剥掉纯注释行(整行以 # 开头,允许缩进),供源码级 contains 断言用。
# 只剥「整行注释」:行尾注释里写字面量的情况本层没有,不做正则以免误伤字符串里的 #。
func _code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s: String = (line as String).strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		out.append(s)
	return "\n".join(out)


func _finish() -> void:
	if _failures.is_empty():
		print("KH L3 PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L3 PROBE: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
