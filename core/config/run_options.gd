class_name RunOptions
extends RefCounted

# 单人模式开局选项配置（从主菜单传递至 Level0 关卡）。纯静态会话类设计，生命周期同 PvpSession（非 Autoload）。
# 在主菜单选择对应选项后写入；Level0._ready 与玩家初始化时读取并应用。

# 单人模式下禁用武器列表的权威数据源（由主菜单写入，Level0 读取）。
# 联机对战模式下禁用武器以服务端 MatchHost 权威判定为准，客户端通过 weapons.set_enabled_types() 同步生效。
# 详细设计参见 core/pvp_session.gd 说明。
static var disabled_weapons: Array[int] = []   # 禁用的武器槽位列表（1-6）

static func reset() -> void:
	disabled_weapons = []
