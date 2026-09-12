class_name RunOptions
extends RefCounted

# 单人开局选项(菜单→Level0 传递)。静态会话,同 PvpSession 风格(非 autoload)。
# 菜单里选择后写这里;Level0._ready / 玩家 _ready 读取生效。

static var disabled_weapons: Array[int] = []   # 禁用的武器槽位(1-5)
static var difficulty: int = 1                 # 0=简单 1=普通 2=困难
static var map_file: String = ""               # 单机指定地图(文件名;空=按旧规则随机)

# 难度 → 鸟密度倍率(相对地图 # enemy 元数据数量;困难在图上补采地板格刷新鸟)
const DENSITY: Array[float] = [0.5, 1.0, 1.5]
const DIFFICULTY_NAMES: Array[String] = ["简单", "普通", "困难"]

static func difficulty_mult() -> float:
	return DENSITY[clampi(difficulty, 0, DENSITY.size() - 1)]

static func reset() -> void:
	disabled_weapons = []
	difficulty = 1
	map_file = ""
