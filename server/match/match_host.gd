class_name MatchHost
extends Node


var state: MatchState = null
var grace_snapshot: Dictionary = {}


func _ensure_state() -> void:
	if state == null:
		state = MatchState.new()


func destroyed_cells() -> Array[Vector2i]:
	return state.destroyed_cells()


func damaged_partial_subs() -> Array[Vector2i]:
	return state.damaged_partial_subs()


func note_disconnect_round(role: int) -> void:
	state.note_disconnect_round(role)


func is_friendly(a: Node, b: Node) -> bool:
	return state.is_friendly(a, b)

const TIME_SYNC_INTERVAL := 0.1

var _time_sync := 0.0

const RW_SNAP_DT := 1.0 / 20.0
var _rw_buf: Dictionary = {}
var _rw_cursor: Dictionary = {}
var _rw_snap_t: Dictionary = {}
var _rw_t0: Dictionary = {}

var _ports: MatchPorts = null
var _snapshot: SnapshotSystem = null
var _combat: CombatSystem = null
var _ground: GroundSystem = null
var _round: RoundSystem = null

func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], teams: Dictionary = {}, spawns: Dictionary = {}) -> void:
	_ensure_state()
	state._team_of = teams.duplicate()
# 1v1 出生点:start_on 算好的那一份(与 match_start / match_sync 广播同源)。空 = 手工/测试路径(基类 _spawn_cell 自己随机)。
# ★ 子类(RoyaleHost / TeamHost)覆写了 _spawn_cell 与 role_spawns,本表对它们无效(它们各自持有自己的点表)。
	state._duel_spawns = spawns.duplicate()
	state._round_full_heal = bool(options.get("round_full_heal", false))
	var raw_disabled: Array = options.get("disabled_weapons", [])
	for v in raw_disabled:
		state._disabled_weapons.append(int(v))
	state._ai_roles = ai_roles
	var time_dict: Dictionary = options.get("time", {})
	if not time_dict.is_empty():
		state.time_economy = TimeEconomy.new(TimeRules.from_dict(time_dict))
		for role in role_peers:
			state.time_economy.add_role(int(role))
		for r in ai_roles:
			state.time_economy.add_role(int(r))
	MazeGenerator.set_map_file(map_path)

	state.grid = WorldBuilder.load_grid()
	if state.grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	state._base_grid = MazeGenerator.copy_grid(state.grid)
	_bind_ports()
	_snapshot = SnapshotSystem.new()
	_snapshot.bind(state, _ports)
	_combat = CombatSystem.new()
	_combat.bind(state, _ports)
	_ground = GroundSystem.new()
	_ground.bind(state, _ports)
	_round = RoundSystem.new()
	_round.bind(state, _ports, _ground)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
