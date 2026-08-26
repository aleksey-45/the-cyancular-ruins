extends Node

# 共享参数:玩家/敌人/子弹共用的物理与全局网格、敌人生成。
# 玩家专属参数已拆到 PlayerParams(移动/跳跃/冲刺/镜头/战斗)。

# ── 物理基础(共享)──
const gravity0: float = 1600.0
const TILE_SIZE: int = 64

# ── 水 ──
const water_sway_amp: float = 3.0        # 水面起伏幅度(px,顶部拉伸)
const water_sway_speed: float = 0.8      # 水面晃动角速度(rad/s)
const water_bullet_drag: float = 2.0     # 子弹水中速度指数阻力(exp(-drag·Δt))
const water_fx_move_threshold: float = 40.0   # 实体移动速度低于此值不发射水粒子
const water_fx_splash_band: float = 20.0     # 脚底距水面线 ≤ 此值算溅水花
const water_fx_splash_interval: float = 0.15
const water_fx_bubble_interval: float = 0.12

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
