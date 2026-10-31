class_name TeamRules
extends RefCounted

# 「两队对抗」(模式 id 仍是 `ModeDefs.MODE_TEAM = "team"`)的数值规则**单一来源**:纯静态、不引 autoload
# ⇒ `-s` 冒烟可直接 load(`mode_defs_smoke` 已删,本文件的守卫 = `tests/smoke/team_rules_smoke.gd`)。
#
# 角色:2~10 人、两队各 **至少 1 人** 即可开局、每队上限 `ModeDefs.TEAM_SIZE`(5)。人数不相等时给少人方三种补贴。
# ★ 为什么要一个纯类:目标 / 比分补贴 / 血量补贴 / 伤害补贴要同时被**服务器**(`server/hosts/team_host.gd` 的真值)、
#   **客户端**(`scenes/team_game.gd` 从 match_sync 的 `teams` 复算同一条,不新增协议字段)与**纯冒烟**读;
#   三处各写一份公式必然漂,而漂了不报错(只是两边看到的血上限/目标不一样)。
#
# ★★ 硬约束(**6 人 3v3 行为与改造前逐字一致**):3v3 = 两队各 3 人 ⇒ 人数差 0 ⇒ `subsidy()` 必须给出
#   目标 9 / 比分补贴 0 / 血量补贴 0 / 伤害倍率 1.0。这四条由冒烟的「6 人恒等」一节钉住;`team_match_probe`
#   (真链路 6 人)只验行为,验不到公式,故公式侧的守卫必须住在这里。

# ── 开局条件 ──
const MIN_PER_TEAM := 1   # 两队各 ≥1 人即可开局(用户要求「两队都有人即可开始」)
# 每队人数上限:与大厅容量同源 —— 容量 = TEAM_SIZE × TEAM_COUNT(见 ModeDefs),不在这里写第二份 5。
# 本类只做数值计算,容量闸门仍由 `RoomTypes.team_can_join` / `LobbyRooms.team_join` 负责。

# ── 每局击杀目标 ──
# 公式:**目标 = 总人数 + 3**(再钳到 [5,13])。三点锚定用户给的数:2 人 → 5、6 人 → 9(= 原 3v3 的 9,逐字保留)、
# 10 人 → 13。取「人数 + 常数」而不是按比例:对局是**两队对抗**,每多一个人就多一条命要打,目标应线性涨;
# 常数 3 保证 2 人局也不会 2 杀就收(至少 5 杀),线性项保证人多不会把人头摊薄到没有节奏。
const KILLS_BASE := 3
const KILLS_MIN := 5
const KILLS_MAX := 13

# ── 开局比分补贴 ──
# 少人方开局直接带 `人数差` 分;上限 = 目标 - 1(差 1 分就赢的局 = 开局即胜,必须防)。
# 理由:比分补贴是最直接的"少打多"补偿,1 人 = 1 分,量纲与击杀一致,玩家一眼能读懂。

# ── 血量补贴 ──
# 每差 1 人 +10% 基础血上限(基础 50 ⇒ +5 血),上限 +40%(⇒ 70 血)。理由:
#   · 血量是"顶住多人集火"最直观的补偿,且与伤害补贴不同,它不改变任何人的进攻手感;
#   · 10%/人的斜率让 3v1(差 2)是 60 血、5v1(差 4)是 70 血 —— 够用,但到 70 就封顶:
#     再不封顶,1v9 的 1 人方会变成"打不死",而本模式的胜负手是击杀目标而不是单挑。
# ★ 血量上限是**两端各自从队伍表复算**的(服务端真值 + 客户端镜像),不走协议 —— 见 team_game.gd::_apply_team_health_subsidy。
const HP_STEP_PERMILLE := 100    # 每差 1 人的血量补贴(千分比,+10%)
const HP_CAP_PERMILLE := 400     # 血量补贴上限(+40%)

# ── 伤害补贴(只在"极端少"时给)──
# 人数差 ≥ `DAMAGE_THRESHOLD`(3,即 4v1 / 5v2 这种)才给,每多差 1 人 +10%,上限 +30%。
# 理由:伤害是**最烫**的补偿(直接改 TTK),差 1~2 人时用比分 + 血量就已足够;到 4v1 这种极端场面才需要它。
# 差 < 3 时倍率**恒等 1.0**(整数伤害按 `roundi(base × 1.0)` 回来还是原值 ⇒ 6 人 3v3 逐字不变)。
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


# 某个队号是不是"需要补贴的少人方"。势均 / 队号非法 ⇒ false(恒等分支:什么都不要给)。
static func is_subsidized_team(counts: Dictionary, team: int) -> bool:
	var s := smaller_team(counts)
	return s != 0 and int(team) == s
