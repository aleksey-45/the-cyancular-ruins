extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var marker := "日志探针 🌏 \"换行\"\n第二行"
	GameLog.record("log_probe", {"text": marker, "tick": 123, "nested": {"ok": true}})
	print("LOG PROBE engine output")
	var workers: Array[Thread] = []
	for worker in 4:
		var thread := Thread.new()
		thread.start(func() -> void:
			print("LOG PROBE worker %d" % worker)
			for i in 50:
				GameLog.record("thread_probe", {"worker": worker, "number": i}))
		workers.append(thread)
	for thread in workers:
		thread.wait_to_finish()
	push_warning("LOG PROBE warning")
	# 警告立即冲刷此前的普通记录，读取者可在进程仍运行时解析完整 JSON 行。
	var records: Array = []
	for line in FileAccess.get_file_as_string(GameLog.log_file()).split("\n", false):
		var entry: Dictionary = JSON.parse_string(line)
		assert(entry["pid"] == OS.get_process_id() and entry["time"].ends_with("Z"))
		records.append(entry)
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "session_start"))
	assert(records.filter(func(r: Dictionary) -> bool: return r["event"] == "thread_probe").size() == 200)
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "log_probe" and r["data"]["text"] == marker))
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "engine" and r["data"]["message"].strip_edges() == "LOG PROBE engine output"))
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "engine_error" and r["data"]["message"] == "LOG PROBE warning"))
	await get_tree().create_timer(1.2).timeout
	var text := FileAccess.get_file_as_string(GameLog.log_file())
	assert(text.contains('"event":"performance"'))
	print("GAME LOG OK")
	get_tree().quit()
