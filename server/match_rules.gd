class_name MatchRules
extends RefCounted

# 单局规则：出生点规划、回合推进与团队模式的固定阵容补偿。

const SPAWN_RECT := Rect2(-45.0, -50.0, 80.0, 107.0)   # 站立角色相对格中心的碰撞包围盒
const SPAWN_CENTER := 32.0
const SPAWN_SUPPORT_ROWS := 2

var mode := PvpSession.MODE_PVP
var teams: Dictionary = {}
var team_counts: Dictionary = {}
var spawns: Dictionary = {}
var swapped: Dictionary = {}
var match_time := 300.0
var hud_time := 0.0
var winner := 0

func setup(p_mode: String, roster: Array, p_teams: Dictionary, options: Dictionary) -> void:
	mode = p_mode
	teams = p_teams
	match_time = float(options.get("match_time", 300.0))
	if mode == PvpSession.MODE_TEAM:
		# 开局后固定阵容；中途掉线不重算补偿。
		team_counts = TeamRules.team_counts(teams)
		if team_counts.is_empty():
			push_error("MatchRules: 团队阵容非法，无法规划出生点")
			return
		spawns = plan_team_spawns(teams, false)
		swapped = plan_team_spawns(teams, true)
		if spawns.is_empty() or swapped.is_empty():
			push_error("MatchRules: 团队出生点规划失败")
	elif mode == PvpSession.MODE_ROYALE:
		var dims := SpawnPicker.grid_dims()
		var points := GridPathfinder.spread_cells(SpawnPicker.spawn_candidates(), roster.size(), 15, dims.x, dims.y)
		for i in roster.size():
			spawns[roster[i]] = points[i]
	else:
		var points := MazeGenerator.current_spawns
		var a: Vector2i = points["player"]
		var b: Vector2i = points.get("player2", Vector2i(-1, -1))
		if b.x < 0:
			b = SpawnPicker.far_spawn_from(a, TileDefs.terrain.get_grid_snapshot())
		spawns = {1: a, 2: b}
		swapped = {1: b, 2: a}

func same_team(a: int, b: int) -> bool:
	return teams.has(a) and teams[a] == teams.get(b, 0)

## 单局初始比分：团队双方按人数差补贴，其他模式保持清空。
func apply_initial_scores(world: Node) -> void:
	world._scores = {}
	if team_counts.is_empty():
		return
	for team: int in [1, 2]:
		var bonus := TeamRules.score_bonus(team, team_counts)
		if bonus > 0:
			world._scores[team] = bonus

func spawn_for(world: Node, role: int, initial: bool = false) -> Vector2i:
	if initial or mode == PvpSession.MODE_PVP:
		return spawns.get(role, Vector2i(-1, -1))
	if mode == PvpSession.MODE_TEAM:
		return team_respawn_point(world, role)
	var dims := SpawnPicker.grid_dims()
	var best := spawns[role] as Vector2i
	var best_distance := -1
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for cell: Vector2i in cells:
			var distance := 1000000
			for other in world.players:
				var player: Node2D = world.players[other]
				if other == role or same_team(role, other) or player.is_downed():
					continue
				distance = mini(distance, GridPathfinder.toroidal_dist(cell, Vector2i(player.position / GameParameters.TILE_SIZE), dims.x, dims.y))
			if distance > best_distance:
				best = cell
				best_distance = distance
			if distance >= 8:
				return cell
	return best