# cyrm v4(B18):破坏已下沉 16px 子格 —— worker 必须连子格回调(TileDefs.on_sub_destroyed),否则客户端永远收不到拆砖事件(幽灵墙:服务器碰撞已消、客户端还在渲染/预测碰撞)。
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(state.grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	state.destructible_sub = WorldBuilder.build_sim(self, state.grid)
	CombatComponent.pvp_arena = true

	state.peer_by_role = role_peers.duplicate()
	for role in role_peers:
		_add_player(role, PacketInputSource.new(), null)
	for ai_role in state._ai_roles:
		_add_player(int(ai_role), AiInputSource.new(), AiNavigator.new())


func _bind_ports() -> void:
	_ports = MatchPorts.new()
	_ports.net_rpc_role = Callable(self, "_port_rpc_role")
	_ports.net_rpc_role_all = Callable(self, "_port_rpc_role_all")
	_ports.net_broadcast = Callable(self, "_port_broadcast")
	_ports.net_peers_sendable = Callable(self, "_port_net_peers_sendable")
	_ports.net_peer_count = Callable(self, "_port_net_peer_count")
	_ports.scene_bullets = Callable(self, "_port_scene_bullets")
	_ports.scene_add_child = Callable(self, "_port_scene_add_child")
	_ports.scene_rebuild_chunk = Callable(self, "_port_scene_rebuild_chunk")
	_ports.send_round_state = Callable(self, "_send_round_state")
	_ports.on_bullet_hit = Callable(self, "_on_bullet_hit")
	_ports.broadcast_round_state = Callable(self, "_broadcast_round_state")
	_ports.match_winner = Callable(self, "_match_winner")
	_ports.spawn_cell = Callable(self, "_spawn_cell")
	_ports.respawn_player = Callable(self, "_respawn_player")
	_ports.down_killer_of = Callable(self, "_down_killer_of")
	_ports.award_down = Callable(self, "_award_down")
	_ports.finish_match = Callable(self, "_finish_match")
	_ports.start_next_round = Callable(self, "_start_next_round")
	_ports.reset_time_rewind_state = Callable(self, "reset_time_rewind_state")
	assert(_ports.is_ready(), "MatchPorts 未绑全")


func ports() -> MatchPorts:
	return _ports


func _port_rpc_role(role: int, method: String, args: Array, via_ext: bool = false) -> void:
	var peer: int = int(state.peer_by_role.get(role, -1))
	if peer < 0 or not NetBus.is_peer_live(peer):
		return
	if via_ext:
		NetBusExt.callv("rpc_id", [peer, method] + args)
	else:
		NetBus.callv("rpc_id", [peer, method] + args)


func _port_rpc_role_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true, via_ext: bool = false) -> void:
	if via_ext:
		_rpc_all_ext(method, args, except_role, live_only)
	else:
		_rpc_all(method, args, except_role, live_only)


func _port_broadcast(method: String, args: Array = []) -> void:
	if not NetBus.all_peers_sendable():
		return
	NetBus.callv("rpc", [method] + args)


func _port_net_peers_sendable() -> bool:
	return NetBus.all_peers_sendable()


func _port_net_peer_count() -> int:
	return multiplayer.get_peers().size()


func _port_scene_bullets() -> Array:
	return get_tree().get_nodes_in_group("bullet")


func _port_scene_add_child(node: Node) -> void:
	add_child(node)


func _port_scene_rebuild_chunk(chunk: Vector2i) -> void:
	CollisionBuilder.rebuild_chunk(state.destructible_sub, chunk, self)


func _on_tile_destroyed(cell: Vector2i) -> void:
	_combat.on_tile_destroyed(cell)


func _on_sub_destroyed(sub: Vector2i, pre_hp: int, owner: Node) -> void:
	_combat.on_sub_destroyed(sub, pre_hp, owner)


func _on_player_hit(source_pos: Vector2, damage: int, cause: String, role: int) -> void:
	_combat.on_player_hit(source_pos, damage, cause, role)


func _adjudicate_bullets() -> void:
	_combat.adjudicate()


func _broadcast_pending_beams() -> void:
	_combat.broadcast_pending_beams()


func notify_direct_hit(shooter: Node, victim: Node) -> void:
	_combat.notify_direct_hit(shooter, victim)


func _sync_ground_positions() -> void:
	_ground.sync_positions()


func _debug_keep_weapon_within_reach() -> void:
	_ground.debug_keep_weapon_within_reach()


func _handle_ground_actions(role: int, src: PacketInputSource) -> void:
	_ground.handle_actions(role, src)


func _setup_ground_weapons() -> void:
	_ground.setup()


func ground_weapons_payload() -> Array:
	return _ground.payload()


func _match_round_tick(delta: float) -> void:
	_round.tick(delta)


func _broadcast_round_state() -> void:
	_round.broadcast_round_state()


func _match_winner() -> int:
	return int(_round.match_winner())


func _down_killer_of(role: int) -> int:
	return int(_round.down_killer_of(role))


func _award_down(victim_role: int, killer_role: int) -> void:
	_round.award_down(victim_role, killer_role)


func _respawn_player(role: int) -> void:
	_round.respawn_player(role)


func _start_next_round() -> void:
	_round.start_next_round()


func _round_over(winner: int) -> void:
	_round.round_over(winner)


