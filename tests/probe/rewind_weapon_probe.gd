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
# `_current_slot` 改名成 `_current_type` 后 `get()` 返回 null,快照值静默恒为 0)。
# ★★ 2026-10-04 实测订正**上面这句的后果**(原文只说"快照值静默恒为 0",说轻了;★ R1 评审 ⑦:
#   原句**保留在上**,订正只作追加,不就地改写):那一帧 `_snapshot_player()` 返回的是**空字典**
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
#   S7 **生产端**:`WorldRewind._snapshot_player()` 产出的快照逐字段 == 真值(★ 含 `downed`,
#      2026-10-04 Plan B Task 15 补),且 `wslot`/`widx`/`wmags`/`wlive` **都没被静默写成 0/空**
#      (形状 14 条 + 行为 **10** 条;0 与真值不可分的地方用三个互不相同的非 0 值占位)。
#   S8 **往返保真(2026-10-05 Plan B Task 2)**:发现 A(切枪帧 `_ready` 用条目旧值冲掉回溯写下的
#      `wlive`)+ 发现 B(切枪把**走掉那把**的出膛实弹写回条目、冲掉刚恢复的快照值)的**实测数字**
#      变成断言;另加 `wlive=-1` 且切枪时新实例该取快照条目值、以及条目为 `MAG_FULL`(满弹)时
#      新枪必须满弹(修复轮 1 的 I-1)—— **16 条**。
#   S9 **PvP 宿主形状(同上)**:`server/match/match_host.gd` 的武器/战斗段**逐条**钉住"隔着
#      `wc`/`inv`/`slot`/`live`/`combat` 句柄还反射"为 0、反向钉住类型化访问在位,
#      并且**单独一条顺序判据**钉住 `_apply_rw_frame` 的"切枪在条目写回之前"(修复轮 1 的 I-2)
#      —— **13 条**。
#   S10 **`pvp_haste_mult` 那族的参数注入化(2026-10-05 closeout 批 Task 3 / T10)**:全仓
#      (scenes|core|server)那一族的**字符串反射形态为 0** + 四个类型化站点(属主自读 / PvP 客户端写
#      / **服务端权威写** / 快照读)逐个在位 + 三处注入弧接上(游泳=调用参数、攀爬/武器=每帧推的
#      注入成员);行为侧用**服务端那种写法**改字段,量游泳/攀爬/出膛弹速与根的速度域是否随之变
#      —— **21 条**(形状 12 + 行为 9)。
#   S11 **`pvp_match_client.gd` 那 7 处对象反射(T11)**:加速/回溯/视效三段里逐成员钉"反射形态为 0
#      + 类型化形态在位"(`:234`/`:240` 的 `input_source` 必须是**读宿主自己的、2 次** —— 换成注入源
#      会死锁,债单 §六.7)—— **10 条**,★ 只有形状,**行为归真链路批 A**。
#   S12 **`world_rewind.gd` 敌人/子弹快照段(T12)**:`record()` 那 8 处 + 回放侧 7 处对象反射归零、
#      类型化逐名在位;行为侧直调 `record()` 用**真** EnemyBase/BulletBase 标本逐字段比真值
#      (含 `dead`/`from_player` 两相、`fuse` 整个字典)—— **28 条**(形状 13 + 行为 15)。
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
# ★ 另一条边界(2026-10-05 Task 2 订正):本探针所有场景都以**同一次调用**喂快照,而生产路径
#   **每帧**调一次 —— S5 原先只按"生产口径(连续两帧)"断言,于是发现 A(切枪帧被 `_ready` 冲掉)
#   恰好被下一帧那次调用**补掉**、旧断言全绿而缺陷在。S8 补上了**相反**的口径:只调一次、
#   等新枪入树再断言(=「最后一次回溯正落在切枪帧」)。两条口径都要有,别只留一条。

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const PLAYER_SRC := "res://scenes/player/player.gd"
const WREWIND_SRC := "res://core/sim/world_rewind.gd"
const MATCH_HOST_SRC := "res://server/match/match_host.gd"

# S7 形状用的两个词表(逐名钉住,而不是只数一个总数 —— 见 `_s7_shape()`)。
# 前一条是**已经清掉**的六处对象反射的字面形状;后一条是替上去的类型化访问。
const PRODUCER_REFLECTION := [".get(\"_current_type\")", ".get(\"_current_index\")",
		".get(\"inventory\")", ".get(\"held\")", ".call(\"current_weapon\")",
		".get(\"mag_ammo\")"]
const PRODUCER_TYPED := [".inventory", "._current_type", "._current_index", ".held",
		".current_weapon()", ".mag_ammo"]
# ★★ 玩家根(`player.gd`,**无 `class_name`**)上那 **5 处按字符串名**的访问 —— **逐条**钉住,
# 而不是只数一个总数(2026-10-04 Plan B Task 15;来源 = Task 13 的 G-1 实测)。
# 为什么"只数总数"没有牙:把 `has_method("is_downed")` 的**字符串**改成 `"is_downed_x"`
# (玩家根的真方法一动不动)时,`.get("` + `has_method("` 的计数**仍是 5 ⇒ 旧的 `≤ 5` 照绿**,
# 而生产端那一帧的 `"downed"` **静默恒 false** ⇒ 消费端 `player.gd:1039-1042` 的倒地/复活还原
# 被静默跳过(实测:探针 60 条全绿)。
# ★ 每条都写**成员名 + 访问形态**(`get("hp")` 而不是裸 `hp`):裸名会被**同一个函数里的别的出现**
#   骗过 —— `"hp"` 同时是字典键、`is_downed` 同时是 `player.is_downed()` 那个真方法调用
#   ⇒ 裸名判据对"字符串被改名"**恰好无牙**(G-1 咬不住就是这个原因)。
# ★ 覆盖上限:`_has_member_token` + 这 5 条只挡"成员名被改名/后缀拼接"(如 `is_downed_x`);
#   **换个完全不同的名字**(`is_downed` → `is_alive`)咬不住 ⇒ 那种退化只有**行为**断言兜着
#   (S7 的 `snap["downed"] == 真值` 那一条)。
const PRODUCER_NAMED_PLAYER_ACCESS := [".get(\"velocity\")", ".get(\"hp\")",
		".get(\"facing_direction\")", ".get(\"weapons\")", ".has_method(\"is_downed\")"]

# ── S9 的判据表:PvP 宿主 `server/match/match_host.gd` 的武器/战斗段 ─────────────
# ★ 为什么把 PvP 那一份也钉进来:单机(`Player.rewind_restore`)与 PvP(`MatchHost._apply_rw_frame`)
#   是**同一个往返的两份实现**,`_record_rw_frame` / `_apply_rw_frame` 里的武器族 6 处 + 战斗族 5 处
#   原先全是隔着句柄的字符串反射。只清单机那一半 = 修一半。
# ★ 形状守卫的**目标**(可达且精确):拿到 `wc` / `inv` / `live` / `combat` 句柄之后,
#   "隔着一层还反射"的链**归零**。逐条钉(而不是数一个总数):总数对"其中一处没清掉但别处少了"
#   无牙;逐条才能各自咬住自己的改名/回退。
const HOST_FUNCS := ["_record_rw_frame", "_apply_rw_frame", "_wire_hit_feedback"]
const HOST_HANDLE_REFLECTION := ["wc.get(\"", "wc.call(\"", "inv.get(\"", "slot.get(\"",
		"live.get(\"", "live.set(\"", "combat.get(\"", "combat.set(\"", "combat.call(\""]
# 反向:类型化访问必须**逐名在位**(全段删掉也能让上面 9 条计数为 0;同 S6/S7 的反向六条)。
const HOST_TYPED_TOKENS := ["wc._current_index", "wc.inventory", "inv.held", "wc.current_weapon()",
		"wc.equip_index(", "live.mag_ammo", ".apply_mag(", "combat.max_hp", "combat.hp",
		"combat.hp_changed.emit("]
# ★ 玩家根上的按名取组件(**唯一允许的那一层**;玩家根无 `class_name` ⇒ 只能按名取):
#   `get("weapons")` 2 处(**`_record_rw_frame` + `_apply_rw_frame`**)、
#   `get("combat")` 2 处(**`_apply_rw_frame` + `_wire_hit_feedback`**)——
#   ★ 2026-10-05 修复轮 1(M-7):两个计数**各自 2**、但**分布不同**(`_wire_hit_feedback` 里
#   **没有** `get("weapons")`;`_record_rw_frame` 里**没有** `get("combat")`)⇒ 别把括号读成
#   "三函数各占一份"。本包不许把它改多 —— 类型化它要动类结构(全局类名 + 打掉两个刻意造的裸宿主桩,
#   R11 明令禁止)。★ 用 `<=` 而不是 `==`:将来真给玩家根加了 `class_name`,处数**下降**不该把
#   守卫喂红(同 S7 那条的处理)。★ 覆盖上限:`<=` 对"整段被删"也成立(0 ≤ 2)⇒ 那由上面的反向
#   `HOST_TYPED_TOKENS` 与 S8 的行为断言兜着。
const HOST_ROOT_WEAPONS_GET := "get(\"weapons\")"
const HOST_ROOT_COMBAT_GET := "get(\"combat\")"
# ★ S9 的**顺序**判据用的两个锚(修复轮 1 评审 I-2):`_apply_rw_frame` 的修 B 是**语句序**,
#   而上面那 9 条计数 + 反向令牌对**顺序**天生不可见 —— 把 `if switched: wc.equip_index(...)`
#   整段挪到条目写回**之后**(= M2 的 PvP 等价物),那些判据**一条都不红**。
#   ⇒ 单独用 `find()` 的下标关系钉住:`equip_index` 必须出现在条目写回**之前**。
#   ★ 两个锚都是**整条语句**级(不是裸成员名):`find` 找的是完整语句,不会被"同名的别处出现"骗过;
#     注释已被 `_code_view` 剥掉 ⇒ 注释里写锚串不会误伤(负向对照 M17 同一机理)。
const HOST_APPLY_EQUIP_ANCHOR := "wc.equip_index("
const HOST_APPLY_WRITEBACK_ANCHOR := "held[i][\"mag\"] = int(mags[i])"
# 成员名字符集(给 `_has_member_token`)
const _IDENT_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


# `_has_member_token` 的**计数**版:两侧都判边界,返回完整成员名出现的次数。
# ★ 为什么需要它(closeout Task 3 的逐条变异 M1 **实测**出来的洞):S10 那条"`swim.update` 的
#   `haste_mult` 参数有没有被函数体用到"原先写的是 `body.count("haste_mult") >= 2` —— 而把参数
#   换回**反射**写法(`float(parent.get("pvp_haste_mult"))`)之后,那个字符串里的
#   `pvp_haste_mult` **含有** `haste_mult` 这个子串 ⇒ 计数仍是 2、**那条断言照绿**
#   (只有"全仓反射形态"那条红)。这正是本仓那条纪律的又一例:「守卫能给的保证总是比它读起来少」。
func _count_member_tokens(body: String, pat: String) -> int:
	var n := 0
	var from := 0
	while true:
		var i := body.find(pat, from)
		if i < 0:
			return n
		var after := body.substr(i + pat.length(), 1)
		var before := body.substr(i - 1, 1) if i > 0 else ""
		if (after == "" or not _IDENT_CHARS.contains(after)) \
				and (before == "" or not _IDENT_CHARS.contains(before)):
			n += 1
		from = i + 1
	return n

