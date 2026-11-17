extends Node

const MAP := "res://maps/demo.cyrm"
const DT := 1.0 / 60.0
const MARKER := "DOWN EDGE PROBE: ALL-OK"
const EXPECTED_CHECKS := 3

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[down-edge]   ✓ %s" % msg)
	else:
		_fails.append(msg)
		print("[down-edge]   ✗ %s" % msg)


func _ready() -> void:
	_test_duel_five_kills()
	await get_tree().process_frame
	_test_royale_unattributed()
	await get_tree().process_frame
	_test_team_friendly_fire()
	await get_tree().process_frame

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	print("[down-edge] checks = %d (EXPECTED_CHECKS=%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("DOWN EDGE PROBE: FAIL")
		for f in _fails:
			print("[down-edge]   ✗ %s" % f)
		get_tree().quit(1)


func _test_duel_five_kills() -> void:
	var h: MatchHost = MatchHost.new(MAP, {1: 19001, 2: 19002})
	add_child(h)
	h.state._round_state = MatchState.RoundState.PLAYING
	var p1 = h.state.players[1]
	for i in range(MatchState.KILLS_TO_WIN):
		p1.combat.force_down()
		h._match_round_tick(DT)
		if i < MatchState.KILLS_TO_WIN - 1:
			h._respawn_player(1)
	var stats: Dictionary = h.state.stats_payload()
	var score2 := int(h.state._scores.get(2, 0))
	var kills2 := int((stats.get(2, {}) as Dictionary).get("kills", 0))
	var deaths1 := int((stats.get(1, {}) as Dictionary).get("deaths", 0))
	_chk(score2 == MatchState.KILLS_TO_WIN and kills2 == score2 and deaths1 == MatchState.KILLS_TO_WIN
			and int(h.state._round_state) == MatchState.RoundState.ROUND_OVER,
			"① 1v1 5 杀:记分条 %d / 结算 kills %d / 死者 deaths %d / 相位 %d(期望 5/5/5/ROUND_OVER)"
			% [score2, kills2, deaths1, int(h.state._round_state)])
	h.queue_free()


func _test_royale_unattributed() -> void:
	var h: RoyaleHost = RoyaleHost.new(MAP, {1: 19001, 2: 19002})
	add_child(h)
	h.state._round_state = MatchState.RoundState.PLAYING
	h.state.players[1].combat.force_down()
	h._match_round_tick(DT)
	var stats: Dictionary = h.state.stats_payload()
	var kills2 := int((stats.get(2, {}) as Dictionary).get("kills", -1))
	var deaths1 := int((stats.get(1, {}) as Dictionary).get("deaths", 0))
	_chk(kills2 == 0 and h.state._scores.is_empty() and deaths1 == 1,
			"② 大乱斗无归因死亡:对手 kills=%d、记分 %s、死者 deaths=%d(期望 0/{} /1)"
			% [kills2, str(h.state._scores), deaths1])
	h.queue_free()


func _test_team_friendly_fire() -> void:
	var teams := {1: 1, 2: 1, 3: 2}
	var h: TeamHost = TeamHost.new(MAP, {1: 19001, 2: 19002, 3: 19003}, {}, [], {}, teams)
	add_child(h)
	h.state._round_state = MatchState.RoundState.PLAYING
	var score_before := int(h.state._scores.get(2, 0))
	var attacker = h.state.players[1]
	var victim = h.state.players[2]
	victim.set_meta("last_damager", attacker)
	victim.set_meta("last_damager_time", Time.get_ticks_msec())
	victim.combat.force_down()
	h._match_round_tick(DT)
	var stats: Dictionary = h.state.stats_payload()
	var atk: Dictionary = stats.get(1, {})
	var vic: Dictionary = stats.get(2, {})
	var raw_atk: Dictionary = h.state._stats.get(1, {})
	_chk(int(h.state._scores.get(2, 0)) == score_before + 1 and int(atk.get("kills", -1)) == 0
			and int(raw_atk.get("team_kills", -1)) == 1 and int(vic.get("deaths", 0)) == 1,
			"③ 3v3 队友误炸:对方队 +1(%d→%d)、肇事者 kills=%d team_kills=%d、死者 deaths=%d(期望 +1/0/1/1)"
			% [score_before, int(h.state._scores.get(2, 0)), int(atk.get("kills", -1)),
			int(raw_atk.get("team_kills", -1)), int(vic.get("deaths", 0))])
	h.queue_free()