func _on_down_edge(role: int) -> void:
	_round.on_down_edge(role)


func _handle_respawns(delta: float) -> void:
	_round.handle_respawns(delta)


func _countdown_can_start(delta: float) -> bool:
	return bool(_round.countdown_can_start(delta))


func _countdown_resync_tick(delta: float) -> void:
	_round.countdown_resync_tick(delta)


func _reset_world_and_clear_dynamics() -> void:
	_round.reset_world_and_clear_dynamics()


func _round_state_base() -> Dictionary:
	return _round.round_state_base()


func _broadcast_kill(killer: int, victim: int) -> void:
	_round.broadcast_kill(killer, victim)


func is_match_over() -> bool:
	return bool(_round.is_match_over())


func mark_client_ready(role: int) -> void:
	_round.mark_client_ready(role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	var pl := victim as Player
	if pl != null:
		pl.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	var shooter_role := state._role_of(bullet.shooter)
	_port_rpc_role(shooter_role, "hit_confirm", [shooter_role, _victim_role], true)
	bullet.queue_free()


func _add_player(role: int, src: PlayerInput, nav: AiNavigator) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(src)
	add_child(p)
	p.collision_mask |= 2
	state.players[role] = p
	if nav == null:
		state.input_sources[role] = src
	else:
		nav.host = self
		nav.role = role
		nav.src = src
		p.add_child(nav)

	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	var who := "AI " if nav != null else ""
	print("MatchHost: %s角色 %d 出生点 %s" % [who, role, spawn])
	return p


func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)


func _ready() -> void:

	state._round_state = MatchState.RoundState.COUNTDOWN
	state._round_timer = MatchState.COUNTDOWN_TIME
	state._countdown_hold = MatchState.COUNTDOWN_HOLD_MAX
	state._countdown_bcast_done = false
	state._countdown_resync = MatchState.COUNTDOWN_RESYNC
	for role in state.players:
		(state.players[role] as Node).weapons.set_enabled_types(state._disabled_weapons)
# 地面武器:铺 12 把 + 每个玩家随机拿 1 把。★ 必须排在 set_enabled_types 之后 —— 先给再禁的话,手上一旦是禁用武器会被判成空手。
# ★ 这同时是服务器玩家有枪的唯一来源(player.tscn 自身的 _ready 给的是空背包,不发就开不了火,且不会有任何报错)。
	_setup_ground_weapons()

	_wire_hit_feedback()
	_broadcast_round_state()
	add_to_group("authority_explosion_sink")


func on_authority_explosion(pos: Vector2, shooter: Node, visual: PackedScene) -> void:
	var role := state._role_of(shooter)
	var path := ""
	if visual != null:
		path = visual.resource_path
	var canonical := MazeGenerator.wrap_to_range(pos, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_rpc_all_ext("explosion", [canonical, role, path])


func _wire_hit_feedback() -> void:
	for role in state.players:
		var combat = (state.players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))

# ★ 生效选项改由对局场景进场拉取下发(随 NetBus.match_sync 的应答):原先那次「推」与 match_start 落在同一次客户端 poll,而新场景的订阅方还不存在 ⇒ 静默丢失。


var _intake := InputIntake.new()
var _own_flush_pending := false


func _netstat_tick(delta: float) -> void:
	_intake.tick(state._pending_input, delta, state._round_state, state._client_snap_tick, state._client_tick)


func reset_input_queue(role: int) -> void:
	_intake.reset(state._pending_input, role)


func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in state.peer_by_role:
		if state.peer_by_role[role] == caller:
			state._client_snap_tick[int(role)] = int(pkt.get("st", 0))
			state._client_tick[int(role)] = int(pkt.get("ct", 0))
			_intake.intake(state._pending_input, int(role), pkt)
			return


var _tick_timing := preload("res://server/match/tick_timing.gd").new()


