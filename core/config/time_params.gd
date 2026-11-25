class_name TimeParams
extends RefCounted

# 通过现有的单人时间技能接口读取 time_config.tres 中的数值。
const _CFG: TimeConfig = preload("res://core/config/time_config.tres")

static var GRAIN_INITIAL: int = _CFG.GRAIN_INITIAL
static var GRAIN_CAP: int = _CFG.GRAIN_CAP
static var SHORT_WINDOW: float = _CFG.SHORT_WINDOW
static var SHORT_REGEN: float = _CFG.SHORT_REGEN
static var LOAN_LIMIT: float = _CFG.LOAN_LIMIT
static var COST_REWIND: float = _CFG.COST_REWIND
static var COST_HASTE: float = _CFG.COST_HASTE
static var SNAP_HZ: int = _CFG.SNAP_HZ
static var SNAP_SECONDS: float = _CFG.SNAP_SECONDS
static var REWIND_START_MULT: float = _CFG.REWIND_START_MULT
static var REWIND_RAMP_TIME: float = _CFG.REWIND_RAMP_TIME
static var HASTE_PLAYER: float = _CFG.HASTE_PLAYER
static var HASTE_WORLD: float = _CFG.HASTE_WORLD
static var LOAN_ENEMY_SPEED_BONUS: float = _CFG.LOAN_ENEMY_SPEED_BONUS
static var LOAN_PITCH_RANGE: float = _CFG.LOAN_PITCH_RANGE
static var ELITE_GRAIN_DROP: int = _CFG.ELITE_GRAIN_DROP
static var ELITE_GRAIN_DELAY_TICKS: int = _CFG.ELITE_GRAIN_DELAY_TICKS
static var SNAP_INTERVAL: float = 1.0 / maxf(float(_CFG.SNAP_HZ), 1.0)

static func rewind_delta(rewound: float, delta: float) -> float:
	var ramp := clampf(rewound / REWIND_RAMP_TIME, 0.0, 1.0)
	return delta * lerpf(REWIND_START_MULT, 1.0, ramp)
