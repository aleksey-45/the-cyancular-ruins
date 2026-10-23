class_name RoyaleHost
extends MatchHost

# 大乱斗权威对局(N 人限时死斗):roles 1..N 散点出生,死亡 2s 复活,复活点动态选「离所有存活敌人 ≥ 若干格」的地板格。
# ★ 限时 MATCH_TIME:倒计时归零 → MATCH_OVER,击杀最多者胜(并列 = 0)。★ 击杀归因靠受害者 meta(last_damager),无源死亡不计分。
# ★ 排行榜数据经 round_state 下发(scores / names / timer / match_winner)。★ 中途掉线 = 移出对局(节点释放,排行榜标「离开」),
# 剩余 < 2 人时终局。★ 出生点静态几何已搬到 core/sim/spawn_picker.gd;散点/复活选格的计算在 server/hosts/royale_spawn.gd
# (RoyaleSpawn),这里只留生命周期、_round_spawns/_spawned_once 的状态与同名转发。

const MATCH_TIME := 300.0        # 一局时长(秒)
const HUD_SYNC_INTERVAL := 1.0   # 倒计时/比分周期广播

var _match_time := MATCH_TIME
var _cfg_match_time := 0.0             # 房主自定义时长(秒;0=默认 MATCH_TIME)
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}    # role -> Vector2i(开局散点,_init 摆位用)
var _spawned_once: Dictionary = {}    # role -> true(首次摆位走散点,之后动态选复活点)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}) -> void:
# ★ 散点必须在 super._init() 之前就绪:父类 _init 摆位会虚调 _spawn_cell(role),那时 _round_spawns 若还空,首次摆位会拿到
# (-1,-1) 并被 _spawned_once 闩死 ⇒ 全体玩家挤到地图回卷角落,散点/复活设计失效。
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
# ★ 出生点单一来源:常规路径由 start_on 算好传进来(它同时把同一份经 match_start 广播给客户端);传空 = 手工/测试路径才自己算。
# 这里不得再调一次 plan_spawns —— 它内部 cells.shuffle(),重算出的是另一份随机散点,而实际摆位读的是这一份,事后覆盖
# _round_spawns 也改不回任何人的位置(_spawned_once 已闩)⇒ 广播给客户端的那份从不生效、两端位置不一致,且完全不报错。
	_round_spawns = spawns if not spawns.is_empty() else plan_spawns(role_peers.keys() + ai_roles)
	_cfg_match_time = float(options.get("match_time", 0.0))
	super._init(map_path, role_peers, options, ai_roles)


# ── 开局(在 worker 进程调用):算散点出生 → 逐角色 match_start → 建 RoyaleHost。ai_roles = AI 补位 role 列表(由服务端 AI 驱动,不发 match_start)。──
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()

	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_spawns(role_peers.keys() + ai_roles)
	for role in role_peers:

		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "大乱斗开始")

	var host := RoyaleHost.new(map_path, role_peers, options, ai_roles, spawns)
	return host



# ── 散点 ── 实现(SPAWN_CLEARANCE / 候选层回退的逐条「为什么」)在 RoyaleSpawn.plan_spawns。
# ★ 保留静态转发而不是让调用点直接引 RoyaleSpawn:start_on 与 _init 的调用面零 diff,搬运不牵连调用方。
static func plan_spawns(roles: Array) -> Dictionary:
	return RoyaleSpawn.plan_spawns(roles)


# 出生点:首次 = 开局散点(权威是 _round_spawns);复活 = 优选开阔格中离所有存活敌人 ≥ RESPAWN_CLEARANCE 的随机格。
# ★ role_spawns 覆写不可省 —— 基类走 _spawn_cell,而本类的 _spawn_cell 第二次起返回动态复活点且带 _spawned_once 副作用。
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


# ★ _spawned_once 的「首次」闩与 _round_spawns 的状态留在宿主;选格计算在 RoyaleSpawn.respawn_cell。
func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(role, Vector2i(-1, -1))
	return RoyaleSpawn.respawn_cell(role, players, _left)


func _ready() -> void:
	super._ready()
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_match_time = _cfg_match_time if _cfg_match_time > 0.0 else MATCH_TIME

	_broadcast_round_state()



func _match_round_tick(delta: float) -> void:
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				_broadcast_round_state()
# 倒计时每 0.5s 重播:客户端切场景/建 HUD 有延迟,_ready 只广播一次会漏收。
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = 0.5
				_broadcast_round_state()
		RoundState.PLAYING:
			_match_time = maxf(_match_time - delta, 0.0)

			for role in players:
				var p: Node2D = players[role]
				if p.is_downed() and not _respawn_pending.has(role):
					_respawn_pending[role] = RESPAWN_DELAY
			_handle_respawns(delta)

			for role in players:
				var p: Node2D = players[role]
				if not p.is_downed() or _down_counted.get(role, false):
					continue
				_down_counted[role] = true
# 掉落:倒地这一刻在原地丢下除随机保留一把外的全部武器(理由见 MatchGround._drop_all_but_one);共用 _down_counted 闩 ⇒ 每次死亡恰好一次。
				_drop_all_but_one(p, int(role))
				var killer := _attributed_killer(p)
