class_name TeamHost
extends MatchHost

# 3v3 团队对抗权威对局(第三个模式宿主,与 RoyaleHost 平级):6 人两队各 3、三局两胜、每队先到 TEAM_KILLS_TO_WIN 击杀赢一局、
# 局间整队换边、局内死亡 2s 复活;击杀后不复位任何人(代价见 _match_round_tick)。★ 计分不分死因:任一玩家倒地 → 对方队 +1;
# 子弹穿透队友、爆炸对队友满效(现状)。★ 掉线:整队走光才终局(走光即弃权,两队都走光 = 平局);队伍归属来自 MatchState._team_of。
# ★ 本类是末端子类,生命周期钩子只能在这里;_init 顺序不可整理。

const TEAM_KILLS_TO_WIN := 9     # ★ 不能叫 KILLS_TO_WIN:基类 MatchState 已有该常量,同名遮蔽会报错
const TEAM_ROUNDS_TO_WIN := 2    # ★ 同上,基类是 ROUNDS_TO_WIN
# ★ _endgame_winner 的「未定」哨兵:必须三态,不能拿 0 当未定 —— 0 是合法结果(两队都走光 = 平局)。
const ENDGAME_NONE := -1
# 散点 / 复活选格 / 队层契约的常量与实现都在 TeamSpawn(server/hosts/team_spawn.gd)。★ 下面这行是转出:客户端
# scenes/team_game.gd 与 tests/harness/team_match_watcher.gd 按这个**名字**读数,契约表那条注释也留在 TeamSpawn 里。
const TEAM_ENEMY_LAYER := TeamSpawn.TEAM_ENEMY_LAYER

var _round_spawns: Dictionary = {}   # role -> Vector2i(本局出生点,与 match_start 广播的同一份)
var _swap_spawns: Dictionary = {}    # role -> Vector2i(换边后的点;两队点集整体对调)
var _spawned_once: Dictionary = {}   # role -> true(首次摆位走出生点,之后走动态复活点)

var _endgame_winner := ENDGAME_NONE


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:

	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_team_of = teams.duplicate()
# ★ spawns 传空只在手工/测试路径才自己算一份:plan_team_spawns 内部有 shuffle,重算会得到另一份散点,而广播给客户端的是 start_on 那一份。
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
	_swap_spawns = compute_swap_spawns(_round_spawns, _team_of)
# ★ 第 5 个实参是 teams、不是 spawns(两者在 RoyaleHost 里同名易混):传错不是崩溃,而是整局队伍判定全错 —— _team_of 被塞成 {role: Vector2i} ⇒ team_of() 返回 0 ⇒ 子弹不穿队友、队伍表下发为空。
	super._init(map_path, role_peers, options, ai_roles, teams)
	_apply_team_layers()


# ── 队友不互挡(用户裁定「完全穿透」)── 契约与配层规则单一来源 = TeamSpawn.apply_team_layers;本函数只留
# 「什么时候调」(必须在 super._init 之后),并让「手工摆位」路径还能补调一次(幂等、直接赋值不叠加)。
# ★ 队号 1/2 的穷举、表外 role push_error、1 队 mask=21 / 2 队 mask=7 的逐条理由全在那份实现里。
func _apply_team_layers() -> void:
	TeamSpawn.apply_team_layers(players, _team_of)



static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_team_spawns(teams)
	for role in role_peers:

		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "3v3 开始")

	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# ── 散点 ── 实现(重试循环 / 基座 / 队内间距的逐条「为什么」)在 TeamSpawn.plan_team_spawns。
# ★ 保留静态转发而不是让调用点直接引 TeamSpawn:start_on 与手工路径的调用面零 diff,搬运不牵连调用方。
static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	return TeamSpawn.plan_team_spawns(teams)


# 换边点集(两队点整体对调):实现在 TeamSpawn.compute_swap_spawns。★ 保留静态转发是因为 team_match_probe 相④
# 直接用 `TeamHost.compute_swap_spawns(...)` 算期望 —— 探针不在本次改动面内,这个名字必须继续可用。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	return TeamSpawn.compute_swap_spawns(spawns, teams)



