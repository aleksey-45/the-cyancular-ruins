class_name TeamRules
extends RefCounted

# 「两队对抗」(模式 id 仍是 `ModeDefs.MODE_TEAM = "team"`)的数值规则**单一来源**:纯静态、不引 autoload

# ── 开局条件 ──
const MIN_PER_TEAM := 1   # 两队各 ≥1 人即可开局(用户要求「两队都有人即可开始」)
# 每队人数上限:与大厅容量同源 —— 容量 = TEAM_SIZE × TEAM_COUNT(见 ModeDefs),不在这里写第二份 5。
# 本类只做数值计算,容量闸门仍由 `RoomTypes.team_can_join` / `LobbyRooms.team_join` 负责。

# ── 每局击杀目标 ──
const KILLS_BASE := 3
const KILLS_MIN := 5
const KILLS_MAX := 13

# ── 开局比分补贴 ──
# 少人方开局直接带 `人数差` 分;上限 = 目标 - 1(差 1 分就赢的局 = 开局即胜,必须防)。
# 理由:比分补贴是最直接的"少打多"补偿,1 人 = 1 分,量纲与击杀一致,玩家一眼能读懂。

# ── 血量补贴 ──
const HP_STEP_PERMILLE := 100    # 每差 1 人的血量补贴(千分比,+10%)
const HP_CAP_PERMILLE := 400     # 血量补贴上限(+40%)

# ── 伤害补贴(只在"极端少"时给)──
const DAMAGE_THRESHOLD := 3
const DAMAGE_STEP := 0.1
const DAMAGE_CAP_STEPS := 3      # ⇒ 上限 1.3


# `teams` = role(int) -> 队号(1/2),就是 `TeamHost.team_map()` / match_sync 里 `teams` 的形状。
# 返回 {1: 人数, 2: 人数};不在 {1,2} 的队号不计(与 `TeamSpawn.apply_team_layers` 的穷举口径一致)。
static func team_counts(teams: Dictionary) -> Dictionary:
	var counts := {1: 0, 2: 0}
	for role in teams:
		var t := int(teams[role])
		if counts.has(t):
			counts[t] = int(counts[t]) + 1
	return counts


static func total_players(counts: Dictionary) -> int:
	return int(counts.get(1, 0)) + int(counts.get(2, 0))


# 两队人数差(绝对值)。差 0 = 势均,一切补贴必须恒等。
static func head_diff(counts: Dictionary) -> int:
	return absi(int(counts.get(1, 0)) - int(counts.get(2, 0)))


# 人少那一队的队号;势均(或没有有效的两队)⇒ 0(本模式没有 0 队,0 = 「没有少人方」)。
static func smaller_team(counts: Dictionary) -> int:
	var a := int(counts.get(1, 0))
	var b := int(counts.get(2, 0))
	if a == b:
		return 0
	return 1 if a < b else 2


# 每局击杀目标 = clamp(总人数 + 3, 5, 13)。锚点:2 人 → 5、6 人 → 9、10 人 → 13。
static func kills_to_win(counts: Dictionary) -> int:
	return clampi(total_players(counts) + KILLS_BASE, KILLS_MIN, KILLS_MAX)


# 少人方开局比分补贴 = min(人数差, 目标 - 1)。势均 ⇒ 0(**恒等**,不是"0 分也写进表")。
static func score_bonus(counts: Dictionary) -> int:
	var diff := head_diff(counts)
	if diff == 0:
		return 0
	return mini(diff, kills_to_win(counts) - 1)


# 少人方基础血上限的**加成点数** = round(基础血上限 × 千分比)。整数血量按点位算,不做四舍五入到十位。
static func hp_bonus_hp(counts: Dictionary) -> int:
	var permille := mini(head_diff(counts) * HP_STEP_PERMILLE, HP_CAP_PERMILLE)
	if permille <= 0:
		return 0
	return roundi(float(PlayerParams.player_max_hp) * float(permille) / 1000.0)


# 少人方**造成的伤害**倍率。差 < 3 ⇒ 恒 1.0(所有整数值原样返回);之后每差 1 人 +0.1,封顶 1.3。
static func damage_mult(counts: Dictionary) -> float:
	var diff := head_diff(counts)
	if diff < DAMAGE_THRESHOLD:
		return 1.0
	var steps := mini(diff - DAMAGE_THRESHOLD + 1, DAMAGE_CAP_STEPS)
	return 1.0 + DAMAGE_STEP * float(steps)


# 一次性算全(权威与客户端都只读这一份;不要在调用点各拼一次 —— 那是"同一件事两处实现")。
# 返回键:counts / total / diff / smaller_team / kills_target / score_bonus / hp_bonus / damage_mult。
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


