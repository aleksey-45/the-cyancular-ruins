class_name PlayerConfig
extends Resource

# 玩家调参值见 player_config.tres。

@export var body_scale: float
@export var standing_hull: Rect2
@export var crouched_hull: Rect2
@export var move_speed: float
@export var accel_ground: float
@export var accel_air: float
@export var brake_ground: float
@export var brake_air: float
@export var stop_snap: float
@export var jump_velocity: float
@export var coyote_time: float
@export var jump_buffer_time: float
@export var jump_cut_factor: float
@export var crouch_walk_speed: float
@export var charge_down_velocity: float
@export var charge_velocity: float
@export var charge_distance: float
@export var charge_air_gravity_mult: float
@export var player_swim_speed: float
@export var player_swim_up: float
@export var player_swim_down: float
@export var player_swim_accel: float
@export var player_waterproof_max: int
@export var player_waterproof_damage: int
@export var cam_lead_x: float
@export var cam_y_bias: float
@export var cam_smooth_x: float
@export var cam_smooth_y: float
@export var cam_deadzone: float
@export var cam_zoom: float
@export var cam_seam_margin: float
@export var climb_speed: float
@export var climb_vertical_mult: float
@export var climb_recoil_mult: float
@export var climb_foot_offset: float
@export var elastic_bounce: float
@export var step_max_cells: int
@export var step_walk_cells: int
@export var air_ledge_cells: int
@export var player_max_hp: int
@export var iframes_time: float
@export var player_hit_knockback: float
@export var player_hit_knockback_up: float
@export var player_knock_decay_rate: float
@export var hit_cam_shake: float
@export var hit_cam_shake_time: float
@export var explosion_cam_shake: float
@export var explosion_cam_shake_time: float
@export var weapon_pickup_radius: float
@export var weapon_drop_hold_time: float
@export var weapon_drop_speed: float
@export var weapon_drop_up: float
@export var weapon_drop_offset: Vector2
@export var weapon_ground_friction: float
@export var weapon_air_drag: float
@export var weapon_fall_gravity: float
@export var weapon_stop_eps: float
@export var weapon_pickup_self_delay: float

# 挤压与拉伸参数见 core/present/squash_tracker.gd。
# squash_amount 控制最大形变比例，0.06 对应 0.94 至 1.06 倍缩放。
# squash_recover 控制动作形变的指数衰减速率。
@export var squash_amount: float
@export var squash_recover: float
@export var squash_jump: float
# 落地时按竖直速度插值。低于最小速度时不触发，达到参考速度后使用最大强度。
@export var squash_land_min_vy: float
@export var squash_land_ref_vy: float
@export var squash_land: float
@export var squash_hurt: float
@export var squash_dash: float
@export var squash_air: float
@export var squash_air_ref_vy: float
