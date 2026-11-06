class_name PlayerParams
extends RefCounted

const move_speed: float = 700.0
const accel_ground: float = 30.0
const accel_air: float = 9.0
const brake_ground: float = 16.0
const brake_air: float = 6.0
# 水平速度低于此值直接归零(避免贴地滑行 / 极慢速抖动)。★ 移动手感数值的唯一去处就是本文件,别再抄第三份。
const stop_snap: float = 1.0

const jump_velocity: float = -1000.0
const coyote_time: float = 0.1
const jump_buffer_time: float = 0.12
const jump_cut_factor: float = 0.5

const crouch_walk_speed: float = 245.0

const charge_down_velocity: float = 2000.0
const charge_distance: float = 256.0
const charge_velocity: float = 3000.0
const charge_duration: float = charge_distance / charge_velocity
const charge_air_gravity_mult: float = 0.35
const charge_dir_window: float = 0.3

const player_swim_speed: float = 540.0
const player_swim_up: float = -400.0
const player_swim_down: float = 320.0
const player_swim_accel: float = 6.0
const player_waterproof_max: int = 10
const player_waterproof_damage: int = 5

const cam_lookahead_x: float = 100.0
const cam_lookahead_y: float = 80.0
const cam_y_bias: float = -100.0
const cam_smooth_x: float = 10.0
const cam_smooth_y: float = 8.0
const cam_deadzone: float = 32.0
const cam_zoom: float = 0.75

const climb_ladder_up_speed: float = 850.0
const climb_ladder_down_speed: float = 800.0
const climb_chain_up_speed: float = 800.0
const elastic_bounce: float = 150.0

const player_max_hp: int = 50
const iframes_time: float = 0.25
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0
const player_knock_decay_rate: float = 10.0
const hit_cam_shake: float = 8.0
const hit_cam_shake_time: float = 0.25

const explosion_cam_shake: float = 30.0
const explosion_cam_shake_time: float = 0.5

const weapon_pickup_radius: float = 64.0
const weapon_drop_hold_time: float = 0.6
const weapon_drop_speed: float = 400.0
const weapon_drop_up: float = 220.0
const weapon_drop_offset := Vector2(24.0, -8.0)
const weapon_ground_friction: float = 12.0
const weapon_air_drag: float = 0.4
const weapon_fall_gravity: float = 1600.0
const weapon_stop_eps: float = 6.0
const weapon_pickup_self_delay: float = 0.5

# 补间形变(squash & stretch,实现见 scenes/effects/squash_stretch.gd):上限 0.06 = 满冲击时最少 0.94 / 最多 1.06,
const squash_amount: float = 0.06
const squash_recover: float = 16.0
const squash_jump: float = 0.75
const squash_land_min_vy: float = 220.0
const squash_land_ref_vy: float = 900.0
const squash_land: float = 1.00
const squash_hurt: float = 0.50
const squash_dash: float = 0.80
const squash_air: float = 0.10
const squash_air_ref_vy: float = 700.0
