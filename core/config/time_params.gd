class_name TimeParams
extends RefCounted

# 单机时间玩法参数的访问入口。★ 数值不在本文件:唯一真相源是 core/config/time_config.tres。
# 为什么不是逐次 getter→Resource:实测每次读比 const 慢 13.8×,这批值在 TimeField 各查询口被读
# ⇒ 改为类加载时读一次(static var = _CFG.x);代价是改 .tres 后要重启进程生效。
# ★ const _CFG := preload(...):缺文件 / 坏文件是加载期硬失败,不会静默退化成 0。

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
static var LOAN_BRIGHT_RANGE: float = _CFG.LOAN_BRIGHT_RANGE
static var LOAN_ABERRATION_PX: float = _CFG.LOAN_ABERRATION_PX

static var ELITE_GRAIN_DROP: int = _CFG.ELITE_GRAIN_DROP
