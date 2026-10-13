extends Node

var index := 0
var count := 2
var mode := "pvp"
var port := 7777
var elapsed := 0.0
var code := ""
var token := ""
var game: PvpMatchClient
var snapshots := 0
var baselines := 0
var reconnected := false
var drop := false
var started := false
var sent_start := false
var states_at_drop := 0
var rewind_seen := false
var haste_seen := false
var convergence_error := INF
var convergence_started := -1.0
var validated := false
var result_seen := false
var fire_keys: Dictionary = {}
var exported := false
var last_suicide := 0.0
var playback_metrics := {"seconds": 0.0, "no_next_seconds": 0.0, "extrapolation_seconds": 0.0,
	"frozen_seconds": 0.0, "longest_freeze_seconds": 0.0, "repositions": 0, "max_samples": 0,
	"min_buffer_ticks": INF, "max_buffer_ticks": -INF}
var _before_playback := 0.0
var _predicted: Array = []
var _prediction_epoch := 0
var _timing_report := 0
var _last_state_us := 0
var _started_us := 0
var _freeze_seconds := 0.0
var _metrics_second := -1
var _baseline_us := 0
var _awaiting_state := false
var _process_us := 0
var _last_packet_us := 0
var _decode_gap := false
var _sample: Dictionary = {}
var _sample_wall := 0.0
var _sample_tick := 0.0
var _sample_cap := false
var _sample_stall := 0.0
var _sample_state_wall := 0.0
var _clock_wall := 0.0
var _network_workload := false
var _network_metrics := {"index": 0, "state_gaps_ms": [], "ping_ms": [], "throttle": [],
	"baseline_seconds": [], "wire_bytes": 0, "wire_packets": 0, "state_count": 0, "baselines": 0,
	"playback_trace": [], "state_packets": 0, "decode_misses": 0, "state_packet_gaps_ms": []}

func _ready() -> void:
	process_priority = 200
	var args := OS.get_cmdline_user_args()
	index = int(args[args.find("--index") + 1])
	_network_metrics["index"] = index
	_started_us = Time.get_ticks_usec()
	_clock_wall = Time.get_unix_time_from_system()
	_network_workload = args.has("--network-sample")
	count = int(args[args.find("--count") + 1])
	port = int(args[args.find("--port") + 1])
	mode = args[args.find("--mode") + 1]
	drop = args.has("--drop")
	exported = args.has("--exported")
	NetBus.event_received.connect(on_event)
	NetBus.state_received.connect(on_state)
	multiplayer.connected_to_server.connect(on_connected)
	multiplayer.peer_packet.connect(on_packet)
	PvpSession.server_port = port
	PvpSession.server_address = "127.0.0.1"
	assert(NetBus.start_client("127.0.0.1", port) == OK)
	print("MATCH CLIENT CONNECTING index=%d" % index)
	if args.has("--none"):
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_host().compress(ENetConnection.COMPRESS_NONE)

func on_connected() -> void:
	if game != null:
		return
	NetBus.send_event(NetEvent.Kind.HELLO, {"name": "Bot%d" % index, "hue": float(index * 35)})
	if index == 0 and code.is_empty():
		var map_path := "res://tests/network/arena.cyrm" if _network_workload else "res://maps/newfactory.cyrm"
		NetBus.send_event(NetEvent.Kind.CREATE, {"mode": mode, "options": {"map": map_path, "max_players": count, "match_time": 300, "beta": true, "time": TimeRules.new().to_dict()}})
	else:
		NetBus.send_event(NetEvent.Kind.LIST, {"beta": true, "token": token})

