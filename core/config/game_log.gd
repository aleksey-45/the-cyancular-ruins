extends Node

# 每次运行一个 JSON Lines 文件；后台格式化、JSON 编码与写盘，正常退出时写完队列。
const ROLE_CLIENT := "client"
const ROLE_SERVER := "server"
static var _sink: Logger
static var _writer: Writer
static var _path := ""
static var _role := ROLE_CLIENT
static var _installed := false
static var _session := ""
static var _mutex := Mutex.new()
static var _record_max_us := 0
var _sample_at := Time.get_ticks_msec()
var _frames := 0
var _max_frame_ms := 0.0
var _max_frame_end_us := 0
var _max_frame_end_id := 0
var _frame_at := Time.get_ticks_usec()

class Sink extends Logger:
	var on_record: Callable

	func _log_message(message: String, error: bool) -> void:
		on_record.call("engine", {"message": message, "error": error}, error)

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			script_backtraces: Array) -> void:
		var traces: Array = []
		for trace in script_backtraces:
			traces.append(str(trace))
		on_record.call("engine_error", {"function": function, "file": file, "line": line,
				"code": code, "message": rationale if not rationale.is_empty() else code,
				"type": error_type, "backtraces": traces}, true)

class Writer extends RefCounted:
	const BATCH_ROWS := 128
	var _file: FileAccess
	var _thread := Thread.new()
	var _mutex := Mutex.new()
	var _wake := Semaphore.new()
	var _pending: Array[Dictionary] = []
	var _stopping := false
	var _flush_max_us := 0
	var _encode_max_us := 0
	var _pending_max := 0
	# 仅后台线程使用；同一秒的 UTC 前缀无需逐行重复格式化。
	var _time_second := -1
	var _time_prefix := ""

	func start(file: FileAccess) -> void:
		_file = file
		_thread.start(_run)

	func append(row: Dictionary, urgent: bool) -> void:
		_mutex.lock()
		_pending.append(row)
		_pending_max = maxi(_pending_max, _pending.size())
		var wake := urgent or _pending.size() == BATCH_ROWS
		_mutex.unlock()
		if wake:
			flush()

	func flush() -> void:
		_wake.post()

	func take_flush_max_us() -> int:
		_mutex.lock()
		var elapsed := _flush_max_us
		_flush_max_us = 0
		_mutex.unlock()
		return elapsed

	func take_statistics() -> Dictionary:
		_mutex.lock()
		var result := {"pending": _pending.size(), "pending_max": _pending_max,
				"encode_batch_max_us": _encode_max_us}
		_pending_max = _pending.size()
		_encode_max_us = 0
		_mutex.unlock()
		return result

	func close() -> void:
		_mutex.lock()
		_stopping = true
		_mutex.unlock()
		flush()
		_thread.wait_to_finish()

	func _run() -> void:
		while true:
			_wake.wait()
			_mutex.lock()
			var batch := _pending
			_pending = []
			var stopping := _stopping
			_mutex.unlock()
			if not batch.is_empty():
				_write(batch)
			if stopping:
				_file.close()
				return

	func _write(batch: Array[Dictionary]) -> void:
		var encoding_at := Time.get_ticks_usec()
		var lines := PackedStringArray()
		for row: Dictionary in batch:
			var now: float = row["_unix_time"]
			var second := int(now)
			if second != _time_second:
				_time_second = second
				_time_prefix = Time.get_datetime_string_from_unix_time(second)
			row["time"] = _time_prefix + ".%03dZ" % int(fposmod(now, 1.0) * 1000)
			row.erase("_unix_time")
			lines.append(JSON.stringify(row))
		var encoded_at := Time.get_ticks_usec()
		_file.store_string("\n".join(lines) + "\n")
		var start_us := Time.get_ticks_usec()
		_file.flush()
		_mutex.lock()
		_encode_max_us = maxi(_encode_max_us, encoded_at - encoding_at)
		_flush_max_us = maxi(_flush_max_us, Time.get_ticks_usec() - start_us)
		_mutex.unlock()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	install()
	FrameTrace.install(self)
	get_window().focus_entered.connect(func() -> void: record("window_focus", {"focused": true}))
	get_window().focus_exited.connect(func() -> void: record("window_focus", {"focused": false}))

func _exit_tree() -> void:
	record("session_end", {}, true)
	close()

