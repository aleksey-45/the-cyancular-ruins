class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。

static var server_address: String = "127.0.0.1"
static var port: int = 7777
static var room_code: String = ""
static var role: int = 1          # 1=P1, 2=P2
static var map_path: String = ""
static var spawn: Vector2i = Vector2i(-1, -1)

static func reset() -> void:
	server_address = "127.0.0.1"
	port = 7777
	room_code = ""
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
