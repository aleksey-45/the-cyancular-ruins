class_name LobbyProjection
extends RefCounted

static func card(room: Dictionary, can_open: bool) -> Dictionary:
	var mode: String = room["mode"]
	var rules: String
	var color := UiDesign.C_ACCENT
	match mode:
		PvpSession.MODE_ROYALE:
			var minutes := int(room["match_time"]) / 60
			rules = "限时 %d 分" % minutes if minutes > 0 else "不限时"
			color = UiDesign.C_MODE_ROYALE
		PvpSession.MODE_TEAM:
			var counts: Dictionary = room["team_counts"]
			rules = "A%d / B%d / 未选%d" % [counts[1], counts[2], counts[0]]
			color = UiDesign.C_MODE_TEAM
		_:
			rules = "三局两胜"
	if room["player_collision"]:
		rules += " · 玩家碰撞开启"
	var players: Array = room["players"]
	var names := PackedStringArray()
	for i in mini(players.size(), 3):
		var entry: Dictionary = players[i]
		names.append("· %s%s" % [UiDesign.fit_name(entry["name"], 14),
				"(房主)" if entry["role"] == room["host_role"] else ""])
	if players.size() > 3:
		names.append("…等 %d 人" % players.size())
	return {"can_open": can_open, "title": PvpSession.mode_name(mode, room["beta"]), "mode_color": color,
		"in_match": room["in_match"], "code": room["code"], "rules": rules,
		"count": "人数 %d / %d" % [room["count"], room["max_players"]],
		"host": "房主 %s" % room["host_name"], "roster": "\n".join(names),
		"thumbnail": MapCatalog.thumbnail(room["map"])}

static func waiting(room: Dictionary) -> Dictionary:
	var mode: String = room["mode"]
	var is_team := mode == PvpSession.MODE_TEAM
	var own: int = room["your_role"]
	var host: int = room["host_role"]
	var players: Array = room["players"]
	var title := "%s房间 %s" % [PvpSession.mode_name(mode, room["beta"]), room["code"]]
	if room["player_collision"]:
		title += " · 玩家碰撞开启"
	var roster: Array[Array] = []
	var rank := 0
	var my_team := 0
	for side in ([1, 2] if is_team else [0]):
		var members := players.filter(func(entry: Dictionary) -> bool: return entry["team"] == side) if is_team else players
		if is_team:
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
		PvpSession.MODE_TEAM:
			var counts: Dictionary = room["team_counts"]
			count = "A %d/%d、B %d/%d，共 %d/%d" % [
					counts[1], TeamRules.MAX_TEAM, counts[2], TeamRules.MAX_TEAM, room["count"], TeamRules.MAX_TOTAL]
		PvpSession.MODE_ROYALE:
			count = "%d / %d 人(至少 2 人可开局)" % [players.size(), room["max_players"]]
		_:
			count = "%d / 2 人%s" % [players.size(), "（由房主开始）" if players.size() == 2 else "（等待对手加入）"]
	return {"code": room["code"], "title": title, "count": count, "roster": roster,
		"team": is_team, "my_team": my_team, "can_start": own == host and room["can_start"]}
