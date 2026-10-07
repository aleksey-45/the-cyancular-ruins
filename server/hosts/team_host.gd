class_name TeamHost
extends MatchHost

# 3v3 团队对抗模式服务端对局宿主：
# 1. 规则：6 名玩家（两队各 3 人），三局两胜，每队先达到 9 次击杀获得一局胜利，局间整队换边；死亡 2 秒后复活。
# 2. 计分：任一玩家倒地，对方队伍得分增加 1 点。
# 3. 队友穿透：子弹穿透同队队友；两队玩家通过碰撞分层（Layer 2 与 Layer 16）实现同队穿透、敌对互挡。
# 4. 掉线处理：断线角色在宽限期内保留在场上；宽限期超时后移出对局。整队全部离开时判定弃权输掉对局。

const TEAM_KILLS_TO_WIN := 9     # 胜局所需击杀数
const TEAM_ROUNDS_TO_WIN := 2    # 胜场所需回合数
const ENDGAME_NONE := -1         # 终局胜负未决标记
const SPAWN_CLEARANCE := 15      # 两队基座之间的最小环面距离（瓦片格）
const TEAMMATE_CLEARANCE := 3    # 队内成员之间的最小环面距离（瓦片格）
const SPAWN_BASE_RADIUS := 30    # 基座周边选点搜索半径（瓦片格）
const SPAWN_MAX_TRIES := 12      # 散点规划最大重试次数
const RESPAWN_CLEARANCE := 8     # 复活点与存活对手的最小环面距离（瓦片格）
const TEAM_ENEMY_LAYER := 16     # 队伍 2 物理碰撞层

var _round_spawns: Dictionary = {}   # 本局开局出生点映射：role -> Vector2i
var _swap_spawns: Dictionary = {}    # 换边后出生点映射：role -> Vector2i
var _spawned_once: Dictionary = {}   # 首次出生标记：role -> bool
var _endgame_winner := ENDGAME_NONE  # 弃权或提前终局胜者队伍编号（1、2 或 0 表示平局）


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:
	# 确保地图网格数据在父类初始化前加载完成
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_team_of = teams.duplicate()
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
	_swap_spawns = compute_swap_spawns(_round_spawns, _team_of)
	super._init(map_path, role_peers, options, ai_roles, teams)
	_apply_team_layers()


# 根据队伍分配各玩家的物理碰撞层与掩码：
# 队伍 1 使用 Layer 2，掩码关注 Layer 16；队伍 2 使用 Layer 16，掩码关注 Layer 2；实现同队穿透、敌对互挡
func _apply_team_layers() -> void:
	for role in players:
		var p: Node2D = players[role]
		if p == null or not is_instance_valid(p):
			continue
		var t := team_of(int(role))
		if t != 1 and t != 2:
			push_error("TeamHost: role %d 的队号是 %d(不在 {1,2} 里),不配分队碰撞层" % [int(role), t])
			continue
		match t:
			1:
				p.collision_layer = 2
				p.collision_mask = (p.collision_mask & ~2) | TEAM_ENEMY_LAYER
			2:
				p.collision_layer = TEAM_ENEMY_LAYER


# ── 开局:算散点 → 逐角色 match_start → 建 TeamHost ──
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_team_spawns(teams)
	for role in role_peers:
		# 存活检测:报到与开局之间客户端可能已断开,定向可靠包发往正在断开的 peer 就是那条
		# channel 0 错误(判据见 NetBus.is_peer_live,与 RoyaleHost.start_on 相同机制)
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "3v3 开始")
	# 将计算得到的出生点同步传入宿主实例，确保服务端物理摆位与下发给客户端的位置一致
	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# 规划两队开局散点出生位置：
