class_name PlayerConfig
extends Resource

# 玩家参数表：schema + 默认值；运行时读 player_config.tres。
# 由上游 PlayerParams 常量迁入，数值保持上游 siri 行为。

@export var body_scale: float = 2.5
@export var standing_hull: Rect2 = Rect2(-18, -20, 32, 42.8)
@export var crouched_hull: Rect2 = Rect2(-18, -14, 32, 36.8)
@export var move_speed: float = 700.0
@export var accel_ground: float = 30.0
@export var accel_air: float = 9.0
@export var brake_ground: float = 16.0
@export var brake_air: float = 6.0
@export var stop_snap: float = 1.0
@export var jump_velocity: float = -1000.0
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.12
@export var jump_cut_factor: float = 0.5
@export var crouch_walk_speed: float = 245.0
@export var charge_down_velocity: float = 2000.0
@export var charge_velocity: float = 3000.0
@export var charge_distance: float = 256.0
@export var charge_air_gravity_mult: float = 0.35
@export var player_swim_speed: float = 540.0
@export var player_swim_up: float = -400.0
@export var player_swim_down: float = 320.0
@export var player_swim_accel: float = 6.0
@export var player_waterproof_max: int = 10
@export var player_waterproof_damage: int = 5
@export var cam_lead_x: float = 100.0
@export var cam_y_bias: float = -100.0
@export var cam_smooth_x: float = 10.0
@export var cam_smooth_y: float = 8.0
@export var cam_deadzone: float = 8.0
@export var cam_zoom: float = 1.0
@export var cam_seam_margin: float = 512.0
@export var climb_speed: float = 300.0
@export var climb_vertical_mult: float = 1.2
@export var climb_recoil_mult: float = 0.1
@export var climb_foot_offset: float = 57.0
@export var elastic_bounce: float = 150.0
@export var step_max_height: float = 64.0
@export var player_max_hp: int = 50
@export var iframes_time: float = 0.25
@export var player_hit_knockback: float = 400.0
@export var player_hit_knockback_up: float = 200.0
@export var player_knock_decay_rate: float = 10.0
@export var hit_cam_shake: float = 8.0
@export var hit_cam_shake_time: float = 0.25
@export var explosion_cam_shake: float = 30.0
@export var explosion_cam_shake_time: float = 0.5
@export var weapon_pickup_radius: float = 64.0
@export var weapon_drop_hold_time: float = 0.6
@export var weapon_drop_speed: float = 400.0
@export var weapon_drop_up: float = 220.0
@export var weapon_drop_offset: Vector2 = Vector2(24.0, -8.0)
@export var weapon_ground_friction: float = 12.0
@export var weapon_air_drag: float = 0.4
@export var weapon_fall_gravity: float = 1600.0
@export var weapon_stop_eps: float = 6.0
@export var weapon_pickup_self_delay: float = 0.5
