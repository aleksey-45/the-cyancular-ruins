class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。

static var server_address: String = "120.53.107.140"   # 默认服务器(云)
static var port: int = 7777
static var room_code: String = ""
static var role: int = 1          # 1=P1, 2=P2
static var player_name: String = "Anon"   # 玩家在匹配界面输入的昵称(默认 Anon;头上显示;会话内不清)
static var map_path: String = ""
static var spawn: Vector2i = Vector2i(-1, -1)
static var disabled_weapons: Array[int] = []   # 本局生效的禁用武器(服务器 match_options 下发)

static func reset() -> void:
	server_address = "120.53.107.140"
	port = 7777
	room_code = ""
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	disabled_weapons = []
