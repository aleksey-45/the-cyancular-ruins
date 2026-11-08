class_name PlayerConfig
extends Resource
# 玩家参数表:**只有 schema 和默认值**,真正生效的数值在 `player_config.tres`。
#
# ★ 什么进这里:会被反复调、又不属于地图格式的玩家手感值 —— 移动 / 跳跃 / 冲刺 / 攀爬 / 游泳 /
#   相机 / 生命与受击 / 武器拾取与掉落 / 补间形变。
#   不进这里:结构常量(`GameParameters.TILE_SIZE` 那种地图格式 v4 的定义),以及**派生值**
#   (`charge_duration = charge_distance / charge_velocity` 在 `PlayerParams` 里算,抄一份就会漂)。
#
# ★ .gd 默认值 = "在检查器里新建一份实例时的起点";**运行时永远读 `player_config.tres`**
#   (由 `PlayerParams` 以 `const` preload 引入 ⇒ 缺文件是加载期硬失败,不会静默退化成 0)。

@export_group("移动 / 跳跃")
## 地面水平速度(px/s)。
@export_range(0.0, 2000.0, 1.0) var move_speed: float = 700.0
## 水平加速指数缓动系数(越大越快抵达目标速度)。
@export_range(0.0, 200.0, 0.1) var accel_ground: float = 30.0
@export_range(0.0, 200.0, 0.1) var accel_air: float = 9.0
## 松手后的刹车缓动系数。
@export_range(0.0, 200.0, 0.1) var brake_ground: float = 16.0
@export_range(0.0, 200.0, 0.1) var brake_air: float = 6.0
## 水平速度低于此值直接归零(避免贴地滑行 / 极慢速抖动)。
@export_range(0.0, 50.0, 0.01) var stop_snap: float = 1.0

## 起跳速度(px/s,向上为负)。
@export_range(-3000.0, 0.0, 1.0) var jump_velocity: float = -1000.0
## 土狼时间 / 跳跃缓冲 / 松上键截断系数。
@export_range(0.0, 1.0, 0.01) var coyote_time: float = 0.1
@export_range(0.0, 1.0, 0.01) var jump_buffer_time: float = 0.12
@export_range(0.0, 1.0, 0.01) var jump_cut_factor: float = 0.5

## 蹲走水平速度(px/s)。
@export_range(0.0, 1500.0, 1.0) var crouch_walk_speed: float = 245.0

@export_group("冲刺")
## 空中下冲速度(px/s)。
@export_range(0.0, 6000.0, 1.0) var charge_down_velocity: float = 2000.0
## 冲刺距离(px)与冲刺速度(px/s);`charge_duration = 前者 / 后者`(派生,不在本表)。
@export_range(0.0, 2000.0, 1.0) var charge_distance: float = 256.0
@export_range(0.0, 10000.0, 1.0) var charge_velocity: float = 3000.0
## 空中冲刺重力倍率(只改重力,不改变冲刺距离)。
@export_range(0.0, 3.0, 0.01) var charge_air_gravity_mult: float = 0.35
## 双击方向后仍沿用最近移动方向的时间窗(秒)。
@export_range(0.0, 2.0, 0.01) var charge_dir_window: float = 0.3

@export_group("游泳")
## 水中水平速度 / 上浮 / 下沉(px/s)与水平缓动系数。
@export_range(0.0, 2000.0, 1.0) var player_swim_speed: float = 540.0
@export_range(-3000.0, 0.0, 1.0) var player_swim_up: float = -400.0
@export_range(0.0, 3000.0, 1.0) var player_swim_down: float = 320.0
@export_range(0.0, 100.0, 0.1) var player_swim_accel: float = 6.0
## 防水值上限与没顶时的单次扣血。
@export_range(0, 100, 1) var player_waterproof_max: int = 10
@export_range(0, 50, 1) var player_waterproof_damage: int = 5

@export_group("相机")
## 横向速度前瞻(px)与纵向固定偏移(px,向上为负)。
@export_range(0.0, 1000.0, 1.0) var cam_lookahead_x: float = 100.0
@export_range(0.0, 1000.0, 1.0) var cam_lookahead_y: float = 80.0
@export_range(-1000.0, 1000.0, 1.0) var cam_y_bias: float = -100.0
## 指数平滑系数(越大跟得越紧)。
@export_range(0.1, 60.0, 0.1) var cam_smooth_x: float = 10.0
@export_range(0.1, 60.0, 0.1) var cam_smooth_y: float = 8.0
## 死区半径(px):小于它的位移不推画面。
@export_range(0.0, 500.0, 1.0) var cam_deadzone: float = 32.0
## 镜头缩放。
@export_range(0.1, 4.0, 0.01) var cam_zoom: float = 0.75

