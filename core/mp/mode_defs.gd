class_name ModeDefs
extends RefCounted

# 三模式常量与表的**单一来源**(纯静态、不引 autoload ⇒ `-s` 冒烟可直接 load)。

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"
const MODE_IDS: Array[String] = [MODE_PVP, MODE_ROYALE, MODE_TEAM]

# 角色号上界(大乱斗人数上限 16)。worker 的 `--roles` / `--ai-roles` 越界按此拒绝(ModeContext)。
const ROLE_MAX := 16
# 「两队对抗」(mode id 仍是 "team"):`TEAM_SIZE` = **每队人数上限**(不是每队必须满员),`TEAM_ROLES` 由它乘出来
const TEAM_SIZE := 5
const TEAM_COUNT := 2

# 端口在 teardown 后多久才可复用(秒);三档唯一来源(大厅/worker 都读这里,别抄第二份)。
# 承重的不是这个延迟,而是「worker 进程活着 ⇒ 房与端口都还在」;本表只兜「worker 刚退出、别立刻复用它」。
const PORT_REUSE_DELAY_PVP := 120.0
# 大乱斗/对抗:按默认一局时长 + 收尾估。★ 三档一起动、一起复核(改一档要看另外两档)。
const PORT_REUSE_DELAY_ROYALE := 360.0
const PORT_REUSE_DELAY_TEAM := 360.0


static func port_return_seconds(mode: String) -> float:
	match mode:
		MODE_ROYALE: return PORT_REUSE_DELAY_ROYALE
		MODE_TEAM: return PORT_REUSE_DELAY_TEAM
	return PORT_REUSE_DELAY_PVP

# 选项下发的键:**只列该模式真的有这一项**的(UI 按同一份表显隐 —— 藏了控件却仍生效是明确缺陷)。
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

