extends Node

func start_test_tunnel(host: bool, game_port: int) -> int:
	var args := OS.get_cmdline_user_args()
	if not args.has("--tunnel-config"):
		return game_port
	Tunnel._core_path = args[args.find("--tunnel-core") + 1]
	Tunnel._cli_path = args[args.find("--tunnel-cli") + 1]
	Tunnel._rpc_port = int(args[args.find("--tunnel-rpc") + 1])
	Tunnel._code = args[args.find("--tunnel-code") + 1]
	Tunnel._role = "host" if host else "guest"
	var command := PackedStringArray(["--config-file", args[args.find("--tunnel-config") + 1],
		"--rpc-portal", "127.0.0.1:%d" % Tunnel._rpc_port])
	command.append_array(Tunnel.file_log_args(Tunnel._role))
	Tunnel._pid = NetSession.launch(Tunnel.core_exe(), command)
	assert(Tunnel._pid > 0)
	print("MATCH TUNNEL STARTED " + JSON.stringify({"rpc": Tunnel._rpc_port, "core_pid": Tunnel._pid,
		"log_dir": Tunnel._log_dir}))
	if host:
		return game_port
	var target := await Tunnel._await_host_peer()
	assert(not target.is_empty(), "MATCH CLIENT FAIL tunnel host not found")
	assert(await Tunnel.add_udp_forward(target["port"], target["ipv4"]))
	return Tunnel.forward_port()