# 选取两个相距足够远的基座，分别在其周边为各队分配具有一定间距的散点（队内聚拢、两队相距足够安全）。
# 注意计算结果仅在开局生成一次，避免二次调用导致随机打乱不同步。
static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	var best := {}
	var best_margin := -(1 << 30)
	for _attempt in range(SPAWN_MAX_TRIES):
		var cand := _plan_team_spawns_once(teams)
		var margin := _spawn_margin(cand, teams)
		if margin > best_margin:
			best_margin = margin
			best = cand
		if margin > 0:
			break
	return best


# 单次开局出生散点采样规划
static func _plan_team_spawns_once(teams: Dictionary) -> Dictionary:
	var d := SpawnPicker.grid_dims()
	var bases: Array = GridPathfinder.spread_cells(
			SpawnPicker.spawn_candidates().duplicate(), 2, SPAWN_CLEARANCE, d.x, d.y)
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if by_team.has(t):
			by_team[t].append(int(role))
	var out := {}
	for t in [1, 2]:
		(by_team[t] as Array).sort()
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out


# 计算出生点布局的队间裕度（队间最小环面距离减去队内最大环面距离）
static func _spawn_margin(spawns: Dictionary, teams: Dictionary) -> int:
	if spawns.size() < 2:
		return 1
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 1 << 30
	var roles: Array = spawns.keys()
	roles.sort()
	for i in range(roles.size()):
		for j in range(i + 1, roles.size()):
			var dist := MazeGenerator.toroidal_dist(spawns[roles[i]], spawns[roles[j]], d.x, d.y)
			if int(teams.get(roles[i], 0)) == int(teams.get(roles[j], 0)):
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	return min_cross - max_in


# 计算局间换边后的出生点映射表（两队点位对调）
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a: Array = []
	var b: Array = []
	for role in teams:
		if int(teams[role]) == 1:
			a.append(int(role))
		else:
			b.append(int(role))
	a.sort()
	b.sort()
	var out := {}
	if a.is_empty() or a.size() != b.size():
		return out
	for i in range(a.size()):
		out[a[i]] = spawns.get(b[i], Vector2i(-1, -1))
		out[b[i]] = spawns.get(a[i], Vector2i(-1, -1))
	return out


# 获取各角色本局开局出生点映射表副本
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


# 获取角色队伍映射字典副本，供进场同步使用
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


