extends Node

# 「掉落武器留在**死亡点**」探针(场景模式,`-s` 做不了 —— 要真建宿主)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/death_drop_probe.tscn
# 期望:每条 [dd] ok,末行 "DEATH DROP PROBE: ALL-OK"。
#
# ═══ 为什么需要它(用户 2026-09-21)═══
# 「掉落的武器应该在死亡后直接原地掉落,而不是复活后在玩家出生点掉落」。
# 旧实现把这个错法藏得**完全静默**:`_respawn_player` 先 `p.global_position = 出生点`、
# **再**调 `_drop_all_but_one`(它取 `p.global_position`)⇒ 全掉在出生点 —— 而两处的注释
# 都写着「死亡点」。没有任何报错,既有断言也一条都照不到(别处的位置断言只查**玩家**的坐标)。
#
# ★ 本探针的另一半同样重要:**就算**把掉落留在复活流程里、只改成「用死亡时记下的那一格」,
#   也还是错的 —— 尸体在 2s 倒地窗里继续走物理(重力/击退衰减/滑行),到复活那一刻它早已
#   不在死亡的那一格了。所以「掉在 D」必须在**复活之前**断言(下面 ①②),那才是
#   「死亡后直接原地」。③ 再钉复活那一侧:不再掉第二次、且保留的那把仍在手上。
#
# ═══ 做法 ═══
# 与 grenade_player_hit_probe / team_host_probe 同一手法:真建宿主,但 **role_peers 传空**
# —— 不建玩家、不排 peer、所有 `rpc_id` 无对象(广播静默早退,不会在无多人连接时报错)。
# 玩家由本探针自己摆进 `host.players`,宿主自己的物理帧关掉(只手动推一帧状态机)。
# ★ 三个模式各走一遍:三处倒地边沿是**同一个契约的三份落地**(基类 `_respawn_player`
#   那一支已删),少写一处就静默退化成「该模式死亡不掉武器」。
# ★ 地图钉死 `factory1v1.cyrm`(不钉图的探针每进程随机选一份,跨进程输出不可比);
#   出生点也**显式传**(大乱斗 / 3v3 的 spawns 参数),不依赖任何 shuffle。
#
# ⚠ 判据 grep 文本 "DEATH DROP PROBE: ALL-OK"(不只看退出码:场景探针在脚本报错时
#   仍然会 --quit-after 到点 exit 0,只看退出码会把「根本没跑完」读成「通过」)。

const MAP := "res://maps/factory1v1.cyrm"

# 死亡点与出生点。地图标定的 `# player 17 65` / `# player2 133 64`:环面距离 34 格(2176px),
# 远大于下面用的判定半径(2 格 = 128px)⇒「掉在 D」与「掉在出生点」**必然可区分**。
const DEATH_CELL := Vector2i(133, 64)
const HOME_CELL := Vector2i(17, 65)

const NEAR_CELLS := 2.0        # 「就在旁边」的判定半径(格);掉落物生成在 D + (0,-12)px
const KEEP_ONE := 3            # 倒地前塞进背包的枪数 → 应掉 KEEP_ONE - 1 把

const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
# 3v3 出生点:显式给死(不走 `plan_team_spawns`,那里面有 shuffle)。role 1 的家 = HOME_CELL。
const TEAM_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65),
		4: Vector2i(133, 64), 5: Vector2i(136, 64), 6: Vector2i(139, 64)}
const ROYALE_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65)}

var _failures: Array[String] = []


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[dd]   ok   %s" % msg)
	else:
		_failures.append(msg)
		print("[dd]   FAIL %s" % msg)


func _ready() -> void:
	# 三个模式各一具宿主。构建方式照各自既有的探针:
	#   · 1v1    = MatchHost(map, {})                       —— grenade_player_hit_probe
	#   · 大乱斗 = RoyaleHost(map, {}, {}, [], spawns)      —— royale_disconnect_count_probe
	#   · 3v3    = TeamHost(map, {}, {}, [], spawns, teams) —— team_host_probe
	_run_phase("1v1", MatchHost.new(MAP, {}), HOME_CELL)
	_run_phase("大乱斗", RoyaleHost.new(MAP, {}, {}, [], ROYALE_SPAWNS), HOME_CELL)
	_run_phase("3v3", TeamHost.new(MAP, {}, {}, [], TEAM_SPAWNS, TEAMS), HOME_CELL)

	if _failures.is_empty():
		print("DEATH DROP PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("DEATH DROP PROBE: FAIL(%d 条)" % _failures.size())
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)


