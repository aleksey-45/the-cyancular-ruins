class_name InputUplink
extends RefCounted

# 输入上行组合件(2026-10-30 从 PvpMatchClient 拆出;S-17 第一刀):seq / 30Hz 节拍 / 流水线 / 发包 / ack 记账 / netstat。
# 形状是组合:宿主只留采样与 C2 预步,其余调 begin_tick() → submit(rec, aim) → take_packet();
# 另有 accept_ack(ack) / reset_epoch() / netstat_tick(delta);本类经 bind(client) 读宿主 _rollback / _local / _last_snap_tick。
# ★ 逐字不变量与细节见 docs/eng/netcode-input-uplink.md:seq 只在 reset_epoch 归零;30Hz 一包两条记录;ack > seq 必丢。

var _client: Node = null

var seq := 0             # 本地每 tick 单调的输入序号(60Hz 真输入;服务器每 tick 消费一条记录并回带 ack)
var have_prev_seq := false
var prev_sent_seq := 0
var _input_batch_phase := 1     # 1 = 本 tick 先攒、下一 tick 发包(首包即从 tick0+tick1 开始,不需要伪造 seq0)
var _prev_tick_rec: Dictionary = {}   # 流水线里"上一 tick 的记录",下一包作为低 tick 记录发出去
var _pending_pair: Dictionary = {}    # 本 tick 已组好、待 take_packet() 发出的包
var _send_now := false                # 本 tick 是否发包(由 begin_tick 定)

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


# 每物理 tick 第一步(宿主在 C2 预步之后调):推进 30Hz 节拍 + 分配本 tick 的 seq。
func begin_tick() -> void:
	_send_now = _input_batch_phase == 0
	_input_batch_phase = (_input_batch_phase + 1) % PacketInputSource.INPUT_BATCH_TICKS
	seq += 1


# 本 tick 采完样 → 预测历史记账 + 30Hz 流水线组包;tick_rec = PacketInputSource.pack_record(...) 的产物,aim 供 pack_pair 复用。
func submit(tick_rec: Dictionary, aim: Vector2) -> void:
	if _client._rollback != null:
		_client._rollback.note_input(seq, tick_rec)
	prev_sent_seq = seq
	have_prev_seq = true
	if _send_now:
		# 30Hz 发包 = [上一 tick, 本 tick] 两条记录(流水线;低 tick 记录由上一包之后补齐 ⇒ 服务器收到逐 tick 连续序列)。
		var lo: Dictionary = _prev_tick_rec if not _prev_tick_rec.is_empty() else tick_rec
		_pending_pair = PacketInputSource.pack_pair(lo, tick_rec, aim, _client._last_snap_tick,
				Engine.get_physics_frames())
	else:
		_prev_tick_rec = tick_rec


# 本 tick 的输入包上行(逐字搬自宿主 send_now 分支)。★ 只有真发得出去时才发:离场三条路都会先 NetBus.stop(),
# 中间一两帧 rpc_id 会打引擎错误(no multiplayer peer is active);预测与记账照常走完(seq 照增),重连会重建 C2 状态。
func take_packet() -> void:
	if not _send_now:
		return
	var pair: Dictionary = _pending_pair
	_pending_pair = {}
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pair))   # 42 B/包(含 2 条 tick 记录;P1 前 46)
	_prev_tick_rec = {}


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
	_input_batch_phase = 1     # 与初始一致:重连后第一包从 tick0+tick1 开始
	_prev_tick_rec = {}        # 旧 seq 空间的流水线记录作废(否则会把断线前的输入当低 tick 发给服务器)


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
