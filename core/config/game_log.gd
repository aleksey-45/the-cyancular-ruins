extends Node

# 每个进程、每次运行一个 JSON Lines 文件；普通记录每秒落盘，错误立即落盘。
const ROLE_CLIENT := "client"
const ROLE_SERVER := "server"
static var _sink: Logger
static var _file: FileAccess
static var _path := ""
static var _role := ROLE_CLIENT
static var _installed := false
static var _session := ""
static var _mutex := Mutex.new()
var _sample_at := Time.get_ticks_msec()
var _frames := 0
var _max_frame_ms := 0.0
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

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	install()

func _exit_tree() -> void:
	record("session_end", {}, true)
	close()

func _process(_delta: float) -> void:
	_frames += 1
	var frame_at := Time.get_ticks_usec()
	_max_frame_ms = maxf(_max_frame_ms, (frame_at - _frame_at) / 1000.0)
	_frame_at = frame_at
	var now := Time.get_ticks_msec()
	if now - _sample_at < 1000:
		return
	var scene := get_tree().current_scene
	record("performance", {"interval_ms": now - _sample_at, "frames": _frames,
			"max_frame_ms": _max_frame_ms, "process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"memory_bytes": OS.get_static_memory_usage(), "paused": get_tree().paused,
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
	if role == _role and _file != null:
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
	if _file == null:
		_open(ProjectSettings.globalize_path("user://logs"))
	if _file == null:
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
	_mutex.lock()
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file != null:
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
	_mutex.lock()
	if _file == null:
		_mutex.unlock()
		return
	var now := Time.get_unix_time_from_system()
	_file.store_line(JSON.stringify({"time": Time.get_datetime_string_from_unix_time(int(now)) + ".%03dZ" % int(fposmod(now, 1.0) * 1000),
			"uptime_ms": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": _role,
			"event": event, "data": data}))
	if urgent:
		_file.flush()
	_mutex.unlock()

static func flush() -> void:
	_mutex.lock()
	if _file != null:
		_file.flush()
	_mutex.unlock()

static func close() -> void:
	_mutex.lock()
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	_path = ""
	_mutex.unlock()
