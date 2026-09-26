extends Node

# 1v1 / 大乱斗的逐人统计**写入与投递**守卫(3v3 的那一半在 `tests/team_host_probe` ⑬g)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn
# 判据: 文本 `STATS DELIVERY: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ═══ 为什么需要它 ═══
# `round_state` 是**广播**出去的(经 `_rpc_all` 的 RPC),探针手里没有 peer ⇒ 拿不到那份字典
# (`_rpc_all` 直接跳过)。故"投递"这一半只能**源码级**(函数体里必须出现 `data["stats"]`),
# 与 `team_host_probe` ⑬g 对 3v3 用的同一条手法;"数值"那一半则**真建宿主**、走生产倒地边沿后
# 读 `stats_payload()`。
# ★ 两半缺一不可:只断数值 ⇒ 键没挂上去(客户端永远收不到)照样全绿;只断源码 ⇒ 数值算错也全绿。
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
const CHECK_NAMES := ["duel_phase", "duel_kill_rule", "royale_phase", "delivery_source"]

var _fails: Array[String] = []
var _done: Array[String] = []


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


func _run() -> void:
	await _check_duel_phase()
	await _check_duel_kill_rule()
	await _check_royale_phase()
	_check_delivery_source()


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
func check_royale_deaths_source() -> void:
	var body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/royale_host.gd")), "_broadcast_round_state")
	_check(not body.is_empty(), "取不到 royale_host._broadcast_round_state 的函数体(改名/挪走了?)")
	if body.is_empty():
		return
	_check(body.contains("_roster()"),
			"★ ③ 大乱斗载荷的 `deaths` 必须从逐人表的 role 集合(`_roster()`)构造(第二份计数会漂)")


# ── ④ 投递那一半(源码级):`stats` / `mvp` 真的挂在两个宿主的 round_state 上 ──
func _check_delivery_source() -> void:
	var duel := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_broadcast_round_state")
	_check(not duel.is_empty(), "取不到 match_round._broadcast_round_state 的函数体")
	if not duel.is_empty():
		_check(duel.contains('data["stats"]'), "★ ④ 1v1 的 round_state 挂上 `stats`")
		_check(duel.contains('data["mvp"]'), "★ ④ 1v1 的 round_state 挂上 `mvp`(MATCH_OVER 分支)")
		_check(duel.contains("if not table.is_empty():"),
				"★ ④ 1v1 的 `stats` **只在非空时**带该键(与 teams / destroyed / 3v3 同款纪律)")
	var roy := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/royale_host.gd")), "_broadcast_round_state")
	_check(not roy.is_empty(), "取不到 royale_host._broadcast_round_state 的函数体")
	if not roy.is_empty():
		_check(roy.contains('data["stats"]'), "★ ④ 大乱斗的 round_state 挂上 `stats`")
		# ★ 反向:大乱斗**不给** `mvp`(spec §3.6/§4 都没要求;`acs ≡ kscore` 且榜已按击杀排)。
		#   这条不是洁癖 —— 加上去之后 `for_royale` 不读它,那才是"没有读者的键"。
		_check(not roy.contains('data["mvp"]'),
				"★ ④ 大乱斗**不该**带 `mvp`(本计划的既定取舍;要加是另一件事)")
	# 反向:1v1 的统计**必须**由 `MatchRound._match_round_tick` 的倒地边沿写(不能只靠子类)。
	var tick := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_match_round_tick")
	_check(not tick.is_empty(), "取不到 match_round._match_round_tick 的函数体")
	if not tick.is_empty():
		_check(tick.contains("_record_down("),
				"★ ④ 1v1 的倒地边沿必须调 `_record_down`(不写 = deaths/kills 恒 0,不报错)")

	_done.append("delivery_source")
