class_name WorldRewind
extends RefCounted

# 世界回溯(第一阶段):定频快照环缓 + 反向应用器。纯数据/编排,不碰 UI 与 shader。
#
# 模型(与旧线"瓦片事件账本"互补:本阶段只倒实体,瓦片账本下一阶段接):
#   · record():正常流逝时每 1/SNAP_HZ 秒采一帧 —— 玩家(位置/速度/HP/朝向/倒地)、
#     非精英敌人(位置/速度/HP/存亡)、子弹(场景路径/位置/速度/归属)。
#   · step():回溯中按"已倒退秒数"游标从最新帧往回走,应用目标帧(位置/状态一次性置回);
#     子弹按快照**重建/重定位**(回溯起点清空活弹,由快照帧接管)。
#   · 精英不入快照、不回放(策划案:精英不受回溯影响,依旧保持原本行为)。
#   · 尸体保留:录制期间被击杀的敌人不立即释放(hold_corpses),隐藏待复活;
#     超出缓冲窗口(TimeParams.SNAP_SECONDS)后才由 Level0 清理。
#   · 回放期间不结算伤害:实体脚本靠 TimeField.is_rewinding() 早退,Level0 在回放帧不喂输入。

static var hold_corpses := false   # 由 Level0 每帧同步:录制中=true(击杀保留尸体待复活)

var was_rewinding := false         # 状态沿(Level0 用它判进入/退出回溯)
var _frames: Array = []            # [{t, player:{...}, enemies:[...], bullets:[...]}]
var _t := 0.0                      # 世界已录制时间(秒)
var _acc := 0.0
var _cursor := 0.0                 # 本次回溯已倒退的秒数
var _replay_bullets: Array = []    # 回放用子弹节点(与当前应用帧的 bullets 下标对应)
var _parent: Node = null           # 回放子弹的挂载父节点(通常 WorldViewport)
# ── 完成度观测量(2026-10-05 修复轮 1;来源 = 逐任务评审 C-1)──────────────────
# ★ 为什么是"完成度"而不是"freed 引用数 == 0":带子上留着 freed 实体是**改动前就存在**的条件
#   (精英不保留尸体 `enemy_base.gd:316` + 它死前的帧留在 40s 带上,`TimeParams.SNAP_SECONDS = 40.0`),
#   旧码靠 `and` 短路**静默跳过**它 ⇒ 断言 `invalid_ref_count() == 0` 修完仍是 30+ ⇒ **永久红**。
#   恒红的守卫与恒绿的守卫一样没用。故断言改成:`step()` 里"应当走完 `_apply`"的次数
#   == `_apply` 真正走到底的次数(`tests/probe/rewind_probe.gd` 的 ⑩)。
#   freed 引用数照旧暴露,但它是**登记用的观测量**,不是"必须为 0"的断言。
var _apply_started := 0
var _apply_completed := 0
var _bullets_completed := 0        # `_apply_bullets()` 自己的分子(见该函数末尾;评审 N-1)
var _invalid_refs := 0             # 带子上出现过的 freed / 非节点引用(观测)


func _init(parent: Node = null) -> void:
	_parent = parent


# ── 录制(正常流逝)────────────────────────────────────────────

