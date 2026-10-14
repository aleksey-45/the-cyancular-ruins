extends SceneTree

func _initialize() -> void:
	_check_queue()
	_check_playback()
	print("INPUT PLAYBACK SMOKE OK target ticks, latest movement, action ACK, expiry, starvation, epoch, wrap, playback clock")
	quit()

func _record(seq: int, tick: int) -> Dictionary:
	var record := InputBuffer.neutral()
	record.merge({"seq": seq, "target_tick": tick, "ax": -1.0,
		"held": PacketInputSource.BIT_ATTACK, "aim": Vector2.LEFT}, true)
	return record

func _check_queue() -> void:
	var queue := InputBuffer.new()
	var records: Array = []
	for seq in range(1, 10):
		records.append(_record(seq, seq))
	var jump: Dictionary = records[0].duplicate()
	jump["pressed"] = PacketInputSource.BIT_UP
	var release: Dictionary = records[1].duplicate()
	release["released"] = PacketInputSource.BIT_UP
	queue.push({"frames": records, "actions": [jump, release]}, 9)
	var latest := queue.take(10)
	assert(queue.ack == 9 and queue.frames.is_empty() and latest["ax"] == -1.0)
	assert(latest["pressed"] == PacketInputSource.BIT_UP and queue.action_ack == 1)
	# 移动 ACK 不清理单次动作；重复上报只执行一次，保持按键按下与松开的时序。
	queue.push({"frames": records, "actions": [release, jump]}, 10)
	assert(queue.take(11)["released"] == PacketInputSource.BIT_UP and queue.action_ack == 2)
	for tick in range(12, 20):
		queue.push({"frames": records, "actions": [jump, release]}, tick - 1)
		var held := queue.take(tick)
		assert(held["pressed"] == 0 and held["released"] == 0 and held["winst"] == 0)
		assert(held["ax"] == (-1.0 if tick <= 15 else 0.0))
	# 初始八条旧移动不会永久留下七 tick 延迟；以后每 tick 直接取最新到期状态。
	queue.reset(1)
	queue.push({"frames": records.slice(0, 8), "actions": []}, 8)
	assert(queue.take(9)["seq"] == 8 and queue.frames.is_empty())
	for seq in range(9, 69):
		queue.push({"frames": [_record(seq, seq)], "actions": []}, seq)
		assert(queue.take(seq + 1)["seq"] == seq and queue.frames.is_empty())
	# 未来输入按 tick 留存；空洞使用持续状态，六 tick 后归零且保留瞄准。
	queue.reset(1)
	queue.push({"frames": [_record(1, 101), _record(3, 103)], "actions": []}, 100)
	assert(queue.take(101)["seq"] == 1)
	assert(queue.take(102)["seq"] == 1)
	assert(queue.take(103)["seq"] == 3)
	for tick in range(104, 110):
		assert(queue.take(tick)["held"] == PacketInputSource.BIT_ATTACK)
	assert(queue.take(110)["held"] == 0 and queue.take(111)["aim"] == Vector2.LEFT)
	# 过期动作只确认，不补放；旧移动也不能因刚到包而再持续六 tick。
	queue.reset(1)
	var shot := _record(1, 1)
	shot["pressed"] = PacketInputSource.BIT_ATTACK
	queue.push({"frames": [shot], "actions": [shot]}, 100)
	var expired := queue.take(101)
	assert(expired["ax"] == 0.0 and expired["held"] == 0 and expired["pressed"] == 0)
	assert(queue.ack == 1 and queue.action_ack == 1 and queue.actions.is_empty())
	# 100 次突发：移动立即恢复到最新到期输入，不为旧输入增添模拟时间。
	for burst in range(1, 101):
		records.clear()
		var last := 50 * burst + 1
		for seq in range(last - 49, last + 1):
			records.append(_record(seq, seq))
		queue.push({"frames": records, "actions": []}, last)
		assert(queue.frames.size() == 1 and queue.take(last + 1)["seq"] == last)
		assert(queue.frames.is_empty())
	queue.reset(2)
	queue.push({"frames": records, "actions": [shot]}, 6000)
	assert(queue.frames.is_empty() and queue.actions.is_empty() and queue.ack == 0)
	var new_control := _record(1, 6001)
	new_control["epoch"] = 2
	queue.push({"frames": [new_control], "actions": []}, 6000)
	assert(queue.take(6001)["seq"] == 1 and queue.lead == 1)

func _world(pos: Vector2) -> Dictionary:
	return {"players": {1: {"pos": pos, "vel": Vector2(100, 0), "epoch": 1}}, "projectiles": {}, "pickups": {}}

func _check_playback() -> void:
	var buffer := SnapshotBuffer.new()
	buffer.map_px = Vector2(1000, 500)
	buffer.push(60, _world(Vector2(990, 10)))
	buffer.push(62, _world(Vector2(10, 10)))
	assert(buffer.sample(61)["players"][1]["pos"].distance_to(Vector2(0, 10)) < 0.001)
	assert(buffer.sample(80)["players"][1]["pos"].distance_to(Vector2(20, 10)) < 0.001)
	buffer.advance(2.0)
	assert(buffer.render_tick == 68.0)
	var frozen := buffer.advance(2.0)
	assert(buffer.render_tick == 68.0 and frozen["players"][1]["pos"] == Vector2(20, 10))
	buffer.push(500, _world(Vector2(10, 10)))
	assert(buffer.render_tick == 494.0)
	for tick in range(502, 581, 2):
		buffer.push(tick, _world(Vector2(10, 10)))
	assert(buffer.frames.size() == SnapshotBuffer.KEEP and buffer.render_tick >= 568.0)
	buffer.push(579, _world(Vector2.ZERO))
	assert(buffer.frames[-1]["tick"] == 580)
	buffer.advance(2.0)
	assert(buffer.render_tick == 586.0)
	buffer.reset()
	for tick in [100, 102, 104, 106]:
		buffer.push(tick, _world(Vector2(tick, 10)))
	assert(buffer.sample(103)["players"][1]["pos"].x == 103.0)
	assert(buffer.frames.map(func(frame: Dictionary) -> int: return frame["tick"]) == [102, 104, 106])
	# 普通两包突发没有经过时间，就不能改变播放时间和匀速实体位置。
	buffer.render_tick = 103.0
	buffer.push(108, _world(Vector2(108, 10)))
	buffer.push(110, _world(Vector2(110, 10)))
	assert(buffer.render_tick == 103.0)
	buffer.advance(1.0 / 60.0)
	assert(buffer.render_tick >= 103.96 and buffer.render_tick <= 104.02)
	# 复活不跨 epoch 插值，实体集合也到右端 tick 才转换。
	var alive := _world(Vector2(100, 10))
	alive["projectiles"][7] = {"pos": Vector2(100, 10), "vel": Vector2.ZERO}
	var respawn := _world(Vector2(200, 10))
	respawn["players"][1]["epoch"] = 2
	buffer.reset()
	buffer.push(200, alive)
	buffer.push(202, respawn)
	assert(buffer.sample(201)["players"][1]["pos"].x == 100.0)
	assert(buffer.sample(201)["projectiles"].has(7))
	assert(buffer.sample(202)["players"][1]["pos"].x == 200.0)
	assert(buffer.sample(202)["projectiles"].is_empty())
