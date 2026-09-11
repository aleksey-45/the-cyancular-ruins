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
static var royale: bool = false                # 大乱斗局:N 人限时死斗

# ── 开局三条一次性载荷的跨场景交接(自检 B2)──
# worker 在 `match_start` 同一批 flush 里还发了 `peer_info`(昵称表)/`peer_hues`(角色色相)/
# `match_options`(禁武器等生效选项)。三者与 `match_start` 落在**同一次客户端 poll** 里,而
# 大乱斗大厅收到 `match_start` 后是**帧末**才切场景(royale_lobby._on_match_start,栈内切会
# 段错误,不能改),新场景 royale_game 的订阅在那次 poll 里一个都不存在 → 载荷静默丢失
# (对手颜色不生效 / 昵称表空到连自己头顶 ID 都建不出来 / 禁武器闸门没上)。
# 故由**那一刻还活着**的大厅先接住,缓存到这里,royale_game 进场景时取用。
# 生命周期:进大厅(_ready)与每次 go_match 都先清空 → 不跨局残留(第二局若投递失败,取到的是
# 空词典而不是上一局的昵称/禁武器)。
static var pending_peer_info: Dictionary = {}
static var pending_peer_hues: Dictionary = {}
static var pending_match_options: Dictionary = {}

static func clear_pending_payloads() -> void:
	pending_peer_info = {}
	pending_peer_hues = {}
	pending_match_options = {}

static func reset() -> void:
	server_address = "120.53.107.140"
	port = 7777
	room_code = ""
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	disabled_weapons = []
	royale = false
	clear_pending_payloads()