func _physics_process(delta: float) -> void:
	var _t_all: int = _tick_timing.begin()

	state._srv_tick += 1

	_sync_ground_positions()

	_debug_keep_weapon_within_reach()

	_debug_destroy_tile(delta)
	if state.time_economy != null:
		var _t_rewind: int = _tick_timing.begin()
		_tick_beta_rewind(delta)
		_tick_timing.end(&"rewind", _t_rewind)
	if state.time_economy != null:
		for role in state.input_sources:
			var acc := state.time_economy.accounts.get(int(role)) as GrainAccount
			var p := state.players.get(int(role)) as Node2D
			if acc == null or p == null:
				continue
			var src: PacketInputSource = state.input_sources[role]
			var on: bool = src.haste_held() and acc.can_spend()
			if on:
				var burn: float = state.time_economy.rules.haste_burn * delta
				if acc.spend(delta, state.time_economy.rules.haste_burn) < burn * 0.999:
					on = false
			p.pvp_haste_mult = state.time_economy.rules.haste_mult if on else 1.0
	state._snapshot_tick_phase += 1
	var snapshot_tick := false
	if state._snapshot_tick_phase >= MatchState.SNAPSHOT_STRIDE:
		state._snapshot_tick_phase = 0
		snapshot_tick = true
		var _t_world: int = _tick_timing.begin()
		_snapshot.broadcast()
		_tick_timing.end(&"world_snap", _t_world)

	if state.time_economy != null:
		state.time_economy.tick(delta)
		_time_sync -= delta
		if _time_sync <= 0.0:
			_time_sync = TIME_SYNC_INTERVAL
			_rpc_all_ext("time_state", [state.time_economy.state_payload()])
	for role in state.input_sources:
		var src: PacketInputSource = state.input_sources[role]
		src.clear_edges()
		if state._pending_input.has(role):
			var q: Array = state._pending_input[role]
			if state._round_state == MatchState.RoundState.COUNTDOWN:
				q.clear()
				src.reset_state()
				continue
			if not q.is_empty():
				var pkt: Dictionary = q.pop_front()
				src.apply_packet(pkt)
				state._ack_seq[role] = int(pkt.get("seq", state._ack_seq.get(role, 0)))
				_handle_ground_actions(role, src)

	if not state._stepped_seq_pending:
		state._stepped_seq_pending = true
		_record_stepped_seq.call_deferred()
	if snapshot_tick:
		_own_flush_pending = true
		_flush_own_snapshots.call_deferred()

	var _t_adj: int = _tick_timing.begin()
	_adjudicate_bullets()
	_tick_timing.end(&"adjudicate", _t_adj)

	_broadcast_pending_beams()

	_match_round_tick(delta)

	_netstat_tick(delta)
	if not state._dirty_chunks.is_empty():
		var processed := 0
		var chunks := state._dirty_chunks.keys()
		state._dirty_chunks.clear()
		for ch in chunks:
			if processed >= 2:
				state._dirty_chunks[ch] = true
				continue
			CollisionBuilder.rebuild_chunk(state.destructible_sub, ch, self)
			processed += 1
	_tick_timing.end_tick(_t_all, state.players, self)


func _flush_own_snapshots() -> void:
	if not _own_flush_pending:
		return
	_own_flush_pending = false
	if not is_inside_tree():
		return
	var _t_own: int = _tick_timing.begin()
	_snapshot.send_own()
	_tick_timing.end(&"own_snap", _t_own)


func _record_stepped_seq() -> void:
	state._stepped_seq_pending = false
	if not is_inside_tree():
		return
	for role in state.input_sources:
		state._stepped_seq[int(role)] = int(state._ack_seq.get(int(role), 0))


func _debug_destroy_tile(delta: float) -> void:
	if MatchState.test_destroy_cell.x < 0:
		return
	MatchState.test_destroy_after -= delta
	if MatchState.test_destroy_after > 0.0:
		return
	var cell := MatchState.test_destroy_cell
	MatchState.test_destroy_cell = Vector2i(-1, -1)
	print("worker: [test] 拆格 %s(相⑦ 用)" % str(cell))
	TileDefs.damage_tile(cell, 999999, "explosion")


