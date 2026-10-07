class_name RoyaleHost
extends MatchHost

# 大乱斗模式服务端对局宿主：
# 1. 玩家分散在地图各处出生；倒地后 2 秒自动复活，复活点动态选取距离存活对手较远的地面瓦片。
# 2. 限时死斗机制：倒计时归零时对局结束，按总击杀数决定胜者（分数并列时判定为平局）。
# 3. 击杀归因机制：受到子弹或爆炸伤害时记录伤害来源，在角色倒地时结算击杀者得分；环境死亡与自杀不计分。
# 4. 状态同步机制：通过 round_state 载荷定期广播得分排行榜、剩余时长、角色存活状态与离开标记。
# 5. 玩家掉线处理：掉线玩家移出对局并释放角色节点；当场上存活角色不足 2 人时提前结束对局。

const MATCH_TIME := 300.0        # 对局总时长（秒）
const HUD_SYNC_INTERVAL := 1.0   # 倒计时与比分广播间隔（秒）
const RESPAWN_CLEARANCE := 8     # 复活点与存活对手的最小环面距离（瓦片格）
const SPAWN_CLEARANCE := 15      # 开局散点之间的最小环面距离（瓦片格）

var _match_time := MATCH_TIME
var _cfg_match_time := 0.0             # 自定义对局时长（秒，0 表示使用默认时长）
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}    # 开局出生点分配表：role -> Vector2i
var _spawned_once: Dictionary = {}    # 首次出生标记：role -> bool（首次使用预设散点，后续走动态复活选点）


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}) -> void:
	# 确保地图网格数据在父类初始化前加载完成
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	# 出生点优先使用外部传入的统一规划结果；若未传入则在此保底计算
	_round_spawns = spawns if not spawns.is_empty() else plan_spawns(role_peers.keys() + ai_roles)
	_cfg_match_time = float(options.get("match_time", 0.0))
	super._init(map_path, role_peers, options, ai_roles)


# 启动大乱斗对局：规划散点出生位置、下发开局通知并创建宿主实例
# ai_roles: 服务端驱动的 AI 补位角色列表，无需发送网络开局通知
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# plan_spawns 依赖 current_grid:先预载网格(MatchHost._init 里再 load_grid 幂等)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_spawns(role_peers.keys() + ai_roles)
	for role in role_peers:
		# 检查对端在线状态，避免向已断开连接的客户端发送 RPC
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "大乱斗开始")
	# 将规划好的开局出生点传入宿主实例，确保服务端角色放置与客户端接收到的出生点一致
	var host := RoyaleHost.new(map_path, role_peers, options, ai_roles, spawns)
	return host


# ── 出生点几何查询（转发至 SpawnPicker）──
static func _grid_dims() -> Vector2i:
	return SpawnPicker.grid_dims()

# 计算两点之间的环面瓦片距离
static func _tdist(a: Vector2i, b: Vector2i) -> int:
	var d := _grid_dims()
	return MazeGenerator.toroidal_dist(a, b, d.x, d.y)

static func _floor_cells() -> Array:
	return SpawnPicker.floor_cells()


static func _floor_cells_has(c: Vector2i) -> bool:
	return SpawnPicker.floor_cells_has(c)


static func _region_sizes() -> Dictionary:
	return SpawnPicker.region_sizes()


static func _roomy_floor(c: Vector2i) -> bool:
	return SpawnPicker.roomy_floor(c)


static func _spawn_candidates() -> Array:
	return SpawnPicker.spawn_candidates()


# 复活候选瓦片池（由开阔区域到普通连通区逐级回退）
static func _respawn_pools() -> Array:
	return SpawnPicker.respawn_pools()


# 开局散点规划：在优选出生瓦片中选取两两环面距离满足间距要求的散点；不足时从普通地面瓦片补齐
# roles: 实际参战角色列表（可能因缺员开局而不连续）
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var d := _grid_dims()
	# 使用环面分散点位算法选取出生点
	var picked: Array = GridPathfinder.spread_cells(
		_spawn_candidates().duplicate(), n, SPAWN_CLEARANCE, d.x, d.y)
	# 候选点不足时（极小地图或连通区受限），回退至任意可用地面瓦片进行补足，避免出生在非法坐标
	if picked.size() < n:
		var rest: Array = _floor_cells().duplicate()
		for c in picked:
			rest.erase(c)
		rest.shuffle()
		for c in rest:
			if picked.size() >= n:
				break
			picked.append(c)
	var out := {}
	for i in range(n):
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 获取各角色开局出生点映射表副本：
# 首次出生使用预分配的开局散点，后续死亡复活通过 _spawn_cell 动态选择远离存活对手的瓦片
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(role, Vector2i(-1, -1))
	for pool: Array in _respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		var far: Array = []
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or _left.has(int(other)):
					continue
				var op: Node2D = players[other]
				if op.is_downed():
					continue
				if _tdist(c,
						Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
								int(op.global_position.y) / GameParameters.TILE_SIZE)) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				far.append(c)
		if not far.is_empty():
			return far[0]
	return Vector2i(-1, -1)


