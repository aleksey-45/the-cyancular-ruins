class_name TeamRules
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

# 这里集中定义组队限制、获胜分数和人数劣势时的补偿。
# 服务器、客户端和 HUD 都使用对局开始时确定的队伍人数，以免补偿随连接状态变化。

const MIN_TEAM := 1
const MAX_TEAM := 5
const MAX_TOTAL := 10
const HP_PER_PLAYER := 5
const HP_BONUS_CAP := 4
const DAMAGE_DIFF_MIN := 3
const DAMAGE_STEP := 0.1
const DAMAGE_STEP_CAP := 3

## 检查玩家队伍编号并统计各队人数。人数或队伍编号无效时返回空字典。
static func team_counts(teams: Dictionary) -> Dictionary:
	var counts := {1: 0, 2: 0}
	for role in teams:
		var team := int(teams[role])
		if team != 1 and team != 2:
			return {}
		counts[team] = int(counts[team]) + 1
	var a: int = counts[1]
	var b: int = counts[2]
	if a < MIN_TEAM or b < MIN_TEAM:
		return {}
	if a > MAX_TEAM or b > MAX_TEAM or a + b > MAX_TOTAL:
		return {}
	return counts

## counts 保存两队的人数，由 team_counts() 计算。
static func total_players(counts: Dictionary) -> int:
	return int(counts[1]) + int(counts[2])

static func team_difference(counts: Dictionary) -> int:
	return absi(int(counts[1]) - int(counts[2]))

## 回合目标分为玩家总数加 3，取值范围为 5–13。
static func kills_to_win(total: int) -> int:
	assert(total >= MIN_TEAM * 2 and total <= MAX_TOTAL, "TeamRules: 总人数 %d 超出 2~%d" % [total, MAX_TOTAL])
	return clampi(total + 3, 5, 13)

## 两队人数相同不需要补偿，因此用 0 表示没有人数较少的队伍。
static func disadvantaged_team(counts: Dictionary) -> int:
	var a := int(counts[1])
	var b := int(counts[2])
	if a == b:
		return 0
	return 1 if a < b else 2

## 人数较少的一队开局获得额外分数，每少一人加 1 分。
static func score_bonus(team: int, counts: Dictionary) -> int:
	if team != disadvantaged_team(counts):
		return 0
	return team_difference(counts)

## 通常使用玩家的默认生命值上限。人数较少的一队每少一人增加 5 点生命值上限，最多增加 20 点。
static func max_hp(team: int, counts: Dictionary) -> int:
	var base := CFG.player_max_hp
	if counts.is_empty() or team != disadvantaged_team(counts):
		return base
	return base + HP_PER_PLAYER * mini(team_difference(counts), HP_BONUS_CAP)

## 伤害加成只适用于人数较少的一队攻击另一队。
## 人数相差 3、4、5 人时分别增加 10%、20%、30% 伤害，人数差更大时仍按 30% 计算。
static func damage_factor(attacker_team: int, victim_team: int, counts: Dictionary) -> float:
	if attacker_team != 1 and attacker_team != 2:
		return 1.0
	if victim_team != 1 and victim_team != 2:
		return 1.0
	if attacker_team == victim_team:
		return 1.0
	if attacker_team != disadvantaged_team(counts):
		return 1.0
	var difference := team_difference(counts)
	if difference < DAMAGE_DIFF_MIN:
		return 1.0
	return 1.0 + DAMAGE_STEP * mini(difference - 2, DAMAGE_STEP_CAP)