func _tick_beta_rewind(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in state.players:
		var r := int(role)
		var p := state.players[role] as Node2D
		var src: PacketInputSource = state.input_sources.get(role)
		var acc := state.time_economy.accounts.get(r) as GrainAccount
		if p == null or src == null or acc == null:
			continue

		var want: bool = src.rewind_held() and acc.can_spend() and not p.is_downed()
		var on := bool(state._rw_on.get(r, false))
		if want and not on:
			src.frozen = true
			p.set_meta("time_rewinding", true)
			state._rw_on[r] = true
			_rw_cursor[r] = 0.0
			state._rw_trail[r] = []
			if not _rw_buf.has(r) or (_rw_buf[r] as Array).is_empty():
				_rw_t0[r] = now
			on = true
		elif not want and on:
			_finish_rw(r, p, src)
			continue
		if not on:
			_record_rw_frame(r, p, now)
			continue

		acc.spend(delta, state.time_economy.rules.rewind_burn)
		if acc.balance <= 0.0:
			_finish_rw(r, p, src)
			continue
		var cur := float(_rw_cursor.get(r, 0.0))
		var mult := lerpf(TimeParams.REWIND_START_MULT, 1.0,
				clampf(cur / maxf(TimeParams.REWIND_RAMP_TIME, 0.001), 0.0, 1.0))
		cur += delta * mult
		_rw_cursor[r] = cur
		_apply_rw_frame(r, p, cur)

		if Engine.get_physics_frames() % 3 == 0:
			var trail: Array = state._rw_trail.get(r, [])
			trail.append([p.global_position.x, p.global_position.y])
			if trail.size() > 10:
				trail.pop_front()
			state._rw_trail[r] = trail


func _finish_rw(r: int, p: Node2D, src: PacketInputSource) -> void:
	src.frozen = false
	p.remove_meta("time_rewinding")
	state._rw_on[r] = false
	state._rw_trail[r] = []
	var buf: Array = _rw_buf.get(r, [])
	if buf.is_empty():
		_rw_cursor[r] = 0.0
		return

	var exit_t := float(buf[buf.size() - 1]["t"]) - float(_rw_cursor.get(r, 0.0))
	var kept := 0
	for i in range(buf.size()):
		if float(buf[i]["t"]) <= exit_t:
			kept = i + 1
	if kept == 0:
		kept = 1
	if kept < buf.size():
		buf.resize(kept)
		_rw_buf[r] = buf
	_rw_cursor[r] = 0.0



func _record_rw_frame(r: int, p: Node2D, now: float) -> void:
	if now < float(_rw_snap_t.get(r, 0.0)):
		return
	_rw_snap_t[r] = now + RW_SNAP_DT
	if not _rw_t0.has(r):
		_rw_t0[r] = now
	var d := {
		"t": now - float(_rw_t0[r]),
		"p": p.global_position,
		"v": p.get("velocity"),
		"hp": int(p.get("hp")),
		"facing": int(p.get("facing_direction")),
		"downed": p.is_downed(),
	}
	var wc := p.get("weapons") as WeaponComponent
	if wc != null:
		d["widx"] = wc._current_index
		var inv: WeaponInventory = wc.inventory
		var mags: Array = []
		if inv != null:
			for slot in inv.held:
				mags.append(int(slot["mag"]))
		d["wmags"] = mags
		var live: WeaponBase = wc.current_weapon()
		if live != null and is_instance_valid(live):
			d["wlive"] = live.mag_ammo
	var bl: Array = []
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b) or not (b is Node2D):
			continue
		if b.get("shooter") != p:
			continue
		bl.append({"p": (b as Node2D).global_position, "v": b.get("velocity_vec"),
				"fs": b.call("rewind_state") if b.has_method("rewind_state") else {}})
	d["bullets"] = bl
	if not _rw_buf.has(r):
		_rw_buf[r] = []
	var buf: Array = _rw_buf[r]
	buf.append(d)
	var depth: float = state.time_economy.rules.rewind_buffer_seconds()
	while buf.size() > 2 and float(buf[0]["t"]) < float(buf[buf.size() - 1]["t"]) - depth:
		buf.pop_front()



