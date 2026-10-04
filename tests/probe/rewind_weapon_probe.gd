extends ProbeBase

# 回溯写回**武器域**的守卫(玩家侧消费端)。场景模式:autoload 与 `class_name` 必须已就绪,
# 不能用 `-s` 跑。
# 跑法:`"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/rewind_weapon_probe.tscn`
# 判据:文本 `KH RW-WEAPON PROBE: ALL-OK`(**不看退出码** —— 场景探针脚本报错时,`--quit-after`
#   到点仍 exit 0,退出码与"跑通了"不可分)。
#   ★ 而 `ALL-OK` 只证明"**没有任何断言失败**",**不证明"每条断言都跑过"** —— 脚本错误只结束
#   **出错的那个函数**、调用方继续 ⇒ 后面的断言静默跳过,verdict 照打 `ALL-OK`。
#   本文件因此有两道补丁:① `_finish()` 里的 `_checks != EXPECTED_CHECKS` 计数闸;
#   ② `_check()` 逐条打 `✓/✗` 轨迹(跑没跑过,看输出数行数就知道)。权威表述见
#   `tests/lib/probe_base.gd` 文件头。
#
# ── 存在理由(为什么必须有这一支)────────────────────────────────────
# `Player.rewind_restore()` 的武器段此前用**字符串反射**读写武器域:
#   `wc.get("inventory")` / `inv.get("held")` / `wc.get("_current_index")` /
#   `wc.call("equip_index", …)` / `wc.call("current_weapon")` / `live2.set("mag_ammo", …)`
# 反射的致命处是**拼错名字不报错**:`get()` 返回 null、`call()` 静默什么都不做、`set()` 静默
# 不写 ⇒ "回溯后弹量/手持武器没还原"这类现象在**编辑器与 `--check-only` 下全绿**。
# 而仓里 5 支 rewind 探针(`rewind_probe` / `rewind_fuse` / `rewind_phantom` /
# `rewind_elite_damage` / `tile_rewind`)对**弹量一条断言都没有** ——
# `grep -c 'wmags\|mag_ammo' tests/probe/rewind_*.gd` = 0(2026-10-04 实测)⇒ 那段代码此前
# **没有行为守卫**,改名只会静默失效(同族真事故就写在生成端 `core/sim/world_rewind.gd:98-103`:
# `_current_slot` 改名成 `_current_type` 后 `get()` 返回 null,快照值静默退化)。
# ★ 2026-10-04 实测订正那句"快照值静默恒为 0":那一帧 `_snapshot_player()` 返回的是**空字典**
#   (`snap.size()=0 keys=[]`)⇒ 消费端在第一个键上就早退 ⇒ 位置/HP/武器全不还原。详见 S7 段。
#
# ── 覆盖什么(逐条)──────────────────────────────────────────────
#   S1 不切枪时:各格残弹写回(**逐字段**) + 不动当前下标 + 不重建武器实例 + 手持那件实弹写回
#   S2 `mini(held.size(), mags.size())` 边界:快照比背包短 ⇒ 只写前 N 格,余下**原样不动**
#   S3 `widx >= 0` 下标守卫:快照是空手(-1)⇒ 不切枪,但手持实弹照写
#   S4 `wlive >= 0` 守卫:快照没记手持实弹(-1)⇒ **不得**写(写成 -1 就是守卫丢了)
#   S5 快照的当前武器与现持不同 ⇒ 必须切回那一把,且手持实弹等于快照的 `wlive`
#   S6 形状:那一带的 `.get("/.call("/.set("` 计数为 0(且类型化访问确实在 —— 否则"把整段
#      删掉"也能让计数变 0)
#   S7 **生产端**:`WorldRewind._snapshot_player()` 产出的武器快照逐字段 == 真值,且
#      `wslot`/`widx`/`wmags`/`wlive` **都没被静默写成 0/空**(形状 14 条 + 行为 9 条;
#      0 与真值不可分的地方用三个互不相同的非 0 值占位)。
#
# ── 为什么直调 `rewind_restore` 而不是按住 Shift 走真链路 ──────────────
# 单机真链路(`WorldRewind` 每帧按 `_cursor` 挑一个快照帧)的**落点不可复现** ——
# "回溯到哪一帧、那一帧的 widx/wmags/wlive 是什么"由时间场与按键时长决定,断言只能写成区间,
# 而"逐字段等于快照"恰恰是本任务唯一的验收口径。本探针改为**喂与
# `WorldRewind._snapshot_player()` 逐字同形的快照字典**(键名/类型都对得上,见 `_snap()`)、
# 直调那**同一个生产函数** ⇒ 同一条代码路径,但输入确定 ⇒ 能逐字段断言。
# ★ 覆盖上限(照实):S1-S6 **不覆盖**生成端 `WorldRewind._snapshot_player()`(在
#   `core/sim/world_rewind.gd`)—— 那一半由 S7 补上(2026-10-04,Plan B Task 3)。
#   S7 直调生产函数取样,**不覆盖**真实回溯的帧选择;端到端(真按键、真世界)的那一份
#   覆盖在 `tests/probe/rewind_probe.gd`,它末尾也加了一条同形的生产端契约。
# ★ 另一条边界:本探针所有场景都以**同一次调用**喂快照。生产路径**每帧**调一次 ⇒
#   S5 的"切枪那一帧"在生产里会被下一帧的同一次调用补齐(见 `_s5_switch_back` 里的长注释)。
#   本探针按生产口径(连续两帧)断言,并把那一帧的实测值打出来留档。

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const PLAYER_SRC := "res://scenes/player/player.gd"
const WREWIND_SRC := "res://core/sim/world_rewind.gd"

