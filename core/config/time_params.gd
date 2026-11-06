class_name TimeParams
extends RefCounted

# 个人钟·第一阶段(v0.5.0)参数总表 —— 主策划案 §2.1「时间颗粒」经济的代码单一来源。

const GRAIN_INITIAL := 1000
const GRAIN_CAP := 5000
const SHORT_WINDOW := 400.0
const SHORT_REGEN := 50.0
const LOAN_LIMIT := 100.0

const COST_REWIND := 120.0
const COST_HASTE := 80.0

const SNAP_HZ := 20
const SNAP_SECONDS := 40.0
const REWIND_START_MULT := 3.0
const REWIND_RAMP_TIME := 0.35

const HASTE_PLAYER := 2.0
const HASTE_WORLD := 0.5

const LOAN_ENEMY_SPEED_BONUS := 0.5
const LOAN_PITCH_RANGE := 0.5
const LOAN_BRIGHT_RANGE := 0.35
const LOAN_ABERRATION_PX := 5.0

const ELITE_GRAIN_DROP := 300
