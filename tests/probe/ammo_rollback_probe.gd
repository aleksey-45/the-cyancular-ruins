extends Node
# C1 专用探针:`restore_state` 之后**同帧**打出的那一发,会不会被帧末的延迟写回抹掉。
#
# 跑法:`--headless --quit-after 3600 res://tests/probe/ammo_rollback_probe.tscn`
# 判据:文本 `AMMO ROLLBACK PROBE: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍
#       exit 0,一行裁决都不打印)。
#
# 机制(修复前):`WeaponComponent.restore_inventory` 把权威弹数按
# `_restore_mag.call_deferred(...)` 排到帧末,而 `restore_state` 之后**同帧**打出的每一发
# 都排在它之前 ⇒ 帧末被覆盖回旧值,客户端弹数只增不减。本探针把那个序列直接构造出来:
#   ① 等玩家落地、武器入树,把手上弹数置成非满(4),并同步进**背包条目**;
#   ② 取快照 → `restore_state(快照)` —— 修复前这一步排下 deferred(值 = 4);
#   ③ **同一物理帧**内按一次开火边沿 ⇒ 玩家 `_physics_process` 打出一发(4 → 3);
#   ④ 等 SETTLE 帧读 `mag_ammo`:修复前 = 4(被覆盖),修复后 = 3。
#
# ★ 为什么每条前置都要显式断言:本探针每一步都踩在同一类陷阱上 ——
#   「**未入树时写状态会被 `_ready` 冲掉,而且不报错**」。
#   · 手上弹数要在**武器入树之后**写(否则被 `_ready` 的 `mag_ammo = mag_size` 冲掉);
#   · 背包条目的 mag 要**显式**同步(条目默认是 `MAG_FULL = -1`,而 `restore_inventory` 只在
#     条目 mag ≠ MAG_FULL 时才排 deferred ⇒ 不同步的话 C1 那一支**根本不会被走到**,
#     探针在修复前也是绿的 = 零鉴别力);
#   · `reset_mag_state()` / `_flush_current_mag()` 自身也只在武器入树时才写。
#   三者任一失效,探针都会静默退化成"永远绿",故每一条都配一条断言。

const COLS := 24
const ROWS := 10
const TILE_WALL := 31      # 纹理 1 全砖(墙)
const WARMUP := 30         # 无输入:落地 + 等武器入树
# 非满弹。★ 必须 ≠ `WeaponInventory.MAG_FULL`(-1):条目是满弹时 `restore_inventory` 那一支
# 根本不排 deferred,C1 就走不到 ⇒ 探针**在修复前也是绿的**(假绿)。
# ★ 它与手枪(`pistol_test.tscn`)的 `mag_size` **耦合**:那个值被改到 ≤ 4 时,下面那次
# `w.mag_ammo = MAG_START` 仍会"成功"(裸写不钳位),但 `_ready`/`apply_mag` 那条路会钳到
# `mag_size` ⇒ 期望值 3 变成**假红**。改手枪弹夹容量时回来一起看这个数。
const MAG_START := 4
const SETTLE := 3          # 打出那一发之后等几帧再读(帧末 flush 至少要一帧)

