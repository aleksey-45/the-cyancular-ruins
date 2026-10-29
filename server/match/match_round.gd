class_name MatchRound
extends MatchCombat

# 回合状态机 + 复活 + 每局世界复位域;round_state / kill 广播也在这里(它们是回合事件,不是逐帧快照)。

func _match_round_tick(delta: float) -> void:
	for role in players:
# ★ MATCH_OVER 之后不再产生任何记账:没有这道闸,终局后残留的爆炸致死会让 deaths 再 +1、尸体再掉一次
# 武器、并再广播一次带新 mvp 的终局载荷。★ 只排除 MATCH_OVER —— ROUND_OVER 期间倒地照旧入账。
		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
# ★ 复活调度独立于计分闩锁:塞进 _down_counted 那道闩里,已计分的人就再也不会被安排复活。
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
# 掉落:倒地这一刻在原地丢下「除随机保留一把」外的全部武器。★ 必须在倒地边沿、不能在复活流程里 ——
# _respawn_player 会先把人瞬移到出生点,那样就掉在出生点。★ 复用 _down_counted 闩 ⇒ 每次死亡恰好丢一次。
		_drop_all_but_one(p, role)
# 逐人统计:倒地边沿记 death(一律)与击杀。★ 击杀记给对手、不分死因(自杀/溺水也让对方 +1,1v1 没有归因),
# 结算页 kills 必须与记分条同口径,否则「5 杀取胜」的局在结算页只显示 3 杀;别在这里用子类的具名归因函数 ——
# 基类并集里出现子类方法名会破坏「子类方法不得泄漏进基类」。
		_record_down(int(role), _opponent_of(int(role)))

		var scorer := _opponent_of(role)
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			_broadcast_kill(scorer, role)
			_broadcast_round_state()
# 击杀后双方复位:死者照常走 _respawn_player(2s 后满血复活);活着的一方立刻回出生点但保留血量、不回血(防复活点连杀)。
			_reset_survivor(scorer)
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
			for role in players:
				if int(_scores.get(role, 0)) >= KILLS_TO_WIN:
					_round_over(role)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass   # 对局结束,等玩家退出/服务器关房



func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)

# 重生:摆到本局出生点,血量/防水/倒地复位。★ 背包不在这里动 —— 武器早在倒地那一刻掉在原地了;
# 在这里再掉一次会掉在出生点、而且是多余的一遍。

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
# 助攻表随复活清空(新的一条命;三模式的 _respawn_player 都 super 到这里)。★ 「复活清空 ≡ 倒地清空」靠
# _down_counted 闩维持 —— 它在倒地边沿置位、只在本函数复位;把复位挪走或加一条绕开闩的倒地边沿,等价会静默失效。
	_clear_assist_table(role)



func _reset_survivor(role: int) -> void:
	if not players.has(role):
		return
	var p: Node2D = players[role]
	if p.is_downed():   # 同归于尽:双方都是死者、无活方,各走自己的复活流程
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

# 换局复位(增量,2026-10-24):只还原「被拆过的 16px 子格」—— 整图 build_sim 实测 ~0.48s ⇒ 每局卡顿。
# 与客户端 Level0.reset_destructibles() 同构:sub_hp / 可破坏碰撞子格 / 格级网格与 HP 逐格回基线,只 rebuild 脏块;
# 永久墙与攀爬条从不变化 ⇒ 永不重建。★ 兜底:名单以 damaged_subs 为准,再并上「与 _base_grid 不同的 64px 格」的 16 个子格
# (格级 destroy 路径只清子格 HP、不一定逐子格发回调;漏了它下一局就是「客户端有墙、服务器没有」)。
func _reset_world_and_clear_dynamics() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	_seen_bullets.clear()
# 地面武器清零 + 重新分布 + 各人背包重置为随机一把:与还原砖同一纪律,装备也是本局的进度。
	_reset_ground_weapons()
	if _base_grid.is_empty():
		return
	var sgrid := MazeGenerator.current_subgrid
	if sgrid.is_empty():
		return
	var sc: int = (sgrid[0] as Array).size()
	var sr: int = sgrid.size()
	# ① 收齐要还原的子格 + 就地回格级网格
	var subs: Dictionary = damaged_subs.duplicate()
	for cy in grid.size():
		var row: Array = grid[cy]
		var brow: Array = _base_grid[cy]
		for cx in row.size():
			if row[cx] == brow[cx]:
				continue
			row[cx] = brow[cx]
			for sy in 4:
				for sx in 4:
					subs[Vector2i(cx * 4 + sx, cy * 4 + sy)] = true
	# ② 逐子格还:sub_hp / 可破坏碰撞子格;顺带收脏块与涉及格
	var chunks: Dictionary = {}
	var cells: Dictionary = {}
	for key in subs:
		var sub: Vector2i = key
		if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
			continue
		var tex: int = int(sgrid[sub.y][sub.x])
		TileDefs.restore_sub(sub, TileDefs.hp_of(tex) if tex != 0 else 0)
		if not destructible_sub.is_empty():
			destructible_sub[sub.y][sub.x] = CollisionBuilder.destructible_value(tex)
		var cell := Vector2i(sub.x / 4, sub.y / 4)
		chunks[CollisionBuilder.chunk_of(cell)] = true
		cells[cell] = true
	# ③ 格级 HP 回基线(网格已在 ① 就地回;与 TileDefs.init_hp 同口径)
	for cell in cells:
		TileDefs.set_hp_grid(cell, TileDefs.hp_of(MazeGenerator.texture_of(int(_base_grid[cell.y][cell.x]))))
	# ④ 只重建脏块(不再整图 build_sim)
	for ch in chunks:
		CollisionBuilder.rebuild_chunk(destructible_sub, ch, self)
	_dirty_chunks.clear()
	damaged_subs.clear()


func _start_next_round() -> void:

	for role in players:
		if int(_rounds_won.get(role, 0)) >= ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return

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
# MVP:整场 ACS 最高者(并列 → 击杀多者 → 阵亡少者 → role 升序,权威 = 底座 mvp_role)。★ 与 match_winner 同款时机、只在 MATCH_OVER 带;1v1 也给,口径与 3v3 逐字相同、不限于胜方。
		data["mvp"] = mvp_role()
# 逐人数据只在非空时带该键(空表不占带宽,旧客户端忽略未知键)。★ 本函数是 1v1 专用:RoyaleHost 与 TeamHost 整体覆写了它。
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

# ── 广播样板 ── 原先「遍历有 peer 的 role 逐个 rpc_id」这两行在 5 处各写一遍,漏一处不报错(事件静默不发);
# 收在这里,差异用参数表达。except_role 排除射手(其客户端已本地预测画过,再收会重复);live_only 默认判活:
# 往「正在断开」的 peer 发定向包必然报错且包会丢(判据 Wire.is_peer_live);另恒跳过有 peer 却不在 players 里的 role。

func _broadcast_kill(killer: int, victim: int) -> void:
	_rpc_all(WireKind.KILL_EVENT, [killer, victim])
