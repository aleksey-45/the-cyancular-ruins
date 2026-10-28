extends PacketInputSource

var index := 0
var mode := "royale"
var stop := false
var ticks := 0

static func home(actor_index: int, actor_mode: String) -> Vector2i:
	var left := actor_index < 3 if actor_mode == "team" else actor_index % 2 == 0
	var lane := actor_index % 3 if actor_mode == "team" else actor_index / 2
	return Vector2i(6 if left else 26, 7 + lane * 10)

func advance(game: PvpMatchClient) -> void:
	var buttons := 0
	_axis = 0.0
	var seconds := ticks % 1200 / 60.0
	var goal := (Vector2(home(index, mode)) + Vector2.ONE * 0.5) * GameParameters.TILE_SIZE
	var inward := 1.0 if goal.x < GameParameters.MAP_WIDTH / 2.0 else -1.0
	if not stop and game._last_round_state["state"] == NetEvent.RoundState.PLAYING:
		ticks += 1
		if seconds < 0.6:
			_axis = inward
		elif seconds < 1.0:
			buttons = BIT_UP
		elif seconds < 3.0:
			_axis = clampf(GridPathfinder.toroidal_delta_px(game._local.position, goal,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).x / 32.0, -1.0, 1.0)
		elif seconds < 4.3:
			buttons = BIT_UP
		elif seconds < 5.3:
			buttons = BIT_DOWN
		elif seconds < 17.0:
			buttons = BIT_ATTACK if ticks % 30 < 24 else 0
		elif seconds < 18.0:
			buttons = BIT_RELOAD
		elif seconds < 19.0:
			buttons = BIT_HASTE
			_axis = inward
		elif seconds < 19.5:
			buttons = BIT_REWIND
	_pressed = buttons & ~_held
	_released = _held & ~buttons
	_held = buttons
	var target := (index + 3) % 6 + 1 if mode == "team" else index ^ 1
	for role in game._names:
		var opponent: bool = role == target if mode == "team" else game._names[role] == "Bot%d" % target
		if opponent and game._latest_players.has(role):
			_aim = GridPathfinder.toroidal_delta_px(game._local.position,
				game._latest_players[role]["pos"], GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).normalized()

func _switch_index_raw() -> int:
	return 1 + (ticks / 1200) % 2 if ticks % 1200 == 330 else 0
