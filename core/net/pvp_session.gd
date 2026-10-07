class_name PvpSession
extends RefCounted

# 多人对战会话状态管理器（菜单、大厅与对局场景间的数据共享载体）。
# 纯静态 RefCounted 类，不依赖全局单例。
# 仅维护对局启动、断线重连与大厅流转所需的权威数据。

const DEFAULT_PORT := 7777
static var server_address: String = "127.0.0.1"   # 本地回环地址或远程服务器 IP
static var server_port: int = DEFAULT_PORT
static var role: int = 1                          # 玩家对局角色编号（1 为房主或第一角色）
static var player_name: String = "Anon"           # 玩家昵称
static var map_path: String = ""                  # 当前对局地图文件路径（由服务端权威下发）
static var spawn: Vector2i = Vector2i(-1, -1)     # 本端角色出生坐标

# 断线重连会话凭据：
# token：由服务端生成并下发的一次性会话凭据，用于断线后认领角色实体。
# worker_port：对局服务监听端口，自动重连时直连此端口。
static var token: String = ""
static var worker_port: int = 0

# 大厅重返对局凭据：
# room_code：重连目标房间号，供大厅核对会话凭据并高亮可重连房间。
# rejoin：重连标记，置为 true 时客户端通过 reclaim_role 认领角色而非重新加入。
static var room_code: String = ""
static var rejoin: bool = false

# 时间玩法模式标记：
# 标记当前是否处于 Beta 时间控制模式（影响大厅房间可见性及服务端时间规则判定）。
static var beta_mode := false

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"

# 记录凭据所属的对战模式（pvp / royale / team）
static var room_mode: String = ""

# 进入大厅时的默认筛选模式
static var entry_mode: String = ""


# 检查是否持有完整的有效重连凭据
static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != ""


# 判定指定房间是否为当前客户端可重连的目标房间
static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode


# 清除当前持有的重连凭据（在服务端拒绝重连、重连超时或主动切换房间时调用）
static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false


# 记录当前加入或创建的房间信息。
# 若房间号或模式发生变化，则清空上一局遗留的重连凭据。
static func note_room(code: String, mode: String) -> void:
	if code != room_code or mode != room_mode:
		clear_rejoin()
	room_code = code
	room_mode = mode


# 进入大厅页面时的状态重置：
# 仅重置角色、出生点及模式筛选状态，保留正在进行中的对局重连凭据与上次连接的服务器地址。
static func reset() -> void:
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	beta_mode = false
	entry_mode = ""
