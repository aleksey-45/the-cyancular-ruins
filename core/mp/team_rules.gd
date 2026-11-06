class_name TeamRules
extends RefCounted

# 「两队对抗」(模式 id 仍是 `ModeDefs.MODE_TEAM = "team"`)的数值规则单一来源:纯静态、不引 autoload

const MIN_PER_TEAM := 1
# 每队人数上限:与大厅容量同源 —— 容量 = TEAM_SIZE × TEAM_COUNT(见 ModeDefs),不在这里写第二份 5。
# 本类只做数值计算,容量闸门仍由 `RoomTypes.team_can_join` / `LobbyRooms.team_join` 负责。

const KILLS_BASE := 3
const KILLS_MIN := 5
const KILLS_MAX := 13


const HP_STEP_PERMILLE := 100
const HP_CAP_PERMILLE := 400

const DAMAGE_THRESHOLD := 3
const DAMAGE_STEP := 0.1
const DAMAGE_CAP_STEPS := 3


static func team_counts(teams: Dictionary) -> Dictionary:
	var counts := {1: 0, 2: 0}
	for role in teams:
		var t := int(teams[role])
		if counts.has(t):
			counts[t] = int(counts[t]) + 1
	return counts


static func total_players(counts: Dictionary) -> int:
	return int(counts.get(1, 0)) + int(counts.get(2, 0))


static func head_diff(counts: Dictionary) -> int:
	return absi(int(counts.get(1, 0)) - int(counts.get(2, 0)))


static func smaller_team(counts: Dictionary) -> int:
	var a := int(counts.get(1, 0))
	var b := int(counts.get(2, 0))
	if a == b:
		return 0
	return 1 if a < b else 2


static func kills_to_win(counts: Dictionary) -> int:
	return clampi(total_players(counts) + KILLS_BASE, KILLS_MIN, KILLS_MAX)


static func score_bonus(counts: Dictionary) -> int:
	var diff := head_diff(counts)
	if diff == 0:
		return 0
	return mini(diff, kills_to_win(counts) - 1)


static func hp_bonus_hp(counts: Dictionary) -> int:
	var permille := mini(head_diff(counts) * HP_STEP_PERMILLE, HP_CAP_PERMILLE)
	if permille <= 0:
		return 0
	return roundi(float(PlayerParams.player_max_hp) * float(permille) / 1000.0)


static func damage_mult(counts: Dictionary) -> float:
	var diff := head_diff(counts)
	if diff < DAMAGE_THRESHOLD:
		return 1.0
	var steps := mini(diff - DAMAGE_THRESHOLD + 1, DAMAGE_CAP_STEPS)
	return 1.0 + DAMAGE_STEP * float(steps)


static func subsidy(teams: Dictionary) -> Dictionary:
	var counts := team_counts(teams)
	var diff := head_diff(counts)
	return {
		"counts": counts,
		"total": total_players(counts),
		"diff": diff,
		"smaller_team": smaller_team(counts),
		"kills_target": kills_to_win(counts),
		"score_bonus": score_bonus(counts),
		"hp_bonus": hp_bonus_hp(counts),
		"damage_mult": damage_mult(counts),
	}