func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()



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


# 复活点:选格计算(池序列 / 「躲敌人不躲队友」/ 环面距离)在 TeamSpawn.respawn_cell;本函数只留虚方法覆写与状态读取。
func _respawn_cell_for(role: int) -> Vector2i:
	return TeamSpawn.respawn_cell(int(role), players, _team_of)


# ★ 复活时清 last_damager / last_damager_time:meta 在受击瞬间写下、跨倒地保留,而归因窗口是 ATTRIB_WINDOW(3s)⇒ 复活后 3s 内的
# 环境死亡会记到复活前那名射手头上。与 RoyaleHost 那份逐字同构(对等性欠债别留)。⚠ 零守卫:team_host_probe 已删(2026-10-09)。
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")



func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


# ★ 整段覆写而不是改基类:基类的计分键、胜负判据、复位对象三方都绑在 role 上,逐处插分支会让 1v1 那条路长出团队语义。
func _match_round_tick(delta: float) -> void:
	for role in players:

		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue

		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
# 掉落:倒地这一刻在原地丢下除随机保留一把外的全部武器(理由见 MatchGround._drop_all_but_one)。共用 _down_counted 闩 ⇒ 每次死亡
# 恰好一次。★ 本行与另外两处边沿是同一个契约的三份落地:少写这一处,3v3 会静默退化成「死亡不掉武器」。
		_drop_all_but_one(p, int(role))
# 逐人数据:倒下一律计 death;击杀只在「归因到且异队」时计给杀手。★ 刻意放在 scorer != 0 那道闸之外 —— deaths 的口径是「谁死了都算死」。
		_record_down(int(role), _attributed_killer(p))
# 击杀定义(继承 1v1 的「不分死因」):任一玩家倒地 → 对方队 +1;队友误炸也照此(乱扔雷 = 给对面送分,惩罚自带)。★★ 记分(无归因的
# 队分)与逐人 kills(有归因)是两条账:溺水/自杀/队友误炸让队分 +1 而无人记 kills ⇒ 结算页的击杀之和不等于记分条上的队分(见 docs/eng/modes.md)。
		var scorer := _enemy_team_of(int(role))
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1

			_broadcast_kill(_attributed_killer(p), int(role))
			_broadcast_round_state()
# ★★ 击杀者复位已按用户要求删除(2026-09-21,那个函数已整体删掉):击杀者原地不动,受害者 2s 后回本方出生点复活。
# ★ 代价照实记录:那条规则本是为反「反复活点蹲守」而立,删后 3v3 不再有这条性质;将来若要找回,正确的形状是「复活点选点避开存活敌人」(TeamSpawn.respawn_cell 的 RESPAWN_CLEARANCE 已做一半),而不是把击杀者瞬移走。
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


# 换局:局胜到 TEAM_ROUNDS_TO_WIN → MATCH_OVER;否则整队换边 + 下一局。★ 与基类的三处实质差异:① 局胜的键是队号(基类按 role 查,
# 团队下永远是 0 → 永远打不完);② 换边 = 两份点集整体互换;③ 换边后必须清 _spawned_once —— 否则 _spawn_cell 走动态复活点分支,
# 开局的六个人会被撒到「离敌人远」的随机格而不是本方出生点。★ 与 _match_winner() 互补:一个判要不要进 MATCH_OVER,一个判报哪一队。
func _start_next_round() -> void:
	if _threshold_team() != 0:
		_round_state = RoundState.MATCH_OVER
		_broadcast_round_state()
		return
	_reset_world_and_clear_dynamics()

	if not _swap_spawns.is_empty():
		var tmp := _round_spawns
		_round_spawns = _swap_spawns
		_swap_spawns = tmp

	_spawned_once.clear()
	_round_num += 1
	_scores = {}
# ★ 整场累计的 _stats 不清零:ACS 是整场口径,与每局清零的 _scores(队伍比分)是两份不同的东西。
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()


