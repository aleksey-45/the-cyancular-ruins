class_name MatchRound
extends MatchCombat

# 回合状态机 + 复活 + 每局世界复位域;round_state / kill 广播也在这里(它们是回合事件,不是逐帧快照)。

# 开局 3s 倒计时必须等客户端**场景建好**再开始:服务器建局时客户端还在切场景,
# 那一刻广播的 COUNTDOWN 会丢在"场景未就绪"窗口里(用户实见:倒计时数字不对/跳秒)。
# 判据 = 该 role 已发 match_sync(客户端场景 _ready 里发);上限 COUNTDOWN_HOLD_MAX 秒,超时照常开局。
const COUNTDOWN_HOLD_MAX := 2.0
var _countdown_hold := COUNTDOWN_HOLD_MAX
var _client_ready: Dictionary = {}       # role(int) -> true:该客户端场景已就绪
# 开局那次 COUNTDOWN 广播落在"客户端还在切场景"的窗口里会被丢掉(信号无订阅方)⇒ 就绪后**补发一次**,
# 让 HUD 从 3 起走、且与服务器时钟同拍;之后每局换局时复位。
var _countdown_bcast_done := false
# ★ 倒计时期间每 0.5s 重播一次「当前剩余」(三模式共用,见 _countdown_resync_tick)。
var _countdown_resync := 0.0


# COUNTDOWN 期间的重播节拍(2026-11-01):客户端从「收到那一刻」起自己走秒,而它可能晚到(场景加载 / 重连),
const COUNTDOWN_RESYNC := 0.5


func _countdown_resync_tick(delta: float) -> void:
	_countdown_resync -= delta
	if _countdown_resync <= 0.0:
		_countdown_resync = COUNTDOWN_RESYNC
		_broadcast_round_state()


func mark_client_ready(role: int) -> void:
	_client_ready[int(role)] = true


func _countdown_can_start(delta: float) -> bool:
	var waiting := false
	for role in players:
		if not peer_by_role.has(int(role)):
			continue   # AI 补位没有客户端场景,不等它
		if not bool(_client_ready.get(int(role), false)):
			waiting = true
			break
	if not waiting:
		return true
	_countdown_hold = maxf(_countdown_hold - delta, 0.0)
	return _countdown_hold <= 0.0


func _match_round_tick(delta: float) -> void:
	for role in players:
# ★ MATCH_OVER 之后不再产生任何记账:没有这道闸,终局后残留的爆炸致死会让 deaths 再 +1、尸体再掉一次
# 武器、并再广播一次带新 mvp 的终局载荷。★ 只排除 MATCH_OVER —— ROUND_OVER 期间倒地照旧入账。
		if _round_state == RoundState.MATCH_OVER:
			continue
		var p := players[role] as Player
		if not p.is_downed():
			continue
# ★ 复活调度独立于计分闩锁:塞进 _down_counted 那道闩里,已计分的人就再也不会被安排复活。
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		_on_down_edge(int(role))
	match _round_state:
		RoundState.COUNTDOWN:
			if not _countdown_can_start(delta):
				return   # 客户端场景还没建好:时钟先不走,免得倒计时数字从中间开始
			if not _countdown_bcast_done:
				_countdown_bcast_done = true
				_broadcast_round_state()   # 就绪后补发 COUNTDOWN(timer=3),HUD 从 3 起走、与服务器同拍
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING

				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
			else:
				_countdown_resync_tick(delta)
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
			pass   # 对局结束:全员离开由 server_main._on_peer_left 立刻收场(见 MatchExitRules);留在结算页的人走 MATCH_OVER_LINGER 兜底



# ── 倒地边沿的公共骨架(S-15)── 三模式同形:掉武器 → 算 killer → 记 death/kills → 记分/广播。
# ★ 只在**各模式自己的相位**里被调用(1v1/3v3 在 _round_state 判断之外、大乱斗关在 PLAYING 里):本函数不搬相位。
# ★ 差异全交给两个虚函数(1v1 默认:击杀记给对手、分记给对手、击杀后复位幸存者;大乱斗/3v3 覆写成归因制/队分)。
func _on_down_edge(role: int) -> void:
	var p: Node2D = players[int(role)]
	_drop_all_but_one(p, int(role))
	var killer := _down_killer_of(int(role))
	_record_down(int(role), killer)
	_award_down(int(role), killer)


# 这次死亡算谁的击杀。默认 = 1v1 口径(对手、不分死因);大乱斗/3v3 覆写成归因制(meta last_damager)。
func _down_killer_of(role: int) -> int:
	return _opponent_of(int(role))


