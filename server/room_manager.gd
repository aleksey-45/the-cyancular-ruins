class_name RoomManager
extends Node

# 房间注册表(服务器端):房间号 → 玩家;2 人就绪发 match_start。
# 由 NetBus 转交信号驱动(建房/加入/断线),不硬依赖 NetBus 调用本类方法。

# PvP 固定竞技场地图(1v1,含 # player / # player2 出生点)。
const PVP_MAP := "res://factory_1V1(260827).cyrm"

class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> 1/2
	var match_host: Node = null           # MatchHost 权威对局模拟

var rooms: Dictionary = {}   # code -> Room

func _enter_tree() -> void:
	NetBus.room_create_requested.connect(create_room)
	NetBus.room_join_requested.connect(join_room)
	NetBus.peer_left.connect(on_peer_left)

func _exit_tree() -> void:
	NetBus.room_create_requested.disconnect(create_room)
	NetBus.room_join_requested.disconnect(join_room)
	NetBus.peer_left.disconnect(on_peer_left)

func _generate_code() -> String:
	return "%04d" % (randi() % 10000)

func create_room(caller: int) -> void:
	var code := _generate_code()
	while rooms.has(code):
		code = _generate_code()
	var room := Room.new()
	room.code = code
	room.players.append(caller)
	room.player_role[caller] = 1
	rooms[code] = room
	print("房间 %s 创建(房主 peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_created", code)

func join_room(caller: int, code: String) -> void:
	if not rooms.has(code):
		NetBus.rpc_id(caller, "server_message", "房间不存在")
		return
	var room: Room = rooms[code]
	if room.players.size() >= 2:
		NetBus.rpc_id(caller, "server_message", "房间已满")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	print("房间 %s 加入(peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_joined", 2)
	_start_match(room)

func on_peer_left(peer_id: int) -> void:
	for code in rooms.keys():
		var room: Room = rooms[code]
		if not room.players.has(peer_id):
			continue
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
		# 对局中途断线:1v1 无法继续 → 通知存活方(播报后回菜单),整房拆除
		# (设计:检测到对端退出 → 通知另一客户端 → 回菜单;不做断线恢复。)
		if room.match_host != null and not room.players.is_empty():
			print("房间 %s 对局中断(玩家 %d 退出),通知存活方" % [code, peer_id])
			for survivor in room.players:
				NetBus.rpc_id(survivor, "opponent_left")
			room.match_host.queue_free()
			room.match_host = null
			rooms.erase(code)
			continue
		if room.players.is_empty():
			if room.match_host != null:
				room.match_host.queue_free()
				room.match_host = null
			rooms.erase(code)
			print("房间 %s 关闭" % code)

func _start_match(room: Room) -> void:
	# PvP 固定用 1v1 竞技场地图(含 player/player2 出生点);客户端加载同名文件。
	MazeGenerator.set_map_file(PVP_MAP)
	# 重算世界尺寸:GameParameters._ready 在启动时算的是随机 demo 图(8000 宽),
	# factory 图是 9600 宽,不重算则环面回绕按错边界 → 玩家在图中间被空气墙弹走。
	GameParameters.refresh_map_size()
	var map_path := MazeGenerator.map_file_path()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	for peer_id in room.players:
		var role: int = room.player_role[peer_id]
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	# 创建权威对局模拟(每房间一个 MatchHost)。role_peers = role -> peer_id。
	var role_peers := {}
	for peer_id in room.players:
		role_peers[room.player_role[peer_id]] = peer_id
	var match_host := MatchHost.new(map_path, role_peers)
	add_child(match_host)
	room.match_host = match_host
	print("房间 %s 开局" % room.code)
