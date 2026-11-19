class_name InputScheduler
extends RefCounted

# 每个输入版本独享一份调度状态。快照只公布最近两段 [起始序号, 帧偏移]。
const UNBOUND := [0, 0, 0, 0]
const HZ := 60
const WINDOW := 8 * HZ
const START_MARGIN := 2
const INITIAL_NOTICE := 30
const HORIZON := 4 # 每秒一次决策，四步可遍历 P05 至 P05+3 的整个区间。
const MISS_BUDGET := 0.01
const CHANGE_MS := 12.0 # 每分钟每次改期折算 0.2 ms，即单个一秒决策阶段折算 12 ms。
const SNAPSHOT_INTERVAL := 2

# 客户端在预测器首次采用公告时取样。输入包重传同一个余量，直到状态快照确认。
class InstallFeedback:
	var epoch := -1
	var _start := 0
	var _margin := 0
	var _next := 0

	func install(version: int, plan: Array, last_sample: int, confirmed: bool) -> void:
		var start: int = plan[2]
		if epoch != version or start != _start:
			epoch = version
			_start = start
			_margin = clampi(start - last_sample, -128, 127)
			_next = last_sample + 1
		if confirmed:
			_next = -1

	func attach(packet: Array, seq: int) -> void:
		if _start > 0 and _next >= 0 and seq >= _next and not packet[InputBuffer.PACKET_FRAMES].is_empty():
			packet.append(Vector2i(_start, _margin))
			_next = seq + HZ / 4

var _segments: Array[Vector2i] = []
var _latest := 0
var _first_seq := 0
var _first: Dictionary[int, int] = {} # 采样序号 -> 首份副本最早可取用的权威帧
var _receipts: Dictionary[int, Array] = {} # 包内最新序号 -> [可用帧, 收包相位, 状态解码所需提前量]
var _notices: Array[Vector4i] = [] # [生效序号, 发出的提前量, 当时的解码提前量估计, 实际安装所需提前量]，末项 0 表示待回执。

func notice_confirmed() -> bool:
	return not _notices.is_empty() and _notices[-1].w > 0

func latest_input() -> int:
	return _latest

func announcement() -> Array:
	if _segments.is_empty():
		return UNBOUND
	var last := _segments[-1]
	if _segments.size() == 1:
		return [last.x, last.y, 0, 0]
	var previous := _segments[-2]
	return [previous.x, previous.y, last.x, last.y]

static func target(plan: Array, seq: int) -> int:
	if plan[0] == 0 or seq < plan[0]:
		return -1
	return seq + int(plan[3] if plan[2] > 0 and seq >= plan[2] else plan[1])

func _due(seq: int) -> int:
	for i in range(_segments.size() - 1, -1, -1):
		if seq >= _segments[i].x:
			return seq + _segments[i].y
	return -1

# 输入时钟跳出取用窗口时返回 false，由服务端开一个新版本并发回基线状态。
func submit(buffer: InputBuffer, packet: Array, tick: int, received_us: int, input_at_snapshot := 0) -> bool:
	var first_frame := 0
	var newest := 0
	for group in [InputBuffer.PACKET_FRAMES, InputBuffer.PACKET_ACTIONS]:
		for row: Array in packet[group]:
			var seq: int = row[InputBuffer.SEQ]
			if row[InputBuffer.EPOCH] == buffer.epoch and seq > 0 and seq <= tick + InputBuffer.FUTURE_TICKS:
				newest = maxi(newest, seq)
				if group == InputBuffer.PACKET_FRAMES and (first_frame == 0 or seq < first_frame):
					first_frame = seq
	if newest == 0:
		return true
	var available := tick + 1
	if _segments.is_empty():
		# 首包可能同时补发很早的按键边沿。按连续采样建立锚点。
		_first_seq = first_frame if first_frame > 0 else newest
		_segments.append(Vector2i(1, available + START_MARGIN - _first_seq))
	elif newest > _latest and absi(_due(newest) - tick) > InputBuffer.FUTURE_TICKS:
		return false
	var scheduled := [[], []]
	var frame_seq := 0
	for group in [InputBuffer.PACKET_FRAMES, InputBuffer.PACKET_ACTIONS]:
		for row: Array in packet[group]:
			var seq: int = row[InputBuffer.SEQ]
			var due := _due(seq)
			if seq > tick + InputBuffer.FUTURE_TICKS or row[InputBuffer.EPOCH] != buffer.epoch \
					or due < 0 or due > tick + InputBuffer.FUTURE_TICKS:
				continue
			var record := row.duplicate()
			record[InputBuffer.TARGET_TICK] = due
			scheduled[group].append(record)
			_latest = maxi(_latest, seq)
			if group == InputBuffer.PACKET_FRAMES and due >= tick - WINDOW:
				if not _first.has(seq):
					_first[seq] = available
				frame_seq = maxi(frame_seq, seq)
	if frame_seq > 0 and not _receipts.has(frame_seq):
		var progress := clampi(frame_seq - input_at_snapshot, 1, HZ) if input_at_snapshot > 0 else 0
		_receipts[frame_seq] = [available, received_us * (HZ / 1000000.0) - frame_seq, progress]
	if packet.size() > InputBuffer.PACKET_NOTICE:
		_accept_notice(packet[InputBuffer.PACKET_NOTICE], newest)
	buffer.push(scheduled, tick)
	return true

func _accept_notice(report: Vector2i, newest: int) -> void:
	# 回执绑定当前输入版本中的公告。重复、乱序或跨版本的输入不能重取样。
	if report.x - report.y > newest or report.x - report.y < 0:
		return
	for i in range(_notices.size() - 1, -1, -1):
		var sent := _notices[i]
		if sent.x == report.x:
			if sent.w == 0:
				sent.w = clampi(sent.y - report.y + 1, 1, HZ)
				_notices[i] = sent
			return

