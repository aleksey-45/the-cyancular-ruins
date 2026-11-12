class_name MatchRules
extends RefCounted

# 对局规则持有阶段与比分，按开局阵容规划出生和复活。
const RoundState = NetEvent.RoundState
const RESPAWN_TICKS := 120
const SPAWN_RECT := Rect2(-45.0, -50.0, 80.0, 107.0)   # 站立角色相对格中心的碰撞包围盒
const SPAWN_CENTER := 32.0
const SPAWN_SUPPORT_ROWS := 2

var mode := PvpSession.MODE_PVP
var teams: Dictionary = {}
var team_counts: Dictionary = {}
var spawns: Dictionary = {}
var swapped: Dictionary = {}
var floor_cells: Array[Vector2i]
var phase := RoundState.WAITING
var round_number := 1
var round_timer := 0.0
var match_time := 300.0
var scores: Dictionary = {}
var rounds_won: Dictionary = {}
var round_winner := 0
var winner := 0
var _roster: Array
var _respawns: Dictionary
var _size: Vector2i
var _respawn_pools: Array[Array]

func setup(p_mode: String, roster: Array, p_teams: Dictionary, map: Dictionary, options: Dictionary) -> String:
	mode = p_mode
	_roster = roster
	teams = p_teams
	match_time = float(options.get("match_time", 300.0))
	_size = map["size"]
	var grid: Array[Array] = map["grid"]
	var map_spawns: Dictionary = map["spawns"]
	floor_cells = SpawnPicker.floor_cells(grid, _size)
	if mode == PvpSession.MODE_TEAM:
		# 开局后固定阵容，掉线不重算补偿。
		team_counts = TeamRules.team_counts(teams)
		assert(not team_counts.is_empty())
		_respawns = map_spawns["respawn"]
		spawns = _plan_team_spawns(false)
		swapped = _plan_team_spawns(true)
	elif mode == PvpSession.MODE_ROYALE:
		_respawn_pools = SpawnPicker.respawn_pools(grid, floor_cells, _size)
		var points := GridPathfinder.spread_cells(_respawn_pools[0], roster.size(), 15, _size.x, _size.y)
		if points.size() < roster.size():
			return "地图出生点不足，无法开始对局"
		for i in roster.size():
			spawns[roster[i]] = points[i]
	else:
		var a: Vector2i = map_spawns["player"]
		var b: Vector2i = map_spawns["player2"] if map_spawns.has("player2") \
				else SpawnPicker.far_spawn_from(a, floor_cells, _size)
		if b == SpawnPicker.NO_CELL or b == a:
			return "地图缺少第二个可用出生点"
		spawns = {1: a, 2: b}
		swapped = {1: b, 2: a}
	_reset_scores()
	return ""

func same_team(a: int, b: int) -> bool:
	return teams.has(a) and teams[a] == teams.get(b, 0)

## 单局初始比分：团队双方按人数差补贴，其他模式保持清空。
func _reset_scores() -> void:
	scores.clear()
	if team_counts.is_empty():
		return
	for team: int in [1, 2]:
		var bonus := TeamRules.score_bonus(team, team_counts)
		if bonus > 0:
			scores[team] = bonus

func spawn_for(players: Dictionary, role: int, initial: bool = false) -> Vector2i:
	if initial or mode == PvpSession.MODE_PVP:
		return spawns[role]
	if mode == PvpSession.MODE_TEAM:
		return _team_respawn_point(players, role)
	var best := SpawnPicker.NO_CELL
	var best_distance := -1
	for pool in _respawn_pools:
		var cells := pool.duplicate()
		cells.shuffle()
		for cell: Vector2i in cells:
			var distance := 1000000
			for other in players:
				var player: Player = players[other]
				if other == role or same_team(role, other) or player.sim_downed:
					continue
				distance = mini(distance, GridPathfinder.toroidal_dist(cell, Vector2i(player.position / GameParameters.TILE_SIZE), _size.x, _size.y))
			if distance > best_distance:
				best = cell
				best_distance = distance
			if distance >= 8:
				return cell
	return best

