extends Node

const MONITORS := [
	PerformanceStats.SERVER_TICK, PerformanceStats.STATE_ENCODE, PerformanceStats.STATE_FANOUT,
	PerformanceStats.NETWORK_DISPATCH, PerformanceStats.CLIENT_AUTHORITY, PerformanceStats.REPLAY,
	PerformanceStats.ACTOR_STEP, PerformanceStats.TERRAIN_COMMIT, PerformanceStats.PHYSICS_MOTION,
	PerformanceStats.PHYSICS_RAY, PerformanceStats.PHYSICS_SHAPE, PerformanceStats.CALLBACK_INTERVAL,
]
var _registered: Array[StringName] = []
var _next_publish := 0
var _console := false
var _summary_path := ""
var _trace_path := ""
var _trace = null

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_console = args.has("--perf")
	var at := args.find("--perf-summary")
	if at >= 0:
		if at + 1 < args.size() and not args[at + 1].begins_with("--"):
			_summary_path = args[at + 1]
		else:
			push_warning("--perf-summary 需要文件路径")
	at = args.find("--corr-trace")
	if at >= 0:
		if at + 1 < args.size() and not args[at + 1].begins_with("--"):
			_trace_path = args[at + 1]
		else:
			push_warning("--corr-trace 需要文件路径")
	# 只在命令行指定对应选项时采集数据，正常启动不计时。
	var enabled := (_console or not _summary_path.is_empty() or not _trace_path.is_empty()) and not args.has("--no-perf")
	PerformanceStats.set_enabled(enabled)
	if enabled:
		PerformanceStats.reset_correction_stats()
	if not _trace_path.is_empty():
		_trace = FileAccess.open(_trace_path, FileAccess.WRITE)
		if _trace == null:
			push_warning("无法写入校正追踪：%s" % _trace_path)
	set_process(enabled)
	set_physics_process(enabled)
	_next_publish = Time.get_ticks_usec() + 1000000
	if OS.is_debug_build():
		_monitor("Game/monitor_enabled", PerformanceStats.is_enabled)
		_monitor("Game/physics_ticks_per_frame_max", PerformanceStats.read.bind(PerformanceStats.PHYSICS_TICKS, PerformanceStats.MAXIMUM))
		_monitor("Game/replay_ticks_per_frame_max", PerformanceStats.read.bind(PerformanceStats.REPLAY_TICKS, PerformanceStats.MAXIMUM))
		for metric in MONITORS:
			_monitor("Game/%s_samples" % PerformanceStats.NAMES[metric], PerformanceStats.read.bind(metric, PerformanceStats.SAMPLES))
			_monitor("Game/%s_mean_us" % PerformanceStats.NAMES[metric], PerformanceStats.read.bind(metric, PerformanceStats.MEAN))
			_monitor("Game/%s_max_us" % PerformanceStats.NAMES[metric], PerformanceStats.read.bind(metric, PerformanceStats.MAXIMUM))

func _monitor(label: StringName, sample: Callable) -> void:
	Performance.add_custom_monitor(label, sample)
	_registered.append(label)

func _physics_process(_delta: float) -> void:
	PerformanceStats.physics_tick()

func _flush_correction_samples() -> void:
	var samples := PerformanceStats.take_correction_samples()
	if samples.is_empty():
		return
	if _trace != null:
		for sample in samples:
			_trace.store_line(JSON.stringify(sample))
		_trace.flush()
	else:
		print("PERF correction_samples=%s" % JSON.stringify(samples))

func _process(_delta: float) -> void:
	PerformanceStats.frame_boundary()
	var now := Time.get_ticks_usec()
	if now < _next_publish: return
	_next_publish = now + 1000000
	PerformanceStats.publish()
	_flush_correction_samples()
	if _console:
		print("PERF window_us=%d samples(tick/encode/replay)=%.0f/%.0f/%.0f us mean/max tick=%.0f/%.0f encode_peer=%.0f/%.0f replay=%.0f/%.0f callback_interval_max=%.0f" % [
				PerformanceStats.duration_us(), PerformanceStats.read(PerformanceStats.SERVER_TICK, PerformanceStats.SAMPLES),
				PerformanceStats.read(PerformanceStats.STATE_ENCODE, PerformanceStats.SAMPLES),
				PerformanceStats.read(PerformanceStats.REPLAY, PerformanceStats.SAMPLES),
				PerformanceStats.read(PerformanceStats.SERVER_TICK, PerformanceStats.MEAN), PerformanceStats.read(PerformanceStats.SERVER_TICK, PerformanceStats.MAXIMUM),
				PerformanceStats.read(PerformanceStats.STATE_ENCODE, PerformanceStats.MEAN), PerformanceStats.read(PerformanceStats.STATE_ENCODE, PerformanceStats.MAXIMUM),
				PerformanceStats.read(PerformanceStats.REPLAY, PerformanceStats.MEAN), PerformanceStats.read(PerformanceStats.REPLAY, PerformanceStats.MAXIMUM),
				PerformanceStats.read(PerformanceStats.CALLBACK_INTERVAL, PerformanceStats.MAXIMUM)])
		var corr := PerformanceStats.corr_stats()
		print("PERF correction n=%.0f max=%.1f reasons=%s" % [
				corr["n"], corr["max"], JSON.stringify(corr["reasons"])])

func _exit_tree() -> void:
	_flush_correction_samples()
	if _trace != null:
		_trace.close()
		_trace = null
	for label in _registered:
		Performance.remove_custom_monitor(label)
	if not _summary_path.is_empty():
		var file := FileAccess.open(_summary_path, FileAccess.WRITE)
		if file == null:
			push_warning("无法写入性能汇总：%s" % _summary_path)
			return
		var report := PerformanceStats.snapshot(true)
		report["pid"] = OS.get_process_id()
		report["headless"] = DisplayServer.get_name() == "headless"
		report["physics_ticks_per_second"] = Engine.physics_ticks_per_second
		report["max_fps"] = Engine.max_fps
		report["debug_build"] = OS.is_debug_build()
		report["correction"] = PerformanceStats.corr_stats()
		file.store_string(JSON.stringify(report))