func reset_time_rewind_state() -> void:
	for r in state._rw_on.keys():
		var src: PacketInputSource = state.input_sources.get(int(r), null)
		if src != null:
			src.frozen = false
		var p: Node2D = state.players.get(int(r), null)
		if p != null and is_instance_valid(p):
			p.remove_meta("time_rewinding")
	state._rw_on.clear()
	state._rw_trail.clear()
	_rw_buf.clear()
	_rw_cursor.clear()
	_rw_snap_t.clear()
	_rw_t0.clear()


func _apply_rw_frame(r: int, p: Node2D, cursor: float) -> void:
	var buf: Array = _rw_buf.get(r, [])
	if buf.size() < 2:
		return
	var target := float(buf[buf.size() - 1]["t"]) - cursor
	var f: Dictionary = buf[0]
	for e in buf:
		if float(e["t"]) <= target:
			f = e
		else:
			break
	if p.has_method("rewind_restore"):
		p.rewind_restore(f)




func _detach_role(role: int) -> bool:
	role = int(role)
	if state._left.has(role):
		return false
	state._left[role] = true
	state._respawn_pending.erase(role)
	state._down_counted[role] = true
	if state.players.has(role):
		var p: Node = state.players[role]
		if is_instance_valid(p):
			p.queue_free()
		state.players.erase(role)
	if state.input_sources.has(role):
		state.input_sources.erase(role)
	state.peer_by_role.erase(role)
	return true


func _finish_match() -> void:
	state._round_state = MatchState.RoundState.MATCH_OVER
	_broadcast_round_state()


func _attributed_killer(victim: Node2D) -> int:
	return state._attributed_role_within(victim, MatchState.ATTRIB_WINDOW)


static func prepare_map(map_path: String) -> void:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()


static func ensure_spawn_grid(map_path: String) -> void:
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()


func _rpc_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in state.peer_by_role:
		if role == except_role or not state.players.has(role):
			continue
		var peer: int = state.peer_by_role[role]
		if live_only and not NetBus.is_peer_live(peer):
			continue

		NetBus.callv("rpc_id", [peer, method] + args)



func _rpc_all_ext(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in state.peer_by_role:
		if role == except_role or not state.players.has(role):
			continue
		var peer: int = state.peer_by_role[role]

		if live_only and not NetBus.is_peer_live(peer):
			continue

		NetBusExt.callv("rpc_id", [peer, method] + args)




func _send_round_state(data: Dictionary) -> void:
	GraceWindow.merge_into(data, grace_snapshot)
	_rpc_all("round_state", [data])






func _spawn_cell(role: int) -> Vector2i:
	var r := int(role)
	var points := state.map_respawn_points(state._duel_side(r))
	if points.is_empty():
		state._warn_legacy_spawn()
		return state._legacy_spawn_cell(r)
	if not state._duel_placed.has(r) and state._duel_spawns.has(r):
		state._duel_placed[r] = true
		return state._duel_spawns[r]
	state._duel_placed[r] = true
	var anchors: Array = []
	for other in state._duel_spawns:
		if int(other) != r:
			anchors.append(state._duel_spawns[other])
	var exclude: Array = []
	if state._duel_spawns.has(r):
		exclude.append(state._duel_spawns[r])
	var cell := SpawnChooser.pick(points, exclude, null, SpawnPicker.FAR_CELLS, anchors,
			SpawnPicker.grid_dims())
	if cell.x < 0:
		state._warn_legacy_spawn()
		cell = state._legacy_spawn_cell(r)
	state._duel_spawns[r] = cell
	return cell




func role_spawns() -> Dictionary:
	if state.map_respawn_points(1).is_empty() and state.map_respawn_points(2).is_empty():
		var out := {}
		for role in state.players:
			out[int(role)] = state._legacy_spawn_cell(int(role))
		return out
	return state._duel_spawns.duplicate()
