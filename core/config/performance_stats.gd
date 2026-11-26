class_name PerformanceStats
extends RefCounted

# 统计数组在开始采样前分配，主线程在每次采样时直接更新其中的数值。

enum {
	NETWORK_POLL, NETWORK_DISPATCH, SERVER_TICK, SERVER_SIMULATION, WORLD_CAPTURE, STATE_PREPARE,
	STATE_ENCODE, STATE_FANOUT, TRANSPORT_SEND, CLIENT_AUTHORITY, CLIENT_TICK, CLIENT_PRESENT,
	REPLAY, ACTOR_STEP, PROJECTILE_STEP, COMBAT_STEP, HISTORY_SAVE, TERRAIN_COMMIT,
	CALLBACK_INTERVAL, PHYSICS_TICKS, REPLAY_TICKS, PHYSICS_MOTION, PHYSICS_RAY, PHYSICS_SHAPE,
	COUNT,
}
enum { SAMPLES, MEAN, MAXIMUM, TOTAL, OVER_BUDGET }

const TIME_BOUNDS := [100, 250, 500, 1000, 2000, 4000, 8000, 16667, 33334, 66667]
const COUNT_BOUNDS := [0, 1, 2, 4, 8, 16, 32, 64, 128, 256]
# 每个指标使用一行数组。以下常量给出样本数、累计值、最大值等统计量在行内的索引。
const ROW_COUNT := 0
const ROW_SUM := 1
const ROW_MAX := 2
const ROW_MAX_AT := 3
const ROW_OVER := 4
const ROW_HIST := 5

const NAMES := [
	"network_poll", "network_dispatch", "server_tick", "server_simulation",
	"world_capture", "state_prepare", "state_encode_peer", "state_fanout", "transport_send",
	"client_authority", "client_tick", "client_present", "replay",
	"actor_step", "projectile_step", "combat_step", "history_save", "terrain_commit",
	"callback_interval", "physics_ticks_per_frame", "replay_ticks_per_frame",
	"physics_motion", "physics_ray", "physics_shape",
]

static var _enabled := false
static var _last_frame := 0
static var _physics_ticks := 0
static var _replay_ticks := 0
static var _pending: Dictionary = _new_window()
static var _published: Dictionary = _new_window()
static var _total: Dictionary = _new_window()
static var _correction_n := 0
static var _correction_sum := 0.0
static var _correction_max := 0.0
static var _corrections: Array[Dictionary] = []
static var _correction_reasons := {}

static func reset_correction_stats() -> void:
	_correction_n = 0
	_correction_sum = 0.0
	_correction_max = 0.0
	_corrections.clear()
	_correction_reasons.clear()

static func record_correction(role: int, at: int, simulated: int, reason: String, distance: float) -> void:
	_correction_n += 1
	_correction_sum += distance
	_correction_max = maxf(_correction_max, distance)
	var entry: Array = _correction_reasons.get_or_add(reason, [0, 0.0])
	entry[0] += 1
	entry[1] += distance
	_corrections.append({"t": at, "sim": simulated, "f": reason, "d": distance,
		"role": role, "ms": Time.get_ticks_msec(), "pf": Engine.get_physics_frames()})

static func take_correction_samples() -> Array:
	var samples := _corrections
	_corrections = []
	return samples

static func corr_stats() -> Dictionary:
	return {"n": _correction_n, "sum": _correction_sum, "max": _correction_max, "reasons": _correction_reasons.duplicate()}

static func _now() -> int:
	return Time.get_ticks_usec()

static func is_tick_count(metric: int) -> bool:
	return metric in [PHYSICS_TICKS, REPLAY_TICKS]

static func _new_window() -> Dictionary:
	var metrics: Array = []
	metrics.resize(COUNT)
	for i in COUNT:
		var buckets := PackedInt64Array()
		buckets.resize((COUNT_BOUNDS if is_tick_count(i) else TIME_BOUNDS).size() + 1)
		metrics[i] = [0, 0, 0, 0, 0, buckets]
	return {"started": 0, "ended": 0, "metrics": metrics}

static func _add(row: Array, value: int, count_metric: bool, at: int) -> void:
	if row[ROW_COUNT] == 0 or value > row[ROW_MAX]:
		row[ROW_MAX_AT] = at
	row[ROW_COUNT] += 1
	row[ROW_SUM] += value
	if value > row[ROW_MAX]:
		row[ROW_MAX] = value
	if not count_metric and value > 16667:
		row[ROW_OVER] += 1
	var bounds: Array = COUNT_BOUNDS if count_metric else TIME_BOUNDS
	var bin := 0
	while bin < bounds.size() and value > int(bounds[bin]):
		bin += 1
	row[ROW_HIST][bin] += 1

