class_name TeamRules
extends RefCounted

# 团队模式的纯规则：人数校验、击杀目标、少人方补偿与伤害倍率。
# 服务端、客户端预测与 HUD 共用同一份公式，开局后阵容固定，掉线不重算补偿。

const MIN_TEAM := 1
const MAX_TEAM := 5
const MAX_TOTAL := 10
const BASE_HP := 50
const HP_PER_PLAYER := 5
const HP_BONUS_CAP := 4
const DAMAGE_DIFF_MIN := 3
const DAMAGE_STEP := 0.1
const DAMAGE_STEP_CAP := 3

## 纯校验：返回 {1: 人数, 2: 人数}，非法数据返回空字典；错误由调用方决定是否报告。
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

## 以下规则只接受 team_counts() 验证过的阵容；缺失字段是内部不变量错误，不再按零人处理。
static func total_players(counts: Dictionary) -> int:
	return int(counts[1]) + int(counts[2])

static func team_difference(counts: Dictionary) -> int:
	return absi(int(counts[1]) - int(counts[2]))

## 单局击杀目标：总人数 + 3，夹在 [5, 13]。
## clampi 只处理合法总人数下的规则上限，不替非法阵容兜底。
static func kills_to_win(total: int) -> int:
	assert(total >= MIN_TEAM * 2 and total <= MAX_TOTAL, "TeamRules: 总人数 %d 超出 2~%d" % [total, MAX_TOTAL])
	return clampi(total + 3, 5, 13)

## 少人方队伍编号；人数相同返回 0。
static func disadvantaged_team(counts: Dictionary) -> int:
	var a := int(counts[1])
	var b := int(counts[2])
	if a == b:
		return 0
	return 1 if a < b else 2

## 少人方开局得分补贴等于人数差，其他队伍为 0。
static func score_bonus(team: int, counts: Dictionary) -> int:
	if team != disadvantaged_team(counts):
		return 0
	return team_difference(counts)

## 少人方起始最大生命：50 + 5 × min(人数差, 4)，其他队伍 50。
static func max_hp(team: int, counts: Dictionary) -> int:
	if team != disadvantaged_team(counts):
		return BASE_HP
	return BASE_HP + HP_PER_PLAYER * mini(team_difference(counts), HP_BONUS_CAP)

## 少人方对敌伤害倍率：人数差 ≥3 时为 1.0 + 0.1 × min(人数差 - 2, 3)，否则 1.0。
## 自伤、友伤、无归属伤害与非团队模式都由 attacker_team/victim_team 归零处理。
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
