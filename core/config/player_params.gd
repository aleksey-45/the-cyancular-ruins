class_name PlayerParams
extends RefCounted

# 玩家参数的**访问入口**:数值在 `core/config/player_config.tres`,这里只做转发。
# 访问写法完全不变:`PlayerParams.move_speed`(全部调用点零改动)。
#
# ★ 为什么是"static var = _CFG.x"而不是 getter:实测 getter→Resource 每次读比 const 慢 13.8×
#   (200 万次 319ms vs 23ms),而这些值在 player.gd / camera_2d.gd 里**每帧**读
#   (player.gd 单文件 25 处)。类加载时读一次后成本与 const 同数量级。
#   代价:改 .tres 要重启进程生效(与 world_config / enemy_config 同一口径)。
# ★ `const _CFG := preload(...)`:仓库里 .tres 缺文件/坏文件是**加载期硬失败**,
#   不会静默退化成 0(那会让移速变 0、跳跃失效,而且没人报错)。
# ★ 派生值 `charge_duration` 不抄进 .tres:由 charge_distance / charge_velocity 在类加载时算一次;
#   必须声明在这两者**之后** —— static var 按声明顺序初始化。

const _CFG: PlayerConfig = preload("res://core/config/player_config.tres")

# ── 移动 / 跳跃 ──
static var move_speed: float = _CFG.move_speed
static var accel_ground: float = _CFG.accel_ground
static var accel_air: float = _CFG.accel_air
static var brake_ground: float = _CFG.brake_ground
static var brake_air: float = _CFG.brake_air
# 水平速度低于此值直接归零(避免贴地滑行 / 极慢速抖动)。★ 移动手感数值的唯一去向就是
# `core/config/player_config.tres`,别再抄第三份。
static var stop_snap: float = _CFG.stop_snap

static var jump_velocity: float = _CFG.jump_velocity
static var coyote_time: float = _CFG.coyote_time
static var jump_buffer_time: float = _CFG.jump_buffer_time
static var jump_cut_factor: float = _CFG.jump_cut_factor

static var crouch_walk_speed: float = _CFG.crouch_walk_speed

# ── 冲刺 ──
static var charge_down_velocity: float = _CFG.charge_down_velocity
static var charge_distance: float = _CFG.charge_distance
static var charge_velocity: float = _CFG.charge_velocity
# 派生值:冲刺持续时间(秒)。★ 声明顺序 = 初始化顺序,必须待在上面两个之后。
static var charge_duration: float = charge_distance / charge_velocity
static var charge_air_gravity_mult: float = _CFG.charge_air_gravity_mult
static var charge_dir_window: float = _CFG.charge_dir_window

# ── 游泳 ──
static var player_swim_speed: float = _CFG.player_swim_speed
static var player_swim_up: float = _CFG.player_swim_up
static var player_swim_down: float = _CFG.player_swim_down
static var player_swim_accel: float = _CFG.player_swim_accel
static var player_waterproof_max: int = _CFG.player_waterproof_max
static var player_waterproof_damage: int = _CFG.player_waterproof_damage

# ── 相机 ──
static var cam_lookahead_x: float = _CFG.cam_lookahead_x
static var cam_lookahead_y: float = _CFG.cam_lookahead_y
static var cam_y_bias: float = _CFG.cam_y_bias
static var cam_smooth_x: float = _CFG.cam_smooth_x
static var cam_smooth_y: float = _CFG.cam_smooth_y
static var cam_deadzone: Vector2 = _CFG.cam_deadzone
static var cam_zoom: float = _CFG.cam_zoom

# ── 攀爬 / 弹跳 ──
static var climb_ladder_up_speed: float = _CFG.climb_ladder_up_speed
static var climb_ladder_down_speed: float = _CFG.climb_ladder_down_speed
static var climb_chain_up_speed: float = _CFG.climb_chain_up_speed
static var elastic_bounce: float = _CFG.elastic_bounce

# ── 生命 / 受击 ──
static var player_max_hp: int = _CFG.player_max_hp
static var iframes_time: float = _CFG.iframes_time
static var player_hit_knockback: float = _CFG.player_hit_knockback
static var player_hit_knockback_up: float = _CFG.player_hit_knockback_up
static var player_knock_decay_rate: float = _CFG.player_knock_decay_rate
static var hit_cam_shake: float = _CFG.hit_cam_shake
static var hit_cam_shake_time: float = _CFG.hit_cam_shake_time

# ── 爆炸 ──
static var explosion_cam_shake: float = _CFG.explosion_cam_shake
static var explosion_cam_shake_time: float = _CFG.explosion_cam_shake_time

# ── 武器拾取 / 掉落 ──
static var weapon_pickup_radius: float = _CFG.weapon_pickup_radius
static var weapon_drop_hold_time: float = _CFG.weapon_drop_hold_time
static var weapon_drop_speed: float = _CFG.weapon_drop_speed
static var weapon_drop_up: float = _CFG.weapon_drop_up
static var weapon_drop_offset: Vector2 = _CFG.weapon_drop_offset
static var weapon_ground_friction: float = _CFG.weapon_ground_friction
static var weapon_air_drag: float = _CFG.weapon_air_drag
static var weapon_fall_gravity: float = _CFG.weapon_fall_gravity
static var weapon_stop_eps: float = _CFG.weapon_stop_eps
static var weapon_pickup_self_delay: float = _CFG.weapon_pickup_self_delay

# ── 补间形变 ──
# squash & stretch(实现见 scenes/effects/squash_stretch.gd):上限 0.06 = 满冲击时最少 0.94 / 最多 1.06,
static var squash_amount: float = _CFG.squash_amount
static var squash_recover: float = _CFG.squash_recover
static var squash_jump: float = _CFG.squash_jump
static var squash_land_min_vy: float = _CFG.squash_land_min_vy
static var squash_land_ref_vy: float = _CFG.squash_land_ref_vy
static var squash_land: float = _CFG.squash_land
static var squash_hurt: float = _CFG.squash_hurt
static var squash_dash: float = _CFG.squash_dash
static var squash_air: float = _CFG.squash_air
static var squash_air_ref_vy: float = _CFG.squash_air_ref_vy
