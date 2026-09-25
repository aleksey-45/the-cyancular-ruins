class_name TimeParams
extends RefCounted

# 个人钟·第一阶段(v0.5.0)参数总表 —— 主策划案 §2.1「时间颗粒」经济的代码单一来源。
# 分层约定(见 AGENTS.md「参数体系」):共享=GameParameters;玩家=PlayerParams;敌人=
# EnemyParams;武器=tscn @export;**时间玩法=本文件**(静态访问,如 TimeParams.GRAIN_INITIAL)。
# 改数值只动这里;策划案里的表格数值全部落于此,标定调优无需碰任何逻辑代码。

# ── 颗粒账户(§2.1)────────────────────────────────────────────
const GRAIN_INITIAL := 1000       # 初始颗粒
const GRAIN_CAP := 5000           # 颗粒额度上限(怀表白短针一圈)
const SHORT_WINDOW := 400.0       # 短时间额度(红长针一圈;短时消耗累计,恢复=逆时针拨回)
const SHORT_REGEN := 50.0         # 短时额度恢复速率(颗粒/秒;先还贷后回窗)
const LOAN_LIMIT := 100.0         # 贷款限额 = 红长针额外 1/4 圈(短时窗的 1/4)

# ── 技能消耗(§3.1)────────────────────────────────────────────
const COST_REWIND := 120.0        # 回溯:颗粒/秒(按住 Shift)
const COST_HASTE := 80.0          # 加速:颗粒/秒(按住 Ctrl)

# ── 世界快照/倒放(第一阶段回溯)──────────────────────────────
const SNAP_HZ := 20               # 快照采样频率(Hz)
const SNAP_SECONDS := 40.0        # 环形缓冲容量(秒)≈ 颗粒耗尽前可回溯的最大时长上限
const REWIND_START_MULT := 3.0    # 倒放起步倍速(快速倒流观感,随后落回 1×)
const REWIND_RAMP_TIME := 0.35    # 起步倍速 → 1× 的过渡时长(秒)

# ── 加速相对速率(§3.1「玩家相对普通敌人 2×」)─────────────────
# 实现为:玩家/精英 ×2、普通敌人与敌方子弹 ×1(等价于「世界慢一半」的相对效果,
# 但不动全局 time_scale,物理/tween/网络全不受扰)。
const HASTE_PLAYER := 2.0         # 玩家与精英的行动倍率
const HASTE_WORLD := 1.0          # 普通敌人/敌弹的倍率(策划案口径的「敌人适当放慢」由相对差实现)

# ── 贷款的世界反馈(§怀表设计:贷款越深效果越强)─────────────────
const LOAN_ENEMY_SPEED_BONUS := 0.5    # 敌人表现速度加成上限(深度1 → ×1.5;实为自身变慢)
const LOAN_PITCH_RANGE := 0.5          # Sfx 全局音调加成上限(深度1 → pitch×1.5)
const LOAN_BRIGHT_RANGE := 0.35        # 画面变亮上限(shader 亮度叠加)
const LOAN_ABERRATION_PX := 5.0        # 色差偏移上限(像素;红蓝影分离,深度1 达满)

# ── 乌鸫精英(§3.5.2)──────────────────────────────────────────
const ELITE_GRAIN_DROP := 300     # 击杀一次掉落颗粒