# S7 形状用的两个词表(逐名钉住,而不是只数一个总数 —— 见 `_s7_shape()`)。
# 前一条是**已经清掉**的六处对象反射的字面形状;后一条是替上去的类型化访问。
const PRODUCER_REFLECTION := [".get(\"_current_type\")", ".get(\"_current_index\")",
		".get(\"inventory\")", ".get(\"held\")", ".call(\"current_weapon\")",
		".get(\"mag_ammo\")"]
const PRODUCER_TYPED := [".inventory", "._current_type", "._current_index", ".held",
		".current_weapon()", ".mag_ammo"]

# 注册表里的 1 = 手枪(12 发)、2 = 步枪(30 发)。数值只在 `data/weapons.json`,
# 本探针只借这两个 id 造"两把不同的枪"。
const TYPE_PISTOL := 1
const TYPE_RIFLE := 2

# 断言计数闸(与 `kh_l3_visual_probe` / `combat_hud_visual_probe` 同款)。
# ★ 60 是**逐个数出来的**(全部 `_check(` 调用点都在 `_s1.._s7` 这七个函数里):
#   S1 7(前置 + `_check_cells` 3 + 下标 + 同实例 + 手持实弹)
#   S2 3、S3 5(下标 + `_check_cells` 3 + 手持实弹)
#   S4 6(前置 + 手持实弹未动 + `_check_cells` 3 + 下标)
#   S5 7(下标 + 实例非空 + 类型 id + 手持实弹 + `_check_cells` 3)
#   S6 9、S7 23(前置 1 + 反射逐名 6 + 类型化逐名 6 + 残值上界 1 + 行为 9)⇒ 合计 60。
#   用 `!=` 而不是 `<`:新增断言忘了登记同样要红(`late_match_probe` 同款)。
const EXPECTED_CHECKS := 60
var _checks := 0


func probe_id() -> String:
	return "RW-WEAPON"


