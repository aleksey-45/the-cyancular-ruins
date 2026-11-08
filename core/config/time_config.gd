class_name TimeConfig
extends Resource
# 单机时间玩法参数表:**只有 schema 和默认值**,真正生效的数值在 `time_config.tres`。
#
# ★ 唯一真相源 = `core/config/time_config.tres`(由 `TimeParams` 以 `const` preload 引入 ⇒ 缺文件 / 坏文件是加载期硬失败)。
# `TimeParams` 保留原有 `TimeParams.XXX` 静态访问写法,35 处调用点不用改。

@export_group("颗粒经济")
## 初始颗粒(开局余额)。
@export_range(0, 100000, 1) var GRAIN_INITIAL: int = 1000
## 颗粒额度上限(怀表白短针一圈)。
@export_range(0, 1000000, 1) var GRAIN_CAP: int = 5000
## 短时间额度(红长针一圈)。
@export_range(0.0, 5000.0, 1.0) var SHORT_WINDOW: float = 400.0
## 短时额度恢复速率(颗粒/秒,先还贷后回窗)。
@export_range(0.0, 1000.0, 1.0) var SHORT_REGEN: float = 50.0
## 贷款限额 = 短时窗的 1/4。
@export_range(0.0, 1000.0, 1.0) var LOAN_LIMIT: float = 100.0
## 击杀一次精英掉落颗粒。
@export_range(0, 100000, 1) var ELITE_GRAIN_DROP: int = 300

@export_group("回溯")
## 回溯消耗(颗粒/秒,按住 rewind)。
@export_range(0.0, 1000.0, 1.0) var COST_REWIND: float = 120.0
## 单机快照采样频率(Hz)。
@export_range(1, 240, 1) var SNAP_HZ: int = 20
## 单机环缓容量(秒)。
@export_range(0.0, 600.0, 1.0) var SNAP_SECONDS: float = 40.0
## 倒放起步倍速(随后落回 1×)。
@export_range(1.0, 10.0, 0.1) var REWIND_START_MULT: float = 3.0
## 起步倍速 → 1× 的过渡时长(秒)。
@export_range(0.0, 5.0, 0.01) var REWIND_RAMP_TIME: float = 0.35

@export_group("加速")
## 加速消耗(颗粒/秒,按住 haste)。
@export_range(0.0, 1000.0, 1.0) var COST_HASTE: float = 80.0
## 玩家与精英的行动倍率。
@export_range(1.0, 10.0, 0.1) var HASTE_PLAYER: float = 2.0
## 其余实体(普通敌 / 敌弹 / 世界物件)的倍率。
@export_range(0.0, 1.0, 0.05) var HASTE_WORLD: float = 0.5

@export_group("贷款")
## 贷款深度给普通敌的表现速度加成上限。
@export_range(0.0, 5.0, 0.05) var LOAN_ENEMY_SPEED_BONUS: float = 0.5
## Sfx 全局音调加成上限。
@export_range(0.0, 5.0, 0.05) var LOAN_PITCH_RANGE: float = 0.5
## 画面变亮上限(shader 亮度叠加)。
@export_range(0.0, 2.0, 0.01) var LOAN_BRIGHT_RANGE: float = 0.35
## 色差偏移上限(像素)。
@export_range(0.0, 100.0, 0.1) var LOAN_ABERRATION_PX: float = 5.0