## 团队复活只从当前阵营的地图侧选点：回合序号奇数时队伍与地图侧同号，偶数时交换。
## 排除存活角色占用的点，取到所有存活敌人最小环面距离最大的点。
func _team_respawn_point(players: Dictionary, role: int) -> Vector2i:
	var team := int(teams[role])
	var side := team if round_number % 2 == 1 else 3 - team
	var occupied := {}
	var enemies: Array[Vector2i] = []
	for other in players:
		var player: Player = players[other]
		if player.sim_downed:
			continue
		var cell := GridPathfinder.cell_of(player.global_position, GameParameters.TILE_SIZE, _size.x, _size.y)
		occupied[cell] = true
		if other != role and not same_team(role, other):
			enemies.append(cell)
	var best := Vector2i(-1, -1)
	var best_distance := -1
	for cell: Vector2i in _respawns[side]:
		if occupied.has(cell):
			continue
		var distance := 1000000
		for enemy in enemies:
			distance = mini(distance, GridPathfinder.toroidal_dist(cell, enemy, _size.x, _size.y))
		if distance > best_distance:
			best = cell
			best_distance = distance
	# 全部点位被占用时保持倒地，下一 tick 重新选点。
	return best

func start_countdown() -> bool:
	if phase != RoundState.WAITING:
		return false
	phase = RoundState.COUNTDOWN
	round_timer = 3.0
	return true

func score_down(role: int, killer: int) -> int:
	var credited := 3 - role if mode == PvpSession.MODE_PVP else killer
	var scorer := 3 - int(teams[role]) if mode == PvpSession.MODE_TEAM else credited
	if scorer > 0:
		scores[scorer] = int(scores.get(scorer, 0)) + 1
	return credited

func advance(delta: float) -> void:
	match phase:
		RoundState.COUNTDOWN:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer == 0.0:
				phase = RoundState.PLAYING
		RoundState.PLAYING:
			if mode == PvpSession.MODE_ROYALE:
				match_time = maxf(match_time - delta, 0.0)
				if match_time == 0.0:
					_finish(_royale_winner())
				return
			var limit := TeamRules.kills_to_win(teams.size()) if mode == PvpSession.MODE_TEAM else 5
			for scorer: int in scores:
				if scores[scorer] >= limit:
					round_winner = scorer
					rounds_won[scorer] = int(rounds_won.get(scorer, 0)) + 1
					phase = RoundState.ROUND_OVER
					round_timer = 4.0
					return
		RoundState.ROUND_OVER:
			round_timer = maxf(round_timer - delta, 0.0)
			if round_timer > 0.0:
				return
			if rounds_won[round_winner] >= 2:
				_finish(round_winner)
				return
			var previous := spawns
			spawns = swapped
			swapped = previous
			round_number += 1
			_reset_scores()
			phase = RoundState.WAITING

func role_left(remaining_roles: Array) -> bool:
	if phase == RoundState.MATCH_OVER:
		return false
	var contenders := remaining_roles
	if mode == PvpSession.MODE_TEAM:
		var remaining_teams := {}
		for role in remaining_roles:
			remaining_teams[teams[role]] = true
		contenders = remaining_teams.keys()
	if contenders.size() >= 2:
		return false
	var remaining_winner := 0 if contenders.is_empty() else int(contenders[0])
	_finish(_royale_winner() if mode == PvpSession.MODE_ROYALE else remaining_winner)
	return true

func _finish(winning_id: int) -> void:
	winner = winning_id
	phase = RoundState.MATCH_OVER
	round_timer = 0.0

func _royale_winner() -> int:
	var leader := 0
	var best := -1
	for role: int in _roster:
		var score := int(scores.get(role, 0))
		if score > best:
			leader = role
			best = score
		elif score == best:
			leader = 0
	return leader

## 按角色编号升序把每队角色分配到所属地图侧的前 N 个出生点。
func _plan_team_spawns(swapped_sides: bool) -> Dictionary:
	var result := {}
	for team: int in [1, 2]:
		var map_side := 3 - team if swapped_sides else team
		var roles := teams.keys().filter(func(role: int) -> bool: return int(teams[role]) == team)
		roles.sort()
		for i in roles.size():
			result[roles[i]] = _respawns[map_side][i]
	return result

## START 前的团队地图校验：返回空字符串表示通过，否则返回地图路径、阵营、坐标与原因。
## 校验内容：respawn 元数据格式、每队全部配置点、坐标范围、角色净空、脚下支撑、点不重合与静态空域连通。
## 静态空域连通是必要但不充分的检查：它只证明 64px 格间无阻挡，不证明跳跃与台阶可达。
static func validate_team_spawns(path: String, info: Dictionary) -> String:
	TileDefs.load_defs()
	var descriptors: PackedInt32Array = info["descriptors"]
	var spawns: Dictionary = info["spawns"]
	var errors: Array = spawns["respawn_errors"]
	if not errors.is_empty():
		return "地图 %s 的 respawn 元数据格式错误：%s" % [path, str(errors[0])]
	var respawn: Dictionary = spawns["respawn"]
	var dims: Vector2i = info["size"]
	var occupied := {}
	var points: Array = []
	for team: int in [1, 2]:
		var pool: Array = respawn[team]
		if pool.size() < TeamRules.MAX_TEAM:
			return "地图 %s 阵营 %d 出生点不足（需要 %d 个，实际 %d 个）" % [
					path, team, TeamRules.MAX_TEAM, pool.size()]
		for cell: Vector2i in pool:
			var problem := spawn_cell_problem(descriptors, dims, cell)
			if problem.is_empty() and occupied.has(cell):
				problem = "与其他出生点重合"
			if not problem.is_empty():
				return "地图 %s 阵营 %d 出生点 (%d, %d) 不合格：%s" % [path, team, cell.x, cell.y, problem]
			occupied[cell] = team
			points.append(cell)
	var reachable := static_clear_region(descriptors, dims, points[0])
	for cell: Vector2i in points:
		if not reachable.has(cell):
			return "地图 %s 阵营 %d 出生点 (%d, %d) 不在同一静态空域" % [
					path, int(occupied[cell]), cell.x, cell.y]
	return ""