# 一个模式的完整三相:① 时机(倒地边沿就掉)② 位置(在 D、不在出生点)③ 复活(不再掉第二次)。
func _run_phase(tag: String, host: Node, home_cell: Vector2i) -> void:
	print("[dd] ── %s ──" % tag)
	add_child(host)
	# ★ 关掉宿主自己的 `_physics_process`:本探针只**手动**推一帧状态机。不关的话帧末那一跑
	#   会让快照/复活调度来搅局,读数就不是「我这一帧」的了(与 team_host_probe 同款理由)。
	host.set_physics_process(false)

	var ts: int = GameParameters.TILE_SIZE
	var d_pos := Vector2(float(DEATH_CELL.x) * ts + ts * 0.5, float(DEATH_CELL.y) * ts + ts * 0.5)
	var home_pos := Vector2(float(home_cell.x) * ts + ts * 0.5, float(home_cell.y) * ts + ts * 0.5)
	var near := float(ts) * NEAR_CELLS
	var span := Vector2i(int(GameParameters.MAP_WIDTH / ts), int(GameParameters.MAP_HEIGHT / ts))
	var gap := GridPathfinder.toroidal_dist(DEATH_CELL, home_cell, span.x, span.y)
	_check(float(gap) * float(ts) > near * 4.0,
			"[%s][仪器] 死亡点与出生点相距 %d 格(必须远大于判定半径 %.0fpx,否则下面两条恒真)"
			% [tag, gap, near])

	var p: Node2D = (preload("res://scenes/player/player.tscn") as PackedScene).instantiate()
	host.add_child(p)
	p.global_position = d_pos
	p.set_physics_process(false)      # 本探针只验掉落,不验玩家的物理
	host.players[1] = p
	# 跳过 COUNTDOWN:复活调度只在 PLAYING 里安排(倒计时里倒地不会被排上)。
	host._round_state = MatchHost.RoundState.PLAYING
	# 开局那批散布是「背景」:下面的断言必须在**新增**的那几把上做
	# (出生点附近本来就可能躺着开局撒的一把 —— 直接查「附近有没有枪」会假红)。
	p.weapons.set_initial_inventory([1, 2, 3])
	var before := _insts(host)
	_check(before.size() > 0,
			"[%s][仪器] 开局已散布 %d 件(下面的新增判定需要一个非空基线)" % [tag, before.size()])

	# ── 推一帧状态机:倒地边沿 ──
	(p.get_node("Combat") as Node).force_down()
	host._match_round_tick(0.016)

	# ── ① 时机:掉落发生在**复活之前** ──
	_check(p.is_downed(), "[%s] ① 这一帧玩家仍是倒地态(复活还没到)" % tag)
	var pending := float(host._respawn_pending.get(1, -1.0))
	_check(pending > 1.0,
			"[%s] ★ ① 复活已排期但**远未到点**(还剩 %.2fs)—— 即掉落发生在倒地那一刻"
			% [tag, pending])
	var dropped := _new_insts(host, before)
	_check(dropped.size() == KEEP_ONE - 1,
			"[%s] ★ ① 倒地就掉了 %d 把(背包 %d 把 → 留 1 掉 %d;实得 %d)"
			% [tag, KEEP_ONE - 1, KEEP_ONE, KEEP_ONE - 1, dropped.size()])
	_check(p.weapons.inventory.held.size() == 1 and p.weapons.current_weapon() != null,
			"[%s] ★ ① 保留的那把仍握在手上(背包 %d 把、当前武器 %s)"
			% [tag, p.weapons.inventory.held.size(),
					"有" if p.weapons.current_weapon() != null else "无"])

	# ── ② 位置:在死亡点旁边、**不在**出生点旁边 ──
	# 判据走**生产那一份**查找(`GroundWeaponField.nearest_within`:环面最短距离 + 与拾取判定
	# 同口径的半径)而不是自己算绝对距离 —— 自算的话跨接缝那一侧会判错。
	# ★ `exclude` 传「除新掉的以外全部」而不是留空:开局散点**可能**恰好落在 DEATH_CELL
	#   那一格上(`spread_cells` 从 ~800 个地板格里挑 12 个 ⇒ 约 1.5% 概率),那件背景武器
	#   离 d_pos 是 0px、比新掉的(12px)更近 ⇒ 不排除的话会**偶发假红**。
	#   排除背景后本条语义反而更准:「这批**刚掉的**武器就在 D 附近」(而不是"D 附近最近的那件")。
	var at_d: Dictionary = host.ground_weapons.nearest_within(
			d_pos, near, _all_but(host, dropped))
	_check(not at_d.is_empty() and dropped.has(int(at_d["inst"])),
			"[%s] ★ ② 死亡点 %.0fpx 内躺着**刚掉的**那把(inst=%s,新掉的是 %s)"
			% [tag, near, str(at_d.get("inst", -1)), str(dropped)])
	var at_home: Dictionary = host.ground_weapons.nearest_within(
			home_pos, near, _all_but(host, dropped))
	_check(at_home.is_empty(),
			"[%s] ★ ② 出生点 %.0fpx 内**没有**任何掉落的武器(实得 inst=%s)"
			% [tag, near, str(at_home.get("inst", -1))])

	# ── ③ 复活那一侧:不再掉第二次,保留的那把仍在手上 ──
	# ★ 走**生产**的复活入口(不是直接调 `_respawn_player`)—— 与「复活调度」同一条路。
	host._handle_respawns(2.0)
	_check(not p.is_downed(), "[%s] ③ 复活了(不再倒地)" % tag)
	_check(p.global_position.distance_to(home_pos) < 2.0,
			"[%s] ③ 复活后站到了本局出生点(距 %.1fpx)"
			% [tag, p.global_position.distance_to(home_pos)])
	_check(p.weapons.inventory.held.size() == 1 and p.weapons.current_weapon() != null,
			"[%s] ★ ③ 复活后手上**仍是倒地时保留的那一把**(不是空手;背包 %d 把、当前武器 %s)"
			% [tag, p.weapons.inventory.held.size(),
					"有" if p.weapons.current_weapon() != null else "无"])
	var all_dropped := _new_insts(host, before)
	_check(all_dropped.size() == dropped.size(),
			"[%s] ★ ③ 复活**没有再掉一次**(自本次死亡起掉落总数仍是 %d,实得 %d)"
			% [tag, dropped.size(), all_dropped.size()])
	# ★ 反向那一半:旧实现正是在**这里**掉的 —— 复活后出生点旁边会冒出一批。
	var at_home_after: Dictionary = host.ground_weapons.nearest_within(
			home_pos, near, _all_but(host, all_dropped))
	_check(at_home_after.is_empty(),
			"[%s] ★ ③ 复活后出生点 %.0fpx 内**依然没有**掉落物(实得 inst=%s)"
			% [tag, near, str(at_home_after.get("inst", -1))])


# ── 工具 ──

# 场上所有地面武器的 inst(快照用)。
func _insts(host: Node) -> Array:
	var out: Array = []
	for e in host.ground_weapons.entries:
		out.append(int(e["inst"]))
	return out


# `before` 里没有的那些 inst(= 本次操作新生成的)。
func _new_insts(host: Node, before: Array) -> Array:
	var out: Array = []
	for inst in _insts(host):
		if not before.has(inst):
			out.append(inst)
	return out


# `keep` 之外的全部 inst(`nearest_within` 的 exclude 参数要的是「排除谁」)。
func _all_but(host: Node, keep: Array) -> Array:
	var out: Array = []
	for inst in _insts(host):
		if not keep.has(inst):
			out.append(inst)
	return out
