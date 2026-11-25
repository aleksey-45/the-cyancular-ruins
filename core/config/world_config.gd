class_name WorldConfig
extends Resource

# 定义世界重力和水体参数及其默认值。对局使用 world_config.tres 中的数值。

@export var gravity0: float = 1600.0
@export var water_sway_amp: float = 2.0
@export var water_sway_speed: float = 1.6
@export var water_bullet_drag: float = 2.0
@export var water_fx_move_threshold: float = 40.0
@export var water_fx_splash_band: float = 20.0
@export var water_fx_splash_interval: float = 0.15
@export var water_fx_bubble_interval: float = 0.12
@export var water_drain_interval: float = 1.0
@export var water_recover_interval: float = 0.3
@export var water_drown_damage_interval: float = 1.5
@export var water_enter_depth: float = 8.0
@export var water_exit_depth: float = -2.0