func on_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.FIRE:
			assert(data["role"] != PvpSession.role)
			var key := (int(data["role"]) << 48) | int(data["shot"])
			assert(not fire_keys.has(key))
			fire_keys[key] = true
		NetEvent.Kind.MESSAGE:
			trace_playback("message", data)
			if data.begins_with("NETWORK SAMPLE "):
				_sample = JSON.parse_string(data.trim_prefix("NETWORK SAMPLE "))
				_sample.merge({"observed_seconds": 0.0, "stall_seconds": 0.0, "longest_stall_seconds": 0.0,
					"max_frame_ms": 0.0, "outage_seconds": 0.0, "baseline_changes": 0, "complete": false,
					"state_gaps_ms": [], "ping_ms": []})
				_network_metrics["network_sample"] = _sample
			match data:
				"TEST HASTE": game._local.input_source.phase = "haste"
				"TEST REWIND": game._local.input_source.phase = "rewind"
				"TEST BATTLE": game._local.input_source.phase = "battle"
				"TEST DROP":
					if drop:
						drop_connection()
				"CHECK CONVERGENCE":
					game._local.input_source.phase = "stopped"
					convergence_started = elapsed
		NetEvent.Kind.ROOMS:
			if not data.is_empty():
				code = data[0]["code"]
				NetBus.send_event(NetEvent.Kind.JOIN, {"code": code, "invite": "", "beta": true})
			else:
				await get_tree().create_timer(0.2).timeout
				NetBus.send_event(NetEvent.Kind.LIST, {"beta": true, "token": token})
		NetEvent.Kind.ROOM:
			if result_seen:
				assert(data["code"] == code and data["token"] == token and not data["in_match"])
				NetBus.event_received.disconnect(on_event)
				set_physics_process(false)
				for i in 2:
					await get_tree().process_frame
				assert(get_tree().current_scene is LobbyPage and PvpSession.room["code"] == code)
				NetSession.close()
				while not Level0._reap_queue.is_empty():
					await get_tree().process_frame
				print("MATCH CLIENT OK index=%d states=%d baselines=%d haste=%s rewind=%s error=%.3f result=true same_room=true" % [index, snapshots, baselines, haste_seen, rewind_seen, convergence_error])
				report_metrics()
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
				if mode != "pvp":
					NetBus.send_event(NetEvent.Kind.START, 0)
		NetEvent.Kind.BASELINE:
			if not _sample.is_empty() and sample_clock() >= _sample["start"] and sample_clock() < _sample["end"]:
				_sample["baseline_changes"] += 1
			_baseline_us = Time.get_ticks_usec()
			_awaiting_state = true
			baselines += 1
			trace_playback("baseline_received", data["frame"]["tick"])
			_network_metrics["baseline_seconds"].append((Time.get_ticks_usec() - _started_us) / 1000000.0)
			print("BASELINE RECEIVED t=%.1f tick=%d bytes=%d" % [elapsed, data["frame"]["tick"], var_to_bytes(data).size()])
			if game == null:
				PvpSession.baseline = data
				PvpSession.beta_mode = true
				game = PvpMatchClient.new()
				game.tree_exiting.connect(func() -> void:
					started = false
					set_process(false)
					set_physics_process(false))
				get_tree().root.add_child(game)
				get_tree().current_scene = game
				started = true
				game._local.set_input_source(BotInput.new())
				NetBus.state_received.connect(_after_state)
				NetBus.event_received.connect(_after_event)
				_after_event(0, kind, data)
				print("MATCH CLIENT BASELINE index=%d bytes=%d" % [index, var_to_bytes(data).size()])
		NetEvent.Kind.ROUND:
			trace_playback("round", {"round": data["round"], "state": data["state"]})
			if data["state"] == NetEvent.RoundState.MATCH_OVER:
				if exported:
					validated = snapshots > 100 and baselines >= 2
				assert(validated)
				set_physics_process(false)
				NetBus.state_received.disconnect(on_state)
				NetBus.state_received.disconnect(_after_state)
				result_seen = true
				await get_tree().process_frame
				assert(game._result != null, "MATCH CLIENT FAIL missing result panel")
				assert(game._result.visible and game._last_round_state["state"] == NetEvent.RoundState.MATCH_OVER and not fire_keys.is_empty())
				game._result.leave_requested.emit()

class BotInput:
	extends LocalInputSource
	var ticks := 0
	var phase := "battle"
	func _axis_raw(neg: String, _pos: String) -> float:
		if neg != "left" or phase == "stopped":
			return 0.0
		return 1.0 if ticks % 240 < 120 else -1.0
	func _action_just_pressed_raw(action: String) -> bool:
		return phase != "stopped" and action == "up" and ticks % 60 == 0
	func _action_pressed_raw(action: String) -> bool:
		return (action == "haste" and phase == "haste") or (action == "rewind" and phase == "rewind")
	func _attack_pressed_raw() -> bool:
		return phase == "battle" and ticks % 60 < 30
	func _attack_just_pressed_raw() -> bool:
		return phase == "battle" and ticks % 60 == 0
	func _attack_just_released_raw() -> bool:
		return phase == "battle" and ticks % 60 == 30
	func get_aim_dir_override() -> Vector2:
		return Vector2.RIGHT

