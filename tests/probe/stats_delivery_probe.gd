extends Node

# 三个模式的逐人统计**写入与投递**守卫。
# 注意： 2026-09-26(终审 重要 1):3v3 的那一半原先只是 `tests/probe/team_host_probe` ⑬g 的**三条
#   `contains` 文本断言**,本文件那句"(3v3 的那一半在 team_host_probe ⑬g)"把**两种强度不同**
#   的守卫说成了等价 —— 而本文件头注自己刚宣布那种强度是已知测试漏检(F1)。实测:把
#   `TeamHost._broadcast_round_state` 的 `_rpc_all("round_state", [data])` 提到挂载
#   `stats`/`mvp` 之前  ->  `TEAM HOST: ALL-OK`(175 ok)/`STATS DELIVERY: ALL-OK`(34 ok)/
#   `KH HUD PROBE: ALL-OK` **三条测试全部通过**,而 3v3 客户端收到的是**两个键都没有**的终局帧
#   (结算页两节皆空、没有 MVP 星)。现在 3v3 走 **⑥**,与 1v1/大乱斗相同机制(截获式);`team_host_probe`
#   ⑬g 那三条文本断言已**删除**(该段只剩"载荷形状与数值"那一半,见那段注释)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/stats_delivery_probe.tscn
# 判据: 文本 `STATS DELIVERY: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ═══ 为什么需要它 ═══
# "数值"那一半**实际创建宿主实例**、走生产倒地边沿后读逐人表;"投递"那一半(⑤)则把**真正要发出去的
# `round_state` 字典**截获下来 —— 覆写 `_rpc_all`(见 `RpcPayload` 的注释)。
# - 两半缺一不可:只断数值  ->  键没挂上去(客户端永远收不到)照样测试全部通过;只断投递  ->  数值算错也测试全部通过。
#
# 注意： 本文件 2026-09-26 修掉一处**判据强度**缺陷(F1):旧版的"投递"三问是
#    `函数体里含不含 data["stats"]` 这类**次序无关的文本共现**,于是把
#    `_rpc_all("round_state", [data])` 提到挂载 `stats`/`mvp` **之前**(广播里一个键都不带)
#    三条断言**照样测试全部通过**、verdict 与基线逐字相同  ->  唯一的"投递"守卫在最该红的地方是绿的。
#    旧头注里那句「探针手里没有 peer  ->  投递那一半**只能**源码级」**不成立**:`_rpc_all` 是
#    可覆写的普通方法(不是引擎虚函数),覆写它就能在封包那一刻拿到载荷。**别改回去。**
#    - 仍然保留的**源码级**守卫只剩两条(见 ③/④ 的注释):它们问的是**路由/来源**,不是
#      "文本在不在" —— 那一类(以及 `mvp`、"只在非空时带键")现在**一律行为面**。
#
# 注意： 同日再修一处**判据强度**缺陷(F2,评审 Critical):③ 的旧夹具(受害者 role 3 / 归因射手
#    role 1)里,大乱斗的正确口径(`_record_down(role, _attributed_killer(p))`)与 1v1 的错形状
#    (`_record_down(role, _opponent_of(role))`)在那一格**算出同一个 role**(都是 1) ->  把生产那行
#    换成错形状,③ **测试全部通过**、verdict 与基线逐字相同(实测 31 ok / 0 FAIL / `ALL-OK`)。
#     ->  代码里那句"别照抄 1v1 那一份"的**注释不是守卫**。现在 ③ 把归因目标改成 role 2(两个实现
#      给出**不同**答案 + 一条夹具自检钉住这个鉴别前提),并补上大乱斗这条链上的**无归因**档。
#    详见 ③ 段的注释。
#
# - 宿主构造走本仓既有手法(`match_host_hygiene_probe` / `team_host_probe`):
#   实际创建宿主实例、`role_peers` 传空、玩家手工摆位、显式补调生产的 `_wire_hit_feedback()`。
# - 段数对账(本仓"测试漏检"纪律:`ALL-OK` 只证明"没有断言失败",不证明"该跑的断言都跑过")
#   —— 末尾拿 `_done` 与 `CHECK_NAMES` 对账,名单不全即红。

const MAP := "res://maps/newfactory.cyrm"
# 载荷七个字段的**逐码点升序**(`_keys_of` 走 `Array.sort()`)。
# 注意： `dealt` 排在 `deaths` **之前**,别"顺手纠正"成字母表顺序:Godot 的 `Array.sort()` 对 String
#   走**逐码点**比较(`Variant::operator<` → `String::operator<` → `str_compare`),不是按
#   "dealt < deaths 看着不像"的直觉 —— 第 4 个字符 `l`(0x6C) vs `t`(0x74)  ->  `dealt < deaths`。
#   写成 `[…, deaths, dealt, …]` 会让**生产改对了形状断言照样红**;而错误的修法(放宽成
#   "包含这七个键就行")会把"载荷字段集"这条真契约拆掉 —— 所以这里必须是逐码点升序。
const WANT_KEYS := ["acs", "assists", "dealt", "deaths", "kills", "kscore", "taken"]
const CHECK_NAMES := ["duel_phase", "duel_kill_rule", "duel_bullet_path", "royale_phase",
		"delivery_source", "delivery_payload", "team_phase"]
# ⑦ 两颗子弹用的固定伤害(与 ① 的 7 同值,便于三条 1v1 段互相对照)。
const DUEL_BULLET_DAMAGE := 7

var _fails: Array[String] = []
var _done: Array[String] = []