## 团队复活只从当前阵营的地图侧选点：回合序号奇数时队伍与地图侧同号，偶数时交换。
## 排除存活角色占用的点，取到所有存活敌人最小环面距离最大的点。
func team_respawn_point(world: Node, role: int) -> Vector2i:
	assert(teams.has(role), "MatchRules: 角色 %d 不属于团队阵容" % role)
	var team := int(teams[role])
	assert(team == 1 or team == 2, "MatchRules: 角色 %d 的队伍 %d 非法" % [role, team])
	var side: int = team if int(world._round_num) % 2 == 1 else 3 - team
	var respawn: Dictionary = MazeGenerator.current_spawns.get("respawn", {})
	assert(respawn.has(side), "MatchRules: 地图缺少阵营 %d 的出生点数据" % side)
	var pool: Array = respawn[side]
	assert(pool.size() >= TeamRules.MAX_TEAM, "MatchRules: 阵营 %d 的出生点少于 %d 个" % [side, TeamRules.MAX_TEAM])
	var dims := SpawnPicker.grid_dims()
	var occupied := {}
	for other in world.players:
		var player: Node2D = world.players[other]
		if player.is_downed():
			continue
		occupied[_cell_of(player.global_position, dims)] = true
	var enemies: Array = []
	for other in world.players:
		var player: Node2D = world.players[other]
		if other == role or same_team(role, other) or player.is_downed():
			continue
		enemies.append(_cell_of(player.global_position, dims))
	var best := Vector2i(-1, -1)
	var best_distance := -1
	for cell: Vector2i in pool:
		if occupied.has(cell):
			continue
		var distance := 1000000
		for enemy: Vector2i in enemies:
			distance = mini(distance, GridPathfinder.toroidal_dist(cell, enemy, dims.x, dims.y))
		if distance > best_distance:
			best = cell
			best_distance = distance
	# 全部被其他存活角色占用是正常业务状态：保持倒地，由 MatchRules.tick 在占用解除后的下一 tick 重试。
	return best

static func _cell_of(position: Vector2, dims: Vector2i) -> Vector2i:
	return GridPathfinder.cell_of(position, GameParameters.TILE_SIZE, dims.x, dims.y)

func tick(world: Node, delta: float) -> void:
	if world._round_state == NetEvent.RoundState.MATCH_OVER:
		return
	for role in world.players:
		var player: Node2D = world.players[role]
		if not player.is_downed() or world._round_state != NetEvent.RoundState.PLAYING:
			continue
		if player.respawn_tick > 0:
			continue
		player.respawn_tick = world._snap_tick + 120
		world._drop_all_but_one(player, role)
		var killer: int = world.killer_for(player)
		var scorer := killer
		if mode == PvpSession.MODE_PVP:
			killer = 3 - int(role)
			scorer = killer
		elif mode == PvpSession.MODE_TEAM:
			scorer = 3 - int(teams[role])
		world._record_down(role, killer)
		if scorer > 0:
			world._scores[scorer] = int(world._scores.get(scorer, 0)) + 1
		world.broadcast(NetEvent.Kind.KILL, [killer, role])
		if mode == PvpSession.MODE_PVP and not world.players[killer].is_downed():
			world.respawn(killer, false)
		world.broadcast_round()
	match world._round_state:
		NetEvent.RoundState.WAITING:
			# 等待所有席位 READY；回合计时不推进，也不增加强制开局超时。
			return
		NetEvent.RoundState.COUNTDOWN:
			world._round_timer -= delta
			if world._round_timer <= 0.0:
				world._round_state = NetEvent.RoundState.PLAYING
				if world._options.get("round_full_heal", false):
					for role in world.players:
						var player: Node2D = world.players[role]
						player.apply_authoritative_state(player.max_hp, player.max_waterproof, false)
				world.broadcast_round()
		NetEvent.RoundState.PLAYING:
			for role in world.players:
				var player: Node2D = world.players[role]
				if player.respawn_tick > 0 and world._snap_tick >= player.respawn_tick:
					# 失败只表示所有本方出生点暂时被其他存活角色占用；保持原到期 tick，
					# 占用解除后的下一 tick 立即重试，不做固定 60 tick 的延迟。
					world.respawn(role)
			if mode == PvpSession.MODE_ROYALE:
				match_time -= delta
				hud_time -= delta
				if hud_time <= 0.0:
					hud_time = 1.0
					world.broadcast_round()
				if match_time <= 0.0:
					finish(world)
			else:
				var limit := TeamRules.kills_to_win(teams.size()) if mode == PvpSession.MODE_TEAM else 5
				for scorer in world._scores:
					if world._scores[scorer] >= limit:
						world._last_round_winner = scorer
						world._rounds_won[scorer] = int(world._rounds_won.get(scorer, 0)) + 1
						world._round_state = NetEvent.RoundState.ROUND_OVER
						world._round_timer = 4.0
						world.broadcast_round()
						break
		NetEvent.RoundState.ROUND_OVER:
			world._round_timer -= delta
			if world._round_timer <= 0.0:
				for scorer in world._rounds_won:
					if world._rounds_won[scorer] >= 2:
						winner = scorer
						finish(world)
						return
				var previous := spawns
				spawns = swapped
				swapped = previous
				world.start_round()