func _ready() -> void:
	super._ready()
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_match_time = _cfg_match_time if _cfg_match_time > 0.0 else MATCH_TIME
	# 将开局玩家昵称表注入 round_state，供客户端排行榜直接展示
	_broadcast_round_state()


# ── 限时死斗回合驱动逻辑 ──
func _match_round_tick(delta: float) -> void:
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				_broadcast_round_state()
			# 倒计时阶段每 0.5 秒广播一次状态，避免客户端场景切换延迟导致丢包
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = 0.5
				_broadcast_round_state()
		RoundState.PLAYING:
			_match_time = maxf(_match_time - delta, 0.0)
			# 倒地角色进入复活队列，等待复活延迟后执行重生
			for role in players:
				var p: Node2D = players[role]
				if p.is_downed() and not _respawn_pending.has(role):
					_respawn_pending[role] = RESPAWN_DELAY
			_handle_respawns(delta)
			# 角色倒地时触发击杀结算与掉落判定
			for role in players:
				var p: Node2D = players[role]
				if not p.is_downed() or _down_counted.get(role, false):
					continue
				_down_counted[role] = true
				# 角色倒地时掉落除随机一把武器外的全部随身武器
				_drop_all_but_one(p, int(role))
				var killer := _attributed_killer(p)
				# 记录倒地事件；仅在有明确攻击者归因时计入击杀
				_record_down(int(role), killer)
				if killer != 0:
					_scores[killer] = int(_scores.get(killer, 0)) + 1
					_broadcast_kill(killer, role)
				_broadcast_round_state()
			# 定期广播对局状态快照（同步倒计时与比分）
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = HUD_SYNC_INTERVAL
				_broadcast_round_state()
			if _match_time <= 0.0:
				_finish_match()
		RoundState.MATCH_OVER:
			pass   # 结算展示阶段，等待玩家主动离开或返回大厅


# 击杀归因：检查受害者元数据中的攻击者节点并映射为角色编号
# 伤害超出判定时间窗口则判定为无归因死亡（例如坠落或环境伤害）
func _attributed_killer(victim: Node2D) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		var age := Time.get_ticks_msec() - int(victim.get_meta("last_damager_time"))
		if age > ATTRIB_WINDOW:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("RoyaleHost: 对局结束,胜者 role %d" % _match_winner())


# 判定胜者角色编号：分数最高者获胜；榜首并列时判定为平局（返回 0）
# 计分候选集包含仍在场角色、计分记录角色以及已离开角色，确保断线离开玩家的历史得分正常参与终局判定
func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	var tie := false
	var candidates := {}
	for role in players:
		candidates[int(role)] = true
	for role in _scores:
		candidates[int(role)] = true
	for role in _left:
		candidates[int(role)] = true
	for role in candidates:
		var n: int = int(_scores.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
			tie = false
		elif n == best_n:
			tie = true
	return 0 if tie else best_role


# 构造并广播 round_state 回合状态载荷
func _broadcast_round_state() -> void:
	var names := {}
	var alive := {}
	# 收集真人、已离开玩家及 AI 补位角色的展示昵称
	for role in peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in players:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in _left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	# 角色存活状态：未倒地即为存活
	for role in players:
		var p: Node2D = players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
	# 从逐人统计表中提取各角色阵亡次数
	var deaths := {}
	for role in _roster():
		var s: Dictionary = _stats.get(int(role), {})
		deaths[int(role)] = int(s.get("deaths", 0))
	var data := {
		"state": _round_state,
		"round": 1,
		"scores": _scores,
		"deaths": deaths,
		"rounds_won": {},          # 大乱斗模式无局胜统计，占位兼容客户端界面
		"timer": ceilf(_match_time) if _round_state == RoundState.PLAYING else _round_timer,
		"names": names,
		"alive": alive,
		"left": _left.keys(),
	}
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	_send_round_state(data)


# 房间玩家昵称表，供排行榜展示
var _display_names: Dictionary = {}

func set_display_names(names: Dictionary) -> void:
	_display_names = names
	_broadcast_round_state()


# 玩家中途掉线处理：释放角色节点并在排行榜中标记为离开；若有效角色少于 2 人则提前结束对局
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true
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
	_broadcast_round_state()
	# 场上剩余有效角色（真人或 AI 补位）少于 2 人时提前结束对局
	if players.size() < 2 and _round_state != RoundState.MATCH_OVER:
		_finish_match()


# 子弹命中受害者时记录射手元数据，供后续倒地击杀归因
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


# 角色复活时清除击杀归因元数据，防止复活后发生环境伤害时误归因给历史攻击者
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")

# 玩家主动自杀脱困请求处理：清除归因并强制倒地，计入自身阵亡但不计入他人击杀
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
