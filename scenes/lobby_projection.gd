class_name LobbyProjection
extends RefCounted

static func waiting(room: Dictionary) -> Dictionary:
	var mode: String = room["mode"]
	var is_team := mode == WorldSpec.TEAM
	var own: int = room["your_role"]
	var host: int = room["host_role"]
	var players: Array = room["players"]
	var title := "%s房间 %s" % [PvpSession.mode_name(mode, room["beta"]), room["code"]]
	if room["player_collision"]:
		title += " · 玩家碰撞开启"
	var roster: Array[Array] = []
	var team_sizes := {}
	var rank := 0
	var my_team := 0
	for side in ([1, 2] if is_team else [0]):
		var members := players.filter(func(entry: Dictionary) -> bool: return entry["team"] == side) if is_team else players
		if is_team:
			team_sizes[side] = members.size()
			roster.append(["—— %s 队(%d/%d) ——" % ["A" if side == 1 else "B", members.size(), TeamRules.MAX_TEAM],
					UiDesign.C_ACCENT])
		for member: Dictionary in members:
			var role: int = member["role"]
			var mine := role == own
			if mine:
				my_team = side
			rank += 1
			roster.append(["%d. %s%s%s" % [rank, member["name"], "(我)" if mine else "", "(房主)" if role == host else ""],
					UiDesign.C_ACCENT if mine else UiDesign.C_TEXT])
	var count: String
	match mode:
		WorldSpec.TEAM:
			count = "A %d/%d、B %d/%d，共 %d/%d" % [
					team_sizes[1], TeamRules.MAX_TEAM, team_sizes[2], TeamRules.MAX_TEAM, players.size(), TeamRules.MAX_TOTAL]
		WorldSpec.ROYALE:
			count = "%d / %d 人(至少 2 人可开局)" % [players.size(), room["max_players"]]
		_:
			count = "%d / 2 人%s" % [players.size(), "（由房主开始）" if players.size() == 2 else "（等待对手加入）"]
	return {"code": room["code"], "title": title, "count": count, "roster": roster,
		"team": is_team, "my_team": my_team, "can_start": own == host and room["can_start"]}
