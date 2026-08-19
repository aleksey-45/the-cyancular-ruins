extends Node

# ── 物理基础 ──
const gravity0: float = 1600.0
const jump_velocity: float = -1000.0
const charge_down_velocity: float = 2000.0
const charge_velocity: float = 1500.0
const charge_duration: float = 0.6
const TILE_SIZE: int = 16

# ── 行走手感（方案 A）──
const move_speed: float = 700.0
const accel_ground: float = 30.0    # 地面加速缓动系数（越大起步越跟手）
const accel_air: float = 9.0        # 空中加速
const brake_ground: float = 16.0    # 地面松键减速（带一点滑行）
const brake_air: float = 6.0        # 空中松键减速

# ── 跳跃手感（方案 A）──
const coyote_time: float = 0.1      # 离开地面后仍可起跳的时间（秒）
const jump_buffer_time: float = 0.12  # 落地前提前按跳的缓冲时间（秒）
const jump_cut_factor: float = 0.5  # 上升中松键时向上速度的衰减比例

# ── 镜头手感（方案 A）──
const cam_lookahead_x: float = 100.0   # 满速时的水平前瞻像素
const cam_lookahead_y: float = 80.0   # 满速上升/下落时的垂直前瞻像素
const cam_y_bias: float = -100.0      # 基础向上偏移（保留原 100px）
const cam_smooth_x: float = 10.0      # X 平滑指数系数
const cam_smooth_y: float = 8.0       # Y 平滑指数系数
const cam_deadzone: float = 8.0       # 死区像素（小于此值镜头不动）

# ── 敌人生成 ──
const enemy_count: int = 35
const enemy_spawn_min_dist: float = 500.0

# ── 玩家战斗 ──
const player_max_hp: int = 50
const iframes_time: float = 0.2
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0

var MAP_WIDTH: int
var MAP_HEIGHT: int

func _ready() -> void:
	# 地图尺寸以实际地图文件为准(不再用固定常量,避免地图变更后失真)。
	var cells := MazeGenerator.map_size()
	MAP_WIDTH = cells.x * TILE_SIZE
	MAP_HEIGHT = cells.y * TILE_SIZE
