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
const OPEN_AREA_MIN: int = 20    # 出生可走连通区最小规模(格);密封死角小间远小于此
const PREFER_MIN: int = 8        # 优选格不足此数才回退下一级宽松判据

var _match_time := MATCH_TIME
var _cfg_match_time := 0.0             # 房主自定义时长(秒;0=默认 MATCH_TIME)
var _hud_sync := 0.0
var _round_spawns: Dictionary = {}    # role -> Vector2i(开局散点,_init 摆位用)
var _spawned_once: Dictionary = {}    # role -> true(首次摆位走散点,之后动态选复活点)
var _deaths: Dictionary = {}          # role -> 阵亡数(排行榜展示)
var _left: Dictionary = {}            # role -> true(中途掉线,已移出对局)

static var _floor_cell_cache: Array = []   # 本局地板格(懒采集;砖被拆不刷新,够用)
static var _prefer_cache: Array = []       # 出生优选格缓存(开阔可走区;见 _spawn_candidates)
static var _region_cache: Dictionary = {}  # 地板格 Vector2i -> 同层连通区规模


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = []) -> void:
	# 散点必须在 super._init() 之前就绪:父类 _init 摆位会虚调 _spawn_cell(role),
	# 若 _round_spawns 尚为空,首次摆位拿到 (-1,-1) 且被 _spawned_once 闩锁,
	# 全体玩家挤到地图回卷角落、散点/复活设计失效(自检 S1 严重 bug)。
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_round_spawns = plan_spawns(role_peers.keys() + ai_roles)
	_cfg_match_time = float(options.get("match_time", 0.0))
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


# ── 出生/复活点优选(防"出生在走不出去的小房间")──
# 玩家实测:旧判据只要求"脚下有地",密封死角/1 格高夹层的地板格也会入选 →
# 出生在四面墙的小房间出不去。优选格需同时满足:
#   (1) 头顶 ≥2 格净空(站得直、跳得出去);
#   (2) 左右邻格空(出生处 ≥3 格宽,不被墙夹);
#   (3) 所在同层可走连通区规模 ≥ OPEN_AREA_MIN(密封 1~2 格死角自动淘汰)。
# 地板格不足时逐级回退:连通区大但不要求三宽 → 任意地板格(极小图兜底)。
static func _region_sizes() -> Dictionary:
	if not _region_cache.is_empty():
		return _region_cache
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return {}
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	var seen := {}
	for y in range(rows):
		for x in range(cols):
			var start := Vector2i(x, y)
			if seen.has(start) or not _floor_cells_has(start):
				continue
			var stack: Array = [start]
			var members: Array = []
			seen[start] = true
			while not stack.is_empty():
				var cur: Vector2i = stack.pop_back()
				members.append(cur)
				for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nb := Vector2i(posmod(cur.x + off.x, cols), posmod(cur.y + off.y, rows))
					if seen.has(nb) or not _floor_cells_has(nb):
						continue
					seen[nb] = true
					stack.append(nb)
			var sz := members.size()
			for m in members:
				_region_cache[m] = sz
	return _region_cache


