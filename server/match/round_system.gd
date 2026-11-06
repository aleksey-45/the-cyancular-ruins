class_name RoundSystem
extends RefCounted


var _state: MatchState = null
var _ports: MatchPorts = null
var _ground: GroundSystem = null


func bind(state: MatchState, ports: MatchPorts, ground: GroundSystem) -> void:
	_state = state
	_ports = ports
	_ground = ground


func countdown_resync_tick(delta: float) -> void:
	_state._countdown_resync -= delta
	if _state._countdown_resync <= 0.0:
		_state._countdown_resync = MatchState.COUNTDOWN_RESYNC
		_ports.broadcast_round_state.call()


func mark_client_ready(role: int) -> void:
	_state._client_ready[int(role)] = true


func countdown_can_start(delta: float) -> bool:
	var waiting := false
	for role in _state.players:
		if not _state.peer_by_role.has(int(role)):
			continue
		if not bool(_state._client_ready.get(int(role), false)):
			waiting = true
			break
	if not waiting:
		return true
	_state._countdown_hold = maxf(_state._countdown_hold - delta, 0.0)
	return _state._countdown_hold <= 0.0


func tick(delta: float) -> void:
	for role in _state.players:
		if _state._round_state == MatchState.RoundState.MATCH_OVER:
			continue
		var p := _state.players[role] as Player
		if not p.is_downed():
			continue
		if _state._round_state == MatchState.RoundState.PLAYING and not _state._respawn_pending.has(role):
			_state._respawn_pending[role] = MatchState.RESPAWN_DELAY
		if _state._down_counted.get(role, false):
			continue
		_state._down_counted[role] = true
		on_down_edge(int(role))
	match _state._round_state:
		MatchState.RoundState.COUNTDOWN:
			if not countdown_can_start(delta):
				return
			if not _state._countdown_bcast_done:
				_state._countdown_bcast_done = true
				_ports.broadcast_round_state.call()
			_state._round_timer -= delta
			if _state._round_timer <= 0.0:
				_state._round_state = MatchState.RoundState.PLAYING
				if _state._round_full_heal:
					for heal_role in _state.players:
						(_state.players[heal_role] as Node).apply_authoritative_state(
								(_state.players[heal_role] as Node).max_hp,
								(_state.players[heal_role] as Node).max_waterproof, false)
				_ports.broadcast_round_state.call()
			else:
				countdown_resync_tick(delta)
		MatchState.RoundState.PLAYING:
			handle_respawns(delta)
			for role in _state.players:
				if int(_state._scores.get(role, 0)) >= MatchState.KILLS_TO_WIN:
					round_over(role)
					break
		MatchState.RoundState.ROUND_OVER:
			_state._round_timer -= delta
			if _state._round_timer <= 0.0:
				_ports.start_next_round.call()
		MatchState.RoundState.MATCH_OVER:
			pass


func on_down_edge(role: int) -> void:
	var p: Node2D = _state.players[int(role)]
	_ground.drop_all_but_one(p, int(role))
	var killer: int = int(_ports.down_killer_of.call(int(role)))
	_state._record_down(int(role), killer)
	_ports.award_down.call(int(role), killer)


func down_killer_of(role: int) -> int:
	return _state._opponent_of(int(role))


func award_down(victim_role: int, killer_role: int) -> void:
	var scorer := _state._opponent_of(victim_role)
	if scorer == 0:
		return
	_state._scores[scorer] = int(_state._scores.get(scorer, 0)) + 1
	broadcast_kill(scorer, victim_role)
	_ports.broadcast_round_state.call()
	reset_survivor(scorer)


func handle_respawns(delta: float) -> void:
	for role in _state._respawn_pending.keys():
		_state._respawn_pending[role] = float(_state._respawn_pending[role]) - delta
		if _state._respawn_pending[role] <= 0.0:
			_ports.respawn_player.call(int(role))


