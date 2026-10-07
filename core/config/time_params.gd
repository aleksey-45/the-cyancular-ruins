class_name TimeParams
extends RefCounted

# 怀表时间系统·第一阶段(v0.5.0)参数总表 —— 主策划案 §2.1「时间粒子」经济的代码单一来源。
# 分层约定(见 AGENTS.md「参数体系」):共享=GameParameters;玩家=PlayerParams;敌人=
# EnemyParams;武器=tscn @export;**时间玩法=本文件**(静态访问,如 TimeParams.GRAIN_INITIAL)。
# 改数值只动这里;策划案里的表格数值全部落于此,标定调优无需碰任何逻辑代码。

# ── 粒子账户(§2.1)────────────────────────────────────────────
const GRAIN_INITIAL := 1000       # 初始粒子
const GRAIN_CAP := 5000           # 粒子额度上限(怀表白短针一圈)
const SHORT_WINDOW := 400.0       # 短时间额度(红长针一圈;短时消耗累计,恢复=逆时针拨回)
const SHORT_REGEN := 50.0         # 短期额度恢复速率(粒子/秒;优先偿还透支，还清后恢复短期额度)
const LOAN_LIMIT := 100.0         # 透支限额 = 红长针额外 1/4 圈(短期时间窗口的 1/4)

# ── 技能消耗(§3.1)────────────────────────────────────────────
const COST_REWIND := 120.0        # 回溯:粒子/秒(按住 Shift)
const COST_HASTE := 80.0          # 加速:粒子/秒(按住 Ctrl)

# ── 世界快照/倒放(第一阶段回溯)──────────────────────────────
const SNAP_HZ := 20               # 快照采样频率(Hz)
const SNAP_SECONDS := 40.0        # 环形缓冲容量(秒)≈ 粒子耗尽前可回溯的最大时长上限
const REWIND_START_MULT := 3.0    # 倒放起步倍速(快速倒流观感,随后落回 1×)
const REWIND_RAMP_TIME := 0.35    # 起步倍速 → 1× 的过渡时长(秒)

# ── 加速相对速率(2026-09-26 用户改令:夸张档 —— 主角 ×2、其余一切 ×0.5)──────
# 语义是"主角的时间被加快、别人的时间被拉慢":玩家/精英 ×2.0(移动/换弹/击发/冲刺/游泳/攀爬),
# 普通敌人与敌方子弹、掉落武器等世界物件 ×0.5。相对差 4 倍,不动全局 time_scale
# (物理/tween/网络全不受扰)。
const HASTE_PLAYER := 2.0         # 玩家与精英的行动倍率
const HASTE_WORLD := 0.5          # 其余一切实体(普通敌/敌弹/世界物件)的倍率

# ── 透支的世界反馈(§怀表设计:透支越深效果越强)─────────────────
const LOAN_ENEMY_SPEED_BONUS := 0.5    # 敌人表现速度加成上限(深度1 → ×1.5;实为自身变慢)
const LOAN_PITCH_RANGE := 0.5          # Sfx 全局音调加成上限(深度1 → pitch×1.5)
const LOAN_BRIGHT_RANGE := 0.35        # 画面变亮上限(shader 亮度叠加)
const LOAN_ABERRATION_PX := 5.0        # 色差偏移上限(像素;红蓝影分离,深度1 达满)

# ── 乌鸫精英(§3.5.2)──────────────────────────────────────────
const ELITE_GRAIN_DROP := 300     # 击杀一次掉落粒子
