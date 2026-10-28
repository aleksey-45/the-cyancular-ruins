extends Node

var _injected := false
var _armed := false

func _ready() -> void:
	_run.call_deferred()

func _physics_process(_delta: float) -> void:
	if not _armed or _injected: return
	_injected = true
	var at := Time.get_ticks_usec()
	OS.delay_msec(35)
	FrameTrace.span(&"injected_work", at, Time.get_ticks_usec())
	FrameTrace.event(&"packet", {"direction": "receive", "peer": 1, "received_us": at,
			"bytes": PackedByteArray([0, 7, 128, 255])})

func _run() -> void:
	# 测试安装入口也覆盖命令行关闭时的零工作路径。
	if not FrameTrace.enabled: GameLog.add_child(FrameTrace.new())
	var trace := FrameTrace._instance
	var path: String = trace._path
	for frame in 2: await get_tree().process_frame
	_armed = true
	for frame in 5: await get_tree().process_frame
	trace.free()
	assert(not FrameTrace.enabled)
	var rows: Array = []
	for line in FileAccess.get_file_as_string(path).split("\n", false): rows.append(JSON.parse_string(line))
	assert(rows[0]["event"] == "trace_start" and rows[-1]["event"] == "trace_end")
	assert(rows[-1]["writer"][1] == 0)
	var injected := 0
	var packets := 0
	for row: Dictionary in rows:
		if row["event"] != "frame": continue
		assert(row["end_us"] >= row["start_us"] and row["interval_us"] == row["end_us"] - row["start_us"])
		for span: Array in row["spans"]:
			if span[0] != "injected_work": continue
			injected += 1
			assert(span[2] - span[1] >= 35000 and row["interval_us"] >= 35000,
					"the complete frame must contain the injected work on its exact timeline")
			assert(span[1] >= row["start_us"] and span[2] <= row["end_us"])
		for item: Array in row["events"]:
			if item[0] == "packet":
				packets += 1
				assert(Marshalls.base64_to_raw(item[2]["bytes_b64"]) == PackedByteArray([0, 7, 128, 255]))
	assert(injected == 1 and packets == 1)
	print("FRAME TRACE PROBE OK exact frame, synthetic 35 ms work, raw packet and background drain")
	get_tree().quit()
