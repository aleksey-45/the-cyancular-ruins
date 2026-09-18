class_name TeamHost
extends MatchHost

# 3v3 团队对抗权威对局(第三个模式宿主,与 RoyaleHost 平级)。
#  - 6 人(两队各 3)、三局两胜、每队先到 TEAM_KILLS_TO_WIN 击杀赢一局、局间**整队换边**;
#    局内死亡 2s 复活;击杀后**只把击杀者本人**送回本方出生点(队友不动)。
#  - 计分**不分死因**:任一玩家倒地 → 对方队 +1(枪杀/爆炸/溺水/自伤/队友误炸一律如此)。
#  - 子弹穿透队友(在 MatchCombat 裁决层,按 role 判);**爆炸对队友满效**(现状行为,未改)。
#  - 队伍归属来自 `MatchState._team_of`(由大厅经 `--teams` 显式传入)。
#
# ★ 继承链与中间层纪律同 RoyaleHost:本类是末端子类,生命周期钩子只能出现在这里。
# ★ `_init` 顺序不可整理:父类 `_init` 会**虚调** `_spawn_cell(role)` 摆位,那时 `_round_spawns`
#   必须已就绪(与 RoyaleHost 同一个坑,见 royale_host.gd:35-37)。

const TEAM_KILLS_TO_WIN := 9     # ★ 不能叫 KILLS_TO_WIN:基类 MatchState 已有该常量,同名遮蔽会报错
const TEAM_ROUNDS_TO_WIN := 2    # ★ 同上,基类是 ROUNDS_TO_WIN
const SPAWN_CLEARANCE := 15      # 两个基座的最小环面距离(格)
const TEAMMATE_CLEARANCE := 3    # 队内三人最小间距(格):够散开,又不至于走出"队形"
const SPAWN_BASE_RADIUS := 30    # 基座附近取点半径(格);池子不够会退回全量候选
const SPAWN_MAX_TRIES := 12      # 散点重试次数(见 plan_team_spawns 的说明;每份只要 ~几十微秒)
const RESPAWN_CLEARANCE := 8     # 复活点离**存活敌人**的最小环面距离(格)
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS   # 击杀归因时效(3s),与 RoyaleHost 同源

var _round_spawns: Dictionary = {}   # role -> Vector2i(本局出生点,与 match_start 广播的同一份)
var _swap_spawns: Dictionary = {}    # role -> Vector2i(换边后的点;两队点集整体对调)
var _spawned_once: Dictionary = {}   # role -> true(首次摆位走出生点,之后走动态复活点)
var _left: Dictionary = {}           # role -> true(已移出对局;排行榜/比分判据用)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:
	# 散点必须在 super._init() 之前就绪(父类 _init 会虚调 _spawn_cell 摆位)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_team_of = teams.duplicate()
	# ★ spawns 传空 = 手工/测试路径,才自己算一份。常规路径由 start_on 算好传进来 ——
	#   `plan_team_spawns` 内部走 `spread_cells`(有 shuffle),重算会得到**另一份**散点,
	#   而广播给客户端的是 start_on 那一份(与 RoyaleHost 完全同款纪律)。
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
	_swap_spawns = compute_swap_spawns(_round_spawns, _team_of)
	# ★ 第 5 个实参是 `teams`,**不是** `spawns`(`RoyaleHost` 那两个参数同名易混)。
	#   传错的后果不是崩溃而是"整局队伍判定全错":`_team_of` 被塞成 `{role: Vector2i}`,
	#   `team_of()` 里 `int(Vector2i)` 报 `Nonexistent 'int' constructor` 并让该函数当场返回 0
	#   → 子弹不穿队友、`team_map()` 下发空表。守卫:`tests/team_host_probe` 的 ③ 直读
	#   `_team_of` 逐值断言 `typeof(...) == TYPE_INT`(只断言"非空"抓不到这一档)。
	super._init(map_path, role_peers, options, ai_roles, teams)


