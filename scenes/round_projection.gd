class_name RoundProjection
extends RefCounted

const Mode := MatchFrame.Mode
const Phase := NetEvent.RoundState
const STAT_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const COLUMNS := {
	Mode.DUEL: ["kills", "deaths", "dealt", "taken", "acs"],
	Mode.TEAM: ["kills", "deaths", "assists", "dealt", "taken", "acs"],
	Mode.ROYALE: ["kills", "deaths", "dealt", "taken"],
}

static func sample(data: Dictionary, names: Dictionary, teams: Dictionary, counts: Dictionary,
		role: int, mode: MatchFrame.Mode) -> PvpHud.Round:
	var round := PvpHud.Round.new()
	var stage: int = data["state"]
	var side := int(teams.get(role, 0)) if mode == Mode.TEAM else role
	var wins: Dictionary = data["rounds_won"]
	var series := "局胜 %d - %d" % [wins.get(1, 0), wins.get(2, 0)]
	if mode == Mode.ROYALE:
		round.board = _board(data, names, role, stage == Phase.PLAYING)
	else:
		if mode == Mode.DUEL:
			round.grace = data["grace"].get(3 - side, -1.0)
		var scores: Dictionary = data["scores"]
		var kills := "A 队击杀 %d        B 队击杀 %d" if mode == Mode.TEAM else "P1 击杀 %d        P2 击杀 %d"
		round.score = (kills + "        %s        第 %d 局") % [scores.get(1, 0), scores.get(2, 0), series, data["round"]]
	match stage:
		Phase.WAITING:
			round.timer = "等待玩家加载"
			round.banner.assign([round.timer, ""])
		Phase.COUNTDOWN:
			round.timer = "准备…"
			round.countdown = data["timer"]
			var subtitle := "对战开始" if data["round"] == 1 else "第 %d 局" % data["round"]
			round.banner.assign(["", "大乱斗开始" if mode == Mode.ROYALE else subtitle])
		Phase.PLAYING:
			round.banner.assign(["", ""])
			if mode == Mode.ROYALE:
				round.remaining = data["timer"]
		Phase.ROUND_OVER:
			if mode != Mode.ROYALE:
				var winner: int = data["winner"]
				var subtitle := series
				if mode == Mode.TEAM:
					subtitle = "%s 先到 %d 杀" % ["A 队" if winner == 1 else "B 队",
							TeamRules.kills_to_win(TeamRules.total_players(counts))]
				round.banner.assign(["本局胜利!" if winner == side else "本局落败", subtitle])
		Phase.MATCH_OVER:
			_finish(round, data, names, teams, side, mode, series)
	return round

static func _finish(round: PvpHud.Round, data: Dictionary, names: Dictionary, teams: Dictionary,
		side: int, mode: MatchFrame.Mode, series: String) -> void:
	var winner: int = data["match_winner"]
	var won := winner == side
	var title := "平局" if winner == 0 else ("胜利!" if won else "失败")
	var stats: Dictionary = data["stats"]
	var mvp: int = data["mvp"]
	var subtitle: String
	if mode == Mode.ROYALE:
		round.timer = "对局结束"
		subtitle = "杀敌数不相上下" if winner == 0 else ("你是大乱斗之王" if won else "%s 赢得了大乱斗" % names[winner])
		round.banner.assign(["胜利！" if won and winner != 0 else title, subtitle])
		round.title = "游戏结束"
		round.sections.append(_section("击杀排行榜", UiFactory.C_TEXT, mode, stats.keys(), stats, names, 0))
		return
	if won:
		subtitle = "你们赢下了整场对战" if mode == Mode.TEAM else "你赢得了整场对战"
	elif winner != 0:
		subtitle = "再接再厉…"
	else:
		subtitle = "双方都离开了对局…" if mode == Mode.TEAM else "对局结束"
	round.banner.assign([title, subtitle])
	round.title = title
	round.subtitle = series
	if mode == Mode.TEAM:
		for team in [1, 2]:
			var roles := stats.keys().filter(func(role: int) -> bool: return teams.get(role, 0) == team)
			round.sections.append(_section("A 队" if team == 1 else "B 队",
					UiFactory.C_TEAM_A if team == 1 else UiFactory.C_TEAM_B, mode, roles, stats, names, mvp))
	else:
		round.sections.append(_section("对局", UiFactory.C_TEXT, mode, [1, 2], stats, names, mvp))

static func _section(title: String, color: Color, mode: MatchFrame.Mode, roles: Array, stats: Dictionary,
		names: Dictionary, mvp: int) -> PvpHud.Section:
	var key := "acs" if mode == Mode.TEAM else "kills"
	var player_name := func(role: int) -> String: return str(names.get(role, "玩家%d" % role))
	roles.sort_custom(func(a: int, b: int) -> bool:
		var first: Dictionary = stats.get(a, {})
		var second: Dictionary = stats.get(b, {})
		var score_a := int(first.get(key, 0))
		var score_b := int(second.get(key, 0))
		if score_a != score_b:
			return score_a > score_b
		var deaths_a := int(first.get("deaths", 0))
		var deaths_b := int(second.get("deaths", 0))
		return deaths_a < deaths_b if deaths_a != deaths_b else player_name.call(a) < player_name.call(b))
	var section := PvpHud.Section.new()
	section.title = title
	section.color = color
	var columns: Array = COLUMNS[mode]
	section.headers = ["#", "昵称"] + columns.map(func(field: String) -> String: return STAT_TITLES[field])
	for i in roles.size():
		var role: int = roles[i]
		var values: Dictionary = stats.get(role, {})
		var row := [("★ %d" if role == mvp else "%d") % (i + 1), UiFactory.fit_name(player_name.call(role), 12)]
		for field in columns:
			row.append(int(values.get(field, 0)))
		section.rows.append([role == mvp, row])
	return section

static func _board(data: Dictionary, names: Dictionary, own: int, playing: bool) -> Array[Array]:
	var scores: Dictionary = data["scores"]
	var roles := names.keys()
	roles.sort_custom(func(a: int, b: int) -> bool:
		var first: int = scores.get(a, 0)
		var second: int = scores.get(b, 0)
		return first > second if first != second else a < b)
	var rows: Array[Array] = []
	for i in roles.size():
		var role: int = roles[i]
		var mine := role == own
		var tag := "存活"
		var color := UiFactory.C_ACCENT if mine else UiFactory.C_TEXT
		if data["left"].has(role):
			tag = "离开"
			color = UiFactory.C_DANGER
		elif data["grace"].has(role):
			tag = "掉线 %ds" % ceili(data["grace"][role])
			color = UiFactory.C_GRACE
		elif playing and not data["alive"][role]:
			tag = "复活中"
			color = UiFactory.C_ACCENT if mine else UiFactory.C_TEXT_DIM
		rows.append(["%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, UiFactory.fit_name(names[role], 14), scores.get(role, 0), data["stats"][role]["deaths"], tag], color])
	return rows