# 选取复活点：在开阔地面瓦片中选取距离所有存活敌人满足最小间距的瓦片
func _respawn_cell_for(role: int) -> Vector2i:
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or same_team(role, int(other)):
					continue
				var op: Node2D = players[other]
				if op == null or not is_instance_valid(op) or op.is_downed():
					continue
				var oc := Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
						int(op.global_position.y) / GameParameters.TILE_SIZE)
				if MazeGenerator.toroidal_dist(c, oc, SpawnPicker.grid_dims().x,
						SpawnPicker.grid_dims().y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				return c
	return Vector2i(-1, -1)


# 角色复活时清除伤害归因元数据，防止复活后发生环境伤害时误归因给历史攻击者
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")


# 获取指定角色的对方队伍编号（未分配队伍时返回 0）
func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


# 团队回合状态机主循环：计分与胜负以队伍为单位进行结算
func _match_round_tick(delta: float) -> void:
	for role in players:
		# 对局结束后（MATCH_OVER）停止所有击杀计分、武器掉落与状态广播，防止结算后延迟伤害产生副作用
		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁(与基类相同机制:旧实现把它塞在闩锁内,曾导致复活永不安排)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 倒地瞬间在原地丢下除随机保留一把外的全部武器（与基类/大乱斗逻辑一致）。
		# 共用 _down_counted 标记，确保每次死亡仅触发一次；复活流程中不再触发掉落。
		_drop_all_but_one(p, int(role))
		# 玩家倒地统一计入 death；仅当成功归因且击杀者属于敌方队伍时计入 kill。
		# 死亡统计独立于队伍得分判定，任何原因倒地均记录为死亡。
		_record_down(int(role), _attributed_killer(p))
		# 击杀判定：任一玩家倒地，对方队伍得分增加 1 分。
		# 队友误伤或环境伤害同样为对方队伍送分。
		# 队伍得分与单人击杀数分别统计：环境倒地或误伤仅增加队分，不增加个人击杀。
		var scorer := _enemy_team_of(int(role))
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			# kill_event 载荷按角色粒度记录击杀来源（0 表示无明确归因）。
			# 客户端结合队伍信息进行映射展示。即使未识别攻击来源也照常广播。
			_broadcast_kill(_attributed_killer(p), int(role))
			_broadcast_round_state()
			# 击杀发生后击杀者保持原地不动，阵亡玩家等待复活倒计时后回本方出生点复活。
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


# 局胜切换：当某队赢得局数达到 TEAM_ROUNDS_TO_WIN 时进入 MATCH_OVER，
# 否则执行整队换边并开启下一回合。
# 换边逻辑将 _round_spawns 与 _swap_spawns 互换，并重置 _spawned_once，
# 确保新回合所有玩家刷新在换边后的队伍初始出生点。
func _start_next_round() -> void:
	if _threshold_team() != 0:
		_round_state = RoundState.MATCH_OVER
		_broadcast_round_state()
		return
	_reset_world_and_clear_dynamics()
	# 两队人数不匹配时 _swap_spawns 为空，保持原有出生点不换边
	if not _swap_spawns.is_empty():
		var tmp := _round_spawns
		_round_spawns = _swap_spawns
		_swap_spawns = tmp
	# 清空初始出生标记，使后续出生走换边后的队伍阵营点而非动态复活点
	_spawned_once.clear()
	_round_num += 1
	_scores = {}
	# 个人整场累计战绩跨局保留，仅单局比分 _scores 与复活队列每局重置
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()


# 获取对局获胜队伍编号：
# 1. 若因一方全体离开导致弃权终局，优先返回 _endgame_winner；
# 2. 正常完赛时，返回局胜达到 TEAM_ROUNDS_TO_WIN 的队伍；
# 3. 未达标保底返回当前局胜领先队伍。
func _match_winner() -> int:
	if _endgame_winner != ENDGAME_NONE:
		return _endgame_winner
	var decided := _threshold_team()
	if decided != 0:
		return decided
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# 查询局胜达到获胜阈值的队伍编号。
# 若某队局胜达到 TEAM_ROUNDS_TO_WIN 则返回对应队号（1 或 2），未决出返回 0。
func _threshold_team() -> int:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 0


# 广播当前回合与对局状态。
# scores 与 rounds_won 的键为队伍编号；队伍名单通过 match_sync 单独下发。
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
		# 整场表现分最高者获评 MVP
		data["mvp"] = mvp_role()
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	_send_round_state(data)


# 伤害归因：查询最近窗口内对受害者造成伤害的角色编号。
func _attributed_killer(victim: Node2D) -> int:
	return _attributed_role_within(victim, ATTRIB_WINDOW)


# 玩家掉线宽限期超时处理：
# 将角色移出对局；若某队伍全员离场，则判对方队伍获胜。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true
	# 记录玩家离线时所处的回合数，用于后续战绩均值结算
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
	# 统计场上仍有活跃成员的队伍
	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2 and not _decided_by_rounds():
		# 队伍全员离场判负；若两队均离场则记为平局 0
		var survivors: Array = alive_teams.keys()
		_endgame_winner = int(survivors[0]) if survivors.size() == 1 else 0
		if _round_state != RoundState.MATCH_OVER:
			_finish_match()
			return
	_broadcast_round_state()


# 检查对局是否已通过局胜阈值决出胜负。
# 用于避免离线清理逻辑误判已正常结束的对局。
func _decided_by_rounds() -> bool:
	return _threshold_team() != 0


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


# 处理客户端主动自杀脱困请求。
# 在地形卡死等异常情况下使角色倒地进入正常复活流程，清除伤害归因不计入击杀。
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


# 玩家战绩统计与伤害归因接口已整合至基类 MatchState。
# 子弹击中玩家时记录归因并发起命中判定。
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)