# 覆写只为**逐条留轨迹**:37 行 ✓/✗ 是"该跑的都跑过"的凭据(计数闸之外的第二道)。
func _check(ok: bool, msg: String) -> void:
	_checks += 1
	print("[RW-WEAPON] %s %s" % ["✓" if ok else "✗", msg])
	super._check(ok, msg)


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_failures.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上"
				% [_checks, EXPECTED_CHECKS]
				+ "(要么有断言被静默跳过 —— 脚本错误只结束出错的那个函数、调用方继续;"
				+ "要么新加的断言没登记进 EXPECTED_CHECKS)")
	super._finish()


func _ready() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户开着 pvp。
	Level0.pvp_mode = false
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load(PLAYER_SCENE)
	if scene == null:
		_failures.append("player.tscn 载入失败 —— 武器段无从验证")
		_finish()
		return
	var player: Node = scene.instantiate()
	add_child(player)
	# 关掉玩家物理:本探针只验武器域的重建口径,不要被重力/落地/武器自动 tick 干扰。
	# (`WeaponBase` 自己没有 _process/_physics_process,只有被组件驱动的 tick(),故关掉玩家
	#  物理就等于关掉了整条武器帧逻辑。)★ 注意:关物理**不影响** `call_deferred("add_child")`
	#  的入树时机 —— 那走 MessageQueue,与本探针 await 的 process_frame 同一条路。
	player.set_physics_process(false)
	await _frames(3)
	var wc := player.get("weapons") as WeaponComponent
	if wc == null:
		_failures.append("player.tscn 上没有 Weapons 组件(节点改名/被删?)")
		_finish()
		return
	# 两把**不同**的枪:只有"当前武器不是快照那一把"才走得到切枪分支。
	wc.set_initial_inventory([TYPE_PISTOL, TYPE_RIFLE])
	await _frames(3)

	await _s1_cells_and_live(player, wc)
	await _s2_short_snapshot(player, wc)
	await _s3_no_index(player, wc)
	await _s4_no_live(player, wc)
	await _s5_switch_back(player, wc)
	_s6_shape()
	await _s7_producer(player, wc)
	_s7_shape()

	_finish()


# ── 生产口径的两条小助手 ────────────────────────────────────────────

# `Player.rewind_restore` 是根脚本上的方法,而本探针手里的 `player` 是 `Node`
# (根没有 class_name)⇒ 只能动态调。★ 名字写错时 `.call()` 会当场报
# "Invalid call. Nonexistent function" 并结束**这个函数**(不是进程),下面的断言随之红。
func _restore(player: Node, d: Dictionary) -> void:
	player.call("rewind_restore", d)


# 与 `core/sim/world_rewind.gd::_snapshot_player()` **逐字同形**的快照字典。
# `v = null` 走 `rewind_restore` 的"保持当前速度"分支,减少本探针的无关副作用。
func _snap(player: Node, widx: int, wmags: Array, wlive: int) -> Dictionary:
	return {
		"p": (player as Node2D).global_position,
		"v": null,
		"hp": int(player.get("hp")),
		"facing": int(player.get("facing_direction")),
		"downed": bool(player.call("is_downed")),
		"wslot": 0, "widx": widx, "wmags": wmags, "wlive": wlive,
	}


# 逐字段:背包各格残弹 == 快照 `wmags`(格数 + 每格各一条断言,不是"总数对得上")。
# 产出条数 = 1 + mags.size(),登记在 EXPECTED_CHECKS 里。
func _check_cells(tag: String, wc: WeaponComponent, mags: Array) -> void:
	var held: Array = wc.inventory.held
	_check(held.size() == mags.size(),
			"%s: 背包格数应 = 快照格数(实得 %d / %d)" % [tag, held.size(), mags.size()])
	for i in mini(held.size(), mags.size()):
		_check(int(held[i]["mag"]) == int(mags[i]),
				"%s: 第 %d 格残弹 = %d(快照 %d)" % [tag, i, int(held[i]["mag"]), int(mags[i])])


