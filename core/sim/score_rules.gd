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
# ★★ 五个权重是**首版默认值,属于平衡参数、预期会被调**(spec §3.2)。守卫在 `tests/score_rules_smoke.gd`
#   里钉的是**性质**(死亡多 ⇒ ACS 低…),不是这几个数本身 —— 调数不该让任何探针红。

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
