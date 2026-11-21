class_name EnemyConfig
extends Resource
# 敌人参数表:**只有 schema 和默认值**,真正生效的数值在 `enemy_config.tres`。
#
# ★ 为什么字段是"扁平 + 前缀"(shared_/jump_bird_/fly_bird_/black_bird_)而不是 4 个子 Resource:
#   GDScript 的**内层类不能当 @export 类型**(实测 Parse Error: Export type can only be built-in,
#   a resource, a node, or an enum)⇒ 想保住 `EnemyParams.FlyBird.wake_radius` 这个访问写法,
#   数据只能平铺在同一个 Resource 里,由 enemy_params.gd 的内层类转回分层命名。
#
# ★ .gd 默认值 = 新建实例时的起点;运行时永远读 .tres(由 EnemyParams 以 const preload 引入
#   ⇒ 缺文件是加载期硬失败,不会静默退化成 0)。

@export_group("通用(三只鸟共用)")
## 受击白闪 / 转向 / 落水 / 补间形变
@export_range(0.00, 1.00, 0.01) var shared_hit_flash: float = 0.1
@export_range(0.00, 3.00, 0.01) var shared_death_flash_time: float = 0.5
@export_range(0.00, 3.00, 0.01) var shared_turn_min_interval: float = 0.5
@export_range(0.00, 780.00, 1.0) var shared_bird_swim_speed: float = 260.0
@export_range(0.00, 18.00, 0.01) var shared_bird_buoyancy_k: float = 6.0
@export_range(0.00, 780.00, 1.0) var shared_bird_max_float: float = 260.0
@export_range(0.00, 480.00, 1.0) var shared_bird_max_sink: float = 160.0
@export_range(0.00, 15.00, 0.01) var shared_bird_water_damp: float = 5.0
@export_range(0.10, 10.00, 0.01) var shared_drown_interval: float = 1.5
@export_range(0, 30, 1) var shared_drown_damage: int = 5
@export_range(0.00, 0.50, 0.001) var shared_squash_amount: float = 0.06
@export_range(0.00, 48.00, 0.01) var shared_squash_recover: float = 16.0
@export_range(0.00, 3.00, 0.01) var shared_squash_take_off: float = 0.80
@export_range(0.00, 3.00, 0.01) var shared_squash_charge: float = 0.90
@export_range(0.00, 660.00, 1.0) var shared_squash_land_min_vy: float = 220.0
@export_range(0.00, 2700.00, 1.0) var shared_squash_land_ref_vy: float = 900.0
@export_range(0.00, 3.00, 0.01) var shared_squash_land: float = 1.00
@export_range(0.00, 3.00, 0.01) var shared_squash_hurt: float = 0.50
@export_range(0.00, 1.00, 0.01) var shared_squash_air: float = 0.10
@export_range(0.00, 2100.00, 1.0) var shared_squash_air_ref_vy: float = 700.0

@export_group("JumpBird")
## 地走鸟:扑击 / 小跳 / 后跳
@export_range(0.0, 3000.0, 1.0) var jump_bird_wake_radius: float = 900.0
@export_range(0.0, 4000.0, 1.0) var jump_bird_give_up_radius: float = 1100.0
@export_range(0.0, 2000.0, 1.0) var jump_bird_lunge_range: float = 400.0
@export_range(0.0, 2000.0, 1.0) var jump_bird_lunge_max_dist: float = 450.0
@export_range(0.0, 4000.0, 1.0) var jump_bird_lunge_speed: float = 1100.0
@export_range(0.00, 2.00, 0.01) var jump_bird_lunge_windup: float = 0.30
@export_range(0.05, 3.00, 0.01) var jump_bird_hop_interval: float = 0.55
@export_range(0.0, 1500.0, 1.0) var jump_bird_hop_horizontal_speed: float = 240.0
@export_range(-3000.0, 0.0, 1.0) var jump_bird_hop_jump_velocity: float = -750.0
@export_range(-3000.0, 0.0, 1.0) var jump_bird_back_hop_up: float = -520.0
@export_range(0.0, 2000.0, 1.0) var jump_bird_back_hop_away: float = 320.0