func record(delta: float, player: Node, enemies: Array, bullets: Array) -> void:
	if player == null or not is_instance_valid(player):
		return
	_t += delta
	_acc += delta
	if _acc < 1.0 / float(TimeParams.SNAP_HZ):
		return
	_acc = 0.0
	var pe: Array = []
	for node in enemies:
		if not is_instance_valid(node) or (node as Node).has_meta("elite"):
			continue
		# ★★ 2026-10-05(closeout 批 Task 3 / T12):这一段原先四处都是**字符串反射**
		#   (`e.get("velocity")` / `e.get("hp")` / `e.get("is_dead")`)。反射的失败形态实测过:
		#   成员名对不上时 `get` **静默返回 null**,而 `int(null)` 会**当场抛错并中止整个
		#   `record()`** ⇒ 这一帧**压根不入快照**(与 `_snapshot_player()` 那次空字典事故同族)。
		#   现在类型化 —— `EnemyBase` 已有 `class_name`(scenes/enemies/enemy_base.gd:1),
		#   **未动类结构**;拼错成员名变成**点名成员**的运行期错(买到的不是编译期红,理由同
		#   `_snapshot_player()` 那段注释)。
		# ★ 行为差(照实):`enemies` 里混进**非 EnemyBase** 的节点(只有测试桩会这么干)时 ——
		#   旧:读到 null ⇒ `int(null)` 炸掉整帧;新:点名报错 + **跳过这一件**、本帧照常入快照。
		#   真机不可达:全仓只有 `enemy_base.gd:69` 往 `enemies` 组里加节点。
		var e := node as EnemyBase
		if e == null:
			push_error("WorldRewind: enemies 里出现非 EnemyBase 节点(%s)—— 本帧不为它入快照"
					% str(node))
			continue
		pe.append({
			"n": e,
			"p": e.global_position,
			"v": e.velocity,
			"hp": e.hp,
			"dead": e.is_dead,
			"vis": e.visible,
		})
	var pb: Array = []
	for node in bullets:
		if not is_instance_valid(node):
			continue
		# ★★ 2026-10-05(closeout 批 Task 3 / T12):子弹这一段同理(`b.get("velocity_vec")` /
		#   `b.call("rewind_state")` / `b.get("hit_damage")` …)。`BulletBase` 已有 `class_name`
		#   (scenes/weapons/bullet_base.gd:1)⇒ 未动类结构。
		#   ★ 引信/射程状态(爆炸弹"还剩多久炸")必须逐帧带:`rewind_state()` 不再是"按名猜有没有"。
		var b := node as BulletBase
		if b == null:
			push_error("WorldRewind: bullets 里出现非 BulletBase 节点(%s)—— 本帧不为它入快照"
					% str(node))
			continue
		var sh := b.shooter
		# 进快照 → 回溯重建的榴弹不会退回未点燃(见 BulletBase.rewind_state 的注释)。
		var fuse_state: Dictionary = b.rewind_state()
		pb.append({
			"sp": str(b.get_meta("scene_path", "")),
			"p": b.global_position,
			"v": b.velocity_vec,
			"from_player": sh != null and sh.is_in_group("player"),
			"dmg": b.hit_damage,
			"impact": b.hit_impact,
			"fuse": fuse_state,
		})
	_frames.append({
		"t": _t,
		"player": _snapshot_player(player),
		"enemies": pe,
		"bullets": pb,
	})
	var cutoff := _t - TimeParams.SNAP_SECONDS
	while _frames.size() > 1 and float(_frames[0]["t"]) < cutoff:
		_frames.pop_front()


# ── 回放(回溯中)──────────────────────────────────────────────

