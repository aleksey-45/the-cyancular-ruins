extends Node

# 队伍表进权威底座 + 子弹穿透队友。场景模式(root 有 autoload/`multiplayer`)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_table_probe.tscn
# 通过 = `TEAM TABLE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 队伍表算错/传丢的表现**全是静默的**:子弹照样飞、伤害照样结算,只是队友挨了枪。
#   数值断言(距离/伤害)在"队友被误伤"这件事上一条都不会红。
# ★ 反向那条(不传 teams → 全 0、`same_team` 恒 false)是"空参数 = 原行为"的**唯一证据**:
#   1v1/大乱斗的探针跑的是别的路径,照不到这里。
# 做法同 match_host_hygiene_probe:真建宿主,但 **role_peers 传空** —— 不建玩家、不排 peer、不发包;
# 玩家由探针自己按 `MatchHost._init` 的建法手工摆进 `players`。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _host = null
var _ran_to_end := false   # 见 destroyed_cells_probe 的同名注释:跑完闩,防"运行期报错却打 ALL-OK"


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	# ★ `await` 不可省(实测踩到):`_run()` 里有 `await get_tree().physics_frame`,
	#   它因此是协程 —— 不 await 的话 `_run()` 在第一个 await 处就返回,`_finish()` 会**立刻**跑,
	#   此时 `_ran_to_end` 恒 false → 所有断言全绿却打 `FAIL`,而第 ③ 段还排在 FAIL 之后打印。
	# ★ 跑完闩的语义不变:若 `_run()` 中途抛运行期错误(在 await 之前返回),`await` 一个非信号值
	#   会当场继续 → `_finish()` 照旧看到 `_ran_to_end == false` → 报"没跑到末尾"。
	await _run()
	_finish()


# 照 `MatchHost._init:32-44` 的建法手工摆一个玩家(那条路径在 role_peers 为空时不会跑)。
func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	var src := PacketInputSource.new()
	p.set_input_source(src)
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	host.input_sources[role] = src
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