# 某格是否地板格(与 _floor_cells 同判据的 O(1) 版本:自身空 + 下方实心 + 上方留空)
static func _floor_cells_has(c: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	if grid[c.y][c.x] != MazeGenerator.EMPTY:
		return false
	if not TileDefs.is_blocked(grid[posmod(c.y + 1, rows)][c.x]):
		return false
	if grid[posmod(c.y - 1, rows)][c.x] != MazeGenerator.EMPTY:
		return false
	return true


static func _roomy_floor(c: Vector2i) -> bool:
	if not _floor_cells_has(c):
		return false
	var grid := MazeGenerator.current_grid
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	# 头顶两格净空
	if grid[posmod(c.y - 1, rows)][c.x] != MazeGenerator.EMPTY \
			or grid[posmod(c.y - 2, rows)][c.x] != MazeGenerator.EMPTY:
		return false
	# 左右邻格空:出生处 ≥3 格宽
	if grid[c.y][posmod(c.x - 1, cols)] != MazeGenerator.EMPTY \
			or grid[c.y][posmod(c.x + 1, cols)] != MazeGenerator.EMPTY:
		return false
	return true


# 出生候选池(缓存):开阔可走地板格;不足则回退连通区大的地板格;再不足回退任意地板格。
static func _spawn_candidates() -> Array:
	if not _prefer_cache.is_empty():
		return _prefer_cache
	var floor: Array = _floor_cells()
	var sizes := _region_sizes()
	var big: Array = []
	var roomy: Array = []
	for c in floor:
		if int(sizes.get(c, 0)) >= OPEN_AREA_MIN:
			big.append(c)
			if _roomy_floor(c):
				roomy.append(c)
	if roomy.size() >= PREFER_MIN:
		_prefer_cache = roomy
	elif big.size() >= PREFER_MIN:
		_prefer_cache = big
	else:
		_prefer_cache = floor
	return _prefer_cache


# 开局散点:洗牌后贪心取两两环面距离 ≥ SPAWN_CLEARANCE 的 N 个格;不够就放宽(全量补齐)。
# roles = 实际参战 role 列表:缺员降级开局时 role 不连续(如剩 {1,3}),
# 必须按实际键返回,否则 spawns[role] 缺键抛错、对局卡死(自检 S2 严重 bug)。
static func plan_spawns(roles: Array) -> Dictionary:
	var n := roles.size()
	var picked: Array = []
	var cells: Array = _spawn_candidates().duplicate()
	cells.shuffle()
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
	# 候选不够散点(极小图):回退任意地板格补足,避免塞 (-1,-1) 出生到墙角
	if picked.size() < n:
		var rest: Array = _floor_cells().duplicate()
		rest.shuffle()
		for c in rest:
			if picked.size() >= n:
				break
			if not picked.has(c):
				picked.append(c)
	var out := {}
	for i in range(n):
		out[int(roles[i])] = picked[i] if i < picked.size() else Vector2i(-1, -1)
	return out


# 出生点:首次 = 开局散点;复活 = 优选开阔格中离所有存活敌人 ≥ RESPAWN_CLEARANCE 的随机格
# (优选池不够 → 回退任意地板格,同样先保证离敌人远)。
func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(role, Vector2i(-1, -1))
	for pool: Array in [_spawn_candidates(), _floor_cells()]:
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
				_deaths[int(role)] = int(_deaths.get(int(role), 0)) + 1   # 阵亡计数
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
# 带时效:伤害超过 ATTRIB_WINDOW 毫秒前的射手不再归因(防止"被打一枪后溺水"误计)。
# 击杀归因时效窗口(ms)。★ 有意与 main 的单一来源对齐(用户 2026-09-11 裁定):
# 原 KH 值 10000ms 已弃用 —— 现读 CombatFeedback.ATTRIB_WINDOW_MS(3000ms)。
# 背景:两处读的是同一个 last_damager_time meta,但读端对象不重叠 ——
#   CombatFeedback 读「敌人」(决定播不播「击杀 XXX」),本文件读「玩家」(决定谁算击杀)。
# 所以这不是"两套 bug",只是口径选择;选 3s 的理由是与单机播报口径一致。
# 行为变更(有意):打一枪后 4~10s 内的溺水/坠落死亡,现在不再算作你的击杀。
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS

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
	# 昵称行覆盖:真人(peer_by_role)+ 已离开者 + **AI 补位(players 里无 peer 的 role)**
	# AI 此前没进排行榜,因为 names 只遍历 peer_by_role(真人)
	for role in peer_by_role:
		names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in players:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	for role in _left:
		if not names.has(int(role)):
			names[int(role)] = _display_names.get(int(role), "玩家%d" % int(role))
	# alive=未倒地(倒地者 HUD 显示「复活中」,原 M4:恒 true 不可达);AI 同样参与
	for role in players:
		var p: Node2D = players[role]
		alive[int(role)] = is_instance_valid(p) and not p.is_downed()
	var data := {
		"state": _round_state,
		"round": 1,
		"scores": _scores,
		"deaths": _deaths,
		"rounds_won": {},          # 大乱斗无局胜,占位空(客户端 HUD 兼容读取)
		"timer": ceilf(_match_time) if _round_state == RoundState.PLAYING else _round_timer,
		"names": names,
		"alive": alive,
		"left": _left.keys(),
		"match_time": int(_match_time),
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
	# 归因写入统一走 main 的单一入口(它同时写 last_damager + last_damager_time)。
	# 本覆写不可省:服务器子弹撞玩家时掩码不含玩家层,只经 _adjudicate_bullets 到这里,
	# bullet_base._register_player_hit 不会跑 → 必须由本处写 meta,否则击杀归因丢失。
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


# 复活时清空归因 meta:复活后的环境死亡(溺水等)不再记到复活前最后射手头上(自检 M5)
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")

# ── 自杀脱困(K 键:royale_game 客户端 → NetBusExt.suicide_request → server_main 转发)──
# 异常卡死(嵌墙/夹缝)时主动放弃生命:走正常倒地边沿 → 2s 复活;先清 last_damager 归因,
# 自杀不计入任何人击杀(哪怕刚被人打过),只累积自己的阵亡数。
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
