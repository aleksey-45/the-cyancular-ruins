class_name TeamHost
extends MatchHost


const TEAM_ROUNDS_TO_WIN := 2
const ENDGAME_NONE := -1
const META_DAMAGE_SUBSIDY := "team_damage_subsidy"

var _round_spawns: Dictionary = {}
var _side_swap_round := false
var _spawned_once: Dictionary = {}
var _last_spawn: Dictionary = {}

var _endgame_winner := ENDGAME_NONE

var _rules: Dictionary = {}
var _kills_to_win: int = TeamRules.KILLS_MIN


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:
	_ensure_state()

	MatchHost.ensure_spawn_grid(map_path)
	state._team_of = teams.duplicate()
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(state._team_of)
	super._init(map_path, role_peers, options, ai_roles, teams)
	_init_team_rules()


func _init_team_rules() -> void:
	_rules = TeamRules.subsidy(state._team_of)
	_kills_to_win = int(_rules["kills_target"])
	state._scores = _initial_scores()


func _initial_scores() -> Dictionary:
	var bonus := int(_rules.get("score_bonus", 0))
	if bonus <= 0:
		return {}
	return {int(_rules["smaller_team"]): bonus}


func _ready() -> void:
	if int(_rules.get("hp_bonus", 0)) > 0:
		_apply_health_subsidy()
	if float(_rules.get("damage_mult", 1.0)) > 1.0:
		for role in state.players:
			var wc = (state.players[role] as Node).get("weapons")
			if wc != null and wc.has_signal("weapon_changed"):
				wc.weapon_changed.connect(_on_team_weapon_changed.bind(int(role)))
	super._ready()


# 血量补贴:少人方 max_hp = 基础 + 加成,并拉满。★ 客户端在 scenes/team_game.gd::_apply_team_health_subsidy 用同一份
# TeamRules 从 match_sync 的 teams 复算(不新增协议字段);两边必须同值,否则 C2 的 hp 每次快照都被钳到客户端上限。
func _apply_health_subsidy() -> void:
	var bonus := int(_rules.get("hp_bonus", 0))
	var small := int(_rules.get("smaller_team", 0))
	if bonus <= 0 or small == 0:
		return
	for role in state.players:
		if state.team_of(int(role)) != small:
			continue
		var c := (state.players[role] as Node).get("combat") as CombatComponent
		if c == null:
			continue
		c.max_hp = PlayerParams.player_max_hp + bonus
		c.hp = c.max_hp
		c.hp_changed.emit(c.hp, c.max_hp)


func _on_team_weapon_changed(_type_id: int, role: int) -> void:
	var mult := float(_rules.get("damage_mult", 1.0))
	if mult <= 1.0:
		return
	var p: Node2D = state.players.get(int(role))
	if p == null or not is_instance_valid(p):
		return
	var w = p.get("weapons")
	if w == null:
		return
	var weapon: WeaponBase = w.current_weapon()
	if weapon == null or not is_instance_valid(weapon):
		return
	if weapon.has_meta("team_base_damage"):
		return
	weapon.set_meta("team_base_damage", int(weapon.damage))
	weapon.damage = maxi(1, roundi(float(weapon.damage) * mult))


func _adjudicate_bullets() -> void:
	var mult := float(_rules.get("damage_mult", 1.0))
	if mult > 1.0:
		var small := int(_rules.get("smaller_team", 0))
		for b in get_tree().get_nodes_in_group("bullet"):
			if not is_instance_valid(b) or not (b is BulletBase):
				continue
			var bullet := b as BulletBase
			if bullet.has_meta(META_DAMAGE_SUBSIDY):
				continue
			var shooter_role := state._role_of(bullet.shooter)
			if shooter_role < 0 or state.team_of(shooter_role) != small:
				continue
			bullet.set_meta(META_DAMAGE_SUBSIDY, true)
			bullet.direct_hit_damage = maxi(1, roundi(float(bullet.direct_hit_damage) * mult))
			bullet.explosion_damage = maxi(1, roundi(float(bullet.explosion_damage) * mult))
	super._adjudicate_bullets()


