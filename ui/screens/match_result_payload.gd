class_name MatchResultPayload
extends RefCounted

# 结算面板数据适配器：
# 将各模式的服务端回合结算数据转换为 MatchResult 组件所需的统一数据结构。
# 包含字段映射、确定性排序、MVP 判定与多队伍分组逻辑。

# 各模式表格呈现的列集合
const C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]
const C_ROYALE := ["kills", "deaths", "dealt", "taken"]
const C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]


# 生成 1v1 单挑模式结算数据
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var rows: Array = []
	for role in [1, 2]:
		var s: Dictionary = stats.get(role, {})
		rows.append(_row(_name_of(names, role), int(s.get("kills", 0)), int(s.get("deaths", 0)),
				int(s.get("assists", 0)), int(s.get("dealt", 0)), int(s.get("taken", 0)),
				int(s.get("acs", 0)), int(role) == mvp_role))
	_finish(rows, "kills")
	var mvp_pos := {}
	for ri in rows.size():
		if bool(rows[ri]["mvp"]):
			mvp_pos = {"section": 0, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_DUEL,
		"sections": [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": mvp_pos,
	}


# 生成多人大乱斗模式结算数据
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var rows: Array = []
	for role in stats:
		var s: Dictionary = stats[role]
		rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
				int(s.get("deaths", 0)), int(s.get("assists", 0)),
				int(s.get("dealt", 0)), int(s.get("taken", 0)), int(s.get("acs", 0))))
	_finish(rows, "kills")
	return {
		"title": "游戏结束",
		"subtitle": "",
		"columns": C_ROYALE,
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 生成 3v3 团队对抗模式结算数据
static func for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var sections: Array = []
	for t in [1, 2]:
		var rows: Array = []
		for role in stats:
			if int(teams.get(int(role), 0)) != t:
				continue
			var s: Dictionary = stats[role]
			rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
					int(s.get("deaths", 0)), int(s.get("assists", 0)),
					int(s.get("dealt", 0)), int(s.get("taken", 0)),
					int(s.get("acs", 0)), int(role) == mvp_role))
		_finish(rows, "acs")
		sections.append({
			"label": "A 队" if t == 1 else "B 队",
			"color": UiFactory.C_TEAM_A if t == 1 else UiFactory.C_TEAM_B,
			"rows": rows,
		})
	var pos := {}
	for si in sections.size():
		var rows: Array = sections[si]["rows"]
		for ri in rows.size():
			if bool(rows[ri]["mvp"]):
				pos = {"section": si, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict_team(int(round.get("match_winner", 0)), my_team),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_TEAM,
		"sections": sections,
		"mvp": pos,
	}


static func _row(nm: String, kills: int, deaths: int, assists: int, dealt: int, taken: int,
		acs: int, mvp: bool = false) -> Dictionary:
	return {"rank": 0, "name": nm, "kills": kills, "deaths": deaths, "assists": assists,
			"dealt": dealt, "taken": taken, "acs": acs, "mvp": mvp}


# 确定性排序：主键降序 -> 阵亡升序 -> 昵称字典序升序
static func _finish(rows: Array, key: String) -> void:
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a[key]) != int(b[key]):
			return int(a[key]) > int(b[key])
		if int(a["deaths"]) != int(b["deaths"]):
			return int(a["deaths"]) < int(b["deaths"])
		return str(a["name"]) < str(b["name"]))
	for i in rows.size():
		rows[i]["rank"] = i + 1


static func _name_of(names: Dictionary, role: int) -> String:
	return str(names.get(role, "玩家%d" % role))


# 1v1 单挑胜负判定
static func _verdict(match_winner: int, my_role: int) -> String:
	if match_winner == 0:
		return "平 局"
	return "胜利!" if match_winner == my_role else "失败"


# 3v3 团队对抗胜负判定
static func _verdict_team(match_winner: int, my_team: int) -> String:
	if match_winner == 0:
		return "平 局"
	if my_team == 0:
		return "失败"
	return "胜利!" if match_winner == my_team else "失败"

