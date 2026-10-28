extends "res://tests/network/tunnel_peer.gd"

const ScriptedInput := preload("res://tests/network/match_input.gd")
class RenderWatch extends Node:
	var player: Node2D
	var position := Vector2.ZERO
	func _process(_delta: float) -> void:
		position = player.position

var index := 0
var count := 2
var mode := "royale"
var elapsed := 0.0
var duration := 24.0
var code := ""
var token := ""
var game: PvpMatchClient
var driver: PacketInputSource
var render_watch: RenderWatch
var snapshots := 0
var baselines := 0
var drop := false
var reconnected := false
var states_at_drop := 0
var sent_start := false
var result_seen := false
var convergence_error := INF
var predicted: Array = []
var fire_keys: Dictionary = {}
var _started_us := 0
var _clock_wall := 0.0
var _metrics_second := -1
var _sample: Dictionary = {}
var _sample_wall := 0.0
var _sample_tick := 0.0
var _sample_cap := false
var _sample_stall := 0.0
var _sample_state_wall := 0.0
var metrics := {"index": 0}

func _ready() -> void:
	process_priority = 200
	process_physics_priority = -100
	var args := OS.get_cmdline_user_args()
	index = int(args[args.find("--index") + 1])
	count = int(args[args.find("--count") + 1])
	mode = args[args.find("--mode") + 1]
	duration = float(args[args.find("--battle-seconds") + 1])
	drop = args.has("--drop")
	metrics["index"] = index
	_started_us = Time.get_ticks_usec()
	_clock_wall = Time.get_unix_time_from_system()
	NetBus.event_received.connect(on_event)
	NetBus.state_received.connect(on_state)
	NetBus.connected_to_server.connect(on_connected)
	PvpSession.server_port = await start_test_tunnel(false, int(args[args.find("--port") + 1]))
	PvpSession.server_address = "127.0.0.1"
	NetBus.compression_enabled = not args.has("--none")
	assert(NetBus.start_client(PvpSession.server_address, PvpSession.server_port) == OK)

func on_connected() -> void:
	if game != null:
		return
	NetBus.send_event(NetEvent.Kind.HELLO, {"name": "Bot%d" % index, "hue": float(index * 35)})
	if index == 0 and code.is_empty():
		NetBus.send_event(NetEvent.Kind.CREATE, {"mode": mode, "options": {
			"map": ProjectSettings.globalize_path("res://tests/network/arena.cyrm"),
			"max_players": count, "match_time": duration, "beta": true, "time": TimeRules.new().to_dict()}})
	else:
		NetBus.send_event(NetEvent.Kind.LIST, {"beta": true, "token": token})

func _wait_until(condition: Callable, description: String) -> bool:
	var started := Time.get_ticks_msec()
	var frames := 0
	while not condition.call():
		if Time.get_ticks_msec() - started >= 2000:
			push_error("MATCH CLIENT FAIL timeout waiting for " + description)
			get_tree().quit(1)
			return false
		await get_tree().process_frame
		frames += 1
	print("MATCH WAIT OK %s frames=%d elapsed_ms=%d" % [description, frames, Time.get_ticks_msec() - started])
	return true

func on_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.FIRE:
			var key := (int(data["role"]) << 48) | int(data["shot"])
			assert(not fire_keys.has(key))
			fire_keys[key] = true
		NetEvent.Kind.MESSAGE:
			if data.begins_with("NETWORK SAMPLE "):
				_sample = JSON.parse_string(data.trim_prefix("NETWORK SAMPLE "))
				_sample.merge({"observed_seconds": 0.0, "stall_seconds": 0.0, "longest_stall_seconds": 0.0,
					"max_frame_ms": 0.0, "outage_seconds": 0.0, "baseline_changes": 0, "complete": false,
					"state_gaps_ms": [], "ping_ms": []})
				metrics["network_sample"] = _sample
		NetEvent.Kind.ROOMS:
			if not data.is_empty():
				NetBus.send_event(NetEvent.Kind.JOIN, {"code": data[0]["code"], "invite": "", "beta": true})
			else:
				await get_tree().create_timer(0.2).timeout
				NetBus.send_event(NetEvent.Kind.LIST, {"beta": true, "token": token})
		NetEvent.Kind.ROOM:
			if result_seen:
				assert(data["code"] == code and data["token"] == token and not data["in_match"])
				NetBus.event_received.disconnect(on_event)
				if not await _wait_until(func() -> bool:
					return get_tree().current_scene is LobbyPage and PvpSession.room.get("code") == code,
					"same room lobby"): return
				NetSession.close()
				if not await _wait_until(func() -> bool: return Level0._reap_queue.is_empty(), "level cleanup"): return
				print("MATCH CLIENT OK index=%d natural_result=true same_room=true" % index)
				get_tree().quit()
				return
			token = data["token"]
			code = data["code"]
			PvpSession.role = data["your_role"]
			PvpSession.token = token
			PvpSession.room_code = code
			PvpSession.room_mode = mode
			if game == null and index == 0 and data["players"].size() == count and not sent_start:
				sent_start = true
				NetBus.send_event(NetEvent.Kind.START, 0)
		NetEvent.Kind.BASELINE:
			if not _sample.is_empty() and sample_clock() >= _sample["start"] and sample_clock() < _sample["end"]:
				_sample["baseline_changes"] += 1
			baselines += 1
			if game == null:
				PvpSession.baseline = data
				PvpSession.beta_mode = true
				game = PvpMatchClient.new()
				game.tree_exiting.connect(func() -> void:
					set_process(false)
					set_physics_process(false)
					game = null)
				get_tree().root.add_child(game)
				get_tree().current_scene = game
				render_watch = RenderWatch.new()
				render_watch.process_priority = 3
				render_watch.player = game._local
				render_watch.position = game._local.position
				game.add_child(render_watch)
				driver = ScriptedInput.new()
				driver.index = PvpSession.role - 1 if mode == "team" else index
				driver.mode = mode
				game._local.set_input_source(driver)
		NetEvent.Kind.ROUND:
			if data["state"] == NetEvent.RoundState.MATCH_OVER:
				result_seen = true
				set_physics_process(false)
				metrics["stats"] = data["stats"]
				metrics["state_count"] = snapshots
				metrics["baselines"] = baselines
				metrics["convergence_error"] = convergence_error
				metrics["states_after_drop"] = snapshots - states_at_drop if reconnected else 0
				print("NETWORK METRICS " + JSON.stringify(metrics))
				assert(snapshots > 100 and not fire_keys.is_empty())
				assert(not drop or (reconnected and baselines >= 2 and snapshots - states_at_drop > 30))
				if mode == "royale":
					assert(convergence_error < 2.0, "MATCH CLIENT FAIL convergence: %s" % convergence_error)
				if not await _wait_until(func() -> bool:
					return is_instance_valid(game) and is_instance_valid(game._result) and game._result.visible,
					"match result visible"): return
				game._result.leave_requested.emit()