# - 两个摆位的期望值**取自地图自己的 spawn 元数据**(`MapFormat.load_spawns(MAP)` 的
#   `player` / `player2`),不写死 (17,65)/(133,64)——那是上一版 PvP 图的出生点,本图上
#   早就不在这两格了。本文件只用它们当"两个**相距很远**的点"(各条判据都不依赖具体坐标:
#   子弹夹具把弹摆在受害者身上、0 距离),距离不够远时那条夹具自检会红。
#   - 改写后仍拦得住的变异:夹具与地图脱钩(两个 role 摆到同一格 / 摆进与断言无关的点),
#     —— 旧的写死值在**换图之后**恰恰就是这一档(两点仍分离,但已与地图无关,没人看得见)。
var _p1_cell := Vector2i(-1, -1)
var _p2_cell := Vector2i(-1, -1)


# ═══ 载荷截获(把"投递"那一半从**源码文本**升到**真正要发出去的字典**)═══
#
# - `_rpc_all`(`server/match_state.gd`)是**可覆写**的普通方法,不是引擎虚函数:覆写它就能在
#   "封包那一刻"把 `args[0]` 拿到手 —— 探针手里没有 peer(于是 `_rpc_all` 循环无效操作、一个包都不发)
#   也照样能验投递。`super._rpc_all(...)` 照常跑,故**真实发包路径一字未变**。
#
# 注意： 唯一必须搞对的一处:**在调用时刻取快照**。`_broadcast_round_state` 先建一个 `data` 字典、
#   再**就地**往里补 `match_winner` / `mvp` / `stats`,**最后**才 `_rpc_all("round_state", [data])`;
#   而字典是**引用类型**  ->  覆写里只把 `args[0]` 存下来、事后再读,会看到**之后**才挂上去的键,
#   于是"把 `_rpc_all` 提到挂载之前"那个变异下守卫**照样测试全部通过** —— 正是本次要堵的那个测试漏检。
#   故 `snap()` 在**调用那一刻**就 `duplicate(true)` 一份带走。
class RpcPayload:
	static func snap(args: Array) -> Dictionary:
		if args.is_empty() or not (args[0] is Dictionary):
			return {}
		var d: Dictionary = args[0]
		return {"state": int(d.get("state", -1)), "payload": d.duplicate(true)}


# 1v1 的截获宿主:与生产 `MatchHost` 的唯一差别就是下面这个覆写。
class CapturingDuelHost extends MatchHost:
	var frames: Array = []      # 每次 `round_state` 广播的**调用时刻**快照

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			frames.append(RpcPayload.snap(args))
		super._rpc_all(method, args, except_role, live_only)


# 大乱斗那一份(`RoyaleHost` **整体覆写**了 `_broadcast_round_state`,故要单独截获它那一份)。
class CapturingRoyaleHost extends RoyaleHost:
	var frames: Array = []

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			frames.append(RpcPayload.snap(args))
		super._rpc_all(method, args, except_role, live_only)


# 3v3 那一份(`TeamHost` 同样**整体覆写**了 `_broadcast_round_state`)。
# 注意： 为什么必须有它:`team_host_probe` ⑬g 原先那三条文本断言(`contains('data["stats"]')` 一族)
#   在"把 `_rpc_all` 提到挂载之前"的变异下**三条测试全部通过**(见文件头那段实测读数)—— 那种强度
#   只能证明"源码里出现过这串字",证明不了"真要发出去的字典里有这个键"。形状与上面两份逐字相同机制。
class CapturingTeamHost extends TeamHost:
	var frames: Array = []

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			frames.append(RpcPayload.snap(args))
		super._rpc_all(method, args, except_role, live_only)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# - 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(测试误报)。
func _ready() -> void:
	# - 摆位先派生(见 `_p1_cell` 上方):缺任一个出生点就直接红、走保底处理 (-1,-1) 会让
	#   两个玩家重合在同一个点上,几条断言随之静默变松。
	var sp := MapFormat.load_spawns(MAP)
	_p1_cell = sp.get("player", Vector2i(-1, -1))
	_p2_cell = sp.get("player2", Vector2i(-1, -1))
	_check(_p1_cell.x >= 0 and _p2_cell.x >= 0,
			"地图 %s 同时声明了 `# player` 与 `# player2`(本文件的摆位取自它们)" % MAP)
	await _run()
	_finish()


func _finish() -> void:
	# - 段数对账:每个 `_check_*` 末行都要把自己的名字记进 `_done`;名单不全 = 有一段
	#   中途出错被静默跳过(脚本错误只让**出错的那个函数**结束,调用方继续  ->  verdict 照打 ALL-OK)。
	var missing: Array[String] = []
	for n in CHECK_NAMES:
		if not _done.has(n):
			missing.append(n)
	if not missing.is_empty():
		print("STATS DELIVERY: FAIL —— ★★ 这些检查**没跑到尾**:%s" % str(missing))
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("STATS DELIVERY: ALL-OK")
	else:
		print("STATS DELIVERY: FAIL —— " + str(_fails))
	get_tree().quit(0 if _fails.is_empty() else 1)


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


# 逐人条目的原始计数(缺条目 = 0,与生产 `_stat_entry` 同口径)。
func _stat(host, role: int, key: String) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get(key, 0))


# 整张逐人表里 `kills` **非零**的那些条目,形如 `["role 2=1"]`(按 `stats_payload()` 的 role 序)。
# - 用**整张表**而不是写死的 `[1,2,3]`:记到一个**表外**的 role 上时(`_roster()` 会把 `_stats`
#   里的一切都收进载荷)写死列表看不见 —— 而那正是一个更隐蔽的错形状。
func _kills_table(host) -> Array[String]:
	var out: Array[String] = []
	for r in host.stats_payload():
		var k := _stat(host, int(r), "kills")
		if k > 0:
			out.append("role %d=%d" % [int(r), k])
	return out


# 生产那条"强制倒地"入口(`CombatComponent.force_down`;K 键自杀走的也是它)。
func _force_down(host, role: int) -> void:
	(host.players[int(role)] as Node).get_node("Combat").force_down()


