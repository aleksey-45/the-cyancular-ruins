class_name RoyaleHost
extends MatchHost


const MATCH_TIME := 300.0
const HUD_SYNC_INTERVAL := 1.0

var _match_time := MATCH_TIME
var _cfg_match_time := 0.0
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}
var _spawned_once: Dictionary = {}
var _last_spawn: Dictionary = {}


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}) -> void:
	_ensure_state()
# ★ 散点必须在 super._init() 之前就绪:父类 _init 摆位会虚调 _spawn_cell(role),那时 _round_spawns 若还空,首次摆位会拿到
# (-1,-1) 并被 _spawned_once 闩死 ⇒ 全体玩家挤到地图回卷角落,散点/复活设计失效。
	MatchHost.ensure_spawn_grid(map_path)
	_round_spawns = spawns if not spawns.is_empty() else plan_spawns(role_peers.keys() + ai_roles)
	_cfg_match_time = float(options.get("match_time", 0.0))
	super._init(map_path, role_peers, options, ai_roles)


static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		ai_roles: Array = []) -> Node:
	MatchHost.prepare_map(map_path)
	var spawns := plan_spawns(role_peers.keys() + ai_roles)
	for role in role_peers:

		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "大乱斗开始")

	var host := RoyaleHost.new(map_path, role_peers, options, ai_roles, spawns)
	return host



static func plan_spawns(roles: Array) -> Dictionary:
	return RoyaleSpawn.plan_spawns(roles)


func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


func _spawn_cell(role: int) -> Vector2i:
	role = int(role)
	var cell: Vector2i
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		cell = _round_spawns.get(role, Vector2i(-1, -1))
	else:
		cell = RoyaleSpawn.respawn_cell(role, state.players, state._left, _last_spawn, state.map_all_respawn_points())
	_last_spawn[role] = cell
	return cell


func _ready() -> void:
	super._ready()
	state._round_state = MatchState.RoundState.COUNTDOWN
	state._round_timer = MatchState.COUNTDOWN_TIME
	state._countdown_resync = MatchState.COUNTDOWN_RESYNC
	_match_time = _cfg_match_time if _cfg_match_time > 0.0 else MATCH_TIME

	_broadcast_round_state()



func _match_round_tick(delta: float) -> void:
	match state._round_state:
		MatchState.RoundState.COUNTDOWN:
			state._round_timer -= delta
			if state._round_timer <= 0.0:
				state._round_state = MatchState.RoundState.PLAYING
				_broadcast_round_state()
			else:
				_countdown_resync_tick(delta)
		MatchState.RoundState.PLAYING:
			_match_time = maxf(_match_time - delta, 0.0)

			for role in state.players:
				var p: Node2D = state.players[role]
				if p.is_downed() and not state._respawn_pending.has(role):
					state._respawn_pending[role] = MatchState.RESPAWN_DELAY
			_handle_respawns(delta)

			for role in state.players:
				var p: Node2D = state.players[role]
				if not p.is_downed() or state._down_counted.get(role, false):
					continue
				state._down_counted[role] = true
				_on_down_edge(int(role))
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = HUD_SYNC_INTERVAL
				_broadcast_round_state()
			if _match_time <= 0.0:
				_finish_match()
		MatchState.RoundState.MATCH_OVER:
			pass


func _down_killer_of(role: int) -> int:
	return _attributed_killer(state.players[int(role)])


func _award_down(victim_role: int, killer_role: int) -> void:
	if killer_role != 0:
		state._scores[killer_role] = int(state._scores.get(killer_role, 0)) + 1
		_broadcast_kill(killer_role, victim_role)
# ★ 基类 _record_down 里那笔 award_kill 是唯一写端(3v3 与大乱斗同一份),此处不得再记一笔 —— 重复会让大乱斗的击杀颗粒翻倍。
	_broadcast_round_state()


func _finish_match() -> void:
	super._finish_match()
	print("RoyaleHost: 对局结束,胜者 role %d" % _match_winner())



func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	var tie := false
	var candidates := {}
	for role in state.players:
		candidates[int(role)] = true
	for role in state._scores:
		candidates[int(role)] = true
	for role in state._left:
		candidates[int(role)] = true
	for role in candidates:
		var n: int = int(state._scores.get(role, 0))
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
	for role in state.peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in state.players:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in state._left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))

	for role in state.players:
		var p: Node2D = state.players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
# deaths 仍是逐 role 计数,但来源改成逐人统计表(原先的 _deaths 是同一件事的第二份计数,两份必然漂且不会有断言变红)。
# ★ role 集合取 _roster()(在场 ∪ 已离开 ∪ 有数据的):离开者的阵亡数照样要下发,漏了那一行会回落到 0 且不报错。
	var deaths := {}
	for role in state._roster():
		var s: Dictionary = state._stats.get(int(role), {})
		deaths[int(role)] = int(s.get("deaths", 0))
	var data := _round_state_base()
	data["round"] = 1
	data["rounds_won"] = {}
	data["timer"] = ceilf(_match_time) if state._round_state == MatchState.RoundState.PLAYING else state._round_timer
	data["deaths"] = deaths
	data["names"] = names
	data["alive"] = alive
	data["left"] = state._left.keys()
	_send_round_state(data)



var _display_names: Dictionary = {}

func set_display_names(names: Dictionary) -> void:
	_display_names = names
	_broadcast_round_state()



func mark_disconnected(role: int) -> void:
	role = int(role)
	if not _detach_role(role):
		return
	_broadcast_round_state()
	if state.players.size() < 2 and state._round_state != MatchState.RoundState.MATCH_OVER:
		_finish_match()



func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = state.players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")

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