## 进入回溯:清空场上活弹(状态改由快照重建),游标归零。
## 玩家状态快照:位置/速度/HP/朝向/倒地 + **武器弹量**(当前武器类型与下标、背包各格残弹、
## 手持那件的实弹数)——用户要求"除个人钟/精英/Boss 外一切状态都要回溯"。
func _snapshot_player(player: Node) -> Dictionary:
	var d := {
		"p": (player as Node2D).global_position,
		"v": player.get("velocity"),
		"hp": int(player.get("hp")),
		"facing": int(player.get("facing_direction")),
		"downed": player.has_method("is_downed") and player.is_downed(),
		"wslot": 0, "widx": -1, "wmags": [], "wlive": -1,
	}
	# ★ R1(2026-10-04,逐任务评审 Important ④):用**显式守卫**取组件,不用带类型的赋值。
	#   带类型的直接赋值(`var wc: WeaponComponent = player.get("weapons")`)在 `weapons` 不是
	#   `WeaponComponent` 时会抛 "Trying to assign value of type 'Node'…" ⇒ **中止整个函数**
	#   ⇒ 退化成**空字典**(连位置/HP 一起丢);而旧的鸭子类型写法在那种输入上只**局部**退化。
	#   这里改成 `as` + 点名报错 + **返回已收集的部分**(位置/HP/朝向/倒地仍然还原得了)。
	#   ★ 新行为(与旧的鸭子类型不同,照实记):`weapons` 是**非 `WeaponComponent` 的节点**时 ——
	#     旧:接着按名读,读到什么算什么(名字恰好对得上就全对,对不上就整帧空字典);
	#     新:`push_error` 点名 + 武器四键停在初值(`wslot` 0 / `widx` -1 / `wmags` [] / `wlive` -1)。
	#   ★ 真机无差别:`player.tscn` 的 `$Weapons` 就是 `WeaponComponent`(`player.gd:42`),
	#     `weapons == null` 这一支两条写法都在同一处 `return d`。
	#   ★ 分档补记(2026-10-04 Plan B Task 13;评审 Minor:`wc == null` 那一支把**两档**吞进同一个
	#     `push_error`,而上面只点了第 ② 档,读起来像完整枚举):
	#       ① **取不到** —— `player.get("weapons")` 返回 `null`(宿主没有 `$Weapons` 这个子节点);
	#       ② **类型不对** —— 拿到了节点,但它不是 `WeaponComponent`(或那个脚本没挂上)。
	#     **今天没有宿主能触达这两档**:真机 `player.tscn` 必有 `$Weapons`
	#     (`player.gd:42` ⇒ `WeaponComponent`);6 支 rewind 探针里"不是 `WeaponComponent`"出现 **0** 次。
	#   ★ **将来要分档的条件**:若出现"**没有 `$Weapons` 的占位玩家**"(那是**正常态**、不是错误)
	#     ⇒ 必须把两档分开:① 缺组件 ⇒ **静默/降级**(不作声);② 类型错 ⇒ **报错**。
	#     届时改这一处 + 补一条守卫钉住分档。登记与翻案条件:`docs/eng/registered-debt.md` §六.14。
	var wc := player.get("weapons") as WeaponComponent
	if wc == null:
		push_error("WorldRewind: player.weapons 不是 WeaponComponent —— 武器段无法回溯;本帧返回已收集的部分")
		return d
	# ★ 合并订正(2026-10-02):原写的是 `_current_slot` —— 主线已把 `slot` 一词整体退休、
	#   改名为 `_current_type`,于是 `get()` 返回 null ⇒ `int(null)` 每帧(20Hz)抛
	#   "Nonexistent 'int' constructor",而**快照值照旧是 0、不报红、不中断**。
	#   ★★ 2026-10-04 实测订正上面那句的**后果**(原文只说"快照值照旧是 0",说轻了):那条赋值
	#   抛错的**当帧**,本函数返回的是**空字典**,不是"wslot=0、别的键还在"。
	#   仪器原文(与 stderr 里那 83 行 "Nonexistent 'int' constructor" 同一跑):
	#   `snap.size()=0 keys=[] is_empty=true`。后果是**整帧玩家快照全丢** ⇒ 消费端
	#   `rewind_restore({})` 在第一个键上就早退 ⇒ **位置/HP/武器全不还原**
	#   (端到端实测 `rewind_probe` 7 条红:位置差 276px、HP 30≠50、HUD 血量通知未触发)。
	#   即:反射拼错的名字**不止**弄丢一个字段,它把整帧快照弄空,而引擎每帧照报不误。
	# ★ 另注:本键当前**只写不读**(`player.rewind_restore` 还原武器用的是 `widx` + `wmags` +
	#   `wlive`,不看类型 id)。保留它是为了与 `capture_state` 的 `wslot` 同口径,免得下次
	#   有人想按类型还原时以为这里没有。
	# ★ 类型化(2026-10-04,audit §2.5 的**生产端**):下面六处成员访问原先都走**字符串反射**
	#   (按名取值 / 按名调方法)。反射把"成员名拼错"变成**静默 null**,正是上一条注释记的那次
	#   真事故。现改成真类型访问:拼错时**当场、点名成员、带文件:行号**地炸。
	#   ★ 买到的**不是**"编译期红":4.7.1 对 `class_name` 类型上的未知成员只按警告级
	#     `UNSAFE_*` 处理(`project.godot` 也没把它升成错误)⇒ 拼错同样是**运行期** SCRIPT ERROR。
	#     与 `player.gd` 里那段同款说明(实测原文见 `tests/probe/rewind_weapon_probe.gd` 文件头)。
	#   ★ 六个成员都在**已有 `class_name`** 的类上(`WeaponComponent` / `WeaponInventory` /
	#     `WeaponBase`)⇒ **未动类结构**,反射纯属历史遗留。
	# ★ 行为逐字段不变:键名/键序/初值(`wslot` 0、`widx` -1、`wmags` []、`wlive` -1)与两个
	#   `!= null` 守卫都原样保留;`wc.has_method("current_weapon")` 那层探测去掉,是因为 `wc`
	#   现在是 `WeaponComponent`,该方法必然存在(见 `weapon_component.gd:461`)。
	# ★ 覆盖上限(★ R1 订正:原先只列了"4 处按名取值",**漏了本函数第 5 处按名访问**):本函数里
	#   仍然**按字符串名**碰玩家的地方一共 **5 处**,全在**玩家根**(`player.gd`,**没有
	#   `class_name`** ⇒ 类型化它要动类结构:全局类名 + 打掉两个刻意造的裸宿主桩,已登记):
	#     ① `player.get("velocity")` ② `player.get("hp")` ③ `player.get("facing_direction")`
	#     ④ `player.get("weapons")`(本段上面那一处)⑤ `player.has_method("is_downed")`
	#        + `player.is_downed()`(本函数开头那个字典字面量里的 `"downed"` 键)。
	#   ★ 第 ⑤ 处的失败形态与前四处**同型但更阴**:`is_downed` 一改名 ⇒ `has_method` 恒 false
	#     ⇒ `downed` **静默写成 false**(不报错、不中断,`d` 照常返回)⇒ 消费端
	#     `player.gd:1039-1042` 的 `if bool(d["downed"]) and not downed_now` **静默跳过倒地/复活
	#     还原**。★ 原文写的是 `player.gd:987-989` —— 行号**已过期**,2026-10-04(Plan B Task 15)
	#     按内容复核后订正(`grep -n "set_downed_by_rewind\|combat.revive()"`;`player.gd` 共 998 行)。
	#     ★★ 2026-10-05(Task 2)**二次订正**:Task 15 时是 `995-998`,而本轮在同一条链路的
	#     `player.gd::rewind_restore` 里插了 44 行 ⇒ 又移了;复核法同上,实测 `1039-1042`
	#     (`player.gd` 现在共 **1042** 行 = 那四行就是文件末尾)。
	#   ★★ 形状守卫(`rewind_weapon_probe` 的 S7)在 Task 15 已从"`.get("` + `has_method("` **≤ 5** 的
	#     **计数上界**"换成**逐名核那 5 处访问形态**(`_has_member_token`)+ **一条 `snap["downed"] == 真值`
	#     的行为断言**(`EXPECTED_CHECKS` 60→**61**;**★ 2026-10-05:现为 90** —— Task 2 加 S8/S9 到 86、
	#     修复轮 1 再 +4 到 90)。旧计数上界对第 ⑤ 处的改名**无牙**:Task 13 的 G-1
	#     实测 —— 只改字符串、真方法不动 ⇒ 计数**仍是 5 ⇒ 60 条全绿**,而 `"downed"` 静默恒 false。
	#   ★ 为什么**不**顺手去掉 `has_method("is_downed")`(评审 ①(c) 的备选):`player` 的静态
	#     类型是 `Node`,`player.is_downed()` 是**不安全动态调用** —— 方法真缺席时会**抛错中止
	#     整个函数** ⇒ 退化成**空字典**(位置/HP 一起丢)。那正是上面 R1 ④ 明确否掉的形态
	#     ("部分还原 > 完全不还原")⇒ 保持"名字问不到就当 false"的**安全退化**,改用守卫逐名钉住。
	#   正解是把 weapons 组件(以及其余 4 处的值)**当参数注进来**,不属本任务。
	#   守卫:`tests/probe/rewind_weapon_probe.gd` 的 S7(行为 + 形状)+ `rewind_probe.gd` 的 ⑨。
	d["wslot"] = wc._current_type
	d["widx"] = wc._current_index
	var inv: WeaponInventory = wc.inventory
	if inv != null:
		var mags: Array = []
		for e in inv.held:
			mags.append(int(e["mag"]))
		d["wmags"] = mags
	var live: WeaponBase = wc.current_weapon()
	if live != null and is_instance_valid(live):
		d["wlive"] = live.mag_ammo
	return d


