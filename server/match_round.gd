class_name MatchRound
extends MatchCombat

# 回合状态机 + 复活 + 每局世界复位域(阶段 5.6 拆自 server/match_host.gd)。
# 含 round_state/kill 广播(它们是回合事件,不是逐帧快照)。

func _match_round_tick(delta: float) -> void:
	for role in players:
		# ★ MATCH_OVER 之后**不再产生任何记账**(终局后残留的爆炸致死仍会把玩家打倒地):
		#   没有这道闸,`deaths` 会 +1、尸体再掉一次武器、并**再广播一次带新 mvp 的终局载荷**。
		#   大乱斗那一支**天然没有这个问题**(它的倒地边沿住在 `RoundState.PLAYING` 分支里,
		#   见 `RoyaleHost._match_round_tick`)—— 两处形状一致是**刻意**的
		#   (三个模式的倒地边沿是**同一个契约的三份落地**),别把这句当成多余而删掉。
		#   ★ 只排除 MATCH_OVER:`ROUND_OVER` 期间倒地照旧入账(既有行为,不在本项里)。
		if _round_state == RoundState.MATCH_OVER:
			continue
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
		# 掉落:倒地**这一刻**在原地丢下"除随机保留一把"外的全部武器(用户 2026-09-21 裁定)。
		# ★ 必须在**倒地边沿**、不能在复活流程里(旧实现):`_respawn_player` 是先把人瞬移到
		#   出生点再调掉落 ⇒ 掉在出生点;而且尸体在 2s 倒地窗里继续走物理(重力/击退衰减/
		#   滑行),等到复活那一刻它早已不在死亡的那一格了。
		# ★ 复用计分那个 `_down_counted` 闩 ⇒ 每次死亡恰好丢一次(与复活那一支互不重复)。
		_drop_all_but_one(p, role)
		# 逐人统计(★ 2026-09-25):倒地边沿记 death(一律)与击杀。
		# ★ 击杀记给**对手**,口径与下面的 `scorer` 逐字一致 —— 1v1 的计分规则是
		#   「不分死因、对方死亡都算」(用户裁定),它**没有归因**:自杀/溺水也让对方 +1 分。
		#   结算页的 kills 必须与记分条同口径,否则"5 杀取胜"的局在结算页上只显示 3 杀(不报错)。
		# ★ **不能**在这里用击杀归因那个具名函数:它住子类,而基类并集里出现它的名字会让
		#   `tests/kh_l5_probe.gd:544-549` 的反向断言变红(子类方法不得泄漏进基类)。
		_record_down(int(role), _opponent_of(int(role)))
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

# 局内死亡复活:倒计时后重生(重置血量/防水/位置;背包不动 —— 武器已在倒地时掉落)。

func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)

# 重生:摆到本局出生点,血量/防水/倒地复位。
# ★ 背包**不在这里动** —— 武器早在**倒地那一刻**就掉在倒地位置了(见 `_match_round_tick`,
#   用户 2026-09-21 裁定「死亡后直接原地掉落」);这里再掉一次会掉在出生点、且是多余的一遍。

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
	# 助攻表:复活 = 新的一条命,上一次倒地之前的命中历史作废(与"助攻只算这一次倒地之前"一致)。
	# ★ 住在这里一处覆盖三模式 —— 另两个模式的 `_respawn_player` 都 `super` 到本函数。
	# ★ "复活点清空 ≡ 倒地点清空"这个**等价**成立,但**理由不是** `take_hit` 在 `downed` 时
	#   早退(`scenes/player/combat_component.gd:43`)—— 那道早退只挡住**新写入**,倒地窗里
	#   **旧条目仍留在表里**(它没被抹掉,只是没人再读)。真正让两者等价的是 **`_down_counted` 闩**:
	#   `_match_round_tick` 在倒地边沿置位、**只在本函数**复位 ⇒ 同一个受害者在复活之前
	#   **不可能**再进一次 `_record_down`,于是"倒地清空"没有任何"复活清空"做不到的事。
	#   ★ 将来若把 `_down_counted` 的复位挪走、或加一条绕开闩的倒地边沿,这个等价会**静默失效**。
	# ★ 选复活点还与 spec §3.4 的口径逐字一致,且它才是玩家"重新开始"的语义点。
	_clear_assist_table(role)

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
	# 地面武器:清零 + 重新分布 + 各人背包重置为随机一把。
	# 与"还原可破坏砖 + 清子弹"同一纪律 —— 两端每局从同一基线出发,装备也是本局的进度。
	_reset_ground_weapons()
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
		# MVP:整场 ACS 最高者(并列 → 击杀多者 → 阵亡少者 → role 升序,见底座 `mvp_role`)。
		# ★ 与 `match_winner` **同款时机**:只在 MATCH_OVER 带(局中还没有"整场"可言)。
		# ★ 1v1 也给 —— spec §4 明说"1v1 也可给";口径与 3v3 **逐字相同**,不限制在胜方
		#   (换公式之后"MVP 常在败方"的那个结构性来源已经没了,见 spec §1.3)。
		data["mvp"] = mvp_role()
	# 逐人数据:与 `destroyed` / `ground_weapons` / 3v3 同款纪律 —— **只在非空时带该键**
	# (1v1 只有两个 role,一次广播多几十字节;空表不占带宽,旧客户端忽略未知键)。
	# ★ 本函数是 **1v1 专用**:`RoyaleHost` 与 `TeamHost` 都整体覆写了 `_broadcast_round_state`,
	#   不会与本段叠加(同一份数据只投递一次)。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
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
#   · live_only :只发给在线 peer。★ 2026-09-17 起**默认改为 是**(原是"只有 round_state 那两处
#                 判在线",而八个调用点里只有大乱斗那处传 true —— 其余七处不判,正是那条
#                 `Unable to send packet on channel 0` 的主要来源)。判据是 `NetBus.is_peer_live`
#                 (读 ENet peer 自己的 state):往"正在断开"的 peer 发**定向**包必然报错且包会丢
#                 (广播那条由 ENet 自己跳过,不受影响)。发不出去的包本来也没有意义,故默认判活。
#                 传 false 只在"明知对方即将离开、但这条必须试一次"这类场景才有意义 —— 目前没有。
# 另恒跳过「有 peer 但不在 `players` 里」的 role(原实现里两处显式这么判,另三处没写 ——
# 正常路径下二者同键集,故这里统一加上既是等价、又消掉那处不一致)。

func _broadcast_kill(killer: int, victim: int) -> void:
	_rpc_all("kill_event", [killer, victim])
