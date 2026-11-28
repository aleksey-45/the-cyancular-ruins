class_name RoundProjection
extends RefCounted

const Phase := MatchRules.Phase
const RuleState := MatchRules.State
const Actor := preload("res://core/sim/player_state_schema.gd")
const STAT_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const COLUMNS := {
	WorldSpec.DUEL: ["kills", "deaths", "dealt", "taken", "acs"],
	WorldSpec.TEAM: ["kills", "deaths", "assists", "dealt", "taken", "acs"],
	WorldSpec.ROYALE: ["kills", "deaths", "dealt", "taken"],
}

var _spec: WorldSpec
var _role: int
var _tick := -1
var _round := _empty_round()
var _age := 0.0
var _title := ""
var _punch := 0.0
var _countdown := 0.0

func _init(spec: WorldSpec, role: int) -> void:
	_spec = spec
	_role = role

static func _empty_round() -> Dictionary:
	return {"score": "", "board": [], "banner": ["", ""], "countdown": -1.0, "remaining": -1.0,
		"grace": -1.0, "timer": "", "title": "", "subtitle": "", "sections": []}

func advance(state: Dictionary, names: Dictionary, delta: float) -> Dictionary:
	if not state.is_empty() and state.tick != _tick:
		_tick = state.tick
		_round = _project(state, names)
		_age = 0.0
		# 服务器的新快照可以缩短仍在进行的倒计时。
		_countdown = minf(_countdown, _round.countdown) if _countdown > 0.0 else _round.countdown
	else:
		_age += delta
	_countdown = maxf(0.0, _countdown - delta)
	var title: String = str(maxi(1, ceili(_countdown))) if _round.countdown >= 0.0 else _round.banner[0]
	_punch = 1.0 if title != _title else maxf(0.0, _punch - delta * Broadcast.PUNCH_DECAY)
	_title = title
	var timer: String = _round.timer
	if _round.remaining >= 0.0:
		var seconds := int(maxf(0.0, _round.remaining - _age))
		timer = "剩余时间  %d:%02d" % [seconds / 60, seconds % 60]
	var grace := ""
	if _round.grace >= 0.0:
		grace = "对手掉线中,等待重连… 剩余 %ds" % ceili(maxf(0.0, _round.grace - _age))
	return {"round": _round, "timer": timer, "grace": grace, "title": title, "punch": _punch}

func _project(state: Dictionary, names: Dictionary) -> Dictionary:
	var data := round_view(_spec, state)
	data.grace = state.grace
	var mode := _spec.mode
	var round := _empty_round()
	var stage: int = data["state"]
	var side := int(_spec.teams.get(_role, 0)) if mode == WorldSpec.TEAM else _role
	var wins: Dictionary = data["rounds_won"]
	var series := "局胜 %d - %d" % [wins.get(1, 0), wins.get(2, 0)]
	if mode == WorldSpec.ROYALE:
		round.board = _board(data, names, _role, stage == Phase.PLAYING)
	else:
		if mode == WorldSpec.DUEL:
			round.grace = data["grace"].get(3 - side, -1.0)
		var scores: Dictionary = data["scores"]
		var kills := "A 队击杀 %d        B 队击杀 %d" if mode == WorldSpec.TEAM else "P1 击杀 %d        P2 击杀 %d"
		round.score = (kills + "        %s        第 %d 局") % [scores.get(1, 0), scores.get(2, 0), series, data["round"]]
	match stage:
		Phase.WAITING:
			round.timer = "等待玩家加载"
			round.banner.assign([round.timer, ""])
		Phase.COUNTDOWN:
			round.timer = "准备…"
			round.countdown = data["timer"]
			var subtitle := "对战开始" if data["round"] == 1 else "第 %d 局" % data["round"]
			round.banner.assign(["", "大乱斗开始" if mode == WorldSpec.ROYALE else subtitle])
		Phase.PLAYING:
			round.banner.assign(["", ""])
			if mode == WorldSpec.ROYALE:
				round.remaining = data["timer"]
		Phase.ROUND_OVER:
			if mode != WorldSpec.ROYALE:
				var winner: int = data["winner"]
				var subtitle := series
				if mode == WorldSpec.TEAM:
					subtitle = "%s 先到 %d 杀" % ["A 队" if winner == 1 else "B 队",
							TeamRules.kills_to_win(TeamRules.total_players(_spec.team_counts))]
				round.banner.assign(["本局胜利!" if winner == side else "本局落败", subtitle])
		Phase.MATCH_OVER:
			_finish(round, data, names, _spec.teams, side, mode, series)
	return round