func finish(world: Node) -> void:
	if mode == PvpSession.MODE_ROYALE:
		var best := -1
		for role in world._stats:
			var score := int(world._scores.get(role, 0))
			if score > best:
				winner = role
				best = score
			elif score == best:
				winner = 0
	world._round_state = NetEvent.RoundState.MATCH_OVER
	world.clear_pending_blasts()
	world.broadcast_round()

func left(world: Node, _role: int) -> void:
	if world._round_state == NetEvent.RoundState.MATCH_OVER:
		return
	if mode == PvpSession.MODE_TEAM:
		var remaining := {}
		for role in world.players:
			remaining[teams[role]] = true
		if remaining.size() < 2:
			winner = int(remaining.keys()[0]) if remaining.size() == 1 else 0
			finish(world)
	elif world.players.size() < 2:
		winner = int(world.players.keys()[0]) if world.players.size() == 1 else 0
		finish(world)

## 按角色编号升序把每队角色分配到所属地图侧的前 N 个出生点。
## 地图几何合法性已由 validate_team_spawns() 在 START 前完整检查，这里只分配与断言覆盖。
static func plan_team_spawns(p_teams: Dictionary, swapped_sides: bool = false) -> Dictionary:
	var respawn: Dictionary = MazeGenerator.current_spawns.get("respawn", {})
	var result := {}
	var used := {}
	for team: int in [1, 2]:
		var map_side: int = 3 - team if swapped_sides else team
		var roles := p_teams.keys().filter(func(role: int) -> bool: return int(p_teams[role]) == team)
		roles.sort()
		var pool: Array = respawn.get(map_side, [])
		assert(pool.size() >= roles.size(), "MatchRules: 队伍 %d 需要 %d 个出生点，地图侧 %d 只有 %d 个"
				% [team, roles.size(), map_side, pool.size()])
		if pool.size() < roles.size():
			return {}
		for i in roles.size():
			var cell: Vector2i = pool[i]
			assert(not used.has(cell), "MatchRules: 出生点 (%d, %d) 被重复分配" % [cell.x, cell.y])
			if used.has(cell):
				return {}
			used[cell] = true
			result[roles[i]] = cell
	for role in p_teams:
		assert(result.has(role), "MatchRules: 角色 %d 没有分配出生点" % int(role))
		if not result.has(role):
			return {}
	return result

## START 前的团队地图校验：返回空字符串表示通过，否则返回地图路径、阵营、坐标与原因。
## 校验内容：respawn 元数据格式、每队全部配置点、坐标范围、角色净空、脚下支撑、点不重合与静态空域连通。
## 静态空域连通是必要但不充分的检查：它只证明 64px 格间无阻挡，不证明跳跃与台阶可达。
static func validate_team_spawns(path: String, p_teams: Dictionary) -> String:
	TileDefs.load_defs()
	var counts := TeamRules.team_counts(p_teams)
	if counts.is_empty():
		return "团队阵容非法（每队 1~5 人，总计 2~10 人，队伍 ID 只能为 1 或 2）"
	var info := MapFormat.load_map_info(path, true)
	var grid: Array = info.get("grid", [])
	var subgrid: Array = info.get("subgrid", [])
	if grid.is_empty() or subgrid.is_empty():
		return "地图 %s 无法读取地形" % path
	var spawns: Dictionary = info.get("spawns", {})
	var errors: Array = spawns.get("respawn_errors", [])
	if not errors.is_empty():
		return "地图 %s 的 respawn 元数据格式错误：%s" % [path, str(errors[0])]
	var respawn: Dictionary = spawns.get("respawn", {})
	var dims := Vector2i((grid[0] as Array).size(), grid.size())
	var occupied := {}
	var points: Array = []
	for team: int in [1, 2]:
		var pool: Array = respawn.get(team, [])
		if pool.size() < TeamRules.MAX_TEAM:
			return "地图 %s 阵营 %d 出生点不足（需要 %d 个，实际 %d 个）" % [
					path, team, TeamRules.MAX_TEAM, pool.size()]
		for cell: Vector2i in pool:
			var problem := spawn_cell_problem(subgrid, dims, cell)
			if problem.is_empty() and occupied.has(cell):
				problem = "与其他出生点重合"
			if not problem.is_empty():
				return "地图 %s 阵营 %d 出生点 (%d, %d) 不合格：%s" % [path, team, cell.x, cell.y, problem]
			occupied[cell] = team
			points.append(cell)
	var reachable := static_clear_region(subgrid, dims, points[0])
	for cell: Vector2i in points:
		if not reachable.has(cell):
			return "地图 %s 阵营 %d 出生点 (%d, %d) 不在同一静态空域" % [
					path, int(occupied[cell]), cell.x, cell.y]
	return ""

