class_name InputClock
extends RefCounted

# 以采样间隔为时间单位。稳态误差的半衰期为 0.5 秒，短期偏移为 0.25 秒。
const GAIN := 1.0 - 0.5 ** (1.0 / 30.0)
const PERSISTENCE := 0.5 ** (1.0 / 15.0)
const PREVIEW_WEIGHT := GAIN * PERSISTENCE / (1.0 - (1.0 - GAIN) * PERSISTENCE)
const SPACING := 6
const FEEDBACK_VERSION := 1

var _end := 0
var _offset := 0.0
var _observed_seq := 0
var _steady := 0.0
var _recent := 0.0
var _drift := 0.0
var _sampled := false
var _last_adjustment := -SPACING
var _direction := 0
var _held := 0

# 服务器和客户端的时序模块共用此格式，快照直接携带这些字节。
static func pack_feedback(sample: int, steady: float, recent: float, drift := 0.0) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(21)
	bytes.encode_u32(0, sample)
	bytes.encode_double(4, steady)
	bytes.encode_float(12, recent - steady)
	bytes.encode_float(16, drift)
	bytes[20] = FEEDBACK_VERSION
	return bytes

func _observe(feedback: PackedByteArray) -> void:
	if feedback.size() != 21 or feedback[20] != FEEDBACK_VERSION or feedback.decode_u32(0) <= _observed_seq:
		return
	var steady := feedback.decode_double(4)
	var recent := steady + feedback.decode_float(12)
	var drift := feedback.decode_float(16)
	if not is_finite(steady) or not is_finite(recent) or not is_finite(drift) \
			or absf(steady) > 0x7fffffff or absf(recent) > 0x7fffffff:
		return
	_observed_seq = feedback.decode_u32(0)
	_steady = steady
	_recent = recent
	_drift = drift

func reset(at: int, seq: int, ping_ms: int, feedback: PackedByteArray) -> void:
	_observed_seq = 0
	_observe(feedback)
	# 缺少时序反馈时，按一次往返时延估算预测进度，并预留两帧余量。
	var first := seq + ceili(_steady) if _observed_seq > 0 else at + ceili(maxi(0, ping_ms) * 0.06) + 2
	_end = clampi(first, at, at + InputBuffer.FUTURE_TICKS - 1)
	_offset = float(_end - seq)
	_sampled = false
	_last_adjustment = seq - SPACING
	_direction = 0
	_held = 0

func synchronize(at: int, seq: int, feedback: PackedByteArray) -> void:
	_observe(feedback)
	if at > _end:
		_end = at
		_offset = float(at - seq)

# 目标帧在采样时确定。少推进一步时，本次输入仍排到下一模拟帧。
func sample(seq: int, input: Array) -> int:
	var direction := int(signf(input[ActorInput.AX]))
	var protect_edge: bool = input[ActorInput.PRESSED] != 0 or input[ActorInput.RELEASED] != 0 \
			or input[ActorInput.WINST] != 0 or direction != _direction or input[ActorInput.HELD] != _held
	_direction = direction
	_held = input[ActorInput.HELD]
	_sampled = true
	var normal := _end + 1
	var offset := normal - seq
	var correction := 0
	if _observed_seq > 0:
		var age := maxi(0, seq - _observed_seq)
		# 估计到 1 / GAIN 个采样间隔后的时钟偏移。外推最多一帧，反馈陈旧时逐渐衰减。
		var shift := clampf(_drift * (age + 1.0 / GAIN), -1.0, 1.0) * pow(PERSISTENCE, maxi(0, age - 30))
		var steady := ceili(_steady + shift)
		var excursion := (ceili(_recent + shift) - steady) * PREVIEW_WEIGHT * pow(PERSISTENCE, age)
		if (_offset - offset) * (steady + excursion - offset) <= 0.0:
			_offset = offset
		_offset = clampf(_offset, offset - 1.0, offset + 1.0)
		var ideal := _offset
		var errors := PackedFloat64Array()
		for i in SPACING:
			ideal += GAIN * (steady + excursion - ideal)
			excursion *= PERSISTENCE
			errors.append(ideal - offset)
			if i == 0:
				_offset = ideal
		correction = _choose_step(errors, seq - _last_adjustment, protect_edge)
	if correction != 0:
		_last_adjustment = seq
	_end = normal + correction
	return maxi(normal, _end)

static func _choose_step(errors: PackedFloat64Array, since: int, protect_edge: bool) -> int:
	# 两次调整至少间隔六次采样。在接下来六次采样中枚举增减一步的位置，使相位误差的平方和最小。
	# 从后往前遍历，同等代价时优先推迟调整。按键保护只检查已采集的当前输入。
	var correction := 0
	var sum := 0.0
	var best := 0.0
	for i in range(SPACING - 1, -1, -1):
		sum += errors[i]
		if since + i < SPACING:
			continue
		var direction := int(signf(sum))
		if i == 0 and direction < 0 and protect_edge:
			continue
		var cost := SPACING - i - 2.0 * absf(sum)
		if cost < best:
			best = cost
			correction = direction if i == 0 else 0
	return correction

func advance(delta: float, simulated: int, limit: int) -> int:
	if not _sampled:
		var elapsed := maxi(simulated, _end) - _end + roundi(delta * 60.0)
		_end += elapsed
		_offset += elapsed
	_sampled = false
	return clampi(_end, simulated, maxi(simulated, limit))
