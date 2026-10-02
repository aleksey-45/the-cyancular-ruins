class_name RoyaleHost
extends MatchHost

# 大乱斗权威对局(N 人限时死斗,RoyaleServer 分支):
#  - N 个玩家(roles 1..N)散点出生;死亡 2s 复活(复用 MatchHost._handle_respawns),
#    复活点动态选"离所有存活敌人 ≥ 若干格"的地板格,出生分散。
#  - 限时 MATCH_TIME:倒计时归零 → MATCH_OVER,击杀最多者胜(平局=0)。
#  - 击杀归因:子弹/爆炸命中时把射手记到受害者 meta("last_damager"),
#    倒地边沿读 meta 计分;无源死亡(溺水/环境)不计分。
#  - 排行榜数据经 round_state 载荷下发:{scores(总击杀), names, timer(剩余秒), match_winner}。
#  - 中途掉线 = 移出对局(节点释放,排行榜标"离开"),剩余 <2 人时终局。
#  - 出生点静态几何(地板格/连通区规模/开阔优选格,含常量 OPEN_AREA_MIN / PREFER_MIN)
#    已于 2026-09-18 搬到 `core/sim/spawn_picker.gd`(SpawnPicker),这里只留同名转发。

const MATCH_TIME := 300.0        # 一局时长(秒)
const HUD_SYNC_INTERVAL := 1.0   # 倒计时/比分周期广播
const RESPAWN_CLEARANCE := 8     # 复活点与存活敌人的最小环面距离(格)
const SPAWN_CLEARANCE := 15      # 开局散点两两最小距离(格)

var _match_time := MATCH_TIME
var _cfg_match_time := 0.0             # 房主自定义时长(秒;0=默认 MATCH_TIME)
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}    # role -> Vector2i(开局散点,_init 摆位用)
var _spawned_once: Dictionary = {}    # role -> true(首次摆位走散点,之后动态选复活点)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}) -> void:
	# 散点必须在 super._init() 之前就绪:父类 _init 摆位会虚调 _spawn_cell(role),
	# 若 _round_spawns 尚为空,首次摆位拿到 (-1,-1) 且被 _spawned_once 闩锁,
	# 全体玩家挤到地图回卷角落、散点/复活设计失效(自检 S1 严重 bug)。
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	# ★ 出生点**单一来源**:常规路径由 `start_on` 算好传进来(它同时把**同一份**经 match_start
	#   广播给客户端)。这里**不得**再调一次 `plan_spawns` —— 那函数内部 `cells.shuffle()`,
	#   重算出的是**另一份**随机散点;而实际摆位读的是这一份,事后覆盖 `_round_spawns` 也改不回
	#   任何人的位置(`_spawned_once` 已闩)→ 广播给客户端的那份**从不生效**,两端开局位置不一致
	#   且完全不报错。
	#   传空 = 手工/测试路径,才走"自己算一份"的兜底。
	_round_spawns = spawns if not spawns.is_empty() else plan_spawns(role_peers.keys() + ai_roles)
	_cfg_match_time = float(options.get("match_time", 0.0))
	super._init(map_path, role_peers, options, ai_roles)


# ── 开局(在 worker 进程调用):算散点出生 → 逐角色 match_start → 建 RoyaleHost ──
# ai_roles = AI 补位 role 列表(这些 role 由服务端 AI 驱动,不发 match_start)
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# plan_spawns 依赖 current_grid:先预载网格(MatchHost._init 里再 load_grid 幂等)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_spawns(role_peers.keys() + ai_roles)
	for role in role_peers:
		# 判活:与 MatchBootstrap.start_on 同款 —— 报到与开局之间客户端可能已经断开,
		# 而定向可靠包发往正在断开的 peer 就是那条 channel 0 错误(判据见 NetBus.is_peer_live)。
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "大乱斗开始")
	# 把**同一份**散点传进宿主:它据此摆位,而上面已把同一份经 match_start 广播给客户端。
	# (原先靠事后 `host._round_spawns = spawns` 覆盖 —— 那时 `_spawned_once` 已闩上,
	#  覆盖不到任何人的位置,于是广播那份形同虚设。)
	var host := RoyaleHost.new(map_path, role_peers, options, ai_roles, spawns)
	return host


