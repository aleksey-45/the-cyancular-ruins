class_name MatchBootstrap
extends RefCounted

# 建局:在 **worker 进程**里调用 —— 重算世界尺寸 + 给两端发 match_start + 建权威对局宿主。
#
# - 为什么单独成文件(2026-09-14):它原本住在 server/room_manager.gd(RoomManager)里,
#   而 RoomManager 是大厅侧的房间注册表(+ 端口池 + 房间状态广播 + PowerShell 终止进程)。
#   worker 进程只需要建局,却因为 class_name 连带加载整张大厅注册表。
#   MatchHost / RoyaleHost 都住在"对局宿主"这一侧,建局引导也该在这一侧。
#
# role_peers = {role: peer_id};options = 房主(role1)的对局选项(禁武器/回合回血等,见 MatchHost);
# ai_roles = AI 补位 role 列表(实验性):这些 role 由服务端 AI 驱动,不发 match_start。
# 与旧 lobby._start_match 同逻辑,只是脱离大厅进程/房间状态。

const PVP_MAP := "res://maps/newfactory.cyrm"


# - `far_spawn_from` / `FAR_CELLS` 已搬到 `core/sim/spawn_picker.gd`(2026-10-02 合并时)。
#   理由不是"更整齐",而是**原来那条断言根本没在跑**:`map_catalog_probe` 是 `-s` 探针,
#   而本文件静态引用了 autoload(`GameParameters` / `NetBus`) ->  在 `-s` 下**编译失败**,
#   探针里 `load()` 到的是一个没有成员的 GDScript  ->  `mb.far_spawn_from(...)` 抛
#   "Nonexistent function" 而被**静默跳过**,verdict 照打 OK。
#   `SpawnPicker` 自述"全部 static、不引任何 autoload、可被 -s 测试加载",正是这类选格逻辑的家。
static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# 同一进程里换图时 SpawnPicker 的三级缓存必须清(它的注释明确提示过这条纪律;worker 一局一进程,
	# 但大厅/单人若也建宿主就会踩,清一次是零成本的保险)。
	SpawnPicker.reset_cache()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	# 只标了一个出生点的图(单人图,如 demo.cyrm):给 role2 现挑一个远离 role1 的地板格 ——
	# 否则两端会落在同一个点上(或落到 (-1,-1) 的保底处理格上)。
	if s2.x < 0 and s1.x >= 0:
		s2 = SpawnPicker.far_spawn_from(s1, MapFormat.load_map_file(map_path))
		print("MatchBootstrap: 图 %s 无 player2 出生点 → role2 自动分配 %s" % [map_path, s2])
	for role in role_peers:
		var peer_id: int = role_peers[role]
		# 存活检测:有客户端可能已经在「报到 → 收到 match_start」之间的窗口里断开(它自己 stop() 了),
		# 而这两条是**定向**可靠包 → 往正在断开的 peer 发就是那条 channel 0 错误(判据见 NetBus)。
		if not NetBus.is_peer_live(peer_id):
			continue
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles)
	return host