# ── S10 / S11 / S12(2026-10-05 closeout 批 Task 3:**反射清理收口**)用的词表 ──────────
# 三片反射各自的关键字面量。★ 与 S6/S7/S9 同款纪律:**先把注释剥掉**(`_code_view`)——
# 讲这三条病的新注释里会写出反射字形,不剥就会把断言自己喂红(负向对照 M17 同一机理)。
const PROD_ROOTS := ["res://scenes", "res://core", "res://server"]
# T10:`pvp_haste_mult` 一族**不许**再出现的字符串反射形态(全仓 `res://scenes|core|server` 扫)。
const HASTE_REFLECTION_FORMS := [".get(\"pvp_haste_mult\"", ".set(\"pvp_haste_mult\"",
		"\"pvp_haste_mult\" in ", "has_method(\"pvp_haste_mult\""]
const SWIM_SRC := "res://scenes/player/swim_component.gd"
const CLIMB_SRC := "res://scenes/player/climb_component.gd"
const WBASE_SRC := "res://scenes/weapons/weapon_base.gd"
const PVPCLIENT_SRC := "res://scenes/pvp_match_client.gd"
const MATCH_SNAPSHOT_SRC := "res://server/match/match_snapshot.gd"
# T11:那 7 处**经手 `_local`** 的代码只在 pvp_match_client.gd 这三个函数里 ⇒ 逐函数取体,
# 不去数整个文件里那些**合法**的字典取键(34 行)。
const PVP_TIME_FUNCS := ["_tick_beta_time", "_tick_beta_rewind", "_tick_time_fx"]
# T12:`record()` 里敌人/子弹快照段那 8 处对象反射的原文形态(逐条一条断言 ⇒ 各自咬住自己的改名)。
const RW_RECORD_REFLECTION := [".get(\"velocity\")", ".get(\"hp\")", ".get(\"is_dead\")",
		".get(\"shooter\")", ".call(\"rewind_state\")", ".get(\"velocity_vec\")",
		".get(\"hit_damage\")", ".get(\"hit_impact\")"]
# T12:回放侧(`_apply` + `_apply_bullets`)同族反射的原文形态,与替上去的类型化写法。
# ★ **故意不收** `.has_method("rewind_restore")`:`_apply()` 里还剩**一处**打在**玩家根**上
#   (`player.has_method("rewind_restore")`)—— 那是"没有 `class_name` 的玩家根"那一族
#   (S7 已把同族那 5 处逐名收编为**允许保留**),消它要给 player 根加 `class_name`(R11 明令
#   禁止)⇒ **不属本任务**。敌人那处同名字符串已被类型化替掉,锚在下面 `as EnemyBase` 上。
const RW_APPLY_REFLECTION := [".set(\"velocity_vec\"",
		".set(\"apply_damage\"", ".set(\"hit_damage\"", ".set(\"hit_impact\"", ".set(\"shooter\"",
		".call(\"apply_rewind_state\""]
const RW_APPLY_TYPED := [".rewind_restore(", ".apply_rewind_state(", ".velocity_vec = ",
		".hit_damage = ", ".hit_impact = ", ".shooter = ", ".apply_damage = ",
		"as EnemyBase", "as BulletBase"]
const ENEMY_SCENE := "res://scenes/enemies/enemy_fly_bird.tscn"
const BULLET_SCENE := "res://scenes/weapons/bullet.tscn"


# `pat` 必须以**完整成员名**出现:后缀拼接(如 `._current_index_x`)不算。
# ★ 为什么需要它(R1 评审 ② 的逐条变异**实测**出来的弱点):下面那 6 条"类型化访问还在"用的是
#   `contains` —— 而"把成员名改坏成 `原名+后缀`"**仍然包含原串** ⇒ 那 6 条会照旧打 ✓,
#   只有行为断言(整帧快照退化)红。加上边界判定后,每条反向断言都能**各自**咬住自己的改名。
func _has_member_token(body: String, pat: String) -> bool:
	var from := 0
	while true:
		var i := body.find(pat, from)
		if i < 0:
			return false
		var after := body.substr(i + pat.length(), 1)
		if after == "" or not _IDENT_CHARS.contains(after):
			return true
		from = i + 1
	return false

# 注册表里的 1 = 手枪(12 发)、2 = 步枪(30 发)。数值只在 `data/weapons.json`,
# 本探针只借这两个 id 造"两把不同的枪"。
const TYPE_PISTOL := 1
const TYPE_RIFLE := 2

# 断言计数闸(与 `kh_l3_visual_probe` / `combat_hud_visual_probe` 同款)。
# ★ 90 是**逐个数出来的**(全部 `_check(` 调用点都在 `_s1.._s9` 这九个函数里):
#   S1 7(前置 + `_check_cells` 3 + 下标 + 同实例 + 手持实弹)
#   S2 3、S3 5(下标 + `_check_cells` 3 + 手持实弹)
#   S4 6(前置 + 手持实弹未动 + `_check_cells` 3 + 下标)
#   S5 7(下标 + 实例非空 + 类型 id + 手持实弹 + `_check_cells` 3)
#   S6 9、S7 24(前置 1 + 反射逐名 6 + 类型化逐名 6 + 按名访问逐名 1 + 行为 10)
#   S8 **16**(发现 A/B 往返保真:A 前置 1 + 下标 1 + 手持实弹 1 + `_check_cells` 3;
#          B 前置 1 + 走掉那把条目 1 + 第 1 格 1 + 手持实弹 1;
#          C 前置 1 + `wlive=-1` 时新实例取值 1 + 走掉那把条目 1;
#          D 前置 1 + 条目 `MAG_FULL` 时新枪满弹 1 + 条目仍为 `MAG_FULL` 1)
#   S9 **13**(PvP 宿主形状:前置 1 + 隔着句柄的反射逐条 9 + 类型化逐名反向 1 + 根句柄上界 1
#          + **语句序 1**)
#   ⇒ 合计 90。
#   ★ 2026-10-04(Plan B Task 15):S7 行为 9→10 —— 新补一条 `snap["downed"] == 真值`
#     (来源 = Task 13 的 G-1:`snap["downed"]` 此前**一条断言都没有**,连行为带形状都没有)。
#   ★ 2026-10-05(closeout 批 Task 2):61→86 —— 新补 S8(13,发现 A/B 的往返保真)与
#     S9(12,PvP 宿主 `match_host.gd` 的反射归零)。三个写同一个量的地方
#     (本常量 + 上面这句分解 + 下面 `_check()` 上方那句"86 行")必须一起改。
#   ★ 2026-10-05(修复轮 1,评审 I-1/I-2):86→**90** —— S8 +3(`MAG_FULL` 那档)、S9 +1(语句序)。
#   ★ 2026-10-05(closeout 批 **Task 3**:反射清理收口):90→**149** —— 新补三节:
#     · S10(T10 `pvp_haste_mult` 参数注入化)**21** = 形状 12(前置 1 + 全仓反射形态 1 +
#       四个类型化站点 4 + 三处注入弧 6)+ 行为 9(TimeField 前置 1 + 游泳 2 + 攀爬 2 + 武器 3
#       + 权威侧 1)。
#     · S11(T11 `pvp_match_client.gd` 那 7 处)**10** = 前置 2 + 反射逐条 6 + 类型化逐名 1
#       + 聚合 1。
#     · S12(T12 `world_rewind.gd` 敌人/子弹快照段)**28** = 形状 13(前置 2 + `record()` 逐条 8
#       + 回放侧逐条 1 + 类型化逐名 2)+ 行为 15。
#     ★ 实测:**本批第一次跑(改动前)实跑就是 149 条**(日志 `task-3-red-before.txt`),
#       没有"脚本错误静默跳过若干条"的空间 —— 但计数闸仍然要在,它管的是**以后**。
#   用 `!=` 而不是 `<`:新增断言忘了登记同样要红(`late_match_probe` 同款)。
const EXPECTED_CHECKS := 149
var _checks := 0


func probe_id() -> String:
	return "RW-WEAPON"


# 覆写只为**逐条留轨迹**:149 行 ✓/✗ 是"该跑的都跑过"的凭据(计数闸之外的第二道)。
# ★ 这个数字与 `EXPECTED_CHECKS` 是**两处写着同一个量** —— 改计数闸时要一起改(R1 评审 ⑥:
#   它曾经停在 37 而 `EXPECTED_CHECKS` 已是 60;Task 15 时两处一起 60→61;Task 2 时 61→86;
#   修复轮 1 时 86→90;closeout Task 3 时 90→149)。
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
	await _s8_round_trip(player, wc)
	_s9_host_shape()
	# ── 2026-10-05(closeout 批 Task 3:反射清理收口)三片:加速倍率注入 / PvP 客户端 7 处 /
	#    世界回溯的敌人·子弹快照段。★ 为什么钉在本文件:仓里只有它同时具备**真 `player.tscn`
	#    + `_has_member_token` 词表 + `_code_view`/`_top_func_body`**,而这三片要的正是这两样。
	_s10_shape()
	await _s10_behavior(player, wc)
	_s11_client_shape()
	_s12_shape()
	_s12_behavior(player)

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
	# 断言就不必把那条**既有**写回行为钉进本探针(发现 B 由 S8-B 单独钉)。
	var d5 := _snap(player, 1, [5, 4], 9)
	_restore(player, d5)
	# ★ 仪器(不是断言),2026-10-05(Task 2)后实得:
	#   `切枪那一帧 index=1 mag=0;入树(_ready)后 mag=9;再调一次后 index=1 mag=9`。
	#   ★ 三个数字各自的道理(改前的仪器是 `mag=9 → 入树后 4 → 9`,见报告):
	#     · 切枪那一帧 mag=**0** —— 新枪由 `call_deferred("add_child")` 入树,此刻 `_ready` 未跑
	#       ⇒ `mag_ammo` 还是声明初值 0;而 `wlive` 已按 `apply_mag` 落在 `pending_mag` 上
	#       (那一帧谁读 `mag_ammo` 都会读到 0 —— 生产里这个窗口被 `_mag_ready` 与 deferred 的
	#       `_ready` 一起兜住,详见 `weapon_base.gd:100-127`)。
	#     · 入树后 mag=**9** —— `_ready()` 消费 `pending_mag` 得到**快照的 `wlive`**(改前这里是
	#       条目旧值 4 = 发现 A)。
	#     · 再调一次仍 9 —— 生产路径每帧调一次;第二次下标已相同 ⇒ 不再切枪 ⇒ 走同步写那一支。
	#   ★ 本段仍按**生产口径**(连续两帧)断言;"最后一次调用正好落在切枪帧"的口径由 S8-A 钉。
	var idx_frame1 := wc._current_index
	var mag_frame1 := _live_mag(wc)
	await _frames(2)
	# ★ 中间那一拍:新枪此时已入树,`_ready()` 已消费 `pending_mag` ⇒ 这一拍就是发现 A 的现场
	#   (改前 = 条目旧值 4;修好后 = 快照 wlive 9)。
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
			"S5: 手持那件实弹 = %d(快照 wlive=9;=4 即 wlive 那一写没生效(发现 A 的旧值),"
			% (int(live2.mag_ammo) if live2 != null else -99)
			+ "=30 即 `_ready` 的满弹冲掉了它)")
	_check_cells("S5", wc, [5, 4])