# 记分 / kill 广播 / 幸存者复位。★ 三个模式在这块的**广播时机**本就不同(1v1 只在 scorer != 0 时、大乱斗无条件、
# 3v3 在 scorer != 0 时),故保持各自原样留在覆写里 —— 抽的是骨架,不是把三套口径合成一套。
func _award_down(victim_role: int, killer_role: int) -> void:
	var scorer := _opponent_of(victim_role)
	if scorer == 0:
		return
	_scores[scorer] = int(_scores.get(scorer, 0)) + 1
	_broadcast_kill(scorer, victim_role)
	_broadcast_round_state()
# 击杀后双方复位:死者照常走 _respawn_player(2s 后满血复活);活着的一方立刻回出生点但保留血量、不回血(防复活点连杀)。
	_reset_survivor(scorer)


func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)

# 重生:摆到本局出生点,血量/防水/倒地复位。★ 背包不在这里动 —— 武器早在倒地那一刻掉在原地了;
# 在这里再掉一次会掉在出生点、而且是多余的一遍。

func _respawn_player(role: int) -> void:
	var p := players[role] as Player
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.apply_authoritative_state(p.max_hp, p.max_waterproof, false)
	p.cancel_jump_state()
	_respawn_pending.erase(role)
	_down_counted[role] = false
# 助攻表随复活清空(新的一条命;三模式的 _respawn_player 都 super 到这里)。★ 「复活清空 ≡ 倒地清空」靠
# _down_counted 闩维持 —— 它在倒地边沿置位、只在本函数复位;把复位挪走或加一条绕开闩的倒地边沿,等价会静默失效。
	_clear_assist_table(role)



func _reset_survivor(role: int) -> void:
	if not players.has(role):
		return
	var p := players[role] as Player
	if p.is_downed():   # 同归于尽:双方都是死者、无活方,各走自己的复活流程
		return
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.cancel_jump_state()


func _round_over(winner: int) -> void:
	_last_round_winner = winner
	_rounds_won[winner] = int(_rounds_won.get(winner, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()

# 换局复位(增量,2026-10-24):只还原「被拆过的 16px 子格」—— 整图 build_sim 实测 ~0.48s ⇒ 每局卡顿。
func _reset_world_and_clear_dynamics() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	_seen_bullets.clear()
# 地面武器清零 + 重新分布 + 各人背包重置为随机一把:与还原砖同一纪律,装备也是本局的进度。
	_reset_ground_weapons()
	# ★ BUG-04(2026-10-30):回溯环必须随换局复位 —— 否则新一局能回放到上一局的活体帧。
	#   放在早退(无基线/无子格)之前:即使这一局没有可拆砖,回溯环也照样要清。
	if has_method("reset_time_rewind_state"):
		call("reset_time_rewind_state")
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


# 终局判定(给 server_main 的「终局滞留到点收场」用:全员离开由 _on_peer_left 立刻收场,滞留只兜「有人赖在结算页不走」)。
func is_match_over() -> bool:
	return _round_state == RoundState.MATCH_OVER


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
	_countdown_hold = COUNTDOWN_HOLD_MAX
	_countdown_bcast_done = false   # 就绪闸打开时再补发一次(见 COUNTDOWN 分支)
	_countdown_resync = COUNTDOWN_RESYNC
	_broadcast_round_state()


# round_state 载荷的**三模式共有骨架**:5 个共有键 + MATCH_OVER 的 match_winner + 非空的 stats。
func _round_state_base() -> Dictionary:
	var data := {
		"state": _round_state,
		"round": _round_num,
		"scores": _scores,
		"rounds_won": _rounds_won,
		"timer": _round_timer,
	}
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
# 逐人数据只在非空时带该键(空表不占带宽,旧客户端忽略未知键)。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	return data


# ★ 本函数是 1v1 专用:RoyaleHost 与 TeamHost 整体覆写了 _broadcast_round_state(它们不走这里)。
func round_state_payload() -> Dictionary:
	var data := _round_state_base()
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		# MVP:胜方内整场 ACS 最高者(并列 → 击杀多者 → 阵亡少者 → role 升序,权威 = 底座 mvp_role)。
		# ★★ 2026-10-30 用户裁定「明明赢了,全场最佳却是对面」= bug ⇒ 候选集 = [胜者 role](平局 w==0 才放开全场)。
		#    与 match_winner 同款时机、只在 MATCH_OVER 带;1v1 也给,候选规则与 3v3 同源(`mvp_role(candidates)`)。
		var w := int(data["match_winner"])   # 骨架已算过同一个值,不重复调 _match_winner()
		data["mvp"] = mvp_role([w] if w != 0 else [])
	return data


func _broadcast_round_state() -> void:
	_send_round_state(round_state_payload())


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
# 往「正在断开」的 peer 发定向包必然报错且包会丢(判据 NetBus.is_peer_live);另恒跳过有 peer 却不在 players 里的 role。

func _broadcast_kill(killer: int, victim: int) -> void:
	_rpc_all("kill_event", [killer, victim])
