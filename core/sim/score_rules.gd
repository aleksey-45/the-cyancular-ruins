class_name ScoreRules
extends RefCounted


const KILL_SCORE := 100
const ASSIST_SCORE := 50
const DAMAGE_PER_POINT := 5
const DEATH_PENALTY := 50
const TEAM_KILL_PENALTY := 100


static func penalty(team_damage: int, self_damage: int, team_kills: int) -> int:
	return (team_damage + self_damage) / DAMAGE_PER_POINT + team_kills * TEAM_KILL_PENALTY


# 总积分。★ 伤害只在这里出现一次 —— 读端(`acs`)不得再加:那正是"伤害被算两次"的
# 唯一入口,而且双计不报错,只是所有排名静默偏移(spec §1.4)。
static func kscore(kills: int, assists: int, dealt: int, deaths: int,
		team_damage: int = 0, self_damage: int = 0, team_kills: int = 0) -> int:
	return kills * KILL_SCORE \
			+ assists * ASSIST_SCORE \
			+ dealt / DAMAGE_PER_POINT \
			- deaths * DEATH_PENALTY \
			- penalty(team_damage, self_damage, team_kills)


static func acs(total_kscore: int, rounds: int) -> float:
	return float(total_kscore) / float(maxi(rounds, 1))


static func pick_mvp(stats: Dictionary, candidates: Array = []) -> int:
	var pool: Array = []
	if candidates.is_empty():
		pool = stats.keys()
	else:
		for c in candidates:
			var cr := int(c)
			if stats.has(cr):
				pool.append(cr)
		if pool.is_empty():
			pool = stats.keys()
	pool.sort()
	var best_role := 0
	var best_acs := 0.0
	var best_kills := 0
	var best_deaths := 0
	var first := true
	for r in pool:
		var role := int(r)
		var s: Dictionary = stats[role]
		var acs_v := float(s.get("acs", 0.0))
		var kills := int(s.get("kills", 0))
		var deaths := int(s.get("deaths", 0))
		if first or acs_v > best_acs \
				or (acs_v == best_acs and (kills > best_kills
						or (kills == best_kills and deaths < best_deaths))):
			best_role = role
			best_acs = acs_v
			best_kills = kills
			best_deaths = deaths
			first = false
	return best_role