# ── S6 形状:那一带的字符串反射计数为 0 ─────────────────────────────
func _s6_shape() -> void:
	# `code_view` 保留缩进、剥掉注释(注释里提到 `.call("` 不该让本条红/绿);
	# `top_func_body` 只认行首 `func `,免得内部类的同名方法骗过取体。
	var body := _top_func_body(_code_view(_read(PLAYER_SRC)), "rewind_restore")
	var player_body_lines := 0 if body.is_empty() else body.split("\n").size()
	_check(not body.is_empty(),
			"S6 前置:读到了 player.gd 的 rewind_restore 函数体(实得 %d 行;0 行=改名/读不到源,"
			% player_body_lines + "下面几条 `== 0` 全是空转)")
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
	# ★★ 2026-10-04(Plan B Task 13):这五条原来用 `contains(pat)` —— 与 R1 在 S7 段**实测**出的
	#   弱点同款:"把成员名改坏成 `原名+后缀`"(`._current_index` → `._current_index_x`)**仍然包含
	#   原串** ⇒ 这几条照旧打 ✓(只有行为断言会红)。改用 `_has_member_token`(完整成员名 + 边界,
	#   见该函数上方)。
	#   判据 = ①`_has_member_token(stem)`:成员名**后面**必须不是标识符字符 ⇒ 后缀拼接不算"还在";
	#          ②`body.contains(pat)`:原文**形状**必须还在 —— 对自带 `(`/`()` 的两条,它额外钉住
	#            "还是**调用**形状"(那两条本来就不怕后缀拼接:R1 实测 M3 是加固前唯一会红的一条;
	#            留着 ② 是为了不把"调用漂移成裸属性访问"悄悄放过)。
	#   ★ ①∧② 是**合取** ⇒ 相对旧判据只严不宽(条数不变:仍是 5 条)。
	#   ★★ 2026-10-05(closeout 批 Task 2):第 5 条从 `.mag_ammo` 改成 `.apply_mag(`。
	#     理由 = 修发现 A 时,那段"写手持实弹"的**写法**从 `live2.mag_ammo = …`(未入树窗口里
	#     无效、会被 `_ready` 冲掉)换成 `WeaponComponent.apply_mag(live2, …)`。旧条目钉的是
	#     **被修掉的那个写法**,不改它就会把"修好了"读成红。买到的保证不变:仍是"这一段里
	#     有一个**类型化的落弹写法**在"(而不是"整段被删")。
	#   ★ 覆盖上限:`_has_member_token` 只挡"后缀/前缀拼接"这类改名;**换个完全不同的名字**
	#     仍得靠行为断言(S1-S5 那 28 条 + S7 的行为 **10** 条 + S8 的 **16** 条)。
	#     ★ 2026-10-05 修复轮 1(M-1):这里原写"S7 的行为 9 条"、S8 写"13 条" —— 前者与
	#       `:39`/`:141`/`:147` 的 **10** 自相矛盾(Task 15 已 9→10),后者在修复轮 1 变 16。
	for pat in [".inventory", "._current_index", ".equip_index(", ".current_weapon()", ".apply_mag("]:
		var stem: String = pat.rstrip("()")
		_check(_has_member_token(body, stem) and body.contains(pat),
				"S6: rewind_restore 里找不到类型化访问 `%s`(须是**完整成员名** `%s`,"
				% [pat, stem]
				+ "后缀拼接改名如 `%s_x` 不算)" % stem
				+ " —— 该段被删了/改名了?那反射计数为 0 是假的")


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
	# ── ★★ 2026-10-04(Plan B Task 15):`snap["downed"]` 的**行为**断言 ─────────────────
	# 来源 = Task 13 的 G-1 实测:只把生产端那一行的**字符串**改成 `has_method("is_downed_x")`
	#   (玩家根的真方法**一动不动**)⇒ 本探针 **60 条全绿**,而 `"downed"` **静默恒 false**
	#   ⇒ 消费端 `player.gd:1039-1042` 的倒地/复活还原被静默跳过(`if bool(d["downed"])…` 再也不进)。
	#   `rewind_probe.gd` 里 `downed` 出现 0 次 ⇒ 这一维此前**没有任何行为守卫**。
	# ★ 为什么必须**两相都测**(活着 + 倒地):只测一相时,"生产端恒返回同一个常量"照样能过
	#   (恒 false 骗过"活着相"、恒 true 骗过"倒地相")。两相一起钉,"`downed` 有取值来源"才成立。
	# ★ 真值取自 `player.call("is_downed")`(玩家根 → `combat.downed`),与生产端**同一个真值源**;
	#   若这条**造不出倒地玩家**(`truth_downed` 不为 true),本条会**红**,而不是退化成"恒 false 也算过"。
	# ★ 两处 `.get(键, 哨兵)` 的哨兵**故意取"会红"的那一侧**:键被删掉时 `snap_alive` 读成 true、
	#   `snap_downed` 读成 false ⇒ 必红(空读/缺键不许恒绿)。
	# ★ 仪器噪声(既有缺陷、不属本任务):`set_downed_by_rewind` 里那句 `animator.play("downed")` 会打
	#   `ERROR: There is no animation with name 'downed'` —— `player.tscn` 的 SpriteFrames 只有
	#   charge/fly/idle/move/squat,全仓也没有运行时替换。该错误发生在 `downed = v` **之后**
	#   ⇒ 状态照样置上(实测 `truth_downed=true`),只是该函数就此中止、`went_down` 不再发。
	#   本断言只看状态,不受影响;那处死引用记在 Task 15 报告里(不在本任务的允许改动文件内)。
	var combat := player.get("combat") as CombatComponent
	var truth_alive := bool(player.call("is_downed"))
	var snap_alive := bool(WorldRewind.new()._snapshot_player(player).get("downed", true))
	var truth_downed := false
	var snap_downed := true
	if combat != null:
		combat.set_downed_by_rewind(true)
		truth_downed = bool(player.call("is_downed"))
		snap_downed = bool(WorldRewind.new()._snapshot_player(player).get("downed", false))
		# 复原:本探针后面只剩形状段(读源码),但把玩家留在倒地态会给**下一次**改动埋雷。
		combat.set_downed_by_rewind(false)
	_check(not truth_alive and truth_downed and not snap_alive and snap_downed,
			"S7: 快照 `downed` 必须 == 真值(两相:活着 → false、倒地 → true;"
			+ "实得 活着 真值=%s 快照=%s、倒地 真值=%s 快照=%s" % [str(truth_alive), str(snap_alive),
					str(truth_downed), str(snap_downed)]
			+ ")—— 把来源写成常量、或 `has_method` 的名字对不上(恒 false)都是这条要咬的;"
			+ "`combat` 取不到 ⇒ 倒地相造不出来,本条同样红(不许写成'恒 false 也算过')")


# ── S7 形状:生产端武器段不许再有对象反射(逐名 + 残值上界)─────────────
func _s7_shape() -> void:
	# 与 S6 同法:`code_view` 剥注释(否则解释这条病的注释会把断言喂红)、
	# `top_func_body` 只认行首 `func `。
	var body := _top_func_body(_code_view(_read(WREWIND_SRC)), "_snapshot_player")
	# ★ 前置必须自己是一条**会红**的断言,而不是 `if ...: return`:空读时下面那些 `not contains`
	#   恒真(否定断言的空读恒真),只看后面几条会把"读不到源"读成通过。
	# ★ 措辞用**正向**:绿的时候打印"抽不到…"会与 ✓ 自相矛盾,削弱本文件"逐条留轨迹"的证据力
	#   (★ R1 评审 Minor ⑧)。红的时候看 ✗ + 括号里的实得值(0 行)即可。
	#   ★ `"".split("\n")` 在 GDScript 里是 **1** 个元素 —— 空读若直接打 size 会报"1 行",与"空"
	#     自相矛盾(实测),故显式折算成 0。
	var body_lines := 0 if body.is_empty() else body.split("\n").size()
	_check(not body.is_empty(),
			"S7 前置:读到了 world_rewind.gd 的 _snapshot_player 函数体(实得 %d 行;0 行=改名/读不到源,"
			% body_lines + "下面几条计数全是空转)")
	if body.is_empty():
		return
	for pat in PRODUCER_REFLECTION:
		_check(not body.contains(pat),
				"S7: _snapshot_player 里不许再出现对象反射 `%s` —— 成员名对不上时它静默返回 null,"
				% pat + "轻则该字段变 0/空,重则整帧快照退化成空字典(实测;见 world_rewind.gd 注释)")
	# ★ 反向六条:计数/缺席只证明"没有反射",**不证明"类型化访问还在"** —— 把整段删掉也满足。
	#   ★ 用 `_has_member_token` 而不是 `contains`:后缀拼接的改名不算"还在"(见该函数上方)。
	for pat in PRODUCER_TYPED:
		_check(_has_member_token(body, pat),
				"S7: _snapshot_player 里找不到类型化访问 `%s`(须是**完整成员名**,后缀拼接不算)"
				% pat + " —— 该段被删了/改名了?那上面的缺席是假的")
	# 残值边界:`_snapshot_player` 里仍允许的**按字符串名访问玩家**只有**玩家根**(`player.gd`,
	# **无 `class_name`**)上的 **5 处**,这里**逐个点名**(★ R1 订正:原先只数 `.get("`、消息里只列
	# 4 处,读起来像完整枚举,**漏了第 5 处** `player.has_method("is_downed")`);
	#   ① `player.get("velocity")` ② `player.get("hp")` ③ `player.get("facing_direction")`
	#   ④ `player.get("weapons")` ⑤ `player.has_method("is_downed")`(配 `player.is_downed()`)。
	# ⑤ 的失败形态与其它四处同型:`is_downed` 改名 ⇒ `has_method` 恒 false ⇒ `"downed"` 静默写
	# false ⇒ 消费端 `player.gd:1039-1042` **静默跳过倒地/复活还原**(故它必须计入度量)。
	#   ★★ 2026-10-04 订正:原文写的是 `player.gd:987-989` —— 已过期,按内容 `grep` 复核后改成
	#     `1039-1042`(★ 2026-10-05 Task 2 **二次订正**:Task 15 时是 `995-998`,而本轮在同一函数
	#     (`rewind_restore`)里插了 44 行 ⇒ 又移了。复核法同上:`grep -n "set_downed_by_rewind\|combat.revive()"`
	#     实测那四行在 `1039-1042`,该文件共 **1042** 行 = 那四行就是文件末尾)。
	# 它们要类型化得给 player 根加 `class_name`(动类结构:全局类名 + 两个刻意造的裸宿主桩会被
	# 打掉;已登记,不属本任务)⇒ 计数仍用 `<=` 而不是 `==`,免得将来有人补了 class_name 反而把守卫喂红。
	# 正解是把 weapons 组件(及其余 4 处的值)**当参数注进来**(见 Task 3 报告),不是给根加类型。
	# ★★ 2026-10-04(Plan B Task 15):把度量从**只数上界**换成**逐名核**。旧口径的病由 Task 13
	#   的 G-1 实测钉死:`≤ 5` 之下把 `is_downed` 改成 `is_downed_x`,计数**仍是 5 ⇒ 本条照绿**,
	#   而 producer 的 `"downed"` 静默恒 false(日志 `task-13-mutation-log.txt`)。
	#   现在对这 5 处**各来一条 `_has_member_token`**(完整成员名 + 访问形态 + 边界,见该函数上方):
	#   后缀拼接改名(`is_downed_x`)不再算"还在" ⇒ 5 条变异各自红在本条上(消息里点名缺哪个)。
	#   ★ 条数**没变**:5 个谓词与原来的 `≤ 5` 合取进**同一条** `_check` —— 本任务只许净 +1 条,
	#     那一条是上面 `_s7_producer` 里新补的 `snap["downed"] == 真值`。
	#   ★ 覆盖上限:`_has_member_token` 只挡"后缀/前缀拼接"类改名;**换个完全不同的名字**
	#     (`is_downed` → `is_alive`)本条咬不住 ⇒ 那由 `_s7_producer` 的行为断言兜着。
	#   登记的原文与翻案条件:`docs/eng/registered-debt.md` §六.15。
	var named_missing: Array[String] = []
	for pat in PRODUCER_NAMED_PLAYER_ACCESS:
		if not _has_member_token(body, pat):
			named_missing.append(pat)
	var named_accesses := body.count(".get(\"") + body.count("has_method(\"")
	_check(named_missing.is_empty() and named_accesses <= 5,
			"S7: 玩家根那 5 处按字符串名访问必须**逐名**在位(velocity/hp/facing_direction/"
			+ "weapons/is_downed 的**访问形态**),且总数不超过 5 —— 实得 ×%d,缺 %s"
			% [named_accesses, str(named_missing)])