func begin() -> void:
	_cursor = 0.0
	_replay_bullets.clear()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()


## 退出回溯(录像带模型):把"过去的将来"从磁带上裁掉。
## 磁带钟退回到回溯出口,之后 record() 从这里续录——被回溯抹掉的时间段不复存在,
## 两次回溯互不串带(否则第二次回溯会先倒放被抹掉的未来,再掉进更早的真历史)。
## 返回出口时刻(磁带新末尾),Level0 用它把瓦片账本裁到同一位置。
func finish() -> float:
	var exit_t := _t - _cursor
	var kept := 0
	for i in range(_frames.size()):
		if float(_frames[i]["t"]) <= exit_t:
			kept = i + 1
	if kept == 0 and not _frames.is_empty():
		kept = 1   # 倒到了磁带最老处:世界就停在那帧上,磁带从它重新起算
	if kept > 0:
		_frames.resize(kept)
		_t = maxf(exit_t, float(_frames[kept - 1]["t"]))
	_cursor = 0.0
	_replay_bullets.clear()
	return _t


func step(delta: float, player: Node) -> void:
	if _frames.size() < 2:
		return
	_cursor += delta * _mult()
	var target := _t - _cursor
	_apply_started += 1     # 完成度分母(见 `apply_started_count()`)
	_apply(_frame_at(target), player)