func _live_mag(wc: WeaponComponent) -> int:
	var w := wc.current_weapon()
	return int(w.mag_ammo) if w != null else -99


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# ── S1 不切枪:逐字段写回,且不重建武器实例 ──────────────────────────
func _s1_cells_and_live(player: Node, wc: WeaponComponent) -> void:
	var live := wc.current_weapon()
	_check(live != null, "S1 前置:初始背包应装上枪(current_weapon() 非空)")
	if live == null:
		return
	# ★ 先把世界改成与快照**不同**的样子:否则"写了"与"没写"在断言上不可分(恒绿)。
	live.mag_ammo = 11
	wc.inventory.held[0]["mag"] = 3
	wc.inventory.held[1]["mag"] = 7
	_restore(player, _snap(player, 0, [5, 9], 3))
	_check_cells("S1", wc, [5, 9])
	_check(wc._current_index == 0,
			"S1: 快照 widx 与当前下标相同 ⇒ 下标不动(实得 %d)" % wc._current_index)
	var live_after := wc.current_weapon()
	_check(live_after != null and live_after == live,
			"S1: 下标没变 ⇒ **不得**重建武器实例(切枪每次都 instantiate + 响一声 switch)")
	_check(live_after != null and live_after.mag_ammo == 3,
			"S1: 手持那件实弹 = %d(快照 wlive=3;=11 即 live2 那一写没生效)"
			% (int(live_after.mag_ammo) if live_after != null else -99))


# ── S2 `mini(held.size(), mags.size())` 边界 ────────────────────────
func _s2_short_snapshot(player: Node, wc: WeaponComponent) -> void:
	# 背包 2 格、快照只 1 格。§2.5 的原文是 `for i in mini(held.size(), mags.size())`:
	# 短快照只写前 1 格,第 2 格**原样不动**。
	_restore(player, _snap(player, 0, [2], 2))
	var held: Array = wc.inventory.held
	_check(int(held[0]["mag"]) == 2, "S2: 短快照只写前 1 格(第 0 格实得 %d)" % int(held[0]["mag"]))
	_check(int(held[1]["mag"]) == 9,
			"S2: 第 1 格必须**原样不动**(上一步是 9,实得 %d)—— 去掉 mini() 让 i 跑满"
			% int(held[1]["mag"])
			+ " held.size() 就是越界读 mags[1],而越界错误只结束那个函数、verdict 照打 ALL-OK")
	_check(_live_mag(wc) == 2, "S2: 手持实弹 = %d(快照 wlive=2)" % _live_mag(wc))


# ── S3 `widx >= 0` 下标守卫:空手快照不切枪 ──────────────────────────
func _s3_no_index(player: Node, wc: WeaponComponent) -> void:
	var live := wc.current_weapon()
	if live != null:
		live.mag_ammo = 6
	# widx=-1(空手)、wlive=4:不切枪,但手持实弹照写 4。
	# ★ 留档:`_equip_index(-1)` 自己也有越界早退,故 `widx >= 0` 这一条**是冗余防御**
	#   (去掉它行为不变)—— 本断言钉的是**行为**(下标不动),不是那一行守卫的存在性。
	_restore(player, _snap(player, -1, [2, 2], 4))
	_check(wc._current_index == 0,
			"S3: 快照是空手(widx=-1)⇒ 不得切枪,下标应仍为 0(实得 %d)" % wc._current_index)
	_check_cells("S3", wc, [2, 2])
	_check(_live_mag(wc) == 4, "S3: 不切枪时手持实弹照样写 = %d(快照 wlive=4)" % _live_mag(wc))


# ── S4 `wlive >= 0` 守卫:快照没记手持实弹就不许写 ────────────────────
func _s4_no_live(player: Node, wc: WeaponComponent) -> void:
	var live := wc.current_weapon()
	_check(live != null, "S4 前置:手上应有武器")
	if live == null:
		return
	live.mag_ammo = 8
	_restore(player, _snap(player, 0, [1, 1], -1))
	_check(live.mag_ammo == 8,
			"S4: wlive=-1 ⇒ **不得**写手持实弹(应仍为 8,实得 %d;=-1 就是 wlive 守卫丢了)"
			% live.mag_ammo)
	_check_cells("S4", wc, [1, 1])
	_check(wc._current_index == 0, "S4: 下标仍应为 0(实得 %d)" % wc._current_index)