# ── S8 往返保真:切枪帧(发现 A)与走掉那把的条目(发现 B)────────────────────
# 来源 = `reflection-and-input-fallback` Task 1 报告 §发现A / §发现B 的两条**实测仪器**
# (两条都是"改前就有"的既有缺陷 2026-10-05 本包修)。这两条此前**一条断言都没有**:
# S5 那个"跨武器切枪"场景是**连续两帧**喂快照(生产口径),而缺陷恰好被下一帧的那次调用
# **补掉** ⇒ 旧断言全绿而缺陷在。
# ★ 本节的形状刻意与 S5 **相反**:S5 证明"生产里下一帧会补上",本节证明"**就算那是最后一次
#   调用**(玩家恰在那一刻松开 Shift),值也必须是对的" —— 那正是缺陷的真实后果。
# ★ 三个子场景各自钉一个机制(不合并成一次调用):A 钉 `_ready` 把 `wlive` 冲成条目旧值、
#   B 钉切枪把**走掉那把**的条目写回、C 钉 `wlive=-1` 时新实例该拿哪个值。合并会**串味**:
#   一条没修好时另一条的断言跟着红,变异日志就说不清"红在哪条上"(档 3 的硬要求)。
# ★ 覆盖上限:三个子场景都走**真 `player.tscn` + 直调 `rewind_restore`**,与 S1-S7 同一条
#   边界 —— 不覆盖真回溯的帧选择、也不覆盖 PvP 宿主那一份(`MatchHost._apply_rw_frame`);
#   后者只有**源码形状**守卫(S9),行为侧要真链路(批 A,见报告)。
func _s8_round_trip(player: Node, wc: WeaponComponent) -> void:
	# ── S8-A 切枪帧:`rewind_restore` **只调这一次**(= "最后一次回溯正落在切枪帧")──
	# 现场刻意与快照不同(live=3 / 条目 3、4),否则"写了"与"没写"在断言上不可分(恒绿)。
	# ★ 条目第 0 格 = 3 **刻意等于**走掉那把的出膛实弹:让发现 B 的写回在 A 里成为无操作
	#   ⇒ A 只钉发现 A,归因干净(B 由下面的 S8-B 单独钉)。
	await _s8_hold_first(wc)
	var live_a := wc.current_weapon()
	_check(wc._current_index == 0 and live_a != null and live_a.is_inside_tree(),
			"S8-A 前置:应从第 0 把(且已入树)出发 —— 实得 index=%d live=%s"
			% [wc._current_index, str(live_a)])
	if live_a == null:
		return
	live_a.mag_ammo = 3
	wc.inventory.held[0]["mag"] = 3
	wc.inventory.held[1]["mag"] = 4
	_restore(player, _snap(player, 1, [3, 4], 9))
	# ★★ 这里**不**再调第二次 `_restore`(那是 S5 的口径):第二次调用时下标已相同 ⇒ 不再切枪
	#    ⇒ `_ready` 那一冲根本不会发生 ⇒ 缺陷被绕过。只等新枪入树(= `_ready` 已跑)再断言。
	await _frames(3)
	_check(wc._current_index == 1,
			"S8-A: 快照 widx=1 ⇒ 应切回第 1 把(实得 `_current_index`=%d)" % wc._current_index)
	_check(_live_mag(wc) == 9,
			("S8-A(发现 A): 切枪之后再没有第二次 `rewind_restore`,手持实弹仍必须是快照 wlive=9"
			+ "(实得 %d;=4 就是 `WeaponBase._ready()` 消费了 `pending_mag` 里的**条目旧值**"
			+ " —— 发现 A 的机制是「条目 → pending_mag → `_ready` 覆盖 mag_ammo」)")
			% _live_mag(wc))
	_check_cells("S8-A", wc, [3, 4])

	# ── S8-B 走掉那把:快照说它有 11 发,"出膛实弹写回条目"不许把它冲成现场值 3 ──
	await _s8_hold_first(wc)
	var live_b := wc.current_weapon()
	_check(wc._current_index == 0 and live_b != null and live_b.is_inside_tree(),
			"S8-B 前置:应从第 0 把(且已入树)出发 —— 实得 index=%d live=%s"
			% [wc._current_index, str(live_b)])
	if live_b == null:
		return
	live_b.mag_ammo = 3                 # 走掉那把的**出膛实弹**(发现 B 仪器里的那个 3)
	wc.inventory.held[0]["mag"] = 3
	wc.inventory.held[1]["mag"] = 4     # 与快照的 1 不同:证明条目确实被快照写回过
	_restore(player, _snap(player, 1, [11, 1], 1))
	await _frames(3)
	var held_b: Array = wc.inventory.held
	_check(int(held_b[0]["mag"]) == 11,
			("S8-B(发现 B): 走掉那把的条目必须 = 快照 wmags[0]=11(实得 %d;"
			+ "=3 就是 `_equip_index` 把出膛实弹写回条目、把刚恢复的快照值冲掉了)")
			% int(held_b[0]["mag"]))
	_check(int(held_b[1]["mag"]) == 1,
			"S8-B: 第 1 格条目 = 快照 wmags[1]=1(实得 %d)" % int(held_b[1]["mag"]))
	_check(_live_mag(wc) == 1, "S8-B: 手持实弹 = 快照 wlive=1(实得 %d)" % _live_mag(wc))

	# ── S8-C `wlive=-1` 且确实切了枪:新实例总得有个值 ⇒ 用**快照的条目值** ──
	# 快照没记手持实弹(-1)时不许"写成 0 也算过":新枪的值只可能来自快照条目。
	# ★ 这一条**改前改后都绿**(改动前:条目先写回、`_equip_index` 从条目取 ⇒ 1)—— 它钉的是
	#   修法里那条 `wlive < 0` 分支:去掉那条分支,新枪会停在**恢复前**的条目值 7(红)。
	await _s8_hold_first(wc)
	var live_c := wc.current_weapon()
	_check(wc._current_index == 0 and live_c != null and live_c.is_inside_tree(),
			"S8-C 前置:应从第 0 把(且已入树)出发 —— 实得 index=%d live=%s"
			% [wc._current_index, str(live_c)])
	if live_c == null:
		return
	live_c.mag_ammo = 5
	wc.inventory.held[0]["mag"] = 5
	wc.inventory.held[1]["mag"] = 7     # 恢复前的旧条目值:新实例**不许**停在这里
	_restore(player, _snap(player, 1, [11, 1], -1))
	await _frames(3)
	_check(_live_mag(wc) == 1,
			("S8-C: wlive=-1(快照没记手持实弹)而确实切了枪 ⇒ 新实例应落在**快照条目值** 1"
			+ "(实得 %d;=7 就是恢复前的旧条目值 —— 语句序改动后漏了那条 `wlive < 0` 分支)")
			% _live_mag(wc))
	_check(int(wc.inventory.held[0]["mag"]) == 11,
			"S8-C: 同一次调用里走掉那把的条目仍 = 快照 wmags[0]=11(实得 %d)"
			% int(wc.inventory.held[0]["mag"]))

	# ── S8-D ★★ 2026-10-05 修复轮 1(评审 I-1):快照条目是 `MAG_FULL(-1)` 时新枪必须是**满弹** ──
	# 为什么单独一条:**两个 `-1` 语义不同** —— `wlive == -1` 是"快照没记"的**哨兵**,
	#   而**条目**的 `mag == MAG_FULL(-1)` 是"**满弹**"(`weapon_inventory.gd:38`;
	#   `_equip_index` 对着它**不设** `pending_mag`、由 `_ready` 落 `mag_size`)。
	#   语句序换到"切枪在前"之后,`_equip_index` 读的是**恢复前**的条目 ⇒ 条目为满弹时它什么都不设;
	#   而 C 分支把 `want` 解成 `-1`、又被 `want >= 0` 挡住 ⇒ `apply_mag` 不被调用 ⇒ 新枪停在
	#   `_equip_index` 从恢复前条目取的那个**有限旧值**。**改动前**(条目写回在前)那一跑给的是
	#   **满弹** ⇒ 这是换序引入的**真行为差**,不是"够不到的边角"。
	# ★ 可达性(照实,与评审的推演一致):生产里要同时满足"`widx >= 0 且 wlive == -1`"(= 幽灵态
	#   `_current_index >= 0 && _weapon == null`,由 `world_rewind.gd:93` 的 `wlive: -1` 初值暴露)
	#   与"该槽条目停在 `MAG_FULL`"(`set_initial_inventory` 就是拿 `MAG_FULL` 建的条目,
	#   切枪/丢弃才写回实弹值)。★ 本探针**直喂快照** ⇒ 不需要真造出幽灵态就能钉住**消费端契约**
	#   (消费端只看得见字典);"生产里那一态可不可达"是另一件事,不靠这条断言。
	# ★ 判据写成"== `mag_size`"而不是写死 30:钉的是**语义(满弹)**,不是步枪的数字。
	await _s8_hold_first(wc)
	var live_d := wc.current_weapon()
	_check(wc._current_index == 0 and live_d != null and live_d.is_inside_tree(),
			"S8-D 前置:应从第 0 把(且已入树)出发 —— 实得 index=%d live=%s"
			% [wc._current_index, str(live_d)])
	if live_d == null:
		return
	live_d.mag_ammo = 5
	wc.inventory.held[0]["mag"] = 5
	wc.inventory.held[1]["mag"] = 7     # **恢复前**的条目:有限值、且 != MAG_FULL != 满弹
	_restore(player, _snap(player, 1, [5, -1], -1))
	await _frames(3)
	var rifle_d := wc.current_weapon()
	var want_full := int(rifle_d.mag_size) if rifle_d != null else -99
	_check(rifle_d != null and _live_mag(wc) == want_full,
			("S8-D(I-1): 快照条目 = `MAG_FULL(-1)`(满弹)+ `wlive=-1` ⇒ 新枪必须是**满弹** %d"
			+ "(实得 %d;=7 就是 `_equip_index` 从**恢复前**条目取的旧值 —— 语句序换过来之后,")
			% [want_full, _live_mag(wc)]
			+ "没把条目的 `MAG_FULL` 折成 `mag_size`,于是 `apply_mag` 根本没被调用)")
	_check(int(wc.inventory.held[1]["mag"]) == WeaponInventory.MAG_FULL,
			"S8-D: 同一个条目仍必须是快照原值 MAG_FULL=%d(实得 %d)—— 条目照抄快照,不许被" % [
					WeaponInventory.MAG_FULL, int(wc.inventory.held[1]["mag"])]
			+ "那次切枪的写回或这里的折算改掉)")


