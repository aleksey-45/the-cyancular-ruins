class_name PvpMatchClient
extends MatchController

const PhaseRule := MatchRules.Phase
enum Phase { LOADING, ONLINE, RECONNECTING, OFFLINE }
var phase := Phase.LOADING
signal input_sampled(packet: Array)
var session: PredictedMatch
var _baseline: Dictionary
var _pause_open := false

func _enter_tree() -> void:
	_baseline = PvpSession.baseline
	PvpSession.baseline = {}
	session = PredictedMatch.new(_baseline, NetBus.ping_ms)
	_bind(session.world, session.role)

func _ready() -> void:
	_mount_session(Settings.pvp_show_minimap)
	_view.pause.toggled.connect(_set_pause)
	_view.pvp_hud.leave_requested.connect(_leave_result)
	NetBus.ping_updated.connect(_view.pvp_hud.set_ping)
	input_sampled.connect(NetBus.send_input)
	_presenter.names = _baseline["names"]
	_presenter.hues = _baseline["hues"]
	NetBus.event_received.connect(_on_event)
	NetBus.server_disconnected.connect(_begin_reconnect)
	NetBus.protocol_error.connect(_go_offline)
	_baseline_ready()
	_baseline = {}

func _baseline_ready() -> void:
	_reset_sampler()
	_sampler.accept(session.baseline_view())
	phase = Phase.ONLINE
	_view.pvp_hud.set_status("")
	_refresh_input_lock()
	NetBus.send_event(NetEvent.Kind.READY, session.latest_authority["checkpoint"]["rules"][MatchRules.State.NUMBER])

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.BASELINE:
			session.install(data, NetBus.ping_ms)
			_baseline_ready()
		NetEvent.Kind.ROOM:
			if not data["in_match"]:
				phase = Phase.OFFLINE
				SceneTransition.change(get_tree(), "res://scenes/mp_lobby.tscn")
		NetEvent.Kind.REJOIN_DENIED: _go_offline(data)
		NetEvent.Kind.ROOM_CLOSED:
			phase = Phase.OFFLINE
			NetSession.disconnect_client()
			SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _physics_process(delta: float) -> void:
	for message: Array in NetSession.take_match_inbox():
		match message[0]:
			NetSession.MatchMessage.ROUND:
				session.install(message[1], NetBus.ping_ms)
				_baseline_ready()
			NetSession.MatchMessage.TERRAIN:
				session.receive_terrain(message[1])
			NetSession.MatchMessage.STATE:
				session.receive_state(message[1])
	if phase == Phase.ONLINE:
		var started := PerformanceStats.begin()
		var update := session.reconcile(NetBus.ping_ms)
		_refresh_input_lock()
		update.merge(session.predict(_sample_input(delta)))
		input_sampled.emit(update["input"])
		_sampler.accept(update)
		PerformanceStats.end(PerformanceStats.CLIENT_TICK, started)

func _process(delta: float) -> void:
	if phase == Phase.ONLINE:
		var started := PerformanceStats.begin()
		super(delta)
		PerformanceStats.end(PerformanceStats.CLIENT_PRESENT, started)

func _round_phase() -> int:
	return session.latest_authority["checkpoint"]["rules"][MatchRules.State.PHASE]

func _leave_match() -> void:
	NetSession.disconnect_client()
	super()

func _leave_result() -> void:
	_view.pvp_hud.set_status("等待其他玩家返回房间…")
	NetBus.send_event(NetEvent.Kind.LEAVE)

func _refresh_input_lock() -> void:
	controls.frozen = phase != Phase.ONLINE or _pause_open or _round_phase() != PhaseRule.PLAYING

func _set_pause(open: bool) -> void:
	_pause_open = open
	_refresh_input_lock()

func _unhandled_input(event: InputEvent) -> void:
	super(event)
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_K \
			and phase == Phase.ONLINE and _round_phase() != PhaseRule.MATCH_OVER:
		NetBus.send_event(NetEvent.Kind.SUICIDE)

func _begin_reconnect() -> void:
	if phase != Phase.ONLINE:
		return
	phase = Phase.RECONNECTING
	_refresh_input_lock()
	_view.pvp_hud.set_status("正在重连…")
	var error := await NetSession.rejoin_room(true)
	if not error.is_empty() and phase == Phase.RECONNECTING and is_inside_tree():
		_go_offline(error)

func _go_offline(message: String) -> void:
	phase = Phase.OFFLINE
	_refresh_input_lock()
	_view.pvp_hud.set_status(message)

func _exit_tree() -> void:
	if phase == Phase.RECONNECTING:
		NetSession.disconnect_client()
	super()