# ── 出生点几何:已搬到 `core/sim/spawn_picker.gd`(SpawnPicker)──
# 2026-09-18 逐字搬迁(3v3 要共用同一套"别出生在密封小间"的判据),这里只留转发,
# 保证本文件所有调用点(`plan_spawns` / `_spawn_cell` / `_spawn_candidates`)名字不变。
static func _grid_dims() -> Vector2i:
	return SpawnPicker.grid_dims()

# 环面格距(current_grid 尺寸版,MazeGenerator.toroidal_dist 的便捷封装)
# ★ 未随上一条搬走:`_tdist` 只服务本文件的 `_spawn_cell`(复活点选格),3v3 那一侧用
#   `SpawnPicker.cells_within`(内部走 `GridPathfinder.toroidal_dist`)—— 没有第二个调用方。
static func _tdist(a: Vector2i, b: Vector2i) -> int:
	var d := _grid_dims()
	return MazeGenerator.toroidal_dist(a, b, d.x, d.y)

static func _floor_cells() -> Array:
	return SpawnPicker.floor_cells()


static func _floor_cells_has(c: Vector2i) -> bool:
	return SpawnPicker.floor_cells_has(c)


static func _region_sizes() -> Dictionary:
	return SpawnPicker.region_sizes()


static func _roomy_floor(c: Vector2i) -> bool:
	return SpawnPicker.roomy_floor(c)


static func _spawn_candidates() -> Array:
	return SpawnPicker.spawn_candidates()


# 复活选格的池子序列(优选 → 兜底)。★ 与 `_spawn_candidates` 同款:**只是转发**,判据在
# `SpawnPicker.respawn_pools` 一处(见那边的说明:两处调用方各写一遍 = 本次修的那个病)。
static func _respawn_pools() -> Array:
	return SpawnPicker.respawn_pools()


# 开局散点:洗牌后贪心取两两环面距离 ≥ SPAWN_CLEARANCE 的 N 个格;不够就放宽(全量补齐)。
# roles = 实际参战 role 列表:缺员降级开局时 role 不连续(如剩 {1,3}),
# 必须按实际键返回,否则 spawns[role] 缺键抛错、对局卡死(自检 S2 严重 bug)。
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var d := _grid_dims()
	# ★ 散点几何已抽到 `GridPathfinder.spread_cells`(2026-09-15):单机铺地面武器也用它,
	#   两处"尽量均匀地撒点"从此是同一份实现,改一处即改两处。
	#   ★ 它内部有 shuffle() —— 本函数的既有纪律不变:**不得在广播之后再调一次**。
	var picked: Array = GridPathfinder.spread_cells(
		_spawn_candidates().duplicate(), n, SPAWN_CLEARANCE, d.x, d.y)
	# 候选不够散点(极小图 / 密封图):回退任意地板格补足,避免塞 (-1,-1) 出生到墙角。
	# ★ 这层回退与候选层的**优先级**必须留在本函数里:spread_cells 的兜底只在"传给它的池子"
	#   里补,把两层并成一个池子就等于取消优先级(会优先选到死角格)。
	# ★★ 这是"出生池缺陷"(2026-09-19)在**本文件**里唯一还剩的姐妹分支:它取的仍是
	#   `_floor_cells()`(全量、含孤立单格)。**今天不可达**,两条前提都得成立才可达:
	#   ① `spread_cells` 恒返回 `min(n, 池大小)`(已实测);② 故本分支可达 ⟺ **首档池 < 人数**
	#      —— 两图池 122 / 59,人数上限 8 ⇒ 死路。守卫:`tests/smoke/spawn_pool_smoke` 的 ⑦。
	# ★ 为什么**不**顺手把它也收窄(与用户"收掉它"的裁定不矛盾,这里情况不同):本分支恰在
	#   "池子极小时"才可达,那时收窄会让补足**补不满** ⇒ `out[role] = (-1,-1)` ⇒ 摆到地图回卷
	#   角落 —— 按用户已裁定的偏好((-1,-1) 更糟),**保持全量才是对的**。取舍已登记在报告里;
	#   ⑦ 那条守卫红了(池缩到人数以下)时由人来裁,别静默改掉。
	if picked.size() < n:
		var rest: Array = _floor_cells().duplicate()
		for c in picked:
			rest.erase(c)
		rest.shuffle()
		for c in rest:
			if picked.size() >= n:
				break
			picked.append(c)
	var out := {}
	for i in range(n):
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 出生点:首次 = 开局散点;复活 = 优选开阔格中离所有存活敌人 ≥ RESPAWN_CLEARANCE 的随机格
# (优选池不够 → 走**兜底池**,同样先保证离敌人远)。
# ★ 池子序列改为读 `SpawnPicker.respawn_pools()`(2026-09-19):原来是 `[_spawn_candidates(),
#   _floor_cells()]` —— 第二档是**全部地板格**,于是在干净池子筛空时会把人放进**孤立单格区**
#   的复活点里(与"开局被关住"同一个病)。池序列现在只有一处来源。
# 覆写(不可省):基类 `role_spawns()` 走 `_spawn_cell`,而本类的 `_spawn_cell` 第二次起返回
# **动态复活点**且带 `_spawned_once` 副作用 —— 那会把复活点当开局出生点下发。
# 本类的权威出生点就是 `_round_spawns`(由 start_on 算好传进来,与 match_start 广播的同一份)。
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(role, Vector2i(-1, -1))
	for pool: Array in _respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		var far: Array = []
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or _left.has(int(other)):
					continue
				var op: Node2D = players[other]
				if op.is_downed():
					continue
				if _tdist(c,
						Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
								int(op.global_position.y) / GameParameters.TILE_SIZE)) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				far.append(c)
		if not far.is_empty():
			return far[0]
	return Vector2i(-1, -1)


