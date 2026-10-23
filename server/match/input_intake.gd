class_name InputIntake
extends RefCounted

# 服务器输入队列(纯搬移自 MatchHost,行为零变化):入队 + 有界丢包 + 抖动包络 + 1Hz 队列诊断。
# ★ 队列本体不住这里:_pending_input 住 MatchState(快照 match_snapshot 要按 role 读深度),本模块只写它;
# 抖动包络 / 累计丢弃是纯诊断读数,除本文件的诊断外没有读者,故收在这里。
# ★ 上限的判据住 PacketInputSource(adapted_cap / push_pending):不住这里也不住 MatchHost,因为那条判据要能用最便宜的
# `-s` 冒烟跑 —— MatchHost 引用 NetBus 自动加载 ⇒ 冒烟加载不了它。★ 服务端自述 ρ≈1、开局有「1 秒内 0→8」的突刺;无界 ⇒ 积压不可恢复。

var _q_peak: Dictionary = {}   # role -> 最近「一 tick 到过几包」的原始深度(丢包之前),每 tick 衰减 1
var _q_drops: Dictionary = {}  # role -> 累计被丢弃的**陈旧**包数(诊断;丢包=服务器跳过一格输入)
var _diag_acc := 0.0           # 结构化诊断(--diag)的 1Hz 采样累加;默认关时下面整段直接返回

var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_trace := false     # 逐帧队列追踪(`--netstat-trace`,前 600 tick)
var _netstat_trace_f := 0


# ★ 清队列与复位抖动包络必须一起做:只清队列 ⇒ 旧包络把上限继续顶在高位,新纪元开局就白带一层陈旧延迟。
func reset(pending: Dictionary, role: int) -> void:
	pending[role] = []
	_q_peak.erase(role)
	_q_drops.erase(role)


# 缓冲本帧到达的包,按 seq 序 FIFO,每物理 tick 消费一个 ⇒ 服务器权威模拟与客户端「重放未确认输入」1:1 同序(C2 rollback 需要)。
# ★ 入队走 push_pending():有界,且丢包时保住边沿。★ 上限跟着实测抖动包络走(一 tick 到几包就留几包 +1 余量,包络每 tick 衰减 1)
# ⇒ 网络一安静上限自己缩回去,把堆着的陈旧包释放掉(丢的永远是最旧那包,边沿并入下一包)。没有这一步就是 ρ=1 的零漂移随机游走:顶上去就永远停在那儿。
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
func tick(pending: Dictionary, delta: float, round_state: int) -> void:
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
	for role in pending:
		parts.append("%d=%d" % [role, (pending[role] as Array).size()])
		caps.append("%d=%d" % [role, PacketInputSource.adapted_cap(int(_q_peak.get(role, 0)))])
		drops.append("%d=%d" % [role, int(_q_drops.get(role, 0))])
	print("[netstat-srv] 待消费队列(包) %s | 抖动上限 %s | 累计丢弃 %s" % [
			", ".join(parts), ", ".join(caps), ", ".join(drops)])


# 结构化诊断(--diag,默认关):1Hz 采样每 role 的队列深度 / 抖动上限 / 累计丢弃。
# ★ 与 --netstat 同源但**不依赖它**:--netstat 是人读的一行,这里要的是可解析、可与客户端 snap_gap/rollback
#   按事件对齐的时间轴。两处读数必须同源(_q_peak/_q_drops),别各算一份。默认关时首行即返回,零开销。
func _diag_tick(pending: Dictionary, delta: float) -> void:
	if not NetDiag.enabled():
		return
	_diag_acc += delta
	if _diag_acc < 1.0:
		return
	_diag_acc = 0.0
	for role in pending:
		NetDiag.log_event("queue", {
			"role": int(role),
			"depth": (pending[role] as Array).size(),
			"cap": PacketInputSource.adapted_cap(int(_q_peak.get(role, 0))),
			"peak": int(_q_peak.get(role, 0)),
			"drops": int(_q_drops.get(role, 0)),
		})