static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MatchHost.prepare_map(map_path)
	var spawns := plan_team_spawns(teams)
	for role in role_peers:

		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "对抗开始")

	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


static func plan_team_spawns(teams: Dictionary, last: Dictionary = {}, side_swap := false) -> Dictionary:
	return TeamSpawn.plan_team_spawns(teams, last, side_swap)


static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	return TeamSpawn.compute_swap_spawns(spawns, teams)



func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()



func team_map() -> Dictionary:
	var out := {}
	for role in state._team_of:
		out[int(role)] = int(state._team_of[role])
	return out


func _spawn_cell(role: int) -> Vector2i:
	role = int(role)
	var cell: Vector2i
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		cell = _round_spawns.get(role, Vector2i(-1, -1))
	else:
		cell = _respawn_cell_for(role)
	_last_spawn[role] = cell
	return cell


func _respawn_cell_for(role: int) -> Vector2i:
	return TeamSpawn.respawn_cell(int(role), state.players, state._team_of, _last_spawn,
			state.map_spawn_data().get("respawns", {}), _side_swap_round)


func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = state.players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")



func _enemy_team_of(role: int) -> int:
	var t := state.team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


func _match_round_tick(delta: float) -> void:
	for role in state.players:

		if state._round_state == MatchState.RoundState.MATCH_OVER:
			continue
		var p: Node2D = state.players[role]
		if not p.is_downed():
			continue

		if state._round_state == MatchState.RoundState.PLAYING and not state._respawn_pending.has(role):
			state._respawn_pending[role] = MatchState.RESPAWN_DELAY
		if state._down_counted.get(role, false):
			continue
		state._down_counted[role] = true
		_on_down_edge(int(role))
	match state._round_state:
		MatchState.RoundState.COUNTDOWN:
			if not _countdown_can_start(delta):
				return
			if not state._countdown_bcast_done:
				state._countdown_bcast_done = true
				_broadcast_round_state()
			state._round_timer -= delta
			if state._round_timer <= 0.0:
				state._round_state = MatchState.RoundState.PLAYING
				if state._round_full_heal:
					for heal_role in state.players:
						(state.players[heal_role] as Node).apply_authoritative_state(
								(state.players[heal_role] as Node).max_hp,
								(state.players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
			else:
				_countdown_resync_tick(delta)
		MatchState.RoundState.PLAYING:
			_handle_respawns(delta)
			for t in [1, 2]:
				if int(state._scores.get(t, 0)) >= _kills_to_win:
					_round_over(t)
					break
		MatchState.RoundState.ROUND_OVER:
			state._round_timer -= delta
			if state._round_timer <= 0.0:
				_start_next_round()
		MatchState.RoundState.MATCH_OVER:
			pass


func _start_next_round() -> void:
	if _threshold_team() != 0:
		state._round_state = MatchState.RoundState.MATCH_OVER
		_broadcast_round_state()
		return
	_reset_world_and_clear_dynamics()

	_side_swap_round = not _side_swap_round
	_round_spawns = plan_team_spawns(state._team_of, _round_spawns, _side_swap_round)

	_spawned_once.clear()
	state._round_num += 1
	state._scores = _initial_scores()
	state._respawn_pending = {}
	state._down_counted = {}
	for role in state.players:
		_respawn_player(role)
	state._round_state = MatchState.RoundState.COUNTDOWN
	state._round_timer = MatchState.COUNTDOWN_TIME
	state._countdown_hold = MatchState.COUNTDOWN_HOLD_MAX
	state._countdown_bcast_done = false
	state._countdown_resync = MatchState.COUNTDOWN_RESYNC
	_broadcast_round_state()


# 对局胜者(队号):① 走光(弃权)看 _endgame_winner;② 正常收局 = 先到 TEAM_ROUNDS_TO_WIN 局胜的那队;③ 都还没到则退回「局胜高者」。
# ★★ 下面那两个 2 不是阈值、是队号,别换成 TEAM_ROUNDS_TO_WIN —— 今天两者都等于 2,换错了不报错,而档位一改就会报出不存在的队号。
func _match_winner() -> int:
	if _endgame_winner != ENDGAME_NONE:
		return _endgame_winner
	var decided := _threshold_team()
	if decided != 0:
		return decided
	return 1 if int(state._rounds_won.get(1, 0)) >= int(state._rounds_won.get(2, 0)) else 2


# 「局胜阈值」谓词的单一来源:先到 TEAM_ROUNDS_TO_WIN 局的那一队,都还没到 → 0。★ 三个读者问的是同一个谓词的三种问法
# (_start_next_round 问要不要进、_match_winner 问报哪队、_decided_by_rounds 问是否已决出)。★ 返回的 0 不是队号(本模式没有 0 队)。
func _threshold_team() -> int:
	for t in [1, 2]:
		if int(state._rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 0



func _broadcast_round_state() -> void:
	var data := _round_state_base()
	data["target"] = _kills_to_win
	if int(_rules.get("diff", 0)) > 0:
		data["handicap"] = {
			"team": int(_rules["smaller_team"]),
			"diff": int(_rules["diff"]),
			"score": int(_rules["score_bonus"]),
			"hp": int(_rules["hp_bonus"]),
			"damage_pct": roundi((float(_rules["damage_mult"]) - 1.0) * 100.0),
		}
	if state._round_state == MatchState.RoundState.ROUND_OVER and state._last_round_winner != 0:
		data["winner"] = state._last_round_winner
	if state._round_state == MatchState.RoundState.MATCH_OVER:
		data["mvp"] = state.mvp_role(_roles_of_team(int(data["match_winner"])))
	_send_round_state(data)


func _roles_of_team(team: int) -> Array:
	var out: Array = []
	if team <= 0:
		return out
	for role in state._roster():
		if state.team_of(int(role)) == team:
			out.append(int(role))
	return out


# ── 击杀归因:`_attributed_killer`(读上次射手 meta,3s 窗口)已上提到 MatchHost(与 RoyaleHost 逐字同款那份);
# 单一来源仍是 CombatFeedback 写 meta + MatchState._attributed_role_within 读。


func mark_disconnected(role: int) -> void:
	role = int(role)
	if not _detach_role(role):
		return
	state._left_round[role] = int(state._leave_round.get(role, state._round_num))

	var alive_teams := {}
	for r in state.players:
		var t := state.team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2 and not _decided_by_rounds():
		var survivors: Array = alive_teams.keys()
		_endgame_winner = int(survivors[0]) if survivors.size() == 1 else 0
		if state._round_state != MatchState.RoundState.MATCH_OVER:
			_finish_match()
			return

	_broadcast_round_state()


func _decided_by_rounds() -> bool:
	return _threshold_team() != 0


func _finish_match() -> void:
	super._finish_match()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


func request_suicide_role(role: int) -> void:
	if state._round_state != MatchState.RoundState.PLAYING:
		return
	var p: Node2D = state.players.get(int(role))
	if p == null or not is_instance_valid(p) or p.is_downed():
		return
	for m in ["last_damager", "last_damager_time"]:
		if p.has_meta(m):
			p.remove_meta(m)
	var combat: Node = p.get_node_or_null("Combat")
	if combat != null and combat.has_method("force_down"):
		combat.force_down()


# 逐人数据 + ACS / MVP 的口径已上提到 MatchState(公式见 core/sim/score_rules.gd);本文件只留对抗特有的两处写入:倒地边沿 _record_down、子弹直击补归因。


# 对抗口径:击杀定义沿用 1v1 的「不分死因」(任一玩家倒地 → 对方队 +1;队友误炸也照此,乱扔雷 = 给对面送分);
# 逐人 kills 仍只在「归因到且异队」时由基类 _record_down 记(队分与逐人 kills 是两条账,见 docs/systems/gameplay/modes.md)。
func _down_killer_of(role: int) -> int:
	return _attributed_killer(state.players[int(role)])


func _award_down(victim_role: int, killer_role: int) -> void:
	var scorer := _enemy_team_of(victim_role)
	if scorer == 0:
		return
	state._scores[scorer] = int(state._scores.get(scorer, 0)) + 1
	_broadcast_kill(killer_role, victim_role)
	_broadcast_round_state()


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)
