extends Node

# 1v1 / 大乱斗的逐人统计**写入与投递**守卫(3v3 的那一半在 `tests/team_host_probe` ⑬g)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn
# 判据: 文本 `STATS DELIVERY: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ═══ 为什么需要它 ═══
# "数值"那一半**真建宿主**、走生产倒地边沿后读逐人表;"投递"那一半(⑤)则把**真正要发出去的
# `round_state` 字典**截获下来 —— 覆写 `_rpc_all`(见 `RpcPayload` 的注释)。
# ★ 两半缺一不可:只断数值 ⇒ 键没挂上去(客户端永远收不到)照样全绿;只断投递 ⇒ 数值算错也全绿。
#
# ★★ 本文件 2026-09-26 修掉一处**判据强度**缺陷(F1):旧版的"投递"三问是
#    `函数体里含不含 data["stats"]` 这类**次序无关的文本共现**,于是把
#    `_rpc_all("round_state", [data])` 提到挂载 `stats`/`mvp` **之前**(广播里一个键都不带)
#    三条断言**照样全绿**、verdict 与基线逐字相同 ⇒ 唯一的"投递"守卫在最该红的地方是绿的。
#    旧头注里那句「探针手里没有 peer ⇒ 投递那一半**只能**源码级」**不成立**:`_rpc_all` 是
#    可覆写的普通方法(不是引擎虚函数),覆写它就能在封包那一刻拿到载荷。**别改回去。**
#    ★ 仍然保留的**源码级**守卫只剩两条(见 ③/④ 的注释):它们问的是**路由/来源**,不是
#      "文本在不在" —— 那一类(以及 `mvp`、"只在非空时带键")现在**一律行为面**。
#
# ★ 宿主构造走本仓既有手法(`match_host_hygiene_probe` / `team_host_probe`):
#   真建宿主、`role_peers` 传空、玩家手工摆位、显式补调生产的 `_wire_hit_feedback()`。
# ★ 段数对账(本仓"假绿"纪律:`ALL-OK` 只证明"没有断言失败",不证明"该跑的断言都跑过")
#   —— 末尾拿 `_done` 与 `CHECK_NAMES` 对账,名单不全即红。

const MAP := "res://maps/factory1v1.cyrm"
# 载荷七个字段的**逐码点升序**(`_keys_of` 走 `Array.sort()`)。
# ★★ `dealt` 排在 `deaths` **之前**,别"顺手纠正"成字母表顺序:Godot 的 `Array.sort()` 对 String
#   走**逐码点**比较(`Variant::operator<` → `String::operator<` → `str_compare`),不是按
#   "dealt < deaths 看着不像"的直觉 —— 第 4 个字符 `l`(0x6C) vs `t`(0x74) ⇒ `dealt < deaths`。
#   写成 `[…, deaths, dealt, …]` 会让**生产改对了形状断言照样红**;而错误的修法(放宽成
#   "包含这七个键就行")会把"载荷字段集"这条真契约拆掉 —— 所以这里必须是逐码点升序。
const WANT_KEYS := ["acs", "assists", "dealt", "deaths", "kills", "kscore", "taken"]
const CHECK_NAMES := ["duel_phase", "duel_kill_rule", "royale_phase", "delivery_source",
		"delivery_payload"]

var _fails: Array[String] = []
var _done: Array[String] = []


# ═══ 载荷截获(把"投递"那一半从**源码文本**升到**真正要发出去的字典**)═══
#
# ★ `_rpc_all`(`server/match_state.gd`)是**可覆写**的普通方法,不是引擎虚函数:覆写它就能在
#   "封包那一刻"把 `args[0]` 拿到手 —— 探针手里没有 peer(于是 `_rpc_all` 循环空转、一个包都不发)
#   也照样能验投递。`super._rpc_all(...)` 照常跑,故**真实发包路径一字未变**。
#
# ★★ 唯一必须搞对的一处:**在调用时刻取快照**。`_broadcast_round_state` 先建一个 `data` 字典、
#   再**就地**往里补 `match_winner` / `mvp` / `stats`,**最后**才 `_rpc_all("round_state", [data])`;
#   而字典是**引用类型** ⇒ 覆写里只把 `args[0]` 存下来、事后再读,会看到**之后**才挂上去的键,
#   于是"把 `_rpc_all` 提到挂载之前"那个变异下守卫**照样全绿** —— 正是本次要堵的那个假绿。
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


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
func _ready() -> void:
	await _run()
	_finish()


