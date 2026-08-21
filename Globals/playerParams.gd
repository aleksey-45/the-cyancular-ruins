class_name PlayerParams
extends RefCounted

# 玩家专属参数集中地(从 gameParameters 拆出)。gameParameters 只留共享参数
# (gravity0/TILE_SIZE/地图尺寸/敌人生成)。访问方式: PlayerParams.move_speed。
# 与 EnemyParams 同风格: RefCounted + const,不做 autoload。

# ── 行走手感(方案 A)──
const move_speed: float = 700.0
const accel_ground: float = 30.0    # 地面加速缓动系数(越大起步越跟手)
const accel_air: float = 9.0        # 空中加速
const brake_ground: float = 16.0    # 地面松键减速(带一点滑行)
const brake_air: float = 6.0        # 空中松键减速

# ── 跳跃手感(方案 A)──
const jump_velocity: float = -1000.0
const coyote_time: float = 0.1      # 离开地面后仍可起跳的时间(秒)
const jump_buffer_time: float = 0.12  # 落地前提前按跳的缓冲时间(秒)
const jump_cut_factor: float = 0.5  # 上升中松键时向上速度的衰减比例

# ── 冲刺 ──
const charge_down_velocity: float = 2000.0
const charge_velocity: float = 1500.0
const charge_duration: float = 0.6
const charge_dir_window: float = 0.3  # 冲刺方向沿用最近移动方向的窗口(秒)

# ── 镜头手感(方案 A)──
const cam_lookahead_x: float = 100.0   # 满速时的水平前瞻像素
const cam_lookahead_y: float = 80.0    # 满速上升/下落时的垂直前瞻像素
const cam_y_bias: float = -100.0       # 基础向上偏移(保留原 100px)
const cam_smooth_x: float = 10.0       # X 平滑指数系数
const cam_smooth_y: float = 8.0        # Y 平滑指数系数
const cam_deadzone: float = 8.0        # 死区像素(小于此值镜头不动)

# ── 玩家战斗 ──
const player_max_hp: int = 50
const iframes_time: float = 0.25
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0
const player_knock_decay_rate: float = 10.0  # 爆炸击退向量指数衰减率(越大停得越快)
const hit_cam_shake: float = 8.0        # 大伤害(一次扣血 >25% 最大血)相机震动基准幅度
const hit_cam_shake_time: float = 0.25  # 大伤害相机震动时长(秒)
