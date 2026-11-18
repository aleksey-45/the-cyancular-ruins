class_name TimeParams
extends RefCounted

# 单人模式在这里设定时间颗粒、玩家的时间技能以及记录游戏状态的频率。

const GRAIN_INITIAL := 1000       # 进入单人关卡时持有的时间颗粒数。
const GRAIN_CAP := 5000           # 余额达到此上限时，怀表的白色短针转满一圈。
const SHORT_WINDOW := 400.0       # 短期消耗达到此上限时，怀表的红色长针转满一圈。
const SHORT_REGEN := 50.0         # 每秒补充的使用额度。若已透支，先偿还欠下的额度。
const LOAN_LIMIT := 100.0         # 短期额度已用完时，可额外透支的时间颗粒数。

const COST_REWIND := 120.0        # 每秒维持时间回溯所需的时间颗粒数。
const COST_HASTE := 80.0          # 每秒维持时间加速所需的时间颗粒数。

const SNAP_HZ := 20               # 游戏每秒为时间回溯保存这么多份状态。
const SNAP_INTERVAL := 1.0 / SNAP_HZ
const SNAP_SECONDS := 40.0        # 可用于回溯的历史状态最多覆盖这么多秒。
const REWIND_START_MULT := 3.0    # 刚进入回溯时，每秒回退的游戏时间与实际时间之比。
const REWIND_RAMP_TIME := 0.35    # 累计回退这么多秒的游戏时间后，回溯速度降至正常速度。

# 时间加速期间，各类物体用以下倍率换算模拟时间。
const HASTE_PLAYER := 2.0         # 适用于玩家、玩家发射的弹丸和精英敌人。
const HASTE_WORLD := 0.5          # 适用于普通敌人、敌方弹丸和地上的武器。

const LOAN_ENEMY_SPEED_BONUS := 0.5    # 普通敌人的时间倍率随透支比例增加。透支用满时，在原倍率上额外增加此比例。
const LOAN_PITCH_RANGE := 0.5          # 透支会提高音效的音高。此值为透支用满时音高倍率的增量。

const ELITE_GRAIN_DROP := 300     # 乌鸫被击败后，玩家获得的时间颗粒数。
const ELITE_GRAIN_DELAY_TICKS := 36

static func rewind_delta(rewound: float, delta: float) -> float:
	var ramp := clampf(rewound / REWIND_RAMP_TIME, 0.0, 1.0)
	return delta * lerpf(REWIND_START_MULT, 1.0, ramp)