## 返回出生点不合格原因；空字符串表示角色净空、脚下支撑与坐标范围全部合法。
static func spawn_cell_problem(subgrid: Array, dims: Vector2i, cell: Vector2i) -> String:
	if cell.x < 0 or cell.y < 0 or cell.x >= dims.x or cell.y >= dims.y:
		return "坐标越界（地图 %dx%d）" % [dims.x, dims.y]
	if subgrid.is_empty():
		return "地图缺少 16px 子格数据"
	var center := Vector2(cell) * float(GameParameters.TILE_SIZE) \
			+ Vector2(SPAWN_CENTER, SPAWN_CENTER)
	var bounds := Rect2(center + SPAWN_RECT.position, SPAWN_RECT.size)
	var sub := int(Terrain.SUB_SIZE)
	var rows := subgrid.size()
	var columns := (subgrid[0] as Array).size()
	var blocked := _first_blocking_sub(subgrid, rows, columns, cell)
	if not blocked.is_empty():
		return "角色净空被 16px 子格阻挡 (%d, %d)" % [blocked[0], blocked[1]]
	var feet := bounds.end.y
	for extra in SPAWN_SUPPORT_ROWS:
		var row := floori(feet / sub) + extra
		if row * sub < feet - 0.001:
			continue
		var support := 0
		for sx in range(floori(bounds.position.x / sub), floori((bounds.end.x - 0.001) / sub) + 1):
			if cell_blocked(subgrid, rows, columns, sx, row):
				support += 1
		if support >= 3:
			return ""
	return "脚下没有支撑"

static func cell_blocked(subgrid: Array, rows: int, columns: int, sx: int, sy: int) -> bool:
	var texture := int((subgrid[posmod(sy, rows)] as Array)[posmod(sx, columns)])
	return texture != 0 and TileDefs.type_id_of(texture) == TileDefs.TYPE_WALL

## 角色包围盒触碰的第一个 16px 阻挡子格；空数组表示净空。
static func _first_blocking_sub(subgrid: Array, rows: int, columns: int, cell: Vector2i) -> Array:
	var center := Vector2(cell) * float(GameParameters.TILE_SIZE) \
			+ Vector2(SPAWN_CENTER, SPAWN_CENTER)
	var bounds := Rect2(center + SPAWN_RECT.position, SPAWN_RECT.size)
	var sub := int(Terrain.SUB_SIZE)
	for sy in range(floori(bounds.position.y / sub), floori((bounds.end.y - 0.001) / sub) + 1):
		for sx in range(floori(bounds.position.x / sub), floori((bounds.end.x - 0.001) / sub) + 1):
			if cell_blocked(subgrid, rows, columns, sx, sy):
				return [sx, sy]
	return []

## 角色包围盒无阻挡的 64px 格集合；只证明静态空域邻接，不代表跳跃/台阶可达。
static func static_clear_region(subgrid: Array, dims: Vector2i, start: Vector2i) -> Dictionary:
	var visited := {}
	if start.x < 0 or start.y < 0 or start.x >= dims.x or start.y >= dims.y:
		return visited
	var rows := subgrid.size()
	var columns := (subgrid[0] as Array).size()
	var stack: Array = [start]
	visited[start] = true
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next := Vector2i(posmod(cell.x + offset.x, dims.x), posmod(cell.y + offset.y, dims.y))
			if visited.has(next):
				continue
			if _first_blocking_sub(subgrid, rows, columns, next).is_empty():
				visited[next] = true
				stack.append(next)
	return visited
