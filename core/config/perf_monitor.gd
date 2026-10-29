extends Node

const MONITORS := {
	"server_tick": NativePerformanceStats.SERVER_TICK, "state_encode_peer": NativePerformanceStats.STATE_ENCODE,
	"state_fanout": NativePerformanceStats.STATE_FANOUT, "network_dispatch": NativePerformanceStats.NETWORK_DISPATCH,
	"client_authority": NativePerformanceStats.CLIENT_AUTHORITY, "replay": NativePerformanceStats.REPLAY,
	"actor_step": NativePerformanceStats.ACTOR_STEP, "terrain_commit": NativePerformanceStats.TERRAIN_COMMIT,
	"callback_interval": NativePerformanceStats.CALLBACK_INTERVAL,
}
var _next_publish := 0
var _console := false
var _summary_path := ""

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	NativePerformanceStats.set_enabled(not args.has("--no-perf"))
	_console = args.has("--perf")
	var at := args.find("--perf-summary")
	if at >= 0:
		if at + 1 < args.size() and not args[at + 1].begins_with("--"):
			_summary_path = args[at + 1]
		else:
			push_warning("--perf-summary 需要文件路径")
	set_process(NativePerformanceStats.is_enabled())
	set_physics_process(NativePerformanceStats.is_enabled())
	_next_publish = Time.get_ticks_usec() + 1000000
	if OS.is_debug_build():
		Performance.add_custom_monitor("Game/monitor_enabled", NativePerformanceStats.is_enabled)
		Performance.add_custom_monitor("Game/physics_ticks_per_frame_max", NativePerformanceStats.read.bind(NativePerformanceStats.PHYSICS_TICKS, NativePerformanceStats.MAXIMUM))
		Performance.add_custom_monitor("Game/replay_ticks_per_frame_max", NativePerformanceStats.read.bind(NativePerformanceStats.REPLAY_TICKS, NativePerformanceStats.MAXIMUM))
		for metric in MONITORS:
			Performance.add_custom_monitor("Game/%s_samples" % metric, NativePerformanceStats.read.bind(MONITORS[metric], NativePerformanceStats.SAMPLES))
			Performance.add_custom_monitor("Game/%s_mean_us" % metric, NativePerformanceStats.read.bind(MONITORS[metric], NativePerformanceStats.MEAN))
			Performance.add_custom_monitor("Game/%s_max_us" % metric, NativePerformanceStats.read.bind(MONITORS[metric], NativePerformanceStats.MAXIMUM))

func _physics_process(_delta: float) -> void:
	NativePerformanceStats.physics_tick()

func _process(_delta: float) -> void:
	NativePerformanceStats.frame_boundary()
	var now := Time.get_ticks_usec()
	if now < _next_publish: return
	_next_publish = now + 1000000
	NativePerformanceStats.publish()
	if _console:
		var window := NativePerformanceStats.snapshot(false)
		print("PERF window_us=%d samples(tick/encode/replay)=%.0f/%.0f/%.0f us mean/max tick=%.0f/%.0f encode_peer=%.0f/%.0f replay=%.0f/%.0f callback_interval_max=%.0f" % [
				window["window_us"], NativePerformanceStats.read(NativePerformanceStats.SERVER_TICK, NativePerformanceStats.SAMPLES),
				NativePerformanceStats.read(NativePerformanceStats.STATE_ENCODE, NativePerformanceStats.SAMPLES),
				NativePerformanceStats.read(NativePerformanceStats.REPLAY, NativePerformanceStats.SAMPLES),
				NativePerformanceStats.read(NativePerformanceStats.SERVER_TICK, NativePerformanceStats.MEAN), NativePerformanceStats.read(NativePerformanceStats.SERVER_TICK, NativePerformanceStats.MAXIMUM),
				NativePerformanceStats.read(NativePerformanceStats.STATE_ENCODE, NativePerformanceStats.MEAN), NativePerformanceStats.read(NativePerformanceStats.STATE_ENCODE, NativePerformanceStats.MAXIMUM),
				NativePerformanceStats.read(NativePerformanceStats.REPLAY, NativePerformanceStats.MEAN), NativePerformanceStats.read(NativePerformanceStats.REPLAY, NativePerformanceStats.MAXIMUM),
				NativePerformanceStats.read(NativePerformanceStats.CALLBACK_INTERVAL, NativePerformanceStats.MAXIMUM)])

func _exit_tree() -> void:
	if OS.is_debug_build():
		Performance.remove_custom_monitor("Game/monitor_enabled")
		Performance.remove_custom_monitor("Game/physics_ticks_per_frame_max")
		Performance.remove_custom_monitor("Game/replay_ticks_per_frame_max")
		for metric in MONITORS:
			Performance.remove_custom_monitor("Game/%s_samples" % metric)
			Performance.remove_custom_monitor("Game/%s_mean_us" % metric)
			Performance.remove_custom_monitor("Game/%s_max_us" % metric)
	if not _summary_path.is_empty():
		var file := FileAccess.open(_summary_path, FileAccess.WRITE)
		if file == null:
			push_warning("无法写入性能汇总：%s" % _summary_path)
			return
		var report := NativePerformanceStats.snapshot(true)
		report["pid"] = OS.get_process_id()
		report["headless"] = DisplayServer.get_name() == "headless"
		report["physics_ticks_per_second"] = Engine.physics_ticks_per_second
		report["max_fps"] = Engine.max_fps
		report["debug_build"] = OS.is_debug_build()
		file.store_string(JSON.stringify(report))