# 三个子场景的共用起点:手持第 0 把、且**已入树**。
# ★ 为什么必须"已入树":发现 B 的那条写回自带 `is_inside_tree()` 闸门 —— 未入树时它不跑,
#   B 就复现不出来(而那正是生产常态:切枪时旧枪早就入树了)。
# ★ 四个前置断言(S8-A/B/C/D 各 1 条)**没有专属变异**(评审 M-8 的完整性登记):它们的作用是
#   **防假绿**(前置坏 ⇒ 各自 `return` 早退 ⇒ `_checks != EXPECTED_CHECKS` 条数闸红),
#   而"前置本身能红"已经由 M16 那条(改函数名 ⇒ 前置红 + 条数闸红)的**同一机理**覆盖 ——
#   档 3 要求的"每条**承重**断言各来一次"不含这类防假绿前置。
func _s8_hold_first(wc: WeaponComponent) -> void:
	wc.equip_index(0)
	await _frames(3)


# ── S9 形状:PvP 宿主(server/match/match_host.gd)的武器/战斗段不许再隔着句柄反射 ──
# 为什么要有这一段:单机(`Player.rewind_restore`)那一半由 S6 钉着,而 PvP 是**同一个往返的
# 另一份实现**(`_record_rw_frame` 生产 + `_apply_rw_frame` 写回),两份都得清。
# ★ 判据是**逐条**的(9 条各一个 `_check`),不是数一个总数:总数对"其中一处回退了、别处少了"
#   无牙(逐条才能各自咬住自己的回退)。
# ★★ 覆盖上限(必须落在纸上):本节只挡**这一份源码文本的形状** —— 它证明得了"隔着一层还反射
#   的链归零"、以及 `_apply_rw_frame` 的**语句序**(下面那条 `find` 下标判据),但**证明不了行为对**
#   (PvP 那两段的行为没有被任何 headless 探针驱动:全仓 `grep '_apply_rw_frame'` 只命中生产自己)
#   ⇒ **行为侧(值对不对)归真链路批 A**,见报告。
# ★ 同一条谱系的既有病(G-1 实测):把成员名改成**带后缀的假名**时,`contains` 旧写法照样打 ✓
#   ⇒ 这里一律走 `_has_member_token`(完整成员名 + 边界),与 S6/S7 同款。
# ★★ 2026-10-05 修复轮 1(评审 I-2):上面那 9 条计数 + 反向令牌**对语句序天生无牙** ——
#   把 `_apply_rw_frame` 的 `if switched: wc.equip_index(...)` 整段挪到条目写回**之后**,
#   它们**一条都不红**;而"修 B"修的正是**顺序**。故本节末补 1 条**顺序**判据
#   (`HOST_APPLY_EQUIP_ANCHOR` 的 `find` 下标必须小于 `HOST_APPLY_WRITEBACK_ANCHOR` 的)。
func _s9_host_shape() -> void:
	var code := _code_view(_read(MATCH_HOST_SRC))
	var body_of: Dictionary = {}
	var missing_bodies: Array[String] = []
	for fn in HOST_FUNCS:
		var b := _top_func_body(code, fn)
		body_of[fn] = b
		if b.is_empty():
			missing_bodies.append(fn)
	_check(missing_bodies.is_empty(),
			("S9 前置:三个函数体都要读到(缺 %s)—— 函数改名/挪文件时下面 12 条全是空转"
			% str(missing_bodies))
			+ "(计数为 0 与「没有反射」不可分)")
	if not missing_bodies.is_empty():
		return
	var parts: Array[String] = []
	for fn in HOST_FUNCS:
		parts.append(str(body_of.get(fn, "")))
	var joined := "\n".join(parts)
	# 逐条:隔着 `wc` / `inv` / `slot` / `live` / `combat` 句柄的字符串反射各为 0。
	# 各自会红的形态见每条消息(即"去掉什么它才会红")。
	for pat in HOST_HANDLE_REFLECTION:
		_check(joined.count(pat) == 0,
				"S9: 拿到句柄后不许再反射 `%s`(实得 ×%d)—— 拼错成员名时 get 静默返回 null、"
				% [pat, joined.count(pat)]
				+ "set 静默不写、call 当场报错并**中止整段写回**(连后面的手持实弹一起跳过)")
	# 反向:类型化访问必须**逐名在位** —— 把整段删掉也能让上面 9 条计数为 0(同 S6/S7)。
	# ★ 与 S6 同款的两段判据:①`_has_member_token(stem)`(成员名后面不是标识符字符 ⇒ 后缀拼接
	#   改名不算"还在");②`contains(pat)`(原文形状还在)。**必须**先 `rstrip("()")` 取 stem ——
	#   带 `(` 的模式后面紧跟的是**实参**(标识符字符),直接喂 `_has_member_token` 会**恒假**
	#   (实测踩到:`wc.equip_index(` / `.apply_mag(` / `combat.hp_changed.emit(` 三条假红)。
	var typed_missing: Array[String] = []
	for pat in HOST_TYPED_TOKENS:
		var stem: String = pat.rstrip("()")
		if not (_has_member_token(joined, stem) and joined.contains(pat)):
			typed_missing.append(pat)
	_check(typed_missing.is_empty(),
			"S9: 类型化访问必须逐名在位(缺 %s;后缀拼接改名如 `%s_x` 不算)"
			% [str(typed_missing), typed_missing[0] if not typed_missing.is_empty() else ""]
			+ " —— 全段被删/回退成反射时,上面 9 条计数为 0 是假的")
	# 根句柄处数上界:玩家根**无 class_name** ⇒ 那两层按名取是**唯一允许**的一处,不许改多。
	var root_w := joined.count(HOST_ROOT_WEAPONS_GET)
	var root_c := joined.count(HOST_ROOT_COMBAT_GET)
	_check(root_w <= 2 and root_c <= 2,
			("S9: 玩家根上的按名取组件处数不许增加(get(\"weapons\") %d ≤ 2、get(\"combat\") %d ≤ 2)"
			% [root_w, root_c])
			+ " —— 玩家根没有 class_name,类型化它要动类结构(全局类名 + 打掉两个刻意造的裸宿主桩,"
			+ "R11 明令禁止);这一层是 S9 唯一**保留**的反射")
	# ── ★★ 顺序判据(2026-10-05 修复轮 1,评审 I-2)────────────────────────────────
	# "修 B"= **把切枪排在条目写回之前**(`_equip_index` 会把走掉那把的出膛实弹写回条目,
	# 排在写回之后就冲掉刚恢复的快照值)。上面那些计数/令牌判据对**顺序**完全不可见 ⇒ 单独钉:
	#   `_apply_rw_frame` 体内,`wc.equip_index(` 的 `find` 下标必须 **小于**
	#   `held[i]["mag"] = int(mags[i])`(条目写回那一句)的下标。
	# ★ 会红的形态:把那三行(`var switched … if switched: wc.equip_index(want_idx)`)整段挪到
	#   写回循环之后 ⇒ 本条的 `i_equip > i_write` ⇒ 红(实测变异 **M20**,见 `task-2-mutation-log.txt`)。
	# ★ 为什么用**整条语句**当下标锚(而不是裸成员名):`find` 找的是完整语句,不会被"同名成员在
	#   别处出现"骗过;注释已被 `_code_view` 剥掉 ⇒ 在注释里写锚串不会误伤(M17 负向对照同一机理)。
	# ★ 覆盖上限:本条只保证"**这一份源码文本里**切枪语句在下标上早于条目写回那一句" ——
	#   它**不**保证运行时真走了这条顺序(例:有人把切枪改成一个 `call_deferred` 排到帧末,
	#   下标仍在前、顺序已变)。那种退化只有**行为**断言能咬;PvP 的行为侧今天为零 ⇒ 归批 A。
	var apply_body: String = body_of.get("_apply_rw_frame", "")
	var i_equip := apply_body.find(HOST_APPLY_EQUIP_ANCHOR)
	var i_write := apply_body.find(HOST_APPLY_WRITEBACK_ANCHOR)
	_check(i_equip >= 0 and i_write >= 0 and i_equip < i_write,
			("S9: `_apply_rw_frame` 里切枪必须排在**条目写回之前**(修 B 的语句序);"
			+ "实得 `%s`@%d、`%s`@%d") % [HOST_APPLY_EQUIP_ANCHOR, i_equip,
					HOST_APPLY_WRITEBACK_ANCHOR, i_write]
			+ " —— 顺序反了就会被走掉那把的出膛实弹冲掉刚恢复的快照值(发现 B)")


