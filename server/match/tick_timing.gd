extends RefCounted

# O0(bullet-perf 那一轮的 O0 段;细节见 git log)· 服务器 tick 分段计时。

const SECTIONS: Array[StringName] = [&"adjudicate", &"own_snap", &"world_snap", &"rewind"]

var on := NetDiag.enabled()

var _win_at := 0
var _ticks := 0
var _tick_sum := 0
var _tick_max := 0
var _bullets_sum := 0
var _bullets_max := 0
var _players := 0
var _sum: Dictionary = {}
var _max: Dictionary = {}
var _runs: Dictionary = {}


func begin() -> int:
	if not on:
		return -1
	return Time.get_ticks_usec()


func end(section: StringName, t0: int) -> void:
	if not on or t0 < 0:
		return
	var usec := Time.get_ticks_usec() - t0
	_sum[section] = int(_sum.get(section, 0)) + usec
	_runs[section] = int(_runs.get(section, 0)) + 1
	if usec > int(_max.get(section, 0)):
		_max[section] = usec


func end_tick(t0: int, players: Dictionary, host: Node) -> void:
	if not on or t0 < 0:
		return
	var now := Time.get_ticks_usec()
	var usec := now - t0
	_ticks += 1
	_tick_sum += usec
	if usec > _tick_max:
		_tick_max = usec
	_players = players.size()
	var bullets := 0
	if host != null and host.is_inside_tree():
		bullets = host.get_tree().get_nodes_in_group("bullet").size()
	_bullets_sum += bullets
	if bullets > _bullets_max:
		_bullets_max = bullets
	if _win_at == 0:
		_win_at = now
		return
	if now - _win_at < NetDiag.metric_interval_ms() * 1000:
		return
	_emit(now)


func _emit(now: int) -> void:
	if _ticks > 0:
		var ticks := _ticks
		var tick_avg := float(_tick_sum) / float(ticks)
		var d := {
			"interval_ms": (now - _win_at) / 1000,
			"ticks": ticks,
			"players": _players,
			"bullets_avg": roundi(float(_bullets_sum) / float(ticks)),
			"bullets_max": _bullets_max,
			"tick_avg_us": roundi(tick_avg),
			"tick_max_us": _tick_max,
		}
		for section in SECTIONS:
			var avg := float(int(_sum.get(section, 0))) / float(ticks)
			d["%s_runs" % section] = int(_runs.get(section, 0))
			d["%s_avg_us" % section] = roundi(avg)
			d["%s_max_us" % section] = int(_max.get(section, 0))
			d["%s_pct" % section] = snappedf(avg * 100.0 / maxf(tick_avg, 1.0), 0.1)
		NetDiag.log_metric("tick_sections", d)
	_reset(now)


func _reset(now: int) -> void:
	_win_at = now
	_ticks = 0
	_tick_sum = 0
	_tick_max = 0
	_bullets_sum = 0
	_bullets_max = 0
	_players = 0
	_sum.clear()
	_max.clear()
	_runs.clear()
