class_name MatchRound
extends MatchCombat

# 回合状态机与生命周期管理：处理回合倒计时、击杀判定、复活调度及换局世界重置。
# 包含 round_state 与 kill 事件广播。

func _match_round_tick(delta: float) -> void:
	for role in players:
		# 对局结束后不再进行倒地与击杀记账
		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 处于比赛进行状态且未安排复活时，安排延迟复活任务
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 角色倒地时原地掉落除随机保留一把之外的全部武器
		_drop_all_but_one(p, role)
		# 记录倒地与击杀统计数据
		_record_down(int(role), _opponent_of(int(role)))
		# 1v1 规则下对手倒地计分加 1
		var scorer := _opponent_of(role)
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			_broadcast_kill(scorer, role)
			_broadcast_round_state()
			# 击杀后存活方立即复位至己方出生点（保留当前血量，防止复活点压制）
			_reset_survivor(scorer)
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				# 开启回合满血配置时，回合开始恢复满血与防水
				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
		RoundState.PLAYING:
			_handle_respawns(delta)
			for role in players:
				if int(_scores.get(role, 0)) >= KILLS_TO_WIN:
					_round_over(role)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass   # 对局结束，等待玩家退出或大厅回收房间

# 局内延迟复活处理：倒计时结束后重置角色状态并重新放置至出生点
func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)


# 角色复活：重置位置至出生点，恢复满生命值与防水值
func _respawn_player(role: int) -> void:
	var p: Node2D = players[role]
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.apply_authoritative_state(p.max_hp, p.max_waterproof, false)
	if p.has_method("cancel_jump_state"):
		p.cancel_jump_state()
	_respawn_pending.erase(role)
	_down_counted[role] = false
	# 复活后清空该角色的助攻记录表
	_clear_assist_table(role)


# 存活方击杀后瞬移复位至己方出生点（保留当前血量，防止复活点压制）
func _reset_survivor(role: int) -> void:
	if not players.has(role):
		return
	var p: Node2D = players[role]
	if p.is_downed():   # 双方同归于尽时各自进入复活流程
		return
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	if p.has_method("cancel_jump_state"):
		p.cancel_jump_state()


func _round_over(winner: int) -> void:
	_last_round_winner = winner
	_rounds_won[winner] = int(_rounds_won.get(winner, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()


# 换局状态重置：清理场上动态子弹，并将可破坏地形与地面武器重置为初始基线状态
func _reset_world_and_clear_dynamics() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	_seen_bullets.clear()
	# 地面武器重新分布并将各角色手持武器重置为随机一把
	_reset_ground_weapons()
	if _base_grid.is_empty():
		return
	var g := MazeGenerator.copy_grid(_base_grid)
	grid = g
	MazeGenerator.current_grid = g
	TileDefs.init_hp(g)
	destructible_sub = WorldBuilder.build_sim(self, g)


func _start_next_round() -> void:
	# 三局两胜判定：先达胜场阈值者获胜并结束对局
	for role in players:
		if int(_rounds_won.get(role, 0)) >= ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	# 换边并开启下一小局
	_reset_world_and_clear_dynamics()
	_side_swap = not _side_swap
	_round_num += 1
	_scores = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()


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


func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	for role in players:
		var n: int = int(_rounds_won.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
	return best_role


# 统一广播辅助方法：遍历在线客户端发送击杀事件
func _broadcast_kill(killer: int, victim: int) -> void:
	_rpc_all("kill_event", [killer, victim])

