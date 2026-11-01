class_name TeamSpawn
extends RefCounted

# 团队模式的散点选格 / 队层契约 / 复活选格:只有静态计算与配层写入,不持有状态、不碰生命周期。
# ★ 出生/复活点数据 = 地图 meta 的 `# respawn 1|2` 行(按阵营半区写死的固定数据);队 1 用侧 1(左半)、队 2 用侧 2(右半),
#   换边(下一局)时两队互换侧。随机/排除上一次/最小间距在 core/sim/spawn_chooser.gd。
# ★ 缺数据的老图回退到改造前的 SpawnPicker 几何生成(判据与重试循环原样保留),并 push_warning 一次。
# ★ 拆出来的理由:这些计算只读「地图 + 队伍表 + 当前存活者」,与对局流程无关;TeamHost 只留生命周期钩子与虚方法覆写。
# ★ 常量全部住这里作单一来源;TeamHost.TEAM_ENEMY_LAYER 是转出(客户端 team_game 与 team_match_watcher 读的是那个名字)。

const SPAWN_CLEARANCE := 15      # 两个基座的最小环面距离(格)
const TEAMMATE_CLEARANCE := 3    # 队内三人最小间距(格):够散开,又不至于走出"队形"
const SPAWN_BASE_RADIUS := 30    # 基座附近取点半径(格);池子不够会退回全量候选
const SPAWN_MAX_TRIES := 12      # 散点重试次数(见 plan_team_spawns 的说明;每份只要 ~几十微秒)
const RESPAWN_CLEARANCE := 8     # 复活点离**存活敌人**的最小环面距离(格)
# ★ 队 B 的身体层(层位 5,值 16);全仓层位占用:1 地形 / 2 玩家 / 4 敌人 / 8 掉落物,第 5 位此前无人占用。
const TEAM_ENEMY_LAYER := 16


# 队友不互挡(用户裁定「完全穿透」)── ★ 必须「分队位」而不是改掩码:Godot 的碰撞按节点配,没有「按对」的开关,
# 全部玩家同在第 2 层时掩码含 2 就是与所有玩家碰撞;队 B 挪到层位 16、两队掩码互指即可 A↔B 挡、A↔A 与 B↔B 穿。
# ★ 契约:1 队 layer=2 / mask=21、2 队 layer=16 / mask=7(都保留地形 1 与敌人 4,抹 2 时丢掉 1|4 会穿墙);必须在 super._init 之后调。
# ★ 幂等(直接赋值、不叠加):单独成函数是为了让「手工摆位」路径能补调一次,而不必自己再抄一份配层规则(第二份真相)。
static func apply_team_layers(players: Dictionary, teams: Dictionary) -> void:
	for role in players:
		var p: Node2D = players[role]
		if p == null or not is_instance_valid(p):
			continue
# ★ 队号必须穷举 1/2,不能写成 if t == 1 … else …:表外 role 的队号是 0,else 会把它静默划进 2 队 → 非对称碰撞且不报错(与
# 1 队互挡、与 2 队互穿);未知队号什么都不配 + push_error。★ 先 if 拦再 match:实测 match 体内 continue 在非末臂里会「落到下一个 pattern」。
		var t := int(teams.get(int(role), 0))
		if t != 1 and t != 2:
			push_error("TeamHost: role %d 的队号是 %d(不在 {1,2} 里),不配分队碰撞层" % [int(role), t])
			continue
		match t:
			1:
				p.collision_layer = 2
				p.collision_mask = (p.collision_mask & ~2) | TEAM_ENEMY_LAYER
			2:
				p.collision_layer = TEAM_ENEMY_LAYER


