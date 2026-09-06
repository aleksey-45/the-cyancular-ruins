class_name RoyaleHost
extends MatchHost

# 大乱斗权威对局(N 人限时死斗,RoyaleServer 分支):
#  - N 个玩家(roles 1..N)散点出生;死亡 2s 复活(复用 MatchHost._handle_respawns),
#    复活点动态选"离所有存活敌人 ≥ 若干格"的地板格,出生分散。
#  - 限时 MATCH_TIME:倒计时归零 → MATCH_OVER,击杀最多者胜(平局=0)。
#  - 击杀归因:子弹/爆炸命中时把射手记到受害者 meta("last_damager"),
#    倒地边沿读 meta 计分;无源死亡(溺水/环境)不计分。
#  - 排行榜数据经 round_state 载荷下发:{scores(总击杀), names, timer(剩余秒), match_winner}。
#  - 中途掉线 = 移出对局(节点释放,排行榜标"离开"),剩余 <2 人时终局。

const MATCH_TIME := 300.0        # 一局时长(秒)
const HUD_SYNC_INTERVAL := 1.0   # 倒计时/比分周期广播
const RESPAWN_CLEARANCE := 8     # 复活点与存活敌人的最小环面距离(格)
const SPAWN_CLEARANCE := 15      # 开局散点两两最小距离(格)

var _match_time := MATCH_TIME
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}    # role -> Vector2i(开局散点,_init 摆位用)
var _spawned_once: Dictionary = {}    # role -> true(首次摆位走散点,之后动态选复活点)
var _left: Dictionary = {}            # role -> true(中途掉线,已移出对局)

static var _floor_cell_cache: Array = []   # 本局地板格(懒采集;砖被拆不刷新,够用)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = []) -> void:
	# 散点必须在 super._init() 之前就绪:父类 _init 摆位会虚调 _spawn_cell(role),
	# 若 _round_spawns 尚为空,首次摆位拿到 (-1,-1) 且被 _spawned_once 闩锁,
	# 全体玩家挤到地图回卷角落、散点/复活设计失效(自检 S1 严重 bug)。
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_round_spawns = plan_spawns(role_peers.keys() + ai_roles)
	super._init(map_path, role_peers, options, ai_roles)


# ── 开局(在 worker 进程调用):算散点出生 → 逐角色 match_start → 建 RoyaleHost ──
# ai_roles = AI 补位 role 列表(这些 role 由服务端 AI 驱动,不发 match_start)
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# plan_spawns 依赖 current_grid:先预载网格(MatchHost._init 里再 load_grid 幂等)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_spawns(role_peers.keys() + ai_roles)
	for role in role_peers:
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "大乱斗开始")
	var host := RoyaleHost.new(map_path, role_peers, options, ai_roles)
	host._round_spawns = spawns
	return host


# 采集地板格(EMPTY + 正下方 SOLID + 头上留空;同 MatchHost._is_floor_cell 判据,静态版)
static func _grid_dims() -> Vector2i:
	var grid := MazeGenerator.current_grid
	return Vector2i((grid[0] as Array).size(), grid.size())   # (cols, rows)

# 环面格距(current_grid 尺寸版,MazeGenerator.toroidal_dist 的便捷封装)
static func _tdist(a: Vector2i, b: Vector2i) -> int:
	var d := _grid_dims()
	return MazeGenerator.toroidal_dist(a, b, d.x, d.y)

static func _floor_cells() -> Array:
	if not _floor_cell_cache.is_empty():
		return _floor_cell_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return []
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	for y in range(rows):
		for x in range(cols):
			var c := Vector2i(x, y)
			if grid[c.y][c.x] != MazeGenerator.EMPTY:
				continue
			if not TileDefs.is_blocked(grid[posmod(c.y + 1, rows)][c.x]):
				continue
			if grid[posmod(c.y - 1, rows)][c.x] != MazeGenerator.EMPTY:
				continue
			_floor_cell_cache.append(c)
	return _floor_cell_cache


# 开局散点:洗牌后贪心取两两环面距离 ≥ SPAWN_CLEARANCE 的 N 个格;不够就放宽(全量补齐)。
# roles = 实际参战 role 列表:缺员降级开局时 role 不连续(如剩 {1,3}),
# 必须按实际键返回,否则 spawns[role] 缺键抛错、对局卡死(自检 S2 严重 bug)。
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var cells: Array = _floor_cells().duplicate()
	cells.shuffle()
	var picked: Array = []
	var clearance := SPAWN_CLEARANCE
	while picked.size() < n and clearance >= 0:
		for c in cells:
			if picked.size() >= n:
				break
			var ok := true
			for p in picked:
				if _tdist(p, c) < clearance:
					ok = false
					break
			if ok and not picked.has(c):
				picked.append(c)
		clearance -= 5   # 地板格不足时放宽间距重收
	var out := {}
	for i in range(n):
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 出生点:首次 = 开局散点;复活 = 离所有存活敌人 ≥ RESPAWN_CLEARANCE 的随机地板格(退而求其次任取)
func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(role, Vector2i(-1, -1))
	var cells: Array = _floor_cells()
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
	return cells[0] if not cells.is_empty() else Vector2i(-1, -1)