# ── S10 T10:`pvp_haste_mult` 那族的**参数注入化**(2026-10-05 closeout 批 Task 3)────────
# 反射家族最后一片:三处读原先各走 `get("pvp_haste_mult")`(宿主 `player` 根**没有 `class_name`**,
# 给它上类型要动类结构 —— R11 明令禁止,实测会打掉两个**刻意造裸**的测试桩)。改法 = 由**根**把
# 倍率推给消费点;形状按"宿主引用什么时候给入"分两种:
#   · 游泳 = **调用参数**(`swim.update` 每次调用都拿到宿主,顺手把倍率一起给)
#   · 攀爬 / 武器 = **注入成员**(宿主引用只在 `_ready` / `equip` 给一次 ⇒ 倍率必须**每帧推**)
# ★★ 为什么形状判据走**全仓**(不是只看那三个文件):本任务的目标是"这一族的反射在承重面清零" ——
#   只看三个文件的话,"反射搬到第四个文件"会静默过关。
# ★ 这一节**不覆盖**(照实):`player` 根那一处自己的读(`player.gd:191`)与两个**类型化**的
#   服务端站点(match_host 写 / match_snapshot 读)—— 它们本来就无反射,本相只钉"还在、没被删"。
func _s10_shape() -> void:
	var player_src := _code_view(_read(PLAYER_SRC))
	var swim_src := _code_view(_read(SWIM_SRC))
	var climb_src := _code_view(_read(CLIMB_SRC))
	var wbase_src := _code_view(_read(WBASE_SRC))
	var client_src := _code_view(_read(PVPCLIENT_SRC))
	var host_src := _code_view(_read(MATCH_HOST_SRC))
	var snap_src := _code_view(_read(MATCH_SNAPSHOT_SRC))
	var missing: Array[String] = []
	for pair in [[PLAYER_SRC, player_src], [SWIM_SRC, swim_src], [CLIMB_SRC, climb_src],
			[WBASE_SRC, wbase_src], [PVPCLIENT_SRC, client_src], [MATCH_HOST_SRC, host_src],
			[MATCH_SNAPSHOT_SRC, snap_src]]:
		if str(pair[1]).is_empty():
			missing.append(str(pair[0]))
	_check(missing.is_empty(),
			"S10 前置:7 份源都要读到(缺 %s)—— 读不到时下面的否定断言恒真" % str(missing))
	if not missing.is_empty():
		return
	# ① 全仓:那一族的**字符串反射形态**必须为 0(含 `"pvp_haste_mult" in player` 那种存在性探测)。
	var files := _collect(PROD_ROOTS)
	var scanned := 0
	var offenders: Array[String] = []
	for f in files:
		if not f.ends_with(".gd"):
			continue
		scanned += 1
		var body := _code_view(_read(f))
		for pat in HASTE_REFLECTION_FORMS:
			if body.contains(pat):
				offenders.append("%s 里的 `%s`" % [f, pat])
	_check(scanned > 50 and offenders.is_empty(),
			"S10: 产品代码(%d 个 .gd)里 `pvp_haste_mult` 不许再有字符串反射形态 —— 实得 %s"
			% [scanned, str(offenders)]
			+ "(改前实测 3 处 `.get(\"pvp_haste_mult\")`:游泳 / 攀爬 / 武器出弹)")
	# ② 类型化站点**逐个在位** —— 否则"把整段删掉"也能让上面那条为 0(同 S6/S7 的反向纪律)。
	#    四个站点是**四条独立的弧**(属主自读 / PvP 客户端写 / 服务端权威写 / 快照读),
	#    清掉哪一条都该有人红 —— 尤其**服务端那一写**(R4):它变死代码时单机与探针全绿。
	_check(player_src.contains("var pvp_haste_mult") and player_src.contains("else pvp_haste_mult"),
			"S10: 属主 player.gd 必须仍持有 `pvp_haste_mult` 并在自己那条判据里读它(`player.gd:191`)")
	_check(client_src.contains("_local.pvp_haste_mult = "),
			"S10: PvP 客户端那一处**写**(`pvp_match_client.gd:215`)必须换成对 `_local` 的类型化写")
	_check(host_src.contains("p.pvp_haste_mult = "),
			"S10(权威侧 R4): 服务端那一写(`match_host.gd:223`)必须原样在位 —— 它是权威生产者,"
			+ "不是反射;它变死代码时整个 headless 面全绿、只有真链路才现形")
	_check(snap_src.contains("p.pvp_haste_mult > 1.0"),
			"S10: 快照那一处类型化**读**(`match_snapshot.gd:30`)必须原样在位")
	# ③ 三处消费点的注入弧**真的接上**(不是"加个参数然后函数体不用它")。
	var swim_update := _top_func_body(swim_src, "update")
	var swim_uses := _count_member_tokens(swim_update, "haste_mult")
	_check(swim_uses >= 2,
			"S10: `swim.update` 的 `haste_mult` 必须**被函数体用到**(实得完整成员名出现 %d 次;"
			% swim_uses + "=1 就是只写在签名上 —— 那是最典型的『加了参数但没接线』;"
			+ "★ 判据走 `_count_member_tokens`(两侧边界):用 `count()` 会被反射串"
			+ "`pvp_haste_mult` 里的子串骗过 —— 变异 M1 实测)")
	_check(player_src.contains("swim.update(self, delta, mult, input_source, tm)"),
			"S10: 根必须把本帧倍率 `tm` 当第 5 个实参传给 `swim.update`")
	var climb_time := _top_func_body(climb_src, "_time_mult")
	var climb_uses := _count_member_tokens(climb_time, "haste_mult")
	_check(climb_src.contains("var haste_mult") and climb_uses >= 1,
			"S10: `climb_component.gd` 要有注入成员 `haste_mult`,且 `_time_mult()` **读的是它**"
			+ "(实得完整成员名出现 %d 次;★ 两侧边界 —— 反射串 `pvp_haste_mult` 不算)" % climb_uses)
	_check(player_src.contains("climb.haste_mult = "),
			"S10: 根必须每物理帧把倍率推给攀爬组件(`climb.haste_mult = tm`)")
	var spawn_body := _top_func_body(wbase_src, "_spawn_projectiles")
	var wbase_uses := _count_member_tokens(spawn_body, "haste_mult")
	_check(wbase_src.contains("var haste_mult") and wbase_uses >= 1,
			"S10: `weapon_base.gd` 要有注入成员 `haste_mult`,且出弹段读的是它(实得完整成员名"
			+ "出现 %d 次;★ 两侧边界 —— 反射串 `pvp_haste_mult` 不算)" % wbase_uses)
	_check(player_src.contains("cur_w.haste_mult = "),
			"S10: 根必须每物理帧把倍率推给**当前那把枪**(推送点见 player.gd 的 `_push_haste_mult`)")


# S10 行为:倍率**真的**到达三个消费点。★ 与形状断言互补 —— 形状只证明"反射没了、注入成员在",
# 它证不了"值真的走得通"。本相用**同一个写法**改 `pvp_haste_mult`(与 `match_host.gd:223` 逐字同款),
# 再看三个消费点的物理量是否随倍率变 —— 即 R4 要的"权威侧那条路也有一条"。
# ★ 前置(必须在最前):本探针只加载 `player.tscn`、不建 Level0 ⇒ `TimeField.current == null`
#   ⇒ 才会走 `pvp_haste_mult` 那一支;否则单机走 TimeField,本相测不到任何东西。
# ★ 这里**把玩家物理开回来**(S1-S9 全程关着),让**引擎自己**调 `_physics_process` —— 直接手调
#   那个虚函数能不能落到脚本实现上取决于引擎的虚方法派发,不值得赌;开着循环是仓内既有做法
#   (haste_probe 同款),帧数由"等几个 physics_frame"确定,不吃时序抽奖。
func _s10_behavior(player: Node, wc: WeaponComponent) -> void:
	_check(TimeField.current == null,
			"S10 前置:本探针里 `TimeField.current` 必须是 null(实得 %s)⇒ 才会走 `pvp_haste_mult` 那支"
			% str(TimeField.current))
	var grid_save: Array[Array] = MazeGenerator.current_grid
	# ★ 必须显式载入瓦片定义:`-s` 探针才自己调它,场景探针里没人调 ⇒ `is_liquid(21)` /
	#   `climb_speed(11)` 全返回 0 ⇒ 水格与梯格都判不出来,本相会**静默**退化成"陆上那一支"
	#   (第一次跑实测就是这么红的:`in_water=false`、攀爬压根没进分支)。
	TileDefs.load_defs()
	player.set_physics_process(true)
	# ① 游泳:合成**上空气 + 下水**的网格(形状说明见 `_water_band_grid()` —— 全水网格会**卡死**)
	MazeGenerator.current_grid = _water_band_grid()
	Input.action_press("right")
	var v1 := await _swim_vx(player, 1.0)
	var in_water_seen := bool(player.swim.in_water)
	var v2 := await _swim_vx(player, 2.0)
	Input.action_release("right")
	_check(in_water_seen and absf(v1) > 100.0,
			("S10 游泳前置:必须真的在水里游(实得 in_water=%s、vx=%.1f)"
			% [str(in_water_seen), v1])
			+ " —— 不在水里时水平速度由**根自己**算(`_tick_horizontal`),下面那条就测不到游泳组件")
	_check(absf(v2 - v1 * 2.0) <= maxf(1.0, absf(v1) * 0.01),
			("S10: 倍率必须**真的**到达游泳消费点(1× → %.1f px/s、2× → %.1f px/s,比 %.4f 期望 2.0)"
			% [v1, v2, (v2 / v1) if absf(v1) > 0.001 else -1.0])
			+ " —— 红在哪条:去掉『根部把 tm 传给 swim.update』这半条弧,两跑同值 ⇒ 比 ≈1")
	# ② 攀爬:合成**全梯**网格 + 按住上。`_latched` 直接置真 —— 本相测的是**倍率**,
	#    抓附边沿(`is_action_just_pressed("up")`)另有守卫(player_contract_smoke 的缺 src 相)。
	MazeGenerator.current_grid = _fill_grid(MazeGenerator.pack(11, 15), 12, 12)
	Input.action_press("up")
	var c1 := await _climb_vy(player, 1.0)
	var c2 := await _climb_vy(player, 2.0)
	Input.action_release("up")
	MazeGenerator.current_grid = grid_save
	_check(c1 < -50.0,
			("S10 攀爬前置:梯格 + 注入 src + 按上 ⇒ 必须上爬(实得 velocity.y=%.1f)" % c1)
			+ " —— 不是负数说明这一相压根没进攀爬分支,下面那条恒真")
	_check(absf(c2 - c1 * 2.0) <= maxf(1.0, absf(c1) * 0.01),
			("S10: 倍率必须**真的**到达攀爬消费点(1× → vy=%.1f、2× → vy=%.1f,比 %.4f 期望 2.0)"
			% [c1, c2, (c2 / c1) if absf(c1) > 0.001 else -1.0])
			+ " —— 红在哪条:去掉『根部推 climb.haste_mult』,`_time_mult()` 恒读默认 1.0 ⇒ 比 =1")
	# ③ 武器:出膛弹速 = `bullet_speed × 倍率`(用户裁定"射手加速 ⇒ 子弹也加速")。
	# ★ 前置只要"单弹丸":**散布不影响速率**(`setup` 里是 `dir.normalized() * spd`),故不卡 spread。
	var w := wc.current_weapon()
	_check(w != null and w.pellet_count == 1,
			("S10 武器前置:要一把单弹丸的枪(实得 w=%s pellet=%s)"
			% [str(w), str(w.pellet_count if w != null else -1)])
			+ " —— 多弹丸时下面的『新弹』取法会撞上同帧的其它弹")
	if w != null:
		var want := float(w.bullet_speed)
		player.pvp_haste_mult = 1.0
		await _phys_steps(2)
		var s1 := _spawn_one_bullet(w)
		player.pvp_haste_mult = 2.0
		await _phys_steps(2)
		var s2 := _spawn_one_bullet(w)
		_check(absf(s1 - want) <= 0.01,
				"S10 武器:倍率 1 时的出膛弹速应 = bullet_speed %.1f(实得 %.1f)" % [want, s1])
		_check(absf(s2 - want * 2.0) <= 0.01,
				("S10: 倍率 2 时的出膛弹速应 = bullet_speed×2 = %.1f(实得 %.1f)" % [want * 2.0, s2])
				+ " —— 红在哪条:去掉『根部推 cur_w.haste_mult』,枪停在默认 1.0 ⇒ 实得 == bullet_speed")
	# ④ 权威侧(R4):**服务端那种写法**改字段(`p.pvp_haste_mult = …`,与 match_host.gd:223 逐字同款)
	#   必须继续到达消费点。这里看**根自己**那一处消费(`player.gd:191` → `_speed_mult`)——
	#    它是权威侧速度域的入口,也是本任务**刻意不动**的那一处(它本来就是类型化读)。
	player.pvp_haste_mult = 3.0
	await _phys_steps(2)
	var seen := float(player._speed_mult)
	_check(absf(seen - 3.0) <= 1e-6,
			("S10(权威侧 R4): 服务端写法(`player.pvp_haste_mult = 3.0`)必须到达消费点;"
			+ "实得根的速度域 `_speed_mult`=%.3f 期望 3.0") % seen)
	player.pvp_haste_mult = 1.0
	await _phys_steps(2)
	player.set_physics_process(false)