## 完成度观测量(分子/分母)与 freed 引用计数 —— 三者的用法见字段声明处那段注释。
## ★ 断言口径:分子 == 分母(`_apply` 与 `_apply_bullets` **各一条**);
##   **不是** `invalid_ref_count() == 0`(那会恒红)。
func apply_started_count() -> int:
	return _apply_started


func apply_completed_count() -> int:
	return _apply_completed


## 子弹段**走完或无事可做**的帧数(★ 与 `apply_completed_count()` 是**两条独立的分子** —— 见 N-1)。
## ★ 措辞按实况(修复轮 3,评审 A):`_apply()` 的**空帧早退**那一支会在 `_apply_bullets()` **从未被调用**时
##   也给它 +1 ⇒ 它数的是"走完**或**无事可做的帧数",不是"函数被走到底的次数"。
func apply_bullets_completed_count() -> int:
	return _bullets_completed


func invalid_ref_count() -> int:
	return _invalid_refs


## 回放完成度的**唯一判据**(2026-10-05 修复轮 3;来源 = 范围重审 **N-2**):
## 正常返回 `""`,否则返回**一句**可直接当探针判词的错话(第一处命中即返回)。
## ★★ 为什么判据住在产品侧而不是"三支探针各抄一份":三支 rewind 探针都要它,而
##   (a) `tests/lib/` 的**现有**文件不许改;(b) **新增**任何 `.gd`(含 `tests/lib/`)会让
##   `allscript_probe` 的 `EXPECTED_SCRIPTS` 由 287 变 288(实测 287 = `git ls-files '*.gd'`);
##   (c) 这三支 `extends Node`、**不继承 `ProbeBase`** ⇒ "往 `ProbeBase` 加助手"对它们**根本不可达**。
##   ⇒ 判据摆在计数器旁边才是它该在的地方;探针只剩"非空就 `_fail`"一行(抄三份**一轮内就漂移**过:
##     上一轮 Minor ⑤ 的"分子 > 分母"分档只落到了 1/3 支)。
## ★ **只读**:不写任何计数器、无副作用(三支探针每跑调用一次)。
## ★ 两条硬口径:① `started <= 0` 的"没有样本"也在这里报(否则三支各自留着那句会再漂移);
##   ② `分子 > 分母` 一律说"**计数点被改坏/重复计数**" —— **不许**说"没走完(差 -N)"(那是荒谬文案)。
func replay_completion_error() -> String:
	if _apply_started <= 0:
		return "完成度观测量没有样本(回溯期 step() 一次都没被调到)—— 本条会空转"
	if _apply_completed > _apply_started:
		return "完成度分子超出分母:`_apply` %d/%d —— 计数点被改坏或重复计数(不是『没走完』)" % [
				_apply_completed, _apply_started]
	if _apply_completed != _apply_started:
		return ("回溯里 `_apply` 没走完:%d/%d 次(差 %d)—— 它在类型收窄上撞到 freed 实例,**当场抛错并中止**"
				% [_apply_completed, _apply_started, _apply_started - _apply_completed]
				+ "(本条范围只是 `_apply()` 自己的函数体;`_apply_bullets()` 内的中止见后一条)")
	if _bullets_completed > _apply_started:
		return "完成度分子超出分母:`_apply_bullets` %d/%d —— 计数点被改坏或重复计数(不是『没走完』)" % [
				_bullets_completed, _apply_started]
	if _bullets_completed != _apply_started:
		return ("回溯里 `_apply_bullets` 没走完:%d/%d 次(差 %d)—— 子弹段函数体内被中止 ⇒ 回放弹不重建/"
				% [_bullets_completed, _apply_started, _apply_started - _bullets_completed]
				+ "不摆位/引信不回写,后面『隐藏多余弹』也一起跳过。★ 它**不会**被前一条看见:"
				+ "脚本错误只中止出错的那个函数、`_apply()` 照常走到末尾 +1(评审 N-1 的插桩实测)")
	return ""