func _ready() -> void:
	super._ready()
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_match_time = _cfg_match_time if _cfg_match_time > 0.0 else MATCH_TIME
	# 本局开局昵称表进 round_state(排行榜直接展示,客户端不必另配 peer_info)
	_broadcast_round_state()


# ── 限时死斗回合逻辑(完全替代父类三局两胜制)──
func _match_round_tick(delta: float) -> void:
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				_broadcast_round_state()
			# 倒计时每 0.5s 重播:客户端切场景/建 HUD 有延迟,_ready 只广播一次会漏收
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = 0.5
				_broadcast_round_state()
		RoundState.PLAYING:
			_match_time = maxf(_match_time - delta, 0.0)
			# 复活调度(同父类:PLAYING 内倒地即安排 2s 复活)+ 复活执行
			for role in players:
				var p: Node2D = players[role]
				if p.is_downed() and not _respawn_pending.has(role):
					_respawn_pending[role] = RESPAWN_DELAY
			_handle_respawns(delta)
			# 击杀计分:倒地边沿 + 射手归因(meta)
			for role in players:
				var p: Node2D = players[role]
				if not p.is_downed() or _down_counted.get(role, false):
					continue
				_down_counted[role] = true
				# 掉落:倒地**这一刻**在原地丢下除随机保留一把外的全部武器(与基类同款 ——
				# 见 `MatchGround._drop_all_but_one` 上方的完整理由)。共用 `_down_counted`
				# 闩 ⇒ 每次死亡恰好一次;`_respawn_player` 那一支**不再**掉(会掉在出生点)。
				_drop_all_but_one(p, int(role))
				var killer := _attributed_killer(p)
				# 逐人统计(★ 2026-09-25):倒地边沿记 death(一律)与击杀(仅在归因到时)。
				# ★ 与 1v1(`MatchRound._match_round_tick`)的**口径不同,别照抄那一份**:
				#   那边是「不分死因、对方死亡都算」⇒ 传 `_opponent_of(role)`;大乱斗是
				#   **自由混战 + 归因制** ⇒ 必须传 `_attributed_killer(p)`,无归因的死亡
				#   (溺水/坠落/自杀)不计**任何人的**击杀。
				# ★ `_deaths` 那份**独立的**阵亡计数已删 —— 它与逐人表记的是同一件事,
				#   两份计数必然漂(载荷里的 `deaths` 改从逐人表构造,见 `_broadcast_round_state`)。
				_record_down(int(role), killer)
				if killer != 0:
					_scores[killer] = int(_scores.get(killer, 0)) + 1
					_broadcast_kill(killer, role)
				# Beta 时间玩法:击杀得"被击杀者余额 × 比例"(被击杀者不减;归因不到不结算)
				if time_economy != null:
					time_economy.award_kill(killer, int(role))
				_broadcast_round_state()
			# 周期广播(倒计时/比分同步)
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = HUD_SYNC_INTERVAL
				_broadcast_round_state()
			if _match_time <= 0.0:
				_finish_match()
		RoundState.MATCH_OVER:
			pass   # 结果展示阶段:客户端弹结算页,**玩家自己退**(不再有 N 秒自动回菜单)