# ── S5 快照的当前武器与现持不同 ⇒ 切回那一把 ────────────────────────
func _s5_switch_back(player: Node, wc: WeaponComponent) -> void:
	var live := wc.current_weapon()
	if live != null:
		live.mag_ammo = 5
	wc.inventory.held[0]["mag"] = 5
	wc.inventory.held[1]["mag"] = 1
	# wmags[1]=4 与 wlive=9 **刻意不同**:手持那一格在背包里是**旧值**(残弹写回只在切枪/丢弃
	# 时发生),`wlive` 那一次写才是权威。两者相等的话,"wlive 那一写没生效"就抓不到。
	# wmags[0]=5 == 切走时手枪的实弹:让 `_equip_index` 的"残弹写回旧枪"成为无操作,
	# 断言就不必把那条**既有**写回行为钉进本探针(那不是本次改动的一部分)。
	var d5 := _snap(player, 1, [5, 4], 9)
	_restore(player, d5)
	# ★ 仪器(不是断言):切枪那一帧新枪还没入树(`_equip_index` 用
	#   `call_deferred("add_child")`),而 `_ready()` 会把 `mag_ammo` 置成 `pending_mag`
	#   (刚从背包条目取的 4)⇒ **那一帧**的 `wlive=9` 会被冲掉。生产路径每帧调一次
	#   `rewind_restore`,下一帧 `_current_index` 已相同 ⇒ 不再切枪 ⇒ 那时 `wlive` 才落定。
	#   这是**既有行为**,本任务不许改行为 ⇒ 探针按生产口径(连续两帧)断言,这里只留档。
	var idx_frame1 := wc._current_index
	var mag_frame1 := _live_mag(wc)
	await _frames(2)
	# ★ 中间那一拍才是关键证据:新枪此时已入树,`_ready()` 已把 `mag_ammo` 置成
	#   `pending_mag`(背包条目里的 4)—— 那一帧的 `wlive=9` **确实被冲掉了**。
	var mag_after_ready := _live_mag(wc)
	_restore(player, d5)
	print("[RW-WEAPON] 仪器:S5 切枪那一帧 index=%d mag=%d;入树(_ready)后 mag=%d;"
			% [idx_frame1, mag_frame1, mag_after_ready]
			+ "再调一次(生产里就是下一帧)后 index=%d mag=%d" % [wc._current_index, _live_mag(wc)])
	_check(wc._current_index == 1,
			"S5: 快照 widx=1 ⇒ 应切回第 1 把(实得 `_current_index`=%d;"
			% wc._current_index
			+ "方法名拼错被反射静默丢弃时就停在这一条)")
	var live2 := wc.current_weapon()
	_check(live2 != null, "S5: 切回来后 current_weapon() 应非空(实得 %s)" % str(live2))
	_check(wc._current_type == TYPE_RIFLE,
			"S5: 切回来的应是 2 号步枪(实得类型 id %d)" % wc._current_type)
	_check(live2 != null and live2.mag_ammo == 9,
			"S5: 手持那件实弹 = %d(快照 wlive=9;=4 即 wlive 那一写没生效,=30 即 _ready 的满弹"
			% (int(live2.mag_ammo) if live2 != null else -99)
			+ "冲掉了它)")
	_check_cells("S5", wc, [5, 4])


