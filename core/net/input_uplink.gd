class_name InputUplink
extends RefCounted


var _state: ClientState = null

var seq := 0
var have_prev_seq := false
var prev_sent_seq := 0
var _pending_pkt: Dictionary = {}

var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_prev_rb := 0
var _netstat_prev_ea := 0
var _netstat_prev_er := 0
var _last_ack := 0
var _netstat_steps := 0


func bind(state: ClientState) -> void:
	_state = state


func begin_tick() -> void:
	seq += 1


func submit(tick_rec: Dictionary, aim: Vector2) -> void:
	if _state._rollback != null:
		_state._rollback.note_input(seq, tick_rec)
	prev_sent_seq = seq
	have_prev_seq = true
	_pending_pkt = tick_rec


# 本 tick 的输入包上行(逐字搬自宿主 send_now 分支)。★ 只有真发得出去时才发:离场三条路都会先 NetBus.stop(),
# 中间一两帧 rpc_id 会打引擎错误(no multiplayer peer is active);预测与记账照常走完(seq 照增),重连会重建 C2 状态。
func take_packet() -> void:
	if _pending_pkt.is_empty():
		return
	var pkt: Dictionary = _pending_pkt
	_pending_pkt = {}
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pkt))
	


# 本人包回带的 ack 记账口(逐字搬自宿主 _on_snapshot_own 的闸);返回 false = 这条 ack 必须丢掉。
# ★ 跨纪元残留必丢:ack > seq 只可能是上一个 seq 空间的包,抬进 rollback 会让之后所有真实 ack 全丢(实测 ~9s 哑火)。
func accept_ack(ack: int) -> bool:
	if ack > seq:
		return false
	_last_ack = ack
	return true


func reset_epoch() -> void:
	seq = 0
	have_prev_seq = false
	prev_sent_seq = -1
	_pending_pkt = {}


# 网络统计读数(逐字搬自宿主 _netstat_tick):开关懒查一次(宿主没有 _ready ⇒ 不能放进 _ready)。
# 本函数每物理步调一次 ⇒ 两次打印之间的调用次数 = 物理步/秒,显著高于渲染帧率即物理追赶(会成串发输入包)。
func netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		_netstat = OS.get_cmdline_user_args().has("--netstat")
	if not _netstat:
		return
	_netstat_steps += 1
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var gap := seq - _last_ack
	var lag_ms := float(gap) * (1000.0 / 60.0) * float(PacketInputSource.TICKS_PER_RECORD)
	var ping := NetBus.ping_ms
	var rb := 0
	var ea := 0
	var er := 0
	if _state._rollback != null:
		rb = int(_state._rollback.rollback_count())
		ea = int(_state._rollback.event_aligns())
		er = int(_state._rollback.event_rejects())
	var where := Vector2.ZERO
	if _state._local != null and is_instance_valid(_state._local):
		where = (_state._local as Node2D).global_position
	var snap := NetBus.snap_stats()
	var wl := int(snap["world_lost"])
	var ol := int(snap["own_lost"])
	print("[netstat] seq=%d ack=%d gap=%d(滞后 %.0fms) | ping=%dms | 扣网后积压≈%.0fms | 回滚累计=%d (+%d/s) | 事件对齐=%d(+%d/s) 拒绝=%d(+%d/s) | 世界包 rx=%d 丢=%d(≈%d%%) | 本人包 rx=%d 丢=%d(≈%d%%) | pos=(%.0f,%.0f) | 物理步/秒=%d 渲染fps=%d"
			% [seq, _last_ack, gap, lag_ms, ping, lag_ms - float(ping), rb, rb - _netstat_prev_rb,
			ea, ea - _netstat_prev_ea, er, er - _netstat_prev_er,
			int(snap["world_rx"]), wl, NetMetrics.loss_pct(int(snap["world_rx"]), wl),
			int(snap["own_rx"]), ol, NetMetrics.loss_pct(int(snap["own_rx"]), ol),
			where.x, where.y, _netstat_steps, Engine.get_frames_per_second()])
	_netstat_steps = 0
	_netstat_prev_rb = rb
	_netstat_prev_ea = ea
	_netstat_prev_er = er