var P = null
var _tick := 0
var _fired_at := -1
var _expected := -1
var _checks := 0
var _fail := ""
var _done := false


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	host.name = "Host"
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	var ts := GameParameters.TILE_SIZE
	P = preload("res://scenes/player/player.tscn").instantiate()
	P.name = "AmmoProbe"
	P.set_input_source(PacketInputSource.new())
	host.add_child(P)
	P.global_position = Vector2(6 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	P.weapons.set_initial_inventory([1])   # 只给手枪(type_id 1)
	_run_pre_tree_tick_phase()   # 相②:未入树窗口的 tick()(2026-09-28)


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(TILE_WALL if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _physics_process(_delta: float) -> void:
	if P == null or _done:
		return
	# ★ 断言一失败就**当场裁决**,不能只是 return:那样 `_tick` 不再增长、下面的超时守卫永远到不了、
	#   `_finish()` 永不调用 ⇒ 探针耗尽 `--quit-after` 才退出且**一行裁决都不打印** ——
	#   那与"真失败"在输出上不可分(本仓登记过的坑;`_finish()` 自带 `_done` 防重入)。
	if not _fail.is_empty():
		_finish()
		return
	_tick += 1
	# ★ 超时自守卫:本探针每个"等一下"都可能永远等不到(武器永不入树 / 开火被冷却挡住)。
	#   没有它,探针会耗尽 `--quit-after` 才退出、**一行裁决都不打印** —— 那与真失败在输出上
	#   不可分(本仓登记过的坑)。正常路径在 `WARMUP + SETTLE` 帧内跑完,余量给足。
	if _tick > WARMUP + 120:
		_check(false, "探针超时:等了 %d 帧仍未走到裁决(武器没入树?开火被挡?)" % _tick)
		_finish()
		return
	var w = P.weapons.current_weapon()
	if _fired_at < 0:
		if _tick < WARMUP or w == null or not w.is_inside_tree():
			return        # 武器由 call_deferred 入树:没入树就继续等(此时写状态会被 _ready 冲掉)
		w.mag_ammo = MAG_START
		_check(int(w.mag_ammo) == MAG_START,
			"置残弹失败:写 %d、读回 %d(武器未入树时写会被 _ready 冲成 mag_size)" % [MAG_START, int(w.mag_ammo)])
		P.weapons.reset_mag_state()   # ★ 把手上弹数同步进**背包条目**(默认 MAG_FULL ⇒ 不排 deferred)
		_check(int(P.weapons.inventory.held[P.weapons._current_index]["mag"]) == MAG_START,
			"背包条目残弹没同步上 ⇒ restore_inventory 不会排 deferred,C1 根本没被走到(探针会假绿)")
		if not _fail.is_empty():
			return
		# ★ 同一物理帧内:restore(修复前在此排下帧末 deferred) → 开火边沿。
		#   本节点是场景根、玩家是它的孙子节点 ⇒ 玩家的 `_physics_process` 在本函数**之后**跑,
		#   那一发正落在"restore 之后、帧末 flush 之前"—— C1 的窗口就是这一段。
		P.restore_state(P.capture_state())
		_apply_attack()
		_fired_at = _tick
		_expected = MAG_START - 1
		return
	# 后续帧清掉边沿:别让 `pressed` 挂在那里、在冷却允许时又打出一发(那会让期望值变成 2)
	(P.input_source as PacketInputSource).clear_edges()
	if _tick >= _fired_at + SETTLE:
		var got := int(w.mag_ammo) if w != null else -99
		_check(got == _expected,
			"弹数被帧末写回覆盖:restore 后同帧打出一发,期望 %d、实得 %d" % [_expected, got])
		_finish()


func _apply_attack() -> void:
	var src := P.input_source as PacketInputSource
	src.clear_edges()
	src.apply_packet({
		"seq": _tick, "ax": 0.0,
		"held": PacketInputSource.BIT_ATTACK,
		"pressed": PacketInputSource.BIT_ATTACK,
		"released": 0,
		"winst": 0,
		"aim": Vector2(1.0, 0.0),
	})


# ── 相②(2026-09-28):未入树窗口的 `tick()` 不得把权威 `_reloading=false` 冲成 true ──
# 复现 `WeaponComponent._equip_index` 那个窗口:`equip()` 是**同步**的,而 `add_child` 是
# **deferred** 的 ⇒ 入树前 `player` 已非空、`_player_ok()` 为真 ⇒ `tick()` 照跑,
# 而 `mag_ammo` 还是**声明初值 0**(`_ready()` 才置 `mag_size`)⇒ `fire()` 的
# "空弹夹自动换弹"被这个**假前提**触发 ⇒ `start_reload()` 把权威刚写下的 `_reloading = false`
# 冲成 true,并多播一次没按键的 `Sfx.play("reload")`。
# ★ 判据分两半,两半缺一不可:
#   ① **负向**(前提 + 结论):未入树时 `mag_ammo` 仍是 0(前提不成立时下面是恒绿的空断言),
#      而 `tick()` 之后 `_reloading` 仍为 false **且** `mag_ammo` 未被写(设计里的判据原文);
#   ② **正向对照**:入树之后空弹夹开火**仍应**自动换弹。没有这一半,本相只钉住了"不该换弹时
#      不换" —— 把 `_mag_ready` 的置真删掉、或把那个分支改成裸 `return`,都会让一个**已上线**
#      的功能(空弹夹自动换弹)静默消失,而全仓其余断言**一条都不会红**。这是"单向断言"形态。
#   ★ **相②c** = 同窗口里的**第二条入口**:按 R 那条路(`player.gd` 直接调 `start_reload()`)
#     **绕过 `fire()`** ⇒ 它的守卫必须**独立**成立,别以为 `fire()` 那条盖住了它(见该相上方注释)。
func _run_pre_tree_tick_phase() -> void:
	var scene: PackedScene = load(WeaponRegistry.scene_of(1))
	if scene == null:
		_check(false, "相② 读不到手枪场景(WeaponRegistry.scene_of(1) 返回了空路径)")
		return
	var w: WeaponBase = scene.instantiate()
	# ★ 顺序与 `_equip_index` 逐字一致:先 `equip()`(同步写好 player)——
	#   本相**刻意不** `add_child`,就是要停在那一个窗口里。
	w.equip(P, 0.0)
	w._reloading = false           # 模拟 `_apply_weapon_state` 刚写下的权威值
	_check(not w.is_inside_tree(),
			"相② 前提:武器确实**不在**树上(否则本相验的不是那个窗口)")
	_check(int(w.mag_ammo) == 0,
			"相② 前提:未入树时 `mag_ammo` 仍是声明初值 0(实得 %d;若已非 0,本相恒绿)"
			% int(w.mag_ammo))
	_apply_attack()                # 按住开火(与 C1 相共用同一个输入源)
	w.tick(1.0 / 60.0)
	_check(not w.is_reloading(),
			"★ 未入树窗口里 `tick()` 把权威 `_reloading=false` 冲成了 true(未按键的假换弹)")
	# ★ 同一条结论的**另一半**:一帧过去后 `mag_ammo` 仍不得被写(设计里的判据原文是
	#   "断言 is_reloading()==false **且** mag_ammo 未被写")。
	#   ★ 它的**唯一**独立鉴别力是那种「`_reloading` 全程为 false、却写动了 `mag_ammo`」的形态
	#   (评审批的变异 3b:把 `mag_ammo = mag_size` 写在 `if _mag_ready:` **之外**)—— 那一形态下
	#   上面那条 `not is_reloading()` 是**过**的,只有本条红。
	#   ★ **别**用"将来若扩成步进多帧"给它找理由:`tick()` 收尾那次 `mag_ammo = mag_size` 是
	#   **挂在 `_reloading == true` 之下**的,而在多帧扩展里"错成 true 的 `_reloading`"上面那条
	#   断言会**先**红 ⇒ 本条被遮住、不承重。它拦的是与 `_reloading` **解耦**的那类写。
	_check(int(w.mag_ammo) == 0,
			"★ 未入树窗口里 `tick()` 写动了 `mag_ammo`(实得 %d;应为声明初值 0)" % int(w.mag_ammo))
	# ★ 第二拍:本拍只为证明"未入树时 `tick()` **照常跑完**"—— 钉的是设计**明文否决**的那个替代方案
	#   (`tick()` 顶部加 `is_inside_tree()` 早退:它会丢帧、并把 `_auto_aim()` 的朝向一起冻住
	#   ⇒ 那本身造成真分歧)。没有它,那个变体会让本相**两半都绿**(负向那半的换弹被别的理由挡下、
	#   正向对照用的是入树武器)。
	#   ★ 判据取冷却递减:`tick()` 里 `fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)` 排在
	#   `_player_ok()` 之后、与树无关 ⇒ 采纳的实现必减、被否决的实现必不减。
	#   ★★ **必须放在第二拍**:任何正冷却都会让 `try_fire()` 提前 return,于是 `fire()` 根本不会被调到
	#   —— 而第一拍的全部意义就是**走进 `fire()`**。把冷却设在第一拍之前会让上面那条 `_reloading`
	#   断言变成**空转**(更坏:它照样绿)。
	w.fire_cd_timer = 0.5
	w.tick(1.0 / 60.0)
	_check(absf(w.fire_cd_timer - (0.5 - 1.0 / 60.0)) < 0.0001,
			"★ 未入树窗口里 `tick()` 必须**照常跑完**(冷却 0.5 → 期望 %.4f,实得 %.4f)"
			% [0.5 - 1.0 / 60.0, w.fire_cd_timer]
			+ " —— 在 `tick()` 顶部加 `is_inside_tree()` 早退(设计明文否决)会让这里不变")
	w.free()                       # 不在树上 ⇒ 必须 free(),queue_free() 不会回收它
	# ★ 收尾复位输入源:本相按下的 attack 若留在 `_held` 里,会让紧接的 C1 相提前打光弹夹,
	#   那一相的"期望 3、实得 4"就变成**假红**。`clear_edges()` **不清 `_held`**,必须用
	#   `reset_state()`。
	(P.input_source as PacketInputSource).reset_state()

	# ── 相②的正向对照:入树之后,空弹夹**仍然**会自动换弹 ──
	# ★ 没有这一半,本相只钉住了"不该换弹时不换" —— 而把 `_mag_ready` 从 `_ready()` 里删掉、
	#   或把那个分支改成裸 `return`,都会让**已上线的一个功能静默消失**(空弹夹开火不再自动换弹),
	#   而本探针与全仓其余断言**一条都不会红**(`kh_l3_probe` / `kh_l3_visual_probe` 都是直接
	#   驱动 `start_reload()`,不走 `fire()` 这条路)。这是本仓反复强调的"单向断言"形态。
	var w2: WeaponBase = scene.instantiate()
	w2.equip(P, 0.0)
	add_child(w2)                  # ★ 入树 ⇒ `_ready()` 真的跑一次(这正是 `_mag_ready` 的置真点)
	_check(w2._mag_ready,
			"正向对照前提:入树后 `_mag_ready` 已置真(否则下面那条测的不是「入树后仍会换弹」)")
	w2.mag_ammo = 0                # `_ready()` 刚把它置成 `mag_size`,这里显式清空
	_apply_attack()
	w2.tick(1.0 / 60.0)
	_check(w2.is_reloading(),
			"★ 正向对照:入树之后空弹夹开火**仍应**自动换弹(把 `_mag_ready` 的置真删掉、"
			+ "或把那个分支改成裸 return,都会让这条红 —— 而没有它,那个功能会静默消失)")
	(P.input_source as PacketInputSource).reset_state()
	# ★ 刻意**不** free `w2`:留在树上直到探针退出。`_ready()` 里排了
	#   `call_deferred("add_child", _laser)` / `_explosion_marker` 两条,帧末前 free 掉本节点会
	#   让那两颗子节点变孤儿、给输出添 leaked 警告(本仓探针要求输出干净)。而 w2 之后不会再被
	#   任何东西 tick(只有玩家自己手上那把由 `WeaponComponent.tick()` 驱动),它就静静停在
	#   `_reloading = true` 上,无副作用。

	# ── 相②c:按 R 那条路在**同一个**窗口里也要被挡住(`start_reload()` 的首行守卫)──
	# ★ 为什么单开一条:`fire()` 的守卫**够不到**按 R 那条路 —— `scenes/player/player.gd` 的
	#   `_physics_process` 语句序是「武器 `tick()` → 切枪(**同步**换掉 `_weapon`,`add_child`
	#   是 deferred)→ R 轮询」,而 PvP 下切枪由服务器的 `winst` 应答驱动、R 是**本地边沿**
	#   ⇒ 两者互不相干,同帧相撞是**概率**问题而不是手速问题。撞上时 `start_reload()` 读到的
	#   `mag_ammo == 0` 同样是**声明初值**,会把权威刚写下的 `_reloading = false` 冲成 true;
	#   而 `_ready()` **不复位** `_reloading` ⇒ 那把枪白吃一个 `reload_time`(期间 `fire()`
	#   见 `_reloading` 直接 return = 打不出枪),直到下一次 `restore_state` 才回正。
	# ★ 夹具与相② 同形:一个 `equip()` 过、**不在树上**的实例 + 权威 `_reloading = false`。
	var w3: WeaponBase = scene.instantiate()
	w3.equip(P, 0.0)
	w3._reloading = false          # 模拟 `_apply_weapon_state` 刚写下的权威值
	# ★ [仪器] 两条前提缺一不可,**两条都断言**:不在树上(否则 `_ready()` 已把 `mag_ammo`
	#   落定成 `mag_size`);且 `mag_ammo` 仍是声明初值 0(否则 `mag_ammo >= mag_size`
	#   会替守卫把这次换弹挡下)。任一条不成立,下面那条主断言都是**恒绿的空转**。
	_check(not w3.is_inside_tree(),
			"相②c 前提:武器确实**不在**树上(否则 `_ready()` 已把弹数落定,本相恒绿)")
	_check(int(w3.mag_ammo) == 0,
			"相②c 前提:未入树时 `mag_ammo` 仍是声明初值 0(实得 %d;若已非 0,本相恒绿)"
			% int(w3.mag_ammo))
	w3.start_reload()              # ← 按 R 那条路(`player.gd` 直接调它,不经过 `fire()`)
	_check(not w3.is_reloading(),
			"★ 未入树的武器上直接调 `start_reload()` 必须是 **no-op**(权威 `_reloading = false`"
			+ "被冲成了 true —— 按 R 那条路**绕过** `fire()` 的守卫,而 `_ready()` 又**不复位**"
			+ "`_reloading` ⇒ 该武器白吃一个 `reload_time`)")
	w3.free()                      # 不在树上 ⇒ 必须 free(),`queue_free()` 不会回收它


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok and _fail.is_empty():
		_fail = msg


func _finish() -> void:
	if _done:
		return    # `quit()` 帧末才生效:本帧之后可能还会被调一次,防重入(否则裁决打印两遍)
	_done = true
	if _fail.is_empty():
		print("AMMO ROLLBACK PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("AMMO ROLLBACK PROBE: FAIL —— %s" % _fail)
		get_tree().quit(1)
