class_name RunOptions
extends RefCounted

# 单人开局选项(菜单→Level0 传递)。静态会话,同 PvpSession 风格(非 autoload)。
# 菜单里选择后写这里;Level0._ready / 玩家 _ready 读取生效。

# 「本局禁了哪些枪」在**单机**下的权威就是本字段(菜单写入,`level_0.gd:94` 读)。
# 联机对局的权威是服务器 MatchHost,客户端侧真生效点是 `weapons.set_enabled_slots()`
# —— 完整对照见 core/pvp_session.gd 的「权威在哪」小节(全仓曾有 4 个同名 disabled_weapons)。
static var disabled_weapons: Array[int] = []   # 禁用的武器槽位(1-6)

static func reset() -> void:
	disabled_weapons = []
