class_name TimeParams
extends RefCounted

# 时间维度参数总表 —— 策划案《The Cyancular Ruins 时间维度玩法》v0.3 §9 的**代码单一来源**。
#
# 分层约定(见 AGENTS.md「参数体系」):共享=GameParameters;玩家=PlayerParams;敌人=EnemyParams;
# 武器=tscn @export;瓦片=tile_defs.json;持久偏好=Settings;**时间维度=本文件**(静态访问,
# 如 TimeParams.W0_DEFAULT / TimeParams.kill_seconds("BlackBird"))。
#
# 单位约定(重要):内部一律 **秒(float)**;策划案表格用分钟,故"分钟"常量带 _MIN 后缀,
# 一律经 *_seconds()/min_to_sec() 换算,禁止在业务代码里手写 ×60。
# 时间粒度 = 10ms(§12 决议 2):内部浮点秒,HUD 显示百分秒,地图事件行支持小数秒。

# ── 时间轴(§1.1)──────────────────────────────────────────────
# D = (FINAL − w) / FINAL;w 是"距最终时刻的剩余秒"(世界针)。
const FINAL_SECONDS: float = 7200.0    # 轴全长 120 min → 灾前 D=0 / 终末 D=1
const W0_DEFAULT: float = 3600.0       # 开局世界针(距最终时刻 60 min)= T_ruin,D=50%
const PRE_RUIN_TARGET: float = 7200.0  # W ≥ 此值 = 回到灾前(真结局条件;含 Boss 巨块 +60')

# ── 时间粒度(§12 决议 2)──────────────────────────────────────
const GRANULARITY_MS: int = 10         # 逻辑粒度(毫秒)
const GRANULARITY: float = 0.01        # 逻辑粒度(秒)= GRANULARITY_MS / 1000

# ── 自然衰减(§9)─────────────────────────────────────────────
const DECAY_FLOW: float = 1.0                                   # F0 基准流速(世界秒 / 真实秒)
const PHASE_DECAY_BONUS: Array[float] = [0.0, 0.15, 0.30, 0.50]  # 四阶段额外衰减
const PHASE_THRESHOLDS: Array[float] = [0.25, 0.50, 0.75]        # 毁灭度阶段阈值
const PHASE_NAMES: Array[String] = ["灾前余晖", "侵蚀", "崩坏", "终末"]

# ── 时间流速场(§3)───────────────────────────────────────────
const FLOW_NORMAL: float = 1.0
const FLOW_RUSH: float = 2.0      # 时间涨潮区(高风险高回报)
const FLOW_LAG: float = 0.5       # 时滞区(安全但收益慢)
const FLOW_STORM: float = 3.0     # 时间风暴(事件临时改写)

# ── 子弹时间 / 决策时停(§12 决议 3)────────────────────────────
const SCALE_NORMAL: float = 1.0
const SCALE_PAUSE: float = 0.0    # 决策 UI(交易/合成/地图)打开 → 时停,思考不烧钟
const SCALE_SLOW: float = 0.05    # 可选的风格化慢放档

# ── 击杀回收(§4.4;单位分钟,键 = 敌人类型键)────────────────────
const KILL_VALUES_MIN: Dictionary = {
	"SmallBird": 0.2,
	"JumpBird": 0.35,
	"FlyBird": 0.35,
	"BlackBird": 1.0,
	"Elite": 2.0,
	"RegionBoss": 15.0,
	"FinalBoss": 60.0,   # 足以回拨越过灾前
}
# 经济防崩(§10):同种怪在窗口内重复击杀收益递减。M8 平衡期启用(默认 1.0=不衰减)。
const KILL_REPEAT_DECAY: float = 0.85
const KILL_REPEAT_WINDOW: float = 20.0

# ── 时间线事件默认值(.cyrt 事件行可用 k=v 标志逐条覆盖)────────────
const EVT_EXPLODE_DMG: int = 45       # explode(战斗规则爆炸):满伤(随距离二次衰减)
const EVT_EXPLODE_KB: float = 260.0   # explode:击退力
const EVT_WIPE_DMG: int = 60          # wipe(强制清除):实体固定伤害(不衰减/无 LOS)
const EVT_WIPE_KB: float = 320.0      # wipe:固定击退

# ── 消费与惩罚(§4.1)────────────────────────────────────────
const DEATH_PENALTY_MIN: float = 5.0                      # 死亡:W 向毁灭推进 5 min
const SEAL_DENOMINATIONS_MIN: Array[float] = [5.0, 10.0, 25.0]   # 封存块面额(道具卡)
const SEAL_FORGE_LOSS_MIN: float = 1.0                    # 铸 10' 块收 11'(惩罚档;M5 启用)

# ── 事件系统(§4.2)──────────────────────────────────────────
const EVENT_WARN_SECONDS: float = 60.0   # 阈值前预告窗(HUD 表盘警告)


# ── 换算与派生(全部纯函数,-s 探针可直接断言)────────────────────

static func min_to_sec(minutes: float) -> float:
	return minutes * 60.0


static func sec_to_min(seconds: float) -> float:
	return seconds / 60.0


## 某类敌人的时间价值(秒)。未知键返回 0(不回收)。
static func kill_seconds(enemy_key: String) -> float:
	return min_to_sec(float(KILL_VALUES_MIN.get(enemy_key, 0.0)))


## 毁灭度 → 阶段序号(0=灾前余晖 … 3=终末)。
static func phase_of(destruction: float) -> int:
	var p := 0
	for t in PHASE_THRESHOLDS:
		if destruction >= t:
			p += 1
	return p


## 阶段序号 → 世界钟衰减倍率(F0 + 阶段加成)。
static func decay_multiplier_of(destruction: float) -> float:
	return DECAY_FLOW + PHASE_DECAY_BONUS[phase_of(destruction)]


## 阶段序号 → 中文名(HUD/播报用)。
static func phase_name(phase: int) -> String:
	return PHASE_NAMES[clampi(phase, 0, PHASE_NAMES.size() - 1)]


## 表盘文本(百分秒,§4.7)。例:14.3 → "T-14.30"。
static func format_clock(w: float) -> String:
	return "T-%05.2f" % maxf(w, 0.0)