func on_packet(_peer: int, packet: PackedByteArray) -> void:
	if packet[0] != NetCodec.STATE:
		return
	var now := Time.get_ticks_usec()
	if _last_packet_us > 0:
		_network_metrics["state_packet_gaps_ms"].append((now - _last_packet_us) / 1000.0)
	_last_packet_us = now
	_network_metrics["state_packets"] += 1
	var number := packet.decode_u32(1)
	var codec: NetCodec = NetBus._codecs[1]
	var missed := number > codec.latest
	if missed:
		_network_metrics["decode_misses"] += 1
	if missed != _decode_gap:
		trace_playback("decode_gap_start" if missed else "decode_gap_end",
			{"number": number, "base": packet.decode_u32(5), "latest": codec.latest})
	_decode_gap = missed

func on_state(frame: Dictionary) -> void:
	var now := Time.get_ticks_usec()
	var wall := sample_clock()
	if not _sample.is_empty() and wall >= _sample["start"] and wall < _sample["end"]:
		if _sample_state_wall >= _sample["start"]:
			_sample["state_gaps_ms"].append((wall - _sample_state_wall) * 1000.0)
		_sample_state_wall = wall
	if _awaiting_state:
		trace_playback("state_after_baseline", frame["tick"])
		_awaiting_state = false
	if _last_state_us > 0:
		_network_metrics["state_gaps_ms"].append((now - _last_state_us) / 1000.0)
	_last_state_us = now
	if game != null:
		_before_playback = game._playback.render_tick
	snapshots += 1
	rewind_seen = rewind_seen or frame["world"]["players"].values().any(func(player: Dictionary) -> bool: return player["rewind"])
	haste_seen = haste_seen or frame["world"]["players"].values().any(func(player: Dictionary) -> bool: return player["haste"])
	if convergence_started >= 0 and elapsed - convergence_started > 1 and game != null \
			and _prediction_epoch == frame["own"]["epoch"] and _predicted.size() > 1 \
			and _predicted[0]["tick"] <= frame["tick"] and frame["tick"] <= _predicted[-1]["tick"]:
		for i in range(1, _predicted.size()):
			var to: Dictionary = _predicted[i]
			if to["tick"] >= frame["tick"]:
				var from: Dictionary = _predicted[i - 1]
				var weight: float = float(frame["tick"] - from["tick"]) / (to["tick"] - from["tick"])
				var movement := GridPathfinder.toroidal_delta_px(from["pos"], to["pos"], GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
				var predicted: Vector2 = to["pos"] if weight >= 1 else from["pos"]
				if movement.length() < 256:
					predicted = from["pos"] + movement * weight
				convergence_error = GridPathfinder.toroidal_delta_px(frame["own"]["state"]["pos"], predicted,
						GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
				break

func _after_state(_frame: Dictionary) -> void:
	if not is_equal_approx(_before_playback, game._playback.render_tick):
		playback_metrics["repositions"] += 1
	if game._rollback.epoch != _prediction_epoch:
		_prediction_epoch = game._rollback.epoch
		_predicted.clear()

func trace_playback(kind: String, data: Variant = null) -> void:
	_network_metrics["playback_trace"].append({"kind": kind, "data": data,
		"seconds": (Time.get_ticks_usec() - _started_us) / 1000000.0,
		"wall_seconds": Time.get_unix_time_from_system(), "baselines": baselines})

func _after_event(_peer: int, kind: int, _data: Variant) -> void:
	if kind == NetEvent.Kind.BASELINE and _baseline_us > 0:
		trace_playback("baseline_applied", (Time.get_ticks_usec() - _baseline_us) / 1000.0)
		_baseline_us = 0

func finish_freeze() -> void:
	if _freeze_seconds > 0:
		trace_playback("freeze_end", _freeze_seconds)
	_freeze_seconds = 0.0

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

func _process(delta: float) -> void:
	sample_network()
	var now := Time.get_ticks_usec()
	if _process_us > 0 and now - _process_us > 100000:
		trace_playback("slow_frame", (now - _process_us) / 1000.0)
	_process_us = now
	if int((Time.get_ticks_usec() - _started_us) / 1000000) > _metrics_second:
		_metrics_second += 1
		report_metrics()
	if game == null or result_seen or game.phase != PvpMatchClient.Phase.ONLINE or game._playback.frames.is_empty():
		finish_freeze()
		return
	var buffer := game._playback
	var camera := game._world.get_node("Camera2D")
	assert(camera.target == game._local.visuals)
	assert(is_equal_approx(camera.get_base_global_position().x, game._local.visuals.global_position.x))
	if _predicted.is_empty() or _predicted[-1]["tick"] < game._rollback._sim_tick:
		_predicted.append({"tick": game._rollback._sim_tick, "pos": game._local.position})
		if _predicted.size() > 128:
			_predicted.pop_front()
	var gap: float = buffer.frames[-1]["tick"] - buffer.render_tick
	playback_metrics["seconds"] += delta
	playback_metrics["max_samples"] = maxi(playback_metrics["max_samples"], buffer.frames.size())
	playback_metrics["min_buffer_ticks"] = minf(playback_metrics["min_buffer_ticks"], gap)
	playback_metrics["max_buffer_ticks"] = maxf(playback_metrics["max_buffer_ticks"], gap)
	if gap <= 0.0:
		playback_metrics["no_next_seconds"] += delta
		if gap > -SnapshotBuffer.MAX_EXTRAPOLATION:
			playback_metrics["extrapolation_seconds"] += delta
		else:
			if _freeze_seconds == 0:
				trace_playback("freeze_start", {"tick": buffer.frames[-1]["tick"], "delta_ms": delta * 1000.0})
			playback_metrics["frozen_seconds"] += delta
			_freeze_seconds += delta
			playback_metrics["longest_freeze_seconds"] = maxf(playback_metrics["longest_freeze_seconds"], _freeze_seconds)
			return
	finish_freeze()

func report_metrics() -> void:
	var wall := sample_clock()
	if not _sample.is_empty() and wall >= _sample["start"] and wall < _sample["end"]:
		_sample["ping_ms"].append(NetBus.ping_ms)
	if NetBus.can_send_to_server():
		var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
		_network_metrics["ping_ms"].append(NetBus.ping_ms)
		_network_metrics["throttle"].append(peer.get_peer(1).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE))
		_network_metrics["wire_bytes"] += peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		_network_metrics["wire_packets"] += peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
	_network_metrics["state_count"] = snapshots
	_network_metrics["baselines"] = baselines
	_network_metrics["convergence_error"] = convergence_error
	_network_metrics["converged"] = validated
	_network_metrics["haste_seen"] = haste_seen
	_network_metrics["rewind_seen"] = rewind_seen
	_network_metrics["states_after_drop"] = snapshots - states_at_drop if reconnected else 0
	print("NETWORK METRICS " + JSON.stringify(_network_metrics))
	print("PLAYBACK METRICS " + JSON.stringify(playback_metrics))

func _physics_process(delta: float) -> void:
	if not started:
		return
	elapsed += delta
	if elapsed >= _timing_report:
		_timing_report += 5
		if NetBus.can_send_to_server():
			var peer := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(1)
			print("CLIENT TIMING t=%.1f tick=%d own_tick=%d clock=%.1f lead=%.1f ping=%d throttle=%d map=%d phase=%s" % [elapsed,
				game._last_tick, game._own_tick, game._rollback._clock, game._rollback._lead, NetBus.ping_ms,
				peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE), game._map_revision, game._local.input_source.phase])
	if game._local.input_source is BotInput:
		if exported and elapsed > 3.8:
			game._local.input_source.phase = "stopped"
		game._local.input_source.ticks += 1
	if exported and index == 1 and elapsed - last_suicide > 2.5 and elapsed > 3.8 \
			and game._last_round_state["state"] == NetEvent.RoundState.PLAYING and not game._local.is_downed():
		last_suicide = elapsed
		NetBus.send_event(NetEvent.Kind.SUICIDE)
	if exported and drop and not reconnected and elapsed > 6:
		drop_connection()
	if convergence_started >= 0 and elapsed - convergence_started > 3 and not validated:
		var resumed := not drop or (snapshots - states_at_drop > 60 and game.phase == PvpMatchClient.Phase.ONLINE)
		if snapshots > 100 and baselines >= 2 and resumed and convergence_error < 2.0 and haste_seen and rewind_seen:
			validated = true
			NetBus.send_event(NetEvent.Kind.MESSAGE, "CHECK OK")
			print("CONVERGENCE OK index=%d error=%.3f" % [index, convergence_error])
		elif elapsed - convergence_started > 12:
			push_error("MATCH CLIENT FAIL states=%d baselines=%d resumed=%s haste=%s rewind=%s error=%.3f" % [snapshots, baselines, resumed, haste_seen, rewind_seen, convergence_error])
			get_tree().quit(1)

func drop_connection() -> void:
	trace_playback("disconnect")
	reconnected = true
	states_at_drop = snapshots
	NetBus.stop()
	game._begin_reconnect()