static func set_enabled(enabled: bool) -> void:
	if _enabled == enabled:
		return
	_enabled = enabled
	reset()

static func is_enabled() -> bool:
	return _enabled

static func reset() -> void:
	_pending = _new_window()
	_published = _new_window()
	_total = _new_window()
	_last_frame = 0
	_physics_ticks = 0
	_replay_ticks = 0
	var now := _now()
	_total["started"] = now
	_pending["started"] = now

static func begin() -> int:
	return _now() if _enabled else 0

static func end(metric: int, started: int) -> void:
	if _enabled and started > 0:
		observe(metric, maxi(0, _now() - started))

static func observe(metric: int, value: int) -> void:
	if not _enabled or metric < 0 or metric >= COUNT or value < 0:
		return
	var count_metric := is_tick_count(metric)
	var pending_row: Array = _pending["metrics"][metric]
	var total_row: Array = _total["metrics"][metric]
	var at := 0
	if pending_row[ROW_COUNT] == 0 or value > pending_row[ROW_MAX] \
			or total_row[ROW_COUNT] == 0 or value > total_row[ROW_MAX]:
		at = _now()
	_add(pending_row, value, count_metric, at)
	_add(total_row, value, count_metric, at)

static func physics_tick() -> void:
	if _enabled:
		_physics_ticks += 1

static func replayed(ticks: int) -> void:
	if _enabled:
		_replay_ticks += maxi(0, ticks)

static func frame_boundary() -> void:
	if not _enabled:
		return
	var at := _now()
	if _last_frame > 0:
		observe(CALLBACK_INTERVAL, at - _last_frame)
	observe(PHYSICS_TICKS, _physics_ticks)
	observe(REPLAY_TICKS, _replay_ticks)
	_last_frame = at
	_physics_ticks = 0
	_replay_ticks = 0

static func publish() -> void:
	if not _enabled:
		return
	_pending["ended"] = _now()
	_published = _pending
	_pending = _new_window()
	_pending["started"] = _published["ended"]

static func read(metric: int, statistic: int) -> float:
	if metric < 0 or metric >= COUNT:
		return 0.0
	var sample: Array = _published["metrics"][metric]
	match statistic:
		SAMPLES:
			return float(sample[ROW_COUNT])
		MEAN:
			return float(sample[ROW_SUM]) / float(sample[ROW_COUNT]) if sample[ROW_COUNT] else 0.0
		MAXIMUM:
			return float(sample[ROW_MAX])
		TOTAL:
			return float(sample[ROW_SUM])
		OVER_BUDGET:
			return float(sample[ROW_OVER])
	return 0.0

static func snapshot(total: bool) -> Dictionary:
	var window: Dictionary = _total if total else _published
	var metrics := {}
	for i in COUNT:
		var sample: Array = window["metrics"][i]
		var row := {}
		row["unit"] = "ticks" if is_tick_count(i) else "us"
		row["samples"] = sample[ROW_COUNT]
		row["sum"] = sample[ROW_SUM]
		row["max"] = sample[ROW_MAX]
		row["max_at_uptime_us"] = sample[ROW_MAX_AT]
		row["over_16667_us"] = sample[ROW_OVER]
		row["histogram"] = (sample[ROW_HIST] as PackedInt64Array).duplicate()
		metrics[NAMES[i]] = row
	var result := {}
	result["enabled"] = _enabled
	result["window_us"] = duration_us(total)
	result["storage_bytes"] = storage_bytes()
	result["time_bucket_upper_us"] = PackedInt64Array(TIME_BOUNDS)
	result["count_bucket_upper"] = PackedInt64Array(COUNT_BOUNDS)
	result["metrics"] = metrics
	return result

static func duration_us(total := false) -> int:
	var window := _total if total else _published
	var started: int = window["started"]
	var ended: int = _now() if total else int(window["ended"])
	return maxi(0, ended - started) if started else 0

static func storage_bytes() -> int:
	# 分别计算当前采样、上一次发布的结果和累计结果。每行含五项统计量和十一个直方图区间。
	return 3 * COUNT * (5 * 8 + (TIME_BOUNDS.size() + 1) * 8) + 32
