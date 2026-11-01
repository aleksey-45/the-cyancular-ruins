class_name MatchBootstrap
extends RefCounted

# 建局:在 **worker 进程**里调用 —— 重算世界尺寸 + 给两端发 match_start + 建权威对局宿主。
#
# ★ 为什么单独成文件(2026-09-14):它原本住在 server/room_manager.gd(RoomManager)里,
#   而 RoomManager 是大厅侧的房间注册表(+ 端口池 + 房间状态广播 + PowerShell 杀进程)。
#   worker 进程只需要建局,却因为 class_name 连带加载整张大厅注册表。
#   MatchHost / RoyaleHost 都住在"对局宿主"这一侧,建局引导也该在这一侧。
#
# role_peers = {role: peer_id};options = 房主(role1)的对局选项(禁武器/回合回血等,见 MatchHost);
# ai_roles = AI 补位 role 列表(实验性):这些 role 由服务端 AI 驱动,不发 match_start。
# 与旧 lobby._start_match 同逻辑,只是脱离大厅进程/房间状态。

const PVP_MAP := "res://maps/newfactory.cyrm"
# ★ 1v1 出生点 = 地图 meta 的 `# respawn 1|2` 列表(按半区写死的固定数据):start_on 按侧随机算好一份交给宿主,并广播同一份。
#   侧 1 = 左半 / 侧 2 = 右半;role1 → 侧 1、role2 → 侧 2(其它 role 沿用旧口径走侧 2)。
#   无 `# respawn` 的老图回退到改造前的两点逻辑(`# player` / `# player2` + role2 缺失时 far_spawn_from)。
# ★ `far_spawn_from` / `FAR_CELLS` 仍住在 `core/sim/spawn_picker.gd`(这个文件静态引用 autoload,`-s` 下编译不过)。


# 1v1 出生点:每个 role 从**自己半区**的 `# respawn` 列表随机取一格(互不相同、尽量 ≥ SpawnPicker.FAR_CELLS)。
# 空表 = 老图无 `# respawn` / 某侧无点 → 调用方走 legacy 回退路径。
static func plan_spawns(roles: Array) -> Dictionary:
	var sides: Dictionary = MazeGenerator.load_spawns().get("respawns", {})
	var out := {}
	if sides.is_empty():
		return out
	var dims := MazeGenerator.map_size()
	var taken: Array = []
	for role in roles:
		var side := SpawnChooser.SIDE_LEFT if int(role) == 1 else SpawnChooser.SIDE_RIGHT
		var points: Array = SpawnPicker.filter_reachable(sides.get(side, []))
		if points.is_empty():
			return {}
		var cell := SpawnChooser.pick(points, taken, null, SpawnPicker.FAR_CELLS, taken, dims)
		if cell.x < 0:
			return {}
		taken.append(cell)
		out[int(role)] = cell
	return out


# 老地图(无 `# respawn`)的向后兼容路径:逐字保留改造前行为 —— 地图两点 + role2 缺失时现挑一个远离 role1 的地板格。
# ★ role_peers 的键为 1/2 时与改造前一致;其它 role(1v1 AI 补位)沿用旧代码的"非 1 即 s2"口径。
static func legacy_plan_spawns(roles: Array, map_path: String) -> Dictionary:
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	if s2.x < 0 and s1.x >= 0:
		s2 = SpawnPicker.far_spawn_from(s1, MapFormat.load_map_file(map_path))
		print("MatchBootstrap: 图 %s 无 player2 出生点 → role2 自动分配 %s" % [map_path, s2])
	var out := {}
	for role in roles:
		out[int(role)] = s1 if int(role) == 1 else s2
	return out


static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# ★★ 必须在地图出生点规划**之前**把网格载进 MazeGenerator:可抵达判据(`SpawnPicker.reachable_spawn_cells`)
	#   读 `current_grid`,网格为空时所有 `# respawn` 点都会被判"不可抵达" ⇒ 永远掉进 legacy 回退。
	#   (RoyaleHost/TeamHost 的 start_on 本来就是这个顺序,只有这里漏了 —— 2026-11-01 修。)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	# 同一进程里换图时 SpawnPicker 的几何缓存必须清(回退路径用它;worker 一局一进程,清一次是零成本的保险)。
	SpawnPicker.reset_cache()
	var roles: Array = role_peers.keys()
	var spawns := plan_spawns(roles)
	if spawns.is_empty():
		spawns = legacy_plan_spawns(roles, map_path)
	for role in role_peers:
		var peer_id: int = role_peers[role]
		# 判活:有客户端可能已经在「报到 → 收到 match_start」之间的窗口里断开(它自己 stop() 了),
		# 而这两条是**定向**可靠包 → 往正在断开的 peer 发就是那条 channel 0 错误(判据见 NetBus)。
		if not NetBus.is_peer_live(peer_id):
			continue
		NetBus.rpc_id(peer_id, "match_start", role, spawns.get(int(role), Vector2i(-1, -1)), map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	# ★ 第 5 个实参是 teams(本模式空表)、第 6 个是 spawns —— 传错不是崩溃,而是两端出生点不一致(只剩一行日志可查)。
	var host := MatchHost.new(map_path, role_peers, options, ai_roles, {}, spawns)
	return host
