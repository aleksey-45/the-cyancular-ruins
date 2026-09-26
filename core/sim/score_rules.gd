class_name ScoreRules
extends RefCounted

# 逐人计分口径(**纯静态、无 autoload、可 `-s` 测**)。
# ★ 为什么单独成文件:口径要能被 `-s` 冒烟直接钉(性质断言),而宿主链
#   (`MatchState` → …)引用 `NetBus`,静态引用它会连带编译到 autoload ⇒ `-s` 里
#   **连 `_initialize()` 都进不去、直接挂到 timeout**。与 `core/sim/weapon_inventory.gd` /
#   `core/sim/explosion.gd` 同款取舍(纯逻辑、可 `-s` 测)。
# ★ 三模式共用**同一份** —— 这正是统计面能上提到基类的前提:旧口径
#   `kill_bonus_score(敌方存活人数)` 在 1v1(两人)与大乱斗(自由混战)里根本没有对应物。
#
# ★★ 五个权重是**首版默认值,属于平衡参数、预期会被调**(spec §3.2)。守卫分**两半**,别只读前半句:
#   ① `tests/score_rules_smoke.gd` 钉的是**性质**(死亡多 ⇒ ACS 低…),**它自己与权重取值无关** ——
#      调数确实不会让它红;
#   ② 但**测量生产路径分数**的那几条把**字面量**写进了期望值(`tests/stats_delivery_probe.tscn` ①、
#      `tests/team_host_probe.tscn` ⑬d/⑬e/⑬f/⑬g)。**实测(2026-09-26,HEAD)**:`KILL_SCORE` 100→110
#      ⇒ `score_rules_smoke` 与 `match_result_payload_smoke` 照旧全绿,而 `stats_delivery_probe` 红
#      **1** 条(①)、`team_host_probe` 红 **6** 条(⑬d ×2 / ⑬e ×2 / ⑬f 的 `[仪器]` 前提 ×1 / ⑬g ×1
#      —— ⑬f 与 ⑬g 各自的**主**断言仍绿,红的只是它们的前置/派生读数)。
#   ⇒ **"调数不该让任何探针红"是错的(2026-09-26 订正)**:调权重必须**同步改那两处期望值**
#      (或把它们改成从本文件的常量派生)。★ 别把那 7 条当假红去放宽 —— 它们正是
#      "新公式真的走在生产路径上"的唯一守卫。

const KILL_SCORE := 100          # 一个击杀
const ASSIST_SCORE := 50         # 一次助攻
const DAMAGE_PER_POINT := 5      # 伤害 ÷ 5:打光一个人(玩家满血 50)≈ 10 分
const DEATH_PENALTY := 50        # 死一次 = 半个击杀:疼,但不至于让"敢冲"亏本
const TEAM_KILL_PENALTY := 100   # 击杀队友:额外重罚一个击杀的分量


# 惩罚 = (对队友造成的伤害 + 对自己造成的伤害) ÷ 5 + 击杀队友 × 100
# ★ 伤害项与"伤害"**同倍率**(`DAMAGE_PER_POINT`)⇒ 友伤在伤害那一项上 1:1 冲销,不双重惩罚。
# ★ 三项都记在**肇事者**身上(调用方保证),只减分、不进 `dealt` / `taken`。
static func penalty(team_damage: int, self_damage: int, team_kills: int) -> int:
	return (team_damage + self_damage) / DAMAGE_PER_POINT + team_kills * TEAM_KILL_PENALTY


# 总积分。★ **伤害只在这里出现一次** —— 读端(`acs`)不得再加:那正是"伤害被算两次"的
# 唯一入口,而且双计**不报错**,只是所有排名静默偏移(spec §1.4)。
static func kscore(kills: int, assists: int, dealt: int, deaths: int,
		team_damage: int = 0, self_damage: int = 0, team_kills: int = 0) -> int:
	return kills * KILL_SCORE \
			+ assists * ASSIST_SCORE \
			+ dealt / DAMAGE_PER_POINT \
			- deaths * DEATH_PENALTY \
			- penalty(team_damage, self_damage, team_kills)


# 场均。局数下限 1(与既有 `_acs_of` 的 `maxi(_rounds_for(role), 1)` 同口径)。
static func acs(total_kscore: int, rounds: int) -> float:
	return float(total_kscore) / float(maxi(rounds, 1))
