class_name MatchBootstrap
extends RefCounted

# 对局引导启动器：刷新世界尺寸、向参战客户端分发 match_start 指令并构建权威对局宿主。
#
# 架构设计说明：
# 独立解耦对局引导逻辑，避免对局宿主不必要地强依赖大厅房间管理器。
#
# 参数说明：
# - role_peers: 角色编号到客户端 peer_id 的映射字典
# - map_path: 对局使用的地图资源路径
# - options: 房主配置的对局选项（如禁用武器、回合回血等）
# - ai_roles: AI 补位角色编号列表（由服务端 AI 控制，不发送客户端开局包）

const PVP_MAP := "res://maps/newfactory.cyrm"


# 动态出生点选择逻辑集中由 SpawnPicker 管理，保证在独立测试环境下具备可测性。
static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	# 切换地图时重置 SpawnPicker 缓存，避免残留上一张地图的有效地面瓦片索引
	SpawnPicker.reset_cache()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	# 单出生点地图兼容处理：若地图仅包含 player 出生点，则为 role2 自动选取远离 role1 的有效地面位置
	if s2.x < 0 and s1.x >= 0:
		s2 = SpawnPicker.far_spawn_from(s1, MapFormat.load_map_file(map_path))
		print("MatchBootstrap: 地图 %s 缺少 player2 出生点，自动分配至 %s" % [map_path, s2])
	for role in role_peers:
		var peer_id: int = role_peers[role]
		# 客户端存活检测：避免向已断开连接的节点发送可靠 RPC 产生传输错误
		if not NetBus.is_peer_live(peer_id):
			continue
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles)
	return host
