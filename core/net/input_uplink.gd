class_name InputUplink
extends RefCounted

# 输入上行组合件(2026-10-30 从 PvpMatchClient 拆出;S-17 第一刀):seq / 60Hz 逐 tick 发包 / ack 记账 / netstat。

var _client: Node = null

var seq := 0             # 本地每 tick 单调的输入序号(60Hz 真输入;服务器每 tick 消费一条记录并回带 ack)
var have_prev_seq := false
var prev_sent_seq := 0
var _pending_pkt: Dictionary = {}   # 本 tick 待发的记录(60Hz:当 tick 就发)

# ── 网络统计读数(默认关;开关 -- --netstat,必须写在 -- 之后):gap = seq − 最后 ack;ping = NetBus.ping_ms;积压 = gap×16.7ms − ping;回滚 = rollback_count() 每秒增量(恒 0 也可能是哑火)。
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_prev_rb := 0
var _netstat_prev_ea := 0    # 事件对齐累计(上一次打印时的值,算 +N/s)
var _netstat_prev_er := 0    # 事件拒绝累计
var _last_ack := 0
var _netstat_steps := 0     # 两次打印之间的物理步数(=物理步/秒,因为本函数每物理步调一次)


func bind(client: Node) -> void:
	_client = client


# 每物理 tick 第一步(宿主在 C2 预步之后调):分配本 tick 的 seq(60Hz,每 tick 一包)。
func begin_tick() -> void:
	seq += 1


# 本 tick 采完样 → 预测历史记账 + 60Hz 逐 tick 发包;tick_rec = PacketInputSource.pack_record(...) 的产物。
func submit(tick_rec: Dictionary, aim: Vector2) -> void:
	if _client._rollback != null:
		_client._rollback.note_input(seq, tick_rec)
	prev_sent_seq = seq
	have_prev_seq = true
	# 60Hz:本 tick 的这条记录本 tick 就发(不再等下一 tick 合包 ⇒ 服务器收到的输入最多旧 1 个 tick)。
	_pending_pkt = tick_rec


# 本 tick 的输入包上行(逐字搬自宿主 send_now 分支)。★ 只有真发得出去时才发:离场三条路都会先 NetBus.stop(),
# 中间一两帧 rpc_id 会打引擎错误(no multiplayer peer is active);预测与记账照常走完(seq 照增),重连会重建 C2 状态。
func take_packet() -> void:
	if _pending_pkt.is_empty():
		return
	var pkt: Dictionary = _pending_pkt
	_pending_pkt = {}
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pkt))   # 28 B/包(一条 tick 记录;60Hz)
	


# 本人包回带的 ack 记账口(逐字搬自宿主 _on_snapshot_own 的闸);返回 false = 这条 ack 必须丢掉。
# ★ 跨纪元残留必丢:ack > seq 只可能是上一个 seq 空间的包,抬进 rollback 会让之后所有真实 ack 全丢(实测 ~9s 哑火)。
func accept_ack(ack: int) -> bool:
	if ack > seq:
		return false
	_last_ack = ack          # 网络统计读数用(诊断,默认关)
	return true


# 重连成功后重置输入上行纪元(seq 归零 + 流水线作废,与初始一致)。★ _last_ack / _netstat_* 刻意不重置(原实现如此)。
func reset_epoch() -> void:
	seq = 0
	have_prev_seq = false
	prev_sent_seq = -1
	_pending_pkt = {}          # 旧 seq 空间的待发记录作废(否则会把断线前的输入发给服务器)


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
	if _client._rollback != null:
		rb = int(_client._rollback.rollback_count())
		ea = int(_client._rollback.event_aligns())
		er = int(_client._rollback.event_rejects())
	var where := Vector2.ZERO
	if _client._local != null and is_instance_valid(_client._local):
		where = (_client._local as Node2D).global_position
	# 下行丢包估计:world_lost 涨而 ping 稳 = 链路丢包,不是服务器慢(口径见 NetMetrics.snapshot_loss)。
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
