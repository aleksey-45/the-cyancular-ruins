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

# ── 「开局三载荷的跨场景交接」已删除(2026-09-12)──
# 原先 worker 在 match_start 同一批 flush 里**推** peer_info/peer_hues/match_options,而客户端
# 那一刻正在帧末切场景 → 订阅方一个都不存在 → 静默丢失(自检 B2:对手颜色不生效 / 昵称表空到
# 连自己头顶 ID 都建不出来 / 禁武器闸门没上)。当时的解法是大厅先接住、缓存成本文件的
# pending_* 静态字段、新场景进场景时取用。
# 现在改成**进场拉取**(`NetBus.match_sync`):新场景建好、订阅齐了才开口要,时序不敏感。
# 于是缓存这一层连同 pending_* 一并删除 —— 只留一条投递路径,也就不存在"只改一条"的错法。
# 守卫:`tests/match_sync_probe` 的反向断言,全仓不得再出现这些标识符。

static func reset() -> void:
	server_address = "120.53.107.140"
	port = 7777
	room_code = ""
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	disabled_weapons = []
	royale = false