# 造一颗**真子弹**、走生产裁决链(`_adjudicate_bullets` → `_on_bullet_hit`)—— ⑦ 专用。
# - 摆在受害者**身上**(0 距离 < `HIT_RADIUS`)。
# - **不 await**:一 await 子弹就按自己的 `_physics_process` 飞走了。
# - 射手与伤害**照 `WeaponBase.fire()` 的注入方式**手工设(`shooter` / `hit_damage` 就是 fire 设的两个量),
#   本函数不重造那半条链 —— ⑦ 要验的是**裁决侧**(`_on_bullet_hit` 写不写归因),不是出膛侧。
func _fire_bullet_at(host, shooter: Node2D, victim: Node2D) -> void:
	var bullet: CharacterBody2D = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.shooter = shooter
	bullet.hit_damage = DUEL_BULLET_DAMAGE
	add_child(bullet)                 # `_ready` 在这里把它加进 `bullet` 组(`_adjudicate_bullets` 靠它找)
	bullet.global_position = victim.global_position
	host._adjudicate_bullets()


func _kscore(host, role: int) -> int:
	return int(host.stats_payload()[int(role)]["kscore"])


func _keys_of(host, role: int) -> Array:
	var row: Dictionary = host.stats_payload().get(int(role), {})
	var k: Array = row.keys()
	k.sort()
	return k


# ── 截获帧的读法(都只读 `RpcPayload.snap` 在**调用时刻**留下的那份拷贝)──

# 该帧里有没有这个键。
func _has(frame: Dictionary, key: String) -> bool:
	return (frame.get("payload", {}) as Dictionary).has(key)


# 该帧真正带的键集(打印进失败消息用 —— "广播里到底有什么"是这条守卫唯一该看的东西)。
func _keys_of_frame(frame: Dictionary) -> Array:
	return (frame.get("payload", {}) as Dictionary).keys()


# **任何**一帧里带过这个键吗(反向断言用:遍历全部帧,而不是只看某一帧)。
func _any_has(frames: Array, key: String) -> bool:
	for f in frames:
		if _has(f, key):
			return true
	return false


# 最后一条 `state == s` 的帧;从没广播过该状态 → 空字典(调用方**必须先**判空,否则为无效操作断言)。
func _frame_at(host, s: int) -> Dictionary:
	var found: Dictionary = {}
	for f in host.frames:
		if int(f.get("state", -1)) == s:
			found = f
	return found


func _run() -> void:
	await _check_duel_phase()
	await _check_duel_kill_rule()
	await _check_duel_bullet_path()
	await _check_royale_phase()
	_check_delivery_source()
	await _check_delivery_payload()
	await _check_team_phase()