func _finish() -> void:
	# ★ 段数对账:每个 `_check_*` 末行都要把自己的名字记进 `_done`;名单不全 = 有一段
	#   中途出错被静默跳过(脚本错误只让**出错的那个函数**结束,调用方继续 ⇒ verdict 照打 ALL-OK)。
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


# 生产那条"强制倒地"入口(`CombatComponent.force_down`;K 键自杀走的也是它)。
func _force_down(host, role: int) -> void:
	(host.players[int(role)] as Node).get_node("Combat").force_down()


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


# 最后一条 `state == s` 的帧;从没广播过该状态 → 空字典(调用方**必须先**判空,否则是空转断言)。
func _frame_at(host, s: int) -> Dictionary:
	var found: Dictionary = {}
	for f in host.frames:
		if int(f.get("state", -1)) == s:
			found = f
	return found


func _run() -> void:
	await _check_duel_phase()
	await _check_duel_kill_rule()
	await _check_royale_phase()
	_check_delivery_source()
	await _check_delivery_payload()


# ── ① 1v1:伤害进 dealt/taken、倒地记 deaths、击杀记给对手、载荷七个字段 ──
func _check_duel_phase() -> void:
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelHost"
	add_child(host)
	# ★ 合成/真图都行:本段只用「归因 + take_hit + 倒地边沿 + 逐人表」,不碰几何。
	#   真图 `factory1v1.cyrm` 有 `# player`/`# player2` 出生点,`_respawn_player` 才可用。
	GameParameters.refresh_map_size()
	_place(host, 1, Vector2i(17, 65))
	_place(host, 2, Vector2i(133, 64))
	host._wire_hit_feedback()     # ★ 手工摆位路径必须补调**生产那一份**接线(否则一条线都没有)
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
	_place(host, 1, Vector2i(17, 65))
	var p2: Node2D = _place(host, 2, Vector2i(133, 64))
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


