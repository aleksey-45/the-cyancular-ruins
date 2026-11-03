class_name ScoreRules
extends RefCounted

# 逐人计分口径(**纯静态、无 autoload、可 `-s` 测**)。

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


# 在候选集里挑 MVP:ACS 高 → 击杀多 → 阵亡少 → role 号升序。纯函数(不碰节点/autoload),`-s` 可测。
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