@export_group("FlyBird")
## 飞鸟:悬停追击 / 投弹 / 冲撞
@export_range(0.0, 4000.0, 1.0) var fly_bird_wake_radius: float = 1100.0
@export_range(0.0, 6000.0, 1.0) var fly_bird_max_chase_distance: float = 2000.0
@export_range(0.0, 6000.0, 1.0) var fly_bird_home_range: float = 2000.0
@export_range(0.0, 500.0, 1.0) var fly_bird_hover_altitude: float = 40.0
@export_range(0.0, 1000.0, 1.0) var fly_bird_hover_offset_x: float = 260.0
@export_range(0.0, 1000.0, 1.0) var fly_bird_hover_offset_y: float = 240.0
@export_range(0.0, 2000.0, 1.0) var fly_bird_fly_speed: float = 320.0
@export_range(0.0, 3000.0, 1.0) var fly_bird_take_off_speed: float = 750.0
@export_range(0.00, 3.00, 0.01) var fly_bird_take_off_time: float = 0.5
@export_range(0.0, 3000.0, 1.0) var fly_bird_shoot_range: float = 800.0
@export_range(0.0, 1000.0, 1.0) var fly_bird_shoot_reacquire_margin: float = 160.0
@export_range(0.0, 800.0, 1.0) var fly_bird_shoot_position_radius: float = 120.0
@export_range(0.05, 8.00, 0.01) var fly_bird_shoot_cooldown: float = 1.6
@export_range(0.0, 1000.0, 1.0) var fly_bird_strafe_range: float = 180.0
@export_range(0.00, 2.00, 0.01) var fly_bird_strafe_duration: float = 0.3
@export_range(0, 18, 1) var fly_bird_bullet_damage: int = 2
@export_range(0.0, 6000.0, 1.0) var fly_bird_bullet_range: float = 2000.0
@export_range(0.00, 3.00, 0.01) var fly_bird_bullet_gravity: float = 0.85
@export_range(0.20, 5.00, 0.01) var fly_bird_bullet_size: float = 1.2
@export_range(0.0, 3000.0, 0.5) var fly_bird_bullet_min_speed: float = 312.5
@export_range(0.0, 5000.0, 1.0) var fly_bird_bullet_max_speed: float = 2000.0
@export_range(0.0, 500.0, 1.0) var fly_bird_bullet_min_drop: float = 30.0
@export_range(0.00, 1.00, 0.01) var fly_bird_charge_hp_fraction: float = 0.25
@export_range(0.0, 4000.0, 1.0) var fly_bird_charge_range: float = 1300.0
@export_range(0.0, 3000.0, 1.0) var fly_bird_charge_speed: float = 1000.0
@export_range(0.10, 10.00, 0.01) var fly_bird_charge_timeout: float = 2.5
@export_range(0, 30, 1) var fly_bird_charge_damage: int = 5
@export_range(0.0, 5000.0, 1.0) var fly_bird_charge_impact: float = 1500.0
@export_range(0.0, 3000.0, 1.0) var fly_bird_charge_impact_up: float = 500.0
@export_range(0.0, 2000.0, 1.0) var fly_bird_shoot_recoil: float = 500.0
@export_range(0.05, 5.00, 0.01) var fly_bird_repath_interval: float = 0.75
@export_range(0.0, 300.0, 1.0) var fly_bird_arrival_radius: float = 50.0
@export_range(0.00, 3.00, 0.01) var fly_bird_landing_time: float = 0.4
@export_range(0, 2410, 1) var fly_bird_path_max_visit: int = 600
@export_range(0, 190, 1) var fly_bird_search_radius_cells: int = 45
@export_range(0, 370, 1) var fly_bird_escape_search_range: int = 90
@export_range(0, 170, 1) var fly_bird_escape_max_descent: int = 40

@export_group("BlackBird")
## 黑鸟(精英):游走 / 瞬移 / 冲锋
@export_range(0.0, 4000.0, 1.0) var black_bird_wake_radius: float = 1000.0
@export_range(0.0, 4000.0, 1.0) var black_bird_sleep_radius: float = 1200.0
@export_range(0.0, 1500.0, 1.0) var black_bird_wander_speed: float = 300.0
@export_range(0.00, 10.00, 0.01) var black_bird_wander_min_t: float = 1.0
@export_range(0.00, 10.00, 0.01) var black_bird_wander_max_t: float = 3.0
@export_range(0.00, 5.00, 0.01) var black_bird_wander_idle_max: float = 1.5
@export_range(-3000.0, 0.0, 1.0) var black_bird_wander_jump_velocity: float = -500.0
@export_range(-4000.0, 0.0, 1.0) var black_bird_take_off_jump_velocity: float = -1000.0
@export_range(0.05, 10.00, 0.01) var black_bird_flank_check_interval: float = 1.0
@export_range(0, 18, 1) var black_bird_teleport_min_tiles: int = 2
@export_range(0, 34, 1) var black_bird_teleport_max_tiles: int = 6
@export_range(0.0, 2000.0, 1.0) var black_bird_teleport_drop: float = 250.0
@export_range(0.00, 3.00, 0.01) var black_bird_landing_timeout: float = 0.3
@export_range(0.00, 2.00, 0.01) var black_bird_teleport_prep_time: float = 0.25
@export_range(0.00, 3.00, 0.01) var black_bird_charge_prep_time: float = 0.4
@export_range(0.00, 15.00, 0.01) var black_bird_teleport_cooldown: float = 3.0
@export_range(0.00, 1.00, 0.01) var black_bird_teleport_flash_time: float = 0.1
@export_range(0.0, 3000.0, 1.0) var black_bird_charge_speed: float = 900.0
@export_range(0, 38, 1) var black_bird_charge_damage: int = 7
@export_range(0.0, 5000.0, 1.0) var black_bird_charge_impact: float = 1500.0
@export_range(0.0, 3000.0, 1.0) var black_bird_charge_impact_up: float = 500.0
@export_range(0.10, 10.00, 0.01) var black_bird_charge_timeout: float = 2.5
@export_range(-3000.0, 0.0, 1.0) var black_bird_charge_jump_velocity: float = -650.0
@export_range(-3000.0, 0.0, 1.0) var black_bird_back_hop_up: float = -500.0
@export_range(0.0, 3000.0, 1.0) var black_bird_back_hop_away: float = 800.0

@export_group("siri 扩展(动画计时)")
@export var jump_bird_wake_time: float = 0.5
@export var jump_bird_settle_time: float = 0.5
@export var fly_bird_wake_time: float = 0.5
@export var fly_bird_settle_time: float = 0.5
@export var black_bird_wake_time: float = 0.625
@export var black_bird_settle_time: float = 0.625
@export var black_bird_teleport_entry_time: float = 0.1
@export var black_bird_teleport_hover_time: float = 0.7