# 对局胜者(队号):① 走光(弃权)看 _endgame_winner;② 正常收局 = 先到 TEAM_ROUNDS_TO_WIN 局胜的那队;③ 都还没到则退回「局胜高者」。
# ★★ 下面那两个 2 不是阈值、是队号,别换成 TEAM_ROUNDS_TO_WIN —— 今天两者都等于 2,换错了不报错,而档位一改就会报出不存在的队号。
func _match_winner() -> int:
# ★ 走光终局优先于按局胜比较的兜底:走光必然走兜底(谁也没赢满),而兜底在 0:0 / 1:1 并列时偏 1 队 ⇒ 不拦就会把「整队走光」那队报成胜者。
	if _endgame_winner != ENDGAME_NONE:
		return _endgame_winner
	var decided := _threshold_team()
	if decided != 0:
		return decided
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# 「局胜阈值」谓词的单一来源:先到 TEAM_ROUNDS_TO_WIN 局的那一队,都还没到 → 0。★ 三个读者问的是同一个谓词的三种问法
# (_start_next_round 问要不要进、_match_winner 问报哪队、_decided_by_rounds 问是否已决出)。★ 返回的 0 不是队号(本模式没有 0 队)。
func _threshold_team() -> int:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 0



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

		data["mvp"] = mvp_role()

	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	_send_round_state(data)


# ── 击杀归因(自带一份,不上提基类):kill_event 要带「是谁杀的」(归因不到就带 0)。★ 基类归属有「基类不得含子类方法」的反向断言守着(那条探针已删);两份都读同一个 meta,单一来源仍是 CombatFeedback。
func _attributed_killer(victim: Node2D) -> int:
	return _attributed_role_within(victim, ATTRIB_WINDOW)


# ── 中途掉线(宽限期到点后由 server_main 调):移出对局,但整队走光才终局。★ 判据是「某个队一个人都不剩」,不是 royale 那条 players.size() < 2(6 人局掉 1 个就终局 = 剩下的人白打);也不能数 peer_by_role(那是「有连接的人」)。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true

	_left_round[role] = int(_leave_round.get(role, _round_num))
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

	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2 and not _decided_by_rounds():
# 走光即弃权:存活的那支队胜;一队不剩 = 平局 0。★ 本判据在走光收场之后仍生效(先走光那队把结果判给对手后,对手也可能接着走光)
# ⇒ 少了它,「六个人在同一批宽限期里走光」的胜者取决于遍历顺序;收缩是单调的。★★ _decided_by_rounds() 那道闸不能省。
		var survivors: Array = alive_teams.keys()
		_endgame_winner = int(survivors[0]) if survivors.size() == 1 else 0
		if _round_state != RoundState.MATCH_OVER:
			_finish_match()
			return      # `_finish_match` 内部自会广播(载荷里的 match_winner 已读新值)

	_broadcast_round_state()


# 对局是否已由局胜(三局两胜)决出。★ 弃权判据不得改判一场已经打完的局 —— 故刻意不用「在 _start_next_round 里记一个闩」的写法:那样 ROUND_OVER 期间(局胜已达标、状态未推进)会漏判。
func _decided_by_rounds() -> bool:
	return _threshold_team() != 0


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


# ── 自杀脱困(K 键:客户端 → NetBusExt.suicide_request → server_main._on_suicide_request)── 异常卡死时主动放弃生命,先清归因 ⇒
# 自杀不计入任何人击杀(3v3 下落进无归因档:对方队 +1、无人被计击杀)。★ 必须留在子类;server_main 原先只认 _royale ⇒ 3v3 的 K 键被静默丢掉。
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


# 逐人数据 + ACS / MVP 的口径已上提到 MatchState(公式见 core/sim/score_rules.gd);本文件只留 3v3 特有的两处写入:倒地边沿 _record_down、子弹直击补归因。


# 子弹直击的归因写入(与 RoyaleHost._on_bullet_hit 逐字同构):服务器上子弹撞玩家不靠物理,只经 _adjudicate_bullets 到这里。
# ★ 基类自 2026-09-27 起也写同一笔 ⇒ 本覆写是冗余的重复写(attribute 幂等);★★ 别据此把基类那行删掉:1v1 直接建 MatchHost,基类那行是它唯一的子弹归因写端。
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)