# ── S6 形状:那一带的字符串反射计数为 0 ─────────────────────────────
func _s6_shape() -> void:
	# `code_view` 保留缩进、剥掉注释(注释里提到 `.call("` 不该让本条红/绿);
	# `top_func_body` 只认行首 `func `,免得内部类的同名方法骗过取体。
	var body := _top_func_body(_code_view(_read(PLAYER_SRC)), "rewind_restore")
	_check(not body.is_empty(),
			"S6 前置:player.gd 里抽不到 rewind_restore 的函数体(改名了?那下面几条 `== 0` 全是空转)")
	# `.call("/.set(" 在武器段没有别的合法用法 ⇒ 计数必须为 0。
	_check(body.count(".call(\"") == 0,
			"S6: rewind_restore 里不许再有 `.call(\"…\")`(实得 ×%d)—— 拼错方法名不再当场报错"
			% body.count(".call(\""))
	_check(body.count(".set(\"") == 0,
			"S6: rewind_restore 里不许再有 `.set(\"…\")`(实得 ×%d)—— 拼错字段名会**静默不写**"
			% body.count(".set(\""))
	# `.get("` 有两种:字典取键带默认值(`d.get("widx", -1)`,**合法且必需** —— `d["widx"]`
	# 在键缺失时会抛)与对象反射。把前者剔掉再数,后者必须为 0。
	var non_dict_gets := body.replace("d.get(\"", "").count(".get(\"")
	_check(non_dict_gets == 0,
			"S6: rewind_restore 里不许再有**对象反射** `.get(\"…\")`(实得 ×%d;"
			% non_dict_gets
			+ "拼错字段名返回 null,整段静默跳过)")
	# ★ 反向五条:`== 0` 只证明"没有反射",**不证明"类型化访问还在"** —— 把整段删掉也能变 0。
	#   故逐条钉住类型化访问确实在(这些串在反射写法里**不出现**,所以改动前它们就是红的)。
	for pat in [".inventory", "._current_index", ".equip_index(", ".current_weapon()", ".mag_ammo"]:
		_check(body.contains(pat),
				"S6: rewind_restore 里找不到类型化访问 `%s` —— 该段被删了?那反射计数为 0 是假的" % pat)


# ── S7 生产端:产出的快照逐字段 == 真值(★ 当年那次事故的形态)──────────────
# 上面 S1-S6 钉的是**消费端**(`Player.rewind_restore` 把快照写回武器域)。快照字典本身由
# **生产端** `WorldRewind._snapshot_player()` 产出,而它的武器段此前同样是字符串反射:
# `wc.get("_current_type")` 那类写法一旦成员名对不上,`get` **静默返回 null** ⇒ 快照值
# 静默退化,**没有任何断言会红**(引擎只在 stderr 每帧报 "Nonexistent 'int' constructor")。
# ★★ 2026-10-04 实测订正事故的**后果**(原注释只说"快照值照旧是 0",说轻了):那一帧
#   `_snapshot_player()` 返回的是**空字典**(仪器原文 `snap.size()=0 keys=[] is_empty=true`)
#   ⇒ 消费端 `rewind_restore({})` 在第一个键上就早退 ⇒ **位置/HP/武器全不还原**。
#   故本节的断言形状是"**逐字段 == 真值**"(而非只看某一个键),并额外钉住 `wslot != 0`。
# 本节直调**那个生产函数**,把产出的字典与真值逐字段比 —— 这是唯一能咬住"静默退化"的形状。
# ★ 为什么用三个**互不相同**的非 0 值(格 0=5 / 格 1=7 / 手持实弹=9):全 0 或全同值时
#   "读错了"与"读对了"在断言上不可分(恒绿)。
# ★ 为什么直调生产函数而不是等 `record()` 落一帧:落点由帧选择决定、不可复现(见文件头);
#   而生产函数**只读不写** ⇒ 真值可以在它返回后**同一瞬间**读,不必担心漂移。
func _s7_producer(player: Node, wc: WeaponComponent) -> void:
	wc.set_initial_inventory([TYPE_PISTOL, TYPE_RIFLE])
	await _frames(3)
	var held: Array = wc.inventory.held
	_check(held.size() == 2, "S7 前置:背包应有 2 格(实得 %d)" % held.size())
	var live := wc.current_weapon()
	_check(live != null, "S7 前置:取样前应装着枪(current_weapon() 非空)")
	if held.size() != 2 or live == null:
		return
	held[0]["mag"] = 5
	held[1]["mag"] = 7
	live.mag_ammo = 9
	var snap: Dictionary = WorldRewind.new()._snapshot_player(player)
	var wslot := int(snap.get("wslot", -99))
	var widx := int(snap.get("widx", -99))
	var wlive := int(snap.get("wlive", -99))
	_check(wslot == wc._current_type,
			"S7: 快照 wslot=%d 应等于真值 `_current_type`=%d(成员名对不上 ⇒ 反射 `get` 返回 null ⇒ 整帧快照退化)"
			% [wslot, wc._current_type])
	_check(wslot != 0,
			("S7: 快照 wslot **必须非 0**(实得 %d)—— 0 是 2026-10-02 那次" % wslot)
			+ "`_current_slot` 改名成 `_current_type` 之后 `get` 返回 null 的事故形态;"
			+ "而实测那次更重:整帧快照退化成空字典(这里会读成 -99)")
	_check(widx == wc._current_index,
			"S7: 快照 widx=%d 应等于真值 `_current_index`=%d" % [widx, wc._current_index])
	# 逐格:产出的 `wmags` 必须与真值逐格相等(格数 + 每格各一条),不是"总数对得上"。
	_check_cells("S7", wc, snap.get("wmags", []))
	_check(wlive == live.mag_ammo,
			"S7: 快照 wlive=%d 应等于真值 `mag_ammo`=%d" % [wlive, live.mag_ammo])


