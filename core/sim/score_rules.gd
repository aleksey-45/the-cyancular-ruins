class_name ScoreRules
extends RefCounted

# 联机模式共用战斗评分规则。总战斗评分除以回合数得到 ACS。

const KILL_SCORE := 100
const ASSIST_SCORE := 50
const DAMAGE_PER_POINT := 5      # 每累计 5 点有效伤害，计入 1 分。
const DEATH_PENALTY := 50
const TEAM_KILL_PENALTY := 100


static func acs(stats: Dictionary) -> float:
	var offense: int = stats["kills"] * KILL_SCORE + stats["assists"] * ASSIST_SCORE + stats["dealt"] / DAMAGE_PER_POINT
	var penalty: int = stats["deaths"] * DEATH_PENALTY + stats["team_kills"] * TEAM_KILL_PENALTY \
			+ (stats["team_damage"] + stats["self_damage"]) / DAMAGE_PER_POINT
	return float(offense - penalty) / stats["rounds"]