static func _finish(round: Dictionary, data: Dictionary, names: Dictionary, teams: Dictionary,
		side: int, mode: String, series: String) -> void:
	var winner: int = data["match_winner"]
	var won := winner == side
	var stats: Dictionary = data["stats"]
	var mvp: int = data["mvp"]
	if mode == WorldSpec.ROYALE:
		round.timer = "对局结束"
		round.title = "游戏结束"
		round.subtitle = "平局" if winner == 0 else ("你赢得了大乱斗" if won else "%s 赢得了大乱斗" % names[winner])
		round.sections.append(_section("击杀排行榜", UiDesign.C_TEXT, mode, stats.keys(), stats, names, 0))
		return
	round.title = "平局" if winner == 0 else ("胜利！" if won else "失败")
	round.subtitle = series
	if mode == WorldSpec.TEAM:
		for team in [1, 2]:
			var roles := stats.keys().filter(func(role: int) -> bool: return teams.get(role, 0) == team)
			round.sections.append(_section("A 队" if team == 1 else "B 队",
					UiDesign.C_TEAM_A if team == 1 else UiDesign.C_TEAM_B, mode, roles, stats, names, mvp))
	else:
		round.sections.append(_section("对局", UiDesign.C_TEXT, mode, [1, 2], stats, names, mvp))

static func _section(title: String, color: Color, mode: String, roles: Array, stats: Dictionary,
		names: Dictionary, mvp: int) -> Dictionary:
	var key := "acs" if mode == WorldSpec.TEAM else "kills"
	var player_name := func(role: int) -> String: return names[role]
	roles.sort_custom(func(a: int, b: int) -> bool:
		var first: Dictionary = stats[a]
		var second: Dictionary = stats[b]
		var score_a := int(first[key])
		var score_b := int(second[key])
		if score_a != score_b:
			return score_a > score_b
		var deaths_a := int(first["deaths"])
		var deaths_b := int(second["deaths"])
		return deaths_a < deaths_b if deaths_a != deaths_b else player_name.call(a) < player_name.call(b))
	var section := {"title": title, "color": color, "headers": [], "rows": []}
	var columns: Array = COLUMNS[mode]
	section.headers = ["#", "昵称"] + columns.map(func(field: String) -> String: return STAT_TITLES[field])
	for i in roles.size():
		var role: int = roles[i]
		var values: Dictionary = stats[role]
		var row := [("★ %d" if role == mvp else "%d") % (i + 1), UiDesign.fit_name(player_name.call(role), 12)]
		for field in columns:
			row.append(int(values[field]))
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
		var color := UiDesign.C_ACCENT if mine else UiDesign.C_TEXT
		if data["left"].has(role):
			tag = "离开"
			color = UiDesign.C_DANGER
		elif data["grace"].has(role):
			tag = "掉线 %ds" % ceili(data["grace"][role])
			color = UiDesign.C_GRACE
		elif playing and not data["alive"][role]:
			tag = "复活中"
			color = UiDesign.C_ACCENT if mine else UiDesign.C_TEXT_DIM
		rows.append(["%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, UiDesign.fit_name(names[role], 14), scores.get(role, 0), data["stats"][role]["deaths"], tag], color])
	return rows

static func round_view(config: WorldSpec, state: Dictionary) -> Dictionary:
	var rules_row: Array = state["rules"]
	var phase: int = rules_row[RuleState.PHASE]
	var winner: int = rules_row[RuleState.WINNER]
	var stats := {}
	var left := []
	var alive := {}
	for role: int in state["stats"]:
		var s: Dictionary = state["stats"][role]
		stats[role] = {"deaths": s["deaths"]}
		if phase == Phase.MATCH_OVER:
			stats[role].merge({"kills": s["kills"], "assists": s["assists"], "dealt": s["dealt"],
				"taken": s["taken"], "acs": ScoreRules.acs(s)})
		if s["left"]:
			left.append(role)
	for role: int in state["players"]:
		alive[role] = not state["players"][role][Actor.DOWNED]
	var candidates: Array = []
	if phase == Phase.MATCH_OVER:
		candidates = stats.keys()
		if config.mode == WorldSpec.TEAM:
			candidates = [] if winner == 0 else candidates.filter(func(role: int) -> bool: return config.teams[role] == winner)
		candidates.sort_custom(func(a: int, b: int) -> bool: return _mvp_better(stats, a, b))
	var timed := config.mode == WorldSpec.ROYALE and phase == Phase.PLAYING
	var timer: float = ceilf(rules_row[RuleState.MATCH_TIME]) if timed else rules_row[RuleState.TIMER]
	return {"state": phase, "round": rules_row[RuleState.NUMBER], "scores": rules_row[RuleState.SCORES],
		"rounds_won": rules_row[RuleState.WINS], "timer": timer, "winner": rules_row[RuleState.ROUND_WINNER],
		"match_winner": winner, "mvp": candidates[0] if not candidates.is_empty() else 0,
		"stats": stats, "left": left, "alive": alive}

static func _mvp_better(stats: Dictionary, a: int, b: int) -> bool:
	for key in ["acs", "kills"]:
		if stats[a][key] != stats[b][key]:
			return stats[a][key] > stats[b][key]
	if stats[a]["deaths"] != stats[b]["deaths"]:
		return stats[a]["deaths"] < stats[b]["deaths"]
	return a < b