# ── S7 形状:生产端武器段不许再有对象反射(逐名 + 残值上界)─────────────
func _s7_shape() -> void:
	# 与 S6 同法:`code_view` 剥注释(否则解释这条病的注释会把断言喂红)、
	# `top_func_body` 只认行首 `func `。
	var body := _top_func_body(_code_view(_read(WREWIND_SRC)), "_snapshot_player")
	# ★ 前置必须自己是一条**会红**的断言,而不是 `if ...: return`:空读时下面那些 `not contains`
	#   恒真(否定断言的空读恒真),只看后面几条会把"读不到源"读成通过。
	_check(not body.is_empty(),
			"S7 前置:world_rewind.gd 里抽不到 _snapshot_player 的函数体(改名了?那下面几条全是空转)")
	if body.is_empty():
		return
	for pat in PRODUCER_REFLECTION:
		_check(not body.contains(pat),
				"S7: _snapshot_player 里不许再出现对象反射 `%s` —— 成员名对不上时它静默返回 null,"
				% pat + "快照值静默变 0/空")
	# ★ 反向六条:计数/缺席只证明"没有反射",**不证明"类型化访问还在"** —— 把整段删掉也满足。
	for pat in PRODUCER_TYPED:
		_check(body.contains(pat),
				"S7: _snapshot_player 里找不到类型化访问 `%s` —— 该段被删了?那上面的缺席是假的" % pat)
	# 残值边界:`_snapshot_player` 里仍允许的**对象反射**只有**玩家根**(`player.gd`,**无
	# `class_name`**)上的四读:velocity / hp / facing_direction / weapons。它们要类型化得给
	# player 根加 `class_name`(动类结构:全局类名 + 两个刻意造的裸宿主桩会被打掉;已登记,
	# 不属本任务)⇒ 这里用 `<=` 而不是 `==`,免得将来有人补了 class_name 反而把守卫喂红。
	# 正解是把 weapons 组件**当参数注进来**(见 Task 3 报告),不是给根加类型。
	var gets := body.count(".get(\"")
	_check(gets <= 4,
			"S7: _snapshot_player 的对象反射不得超过玩家根那 4 处(velocity/hp/facing_direction/weapons),实得 ×%d"
			% gets)
