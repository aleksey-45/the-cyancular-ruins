extends Node

class PostView extends PostProcess:
	func _ready() -> void: pass
	func set_downed(_downed: bool) -> void: pass

class MatchView extends PvpMatchClient:
	var probe: Node
	func _ready() -> void:
		process_priority = 1
		set_process(false)
	func _process(delta: float) -> void:
		if phase == PvpMatchClient.Phase.ONLINE:
			var time := _rollback._clock - _rollback._rate * (1.0 - Engine.get_physics_interpolation_fraction())
			_local.present_prediction(delta, time - _rollback._sim_tick)
	func _exit_tree() -> void: pass
	func _apply_authority(frame: Dictionary) -> void:
		if not Engine.is_in_physics_frame():
			print("MOVEMENT PROBE FAIL reconciliation ran in render frame")
			get_tree().quit(1)
			return
		var previous := _local.position
		super._apply_authority(frame)
		if frame["tick"] > 30:
			probe.record_correction(previous, _local.position)

var server := ENetMultiplayerPeer.new()
var api := SceneMultiplayer.new()
var codec := NetCodec.new()
var authority: CharacterBody2D
var game: MatchView
var tick := 0
var peer_id := 0
var started := false
var corrections := 0
var max_correction := 0.0
var fps := 144
var last_display := Vector2.ZERO
var display_samples := 0
var stationary_frames := 0
var display_seconds := 0.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--fps"): fps = int(args[args.find("--fps") + 1])
	Engine.max_fps = fps
	process_physics_priority = -100
	process_priority = 200
	PvpSession.role = 1
	PvpSession.beta_mode = false
	Level0.pvp_mode = true
	MazeGenerator.current_grid = []
	GameParameters.MAP_WIDTH = 8192
	GameParameters.MAP_HEIGHT = 1024
	authority = actor()
	add_child(authority)
	authority.set_physics_process(false)
	game = MatchView.new()
	game.probe = self
	add_child(game)
	game.phase = PvpMatchClient.Phase.OFFLINE
	game._world = SubViewport.new()
	game.add_child(game._world)
	game._local = actor()
	game._world.add_child(game._local)
	game._local.set_physics_process(false)
	game._local.interpolate_prediction = true
	game._local.correct_visual(game._local.global_position, true)
	game.set_process(true)
	game._local.input_source = PacketInputSource.new()
	game._local.input_source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	game._rollback.bind(game._local)
	game._rollback.reset(1, 0, 0, 0)
	game._playback.map_px = Vector2(8192, 1024)
	game._post = PostView.new()
	game.add_child(game._post)
	var server_root := Node.new()
	add_child(server_root)
	get_tree().set_multiplayer(api, server_root.get_path())
	assert(server.create_server(0, 1, 3) == OK)
	server.get_host().compress(ENetConnection.COMPRESS_ZSTD)
	api.server_relay = false
	api.multiplayer_peer = server
	api.peer_connected.connect(func(peer: int) -> void: peer_id = peer)
	api.peer_packet.connect(func(_peer: int, packet: PackedByteArray) -> void:
		codec.decode_input(ProtocolFixture.stream(packet)))
	NetBus.state_received.connect(game._on_state)
	multiplayer.connected_to_server.connect(func() -> void:
		started = true)
	assert(NetBus.start_client("127.0.0.1", server.get_host().get_local_port()) == OK)

func actor() -> CharacterBody2D:
	var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	player.role = 1
	player.position = Vector2(1000, 300)
	player.gravity = 0.0
	player.move_speed = 720.0
	player.velocity = Vector2(720, 0)
	player.collision_layer = 0
	player.collision_mask = 0
	player.set_physics_process(false)
	return player

func _physics_process(_delta: float) -> void:
	api.poll()
	if not started or peer_id == 0: return
	if tick == 0:
		Engine.max_fps = fps
		game.phase = PvpMatchClient.Phase.ONLINE
		game._rollback._input.seed(InputBuffer.neutral().merged({"ax": 1.0}, true))
	tick += 1
	game._rollback._rate = 0.96 if tick >= 40 and tick < 80 else 1.02 if tick >= 80 and tick < 120 else 1.0
	# 相同持续输入隔离网络到达时刻，测量重放时间步而非迟到输入产生的合理误差。
	var record := InputBuffer.neutral().merged({"ax": 1.0, "seq": maxi(0, tick - 2), "target_tick": tick}, true)
	ActorStep.step(authority, record)
	if tick % 2 == 0:
		var frame := ProtocolFixture.frame(tick)
		frame["own"]["state"] = authority.capture_state()
		frame["own"]["ack"] = record["seq"]
		frame["own"]["input"] = record
		assert(api.send_bytes(codec.encode_state(frame), peer_id, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, 2) == OK)
	server.get_host().flush()
	if tick == 180:
		print("MOVEMENT METRICS fps=%d corrections=%d max=%.6f tick=%d clock=%.2f" % [fps, corrections, max_correction, tick, game._rollback._clock])
		game.phase = PvpMatchClient.Phase.OFFLINE
		NetBus.stop()
		server.close()
		print("DISPLAY METRICS samples=%d stationary=%d average_fps=%.2f" % [display_samples, stationary_frames, display_samples / display_seconds])
		if corrections <= 50 or max_correction >= 0.02 or (fps > 60 and stationary_frames > 2):
			get_tree().quit(1)
			return
		print("MOVEMENT PROBE OK fps=%d corrections=%d max=%.6f physics replay" % [fps, corrections, max_correction])
		get_tree().quit()

func record_correction(previous: Vector2, current: Vector2) -> void:
	corrections += 1
	if previous.distance_to(current) > 0.02 and corrections <= 6:
		print("CORRECTION ", previous, " -> ", current, " sim=", game._rollback._sim_tick, " world=", tick)
	max_correction = maxf(max_correction, previous.distance_to(current))

func _process(delta: float) -> void:
	if tick < 30 or game.phase != PvpMatchClient.Phase.ONLINE: return
	var point: Vector2 = game._local.visuals.global_position
	if display_samples > 0:
		assert(point.x >= last_display.x)
		if point.distance_squared_to(last_display) < 0.000001: stationary_frames += 1
	last_display = point
	display_samples += 1
	display_seconds += delta