# 等 n 个物理步**真正跑完**。★ 为什么不是裸 `await physics_frame`:`SceneTree.physics_frame`
# 在物理步**开始**时发出 ⇒ 协程在节点 `_physics_process` **之前**就恢复 ⇒ 想读到"这一帧处理过
# 之后"的值必须多等一拍(实测踩到:武器那条读到了**上一帧**推的倍率)。
func _phys_steps(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


# 游泳那一相的水格起点(第 12 行正中;第 12 行是该网格的**第一行水**)。
const SWIM_START := Vector2(6.0 * 64.0 + 32.0, 12.0 * 64.0 + 32.0)


# 等若干物理帧后返回水中水平速度。★ 为什么 40 帧就够、而且**不需要**等平台期:水里的水平速度
# 是指数缓动逼近 `player_swim_speed × tm`(见 `MathUtil.approach`),两条曲线**同一时刻**
# 恰好成 2 倍(同一个残留系数)⇒ 比值与跑多少帧无关;40 帧只为让绝对值过得了下面那条前置。
# ★ 两跑都从**同一个**起点出发(否则两次测量的几何不同,可比性靠运气)。
const SWIM_FRAMES := 40


func _swim_vx(player: Node, haste: float) -> float:
	player.pvp_haste_mult = haste
	(player as Node2D).global_position = SWIM_START
	(player as Node2D).velocity = Vector2.ZERO
	await _phys_steps(SWIM_FRAMES)
	return (player as Node2D).velocity.x


# 合成网格:**上 12 行空气 + 下 20 行水**(共 32 行)。
# ★★ 为什么**不能**图省事用"全水"网格(实测踩到,不是假想):`Water.surface_y_at` 从当前格向
#   **上**扫连续液格(`posmod` 回绕,见 water.gd:36-43)⇒ 一整列全是水时**永远扫不到顶** ⇒
#   无限循环 ⇒ 整个主循环卡死(探针挂到外层 timeout,日志里连一行错误都没有 —— 那种"没有错误
#   的挂起"最难查)。真实地图上方必有空气,故本形状才是**与生产同形**的那个。
# ★ 水深 20 行(=1280px)是给"测量期间下沉"留的余量:40 帧内下沉最多 640×0.67≈427px。
func _water_band_grid() -> Array[Array]:
	var g: Array[Array] = []
	for y in 32:
		var row: Array[int] = []
		for _x in 12:
			row.append(MazeGenerator.EMPTY if y < 12 else MazeGenerator.pack(21, 15))
		g.append(row)
	return g


# 等两个物理步后返回攀爬的 vertical velocity(攀爬每帧直接写 `body.velocity.y`,无缓动;
# 第一拍让 `_physics_process` 真跑一次,第二拍读值 —— 理由见 `_phys_steps`)。
func _climb_vy(player: Node, haste: float) -> float:
	player.pvp_haste_mult = haste
	player.climb._latched = true   # 抓附态直置:本相测倍率,不测抓附边沿(见上面注释)
	await _phys_steps(2)
	return (player as Node2D).velocity.y


# 出膛**一颗**弹并返回它的速率。用"前后实例 id 差集"取新弹(不比 group 里第一颗 —— 前面几相
# 可能已经留下活弹),再读 `velocity_vec.length()`(= `setup()` 里写进去的 `speed`)。
func _spawn_one_bullet(w: WeaponBase) -> float:
	var before := {}
	for n in get_tree().get_nodes_in_group("bullet"):
		before[n.get_instance_id()] = true
	w._spawn_projectiles(Vector2.RIGHT)
	for n in get_tree().get_nodes_in_group("bullet"):
		if before.has(n.get_instance_id()):
			continue
		var b := n as BulletBase
		if b != null:
			return b.velocity_vec.length()
	return -1.0


func _fill_grid(v: int, cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for _y in rows:
		var row: Array[int] = []
		for _x in cols:
			row.append(v)
		g.append(row)
	return g


# ── S11 T11:`pvp_match_client.gd` 那 7 处对象反射(2026-10-05 closeout 批 Task 3)──────────
# 那 7 处**全打在 `_local`(Node2D)上**,而**不需要 `class_name`** 也能点访问 —— 先例就在同文件
# (`:134` `_local.weapons.set_enabled_types(...)`)。
# ★ 逐成员一条(不是数一个总数):总数对"其中一处回退了、别处少了"无牙(本仓 Task 13 的 G-1 实测)。
# ★★ `:234`/`:240` 的 `input_source` **不许**换成"注入源":同一个函数会把**同一个** `src.frozen = true`
#   —— 冻结的若不是一个对象,解冻就落不到玩家真读的那个源上 ⇒ **死锁**(债单 §六.7)⇒ 本相要求
#   它仍然**读宿主自己的** `input_source`(下面 count == 2 那条就是钉这个的)。
# ★ 覆盖上限:**行为侧为零** —— 这三段只在真 PvP 对局里跑(全仓 `grep` 只命中真链路),headless
#   探针够不到"按住加速键 ⇒ `_local.pvp_haste_mult` 被写成 3.0"这条端到端 ⇒ **归真链路批 A**。
func _s11_client_shape() -> void:
	var src := _code_view(_read(PVPCLIENT_SRC))
	_check(not src.is_empty(),
			"S11 前置:读到了 pvp_match_client.gd(读不到 ⇒ 下面全是否定断言、恒真)")
	if src.is_empty():
		return
	var parts: Array[String] = []
	for fn in PVP_TIME_FUNCS:
		parts.append(_top_func_body(src, fn))
	var joined := "\n".join(parts)
	_check(not joined.strip_edges().is_empty(),
			"S11 前置:三个函数体都要读到(%s)—— 改名/挪走时下面全是空转" % str(PVP_TIME_FUNCS))
	if joined.strip_edges().is_empty():
		return
	# ① 逐条:那 7 处的**反射形态**为 0(每条独立 ⇒ 各自咬住自己的改名/回退)。
	#    ★ 剥注释后判:讲这几条病的新注释里写着反射字形,不剥会把自己喂红。
	for pat in [".set(\"pvp_haste_mult\"", ".call(\"is_downed\"", "has_method(\"is_downed\"",
			".get(\"input_source\"", ".set(\"frozen\"", ".get(\"animator\")"]:
		_check(not joined.contains(pat),
				"S11: 加速/回溯/视效三段里不许再有对象反射 `%s`(实得 ×%d)—— 拼错成员名时 get 静默"
				% [pat, joined.count(pat)] + "返回 null、set 静默不写、call 当场报错并中止本段")
	# ② 反向:类型化形态必须**逐个在位**(把整段删掉也能让上面 6 条为 0 —— 同 S6/S7 的纪律)。
	#    ★ `input_source` 那一条**必须是 2 次**(进/出各读一次宿主自己的源):改成注入源、或只改一处
	#      ⇒ 红。这是 §六.7 死锁那一条的**形状**守卫。
	var typed_missing: Array[String] = []
	if not joined.contains("_local.pvp_haste_mult = "):
		typed_missing.append("_local.pvp_haste_mult = ")
	if not (joined.contains("_local.is_downed()") and not joined.contains("_local.has_method")):
		typed_missing.append("_local.is_downed()")
	var src_reads := joined.count("_local.input_source")
	if src_reads != 2:
		typed_missing.append("_local.input_source ×2(实得 %d)" % src_reads)
	if not (joined.contains("src.frozen = true") and joined.contains("src2.frozen = false")):
		typed_missing.append("src.frozen / src2.frozen")
	if not joined.contains("_local.animator"):
		typed_missing.append("_local.animator")
	_check(typed_missing.is_empty(),
			"S11: 那 7 处的**类型化**形态必须逐个在位(缺 %s)" % str(typed_missing)
			+ " —— 全段被删/退回反射时,上面 6 条计数为 0 是假的")
	# ③ 聚合:这三段里**任何**对象反射都不该留(`.set(` / `.call(` / `has_method(` / `_local.get(`)。
	#    为什么这里能按 0 钉:本文件那些**合法**的字典取键(`own.get(` / `payload.get(` …)不在本三段。
	var agg := joined.count(".set(\"") + joined.count(".call(\"") \
			+ joined.count("has_method(\"") + joined.count("_local.get(\"")
	_check(agg == 0,
			"S11: 加速/回溯/视效三段里不许再有任何对象反射(实得 ×%d;含新长出来的)" % agg)


# ── S12 T12:`world_rewind.gd` 敌人/子弹快照段的同族反射(2026-10-05 closeout 批 Task 3)──────
# `record()` 的敌人段与子弹段此前走 `.get("velocity")` / `.call("rewind_state")` / `.get("hit_damage")`…
# 同族:**拼错成员名不报错**(`get` 返回 null、`call` 静默什么都不做)⇒ 快照静默退化。
# ★ 可类型化的依据:`scenes/enemies/enemy_base.gd:1` **已有 `class_name EnemyBase`**,
#   `scenes/weapons/bullet_base.gd:1` **已有 `class_name BulletBase`** ⇒ **未动类结构**。
# ★ 形状与行为互补:这里只证明"反射没了、类型化写法在位";值对不对由 `_s12_behavior` 逐字段钉。
func _s12_shape() -> void:
	var src := _code_view(_read(WREWIND_SRC))
	_check(not src.is_empty(),
			"S12 前置:读到了 core/sim/world_rewind.gd(读不到 ⇒ 下面全是空转)")
	if src.is_empty():
		return
	var rec := _top_func_body(src, "record")
	var ap := _top_func_body(src, "_apply")
	var apb := _top_func_body(src, "_apply_bullets")
	var missing_bodies: Array[String] = []
	if rec.is_empty():
		missing_bodies.append("record")
	if ap.is_empty():
		missing_bodies.append("_apply")
	if apb.is_empty():
		missing_bodies.append("_apply_bullets")
	_check(missing_bodies.is_empty(),
			"S12 前置:三个函数体都要读到(缺 %s)—— 改名/挪走时下面全是空转" % str(missing_bodies))
	if not missing_bodies.is_empty():
		return
	# ① 逐条:快照段那 8 处对象反射各为 0。
	for pat in RW_RECORD_REFLECTION:
		_check(not rec.contains(pat),
				"S12: record() 的敌人/子弹快照段不许再有对象反射 `%s`(实得 ×%d)—— `get` 拼错成员名"
				% [pat, rec.count(pat)] + "**静默返回 null**,快照值随之静默退化(整帧退化成空字典那次"
				+ "事故的同族,见 world_rewind.gd 的注释)")
	# ② 回放侧(`_apply` + `_apply_bullets`)的同族反射归零(合并成一条:逐个点名实得者)。
	var apply_offenders: Array[String] = []
	for pat in RW_APPLY_REFLECTION:
		if ap.contains(pat) or apb.contains(pat):
			apply_offenders.append("%s×%d" % [pat, ap.count(pat) + apb.count(pat)])
	_check(apply_offenders.is_empty(),
			"S12: `_apply`/`_apply_bullets` 不许再隔着字符串碰敌人/子弹(实得 %s)" % str(apply_offenders)
			+ " —— `call(\"apply_rewind_state\")` 那种写法在方法改名时**当场报错并中止整段回放**")
	# ③ 反向:类型化访问**逐名在位**(用 `_has_member_token`:后缀拼接改名如 `velocity_x` 不算"还在")。
	var typed_missing: Array[String] = []
	for stem in ["e.global_position", "e.velocity", "e.hp", "e.is_dead", "e.visible",
			"b.global_position", "b.shooter", "b.velocity_vec", "b.hit_damage", "b.hit_impact"]:
		if not _has_member_token(rec, stem):
			typed_missing.append(stem)
	if not rec.contains("b.rewind_state()"):
		typed_missing.append("b.rewind_state()")
	_check(typed_missing.is_empty(),
			"S12: record() 的敌人/子弹段必须**逐名**换成类型化访问(缺 %s)" % str(typed_missing)
			+ " —— 整段被删/回退成反射时,上面 8 条为 0 是假的")
	var apply_typed_missing: Array[String] = []
	for pat in RW_APPLY_TYPED:
		if not (ap.contains(pat) or apb.contains(pat)):
			apply_typed_missing.append(pat)
	_check(apply_typed_missing.is_empty(),
			"S12: `_apply`/`_apply_bullets` 的类型化写法必须逐名在位(缺 %s)" % str(apply_typed_missing)
			+ " —— 否则上面那条『一个都没实得』与『全删了』不可分")


# S12 行为:快照字典**逐字段 == 真值**。★ 为什么用**互不相同的非 0 值**(123/456、77/-33、hp 7、
# dmg 5、impact 3.5、tr 33、mr 444):全 0 或全同值时"读错了"与"读对了"在断言上不可分(恒绿)。
# ★ `dead` / `from_player` 两相都测:只测一相时"恒 false / 恒 true"照样能过。
# ★ 直调**生产函数** `record()`,并用**真** EnemyBase / BulletBase 标本(与生产同一个类)。
func _s12_behavior(player: Node) -> void:
	MazeGenerator.current_grid = _fill_grid(MazeGenerator.EMPTY, 12, 12)
	var enemy: Node = (load(ENEMY_SCENE) as PackedScene).instantiate()
	var bullet: Node = (load(BULLET_SCENE) as PackedScene).instantiate()
	_check(enemy is EnemyBase and bullet is BulletBase,
			"S12 前置:两个标本必须是 EnemyBase / BulletBase(实得 %s / %s)"
			% [str(enemy.get_script()), str(bullet.get_script())])
	if not (enemy is EnemyBase and bullet is BulletBase):
		return
	add_child(enemy)
	add_child(bullet)
	enemy.set_physics_process(false)   # 标本要是活的,会把下面写死的值改掉 ⇒ 采样不可复现
	bullet.set_physics_process(false)
	var e := enemy as EnemyBase
	var b := bullet as BulletBase
	e.global_position = Vector2(123.0, 456.0)
	e.velocity = Vector2(77.0, -33.0)
	e.hp = 7
	e.is_dead = false
	e.visible = false
	b.global_position = Vector2(321.0, 654.0)
	b.velocity_vec = Vector2(11.0, 22.0)
	b.hit_damage = 5
	b.hit_impact = 3.5
	b.traveled = 33.0
	b.max_range = 444.0
	b.gravity_factor = 0.5
	b.speed = 22.0
	b.size = 1.5
	b.bullet_color = Color(0.1, 0.2, 0.3)
	b.shooter = player
	b.set_meta("scene_path", BULLET_SCENE)
	var rw := WorldRewind.new(null)
	rw.record(0.06, player, [e], [b])
	_check(rw.frame_count() == 1,
			"S12 前置:应落下一帧快照(实得 %d;0 ⇒ 下面的读取全是空转)" % rw.frame_count())
	if rw.frame_count() != 1:
		return
	var frame: Dictionary = rw._frames[0]
	var pe: Array = frame["enemies"]
	var pb: Array = frame["bullets"]
	_check(pe.size() == 1 and pb.size() == 1,
			"S12 前置:快照里应各有一件(实得 敌 %d / 弹 %d)" % [pe.size(), pb.size()])
	if pe.size() != 1 or pb.size() != 1:
		return
	var es: Dictionary = pe[0]
	var bs: Dictionary = pb[0]
	_check(es["p"] == e.global_position,
			"S12: 敌人快照位置 = 真值(实得 %s 期望 %s)" % [str(es["p"]), str(e.global_position)])
	_check(es["v"] == e.velocity,
			"S12: 敌人快照速度 = 真值(实得 %s 期望 %s)" % [str(es["v"]), str(e.velocity)])
	_check(int(es["hp"]) == 7,
			"S12: 敌人快照 hp = 真值 7(实得 %d;`get(\"hp\")` 拼错 ⇒ int(null) 当场报错、整帧不入快照)"
			% int(es["hp"]))
	_check(bool(es["vis"]) == false,
			"S12: 敌人快照 vis = 真值 false(实得 %s)" % str(es["vis"]))
	# `dead` 两相:恒 false 骗过第一相、恒 true 骗过第二相 ⇒ 两相一起才代表"有取值来源"。
	e.is_dead = true
	rw.record(0.06, player, [e], [b])
	var es2: Dictionary = rw._frames[rw.frame_count() - 1]["enemies"][0]
	_check(bool(es["dead"]) == false and bool(es2["dead"]) == true,
			("S12: 敌人快照 dead 必须 == 真值(活着相 实得 %s、`is_dead=true` 相 实得 %s)"
			% [str(es["dead"]), str(es2["dead"])])
			+ " —— 写死成常量、或 `get(\"is_dead\")` 的成员名对不上(恒 false)都是这条要咬的")
	_check(str(bs["sp"]) == BULLET_SCENE,
			"S12: 子弹快照 sp = 弹身上那份 `scene_path` meta(实得 `%s`)" % str(bs["sp"]))
	_check(bs["p"] == b.global_position,
			"S12: 子弹快照位置 = 真值(实得 %s 期望 %s)" % [str(bs["p"]), str(b.global_position)])
	_check(bs["v"] == b.velocity_vec,
			"S12: 子弹快照速度 = 真值(实得 %s 期望 %s)" % [str(bs["v"]), str(b.velocity_vec)])
	_check(int(bs["dmg"]) == 5 and absf(float(bs["impact"]) - 3.5) <= 1e-6,
			"S12: 子弹快照 dmg/impact = 真值 5 / 3.5(实得 %d / %.3f)"
			% [int(bs["dmg"]), float(bs["impact"])])
	var fuse: Dictionary = bs["fuse"]
	_check(not fuse.is_empty() and fuse == b.rewind_state(),
			"S12: 子弹快照 fuse 必须 = `rewind_state()` 的真值(实得 %s;/空字典 ⇒ 重建的榴弹退回未点燃)"
			% str(fuse))
	_check(absf(float(fuse.get("mr", -1.0)) - 444.0) <= 1e-6
			and absf(float(fuse.get("tr", -1.0)) - 33.0) <= 1e-6,
			"S12: fuse 里的 max_range/traveled = 真值 444 / 33(实得 %s / %s)"
			% [str(fuse.get("mr")), str(fuse.get("tr"))])
	# `from_player` 两相:它由射手是否在 `player` 组算出 —— 写死成常量会被两相一起咬住。
	b.shooter = null
	rw.record(0.06, player, [e], [b])
	var bs2: Dictionary = rw._frames[rw.frame_count() - 1]["bullets"][0]
	_check(bool(bs["from_player"]) and not bool(bs2["from_player"]),
			("S12: 子弹快照 from_player 必须跟着射手组走(射手=玩家相 实得 %s、射手=null 相 实得 %s)"
			% [str(bs["from_player"]), str(bs2["from_player"])])
			+ " —— 恒 true / 恒 false 各能骗过一相")
