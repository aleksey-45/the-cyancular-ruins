extends Node
const Tunnel := preload("res://core/net/tunnel.gd")
var large := PackedByteArray()
var cycles := 0
var got_state := false
var got_event := false
var host := false
var output := ""

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	host = args.has("--host")
	output = args[args.find("--output") + 1]
	var port := int(args[args.find("--port") + 1])
	var external := args.has("--rpc")
	if external:
		assert(Tunnel.available())
		Tunnel._rpc_port = int(args[args.find("--rpc") + 1])
		Tunnel._pid = NetSession.launch(Tunnel.core_exe(), PackedStringArray([
				"--config-file", args[args.find("--core-config") + 1], "--rpc-portal", "127.0.0.1:%d" % Tunnel._rpc_port]))
		assert(Tunnel._pid > 0)
		Tunnel._role = "host" if host else "guest"
		Tunnel._code = "00001234"
		write_info()
	large.resize(256 * 1024)
	for i in large.size():
		large[i] = (i * 7) % 251
	if host:
		assert(NetBus.start_server(port) == OK)
		NetBus.input_received.connect(func(peer: int, packet: Dictionary) -> void:
			assert(packet == ProtocolFixture.input())
			NetBus.send_state(peer, ProtocolFixture.frame(62)))
		NetBus.event_received.connect(func(peer: int, kind: int, data: Variant) -> void:
			assert(kind == NetEvent.Kind.READY and data == 1)
			var baseline := ProtocolFixture.baseline()
			baseline["map"] = large
			NetBus.send_event(NetEvent.Kind.BASELINE, baseline, peer))
		if not external:
			assert(Tunnel.start_host(port, "00001234"))
		assert(await Tunnel.wait_ready())
		write_info()
		print("TUNNEL HOST READY")
	else:
		if external:
			var target := await Tunnel._await_host_peer()
			assert(not target.is_empty())
			assert(await Tunnel.add_udp_forward(target["port"], target["ipv4"]))
		else:
			var target := await Tunnel.start_client("00001234")
			assert(not target.is_empty())
		write_info()
		multiplayer.connected_to_server.connect(func() -> void:
			NetBus.send_event(NetEvent.Kind.READY, 1))
		NetBus.state_received.connect(func(frame: Dictionary) -> void:
			assert(frame == ProtocolFixture.frame(62))
			got_state = true)
		NetBus.event_received.connect(func(_peer: int, kind: int, data: Variant) -> void:
			assert(kind == NetEvent.Kind.BASELINE and data["map"] == large and data["frame"] == ProtocolFixture.frame())
			got_event = true)
		for cycle in 2:
			got_event = false
			got_state = false
			NetBus.start_client("127.0.0.1", Tunnel.forward_port())
			var deadline := Time.get_ticks_msec() + 15000
			while (not got_event or not got_state) and Time.get_ticks_msec() < deadline:
				if got_event and not got_state:
					NetBus.send_input(ProtocolFixture.input())
				await get_tree().process_frame
			assert(got_event and got_state, "TUNNEL PEER FAIL cycle=%d connected=%s event=%s state=%s" % [
					cycle, NetBus.can_send_to_server(), got_event, got_state])
			NetBus.stop()
			if cycle == 0:
				assert(await Tunnel.refresh_forward())
		var peers := await Tunnel._cli_async(PackedStringArray(["--rpc-portal", "127.0.0.1:%d" % Tunnel._rpc_port, "-o", "json", "peer"]))
		var file := FileAccess.open(output + ".peers.json", FileAccess.WRITE)
		file.store_string(peers[1])
		file.close()
		print("TUNNEL PEER OK input, state, 256KiB baseline, reconnect, code=00001234")
		get_tree().quit()

func write_info() -> void:
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify({"core_pid": Tunnel._pid, "rpc": Tunnel._rpc_port}))
	file.close()