func _ready() -> void:
	super._ready()
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_match_time = MATCH_TIME
	# 本局开局昵称表进 round_state(排行榜直接展示,客户端不必另配 peer_info)
	_broadcast_round_state()


# ── 限时死斗回合逻辑(完全替代父类三局两胜制)──
func _match_round_tick(delta: float) -> void:
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				_broadcast_round_state()
			# 倒计时每 0.5s 重播:客户端切场景/建 HUD 有延迟,_ready 只广播一次会漏收
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = 0.5
				_broadcast_round_state()
		RoundState.PLAYING:
			_match_time = maxf(_match_time - delta, 0.0)
			# 复活调度(同父类:PLAYING 内倒地即安排 2s 复活)+ 复活执行
			for role in players:
				var p: Node2D = players[role]
				if p.is_downed() and not _respawn_pending.has(role):
					_respawn_pending[role] = RESPAWN_DELAY
			_handle_respawns(delta)
			# 击杀计分:倒地边沿 + 射手归因(meta)
			for role in players:
				var p: Node2D = players[role]
				if not p.is_downed() or _down_counted.get(role, false):
					continue
				_down_counted[role] = true
				var killer := _attributed_killer(p)
				if killer != 0:
					_scores[killer] = int(_scores.get(killer, 0)) + 1
					_broadcast_kill(killer, role)
				_broadcast_round_state()
			# 周期广播(倒计时/比分同步)
			_hud_sync -= delta
			if _hud_sync <= 0.0:
				_hud_sync = HUD_SYNC_INTERVAL
				_broadcast_round_state()
			if _match_time <= 0.0:
				_finish_match()
		RoundState.MATCH_OVER:
			pass   # 结果展示阶段:客户端 6s 后自行回菜单


# 击杀归因:读受害者 meta 里的射手节点(子弹直击/爆炸在命中时写入),映射回 role。
# 带时效:伤害超过 ATTRIB_WINDOW 秒前的射手不再归因(防止"被打一枪后溺水"误计)。
const ATTRIB_WINDOW := 10000   # ms

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


# 平局(榜首并列)返回 0;其余返回最高击杀的 role
func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	var tie := false
	for role in players:
		var n: int = int(_scores.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
			tie = false
		elif n == best_n:
			tie = true
	return 0 if tie else best_role


# round_state 载荷(大乱斗版):scores=总击杀,timer=剩余秒,names=昵称表,alive/离开标记
func _broadcast_round_state() -> void:
	var names := {}
	var alive := {}
	# 在房玩家 + 已离开者都保留昵称行(离开玩家在排行榜标「离开」,原 M4:整行消失)
	for role in peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in _left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	# alive=未倒地(倒地者 HUD 显示「复活中」,原 M4:恒 true 不可达)
	for role in players:
		var p: Node2D = players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
	var data := {
		"state": _round_state,
		"round": 1,
		"scores": _scores,
		"rounds_won": {},          # 大乱斗无局胜,占位空(客户端 HUD 兼容读取)
		"timer": ceilf(_match_time) if _round_state == RoundState.PLAYING else _round_timer,
		"names": names,
		"alive": alive,
		"left": _left.keys(),
		"match_time": int(MATCH_TIME),
	}
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	var live_peers := multiplayer.get_peers()
	for role in peer_by_role:
		if live_peers.has(peer_by_role[role]):
			NetBus.rpc_id(peer_by_role[role], "round_state", data)


# 房主昵称表(worker 开局后由 server_main 注入;排行榜展示用)
var _display_names: Dictionary = {}

func set_display_names(names: Dictionary) -> void:
	_display_names = names
	_broadcast_round_state()


# 中途掉线 = 移出对局:节点释放(快照/裁决不再含它),排行榜标"离开"
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
	# 剩余人头 <2 → 直接终局(独行者判胜)
	var online := 0
	for r in peer_by_role:
		online += 1
	if online < 2 and _round_state != RoundState.MATCH_OVER:
		_finish_match()


# 子弹直击归因:命中瞬间把射手记到受害者 meta(倒地边沿时读)
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	if bullet.shooter != null and is_instance_valid(bullet.shooter) and bullet.shooter != victim:
		victim.set_meta("last_damager", bullet.shooter)
		victim.set_meta("last_damager_time", Time.get_ticks_msec())
	super._on_bullet_hit(bullet, victim, victim_role)


# 复活时清空归因 meta:复活后的环境死亡(溺水等)不再记到复活前最后射手头上(自检 M5)
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")
