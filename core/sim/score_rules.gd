class_name ScoreRules
extends RefCounted

# 玩家个人战绩表现分与积分规则（纯逻辑工具类，无 Autoload 依赖）。
# 统一定义全模式通用的战绩权重与场均战斗积分 ACS 计算公式。

const KILL_SCORE := 100          # 单次击杀得分
const ASSIST_SCORE := 50         # 单次助攻得分
const DAMAGE_PER_POINT := 5      # 造成伤害折算分（伤害 / 5）
const DEATH_PENALTY := 50        # 单次阵亡扣分
const TEAM_KILL_PENALTY := 100   # 误杀队友扣分


# 计算违规操作罚分：友军伤害与自伤按相同伤害比例扣除，误杀队友额外扣除固定罚分。
static func penalty(team_damage: int, self_damage: int, team_kills: int) -> int:
	return (team_damage + self_damage) / DAMAGE_PER_POINT + team_kills * TEAM_KILL_PENALTY


# 计算单局或累计表现总积分。
static func kscore(kills: int, assists: int, dealt: int, deaths: int,
		team_damage: int = 0, self_damage: int = 0, team_kills: int = 0) -> int:
	return kills * KILL_SCORE \
			+ assists * ASSIST_SCORE \
			+ dealt / DAMAGE_PER_POINT \
			- deaths * DEATH_PENALTY \
			- penalty(team_damage, self_damage, team_kills)


# 计算每局平均战斗积分 ACS，回合数保底为 1。
static func acs(total_kscore: int, rounds: int) -> float:
	return float(total_kscore) / float(maxi(rounds, 1))