@export_group("攀爬 / 弹跳")
## 梯子上 / 下与锁链上的攀爬速度(px/s,绝对值)。
@export_range(0.0, 3000.0, 1.0) var climb_ladder_up_speed: float = 850.0
@export_range(0.0, 3000.0, 1.0) var climb_ladder_down_speed: float = 800.0
@export_range(0.0, 3000.0, 1.0) var climb_chain_up_speed: float = 800.0
## 撞到弹性面时获得的反向速度(px/s)。
@export_range(0.0, 2000.0, 1.0) var elastic_bounce: float = 150.0

@export_group("生命 / 受击")
## 最大生命值与无敌帧时长(秒)。
@export_range(1, 500, 1) var player_max_hp: int = 50
@export_range(0.0, 3.0, 0.01) var iframes_time: float = 0.25
## 水平 / 向上击退速度(px/s)与击退衰减系数。
@export_range(0.0, 5000.0, 1.0) var player_hit_knockback: float = 400.0
@export_range(0.0, 3000.0, 1.0) var player_hit_knockback_up: float = 200.0
@export_range(0.0, 100.0, 0.1) var player_knock_decay_rate: float = 10.0
## 受击镜头震动幅度与时长。
@export_range(0.0, 100.0, 0.1) var hit_cam_shake: float = 8.0
@export_range(0.0, 3.0, 0.01) var hit_cam_shake_time: float = 0.25

@export_group("爆炸")
## 爆炸镜头震动幅度与时长。
@export_range(0.0, 200.0, 0.1) var explosion_cam_shake: float = 30.0
@export_range(0.0, 3.0, 0.01) var explosion_cam_shake_time: float = 0.5

@export_group("武器拾取 / 掉落")
## 拾取判定半径(px)与掉落物按住 S 的等待时间(秒)。
@export_range(0.0, 500.0, 1.0) var weapon_pickup_radius: float = 64.0
@export_range(0.0, 3.0, 0.01) var weapon_drop_hold_time: float = 0.6
## 掉落初速度(px/s)与相对玩家的生成偏移。
@export_range(0.0, 3000.0, 1.0) var weapon_drop_speed: float = 400.0
@export_range(0.0, 3000.0, 1.0) var weapon_drop_up: float = 220.0
@export var weapon_drop_offset: Vector2 = Vector2(24.0, -8.0)
## 地面摩擦 / 空中阻力(指数)/ 下落重力 / 停住阈值。
@export_range(0.0, 100.0, 0.1) var weapon_ground_friction: float = 12.0
@export_range(0.0, 10.0, 0.01) var weapon_air_drag: float = 0.4
@export_range(0.0, 6000.0, 1.0) var weapon_fall_gravity: float = 1600.0
@export_range(0.0, 100.0, 0.1) var weapon_stop_eps: float = 6.0
## 自己丢下的武器重新可拾取的延迟(秒)。
@export_range(0.0, 5.0, 0.01) var weapon_pickup_self_delay: float = 0.5

@export_group("补间形变")
## squash & stretch(实现见 scenes/effects/squash_stretch.gd):上限 0.06 = 满冲击时最少 0.94 / 最多 1.06。
@export_range(0.0, 0.5, 0.001) var squash_amount: float = 0.06
@export_range(0.0, 48.0, 0.01) var squash_recover: float = 16.0
@export_range(0.0, 3.0, 0.01) var squash_jump: float = 0.75
## 落地形变按竖直速度插值:低于 min 不形变,高于 ref 取满。
@export_range(0.0, 660.0, 1.0) var squash_land_min_vy: float = 220.0
@export_range(0.0, 2700.0, 1.0) var squash_land_ref_vy: float = 900.0
@export_range(0.0, 3.0, 0.01) var squash_land: float = 1.00
@export_range(0.0, 3.0, 0.01) var squash_hurt: float = 0.50
@export_range(0.0, 3.0, 0.01) var squash_dash: float = 0.80
@export_range(0.0, 1.0, 0.01) var squash_air: float = 0.10
@export_range(0.0, 2100.0, 1.0) var squash_air_ref_vy: float = 700.0
