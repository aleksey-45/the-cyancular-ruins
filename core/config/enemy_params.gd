class_name EnemyParams
extends RefCounted

class shared:
	const hit_flash: float = 0.1
	const death_flash_time: float = 0.5
	const turn_min_interval: float = 0.5
	const bird_swim_speed: float = 260.0
	const bird_buoyancy_k: float = 6.0
	const bird_max_float: float = 260.0
	const bird_max_sink: float = 160.0
	const bird_water_damp: float = 5.0
	const drown_interval: float = 1.5
	const drown_damage: int = 5

	const squash_amount: float = 0.06
	const squash_recover: float = 16.0
	const squash_take_off: float = 0.80
	const squash_charge: float = 0.90
	const squash_land_min_vy: float = 220.0
	const squash_land_ref_vy: float = 900.0
	const squash_land: float = 1.00
	const squash_hurt: float = 0.50
	const squash_air: float = 0.10
	const squash_air_ref_vy: float = 700.0

class JumpBird:
	const wake_radius: float = 900.0
	const give_up_radius: float = 1100.0
	const lunge_range: float = 400.0
	const lunge_max_dist: float = 450.0
	const lunge_speed: float = 1100.0
	const lunge_windup: float = 0.30
	const hop_interval: float = 0.55
	const hop_horizontal_speed: float = 240.0
	const hop_jump_velocity: float = -750.0
	const back_hop_up: float = -520.0
	const back_hop_away: float = 320.0

class FlyBird:
	const wake_radius: float = 1100.0
	const max_chase_distance: float = 2000.0
	const home_range: float = 2000.0
	const hover_altitude: float = 40.0
	const hover_offset_x: float = 260.0
	const hover_offset_y: float = 240.0
	const fly_speed: float = 320.0
	const take_off_speed: float = 750.0
	const take_off_time: float = 0.5
	const shoot_range: float = 800.0
	const shoot_reacquire_margin: float = 160.0
	const shoot_position_radius: float = 120.0
	const shoot_cooldown: float = 1.6
	const strafe_range: float = 180.0
	const strafe_duration: float = 0.3
	const bullet_damage: int = 2
	const bullet_range: float = 2000.0
	const bullet_gravity: float = 0.85
	const bullet_size: float = 1.2
	const bullet_min_speed: float = 312.5
	const bullet_max_speed: float = 2000.0
	const bullet_min_drop: float = 30.0
	const charge_hp_fraction: float = 0.25
	const charge_range: float = 1300.0
	const charge_speed: float = 1000.0
	const charge_timeout: float = 2.5
	const charge_damage: int = 5
	const charge_impact: float = 1500.0
	const charge_impact_up: float = 500.0
	const shoot_recoil: float = 500.0
	const repath_interval: float = 0.75
	const arrival_radius: float = 50.0
	const landing_time: float = 0.4
	const path_max_visit: int = 600
	const search_radius_cells: int = 45
	const escape_search_range: int = 90
	const escape_max_descent: int = 40

class BlackBird:
	const wake_radius: float = 1000.0
	const sleep_radius: float = 1200.0
	const wander_speed: float = 300.0
	const wander_min_t: float = 1.0
	const wander_max_t: float = 3.0
	const wander_idle_max: float = 1.5
	const wander_jump_velocity: float = -500.0
	const take_off_jump_velocity: float = -1000.0
	const flank_check_interval: float = 1.0
	const teleport_min_tiles: int = 2
	const teleport_max_tiles: int = 6
	const teleport_drop: float = 250.0
	const landing_timeout: float = 0.3
	const teleport_prep_time: float = 0.25
	const charge_prep_time: float = 0.4
	const teleport_cooldown: float = 3.0
	const teleport_flash_time: float = 0.1
	const charge_speed: float = 900.0
	const charge_damage: int = 7
	const charge_impact: float = 1500.0
	const charge_impact_up: float = 500.0
	const charge_timeout: float = 2.5
	const charge_jump_velocity: float = -650.0
	const back_hop_up: float = -500.0
	const back_hop_away: float = 800.0