## 返回出生点不合格原因；空字符串表示角色净空、脚下支撑与坐标范围全部合法。
static func spawn_cell_problem(descriptors: PackedInt32Array, dims: Vector2i, cell: Vector2i) -> String:
	if cell.x < 0 or cell.y < 0 or cell.x >= dims.x or cell.y >= dims.y:
		return "坐标越界（地图 %dx%d）" % [dims.x, dims.y]
	if descriptors.is_empty():
		return "地图缺少 16px 子格数据"
	var center := Vector2(cell) * float(GameParameters.TILE_SIZE) \
			+ Vector2(SPAWN_CENTER, SPAWN_CENTER)
	var bounds := Rect2(center + SPAWN_RECT.position, SPAWN_RECT.size)
	var sub := int(Terrain.SUB_SIZE)
	var rows := dims.y * Terrain.SUB_PER_CELL
	var columns := dims.x * Terrain.SUB_PER_CELL
	var blocked := _first_blocking_sub(descriptors, rows, columns, cell)
	if not blocked.is_empty():
		return "角色净空被 16px 子格阻挡 (%d, %d)" % [blocked[0], blocked[1]]
	var feet := bounds.end.y
	for extra in SPAWN_SUPPORT_ROWS:
		var row := floori(feet / sub) + extra
		if row * sub < feet - 0.001:
			continue
		var support := 0
		for sx in range(floori(bounds.position.x / sub), floori((bounds.end.x - 0.001) / sub) + 1):
			if cell_blocked(descriptors, rows, columns, sx, row):
				support += 1
		if support >= 3:
			return ""
	return "脚下没有支撑"

static func cell_blocked(descriptors: PackedInt32Array, rows: int, columns: int, sx: int, sy: int) -> bool:
	var texture := MapFormatV4.descriptor_texture(descriptors[posmod(sy, rows) * columns + posmod(sx, columns)])
	return texture != 0 and TileDefs.type_id_of(texture) == TileDefs.TYPE_WALL

## 角色包围盒触碰的第一个 16px 阻挡子格；空数组表示净空。
static func _first_blocking_sub(descriptors: PackedInt32Array, rows: int, columns: int, cell: Vector2i) -> Array:
	var center := Vector2(cell) * float(GameParameters.TILE_SIZE) \
			+ Vector2(SPAWN_CENTER, SPAWN_CENTER)
	var bounds := Rect2(center + SPAWN_RECT.position, SPAWN_RECT.size)
	var sub := int(Terrain.SUB_SIZE)
	for sy in range(floori(bounds.position.y / sub), floori((bounds.end.y - 0.001) / sub) + 1):
		for sx in range(floori(bounds.position.x / sub), floori((bounds.end.x - 0.001) / sub) + 1):
			if cell_blocked(descriptors, rows, columns, sx, sy):
				return [sx, sy]
	return []

## 角色包围盒无阻挡的 64px 格集合；只证明静态空域邻接，不代表跳跃/台阶可达。
static func static_clear_region(descriptors: PackedInt32Array, dims: Vector2i, start: Vector2i) -> Dictionary:
	var visited := {}
	if start.x < 0 or start.y < 0 or start.x >= dims.x or start.y >= dims.y:
		return visited
	var rows := dims.y * Terrain.SUB_PER_CELL
	var columns := dims.x * Terrain.SUB_PER_CELL
	var stack: Array = [start]
	visited[start] = true
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next := Vector2i(posmod(cell.x + offset.x, dims.x), posmod(cell.y + offset.y, dims.y))
			if visited.has(next):
				continue
			if _first_blocking_sub(descriptors, rows, columns, next).is_empty():
				visited[next] = true
				stack.append(next)
	return visited
