class_name RunOptions
extends RefCounted

# 单人开局选项(菜单→Level0 传递)。静态会话,同 PvpSession 风格(非 autoload)。
# 菜单里选择后写这里;Level0._ready / 玩家 _ready 读取生效。

static var disabled_weapons: Array[int] = []   # 禁用的武器槽位(1-6)

static func reset() -> void:
	disabled_weapons = []
