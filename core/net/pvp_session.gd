class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递),静态 RefCounted、非 autoload。加字段前先 grep 确认有读者。
# 回局凭据只在 clear_rejoin 的调用点死:**reset() 不得清凭据、也不得拨 server_address**(两件事都踩过坑,
# 症状是自己那间房恒灰、自建服玩家被踢回云;详见 docs/eng/netplay.md)。can_rejoin_to 是列表渲染与
# 行按下共用的唯一判据,房号与模式都要对上。

static var server_address: String = "120.53.107.140"
static var role: int = 1
static var player_name: String = "Anon"
static var map_path: String = ""
static var spawn: Vector2i = Vector2i(-1, -1)
static var token: String = ""
static var worker_port: int = 0
static var room_code: String = ""
static var rejoin: bool = false
static var beta_mode := false
const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"
static var room_mode: String = ""
static var entry_mode: String = ""


static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != ""


static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode


static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false


# 三页记房号的唯一入口。换房号或换模式 ⇒ 上一间的凭据到此为止;**房号没变时不清** —— 等待室每收一次
# 房间状态都会走这里,清了会把"回局"在本局开局后弄坏。
static func note_room(code: String, mode: String) -> void:
	if code != room_code or mode != room_mode:
		clear_rejoin()
	room_code = code
	room_mode = mode

static func reset() -> void:
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	beta_mode = false
	entry_mode = ""
