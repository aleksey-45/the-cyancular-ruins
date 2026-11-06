extends RefCounted

const TICKS_PER_SEC := 60.0
const TICK_MS := 1000.0 / 60.0
const WINDOW := 8
const DRIFT_SLACK := 1.5
const DRIFT_MAX := 0.10
const DRIFT_GAIN := 0.25
const DEPTH_COMP_MAX := 4.0

var render_tick := 0.0

var _playout := 0
var _local_ms := 0.0
var _offsets: Array[float] = []
var _o_min := 0.0
var _o_max := 0.0
var _started := false


func _init(playout_ticks: int) -> void:
	_playout = maxi(0, playout_ticks)


func on_snapshot(tick: int) -> void:
	var o := _local_ms - float(tick) * TICK_MS
	if not _started:
		_offsets = [o]
		_o_min = o
		_o_max = o
		_started = true
		render_tick = target_tick()
		return
	_offsets.append(o)
	while _offsets.size() > WINDOW:
		_offsets.pop_front()
	_o_min = _offsets[0]
	_o_max = _offsets[0]
	for v in _offsets:
		_o_min = minf(_o_min, v)
		_o_max = maxf(_o_max, v)


## 深度补偿:窗口展布的 1.5 倍(系数实测选的:k=0.5 时单帧最大位移 10.0px 超闸 8.0;光用 o_min 会让有效缓冲比名义 playout 更浅)。
func _depth_comp() -> float:
	if _offsets.size() < 2:
		return 0.0
	return clampf(roundf((_o_max - _o_min) / TICK_MS * 1.5), 0.0, DEPTH_COMP_MAX)


func target_tick() -> float:
	return (_local_ms - _o_min) / TICK_MS - float(_playout) - _depth_comp()


## 每帧推进一步(delta = 渲染帧间隔,秒)。★ 单调性由步长恒 1 ± DRIFT_MAX > 0 保证。
func advance(delta: float) -> void:
	if not _started:
		return
	_local_ms += delta * 1000.0
	var err := target_tick() - render_tick
	var corr := 0.0
	if absf(err) > DRIFT_SLACK:
		corr = clampf((err - signf(err) * DRIFT_SLACK) * DRIFT_GAIN, -DRIFT_MAX, DRIFT_MAX)
	render_tick += (1.0 + corr) * delta * TICKS_PER_SEC