## 起步快放 → 1×(用已倒退量做 ramp;越倒越接近 1×)
func _mult() -> float:
	var k := clampf(_cursor / maxf(TimeParams.REWIND_RAMP_TIME, 0.001), 0.0, 1.0)
	return lerpf(TimeParams.REWIND_START_MULT, 1.0, k)


func _frame_at(target: float) -> Dictionary:
	for i in range(_frames.size() - 1, -1, -1):
		if float(_frames[i]["t"]) <= target:
			return _frames[i]
	return _frames[0]


func _apply(f: Dictionary, player: Node) -> void:
	if f.is_empty():
		# 空帧 = 无事可做,**不是**中止(与函数末尾那两次计的是同一件事)。
		# ★ 这里也把 `_bullets_completed` 一起 +1,是为了保住 `bullets_completed == started` 这条
		#   不变量的**形态**(空帧没有子弹可放)。★ 如实标注:该分支**今天不可达** —— `record()` 只
		#   append 完整帧字典、`_frame_at()` 只可能返回 `_frames[i]`/`_frames[0]`(评审 B-4 用
		#   `noempty` 变异反证过 `E = 0`),这一行是**死防御**,只为不留下"哪天可达就假红"的尖角。
		_apply_completed += 1
		_bullets_completed += 1
		return
	if is_instance_valid(player) and player.has_method("rewind_restore"):
		player.rewind_restore(f["player"])
	for d in f["enemies"]:
		# ★★ 2026-10-05(修复轮 1,**评审 C-1**):`is_instance_valid()` **必须先于**类型收窄。
		#   实测(评审在 `E:/tmp/t3` 副本里做的,实现者复现一致):**真 freed** 实例上
		#   `x as EnemyBase` 抛 `SCRIPT ERROR: Trying to cast a freed object.` 并**中止整个 `_apply`**
		#   ⇒ 同帧的 `_apply_bullets()` 整段被跳过(回放弹不重建/不摆位/引信不回写)。
		#   而**改前**的旧码是 `is_instance_valid(d["n"]) and (d["n"] as Node).has_method(…)` ——
		#   `and` 短路 ⇒ **永不**转型 freed 实例 ⇒ 0 错误。即:首版把转型提到判定之前,是**本包新引入的
		#   运行期中止**,而它在既有探针里每跑 30+ 次(判词照样 `OK`)。
		#   ★ 带子上留着 freed 实体是**改动前就存在**的条件(精英不保留尸体 `enemy_base.gd:316` +
		#     它死前的帧留在 40s 带上 `TimeParams.SNAP_SECONDS = 40.0`)⇒ 这里的正确行为是
		#     **计数 + 跳过**,不是报错。计数是观测量(`invalid_ref_count()`),不是"必须为 0"的断言。
		#   ★★ **两种失败形态别混读**(2026-10-05 修复轮 2,**评审 Minor ④** 指出这半句在改写时被丢了):
		#     ① **freed / 非节点**(`is_instance_valid` 为假)⇒ `_invalid_refs += 1` + **静默跳过**
		#        —— 它是**改动前就存在**的条件,不是错误;
		#     ② **有效但不是 `EnemyBase`** ⇒ **`push_error` 点名** + 跳过**这一件**
		#        (不中止整帧,后面的 `_apply_bullets()` 照跑)。真机今天不可达(全仓只有
		#        `enemy_base.gd:69` 往 `enemies` 组加节点),但它**不属于"静默"那一类**。
		#   ★ `var raw` **故意不加类型**:给 freed 实例做带类型的赋值(`var n: Node = d["n"]`)本身就会
		#     碰那个实例(引擎有 "Trying to assign invalid previously freed instance" 那条路;
		#     评审 E1 实测:连**带类型的形参**也会炸)⇒ `is_instance_valid()` 是**唯一**安全的问法,
		#     必须像旧码那样问**未定型 Variant**。
		var raw = d["n"]
		if not is_instance_valid(raw):
			_invalid_refs += 1
			continue
		var en := raw as EnemyBase
		if en == null:
			push_error("WorldRewind: enemies 里出现非 EnemyBase 节点(%s)—— 本帧不为它回放" % str(raw))
			continue
		en.rewind_restore(d)
	_apply_bullets(f["bullets"], player)
	# ★ 2026-10-05(修复轮 2,**评审 N-1**):**范围改准** —— 这一行只证明 `_apply()` **自己的函数体**
	#   走到了末尾;它**看不见 `_apply_bullets()` 函数体内**的中止 —— GDScript 的脚本错误只中止
	#   "出错的那个函数",**调用方照常继续** ⇒ 那边一中止,这一行**照样**执行。
	#   故 `_apply_bullets()` 另记一个分子(`_bullets_completed`,见该函数末尾),两条一起才等于
	#   "本帧回放整段没被中止"。
	_apply_completed += 1


