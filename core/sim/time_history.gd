class_name TimeHistory
extends RefCounted

enum Sample { COMMIT, TIME, ACTOR, PROJECTILES, ENVIRONMENT }
enum State { TIME, SINCE_SAMPLE, REWOUND, SAMPLES }

var time := 0.0
var rewound := -1.0
var _since_sample := 0.0
var _samples: Array = []
var _seconds: float

func _init(seconds: float) -> void:
	_seconds = seconds

func capture() -> Array:
	return [time, _since_sample, rewound, _samples]

func restore(values: Array) -> void:
	time = values[State.TIME]
	_since_sample = values[State.SINCE_SAMPLE]
	rewound = values[State.REWOUND]
	_samples = values[State.SAMPLES]

func oldest_time() -> float:
	return time if _samples.is_empty() else _samples[0][Sample.TIME]

func can_rewind() -> bool:
	return not _samples.is_empty() and (rewound >= 0.0 or time > oldest_time())

func record(delta: float, at: int, sample: Callable) -> void:
	rewound = -1.0
	time += delta
	_since_sample += delta
	if _since_sample < TimeParams.SNAP_INTERVAL:
		return
	_since_sample = 0.0
	var values: Array = sample.call()
	if not _samples.is_empty():
		var previous: Array = _samples.back()
		if values[0] == previous[Sample.ACTOR]:
			values[0] = previous[Sample.ACTOR]
		_share_rows(values[1], previous[Sample.PROJECTILES])
		if values.size() == 3:
			_share_rows(values[2], previous[Sample.ENVIRONMENT])
	var first := 0
	while first < _samples.size() and _samples[first][Sample.TIME] < time - _seconds:
		first += 1
	# 已提交检查点和编解码基准共享这里的不可变记录。
	_samples = _samples.slice(first)
	_samples.append([at, time] + values)

func backward(delta: float) -> Array:
	if rewound < 0.0:
		rewound = 0.0
		_since_sample = 0.0
	var target := maxf(oldest_time(), time - TimeParams.rewind_delta(rewound, delta))
	rewound += time - target
	time = target
	var end := _samples.size()
	while _samples[end - 1][Sample.TIME] > time:
		end -= 1
	if end != _samples.size():
		_samples = _samples.slice(0, end)
	return _samples.back()

func oldest_environment() -> Dictionary:
	return _samples[0][Sample.ENVIRONMENT] if not _samples.is_empty() else {}

static func _share_rows(rows: Dictionary, previous: Dictionary) -> void:
	for id in rows:
		if not previous.has(id):
			continue
		var old: Variant = previous[id]
		if rows[id] == old:
			rows[id] = old
		elif old is Dictionary and rows[id] is Dictionary:
			_share_rows(rows[id], old)
