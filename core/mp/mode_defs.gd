class_name ModeDefs
extends RefCounted

# 三模式常量与表的**单一来源**(纯静态、不引 autoload ⇒ `-s` 冒烟可直接 load)。
#
# 为什么收在这里:选项键 / 结算列 / 角色上界此前各写一份 ——
#   · 3v3 曾把 1v1 的"禁用武器"照旧上发(界面藏了控件,设置却仍生效);
#   · 16 人上限只改了大厅/UI,worker 的 `--roles` 解析仍卡 8;
#   · 结算列在三处适配器里各维护一份键表。
# 统一到"一张表"后,新增/修改模式只改这里;纯逻辑守卫(`mode_defs_smoke`)已于 2026-10-24 默认批削减删除 ⇒ 改错只能靠联机场景行为/试玩发现。
#
# ★ 三个 ID 必须与 `PvpSession.MODE_*` 逐字一致("pvp"/"royale"/"team")。本文件刻意**不 import**
#   PvpSession(它是 autoload,`-s` 下加载会拿到空成员),一致性由冒烟 ① 钉住字面量。

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"
const MODE_IDS: Array[String] = [MODE_PVP, MODE_ROYALE, MODE_TEAM]

# 角色号上界(大乱斗人数上限 16)。worker 的 `--roles` / `--ai-roles` 越界按此拒绝(ModeContext)。
const ROLE_MAX := 16
# 「两队对抗」(mode id 仍是 "team"):`TEAM_SIZE` = **每队人数上限**(不是每队必须满员),`TEAM_ROLES` 由它乘出来
# ⇒ 大厅容量 / 加入上限 / 列表 cap 全都是 10。开局条件(两队各 ≥1 人)与目标/补贴公式都不在这里 ——
# 前者在 `RoomTypes.team_ready`,后者在 `TeamRules`(纯逻辑单一来源)。
# ★ 2026-11 由「两队各 3、满 6 才开」改成「每队 1..5、两队各有 1 人即开」:3v3 那一档(两队各 3)仍是主用法,
#   但人数不再写死在模式定义里 —— 写死 3 会在 4v4 / 5v5 时静默截断,而现象只是"第 7 个人进不来"。
const TEAM_SIZE := 5
const TEAM_COUNT := 2

# 选项下发的键:**只列该模式真的有这一项**的(UI 按同一份表显隐 —— 藏了控件却仍生效是明确缺陷)。
# ★ 与旧实现的差异是有意的(2026-10-22):3v3 不再上发 `disabled_weapons` / `round_full_heal`,
#   大乱斗不再上发 `round_full_heal`(它没有回合),1v1 不再上发 `match_time`(只有大乱斗读它)。
#   `time`(Beta 时间规则)不在这张表里 —— 它是"beta 开启 且 非 1v1"的条件键,由 ModeOptions.build 追加。
const OPTION_KEYS: Dictionary = {
	MODE_PVP: ["round_full_heal", "disabled_weapons", "map"],
	MODE_ROYALE: ["disabled_weapons", "match_time", "map"],
	MODE_TEAM: ["map"],
}

# 结算页列集(`ui/screens/match_result_payload.gd` 的三个适配器读它)。
const RESULT_COLUMNS: Dictionary = {
	MODE_PVP: ["kills", "deaths", "dealt", "taken", "acs"],
	MODE_ROYALE: ["kills", "deaths", "dealt", "taken"],
	MODE_TEAM: ["kills", "deaths", "assists", "dealt", "taken", "acs"],
}

static func label(mode: String) -> String:
	match mode:
		MODE_PVP: return "1v1"
		MODE_ROYALE: return "大乱斗"
		MODE_TEAM: return "对抗"   # ★ mode id 仍是 "team";只改显示名(2 个汉字,不加副文案)
	return ""

static func option_keys(mode: String) -> Array:
	return (OPTION_KEYS.get(mode, []) as Array).duplicate()

