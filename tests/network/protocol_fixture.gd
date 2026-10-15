class_name ProtocolFixture
extends RefCounted

static func input() -> Dictionary:
	var record := InputBuffer.neutral()
	for key in ["pressed", "released", "winst"]: record.erase(key)
	return {"frames": [record], "actions": []}

static func frame(tick: int = 60) -> Dictionary:
	var state := {"pos": Vector2(1000, 500), "vel": Vector2.ZERO, "knock": Vector2.ZERO,
			"floor": true, "jcut": false, "squat": false, "charge": false, "wp_s": false, "clatch": false, "swim": false, "down": false,
			"haste_mult": 1.0, "slock": 0.0, "coyote": 0.0, "jbuf": 0.0, "ct": 0.0, "lmv_t": 0.0,
			"wp": 100, "wp_t": 0.0, "wp_d": 0.0, "ifr": 0.0, "shot_serial": 0,
			"facing": 1, "state": 1, "lmv_d": 0, "hp": 100, "winst": 0, "inv": []}
	var actor := {"pos": state["pos"], "vel": state["vel"], "aim": Vector2.RIGHT, "facing": 1, "pose": 1, "type_id": 0,
			"hp": 100, "waterproof": 100, "epoch": 1, "downed": false, "previewing": false, "haste": false, "rewind": false}
	return {"tick": tick, "map_revision": 0, "world": {"players": {1: actor}, "pickups": {}},
			"own": {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2, "rewind": false,
			"input": InputBuffer.neutral(), "state": state}, "time": {}}

static func baseline() -> Dictionary:
	return {"code": "00001234", "mode": PvpSession.MODE_PVP, "role": 1, "options": {}, "names": {1: "测试玩家"},
			"hues": {1: 0.125}, "teams": {}, "spawns": {1: Vector2i(3, 7)}, "map": PackedByteArray([67, 89, 82]),
			"sub_hp": {Vector2i(4, 8): 7}, "round_state": {"state": NetEvent.RoundState.COUNTDOWN, "round": 1,
			"timer": 3.0, "winner": 0, "match_winner": 0, "mvp": 1, "scores": {}, "rounds_won": {}, "deaths": {1: 0},
			"left": [], "grace": {}, "alive": {1: true}, "stats": {1: {"kills": 0, "deaths": 0, "assists": 0,
			"dealt": 0, "taken": 0, "kscore": 0, "acs": 0.0}}}, "frame": frame(), "projectiles": {}}

static func stream(packet: PackedByteArray) -> StreamPeerBuffer:
	var s := StreamPeerBuffer.new()
	s.data_array = packet
	s.get_u8()
	return s