# 逐人统计:倒地边沿记 death(一律)与击杀(仅在归因到时)。★ 口径与 1v1 不同、别照抄那一份:那边是「不分死因、对方死亡
# 都算」,大乱斗是自由混战 + 归因制 ⇒ 无归因的死亡(溺水/坠落/自杀)不计任何人的击杀。★ _deaths 那份独立计数已删
# (与逐人表记同一件事,两份必然漂)。
				_record_down(int(role), killer)
				if killer != 0:
					_scores[killer] = int(_scores.get(killer, 0)) + 1
					_broadcast_kill(killer, role)
# ★ 基类 _record_down 里那笔 award_kill 是唯一写端(3v3 与大乱斗同一份),此处不得再记一笔 —— 重复会让大乱斗的击杀颗粒翻倍。
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


# 击杀归因:读受害者 meta 里的射手节点(子弹直击/爆炸在命中时写入),映射回 role;★ 带时效 —— 伤害超过 ATTRIB_WINDOW
# (3000ms)的射手不再归因(防止「被打一枪后溺水」误计)。★ ATTRIB_WINDOW 与逐人伤害的 ATTRIB_FRESH_MS(8ms)都住在底座
# MatchState:子类重复声明基类成员是硬 Parse Error。
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



func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	var tie := false
# ★ 候选 = 还在场的 ∪ 计过分的(含已离开者)。★ 原实现只遍历 players,而 mark_disconnected 会先把退出者 erase 掉 ⇒ 剩 1 人时
# 独行者必胜、与比分无关(现已按分判胜;分平含全场 0 杀则平局)。_scores 不在清理范围内,离开者的分天然还在。
	var candidates := {}
	for role in players:
		candidates[int(role)] = true
	for role in _scores:
		candidates[int(role)] = true
# ★ 已移出但对局仍在继续的人(_left)也必须进候选:0 杀离开者的分不在 _scores 里,他又已被移出 players ⇒ 两边都不在,
# 于是少了一个并列候选 —— 幸存者只剩一个时他是唯一候选、tie 永远不成立,明明全场 0 杀却判成他独胜。_left 是这种离开者
# 唯一的痕迹。★ 只在「幸存者 ≤ 1」这一档改变结果。⚠ 零守卫:late_match_probe ④/⑤/⑤b 已删(2026-10-09)。
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



func _broadcast_round_state() -> void:
	var names := {}
	var alive := {}
# 昵称行覆盖:真人(peer_by_role)+ 已离开者 + AI 补位(players 里没有 peer 的 role)—— 只遍历 peer_by_role 会让 AI 不进排行榜。
	for role in peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in players:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in _left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))

	for role in players:
		var p: Node2D = players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
# deaths 仍是逐 role 计数,但来源改成逐人统计表(原先的 _deaths 是同一件事的第二份计数,两份必然漂且不会有断言变红)。
# ★ role 集合取 _roster()(在场 ∪ 已离开 ∪ 有数据的):离开者的阵亡数照样要下发,漏了那一行会回落到 0 且不报错。
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
# 逐人数据只在非空时带该键。★ 大乱斗不带 mvp(spec §3.6/§4 都没要求,结算页也不列 ACS)—— 加了它就是一个没有读者的键。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
# 基类的广播样板,只多一个「只发在线 peer」;样板本身收在 MatchHost._rpc_all,这里走 _send_round_state(它内部仍调它,并多并一个 grace 字段)。
	_send_round_state(data)



var _display_names: Dictionary = {}

func set_display_names(names: Dictionary) -> void:
	_display_names = names
	_broadcast_round_state()



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
# 剩余玩家 < 2 → 直接终局(独行者判胜)。★ 判据必须是 players(真人 + AI 补位),不是 peer_by_role:AI 补位由服务端驱动、
# 没有 peer,按 peer 数会在「2 真人 + 2 AI 掉 1 真人」时把剩下 1 真人 + 2 AI 当场判终局。
	if players.size() < 2 and _round_state != RoundState.MATCH_OVER:
		_finish_match()



func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
# 归因写入统一走 CombatFeedback 的单一入口(它同时写 last_damager + last_damager_time)。★ 基类自 2026-09-27 起也写同一笔
# ⇒ 本覆写是冗余的重复写(attribute 幂等),保留只为留下写点;★★ 别据此把基类那行删掉 —— 1v1 直接建 MatchHost,基类那行是它唯一的子弹归因写端。
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


# 复活时清空归因 meta:复活后的环境死亡(溺水等)不再记到复活前最后射手头上(与 TeamHost 那份对等)。
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")

# ── 自杀脱困(K 键:royale_game 客户端 → NetBusExt.suicide_request → server_main 转发)── 异常卡死时主动放弃生命:
# 走正常倒地边沿 → 2s 复活;先清 last_damager 归因 ⇒ 自杀不计入任何人击杀(哪怕刚被人打过),只累积自己的阵亡数。
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