## 子弹:按快照帧重建(不足则实例化,多余则隐藏)。回放期间子弹由本函数摆位,
## 实体侧靠 TimeField 冻结;退出回溯后它们恢复为活弹继续飞。
func _apply_bullets(list: Array, player: Node) -> void:
	while _replay_bullets.size() < list.size():
		var meta: Dictionary = list[_replay_bullets.size()]
		var sp := str(meta["sp"])
		# ★★ 2026-10-05(closeout 批 Task 3 / T12):这一段的 `set(…)`/`call(…)` 原先全是**字符串
		#   反射**。两种失败形态都实测过同族:`set` 拼错成员名**静默不写**(弹速/伤害/引信悄悄丢),
		#   `call` 拼错方法名**当场报错并中止本函数**(连后面那些写回一起跳过)。现在类型化。
		#   ★ 行为差(照实):`scene_path` 指向**非 BulletBase** 场景时(今天不可达:唯一写这份
		#     meta 的地方是 `WeaponBase._spawn_projectiles`,写的都是子弹场景)——
		#     旧:按名乱写、节点照旧入树;新:点名报错 + 该帧**不重建**它(记 null)。
		var nb: BulletBase = null
		if sp != "" and ResourceLoader.exists(sp):
			var inst := (load(sp) as PackedScene).instantiate()
			nb = inst as BulletBase
			if nb == null:
				# ★ 2026-10-05(修复轮 1,**评审 M-4**):两处订正 ——
				#   ① 转型失败时这个节点**既不入树也没有被谁引用** ⇒ 必须显式 `free()`,否则泄漏;
				#   ② 措辞:下面 `while _replay_bullets.size() < list.size()` **只按长度补建** ⇒
				#      一个 null 槽在**本次回溯窗口内**都不会被重试(不是"该帧不重建")。
				push_error("WorldRewind: %s 不是 BulletBase —— 该槽位本次回溯内不再重建" % sp)
				inst.free()
			else:
				if _parent != null and is_instance_valid(_parent):
					_parent.add_child(nb)
				elif player != null and is_instance_valid(player):
					player.get_parent().add_child(nb)
				nb.global_position = meta["p"]
				nb.velocity_vec = meta["v"]
				if bool(meta["from_player"]):
					nb.shooter = player
				nb.apply_damage = true
				nb.hit_damage = int(meta.get("dmg", 0))
				nb.hit_impact = float(meta.get("impact", 0.0))
				nb.apply_rewind_state(meta.get("fuse", {}))
				# ★★ 2026-10-03 修:重建出来的弹**必须补上 `scene_path`**,否则**第二次回溯它就没了**。
				#   环缓存的是 `b.get_meta("scene_path")`(见 `record()` 那行),而写这份 meta 的**唯一**
				#   地方是 `WeaponBase._spawn_projectiles`(出膛那一刻)。重建的弹绕过了那条路 ⇒ 它身上
				#   没有 meta ⇒ 退出回溯后它作为**活弹**继续飞,再被 `record()` 时 `sp` 记成**空串**
				#   ⇒ 下一次 `_apply_bullets` 里 `sp == ""` ⇒ 不实例化、`append(null)` ⇒ **子弹凭空消失**。
				#   ★ 这正是用户实测的"第一次回溯正常、第二次回溯子弹直接消失"。
				#   ★ 为什么第一次没事:那一颗是**真**出膛的,meta 齐全;坏的是**重建**出来的那一代,
				#     所以缺陷要**回溯两次**才现形 —— 单次回溯的探针照不到。
				nb.set_meta("scene_path", sp)
		_replay_bullets.append(nb)
	# ── 循环二/三:★ 2026-10-05(修复轮 1,**评审 I-2**):**先判有效性、再类型收窄** ──────────
	#   与 `_apply()` 的敌人循环同一个形态(评审 C-1):`x as BulletBase` 对**真 freed** 实例抛
	#   `Trying to cast a freed object.` 并**中止整个 `_apply_bullets`**(连后面"隐藏多余弹"一起跳过)。
	#   ★ 为什么这里取到 freed 引用**今天不可达**(依据逐条可复核,别只信这句话):
	#     ① `_replay_bullets` 只由本函数 `instantiate()` 填入、或填 `null`(没有第三方往里塞);
	#     ② `begin()`(`:206` 一带)与 `finish()`(`:230` 一带)都会 `clear()` 整表;
	#     ③ `Level0` 只在 `rewinding` 为真时 `step()`(`scenes/level_0.gd:833-835`),
	#        而 `rewinding` 转假的那一帧就 `finish()`(`scenes/level_0.gd:827-828`);
	#     ④ 回溯全程 `scenes/weapons/bullet_base.gd:70-71` 早退 ⇒ 重建弹的 5 条自毁路径
	#        (`:84`/`:114`/`:119`/`:129`/`:134`)**一条都走不到**。
	#     ★ 若哪天这条前提破了(未来新增全局清理 / 换场),这两处就是"抛错 + 整段中止";
	#       故顺序本身就是不变量,不靠注释活着。
	#   ★ `var raw` **故意不加类型**:给 freed 实例做 `var n: Node = …` 这种**带类型的赋值**本身就会
	#     碰那个实例(引擎有 "Trying to assign invalid previously freed instance" 那条路);
	#     旧码能安全跳过它,靠的正是"问的是**未定型 Variant** `is_instance_valid(d["n"])`"。
	for i in list.size():
		var raw2 = _replay_bullets[i]
		if not is_instance_valid(raw2):
			continue
		var nb2 := raw2 as BulletBase
		if nb2 == null:
			continue
		nb2.global_position = list[i]["p"]
		nb2.velocity_vec = list[i]["v"]
		# 引信**每帧**写回:倒退时引信跟着退(否则它会冻结在按下那一刻的剩余量)
		nb2.apply_rewind_state(list[i].get("fuse", {}))
		nb2.visible = true
	for i in range(list.size(), _replay_bullets.size()):
		var raw3 = _replay_bullets[i]
		if not is_instance_valid(raw3):
			continue
		var nb3 := raw3 as BulletBase
		if nb3 == null:
			continue
		nb3.visible = false
	# ★★ 2026-10-05(修复轮 2,**评审 N-1**):本函数的**自己的**完成度分子。
	#   为什么必须有它:`_apply()` 末尾那次递增**看不见本函数体内的中止** —— GDScript 的脚本错误
	#   只中止出错的那个函数、**调用方照常继续** ⇒ 本函数在中途抛错时,`_apply()` 仍会走到末尾 +1。
	#   (评审用插桩实测:错序 + 注入真 freed 弹 ⇒ 本函数的 `[MARK]` 没打印,而 `_apply_completed` 仍 =1、
	#    `⑩` 仍绿。)⇒ 两条分子一起才等于"本帧回放整段没被中止"。
	_bullets_completed += 1


# ── 查询/维护 ───────────────────────────────────────────────

## 当前回放目标时间(秒):瓦片账本按同一时间轴取区间还原。
func current_target() -> float:
	return _t - _cursor


## 回放中的子弹节点(回溯期 Level0 用它们对精英做二次伤害判定)。
func replay_bullets() -> Array:
	return _replay_bullets


func frame_count() -> int:
	return _frames.size()


func recorded_seconds() -> float:
	return _t


## 尸体过期清理:录制中被保留(隐藏)的尸体,死亡时间超出缓冲窗口 → 真正释放。
## Level0 每帧调;用 meta "rw_death_ms" 记的死亡时刻判定。
static func expire_corpses(tree: SceneTree) -> void:
	if tree == null:
		return
	var now := Time.get_ticks_msec()
	var life_ms := int(TimeParams.SNAP_SECONDS * 1000.0)
	for e in tree.get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or not (e as Node).has_meta("rw_death_ms"):
			continue
		if now - int((e as Node).get_meta("rw_death_ms")) > life_ms:
			(e as Node).queue_free()