func on_state(frame: Dictionary) -> void:
	var wall := sample_clock()
	if not _sample.is_empty() and wall >= _sample["start"] and wall < _sample["end"]:
		if _sample_state_wall >= _sample["start"]:
			_sample["state_gaps_ms"].append((wall - _sample_state_wall) * 1000.0)
		_sample_state_wall = wall
	snapshots += 1
	if game != null and driver.stop:
		for i in range(1, predicted.size()):
			var from: Dictionary = predicted[i - 1]
			var to: Dictionary = predicted[i]
			if from["epoch"] != frame["own"]["epoch"] or frame["tick"] < from["tick"] or frame["tick"] > to["tick"]:
				continue
			var weight: float = float(frame["tick"] - from["tick"]) / (to["tick"] - from["tick"])
			var movement := GridPathfinder.toroidal_delta_px(from["pos"], to["pos"], GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			var position: Vector2 = from["pos"] + movement * weight
			convergence_error = GridPathfinder.toroidal_delta_px(frame["own"]["state"]["pos"], position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			metrics["convergence_samples"] = metrics.get("convergence_samples", 0) + 1
			break

func sample_clock() -> float:
	return _clock_wall + (Time.get_ticks_usec() - _started_us) / 1000000.0

func sample_network() -> void:
	if _sample.is_empty() or _sample["complete"]:
		return
	var now := sample_clock()
	var online := game.phase == PvpMatchClient.Phase.ONLINE and not game._playback.frames.is_empty()
	var tick: float = game._playback.render_tick
	var cap: bool = online and tick >= game._playback.frames[-1]["tick"] + SnapshotBuffer.MAX_EXTRAPOLATION
	if _sample_wall > 0 and _sample_wall < _sample["end"] and now >= _sample["start"]:
		var seconds: float = minf(now, _sample["end"]) - maxf(_sample_wall, _sample["start"])
		_sample["observed_seconds"] += seconds
		_sample["max_frame_ms"] = maxf(_sample["max_frame_ms"], (now - _sample_wall) * 1000.0)
		if not online:
			_sample["outage_seconds"] += seconds
		if cap and _sample_cap and is_equal_approx(tick, _sample_tick):
			_sample["stall_seconds"] += seconds
			_sample_stall += seconds
			_sample["longest_stall_seconds"] = maxf(_sample["longest_stall_seconds"], _sample_stall)
		else:
			_sample_stall = 0.0
	_sample["complete"] = now >= _sample["end"]
	_sample_wall = now
	_sample_tick = tick
	_sample_cap = cap

func _process(_delta: float) -> void:
	if game == null or result_seen:
		return
	assert(game.phase != PvpMatchClient.Phase.OFFLINE, "MATCH CLIENT FAIL reconnect timeout")
	sample_network()
	assert(game._local.position.is_equal_approx(render_watch.position), "MATCH CLIENT FAIL physics movement during render")
	assert(game._local.weapons.log_state()["consistent"], "MATCH CLIENT FAIL weapon scene differs from inventory")
	var second := int((Time.get_ticks_usec() - _started_us) / 1000000)
	if second > _metrics_second and not _sample.is_empty() and sample_clock() >= _sample["start"] and sample_clock() < _sample["end"]:
		_metrics_second = second
		_sample["ping_ms"].append(NetBus.ping_ms)

func _physics_process(delta: float) -> void:
	if game == null or result_seen:
		return
	elapsed += delta
	if not predicted.is_empty() and (predicted[-1]["epoch"] != game._rollback.epoch or predicted[-1]["tick"] > game._rollback._sim_tick):
		predicted.clear()
	if predicted.is_empty() or predicted[-1]["tick"] < game._rollback._sim_tick:
		predicted.append({"epoch": game._rollback.epoch, "tick": game._rollback._sim_tick, "pos": game._local.position})
		if predicted.size() > 128:
			predicted.pop_front()
	driver.stop = mode == "royale" and game._last_round_state.get("timer", duration) <= 3.0 \
		and game._last_round_state["state"] == NetEvent.RoundState.PLAYING
	driver.advance(game)
	if drop and not reconnected and elapsed > 11.0:
		reconnected = true
		states_at_drop = snapshots
		NetBus.stop()
		game._begin_reconnect()