# 团队出生点(每局调用一次):用地图 meta 的 `# respawn 1|2` 列表(按阵营半区写死)——队 1 取侧 1、队 2 取侧 2,
# 每人随机一格、不与本人上一局同格、队内尽量拉开;`side_swap` = 换边(两队互换侧)。
# ★ 缺数据(老图无 `# respawn`)或某队人数超过该侧列表 ⇒ 回退改造前的几何生成(`_plan_team_spawns_geometry`,逐字保留),
#   并 push_warning 一次。★★ 数据路径**不做**几何重试:点的合理性由地图数据负责(tools/map_spawn_meta.gd 校验)。
static func plan_team_spawns(teams: Dictionary, last: Dictionary = {}, side_swap := false) -> Dictionary:
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if not by_team.has(t):
			_warn_legacy_spawn("role %d 的队号 %d 不在 {1,2}" % [int(role), t])
			return _plan_team_spawns_geometry(teams)
		(by_team[t] as Array).append(int(role))
	var sides := _map_sides()
	var can_use_data := (sides.get(1, []) as Array).size() >= (by_team[1] as Array).size() \
			and (sides.get(2, []) as Array).size() >= (by_team[2] as Array).size()
	if not can_use_data:
		_warn_legacy_spawn()
		return _plan_team_spawns_geometry(teams)
	var d := SpawnPicker.grid_dims()
	var out := {}
	for t in [1, 2]:
		var roles_t: Array = by_team[t]
		roles_t.sort()   # 确定性:同队的 role 按号升序拿点
		var side: int = (3 - t) if side_swap else t
		var pts: Array = sides.get(side, [])
		var picked: Array = []
		for role in roles_t:
			var exclude: Array = picked.duplicate()
			if last.has(int(role)):
				exclude.append(last[int(role)])
			var cell := SpawnChooser.pick(pts, exclude, null, TEAMMATE_CLEARANCE, picked, d)
			if cell.x < 0:   # 自己的上一局点位 + 已占点把候选筛空:放弃"不与上一局同位"这一条,先保证不撞人
				cell = SpawnChooser.pick(pts, picked, null, TEAMMATE_CLEARANCE, picked, d)
			if cell.x < 0:
				_warn_legacy_spawn()
				return _plan_team_spawns_geometry(teams)
			picked.append(cell)
			out[int(role)] = cell
	return out


# 地图两侧的复活点列表(顺带按 SpawnChooser 的 side 常量取键;缺数据时返回两个空数组。不可达点在此剔除 + warning 一次)。
static func _map_sides() -> Dictionary:
	var raw: Dictionary = MazeGenerator.load_spawns().get("respawns", {})
	var out := {SpawnChooser.SIDE_LEFT: [], SpawnChooser.SIDE_RIGHT: []}
	for side in [SpawnChooser.SIDE_LEFT, SpawnChooser.SIDE_RIGHT]:
		out[side] = SpawnPicker.filter_reachable(raw.get(side, []))
	return out


static var _warned_legacy_spawn := false


static func _warn_legacy_spawn(why := "") -> void:
	if _warned_legacy_spawn:
		return
	_warned_legacy_spawn = true
	push_warning("TeamSpawn: 地图 # respawn 数据不足,回退 SpawnPicker 几何生成%s" % (
			"" if why.is_empty() else "(%s)" % why))


# 改造前的几何生成(无 `# respawn` 时的回退):多试几份、挑「队间最小距 − 队内最大距」最大的一份,绝不返回空表。
# ★★ 为什么外面套一层重试循环:上面那两句并不蕴含「队间远」—— 半径 30 的点云在环面上重叠得很厉害,而基座只保证相距 ≥ 15 格
# (实测 200 次里 123 次「队间最小距 ≤ 队内最大距」,最坏两队有人同格):多试几份、挑最好的一份,但绝不返回空表(start_on 会缺键)。
static func _plan_team_spawns_geometry(teams: Dictionary) -> Dictionary:
	var best := {}
	var best_margin := -(1 << 30)   # ★ GDScript 不接受 `-1 << 30`(移位只收正操作数)
	for _attempt in range(SPAWN_MAX_TRIES):
		var cand := _plan_team_spawns_once(teams)
		var margin := _spawn_margin(cand, teams)
		if margin > best_margin:
			best_margin = margin
			best = cand
		if margin > 0:
			break
	return best



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
		(by_team[t] as Array).sort()   # 确定性:同队的 role 按号升序拿点
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out



