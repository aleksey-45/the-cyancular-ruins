class_name InputScheduler
extends InputBuffer

# 每个远端席位持有一份输入缓冲和时序统计。快照把 feedback 原样传给预测时钟。
const HZ := 60
const BLOCK := 15
const WINDOW := 8 * HZ
const START_MARGIN := 2
const JITTER_BUDGET := 3

var feedback := PackedByteArray()
var _reported := 0
var _next_update := 0
var _latest := 0
# 按输入序号记录原定目标帧、持续输入的首次可用帧和从收包到分发的微秒数。仅收到单次动作时，可用帧为 0。
var _samples: Dictionary[int, Vector3i] = {}

func reset(new_epoch: int) -> void:
	super(new_epoch)
	feedback = PackedByteArray()
	_reported = 0
	_next_update = 0
	_latest = 0
	_samples.clear()

# 最新持续输入超出服务器时序窗口时返回 false，由调用方重置输入版本。
func submit(packet: Array, tick: int, received_us := -1, dispatch_us := -1) -> bool:
	var available := tick + 1
	if dispatch_us < 0:
		dispatch_us = Time.get_ticks_usec()
	var queued_us := clampi(dispatch_us - received_us, 0, 1000000 / HZ - 1) if received_us >= 0 else 0
	var newest := _latest
	var newest_target := 0
	for row: Array in packet[InputBuffer.PACKET_FRAMES]:
		var seq: int = row[InputBuffer.SEQ]
		if row[InputBuffer.EPOCH] == epoch and seq > newest:
			newest = seq
			newest_target = row[InputBuffer.TARGET_TICK]
	if newest > _latest and (newest > tick + InputBuffer.FUTURE_TICKS or absi(newest_target - tick) > InputBuffer.FUTURE_TICKS):
		return false
	var accepted := [[], []]
	for group in [InputBuffer.PACKET_FRAMES, InputBuffer.PACKET_ACTIONS]:
		for row: Array in packet[group]:
			var seq: int = row[InputBuffer.SEQ]
			var target: int = row[InputBuffer.TARGET_TICK]
			if row[InputBuffer.EPOCH] != epoch or seq <= 0 or seq > tick + InputBuffer.FUTURE_TICKS \
					or target <= 0 or target > tick + InputBuffer.FUTURE_TICKS or seq < _latest - WINDOW:
				continue
			var first: Vector3i = _samples.get(seq, Vector3i(target, 0, 0))
			if first.x != target:
				continue
			if group == InputBuffer.PACKET_FRAMES and first.y == 0:
				first.y = available
				first.z = queued_us
				_latest = maxi(_latest, seq)
			_samples[seq] = first
			accepted[group].append(row)
	push(accepted, tick)
	if _reported == 0 and _latest > 0:
		var seed := available - _latest + START_MARGIN
		_publish(_latest, seed, seed)
	if available >= _next_update:
		_next_update = available + BLOCK
		_update(available)
	return true

func _publish(sample: int, steady: float, recent: float, drift := 0.0) -> void:
	_reported = sample
	feedback = InputClock.pack_feedback(sample, steady, recent, drift)

static func _quantile(sorted: Array[float], fraction: float) -> float:
	return sorted[ceili(sorted.size() * fraction) - 1]

func _update(tick: int) -> void:
	# 给最近的序号留出冗余副本到达的时间，再按输入序号去重统计。
	var end := _latest - InputBuffer.REDUNDANCY
	for seq: int in _samples.keys():
		if seq < end - WINDOW or _samples[seq].x < tick - WINDOW - InputBuffer.FUTURE_TICKS:
			_samples.erase(seq)
	if end - BLOCK / 2 <= _reported:
		return
	var measured := 0
	var consecutive := 0
	var centers: Array[float] = []
	var blocks: Array[Array] = []
	for start in range(end - WINDOW + 1, end + 1, BLOCK):
		var block: Array[float] = []
		for seq in range(maxi(1, start), start + BLOCK):
			var first: Vector3i = _samples.get(seq, Vector3i.ZERO)
			if first.y > 0 and first.y <= tick:
				# 扣除不足一帧的分发排队时间。向上取整可还原实际可用帧，跨帧积压仍计入延迟。
				block.append(first.y - seq - first.z * (HZ / 1000000.0))
		if block.size() <= BLOCK / 2:
			consecutive = 0
			continue
		consecutive += 1
		measured = start + BLOCK / 2
		block.sort()
		var center := _quantile(block, 0.5)
		centers.append(center)
		blocks.append(block)
	if measured <= _reported or consecutive == 0:
		return
	var sustained := centers.slice(-mini(3, consecutive))
	sustained.sort()
	var level := _quantile(sustained, 0.5)
	var slope := 0.0
	if consecutive >= 6:
		var mid := (centers[-3] + centers[-4]) / 2.0
		var older := mid - (centers[-5] + centers[-6]) / 2.0
		var newer := (centers[-1] + centers[-2]) / 2.0 - mid
		if older * newer > 0.0 and minf(absf(older), absf(newer)) > 0.1:
			slope = signf(newer) * minf(absf(older), absf(newer)) / (2 * BLOCK)
			level = centers[-1]
	# 选取中位延迟相近的时间段，并保留段内突发的延迟和分发停顿。
	var offsets: Array[float] = []
	for i in centers.size():
		var center := centers[i]
		if i > 0 and i + 1 < centers.size():
			center = clampf(center, minf(centers[i - 1], centers[i + 1]), maxf(centers[i - 1], centers[i + 1]))
		if absf(center - level) <= 0.5 or i == centers.size() - 1:
			offsets.append_array(blocks[i])
	offsets.sort()
	var target := minf(_quantile(offsets, 0.99), _quantile(offsets, 0.05) + JITTER_BUDGET)
	if slope != 0.0:
		target += level - _quantile(offsets, 0.5)
	_publish(measured, target, target + centers[-1] - level, slope)
