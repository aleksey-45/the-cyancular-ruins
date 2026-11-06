class_name InputIntake
extends RefCounted


var _q_peak: Dictionary = {}
var _q_drops: Dictionary = {}
var _diag_acc := 0.0

var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_trace := false
var _netstat_trace_f := 0


func reset(pending: Dictionary, role: int) -> void:
	pending[role] = []
	_q_peak.erase(role)
	_q_drops.erase(role)


func intake(pending: Dictionary, role: int, pkt: Dictionary) -> void:
	if not pending.has(role):
		pending[role] = []
	var prev_peak := int(_q_peak.get(role, 0))
	var cap := PacketInputSource.adapted_cap(prev_peak)
	var raw: int = PacketInputSource.push_pending(pending[role] as Array, pkt, cap)
	if raw > cap:
		_q_drops[role] = int(_q_drops.get(role, 0)) + (raw - cap)
		NetDiag.log_event("queue_drop", {"role": int(role), "raw": raw, "cap": cap,
				"drops": int(_q_drops[role])})
	_q_peak[role] = maxi(raw, prev_peak - 1)


# 每 tick 一次:先 --diag 的 1Hz 采样(与 --netstat 同源但不依赖它),再 --netstat / --netstat-trace 的人读行。
# ★ 次序不可调:--diag 默认关时零开销,而 --netstat 的 1Hz 行要读同一批 _q_peak/_q_drops。
func tick(pending: Dictionary, delta: float, round_state: int, st_map: Dictionary,
		ct_map: Dictionary) -> void:
	_diag_tick(pending, delta)
	if not _netstat_checked:
		_netstat_checked = true
		var ua := OS.get_cmdline_user_args()
		_netstat = ua.has("--netstat")
# --netstat-trace:逐帧打(只在前 600 tick ≈ 10 秒)。★ 每秒一行的采样看不见 0.13 秒的爬升(实测队列在开局 1 秒内从 0 跳到 8 就停住),那一下只能逐帧看。
		_netstat_trace = ua.has("--netstat-trace")
	if not _netstat and not _netstat_trace:
		return
	if _netstat_trace:
		_netstat_trace_f += 1
		if _netstat_trace_f <= 600:
			var tparts: Array[String] = []
			for role in pending:
				tparts.append("%d=%d" % [role, (pending[role] as Array).size()])
			print("[trc] f=%d state=%d q={%s}" % [_netstat_trace_f, round_state, ", ".join(tparts)])
		if not _netstat:
			return
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var parts: Array[String] = []
	var caps: Array[String] = []
	var drops: Array[String] = []
	var peers: Array[String] = []
	for role in pending:
		parts.append("%d=%d" % [role, (pending[role] as Array).size()])
		caps.append("%d=%d" % [role, PacketInputSource.adapted_cap(int(_q_peak.get(role, 0)))])
		drops.append("%d=%d" % [role, int(_q_drops.get(role, 0))])
		peers.append("%d=%d/%d" % [role, int(st_map.get(role, 0)), int(ct_map.get(role, 0))])
	print("[netstat-srv] 待消费队列(条记录) %s | 抖动上限 %s | 累计丢弃 %s | 客户端 st/ct %s" % [
			", ".join(parts), ", ".join(caps), ", ".join(drops), ", ".join(peers)])


func _diag_tick(pending: Dictionary, delta: float) -> void:
	if not NetDiag.enabled():
		return
	_diag_acc += delta
	if _diag_acc < 1.0:
		return
	_diag_acc = 0.0
	for role in pending:
		NetDiag.log_metric("queue", {
			"role": int(role),
			"depth": (pending[role] as Array).size(),
			"cap": PacketInputSource.adapted_cap(int(_q_peak.get(role, 0))),
			"peak": int(_q_peak.get(role, 0)),
			"drops": int(_q_drops.get(role, 0)),
		})