func _process(_delta: float) -> void:
	_frames += 1
	var frame_at := Time.get_ticks_usec()
	var frame_ms := (frame_at - _frame_at) / 1000.0
	if frame_ms > _max_frame_ms:
		_max_frame_ms = frame_ms
		_max_frame_end_us = frame_at
		_max_frame_end_id = Engine.get_process_frames()
	_frame_at = frame_at
	if frame_ms > 50.0:
		var current := get_tree().current_scene
		record("long_frame", {"frame_ms": frame_ms,
				"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				"focused": get_window().has_focus(), "paused": get_tree().paused,
				"scene": current.scene_file_path if current != null else ""})
	var now := Time.get_ticks_msec()
	if now - _sample_at < 1000:
		return
	var scene := get_tree().current_scene
	_mutex.lock()
	var record_max_us := _record_max_us
	_record_max_us = 0
	var flush_max_us := _writer.take_flush_max_us() if _writer != null else 0
	var writer_stats := _writer.take_statistics() if _writer != null else {}
	_mutex.unlock()
	record("performance", {"interval_ms": now - _sample_at, "frames": _frames,
			"max_frame_ms": _max_frame_ms, "process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"max_frame_end_us": _max_frame_end_us, "max_frame_end_process_frame": _max_frame_end_id,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"memory_bytes": OS.get_static_memory_usage(), "paused": get_tree().paused,
			"focused": get_window().has_focus(), "low_processor_usage": OS.low_processor_usage_mode,
			"log_record_max_ms": record_max_us / 1000.0, "log_flush_max_ms": flush_max_us / 1000.0,
			"log_writer": writer_stats,
			"scene": scene.scene_file_path if scene != null else ""})
	_sample_at = now
	_frames = 0
	_max_frame_ms = 0.0
	flush()

static func install() -> void:
	if _installed:
		return
	_installed = true
	_session = Time.get_datetime_string_from_system().replace(":", "").replace("-", "") + "-%d" % OS.get_process_id()
	_sink = Sink.new()
	_sink.on_record = record
	OS.add_logger(_sink)
	var server := OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server") or OS.get_cmdline_args().has("res://server/server_main.tscn")
	use_role(ROLE_SERVER if server else ROLE_CLIENT)

static func use_role(role: String) -> void:
	if role == _role and _writer != null:
		return
	close()
	_role = role
	if _sink == null:
		return
	var dir := AppPaths.log_dir()
	var args := OS.get_cmdline_user_args()
	if args.has("--game-log-dir"):
		dir = args[args.find("--game-log-dir") + 1]
	_open(dir)
	if _writer == null:
		_open(ProjectSettings.globalize_path("user://logs"))
	if _writer == null:
		push_warning("无法创建游戏日志文件")
		return
	record("session_start", {"build": preload("res://core/config/build_info.gd").display(),
			"version": ProjectSettings.get_setting("application/config/version"),
			"physics_hz": Engine.physics_ticks_per_second, "max_fps": Engine.max_fps,
			"engine": Engine.get_version_info()["string"], "os": OS.get_name(), "os_version": OS.get_version(),
			"architecture": Engine.get_architecture_name(), "timezone": Time.get_time_zone_from_system(),
			"renderer": RenderingServer.get_current_rendering_method(), "display": DisplayServer.get_name(), "log": _path}, true)

static func _open(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("%s-%s.log" % [_role, _session])
	var file := FileAccess.open(path, FileAccess.WRITE)
	_mutex.lock()
	if file != null:
		_writer = Writer.new()
		_writer.start(file)
		_path = path
	_mutex.unlock()

static func log_file() -> String:
	return _path

static func log_dir() -> String:
	return _path.get_base_dir() if not _path.is_empty() else AppPaths.log_dir()

static func session_id() -> String:
	return _session

## 字段使用标量、数组和字典；时间为 UTC，uptime_ms 为本进程单调时钟。
static func record(event: String, data: Dictionary = {}, urgent := false) -> void:
	var start_us := Time.get_ticks_usec()
	_mutex.lock()
	if _writer == null:
		_mutex.unlock()
		return
	var now := Time.get_unix_time_from_system()
	# 调用方随后可能 clear/修改嵌套容器；入队前取得独立值快照，后台不访问场景对象。
	_writer.append({"_unix_time": now,
			"uptime_ms": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": _role,
			"process_frame": Engine.get_process_frames(), "physics_frame": Engine.get_physics_frames(),
			"event": event, "data": data.duplicate(true)}, urgent)
	_record_max_us = maxi(_record_max_us, Time.get_ticks_usec() - start_us)
	_mutex.unlock()

static func flush() -> void:
	_mutex.lock()
	if _writer != null:
		_writer.flush()
	_mutex.unlock()

static func close() -> void:
	_mutex.lock()
	var writer := _writer
	_writer = null
	_path = ""
	_mutex.unlock()
	if writer != null:
		writer.close()
