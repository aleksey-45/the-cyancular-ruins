class_name NetMetrics
extends RefCounted


static func snapshot_loss(prev_tick: int, tick: int, step: int) -> int:
	if prev_tick < 0 or tick <= prev_tick:
		return 0
	var st := maxi(step, 1)
	var gap := tick - prev_tick
	if gap <= st:
		return 0
	return int(gap / st) - 1


static func loss_pct(rx: int, lost: int) -> int:
	var total := rx + lost
	if total <= 0:
		return 0
	return roundi(100.0 * float(lost) / float(total))


static func server_log_dir(is_server: bool, is_template: bool, exe_dir: String, user_dir: String) -> String:
	if is_server and is_template:
		return exe_dir.path_join("log")
	return user_dir
