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

const PVP_MAP := "res://maps/factory1v1.cyrm"


static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	for role in role_peers:
		var peer_id: int = role_peers[role]
		# 判活:有客户端可能已经在「报到 → 收到 match_start」之间的窗口里断开(它自己 stop() 了),
		# 而这两条是**定向**可靠包 → 往正在断开的 peer 发就是那条 channel 0 错误(判据见 NetBus)。
		if not NetBus.is_peer_live(peer_id):
			continue
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles)
	return host