func respawn_player(role: int) -> void:
	var p := _state.players[role] as Player
	var spawn: Vector2i = _ports.spawn_cell.call(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.apply_authoritative_state(p.max_hp, p.max_waterproof, false)
	p.cancel_jump_state()
	_state._respawn_pending.erase(role)
	_state._down_counted[role] = false
	_state._clear_assist_table(role)


func reset_survivor(role: int) -> void:
	if not _state.players.has(role):
		return
	var p := _state.players[role] as Player
	if p.is_downed():
		return
	var spawn: Vector2i = _ports.spawn_cell.call(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.cancel_jump_state()


func round_over(winner: int) -> void:
	_state._last_round_winner = winner
	_state._rounds_won[winner] = int(_state._rounds_won.get(winner, 0)) + 1
	_state._round_state = MatchState.RoundState.ROUND_OVER
	_state._round_timer = MatchState.ROUND_OVER_TIME
	_ports.broadcast_round_state.call()


# 换局复位(增量):只还原被拆过的 16px 子格(整图 build_sim 实测 ~0.48s ⇒ 每局卡顿)。
func reset_world_and_clear_dynamics() -> void:
	for b in _ports.scene_bullets.call():
		if is_instance_valid(b):
			(b as Node).queue_free()
	_state._seen_bullets.clear()
	_ground.reset()
	# 回溯环必须随换局复位(否则新一局能回放到上一局的活体帧);放在早退之前。
	_ports.reset_time_rewind_state.call()
	if _state._base_grid.is_empty():
		return
	var sgrid := MazeGenerator.current_subgrid
	if sgrid.is_empty():
		return
	var sc: int = (sgrid[0] as Array).size()
	var sr: int = sgrid.size()
	var subs: Dictionary = _state.damaged_subs.duplicate()
	var grid: Array = _state.grid
	for cy in grid.size():
		var row: Array = grid[cy]
		var brow: Array = _state._base_grid[cy]
		for cx in row.size():
			if row[cx] == brow[cx]:
				continue
			row[cx] = brow[cx]
			for sy in 4:
				for sx in 4:
					subs[Vector2i(cx * 4 + sx, cy * 4 + sy)] = true
	var chunks: Dictionary = {}
	var cells: Dictionary = {}
	var dsub: Array = _state.destructible_sub
	for key in subs:
		var sub: Vector2i = key
		if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
			continue
		var tex: int = int(sgrid[sub.y][sub.x])
		TileDefs.restore_sub(sub, TileDefs.hp_of(tex) if tex != 0 else 0)
		if not dsub.is_empty():
			dsub[sub.y][sub.x] = CollisionBuilder.destructible_value(tex)
		var cell := Vector2i(sub.x / 4, sub.y / 4)
		chunks[CollisionBuilder.chunk_of(cell)] = true
		cells[cell] = true
	for cell in cells:
		TileDefs.set_hp_grid(cell, TileDefs.hp_of(MazeGenerator.texture_of(int(_state._base_grid[cell.y][cell.x]))))
	for ch in chunks:
		_ports.scene_rebuild_chunk.call(ch)
	_state._dirty_chunks.clear()
	_state.damaged_subs.clear()


func is_match_over() -> bool:
	return _state._round_state == MatchState.RoundState.MATCH_OVER


func start_next_round() -> void:
	for role in _state.players:
		if int(_state._rounds_won.get(role, 0)) >= MatchState.ROUNDS_TO_WIN:
			_state._round_state = MatchState.RoundState.MATCH_OVER
			_ports.broadcast_round_state.call()
			return
	reset_world_and_clear_dynamics()
	_state._side_swap = not _state._side_swap
	_state._round_num += 1
	_state._scores = {}
	_state._respawn_pending = {}
	_state._down_counted = {}
	for role in _state.players:
		_ports.respawn_player.call(int(role))
	_state._round_state = MatchState.RoundState.COUNTDOWN
	_state._round_timer = MatchState.COUNTDOWN_TIME
	_state._countdown_hold = MatchState.COUNTDOWN_HOLD_MAX
	_state._countdown_bcast_done = false
	_state._countdown_resync = MatchState.COUNTDOWN_RESYNC
	_ports.broadcast_round_state.call()


func round_state_base() -> Dictionary:
	var data := {
		"state": _state._round_state,
		"round": _state._round_num,
		"scores": _state._scores,
		"rounds_won": _state._rounds_won,
		"timer": _state._round_timer,
	}
	if _state._round_state == MatchState.RoundState.MATCH_OVER:
		data["match_winner"] = _ports.match_winner.call()
	var table := _state.stats_payload()
	if not table.is_empty():
		data["stats"] = table
	return data


func round_state_payload() -> Dictionary:
	var data := round_state_base()
	if _state._round_state == MatchState.RoundState.ROUND_OVER and _state._last_round_winner != 0:
		data["winner"] = _state._last_round_winner
	if _state._round_state == MatchState.RoundState.MATCH_OVER:
		var w := int(data["match_winner"])
		data["mvp"] = _state.mvp_role([w] if w != 0 else [])
	return data


func broadcast_round_state() -> void:
	_ports.send_round_state.call(round_state_payload())


func match_winner() -> int:
	var best_role := 0
	var best_n := -1
	for role in _state.players:
		var n: int = int(_state._rounds_won.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
	return best_role


func broadcast_kill(killer: int, victim: int) -> void:
	_ports.net_rpc_role_all.call("kill_event", [killer, victim])
