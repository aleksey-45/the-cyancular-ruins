extends Node

var server := ENetMultiplayerPeer.new()
var clients: Array[ENetMultiplayerPeer] = []
var server_api := SceneMultiplayer.new()
var client_apis: Array[SceneMultiplayer] = []
var trace: Dictionary
var phase := ""
var tick := 0
var cursor := 0
var received := 0
var baseline_received := 0
var app_bytes := 0
var samples: Array = []
var result := {}
var output := ""
var legacy := false
var server_codecs: Array[NetCodec] = []
var client_codecs: Array[NetCodec] = []
var expected_states: Array[Dictionary] = []
var profiles: Array = []
var decoded_states := 0
var missing_bases := 0

func _ready() -> void:
	set_physics_process(false)
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	output = args[args.find("--output") + 1]
	legacy = args.has("--legacy")
	trace = FileAccess.open(args[args.find("--trace") + 1], FileAccess.READ).get_var()
	if not legacy:
		for type_id in WeaponRegistry.all_ids():
			var weapon: WeaponBase = load(WeaponRegistry.scene_of(type_id)).instantiate()
			if not weapon is LaserWeaponBase:
				profiles.append(WeaponRegistry.projectile_profile(type_id).merged({"type_id": type_id}))
			weapon.free()
		for entry in trace["baselines"]: entry["payload"]["frame"] = compact_frame(entry["payload"]["frame"])
		for entry in trace["messages"]:
			if entry["flow"] == 1: entry["payload"] = compact_frame(entry["payload"])
	trace["messages"].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["tick"] < b["tick"])
	var count: int = trace["count"]
	var compression := ENetConnection.COMPRESS_NONE if args.has("--none") else ENetConnection.COMPRESS_ZSTD
	get_tree().multiplayer_poll = false
	assert(server.create_server(0, count, 3) == OK)
	server.get_host().compress(compression)
	var server_root := Node.new()
	add_child(server_root)
	get_tree().set_multiplayer(server_api, server_root.get_path())
	server_api.server_relay = false
	server_api.multiplayer_peer = server
	server_api.peer_packet.connect(func(peer: int, packet: PackedByteArray) -> void:
		received += 1
		if legacy: bytes_to_var(packet)
		else:
			for i in client_apis.size():
				if client_apis[i].get_unique_id() == peer:
					server_codecs[i].decode_input(ProtocolFixture.stream(packet))
					break)
	for i in count:
		server_codecs.append(NetCodec.new())
		client_codecs.append(NetCodec.new())
		expected_states.append({})
		var peer := ENetMultiplayerPeer.new()
		assert(peer.create_client("127.0.0.1", server.get_host().get_local_port(), 3) == OK)
		peer.get_host().compress(compression)
		clients.append(peer)
		var root := Node.new()
		add_child(root)
		var api := SceneMultiplayer.new()
		get_tree().set_multiplayer(api, root.get_path())
		api.server_relay = false
		api.multiplayer_peer = peer
		client_apis.append(api)
		api.peer_packet.connect(func(_peer: int, packet: PackedByteArray) -> void:
			received += 1
			if legacy:
				var message: Array = bytes_to_var(packet)
				if message[0] == 2 and message[1][0] == NetEvent.Kind.BASELINE:
					assert(packet == var_to_bytes([2, [NetEvent.Kind.BASELINE, trace["baselines"][i]["payload"]]]))
					baseline_received += 1
			else:
				var s := StreamPeerBuffer.new()
				s.data_array = packet
				var code := s.get_u8()
				if code == NetCodec.STATE:
					var frame := client_codecs[i].decode_state(s)
					if frame.is_empty(): missing_bases += 1
					else:
						assert(frame == expected_states[i][client_codecs[i].latest])
						decoded_states += 1
				else:
					var data: Variant = client_codecs[i].decode_event(code - NetCodec.EVENT, s)
					if code - NetCodec.EVENT == NetEvent.Kind.BASELINE:
						assert(data == trace["baselines"][i]["payload"])
						baseline_received += 1)
	set_physics_process(true)
	var deadline := Time.get_ticks_msec() + 5000
	while server_api.get_peers().size() != count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	assert(server_api.get_peers().size() == count)
	reset_counters()
	phase = "baseline"
	var started := Time.get_ticks_usec()
	print("WIRE START baseline")
	mark("baseline:start")
	for entry: Dictionary in trace["baselines"]:
		send(entry["role"], 2, [NetEvent.Kind.BASELINE, entry["payload"]])
	deadline = Time.get_ticks_msec() + 10000
	while baseline_received < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	assert(baseline_received == count)
	await get_tree().create_timer(0.2).timeout
	result["baseline"] = finish_phase(started)
	mark("baseline:end")
	phase = ""
	await get_tree().create_timer(0.05).timeout
	reset_counters()
	phase = "battle"
	started = Time.get_ticks_usec()
	print("WIRE START battle")
	mark("battle:start")
	while tick <= trace["ticks"]:
		await get_tree().physics_frame
	phase = ""
	await get_tree().create_timer(0.2).timeout
	result["battle"] = finish_phase(started)
	mark("battle:end")
	await get_tree().create_timer(0.05).timeout
	result["compression"] = "none" if args.has("--none") else "zstd"
	result["layout"] = "variant_full" if legacy else "binary_delta"
	result["delta_ack"] = "fixed three snapshot intervals (100 ms), replay only"
	result["count"] = count
	var file := FileAccess.open(args[args.find("--output") + 1], FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	for peer in clients:
		peer.close()
	server.close()
	print("WIRE BENCHMARK OK")
	get_tree().quit()

func mark(value: String) -> void:
	var file := FileAccess.open(output + ".phase", FileAccess.WRITE)
	file.store_string(value + ":" + str(OS.get_process_id()))
	file.close()

func _physics_process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	server_api.poll()
	for api in client_apis:
		api.poll()
	if phase == "battle":
		while cursor < trace["messages"].size() and trace["messages"][cursor]["tick"] <= tick:
			var entry: Dictionary = trace["messages"][cursor]
			send(entry["role"], entry["flow"], entry["payload"])
			cursor += 1
		tick += 1
	server.get_host().flush()
	for peer in clients:
		peer.get_host().flush()
	if not phase.is_empty():
		samples.append(Time.get_ticks_usec() - started)

func send(role: int, flow: int, payload: Variant) -> void:
	var packet: PackedByteArray
	var codec := server_codecs[role - 1]
	if legacy: packet = var_to_bytes([flow, payload])
	elif flow == 0:
		client_codecs[role - 1].state_ack = maxi(0, codec.serial - 3)
		packet = client_codecs[role - 1].encode_input(payload)
	elif flow == 1:
		# 固定 ACK 年龄使 NONE/Zstd 编码完全一致；生产使用真实接收确认。
		codec.state_ack = maxi(0, codec.serial - 3)
		packet = codec.encode_state(payload)
		expected_states[role - 1][codec.serial] = payload
	else: packet = codec.encode_event(payload[0], payload[1])
	app_bytes += packet.size()
	if flow == 0:
		assert(client_apis[role - 1].send_bytes(packet, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, 1) == OK)
	else:
		var target := client_apis[role - 1].get_unique_id()
		assert(server_api.send_bytes(packet, target, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED if flow == 1 else MultiplayerPeer.TRANSFER_MODE_RELIABLE, 2 if flow == 1 else 0) == OK)

func reset_counters() -> void:
	for peer in [server] + clients:
		peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
	app_bytes = 0
	received = 0
	decoded_states = 0
	missing_bases = 0
	samples.clear()

func finish_phase(started: int) -> Dictionary:
	var bytes := 0.0
	var packets := 0.0
	for peer in [server] + clients:
		bytes += peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		packets += peer.get_host().pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
	samples.sort()
	var mean := 0.0
	for value in samples:
		mean += value
	mean /= samples.size()
	var metrics := {"udp_payload_bytes": bytes, "udp_packets": packets, "application_bytes": app_bytes,
		"elapsed_ms": (Time.get_ticks_usec() - started) / 1000.0, "messages_received": received,
		"decoded_states": decoded_states, "missing_bases": missing_bases,
		"frame_dispatch_mean_us": mean, "frame_dispatch_p95_us": samples[int(samples.size() * 0.95)]}
	print("WIRE END " + phase if not phase.is_empty() else "WIRE END battle")
	return metrics

# 只用于重放上一提交捕获的完整 Variant 记录，不属于生产协议。
func compact_frame(source: Dictionary) -> Dictionary:
	var frame := source.duplicate(true)
	frame["own"]["input"] = InputBuffer.neutral().merged(frame["own"]["input"], true)
	for id in frame["world"]["projectiles"]:
		var data: Dictionary = frame["world"]["projectiles"][id]
		var type_id := 0
		for profile in profiles:
			if profile["scene"].resource_path == data["scene"] and profile["range"] == data["range"] \
					and profile["size"] == data["size"] and profile["color"] == data["color"]:
				type_id = profile["type_id"]
				break
		assert(type_id != 0)
		frame["world"]["projectiles"][id] = {"type_id": type_id, "input_seq": data["input_seq"], "input_epoch": data["input_epoch"], "pos": data["pos"], "vel": data["vel"]}
	for data in frame["world"]["pickups"].values(): data.erase("inst")
	return frame
