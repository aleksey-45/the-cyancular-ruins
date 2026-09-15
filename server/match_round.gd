class_name MatchRound
extends MatchCombat

# 回合状态机 + 复活 + 每局世界复位域(阶段 5.6 拆自 server/match_host.gd)。
# 含 round_state/kill 广播(它们是回合事件,不是逐帧快照)。

func _match_round_tick(delta: float) -> void:
	for role in players:
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁:PLAYING 内倒地、未安排复活即安排。
		# (旧实现把调度塞在计分闩锁内,且读击杀用 get_meta_or_null —— 该方法 Godot 4.7 不存在,
		#  倒地判定在赋值 killer 时抛错中断 → 复活永不安排、击杀不计分、局永远推不完。)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 击杀定义:对方死亡都算 —— 不分死因(枪杀/爆炸/溺水/自伤/无射手)一律记给对方 +1。
		# (旧实现靠 pvp_killer 射手归因、无射手不计分,已废弃。)
		var scorer := _opponent_of(role)
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			_broadcast_kill(scorer, role)
			_broadcast_round_state()
			# 击杀后双方复位:死者照常走 _respawn_player(2s 后满血复活);
			# 活着的「我方」立刻回本方出生点但保留当前血量(不回血,防复活点连杀)。
			_reset_survivor(scorer)
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				# 选项:回合开始双方回满血(倒计时结束时生效,含换局后的第一拍)
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

# 局内死亡复活:倒计时后重生(重置血量/防水/位置/武器)。

func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)

# 重生:摆到本局出生点,血量/防水/倒地复位,武器回 1。

func _respawn_player(role: int) -> void:
	var p: Node2D = players[role]
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.apply_authoritative_state(p.max_hp, p.max_waterproof, false)
	if p.has_method("cancel_jump_state"):
		p.cancel_jump_state()
	if p.weapons != null and p.weapons.has_method("equip"):
		p.weapons.equip(p.weapons.default_slot())   # 禁用武器闸门下回槽 1 会踩禁用槽(原为 equip("1"))
	_respawn_pending.erase(role)
	_down_counted[role] = false

# 击杀后活方「复位」:回到本方出生点但保留血量/防水,不治疗。死者(另一 role)照常满血复活。

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

# 换局复位(服务器权威):清掉场上所有子弹 + 把可破坏砖/碰撞整层还原为建局基线。
# 客户端在同一时刻收到新一轮 COUNTDOWN 也做同款复位(Level0.reset_destructibles),
# 双方从同一基线出发 → 消除"客户端多拆/少拆砖"造成的幽灵碰撞,旧子弹不跨局残留。

func _reset_world_and_clear_dynamics() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	_seen_bullets.clear()
	if _base_grid.is_empty():
		return
	var g := MazeGenerator.copy_grid(_base_grid)
	grid = g
	MazeGenerator.current_grid = g
	TileDefs.init_hp(g)
	destructible_sub = WorldBuilder.build_sim(self, g)


func _start_next_round() -> void:
	# 三局两胜:先赢 2 局 → MATCH_OVER
	for role in players:
		if int(_rounds_won.get(role, 0)) >= ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	# 换边 + 下一局
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
	# 客户端按自己 role 播报"本局胜利/落败"(ROUND_OVER)与"胜利/失败"(MATCH_OVER)
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	_rpc_all("round_state", [data])


func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	for role in players:
		var n: int = int(_rounds_won.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
	return best_role

# ── 广播样板 ──
# 「遍历有 peer 的 role 逐个 rpc_id」这两行原先在**5 处**各写一遍(拆墙/子弹/光束/回合状态/击杀),
# 各处只差过滤条件。新增一种事件就要改 5 处、且漏一处**不报错**(事件静默不发)。收在此处,
# 差异用参数表达;`RoyaleHost` 覆写的 `_broadcast_round_state` 也复用它。
#
# 过滤参数:
#   · except_role:排除该 role(子弹/光束广播要排除射手 —— 射手客户端已本地预测画过,再收会重复);
#   · live_only :只发给在线 peer(默认 **否**,与多数站点的既有语义一致:只有 round_state 那两处
#                 判在线)。判在线的理由见 `_peer_online` 那段注释:往"正在断开"的 peer 发包会打
#                 channel 错误且包会丢。
# 另恒跳过「有 peer 但不在 `players` 里」的 role(原实现里两处显式这么判,另三处没写 ——
# 正常路径下二者同键集,故这里统一加上既是等价、又消掉那处不一致)。

func _broadcast_kill(killer: int, victim: int) -> void:
	_rpc_all("kill_event", [killer, victim])
