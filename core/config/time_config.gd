class_name TimeConfig
extends Resource

# 单人时间玩法参数表：schema + 默认值；运行时读 time_config.tres。
# 由上游 TimeParams 常量迁入，数值保持上游 siri 行为。

@export var GRAIN_INITIAL: int = 1000
@export var GRAIN_CAP: int = 5000
@export var SHORT_WINDOW: float = 400.0
@export var SHORT_REGEN: float = 50.0
@export var LOAN_LIMIT: float = 100.0
@export var COST_REWIND: float = 120.0
@export var COST_HASTE: float = 80.0
@export var SNAP_HZ: int = 20
@export var SNAP_SECONDS: float = 40.0
@export var REWIND_START_MULT: float = 3.0
@export var REWIND_RAMP_TIME: float = 0.35
@export var HASTE_PLAYER: float = 2.0
@export var HASTE_WORLD: float = 0.5
@export var LOAN_ENEMY_SPEED_BONUS: float = 0.5
@export var LOAN_PITCH_RANGE: float = 0.5
@export var ELITE_GRAIN_DROP: int = 300
@export var ELITE_GRAIN_DELAY_TICKS: int = 36