func _run() -> void:
	# ── ① 带队伍表建局:team_of / same_team 是那张表 ──
	_host = MatchHost.new(MAP, {}, {}, [], TEAMS)
	add_child(_host)
	_host.set_physics_process(false)   # 手工驱动(不关的话 quit(0) 帧末生效,中间还会跑一帧物理)
	_check(_host.team_of(1) == 1, "role1 在 1 队")
	_check(_host.team_of(4) == 2, "role4 在 2 队")
	_check(_host.team_of(9) == 0, "表外的 role → 0(不是猜一个)")
	_check(_host.same_team(1, 3), "1 与 3 同队")
	_check(not _host.same_team(1, 4), "1 与 4 不同队")
	_check(not _host.same_team(0, 0), "★ 0 与 0 不算同队(无队伍 = 不豁免)")

	# ── ② 反向:不传 teams → 表空、same_team 恒 false(= 1v1/大乱斗的原行为)──
	var plain = MatchHost.new(MAP, {}, {}, [])
	add_child(plain)
	plain.set_physics_process(false)
	_check(plain.team_of(1) == 0, "★ 不传 teams 时 team_of 恒 0")
	_check(not plain.same_team(1, 1), "★ 不传 teams 时 same_team 恒 false")

	# ── ③ 子弹穿透队友:同队不结算、异队结算 ──
	# 摆两个玩家:role4(2 队)与 role5(2 队,队友)、role1(1 队,敌人)。全部站在同一格附近。
	var a := _place(_host, 4, Vector2i(20, 20))
	var mate := _place(_host, 5, Vector2i(21, 20))
	var foe := _place(_host, 1, Vector2i(22, 20))
	# ★★ [仪器] 钉住 `players` 的**插入顺序** —— ③/④ 的 `continue` vs `break` 区分度**全靠它**。
	#   裁决循环是 `for role in players`(即字典插入序),而射手是 role4:顺序 [4,5,1] 下,
	#   "打敌人"那次必然先遍历到**队友** role5(= 同队)→ 用 `break` 的实现会在那里**停下**,
	#   永远走不到 role1 → `hit_foe` 红。若有人重排了上面三行的摆放顺序(比如把敌人先摆进来),
	#   区分度**当场消失**而两条真断言**照样全绿** —— 正是本仓反复在删的那种形状。
	#   ★ 所以这条不是"重申实现细节":它守的是"③ 那两条为什么能红"。
	_check(_host.players.keys() == [4, 5, 1],
			"[仪器] players 按摆放顺序插入(4 → 5 → 1)—— **队友先于敌人被遍历**,"
			+ "③ 的 continue/break 区分度就靠它(实际 %s)" % str(_host.players.keys()))
	await get_tree().physics_frame   # 玩家 _ready(@onready combat/weapons)要跑过一帧
	# 子弹:由 4 号发射,位置压在 5 号身上(队友)→ 不该结算;再压到 1 号身上 → 该结算。
	var hit_mate := _fire_probe_bullet(_host, a, mate.global_position, 5)
	_check(not hit_mate, "★ 子弹穿过队友(4 号打 5 号不结算)")
	var hit_foe := _fire_probe_bullet(_host, a, foe.global_position, 1)
	_check(hit_foe, "子弹打敌人照常结算(1 号)")

	# ── ④ 榴弹**直击**那一层同样穿透队友(与普通弹同口径)──
	# ★ 为什么单钉它:`_adjudicate_bullets` 与 `_adjudicate_grenade` 各写了一份 `same_team` 判断,
	#   改一处忘一处时**子弹那条照样绿** —— 只有这一条能照出"榴弹直击还在打队友"。
	# ★ 爆炸那一层**故意不在这里断言**:用户裁定"子弹穿透队友、爆炸对队友**满效**",
	#   满效是 `Explosion.apply_aoe` 玩家分支的现状默认行为(它不看任何队伍关系),
	#   本任务一行未动 —— 给它加断言等于给"没改的代码"上锁,反而会绑住将来对爆炸的调参。
	var g_mate := _fire_probe_grenade(_host, a, mate.global_position, 5)
	_check(not g_mate, "★ 榴弹**直击**穿透队友(4 号砸 5 号不结算)")
	var g_foe := _fire_probe_grenade(_host, a, foe.global_position, 1)
	_check(g_foe, "榴弹直击敌人照常结算(1 号)")

	_ran_to_end = true


# 造一颗探针子弹(由 shooter 发射),摆在目标身上,跑一次裁决,返回"目标是否被结算"。
# ★ 判定用目标自身的**受伤证据**(hp 下降),不是读内部表 —— 与玩家实现解耦。
func _fire_probe_bullet(host, shooter: Node2D, at: Vector2, victim_role: int) -> bool:
	var victim: Node2D = host.players[victim_role]
	var before: int = victim.hp
	var b: CharacterBody2D = preload("res://scenes/weapons/bullet.tscn").instantiate()
	b.shooter = shooter
	b.hit_damage = 7
	host.add_child(b)
	b.global_position = at
	host._adjudicate_bullets()
	var after: int = victim.hp
	if is_instance_valid(b):
		b.queue_free()
	return after < before


# 同上的榴弹版(真 grenade_bullet.tscn,直击伤 5)。手法的来历见 grenade_player_hit_probe:
# `_adjudicate_grenade` 需整局服务器环境(-s 冒烟照不到权威那半)。
func _fire_probe_grenade(host, shooter: Node2D, at: Vector2, victim_role: int) -> bool:
	var victim: Node2D = host.players[victim_role]
	var before: int = victim.hp
	var b: CharacterBody2D = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	b.shooter = shooter
	b.hit_impact = 10.0   # 与 grenade_launcher.tscn 的 impact 一致(weapon_base 出弹时注入的值)
	host.add_child(b)
	b.global_position = at
	host._adjudicate_grenade(b)
	var after: int = victim.hp
	if is_instance_valid(b):
		b.free()   # 立即释放:榴弹被连续穿过判定圈时会反复入队,free 更干净(同 grenade_player_hit_probe)
	return after < before


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM TABLE: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM TABLE: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾(运行期脚本错误吃掉了一个断言段)")
		get_tree().quit(1)