func _notice(network: int) -> int:
	var required := []
	for sent in _notices:
		var need := sent.w
		if need == 0:
			need = HZ
		elif sent.z > 0 and network > 0:
			# 保留这次实际安装超出当时网络估计的部分，换入当前网络估计。
			need += network - sent.z
		required.append(need)
	var notice := maxi(INITIAL_NOTICE, network + SNAPSHOT_INTERVAL)
	if not required.is_empty():
		notice = maxi(network, int(_rank(required, 1.0 - MISS_BUDGET))) + SNAPSHOT_INTERVAL
	return mini(HZ, notice)

static func _rank(values: Array, fraction: float) -> float:
	values.sort()
	return values[ceili(values.size() * fraction) - 1]

static func _median(values: Array) -> float:
	values.sort()
	var mid := values.size() >> 1
	return (float(values[mid]) + float(values[(values.size() - 1) >> 1])) * 0.5

# 对固定的经验分布，最优路径可以直接走向所访问的最低损失偏移，然后保持。
# 每个可达目的地至多四步。先最小化超预算的错过概率，再最小化等待与改期成本。
static func _best_step(values: Array, shift: float, previous: int, low: int, high: int) -> int:
	low = clampi(low, previous - HORIZON, previous + HORIZON)
	high = clampi(high, previous - HORIZON, previous + HORIZON)
	var first := mini(previous, low)
	var last := maxi(previous, high)
	var risks := PackedFloat64Array()
	var waits := PackedFloat64Array()
	var whole := floori(shift)
	var fraction := shift - whole
	var ordered := PackedInt64Array(values)
	ordered.sort()
	var wait_ms := 0.0
	for candidate in range(first, last + 1):
		var threshold := candidate - whole
		var through := ordered.bsearch(threshold, false) # 需要偏移 <= threshold 的样本数。
		var before := ordered.bsearch(threshold, true)
		var on_time := lerpf(through, before, fraction) / ordered.size()
		risks.append(maxf(0.0, 1.0 - on_time - MISS_BUDGET))
		waits.append(wait_ms)
		# 偏移再加一帧，原本准时的每个输入多等一帧。所有方案共有的起始等待可消去。
		wait_ms += on_time * (1000.0 / HZ)
	var best := previous
	var best_risk := INF
	var best_cost := INF
	for target_offset in range(low, high + 1):
		var at := previous
		var risk := 0.0
		var cost := CHANGE_MS * absi(target_offset - previous)
		for step in HORIZON:
			at += signi(target_offset - at)
			risk += risks[at - first]
			cost += waits[at - first]
		var same_risk := absf(risk - best_risk) < 1e-7
		var same_cost := absf(cost - best_cost) < 1e-7
		var less_motion := absi(target_offset - previous) < absi(best - previous)
		var cheaper := cost < best_cost - 1e-7 or (same_cost and less_motion)
		if risk < best_risk - 1e-7 or (same_risk and cheaper):
			best = target_offset
			best_risk = risk
			best_cost = cost
	return previous + signi(best - previous)

func update(tick: int) -> void:
	if _segments.is_empty() or tick % HZ != 0:
		return
	var start := tick - WINDOW + 1
	var recent := []
	for seq: int in _first.keys():
		var at := _first[seq]
		if at < start - InputBuffer.FUTURE_TICKS:
			_first.erase(seq)
		elif at <= tick and at > tick - 2 * HZ:
			recent.append(at - seq)
	var phases := [[], [], []]
	var decoded := []
	for seq: int in _receipts.keys():
		var entry := _receipts[seq]
		var at: int = entry[0]
		if at < start:
			_receipts.erase(seq)
		elif at <= tick:
			var period := 2 if at > tick - 30 else 1 if at > tick - HZ else 0
			phases[period].append(entry[1])
			if entry[2] > 0:
				decoded.append(entry[2])
	var previous := _segments[-1]
	if recent.is_empty() or _latest < previous.x:
		return
	var low := int(_rank(recent, 0.05))
	var high := low + 3
	var network := 0 if decoded.is_empty() else int(_rank(decoded, 1.0 - MISS_BUDGET))
	var notice := _notice(network)
	var window := WINDOW
	var shift := 0.0
	if phases[0].size() >= 90 and mini(phases[1].size(), phases[2].size()) >= 12:
		var now := _median(phases[2])
		var change := now - _median(phases[0])
		if absf(change) > 0.22:
			window = HZ
			var trend := now - _median(phases[1])
			if trend * change > 0:
				# 最近一秒样本中心到预计执行段中心相隔 1 秒再加公告提前量。
				shift = clampf(trend * (2.0 + 2.0 * notice / HZ), -1.0, 1.0)
	# 所有候选使用同一组已到期的序号。缺失样本在每个候选下都计为迟到。
	var end := mini(_latest, tick - maxi(previous.y, high) - 1)
	if end < _first_seq:
		return
	var values := []
	for seq in range(maxi(_first_seq, end - window + 1), end + 1):
		var at: int = _first.get(seq, tick + 1)
		values.append(at - seq if at <= tick else maxi(previous.y, high) + 2)
	var offset := _best_step(values, shift, previous.y, low, high)
	if offset != previous.y:
		var from_seq := _latest + notice
		_segments.append(Vector2i(from_seq, offset))
		_notices.append(Vector4i(from_seq, notice, network, 0))
		if _notices.size() > 100:
			_notices.pop_front()
	while _segments.size() > 2 and _segments[1].x + _segments[0].y < start:
		_segments.pop_front()
