class_name ScoreRules
extends RefCounted

# 多人模式使用同一套战斗计分。ACS 表示每回合平均获得的战斗分。

const KILL_SCORE := 100
const ASSIST_SCORE := 50
const DAMAGE_PER_POINT := 5      # 每累计 5 点有效伤害，计入 1 分。
const DEATH_PENALTY := 50
const TEAM_KILL_PENALTY := 100


# 自伤和友军伤害按伤害量合并扣分，击杀队友另计罚分。
static func penalty(team_damage: int, self_damage: int, team_kills: int) -> int:
	return (team_damage + self_damage) / DAMAGE_PER_POINT + team_kills * TEAM_KILL_PENALTY


# 合计击杀、助攻和伤害得分，扣除阵亡与友军伤害等罚分。
static func kscore(kills: int, assists: int, dealt: int, deaths: int,
		team_damage: int = 0, self_damage: int = 0, team_kills: int = 0) -> int:
	return kills * KILL_SCORE \
			+ assists * ASSIST_SCORE \
			+ dealt / DAMAGE_PER_POINT \
			- deaths * DEATH_PENALTY \
			- penalty(team_damage, self_damage, team_kills)


# 回合计数为零时按一回合计算，以免除零。
static func acs(total_kscore: int, rounds: int) -> float:
	return float(total_kscore) / float(maxi(rounds, 1))