# 击杀归因:读受害者 meta 里的射手节点(子弹直击/爆炸在命中时写入),映射回 role。
# 带时效:伤害超过 `ATTRIB_WINDOW` 毫秒前的射手不再归因(防止"被打一枪后溺水"误计)。
# ★ 时效窗口 `ATTRIB_WINDOW`(= `CombatFeedback.ATTRIB_WINDOW_MS`,3000ms)与逐人伤害的新鲜
#   阈值 `ATTRIB_FRESH_MS`(8ms)都**住在底座** `MatchState`(2026-09-25 上提;两个读者原先
#   各声明一份同名常量,子类重复声明基类成员是硬 Parse Error)。这里的引用走继承,不另立常量。
func _attributed_killer(victim: Node2D) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		var age := Time.get_ticks_msec() - int(victim.get_meta("last_damager_time"))
		if age > ATTRIB_WINDOW:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("RoyaleHost: 对局结束,胜者 role %d" % _match_winner())


# 平局(榜首并列)返回 0;其余返回最高击杀的 role
func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	var tie := false
	# ★ 候选 = **还在场的 ∪ 计过分的**(含已离开者)—— 2026-09-17 按用户要求改成"按分判胜"。
	#   原实现只遍历 `players`,而 `mark_disconnected` 会先把退出者 `erase` 掉 → 剩 1 人时
	#   **独行者必胜、与比分无关**(B 击杀再多,一退出就是 A 胜;`_scores[B]` 还在却没人读)。
	#   现在把已离开但计过分的 role 一起纳入比较:分高者胜,分平(含全场 0 杀)则平局。
	#   `_scores` **不在** `mark_disconnected` 的清理范围内,所以离开者的分数天然还在。
	var candidates := {}
	for role in players:
		candidates[int(role)] = true
	for role in _scores:
		candidates[int(role)] = true
	# ★ 已移出但对局仍在继续的人(`_left`)也必须进候选:一个 **0 杀**离开者的分数**不在**
	#   `_scores` 里(`mark_disconnected` 又把他从 `players` 里 erase 了)⇒ 他两边都不在。
	#   后果**不是**"少算一个人的分"(他的分本来就是 0),而是**少了一个并列候选**:
	#   `tie` 要成立得有 ≥2 个候选共享最高分,而幸存者只剩**一个**时他是唯一候选 ⇒ 没有第二个
	#   候选能置 `tie` ⇒ **独胜** —— 明明全场 0 杀(包括那些离开者),却被判成他赢了。
	#   `_left` 是这种离开者**唯一**的痕迹。
	# ★ 只在「幸存者 ≤ 1」这一档改变结果(≥2 个幸存者时他们**彼此**已在 0 杀上并列 ⇒ 改前
	#   改后都是平局);离开者**有分**时本来就在 `_scores` 里,照旧按分判胜 —— 两条都钉在
	#   `tests/probe/late_match_probe.gd` 的 ④/⑤/⑤b 上(⑤ 是必需的反向对照:没有它,"恒返回 0" 也能过)。
	# ★ 这一条落地后,`scenes/royale_game.gd` 那道 `and not _match_ended` 门**失去了理由**
	#   (它正是为挡这次翻转而立的)—— 但删它在 peer 的层、且需要用户点头,本批**不动**。
	for role in _left:
		candidates[int(role)] = true
	for role in candidates:
		var n: int = int(_scores.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
			tie = false
		elif n == best_n:
			tie = true
	return 0 if tie else best_role


# round_state 载荷(大乱斗版):scores=总击杀,timer=剩余秒,names=昵称表,alive/离开标记
func _broadcast_round_state() -> void:
	var names := {}
	var alive := {}
	# 昵称行覆盖:真人(peer_by_role)+ 已离开者 + **AI 补位(players 里无 peer 的 role)**
	# AI 此前没进排行榜,因为 names 只遍历 peer_by_role(真人)
	for role in peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in players:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in _left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	# alive=未倒地(倒地者 HUD 显示「复活中」,原 M4:恒 true 不可达);AI 同样参与
	for role in players:
		var p: Node2D = players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
	# `deaths` 仍是逐 role 计数(royale_hud 的排行榜按它显示"阵亡"),但来源改成**逐人统计表**
	# —— 原先的 `_deaths` 是同一件事的第二份计数(两份必然漂,且不会有任何断言变红)。
	# ★ role 集合取 `_roster()`(在场 ∪ 已离开 ∪ 有数据的):离开者的阵亡数照样要下发给
	#   排行榜(它按 role 找行),漏了会让那一行**回落到 0 且不报错**。
	var deaths := {}
	for role in _roster():
		var s: Dictionary = _stats.get(int(role), {})
		deaths[int(role)] = int(s.get("deaths", 0))
	var data := {
		"state": _round_state,
		"round": 1,
		"scores": _scores,
		"deaths": deaths,
		"rounds_won": {},          # 大乱斗无局胜,占位空(客户端 HUD 兼容读取)
		"timer": ceilf(_match_time) if _round_state == RoundState.PLAYING else _round_timer,
		"names": names,
		"alive": alive,
		"left": _left.keys(),
	}
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	# 逐人数据:与 `destroyed` / `ground_weapons` / 3v3 同款纪律 —— **只在非空时带该键**。
	# ★ 大乱斗**不带 `mvp`**(spec §3.6/§4 都没要求;结算页那一栏也不列 ACS) ——
	#   加了它就会是一个没有读者的键。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	# 基类的广播样板,只多一个"只发在线 peer"(大乱斗里掉线者仍在 peer_by_role 里待清理,
	# 而往正在断开的 peer 发包会打 channel 错误)。样板本身收在 MatchHost._rpc_all。
	# ★ 2026-09-28 起本行改走 `_send_round_state`(它内部仍调 `_rpc_all`,并多并一个 `grace` 字段)。
	_send_round_state(data)


# 房主昵称表(worker 开局后由 server_main 注入;排行榜展示用)
var _display_names: Dictionary = {}

func set_display_names(names: Dictionary) -> void:
	_display_names = names
	_broadcast_round_state()


# 中途掉线 = 移出对局:节点释放(快照/裁决不再含它),排行榜标"离开"
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
	# 剩余**玩家** <2 → 直接终局(独行者判胜)。
	# ★ 判据必须是 `players`(真人 + AI 补位)而不是 `peer_by_role`:AI 补位 role 由服务端驱动、
	#   没有 peer,压根不在 `peer_by_role` 里 —— 按 peer 数会在「2 真人 + 2 AI 掉 1 真人」时
	#   把剩下 1 真人 + 2 AI 当场判终局(实测于 2026-09-14 审计)。最后一个真人离开时
	#   server_main._on_peer_left 的 `_claims.is_empty() → quit(0)` 已兜住,不会僵持。
	if players.size() < 2 and _round_state != RoundState.MATCH_OVER:
		_finish_match()


# 子弹直击归因:命中瞬间把射手记到受害者 meta(倒地边沿时读)
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	# 归因写入统一走 CombatFeedback 的单一入口(它同时写 last_damager + last_damager_time)。
	# ★ 2026-09-27 起**基类也写同一笔**(`MatchCombat._on_bullet_hit` 第一行)⇒ 本覆写现在是
	#   **冗余的重复写**(`attribute()` 是幂等的纯元数据写入,重复调用无害);保留只为留下写点、
	#   不作废以本处与 `TeamHost` 那份为锚点的既有登记与注释。
	#   ★ **别据此把基类那一行删掉** —— 1v1 走 `MatchBootstrap` 直接建 `MatchHost`,
	#     基类那一行是它**唯一**的子弹归因写端(守卫 `tests/probe/stats_delivery_probe` ⑦)。
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


# 复活时清空归因 meta:复活后的环境死亡(溺水等)不再记到复活前最后射手头上(自检 M5)
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")

# ── 自杀脱困(K 键:royale_game 客户端 → NetBusExt.suicide_request → server_main 转发)──
# 异常卡死(嵌墙/夹缝)时主动放弃生命:走正常倒地边沿 → 2s 复活;先清 last_damager 归因,
# 自杀不计入任何人击杀(哪怕刚被人打过),只累积自己的阵亡数。
func request_suicide_role(role: int) -> void:
	if _round_state != RoundState.PLAYING:
		return
	var p: Node2D = players.get(int(role))
	if p == null or not is_instance_valid(p) or p.is_downed():
		return
	for m in ["last_damager", "last_damager_time"]:
		if p.has_meta(m):
			p.remove_meta(m)
	var combat: Node = p.get_node_or_null("Combat")
	if combat != null and combat.has_method("force_down"):
		combat.force_down()
