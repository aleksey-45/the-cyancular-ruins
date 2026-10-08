class_name TimeParams
extends RefCounted

# 怀表时间系统参数配置表：时间颗粒经济与时间控制的核心数值单一来源。
# 数值统一在此配置，便于平衡性调优。

# ── 颗粒账户 ────────────────────────────────────────────
const GRAIN_INITIAL := 1000       # 初始颗粒
const GRAIN_CAP := 5000           # 颗粒额度上限（怀表白短针一圈）
const SHORT_WINDOW := 400.0       # 短时间额度（红长针一圈；短时消耗累计，恢复时逆时针回拨）
const SHORT_REGEN := 50.0         # 短期额度恢复速率（颗粒/秒；优先偿还透支，还清后恢复短期额度）
const LOAN_LIMIT := 100.0         # 透支限额（红长针额外 1/4 圈，即短期时间窗口的 1/4）

# ── 技能消耗 ────────────────────────────────────────────
const COST_REWIND := 120.0        # 时空回溯消耗率（颗粒/秒，按住 Shift）
const COST_HASTE := 80.0          # 时间加速消耗率（颗粒/秒，按住右键或 Ctrl）

# ── 世界快照与倒放（时空回溯）──────────────────────────────
const SNAP_HZ := 20               # 快照采样频率，单位为 Hz
const SNAP_SECONDS := 40.0        # 环形缓冲容量（秒），即颗粒耗尽前可回溯的最大时长上限
const REWIND_START_MULT := 3.0    # 倒放起步倍速（快速倒流视觉反馈，随后平滑过渡至 1x）
const REWIND_RAMP_TIME := 0.35    # 起步倍速过渡至 1x 的时长（秒）

# ── 时间加速相对流速 ──
# 主角与精英单位时间加快（2.0 倍），普通敌人、敌方子弹及世界物体时间减慢（0.5 倍）。
# 通过分域缩放实现相对 4 倍时差，不修改全局 Engine.time_scale，确保底层物理手感稳定。
const HASTE_PLAYER := 2.0         # 玩家与精英的行动倍率
const HASTE_WORLD := 0.5          # 其余实体（普通敌人、敌弹、世界物件）的倍率

# ── 透支的世界反馈(§怀表设计:透支越深效果越强)─────────────────
const LOAN_ENEMY_SPEED_BONUS := 0.5    # 敌人表现速度加成上限(深度1 → ×1.5;实为自身变慢)
const LOAN_PITCH_RANGE := 0.5          # Sfx 全局音调加成上限(深度1 → pitch×1.5)
const LOAN_BRIGHT_RANGE := 0.35        # 画面变亮上限(shader 亮度叠加)
const LOAN_ABERRATION_PX := 5.0        # 色差偏移上限(像素;红蓝影分离,深度1 达满)

# ── 乌鸫精英(§3.5.2)──────────────────────────────────────────
const ELITE_GRAIN_DROP := 300     # 击杀一次掉落颗粒