# ── 开局(在 worker 进程调用):算散点 → 逐角色 match_start → 建 TeamHost ──
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_team_spawns(teams)
	for role in role_peers:
		# 判活:报到与开局之间客户端可能已断开,定向可靠包发往正在断开的 peer 就是那条
		# channel 0 错误(判据见 NetBus.is_peer_live,与 RoyaleHost.start_on 同款)
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "3v3 开始")
	# 把**同一份**散点传进宿主:它据此摆位,而上面已把同一份经 match_start 广播给客户端
	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# 按队出生散点:① 取两个相距 ≥ SPAWN_CLEARANCE 的基座;② 每队基座附近取 3 个散点(队内 ≥
# TEAMMATE_CLEARANCE)。→ 队内聚、队间远。
# ★ 与 `RoyaleHost.plan_spawns` 同一条纪律:**不得在广播之后再调一次**(内部有 shuffle)。
#
# ★★ 为什么外面套了一层重试循环(偏 brief 一处,**已记入 task-4-report**):
#   上面那两句话**并不**蕴含"队间远"。半径 30 的点云在 150×100 的环面上重叠得很厉害,
#   而基座只保证"相距 ≥ 15 格" —— 实测 200 次里 **123 次(61.5%)队间最小距 ≤ 队内最大距**,
#   最坏情况两队有人落在**同一格**(队间距 = 0)。散点本来就是洗牌撒出来的,故:
#   多试几份、挑一份真正满足"队间远"的;试满 SPAWN_MAX_TRIES 次仍不满足,就退回其中
#   **最好**的那一份(绝不返回空表 —— 那会让 `start_on` 的 `spawns[role]` 缺键)。
#   ★ 六个常量与签名一个没动;实测 200/200 满足(最差队间距从 0 抬到 20)。
static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	var best := {}
	var best_margin := -(1 << 30)   # ★ GDScript 不接受 `-1 << 30`(移位只收正操作数)
	for _attempt in range(SPAWN_MAX_TRIES):
		var cand := _plan_team_spawns_once(teams)
		var margin := _spawn_margin(cand, teams)
		if margin > best_margin:
			best_margin = margin
			best = cand
		if margin > 0:
			break
	return best


# 单次散点(挑中就用它)。★ 本函数**逐字**来自 brief;重试与"哪一份更好"的判断在外面。
static func _plan_team_spawns_once(teams: Dictionary) -> Dictionary:
	var d := SpawnPicker.grid_dims()
	var bases: Array = GridPathfinder.spread_cells(
			SpawnPicker.spawn_candidates().duplicate(), 2, SPAWN_CLEARANCE, d.x, d.y)
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if by_team.has(t):
			by_team[t].append(int(role))
	var out := {}
	for t in [1, 2]:
		(by_team[t] as Array).sort()   # 确定性:同队的 role 按号升序拿点
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out


# "队间远"裕度 = 队间最小环面距 − 队内最大环面距(> 0 = 满足;越大越散)。
# ★ 只在 `plan_team_spawns` 内部用来挑那一份,**不对外**;跨队/队内按 `teams` 分,不按 role 号。
static func _spawn_margin(spawns: Dictionary, teams: Dictionary) -> int:
	if spawns.size() < 2:
		return 1   # 不足两人 = 没有"队间/队内"可言,视为满足(别让空表把重试跑满)
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 1 << 30
	var roles: Array = spawns.keys()
	roles.sort()
	for i in range(roles.size()):
		for j in range(i + 1, roles.size()):
			var dist := MazeGenerator.toroidal_dist(spawns[roles[i]], spawns[roles[j]], d.x, d.y)
			if int(teams.get(roles[i], 0)) == int(teams.get(roles[j], 0)):
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	return min_cross - max_in


# 换边用的点集:把两个队的点**整体对调**(队 A 第 i 人 ↔ 队 B 第 i 人)。
# ★ 前提:两队人数严格相等(满 6 人开局保证)。不相等 → 返回空表,`_start_next_round` 据此**不换边**
#   (宁可这局不换,也不要把人送到错的一侧)。纯函数,可 `-s` 测。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a: Array = []
	var b: Array = []
	for role in teams:
		if int(teams[role]) == 1:
			a.append(int(role))
		else:
			b.append(int(role))
	a.sort()
	b.sort()
	var out := {}
	if a.is_empty() or a.size() != b.size():
		return out
	for i in range(a.size()):
		out[a[i]] = spawns.get(b[i], Vector2i(-1, -1))
		out[b[i]] = spawns.get(a[i], Vector2i(-1, -1))
	return out