static func _spawn_margin(spawns: Dictionary, teams: Dictionary) -> int:
	if spawns.size() < 2:
		return 1   # 不足两人 = 没有"队间/队内"可言,视为满足(别让空表把重试跑满)
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


# 换边用的点集:两个队的点整体对调(队 A 第 i 人 ↔ 队 B 第 i 人)。★ 两队人数必须严格相等(满 6 人开局保证),否则返回空表、不换边 —— 宁可这局不换,也不要把人送到错的一侧。
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


# 局内复活点:用**本队这一局所在侧**的 `# respawn` 列表(不跨侧、不回退几何),筛「离所有存活敌人 ≥ RESPAWN_CLEARANCE」
# 且「不是本 role 上一次落点」的格随机取一个。★ 判据是「离敌人远」、不是「离所有玩家远」(队友在附近复活是好事)。
# ★ 侧:队 1 → 侧 1(左半)、队 2 → 侧 2;`side_swap` 时两队互换。★ 缺数据(老图 / 队号非法 / 该侧列表为空)才回退
#   改造前的 SpawnPicker.respawn_pools() 池序列,并 push_warning 一次。
static func respawn_cell(role: int, players: Dictionary, teams: Dictionary, last: Dictionary = {},
		sides: Dictionary = {}, side_swap := false) -> Vector2i:
	var t := int(teams.get(int(role), 0))
	var pts: Array = []
	if t == 1 or t == 2:
		var side: int = (3 - t) if side_swap else t
		pts = sides.get(side, [])
	if pts.is_empty():
		_warn_legacy_spawn()
		return _respawn_cell_geometry(role, players, teams)
	var d := SpawnPicker.grid_dims()
	var anchors: Array = []
	for other in players:
		if int(other) == int(role) or _same_team(teams, int(role), int(other)):
			continue   # 队友不用躲(语义与 royale 那条"离所有存活玩家远"不同,见上面注释)
		var op: Node2D = players[other]
		if op == null or not is_instance_valid(op) or op.is_downed():
			continue
		anchors.append(Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
				int(op.global_position.y) / GameParameters.TILE_SIZE))
	var exclude: Array = []
	if last.has(int(role)):
		exclude.append(last[int(role)])
	var far: Array = []
	for c in pts:
		if exclude.has(c):
			continue
		var ok := true
		for a in anchors:
			if MazeGenerator.toroidal_dist(c, a, d.x, d.y) < RESPAWN_CLEARANCE:
				ok = false
				break
		if ok:
			far.append(c)
	if not far.is_empty():
		return SpawnChooser.pick(far, [], null)
	var cell := SpawnChooser.pick(pts, exclude, null, RESPAWN_CLEARANCE, anchors, d)
	if cell.x >= 0:
		return cell
	return _respawn_cell_geometry(role, players, teams)


# 改造前的几何复活(无 `# respawn` 数据时的回退):SpawnPicker.respawn_pools() 逐档随机,保留"离敌人远"判据。
static func _respawn_cell_geometry(role: int, players: Dictionary, teams: Dictionary) -> Vector2i:
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or _same_team(teams, role, int(other)):
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


# MatchState.same_team 的本地等价(MatchState 读 _team_of,本模块只拿得到那张表):任一方为 0 一律 false —— 0 == 0
# 若算同队,1v1/无队伍局里两个玩家会被判成队友。
static func _same_team(teams: Dictionary, a_role: int, b_role: int) -> bool:
	var a := int(teams.get(a_role, 0))
	var b := int(teams.get(b_role, 0))
	return a > 0 and a == b
