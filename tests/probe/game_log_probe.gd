extends Node

const LogScript := preload("res://core/config/game_log.gd")
var _physics_ticks := 0

class PausedWriter extends LogScript.Writer:
	var entered := Semaphore.new()
	var release := Semaphore.new()
	var _pause := true

	func _write(batch: Array[Dictionary]) -> void:
		if _pause:
			_pause = false
			entered.post()
			release.wait()
		super._write(batch)

func _ready() -> void:
	_run.call_deferred()

func _physics_process(_delta: float) -> void:
	_physics_ticks += 1

func _read(path: String) -> Array:
	var text := FileAccess.get_file_as_string(path)
	var records: Array = []
	for line in text.left(text.rfind("\n") + 1).split("\n", false):
		var entry: Dictionary = JSON.parse_string(line)
		assert(entry["pid"] == OS.get_process_id() and entry["time"].ends_with("Z"))
		records.append(entry)
	return records

func _wait_for(path: String, event: String) -> Array:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var records := _read(path)
		if records.any(func(r: Dictionary) -> bool: return r["event"] == event):
			return records
		await get_tree().process_frame
	assert(false, "日志写入超时: " + event)
	return []

func _run() -> void:
	GameLog.set_process(false)
	var path := GameLog.log_file()
	await _wait_for(path, "session_start")
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
	# 关闭周期采样时，警告仍会独立唤醒后台写入线程。
	var records := await _wait_for(path, "engine_error")
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "session_start"))
	assert(records.filter(func(r: Dictionary) -> bool: return r["event"] == "thread_probe").size() == 200)
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "log_probe" and r["data"]["text"] == marker))
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "engine" and r["data"]["message"].strip_edges() == "LOG PROBE engine output"))
	assert(records.any(func(r: Dictionary) -> bool: return r["event"] == "engine_error" and r["data"]["message"] == "LOG PROBE warning"))
	for worker in 4:
		var entries := records.filter(func(r: Dictionary) -> bool: return r["event"] == "thread_probe" and r["data"]["worker"] == worker)
		for i in entries.size():
			assert(entries[i]["data"]["number"] == i)
	GameLog.set_process(true)
	GameLog.record("periodic_probe")
	await _wait_for(path, "periodic_probe")
	await _wait_for(path, "performance")
	for entry: Dictionary in _read(path):
		if entry["event"] == "performance":
			assert(entry["data"]["log_record_max_ms"] >= 0.0 and entry["data"]["log_flush_max_ms"] >= 0.0)
			assert(entry["data"].has("focused") and entry["data"].has("low_processor_usage"))
	GameLog.record("close_probe")
	GameLog.close()
	assert(_read(path).any(func(r: Dictionary) -> bool: return r["event"] == "close_probe"))
	await _test_paused_writer(path + ".paused")
	GameLog.use_role(GameLog.ROLE_SERVER)
	assert(GameLog.log_file() != path)
	print("GAME LOG OK")
	get_tree().quit()

func _test_paused_writer(path: String) -> void:
	var writer := PausedWriter.new()
	writer.start(FileAccess.open(path, FileAccess.WRITE))
	GameLog._writer = writer
	GameLog._path = path
	GameLog.record("paused_begin", {}, true)
	while not writer.entered.try_wait():
		await get_tree().process_frame
	var first_tick := _physics_ticks
	var max_call_us := 0
	var data := {"value": 1, "nested": {"rows": [{"value": 3}]}, "packed": PackedInt32Array([5])}
	GameLog.record("snapshot_probe", data)
	data["value"] = 2
	data["nested"]["rows"][0]["value"] = 4
	data["packed"][0] = 6
	for i in 75:
		var started := Time.get_ticks_usec()
		GameLog.record("paused_record", {"number": i}, true)
		GameLog.flush()
		max_call_us = maxi(max_call_us, Time.get_ticks_usec() - started)
		await get_tree().physics_frame
	await get_tree().process_frame
	assert(_physics_ticks - first_tick >= 75)
	assert(writer._thread.is_alive())
	writer.release.post()
	GameLog.record("paused_end")
	GameLog.close()
	assert(not writer._thread.is_started())
	var records := _read(path)
	assert(records.filter(func(r: Dictionary) -> bool: return r["event"] == "paused_record").size() == 75)
	assert(records.any(func(r: Dictionary) -> bool: return (r["event"] == "snapshot_probe"
			and r["data"]["value"] == 1 and r["data"]["nested"]["rows"][0]["value"] == 3
			and r["data"]["packed"].size() == 1 and int(r["data"]["packed"][0]) == 5)))
	assert(records[-1]["event"] == "paused_end")
	print("LOG PROBE paused writer: ticks=%d max_call_ms=%.3f" % [_physics_ticks - first_tick, max_call_us / 1000.0])
