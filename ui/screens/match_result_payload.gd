class_name MatchResultPayload
extends RefCounted

const C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]
const C_ROYALE := ["kills", "deaths", "dealt", "taken"]
const C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]


# 生成 1v1 单挑模式结算数据
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var rows: Array = []
	for role in [1, 2]:
		rows.append(_row(names, role, stats.get(role, {}), mvp_role))
	_finish(rows, "kills")
	var sections := [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}]
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": _score_text(round),
		"columns": C_DUEL,
		"sections": sections,
		"mvp": _mvp_position(sections),
	}


# 生成多人大乱斗模式结算数据
static func for_royale(round: Dictionary, names: Dictionary) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var rows: Array = []
	for role in stats:
		rows.append(_row(names, int(role), stats[role]))
	_finish(rows, "kills")
	return {
		"title": "游戏结束",
		"subtitle": "",
		"columns": C_ROYALE,
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 生成团队对抗模式结算数据
static func for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var sections: Array = []
	for t in [1, 2]:
		var rows: Array = []
		for role in stats:
			if int(teams.get(int(role), 0)) != t:
				continue
			rows.append(_row(names, int(role), stats[role], mvp_role))
		_finish(rows, "acs")
		sections.append({
			"label": "A 队" if t == 1 else "B 队",
			"color": UiFactory.C_TEAM_A if t == 1 else UiFactory.C_TEAM_B,
			"rows": rows,
		})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_team),
		"subtitle": _score_text(round),
		"columns": C_TEAM,
		"sections": sections,
		"mvp": _mvp_position(sections),
	}


static func _row(names: Dictionary, role: int, stats: Dictionary, mvp_role := 0) -> Dictionary:
	var row := {"name": str(names.get(role, "玩家%d" % role)), "mvp": role == mvp_role}
	for field in C_TEAM:
		row[field] = int(stats.get(field, 0))
	return row


static func _mvp_position(sections: Array) -> Dictionary:
	for section in sections.size():
		var rows: Array = sections[section]["rows"]
		for row in rows.size():
			if rows[row]["mvp"]:
				return {"section": section, "row": row}
	return {}


static func _score_text(round: Dictionary) -> String:
	var won: Dictionary = round.get("rounds_won", {})
	return "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))]


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


static func _verdict(match_winner: int, local_side: int) -> String:
	if match_winner == 0:
		return "平局"
	return "胜利!" if match_winner == local_side else "失败"
