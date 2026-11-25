class_name EnemyParams
extends RefCounted

# 通过现有的敌人参数接口读取 enemy_config.tres 中的数值。
const _CFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

class shared:
	static var hit_reaction_time: float = _CFG.shared_hit_reaction_time
	static var corpse_time: float = _CFG.shared_corpse_time
	static var turn_min_interval: float = _CFG.shared_turn_min_interval
	static var bird_swim_speed: float = _CFG.shared_bird_swim_speed
	static var bird_buoyancy_k: float = _CFG.shared_bird_buoyancy_k
	static var bird_max_float: float = _CFG.shared_bird_max_float
	static var bird_max_sink: float = _CFG.shared_bird_max_sink
	static var bird_water_damp: float = _CFG.shared_bird_water_damp
	static var drown_interval: float = _CFG.shared_drown_interval
	static var drown_damage: int = _CFG.shared_drown_damage

class JumpBird:
	static var wake_radius: float = _CFG.jump_bird_wake_radius
	static var wake_time: float = _CFG.jump_bird_wake_time
	static var settle_time: float = _CFG.jump_bird_settle_time
	static var give_up_radius: float = _CFG.jump_bird_give_up_radius
	static var lunge_range: float = _CFG.jump_bird_lunge_range
	static var lunge_max_dist: float = _CFG.jump_bird_lunge_max_dist
	static var lunge_speed: float = _CFG.jump_bird_lunge_speed
	static var lunge_windup: float = _CFG.jump_bird_lunge_windup
	static var hop_interval: float = _CFG.jump_bird_hop_interval
	static var hop_horizontal_speed: float = _CFG.jump_bird_hop_horizontal_speed
	static var hop_jump_velocity: float = _CFG.jump_bird_hop_jump_velocity
	static var back_hop_up: float = _CFG.jump_bird_back_hop_up
	static var back_hop_away: float = _CFG.jump_bird_back_hop_away

class FlyBird:
	static var wake_radius: float = _CFG.fly_bird_wake_radius
	static var wake_time: float = _CFG.fly_bird_wake_time
	static var settle_time: float = _CFG.fly_bird_settle_time
	static var max_chase_distance: float = _CFG.fly_bird_max_chase_distance
	static var home_range: float = _CFG.fly_bird_home_range
	static var hover_altitude: float = _CFG.fly_bird_hover_altitude
	static var hover_offset_x: float = _CFG.fly_bird_hover_offset_x
	static var hover_offset_y: float = _CFG.fly_bird_hover_offset_y
	static var fly_speed: float = _CFG.fly_bird_fly_speed
	static var take_off_speed: float = _CFG.fly_bird_take_off_speed
	static var take_off_time: float = _CFG.fly_bird_take_off_time
	static var shoot_range: float = _CFG.fly_bird_shoot_range
	static var shoot_reacquire_margin: float = _CFG.fly_bird_shoot_reacquire_margin
	static var shoot_position_radius: float = _CFG.fly_bird_shoot_position_radius
	static var shoot_cooldown: float = _CFG.fly_bird_shoot_cooldown
	static var strafe_range: float = _CFG.fly_bird_strafe_range
	static var strafe_duration: float = _CFG.fly_bird_strafe_duration
	static var bullet_damage: int = _CFG.fly_bird_bullet_damage
	static var bullet_range: float = _CFG.fly_bird_bullet_range
	static var bullet_gravity: float = _CFG.fly_bird_bullet_gravity
	static var bullet_size: float = _CFG.fly_bird_bullet_size
	static var bullet_min_speed: float = _CFG.fly_bird_bullet_min_speed
	static var bullet_max_speed: float = _CFG.fly_bird_bullet_max_speed
	static var bullet_min_drop: float = _CFG.fly_bird_bullet_min_drop
	static var charge_hp_fraction: float = _CFG.fly_bird_charge_hp_fraction
	static var charge_range: float = _CFG.fly_bird_charge_range
	static var charge_speed: float = _CFG.fly_bird_charge_speed
	static var charge_timeout: float = _CFG.fly_bird_charge_timeout
	static var charge_damage: int = _CFG.fly_bird_charge_damage
	static var charge_impact: float = _CFG.fly_bird_charge_impact
	static var charge_impact_up: float = _CFG.fly_bird_charge_impact_up
	static var shoot_recoil: float = _CFG.fly_bird_shoot_recoil
	static var repath_interval: float = _CFG.fly_bird_repath_interval
	static var arrival_radius: float = _CFG.fly_bird_arrival_radius
	static var landing_time: float = _CFG.fly_bird_landing_time
	static var path_max_visit: int = _CFG.fly_bird_path_max_visit
	static var search_radius_cells: int = _CFG.fly_bird_search_radius_cells
	static var escape_search_range: int = _CFG.fly_bird_escape_search_range
	static var escape_max_descent: int = _CFG.fly_bird_escape_max_descent

class BlackBird:
	static var wake_radius: float = _CFG.black_bird_wake_radius
	static var wake_time: float = _CFG.black_bird_wake_time
	static var settle_time: float = _CFG.black_bird_settle_time
	static var sleep_radius: float = _CFG.black_bird_sleep_radius
	static var wander_speed: float = _CFG.black_bird_wander_speed
	static var wander_min_t: float = _CFG.black_bird_wander_min_t
	static var wander_max_t: float = _CFG.black_bird_wander_max_t
	static var wander_idle_max: float = _CFG.black_bird_wander_idle_max
	static var wander_jump_velocity: float = _CFG.black_bird_wander_jump_velocity
	static var take_off_jump_velocity: float = _CFG.black_bird_take_off_jump_velocity
	static var flank_check_interval: float = _CFG.black_bird_flank_check_interval
	static var teleport_min_range: float = _CFG.black_bird_teleport_min_range
	static var teleport_max_range: float = _CFG.black_bird_teleport_max_range
	static var teleport_drop: float = _CFG.black_bird_teleport_drop
	static var landing_timeout: float = _CFG.black_bird_landing_timeout
	static var teleport_prep_time: float = _CFG.black_bird_teleport_prep_time
	static var teleport_entry_time: float = _CFG.black_bird_teleport_entry_time
	static var teleport_hover_time: float = _CFG.black_bird_teleport_hover_time
	static var charge_prep_time: float = _CFG.black_bird_charge_prep_time
	static var teleport_cooldown: float = _CFG.black_bird_teleport_cooldown
	static var charge_speed: float = _CFG.black_bird_charge_speed
	static var charge_damage: int = _CFG.black_bird_charge_damage
	static var charge_impact: float = _CFG.black_bird_charge_impact
	static var charge_impact_up: float = _CFG.black_bird_charge_impact_up
	static var charge_timeout: float = _CFG.black_bird_charge_timeout
	static var charge_jump_velocity: float = _CFG.black_bird_charge_jump_velocity
	static var back_hop_up: float = _CFG.black_bird_back_hop_up
	static var back_hop_away: float = _CFG.black_bird_back_hop_away
