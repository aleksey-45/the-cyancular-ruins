extends Node

# 共享参数:玩家/敌人/子弹共用的物理与全局网格、敌人生成。
# 玩家专属参数已拆到 PlayerParams(移动/跳跃/冲刺/镜头/战斗)。

# ── 物理基础(共享)──
const gravity0: float = 1600.0
const TILE_SIZE: int = 32

# ── 敌人生成 ──
const enemy_count: int = 35
const enemy_spawn_min_dist: float = 500.0

var MAP_WIDTH: int
var MAP_HEIGHT: int

func _ready() -> void:
	# 地图尺寸以实际地图文件为准(不再用固定常量,避免地图变更后失真)。
	var cells := MazeGenerator.map_size()
	MAP_WIDTH = cells.x * TILE_SIZE
	MAP_HEIGHT = cells.y * TILE_SIZE
