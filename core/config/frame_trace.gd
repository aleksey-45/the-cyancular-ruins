class_name FrameTrace
extends Node

# 仅 --frame-trace 开启。每条记录覆盖相邻 process_frame 信号之间的墙钟区间：
# 本轮 idle/提交/等待，加上下一轮物理回调。各 span 可嵌套，禁止直接相加。
# JSON 编码与写盘在后台；主线程仅交接已经封口的值，队列有界。
static var enabled := false
static var packets := false
static var _instance: FrameTrace
var _writer: TraceWriter
var _current: Dictionary = {}
var _idle_at := 0
var _physics_at := 0
var _draw_at := 0
var _observer_us := 0
var _threshold_us := 25000
var _path := ""

class TraceWriter extends RefCounted:
	const LIMIT := 600
	var _file: FileAccess
	var _thread := Thread.new()
	var _mutex := Mutex.new()
	var _wake := Semaphore.new()
	var _pending: Array = []
	var _stop := false
	var dropped := 0
	var encode_max_us := 0
	var write_max_us := 0

	func start(path: String) -> bool:
		_file = FileAccess.open(path, FileAccess.WRITE)
		if _file == null: return false
		_thread.start(_run)
		return true

	func append(value: Dictionary) -> void:
		_mutex.lock()
		if _pending.size() >= LIMIT:
			dropped += 1
		else:
			_pending.append(value)
		var wake := _pending.size() == 30
		_mutex.unlock()
		if wake: _wake.post()

	func stats() -> Array:
		_mutex.lock()
		var result := [_pending.size(), dropped, encode_max_us, write_max_us]
		_mutex.unlock()
		return result

	func close() -> void:
		_mutex.lock()
		_stop = true
		_mutex.unlock()
		_wake.post()
		_thread.wait_to_finish()

	func _run() -> void:
		while true:
			_wake.wait()
			_mutex.lock()
			var batch := _pending
			_pending = []
			var stop := _stop
			_mutex.unlock()
			var at := Time.get_ticks_usec()
			var lines := PackedStringArray()
			for row: Dictionary in batch:
				for item: Array in row.get("events", []):
					if item[0] == "packet":
						item[2]["bytes_b64"] = Marshalls.raw_to_base64(item[2]["bytes"])
						item[2].erase("bytes")
				lines.append(JSON.stringify(row))
			var encoded := Time.get_ticks_usec()
			if not lines.is_empty():
				_file.store_string("\n".join(lines) + "\n")
				_file.flush()
			var finished := Time.get_ticks_usec()
			_mutex.lock()
			encode_max_us = maxi(encode_max_us, encoded - at)
			write_max_us = maxi(write_max_us, finished - encoded)
			_mutex.unlock()
			if stop:
				_file.store_line(JSON.stringify({"event": "trace_end", "mono_us": Time.get_ticks_usec(),
						"writer": [0, dropped, encode_max_us, write_max_us]}))
				_file.close()
				return

static func install(owner: Node) -> void:
	if not OS.get_cmdline_user_args().has("--frame-trace"): return
	owner.add_child(FrameTrace.new())

static func finish() -> void:
	if enabled: _instance.queue_free()

func _ready() -> void:
	_path = GameLog.log_file() + ".frames.jsonl"
	_writer = TraceWriter.new()
	if not _writer.start(_path):
		queue_free()
		return
	_instance = self
	enabled = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 2147483647
	process_physics_priority = 2147483647
	var args := OS.get_cmdline_user_args()
	packets = args.has("--frame-trace-packets")
	if args.has("--frame-trace-ms"):
		_threshold_us = maxi(1000, int(float(args[args.find("--frame-trace-ms") + 1]) * 1000.0))
	_writer.append({"event": "trace_start", "schema": 1, "pid": OS.get_process_id(),
			"session": GameLog.session_id(), "unix_us": int(Time.get_unix_time_from_system() * 1000000.0),
			"mono_us": Time.get_ticks_usec(), "threshold_us": _threshold_us,
			"display": DisplayServer.get_name(), "boundary": "process_frame_to_process_frame",
			"packets": packets,
			"span_format": ["name", "start_us", "end_us"], "nested_spans": true})
	get_tree().process_frame.connect(_begin)
	get_tree().physics_frame.connect(_physics_begin)
	RenderingServer.frame_pre_draw.connect(_draw_begin)
	RenderingServer.frame_post_draw.connect(_draw_end)
	GameLog.record("frame_trace_start", {"path": _path, "threshold_ms": _threshold_us / 1000.0})

func _begin() -> void:
	var started := Time.get_ticks_usec()
	_seal(started)
	_current = {"event": "frame", "frame": Engine.get_process_frames(), "start_us": started,
			"physics_frame_begin": Engine.get_physics_frames(), "spans": [], "counts": {}, "events": [], "context": {}}
	_idle_at = started
	_observer_us += Time.get_ticks_usec() - started

func _seal(now: int) -> void:
	if _current.is_empty(): return
	_current["end_us"] = now
	_current["interval_us"] = now - int(_current["start_us"])
	_current["physics_frame_end"] = Engine.get_physics_frames()
	_current["observer_us"] = _observer_us
	_current["writer"] = _writer.stats()
	_current["focused"] = get_window().has_focus()
	_current["paused"] = get_tree().paused
	if _current["interval_us"] >= _threshold_us:
		GameLog.record("frame_budget", {"frame": _current["frame"], "start_us": _current["start_us"],
				"end_us": now, "frame_ms": _current["interval_us"] / 1000.0, "trace": _path})
	_writer.append(_current)
	_current = {}
	_observer_us = 0

func _physics_begin() -> void:
	_physics_at = Time.get_ticks_usec()
	count(&"physics_callbacks")

func _physics_process(_delta: float) -> void:
	span(&"physics_nodes", _physics_at, Time.get_ticks_usec())

func _process(_delta: float) -> void:
	span(&"idle_nodes", _idle_at, Time.get_ticks_usec())

func _draw_begin() -> void:
	_draw_at = Time.get_ticks_usec()

func _draw_end() -> void:
	span(&"render_submit", _draw_at, Time.get_ticks_usec())

static func span(label: StringName, start_us: int, end_us: int) -> void:
	if not enabled or _instance._current.is_empty(): return
	var at := Time.get_ticks_usec()
	_instance._current["spans"].append([label, start_us, end_us])
	_instance._observer_us += Time.get_ticks_usec() - at

static func count(label: StringName, value: int = 1) -> void:
	if not enabled or _instance._current.is_empty(): return
	var at := Time.get_ticks_usec()
	var counts: Dictionary = _instance._current["counts"]
	counts[label] = counts.get(label, 0) + value
	_instance._observer_us += Time.get_ticks_usec() - at

static func context(label: StringName, value: Dictionary) -> void:
	if not enabled or _instance._current.is_empty(): return
	_instance._current["context"][label] = value

static func event(label: StringName, value: Dictionary) -> void:
	if not enabled or _instance._current.is_empty(): return
	_instance._current["events"].append([label, Time.get_ticks_usec(), value])

func _exit_tree() -> void:
	if _instance != self: return
	if not _current.is_empty(): _current["partial"] = true
	_seal(Time.get_ticks_usec())
	enabled = false
	_instance = null
	packets = false
	_writer.close()