# 本局各 role 的出生点(供 match_sync 下发)。★ 覆写不可省:基类实现走 `_spawn_cell`,
# 而本类的 `_spawn_cell` 第二次起返回**动态复活点**且带 `_spawned_once` 副作用
# (与 RoyaleHost.role_spawns 同一个坑)。
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


# 队伍表的只读取法(给 `match_sync` 下发用)。★ 客户端**不能**自己从 roles 推导。
func team_map() -> Dictionary:
	var out := {}
	for role in _team_of:
		out[int(role)] = int(_team_of[role])
	return out


func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(int(role), Vector2i(-1, -1))
	return _respawn_cell_for(int(role))


# 复活点:优选开阔格中,离**所有存活敌人** ≥ RESPAWN_CLEARANCE 的第一个(池子洗牌后取首个)。
# ★ 判据是"离敌人远",**不是**"离所有玩家远" —— 队友在附近复活是好事(royale 那条是全员互敌,
#   故它判所有存活玩家;这里语义变了,别照抄)。
# ★ 池子来源:`SpawnPicker` 的三张缓存是**每进程**的 `static var`,**从不主动清**。
#   本模式 worker 一局一进程、且用固定图(`MatchBootstrap.PVP_MAP`)→ 不需要 `reset_cache()`。
#   **若将来同一个进程里换图**(例如大厅进程也建宿主),必须显式 `SpawnPicker.reset_cache()`,
#   否则会**静默**沿用旧图的地板格池子(不报错,只是出生点全落在上一张图的格上)。
func _respawn_cell_for(role: int) -> Vector2i:
	for pool: Array in [SpawnPicker.spawn_candidates(), SpawnPicker.floor_cells()]:
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or same_team(role, int(other)):
					continue   # 队友不用躲(语义与 royale 那条"离所有存活玩家远"不同,见上面注释)
				var op: Node2D = players[other]
				if op == null or not is_instance_valid(op) or op.is_downed():
					continue
				var oc := Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
						int(op.global_position.y) / GameParameters.TILE_SIZE)
				if MazeGenerator.toroidal_dist(c, oc, SpawnPicker.grid_dims().x,
						SpawnPicker.grid_dims().y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				return c
	return Vector2i(-1, -1)


# 某 role 的**对方队号**(计分归属用)。无队伍 → 0。
func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


# ── 回合机(团队版:计分键 = **队号**,不是 role)──
# ★ 为什么整段覆写而不是改基类:`MatchRound._match_round_tick` 的计分键、胜负判据、复位对象
#   三方都绑在 role 上,逐处插分支会让 1v1 那条路长出团队语义(1v1 的探针照样绿,但已经变了)。
func _match_round_tick(delta: float) -> void:
	for role in players:
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁(与基类同款:旧实现把它塞在闩锁内,曾导致复活永不安排)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 击杀定义(继承 1v1 的"不分死因"):任一玩家倒地 → **对方队** +1。
		# 队友误炸也照此(用户裁定):乱扔雷 = 给对面送分,惩罚是自带的,不必另立规则。
		var scorer := _enemy_team_of(int(role))
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			# kill_event 的载荷仍是 **role 粒度**(射手 = 归因得到,0 = 无归因),
			# 客户端用 match_sync 的队伍表映射到队 —— 协议不为团队改字段(设计 §6)。
			# ★ 归因不到(killer = 0)时**照样广播**:计分归属与"有没有击杀者"是两件事,
			#   给 0 加守卫会让"队友误炸/溺水导致的倒地"在客户端完全无声。
			_broadcast_kill(_attributed_killer(p), int(role))
			_broadcast_round_state()
			_reset_killer_only(p, int(role))
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
		RoundState.PLAYING:
			_handle_respawns(delta)
			for t in [1, 2]:
				if int(_scores.get(t, 0)) >= TEAM_KILLS_TO_WIN:
					_round_over(t)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass


func _round_over(winner_team: int) -> void:
	_last_round_winner = winner_team
	_rounds_won[winner_team] = int(_rounds_won.get(winner_team, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()


# 换局:局胜到 TEAM_ROUNDS_TO_WIN → MATCH_OVER;否则**整队换边** + 下一局。
# ★ 与基类的三处实质差异:
#   ① 局胜的键是**队号**(基类按 role 查,团队下永远是 0 → 永远打不完);
#   ② 换边 = `_round_spawns` 与 `_swap_spawns` **整体互换**(基类只翻一个 `_side_swap` 布尔);
#   ③ 换边后要**清 `_spawned_once`** —— 否则 `_spawn_cell` 走"动态复活点"分支,
#      开局六个人会被撒到"离敌人远"的随机格,而不是本方出生点。
#
# ★★ 本覆写存在的**首要理由**是消灭一个过渡态(Task 5/6 期间登记在案):
#   在此之前 `_match_round_tick` 的 ROUND_OVER 分支虚分派到的是**基类** `MatchRound._start_next_round`,
#   而 `_rounds_won` 的键早已是**队号** —— 队号 {1,2} 与 role 1/2 **字面撞号**,
#   "1 队赢 2 局"被基类读成"role 1 赢 2 局":结果碰巧对,但不是语义对齐(且基类**不换边**)。
#   守卫:`tests/team_host_probe` ⑨(源码级:本函数确实声明在这里;行为级:把状态机推过
#   ROUND_OVER 后出生点已对调、`_side_swap` 一路未被翻 —— 基类那条两样都做不到)。
#
# ★ 与 `_match_winner()` 的关系(**不是重复,是互补**):本函数判的是"**要不要**进 MATCH_OVER"
#   (答案只能是"进/不进"),`_match_winner()` 判的是"进去之后**报哪一队**"。两处都要读
#   `TEAM_ROUNDS_TO_WIN`,但**不能互换** —— `_match_winner()` 恒返回 1 或 2(无胜者时退回
#   "局胜高者"),拿它跟阈值比就是本仓反复踩过的"把队号当阈值"。
func _start_next_round() -> void:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	_reset_world_and_clear_dynamics()
	# ★ 两队人数不等时 `_swap_spawns` 是空表 → **不换边**(宁可这局不换,也不要把人送到错的一侧)
	if not _swap_spawns.is_empty():
		var tmp := _round_spawns
		_round_spawns = _swap_spawns
		_swap_spawns = tmp
	# ★ 这一行不能省:不清的话下面 `_respawn_player` → `_spawn_cell` 走"动态复活点"分支,
	#   六个人被撒到地图各处,而**不是**本方(换边后的)出生点。探针 ⑧/⑨ 的位置断言专抓它。
	_spawned_once.clear()
	_round_num += 1
	_scores = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()


# 对局胜者(**队号**):先到 `TEAM_ROUNDS_TO_WIN` 局胜的那一队;都还没到(只有"整队走光"
# 提前收场那一支能走到,见 Task 8 的 `_finish_match`)则退回"局胜高者"。
# ★ 本函数是 `TEAM_ROUNDS_TO_WIN` 的读者之一(Task 7 的 `_start_next_round` 是另一处)。
#   没有这个阈值分支时,改常量**一点行为都不变** —— 那正是本仓要防的"静默无效"。
# ★★ 下面那两个 `2` **不是**阈值,是**队号**,别把它们换成 `TEAM_ROUNDS_TO_WIN`:
#   今天两者都等于 2,换错了不报错,而 Task 7 一旦把档位改成 3,返回给客户端的就会是
#   "3 队"这种不存在的队号(且照旧不报错)。
func _match_winner() -> int:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# round_state:`scores` / `rounds_won` 的**键是队号**;`winner` / `match_winner` 也是队号。
# ★ 队伍表**不在这里**下发:只走 `match_sync`(进场/重连各拉一次)。两条投递路径是自检 B2 那类
#   事故的形状,别为了"顺手"加第二条。
func _broadcast_round_state() -> void:
	var data := {
		"state": _round_state,
		"round": _round_num,
		"scores": _scores,
		"rounds_won": _rounds_won,
		"timer": _round_timer,
	}
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	_rpc_all("round_state", [data])


# ── 击杀归因(自带一份,不从基类上提)──
# `kill_event` 要带"是谁杀的"(归因不到就带 0),Task 6 的"只复位击杀者"也读它,故在这里落。
# ★ 为什么自带而不是把 `RoyaleHost._attributed_killer` 上提到基类:基类的归属由
#   `tests/kh_l5_probe.gd` 的"新接口归属(基类不得含子类方法)"反向断言守着,为省 12 行去动
#   那条探针不划算;两份都不足 15 行,读的还是同一个 meta(单一来源仍是 CombatFeedback)。
func _attributed_killer(victim: Node2D) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) > ATTRIB_WINDOW:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0


# 击杀后复位:**只把击杀者本人**送回本方出生点(保留血量,不治疗),队友不动。
# (1v1 是"另一方即活方回出生点";三人队里"活方"没有唯一解 —— 用户裁定只动击杀者。)
# ★ 三个"不复位"的档,一个都不能省:
#   · 无归因(溺水/自伤/K 自杀)→ killer 0;
#   · 队友互炸(归因指向同队的人)→ 得分照样给对方队,但**不把队友送回出生点**;
#   · 击杀者自己也倒了(同归于尽)→ 他去走自己的复活流程。
# ★ 提前落地说明:本函数按 Task 6 的语义**整段落在这里**(Task 5 的 `_match_round_tick`
#   要调它,留桩会在运行期报未定义函数);Task 6 剩下的只是它那三条专属断言的探针。
func _reset_killer_only(victim: Node2D, victim_role: int) -> void:
	var killer_role := _attributed_killer(victim)
	if killer_role == 0:
		return
	if same_team(killer_role, victim_role):
		return
	var killer: Node2D = players.get(killer_role)
	if killer == null or not is_instance_valid(killer) or killer.is_downed():
		return
	var spawn: Vector2i = _round_spawns.get(killer_role, Vector2i(-1, -1))
	# ★ 兜底值 `(-1,-1)` 必须**在这里拦掉**:不拦的话下面会算出 `(-32,-32)` 并把击杀者
	#   送到地图外 —— 不报错、人凭空消失(与 `_respawn_cell_for` 的 `(-1,-1)` 契约同款)。
	#   正常路径恒有值(`plan_team_spawns` / `start_on` 保证),这条只在表坏掉时生效。
	if spawn.x < 0:
		push_error("TeamHost: role %d 不在 _round_spawns 里,击杀者复位跳过" % killer_role)
		return
	var ts := GameParameters.TILE_SIZE
	killer.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	killer.velocity = Vector2.ZERO
	if killer.has_method("cancel_jump_state"):
		killer.cancel_jump_state()


# ── 中途掉线(宽限期到点后由 server_main 调)—— 移出对局,但**整队走光才终局** ──
# ★ 判据是"某个队一个人都不剩",**不是** royale 那条"players.size() < 2":
#   6 人局里掉 1 个就终局 = 剩下的人白打(用户裁定:该队少人继续打)。
# ★ 也不能数 `peer_by_role`(那是"有网络连接的人"):3v3 没有 AI 补位,两者当前同键集,
#   但判据写成"每队还剩几个**在场上**的人"才表达得出这条规则的本意。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true
	_respawn_pending.erase(role)
	_down_counted[role] = true
	if players.has(role):
		var p: Node = players[role]
		if is_instance_valid(p):
			p.queue_free()
		players.erase(role)
	if input_sources.has(role):
		input_sources.erase(role)
	peer_by_role.erase(role)
	_broadcast_round_state()
	if _round_state == RoundState.MATCH_OVER:
		return
	# 还有人的队:统计(队伍表里没出现的队号不算)
	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2:
		_finish_match()


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())