# ── ③ 大乱斗:同一个倒地边沿记 deaths/击杀,`deaths` 载荷只从逐人表来 ──
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
	CombatFeedback.attribute(host.players[3], host.players[1])
	(host.players[3] as Node2D).take_hit(Vector2.ZERO, 8)
	_force_down(host, 3)
	host._match_round_tick(0.016)
	_check(_stat(host, 3, "deaths") == 1,
			"★ ③ 大乱斗:倒地边沿记 deaths(实际 %d,期望 1)" % _stat(host, 3, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			"★ ③ 大乱斗:有归因的击杀记给射手(实际 %d,期望 1)" % _stat(host, 1, "kills"))
	_check(_stat(host, 3, "taken") == 8 and _stat(host, 1, "dealt") == 8,
			"★ ③ 大乱斗:dealt/taken 与 1v1 同源(实际 %d/%d,期望 8/8)"
			% [_stat(host, 1, "dealt"), _stat(host, 3, "taken")])
	_check(_keys_of(host, 3) == WANT_KEYS,
			"★ ③ 大乱斗:载荷每行恰好七个字段(实际 %s)" % str(_keys_of(host, 3)))
	check_royale_deaths_source()
	host.free()

	_done.append("royale_phase")
	await get_tree().process_frame


# 大乱斗载荷里的 `deaths` 必须**从逐人表读**(旧的 `_deaths` 是同一件事的第二份计数,已删)。
# ★ 这一条**留源码级**,理由与 ④ 那条同款:它问的是**来源**(载荷里那个键是从哪张表构造的),
#   而不是"某段文本在不在" —— 行为面的**等价物**在 ⑤(`广播出去的 deaths == 逐人表的 deaths`),
#   两者不是冗余:行为面证明"两边的值今天相等",这一条证明"值取自哪里"(并行维护两份计数
#   也能让值相等,而那正是要禁的东西)。
func check_royale_deaths_source() -> void:
	var body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/royale_host.gd")), "_broadcast_round_state")
	_check(not body.is_empty(),
			"★ ③ 定位到 royale_host._broadcast_round_state 的源码(取不到 = 本守卫失明,必须红)")
	if body.is_empty():
		return
	_check(body.contains("_roster()"),
			"★ ③ 大乱斗载荷的 `deaths` 必须从逐人表的 role 集合(`_roster()`)构造(第二份计数会漂)")


# ── ④ 写入口那一半(**源码级**):1v1 的倒地边沿必须走**唯一**的写入口 `_record_down` ──
#
# ★ 为什么这一条**留源码级**(投递那三条已改到 ⑤ 的**行为面**):
#   "倒地边沿记了 deaths/kills"这一半,① / ② 已用**行为**咬住了(把那行注释掉 ⇒ 五条红);
#   但"必须**经由** `_record_down`"是一个**路由**不变量,行为面表达不了 —— 助攻表与惩罚账都写在
#   `_record_down` **体内**,另起一份并行写入会在数字上"看着对",却把助攻/惩罚静默漏掉。
#   ★ 它**不是**次序无关的文本共现(不涉及与 `_rpc_all` 的先后) —— 那一类已从本文件**删除**。
func _check_delivery_source() -> void:
	var tick := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_match_round_tick")
	_check(not tick.is_empty(),
			"★ ④ 定位到 match_round._match_round_tick 的源码(取不到 = 本守卫失明,必须红)")
	if not tick.is_empty():
		_check(tick.contains("_record_down("),
				"★ ④ 1v1 的倒地边沿必须调 `_record_down`(不写 = deaths/kills 恒 0,不报错)")

	_done.append("delivery_source")


# ── ⑤ 投递那一半(**行为面**):截获真正要发出去的 `round_state` 字典 ──
#
# ★ 旧版的三问是"函数体里含不含 `data["stats"]` / `data["mvp"]` / `if not table.is_empty():`"
#   —— **次序无关的文本共现**:把 `_rpc_all("round_state", [data])` 提到挂载之前(客户端一个键
#   都收不到)、或把 `mvp` 挪出 MATCH_OVER 分支(每帧多带一个没有意义的键),三条**照样全绿**。
#   现在这三件事一律按**广播件**判:截获手段见 `RpcPayload` 的注释(**调用时刻取快照**)。
#
# ★ 三个 MATCH_OVER 的判据都配了"夹具自检"(先断言真的广播过那个状态),否则"从没走到那里"
#   会让那几条**空转通过** —— 那是本仓登记过的假绿形状。
func _check_delivery_payload() -> void:
	# ── (甲)1v1:`MatchRound._broadcast_round_state` ──
	var host = CapturingDuelHost.new(MAP, {}, {})
	host.name = "StatsDeliveryDuelHost"
	add_child(host)                    # ← `_ready` 在这里广播一次(**此刻 `players` 还是空的**)
	GameParameters.refresh_map_size()
	# (a) 逐人表为空时不得带 `stats` 键 —— 在 `_place` **之前**取,故它验的**就是**那个分支
	#     (`stats_payload()` 对空 `_roster()` 返回 `{}`;生产靠 `if not table.is_empty():` 省键)。
	#     ★ 这替代了旧版那条 `函数体里含 'if not table.is_empty():'` 的文本断言 —— 后者在
	#       "句子还在、语意没了"(`if …: pass` + 赋值挪到 if 之外)的写法下**全绿**。
	var empty_n: int = host.frames.size()
	_check(empty_n > 0 and not _any_has(host.frames, "stats"),
			"★ ⑤ 1v1:逐人表为空时的 round_state **不带** `stats` 键(带宽纪律,与 teams/destroyed 同款;"
			+ "截获 " + str(empty_n) + " 帧)")

	_place(host, 1, Vector2i(17, 65))
	_place(host, 2, Vector2i(133, 64))
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