# ── ① 1v1:伤害进 dealt/taken、倒地记 deaths、击杀记给对手、载荷七个字段 ──
func _check_duel_phase() -> void:
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelHost"
	add_child(host)
	# - 合成/真图都行:本段只用「归因 + take_hit + 倒地边沿 + 逐人表」,不碰几何。
	#   真图 `newfactory.cyrm` 有 `# player`/`# player2` 出生点,`_respawn_player` 才可用。
	GameParameters.refresh_map_size()
	_place(host, 1, _p1_cell)
	_place(host, 2, _p2_cell)
	host._wire_hit_feedback()     # - 手工摆位路径必须补调**生产那一份**接线(否则一条线都没有)
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame     # 让 `@onready` 的 combat/weapons 就绪

	# (a) 一次已知伤害 → dealt 记给射手、taken 记给受害者
	var dealt0 := _stat(host, 1, "dealt")
	var taken0 := _stat(host, 2, "taken")
	CombatFeedback.attribute(host.players[2], host.players[1])
	(host.players[2] as Node2D).take_hit(Vector2.ZERO, 7)
	_check(_stat(host, 1, "dealt") - dealt0 == 7,
			"★ ① 1v1:己方伤害进**射手**的 dealt(实际 +%d,期望 +7)"
			% (_stat(host, 1, "dealt") - dealt0))
	_check(_stat(host, 2, "taken") - taken0 == 7,
			"★ ① 1v1:同一笔进**受害者**的 taken(实际 +%d,期望 +7)"
			% (_stat(host, 2, "taken") - taken0))

	# (b) 倒地 → deaths 一律 +1、击杀记给对手(1v1 的计分口径)
	_force_down(host, 2)     # 走生产那条强制倒地入口
	host._match_round_tick(0.016)
	_check(_stat(host, 2, "deaths") == 1,
			"★ ① 1v1:倒地边沿记 deaths(实际 %d,期望 1)" % _stat(host, 2, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			"★ ① 1v1:击杀记给对手(实际 %d,期望 1)" % _stat(host, 1, "kills"))
	_check(_kscore(host, 1) == 100 + 7 / 5,
			("★ ① 1v1:kscore = 击杀×100 + 伤害÷5(实际 %d,期望 %d)"
			+ " —— 这条把「公式真的走在生产路径上」与逐人表接起来")
			% [_kscore(host, 1), 100 + 7 / 5])
	_check(_keys_of(host, 1) == WANT_KEYS,
			"★ ① 1v1:载荷每行恰好七个字段(实际 %s)" % str(_keys_of(host, 1)))
	host.free()

	_done.append("duel_phase")
	await get_tree().process_frame


# ── ② 1v1 的击杀规则是**无归因**的:自杀也给对手 +1(结算页必须与记分条同口径)──
func _check_duel_kill_rule() -> void:
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelSuicideHost"
	add_child(host)
	GameParameters.refresh_map_size()
	_place(host, 1, _p1_cell)
	var p2: Node2D = _place(host, 2, _p2_cell)
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	# 自杀:K 键那条路 = 先清归因 meta、再 `force_down`(见 `RoyaleHost.request_suicide_role`)
	for m in ["last_damager", "last_damager_time"]:
		if p2.has_meta(m):
			p2.remove_meta(m)
	_force_down(host, 2)
	host._match_round_tick(0.016)
	_check(_stat(host, 2, "deaths") == 1, "★ ② 1v1:自杀照记 deaths(实际 %d)" % _stat(host, 2, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			("★ ② 1v1:**无归因的死亡也算对手的击杀**(实际 %d,期望 1)"
			+ " —— 1v1 的计分口径是「不分死因、对方死亡都算」(用户裁定);"
			+ "照 3v3 的『只算有归因的击杀』写会让结算页的击杀数**低于**记分条上的分数") % _stat(host, 1, "kills"))
	host.free()

	_done.append("duel_kill_rule")
	await get_tree().process_frame


# ── ⑦ 1v1 的**子弹链**:生产裁决函数**自己**必须写归因 ──
#
# 注意： 为什么单列一段、而不是并进 ①:① 走的是**手工** `CombatFeedback.attribute(...)` +
#   `take_hit(...)` —— **整条子弹链一次都没走**。而缺口恰恰在子弹链上:基类
#   `MatchCombat._on_bullet_hit` 原先**自己不写归因**,只有 `RoyaleHost` / `TeamHost` 的覆写写;
#   而 1v1 走 `MatchBootstrap.start_on` **直接建 `MatchHost`**(全仓唯一实例化点) ->  1v1 的子弹
#   (主要伤害来源)不计入 `dealt`/`taken`,结算页显示 `击杀 5 / 造成 0 / 承受 0`。
#   - ① 长期测试全部通过**正是因为它绕开了被破坏的那一跳** —— 它是"归因 → 统计"的守卫,
#     本段是"**生产自己写不写归因**"的守卫,两条互不替代。
# - 夹具走生产路径:`_adjudicate_bullets()` 是生产同一个函数、同一个 `HIT_RADIUS`
#   (单一来源 `BulletBase.PLAYER_HIT_RADIUS`)。宿主用**裸 `MatchHost`** —— 那正是 1v1 的形态。
func _check_duel_bullet_path() -> void:
	# ── (a) 干净 1v1:子弹命中 → dealt 记给射手、taken 记给受害者 ──
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelBulletHost"
	add_child(host)
	GameParameters.refresh_map_size()
	var shooter: Node2D = _place(host, 1, _p1_cell)
	var victim: Node2D = _place(host, 2, _p2_cell)
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame

	var dealt0 := _stat(host, 1, "dealt")
	var taken0 := _stat(host, 2, "taken")
	# - 用 `get("hp")` 而不是 `victim.hp`:静态类型是 `Node2D`,编译期看不到 `Player.hp`
	#   (Godot 4 对已标注类型的变量取未知属性是**编译错误**,不是运行期错误)。
	var hp0 := int(victim.get("hp"))
	_fire_bullet_at(host, shooter, victim)
	# 夹具自检:命中必须真的发生。少了它,万一子弹没进 `bullet` 组/没走到裁决,
	# 下面两条会因为 `dealt`/`taken` **两边都是 0** 而以"期望 +7 实得 +0"报红(不会测试漏检),
	# 但报的是"没打中",不是"归因缺了" —— 自检把这两种成因分开。
	_check(int(victim.get("hp")) < hp0,
			("★ ⑦(a) 夹具自检:子弹必须真的命中(受害者 hp %d → %d)"
			+ " —— 没命中时下面两条红的是『没打中』,不是『归因缺了』")
			% [hp0, int(victim.get("hp"))])
	_check(_stat(host, 1, "dealt") - dealt0 == DUEL_BULLET_DAMAGE,
			("★ ⑦(a) 1v1:子弹命中必须记进**射手**的 dealt(实际 +%d,期望 +%d)"
			+ " —— 生产 `_on_bullet_hit` 自己不写归因时这里是 0,而 ① 照旧全绿")
			% [_stat(host, 1, "dealt") - dealt0, DUEL_BULLET_DAMAGE])
	_check(_stat(host, 2, "taken") - taken0 == DUEL_BULLET_DAMAGE,
			"★ ⑦(a) 1v1:同一笔进**受害者**的 taken(实际 +%d,期望 +%d)"
			% [_stat(host, 2, "taken") - taken0, DUEL_BULLET_DAMAGE])
	host.free()
	await get_tree().process_frame

	# ── (b) 自伤标记在场时的子弹命中:必须记进**射手**的 dealt,不得记成受害者的 self_damage ──
	# - 这一半是修法**顺带闭合**的耦合症状(见 `CombatFeedback.attribute()` 末尾那句
	#   `remove_meta("last_self_hit_time")`):1v1 没有归因写端  ->  那个标记永不失效  -> 
	#   "自己炸自己之后 8ms 内被敌人打中"会**扣自己的分**(记成 self_damage)。
	# - 受害者取**干净**的一具(另建宿主):若沿用 (a) 那具,`last_damager` 还是新鲜的
	#    ->  `stat_attacker` 非 0  ->  缺了修法那一半时 dealt 照样会涨,(b) 就只剩 self_damage 一条在鉴别。
	var host2 = MatchHost.new(MAP, {}, {})
	host2.name = "StatsDuelBulletSelfHost"
	add_child(host2)
	GameParameters.refresh_map_size()
	var shooter2: Node2D = _place(host2, 1, _p1_cell)
	var victim2: Node2D = _place(host2, 2, _p2_cell)
	host2._wire_hit_feedback()
	host2._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame

	var dealt0b := _stat(host2, 1, "dealt")
	var self0 := _stat(host2, 2, "self_damage")
	CombatFeedback.note_self_hit(victim2)   # 生产写端:`Explosion.apply_aoe` 里 shooter == 自己那一支
	_fire_bullet_at(host2, shooter2, victim2)
	_check(_stat(host2, 2, "self_damage") - self0 == 0,
			("★ ⑦(b) 自伤标记**不得**吃掉紧随其后的敌人子弹(实际 self_damage +%d,期望 +0"
			+ " —— 涨了就是玩家『因为被敌人打中而扣自己的分』)")
			% [_stat(host2, 2, "self_damage") - self0])
	_check(_stat(host2, 1, "dealt") - dealt0b == DUEL_BULLET_DAMAGE,
			"★ ⑦(b) 那一笔必须记进**射手**的 dealt(实际 +%d,期望 +%d)"
			% [_stat(host2, 1, "dealt") - dealt0b, DUEL_BULLET_DAMAGE])
	host2.free()
	await get_tree().process_frame

	_done.append("duel_bullet_path")


# ── ③ 大乱斗:同一个倒地边沿记 deaths/击杀,`deaths` 载荷只从逐人表来 ──
#
# 注意： F2(评审 Critical,2026-09-26):本段的**测试有效性**是专门为下面这一对形状设计的,动夹具
#    里的 role 号之前先读完这段。
#    大乱斗的计分口径 = **归因制**(`_record_down(int(role), _attributed_killer(p))`:无归因的
#    死亡不计任何人的击杀);1v1 的是「不分死因、对方死亡都算」(`_opponent_of(role)`)。
#    旧夹具(受害者 3 / 归因射手 1)里两者**恰好同值**  ->  把生产那行换成 1v1 的错形状,
#    本段断言(含新加的 dealt/taken)**全部照旧绿**,verdict 与基线逐字相同。
#    现在归因目标取 **role 2**,于是:
#      正确实现(`_attributed_killer`)= 2 / 错形状(`_opponent_of(3)` = 按位置第一个非 3 的 role)= 1
#    两者**必然不同**(夹具自检那条钉住这个前提;谁把 `_place` 的顺序或 role 号改了,自检先红)。
#    另有 (b) 的**无归因**档:旧夹具在大乱斗这条链上**从没造过**它(只在 1v1 的 ② 里清过 meta),
#    所以"未归因 = 不计任何人击杀"这条规则在本链上是**零覆盖**的。
func _check_royale_phase() -> void:
	var host = RoyaleHost.new(MAP, {}, {}, [], {})
	host.name = "StatsRoyaleHost"
	add_child(host)
	GameParameters.refresh_map_size()
	_place(host, 1, Vector2i(20, 20))
	_place(host, 2, Vector2i(40, 20))
	_place(host, 3, Vector2i(60, 20))
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame

	# - 夹具自检:本段的测试有效性**只**在"两个实现给出不同答案"时存在。写成"应当不同"而不是
	#   严格约束某个具体值(比如 `== 1`),是为了让它只在**测试有效性消失**时报红,而不去复述
	#   `_opponent_of` 的实现细节 —— 但它确实会因 `_place` 顺序/role 号改动而红,那正是要的。
	_check(host._opponent_of(3) != 2,
			("★ ③ 夹具自检:1v1 的错形状(`_opponent_of(3)` = %d)必须与正确归因(role 2)"
			+ "**给出不同答案** —— 同值则下面那条断言区分不了两种实现(本段旧版就是这么瞎的)")
			% host._opponent_of(3))

	# (a) 有归因:击杀记给**归因到的射手**(role 2),不是按位置推出的对手(role 1)
	CombatFeedback.attribute(host.players[3], host.players[2])
	(host.players[3] as Node2D).take_hit(Vector2.ZERO, 8)
	_force_down(host, 3)
	host._match_round_tick(0.016)
	_check(_stat(host, 3, "deaths") == 1,
			"★ ③ 大乱斗:倒地边沿记 deaths(实际 %d,期望 1)" % _stat(host, 3, "deaths"))
	# 注意： 为什么用**整表**（`kills` 非零的 role 集合 == 恰好一个）而不是只钉 "role 2 == 1"：
	#   整表形式对任何**固定 role 子集**都是**严格加强**，它**唯一多换取收益**的是
	#   "**记对了 role 之外还多记一笔**"那一族（`给所有人都记一笔`）。
	#   - 订正（评审复核实测）：初稿还举了"记到一个**表外** role 上"当理由 —— **举错了**：
	#     那种实现下正确的 role 2 拿到 0 笔，**"role 2 == 1" 的固定断言照样会红**（隔离株 M99 实测）。
	#   代价（登记在此，按本仓"belt 的代价记在守卫处"的惯例）：将来大乱斗若出现
	#   **一次倒地合法地记多笔击杀**的规则，这条会**测试误报** —— 今天没有这条规则。
	_check(_kills_table(host) == ["role 2=1"],
			("★ ③ 大乱斗:有归因的击杀**恰好**记给归因射手(整表 kills 非零者 = %s,期望"
			+ " ['role 2=1'])—— 两个错形状落在这条上:按位置取对手(`_opponent_of(3)` 在这格"
			+ "给 role 1)、以及『给正确的 role 之外**还**多记一笔』")
			% str(_kills_table(host)))
	_check(_stat(host, 3, "taken") == 8 and _stat(host, 2, "dealt") == 8,
			"★ ③ 大乱斗:dealt/taken 与 1v1 同源(实际 %d/%d,期望 8/8)"
			% [_stat(host, 2, "dealt"), _stat(host, 3, "taken")])
	_check(_keys_of(host, 3) == WANT_KEYS,
			"★ ③ 大乱斗:载荷每行恰好七个字段(实际 %s)" % str(_keys_of(host, 3)))

	# (b) 无归因:大乱斗**不是** 1v1 那套"不分死因都算对手的击杀" —— deaths 照记,
	#     但**任何人**的 kills 都不许动。受害者取 role 1(从头到尾没挨过打),并照 ② 的做法
	#     显式清一遍 meta(不依赖"没人打过他"这个隐含前提)。
	var victim: Node2D = host.players[1]
	for m in ["last_damager", "last_damager_time"]:
		if victim.has_meta(m):
			victim.remove_meta(m)
	var before := host.stats_payload()      # 真快照:`stats_payload()` 每次现建一份
	_force_down(host, 1)
	host._match_round_tick(0.016)
	# 这条同时是 (b) 的**夹具自检**:deaths 不动就说明这一 tick 根本没走到倒地边沿
	# (下面那条"谁的 kills 都没涨"会**无效操作通过**)。
	_check(_stat(host, 1, "deaths") == 1,
			"★ ③ 大乱斗:无归因的死亡**照记** deaths(实际 %d,期望 1)"
			% _stat(host, 1, "deaths"))
	var gained: Array[String] = []
	for r in host.stats_payload():      # 整表遍历:表外 role 被记了也看得见
		var role := int(r)
		var was: int = int((before.get(role, {}) as Dictionary).get("kills", 0))
		var now := _stat(host, role, "kills")
		if now != was:
			gained.append("role %d +%d" % [role, now - was])
	_check(gained.is_empty(),
			("★ ③ 大乱斗:无归因的死亡**不计任何人的**击杀(各 role 的 kills 增量 = %s,期望 []"
			+ " —— 1v1 那条『无归因也算对手的击杀』(②)是大乱斗**不该**有的形状:自由混战里"
			+ "自杀/溺水/坠落都会白送别人一分)") % str(gained))

	check_royale_deaths_source()
	host.free()

	_done.append("royale_phase")
	await get_tree().process_frame


# 大乱斗载荷里的 `deaths` 必须**从逐人表读**(旧的 `_deaths` 是同一件事的第二份计数,已删)。
# - 这一条**留源码级**,理由与 ④ 那条相同机制:它问的是**来源**(载荷里那个键是从哪张表构造的),
#   而不是"某段文本在不在" —— 行为面的**等价物**在 ⑤(`广播出去的 deaths == 逐人表的 deaths`),
#   两者不是冗余:行为面证明"两边的值今天相等",这一条证明"值取自哪里"(并行维护两份计数
#   也能让值相等,而那正是要禁的东西)。
func check_royale_deaths_source() -> void:
	var body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/hosts/royale_host.gd")), "_broadcast_round_state")
	_check(not body.is_empty(),
			"★ ③ 定位到 royale_host._broadcast_round_state 的源码(取不到 = 本守卫失明,必须红)")
	if body.is_empty():
		return
	_check(body.contains("_roster()"),
			"★ ③ 大乱斗载荷的 `deaths` 必须从逐人表的 role 集合(`_roster()`)构造(第二份计数会漂)")


# ── ④ 写入口那一半(**源码级**):1v1 的倒地边沿必须走**唯一**的写入口 `_record_down` ──
#
# - 为什么这一条**留源码级**(投递那三条已改到 ⑤ 的**行为面**):
#   "倒地边沿记了 deaths/kills"这一半,① / ② 已用**行为**咬住了(把那行注释掉  ->  五条红);
#   但"必须**经由** `_record_down`"是一个**路由**不变量,行为面表达不了 —— 助攻表与惩罚账都写在
#   `_record_down` **体内**,另起一份并行写入会在数字上"看着对",却把助攻/惩罚静默漏掉。
#   - 它**不是**次序无关的文本共现(不涉及与 `_rpc_all` 的先后) —— 那一类已从本文件**删除**。
func _check_delivery_source() -> void:
	var tick := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match/match_round.gd")), "_match_round_tick")
	_check(not tick.is_empty(),
			"★ ④ 定位到 match_round._match_round_tick 的源码(取不到 = 本守卫失明,必须红)")
	if not tick.is_empty():
		_check(tick.contains("_record_down("),
				"★ ④ 1v1 的倒地边沿必须调 `_record_down`(不写 = deaths/kills 恒 0,不报错)")

	_done.append("delivery_source")


# ── ⑤ 投递那一半(**行为面**):截获真正要发出去的 `round_state` 字典 ──
#
# - 旧版的三问是"函数体里含不含 `data["stats"]` / `data["mvp"]` / `if not table.is_empty():`"
#   —— **次序无关的文本共现**:把 `_rpc_all("round_state", [data])` 提到挂载之前(客户端一个键
#   都收不到)、或把 `mvp` 挪出 MATCH_OVER 分支(每帧多带一个没有意义的键),三条**照样测试全部通过**。
#   现在这三件事一律按**广播件**判:截获手段见 `RpcPayload` 的注释(**调用时刻取快照**)。
#
# - 三个 MATCH_OVER 的判据都配了"夹具自检"(先断言真的广播过那个状态),否则"从没走到那里"
#   会让那几条**无效操作通过** —— 那是本仓登记过的测试漏检形状。
func _check_delivery_payload() -> void:
	# ── (甲)1v1:`MatchRound._broadcast_round_state` ──
	var host = CapturingDuelHost.new(MAP, {}, {})
	host.name = "StatsDeliveryDuelHost"
	add_child(host)                    # ← `_ready` 在这里广播一次(**此刻 `players` 还是空的**)
	GameParameters.refresh_map_size()
	# (a) 逐人表为空时不得带 `stats` 键 —— 在 `_place` **之前**取,故它验的**就是**那个分支
	#     (`stats_payload()` 对空 `_roster()` 返回 `{}`;生产靠 `if not table.is_empty():` 省键)。
	#     - 这替代了旧版那条 `函数体里含 'if not table.is_empty():'` 的文本断言 —— 后者在
	#       "句子还在、语意没了"(`if …: pass` + 赋值挪到 if 之外)的写法下**测试全部通过**。
	var empty_n: int = host.frames.size()
	_check(empty_n > 0 and not _any_has(host.frames, "stats"),
			"★ ⑤ 1v1:逐人表为空时的 round_state **不带** `stats` 键(带宽纪律,与 teams/destroyed 同款;"
			+ "截获 " + str(empty_n) + " 帧)")

	_place(host, 1, _p1_cell)
	_place(host, 2, _p2_cell)
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	_force_down(host, 2)               # 生产那条倒地边沿,它内部会 `_broadcast_round_state()`
	host._match_round_tick(0.016)

	var playing := _frame_at(host, MatchHost.RoundState.PLAYING)
	_check(not playing.is_empty(),
			"★ ⑤ 1v1:PLAYING 真的广播过 round_state(夹具自检 —— 少了它下面四条是空转)")
	_check(_has(playing, "stats"),
			"★ ⑤ 1v1:PLAYING 的 round_state **确实带** `stats`(截获的键集 = "
			+ str(_keys_of_frame(playing)) + " —— 这是真要发出去的字典,不是源码文本)")
	_check(not _has(playing, "mvp"),
			"★ ⑤ 1v1:PLAYING **不带** `mvp`(它只在 MATCH_OVER 支内挂;挪出分支 = 每帧多带一个"
			+ "没有读者的键)截获的键集 = " + str(_keys_of_frame(playing)))
	# 载荷内容:每行恰好七个字段(① 那条读的是 `stats_payload()` 的**返回值**,这条读**广播件**)。
	var sent_row: Dictionary = (playing.get("payload", {}) as Dictionary).get("stats", {}).get(1, {})
	var sent_keys: Array = sent_row.keys()
	sent_keys.sort()
	_check(sent_keys == WANT_KEYS,
			"★ ⑤ 1v1:广播出去的逐人表每行恰好七个字段(实际 " + str(sent_keys) + ")")

	# (b) MATCH_OVER:走生产**唯一**那条进 MATCH_OVER 的路(`_start_next_round` 的局胜分支)。
	host._rounds_won[1] = MatchHost.ROUNDS_TO_WIN
	host._start_next_round()
	var over := _frame_at(host, MatchHost.RoundState.MATCH_OVER)
	_check(not over.is_empty(),
			"★ ⑤ 1v1:MATCH_OVER 真的广播过 round_state(夹具自检)")
	_check(_has(over, "mvp"),
			"★ ⑤ 1v1:MATCH_OVER 的 round_state **确实带** `mvp`(截获的键集 = "
			+ str(_keys_of_frame(over)) + ")")
	var over_payload: Dictionary = over.get("payload", {})
	_check(int(over_payload.get("mvp", -1)) == host.mvp_role(),
			"★ ⑤ 1v1:广播出去的 `mvp` == 生产算出来的 `mvp_role()`(实际 "
			+ str(int(over_payload.get("mvp", -1))) + " / 期望 " + str(host.mvp_role())
			+ ") —— 这条把「挂上了」与「挂的是对的那个值」接起来")
	_check(_has(over, "stats"),
			"★ ⑤ 1v1:MATCH_OVER 的 round_state 也带 `stats`(整场打完那一份是结算页要用的)")
	host.free()
	await get_tree().process_frame

	# ── (乙)大乱斗:`RoyaleHost._broadcast_round_state`(**整体覆写**了基类那一份)──
	var rhost = CapturingRoyaleHost.new(MAP, {}, {}, [], {})
	rhost.name = "StatsDeliveryRoyaleHost"
	add_child(rhost)                   # 同上:此刻 `players` 还是空的
	GameParameters.refresh_map_size()
	var rempty_n: int = rhost.frames.size()
	_check(rempty_n > 0 and not _any_has(rhost.frames, "stats"),
			"★ ⑤ 大乱斗:逐人表为空时的 round_state **不带** `stats` 键(截获 "
			+ str(rempty_n) + " 帧)")
	_place(rhost, 1, Vector2i(20, 20))
	_place(rhost, 2, Vector2i(40, 20))
	_place(rhost, 3, Vector2i(60, 20))
	rhost._wire_hit_feedback()
	rhost._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	_force_down(rhost, 3)
	rhost._match_round_tick(0.016)

	var rplaying := _frame_at(rhost, MatchHost.RoundState.PLAYING)
	_check(not rplaying.is_empty(),
			"★ ⑤ 大乱斗:PLAYING 真的广播过 round_state(夹具自检 —— 少了它下面两条是空转)")
	_check(_has(rplaying, "stats"),
			"★ ⑤ 大乱斗:PLAYING 的 round_state **确实带** `stats`(截获的键集 = "
			+ str(_keys_of_frame(rplaying)) + ")")
	# `deaths` 必须与逐人表**同源**(旧的 `_deaths` 是同一件事的第二份计数;两份必然漂,
	# 且漂了不会有任何报错)—— ③ 那条是**来源**守卫,这条是**值**守卫,两条都要。
	var rdeaths: Dictionary = (rplaying.get("payload", {}) as Dictionary).get("deaths", {})
	var want_deaths := {}
	var rtable := rhost.stats_payload()
	for r in rtable:
		want_deaths[int(r)] = int(rtable[int(r)]["deaths"])
	_check(rdeaths == want_deaths,
			"★ ⑤ 大乱斗:广播出去的 `deaths` == 逐人表的 deaths(实际 " + str(rdeaths)
			+ " / 期望 " + str(want_deaths) + ")")

	# MATCH_OVER:生产路线是 `_match_time` 归零 → `_finish_match()`。
	rhost._match_time = 0.0
	rhost._match_round_tick(0.016)
	var rover := _frame_at(rhost, MatchHost.RoundState.MATCH_OVER)
	_check(not rover.is_empty(),
			"★ ⑤ 大乱斗:MATCH_OVER 真的广播过 round_state(夹具自检 —— 下面那条反向断言"
			+ "要**有意义**就必须走到这里:只扫局中帧的话,'MATCH_OVER 支里加了 mvp' 照绿)")
	_check(not _any_has(rhost.frames, "mvp"),
			"★ ⑤ 大乱斗:**任何**一帧都不带 `mvp`(含 MATCH_OVER;本计划的既定取舍)")
	rhost.free()
	await get_tree().process_frame

	_done.append("delivery_payload")


# ── ⑥ 3v3 的投递那一半(**行为面**):`TeamHost._broadcast_round_state`(**整体覆写**了基类那一份)──
#
# 注意： 本段是"3v3 投递有守卫"这句话**唯一**的落点(替代 `team_host_probe` ⑬g 那三条文本共现 ——
#   它们的失败模式见文件头那段实测读数)。判据与 ⑤ 逐条同形:全部读**截获帧**(调用时刻深拷贝),
#   每一条 MATCH_OVER 判据都配一条"夹具自检",否则"从没走到那里"会让它**无效操作通过**。
# - 夹具与其它段相同机制:实际创建 3v3 宿主、`role_peers` 传空、玩家手工摆位(role 1 = 1 队 / role 4 = 2 队)。
#   - 散点显式传进去(与 `team_host_probe` 相同机制;`spawns` 传空会让 `_init` 自己再 shuffle 一份)。
#   - **本段最后跑**:建宿主会重载全局网格(`MatchHost._init` → `WorldBuilder.load_grid`),
#     前面的段(尤其大乱斗那两份夹具的摆位)依赖它保持不动。
func _check_team_phase() -> void:
	var teams := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
	var host = CapturingTeamHost.new(MAP, {}, {}, [], TeamHost.plan_team_spawns(teams), teams)
	host.name = "StatsDeliveryTeamHost"
	add_child(host)                    # ← `_ready` 在这里广播一次(**此刻 `players` 还是空的**)
	GameParameters.refresh_map_size()
	# (a) 逐人表为空时不得带 `stats` 键 —— 它同时是旧版第三条文本断言
	#     (`if not table.is_empty():`)的**行为面等价物**(那句在"句子还在、语意没了"的写法下测试全部通过)。
	var tempty_n: int = host.frames.size()
	_check(tempty_n > 0 and not _any_has(host.frames, "stats"),
			"★ ⑥ 3v3:逐人表为空时的 round_state **不带** `stats` 键(带宽纪律;截获 "
			+ str(tempty_n) + " 帧)")

	_place(host, 1, _p1_cell)
	_place(host, 4, _p2_cell)
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	_force_down(host, 4)               # 生产那条倒地边沿,它内部会 `_broadcast_round_state()`
	host._match_round_tick(0.016)

	var tplaying := _frame_at(host, MatchHost.RoundState.PLAYING)
	_check(not tplaying.is_empty(),
			"★ ⑥ 3v3:PLAYING 真的广播过 round_state(夹具自检 —— 少了它下面三条是空转)")
	_check(_has(tplaying, "stats"),
			("★ ⑥ 3v3:PLAYING 的 round_state **确实带** `stats`(截获的键集 = "
			+ str(_keys_of_frame(tplaying)) + " —— 这是真要发出去的字典,不是源码文本;"
			+ "把 `_rpc_all` 提到挂载 `stats` 之前时**只有这里**会红)"))
	_check(not _has(tplaying, "mvp"),
			("★ ⑥ 3v3:PLAYING **不带** `mvp`(它只在 MATCH_OVER 支内挂;挪出分支 = 每帧多带一个"
			+ "没有读者的键)截获的键集 = " + str(_keys_of_frame(tplaying))))
	# 载荷内容:每行恰好七个字段(读的是**广播件**,与 `team_host_probe` ⑬g 读 `stats_payload()`
	# 返回值那条不是同一件事)。
	var tsent_row: Dictionary = (tplaying.get("payload", {}) as Dictionary).get("stats", {}).get(4, {})
	var tsent_keys: Array = tsent_row.keys()
	tsent_keys.sort()
	_check(tsent_keys == WANT_KEYS,
			"★ ⑥ 3v3:广播出去的逐人表每行恰好七个字段(实际 " + str(tsent_keys) + ")")

	# (b) MATCH_OVER:走生产**唯一**那条进 MATCH_OVER 的路(`_start_next_round` 的局胜分支)。
	host._rounds_won[1] = TeamHost.TEAM_ROUNDS_TO_WIN
	host._start_next_round()
	var tover := _frame_at(host, MatchHost.RoundState.MATCH_OVER)
	_check(not tover.is_empty(),
			"★ ⑥ 3v3:MATCH_OVER 真的广播过 round_state(夹具自检)")
	_check(_has(tover, "stats"),
			("★ ⑥ 3v3:MATCH_OVER 的 round_state **确实带** `stats`"
			+ "(整场打完那一份是结算页要用的;截获的键集 = " + str(_keys_of_frame(tover)) + ")"))
	_check(_has(tover, "mvp"),
			("★ ⑥ 3v3:MATCH_OVER 的 round_state **确实带** `mvp`(截获的键集 = "
			+ str(_keys_of_frame(tover)) + ")"))
	var tover_payload: Dictionary = tover.get("payload", {})
	_check(int(tover_payload.get("mvp", -1)) == host.mvp_role(),
			("★ ⑥ 3v3:广播出去的 `mvp` == 生产算出来的 `mvp_role()`(实际 "
			+ str(int(tover_payload.get("mvp", -1))) + " / 期望 " + str(host.mvp_role())
			+ ") —— 这条把「挂上了」与「挂的是对的那个值」接起来"))
	host.free()
	await get_tree().process_frame

	_done.append("team_phase")
