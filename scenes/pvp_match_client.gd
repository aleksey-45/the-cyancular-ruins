class_name PvpMatchClient
extends MatchController

const PhaseRule := MatchRules.Phase
enum Phase { LOADING, ONLINE, RECONNECTING, OFFLINE }
var phase := Phase.LOADING
var _inbox: Array = []
var _baseline: Dictionary

func _enter_tree() -> void:
	_baseline = PvpSession.baseline
	PvpSession.baseline = {}
	_inbox = NetSession.take_match_inbox()
	NetBus.manual_poll = true
	session = MatchSession.open_remote(_baseline, NetBus.ping_ms)
	super()

func _ready() -> void:
	_mount_session()
	_view.pvp_hud.leave_requested.connect(_leave_result)
	NetBus.ping_updated.connect(_view.pvp_hud.set_ping)
	NetBus.state_received.connect(_on_state)
	NetBus.event_received.connect(_on_event)
	NetBus.server_disconnected.connect(_begin_reconnect)
	NetBus.protocol_error.connect(_go_offline)
	_baseline_ready(_baseline)
	_baseline = {}

func _baseline_ready(payload: Dictionary) -> void:
	_presenter.names.merge(payload["names"], true)
	_presenter.hues.merge(payload["hues"], true)
	phase = Phase.ONLINE
	_view.pvp_hud.set_status("")
	_refresh_input_lock()
	NetBus.send_event(NetEvent.Kind.READY, payload["frame"]["checkpoint"]["rules"][MatchRules.State.NUMBER])

func _on_state(frame: Dictionary) -> void:
	_inbox.append([-1, frame])

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.BASELINE, NetEvent.Kind.TERRAIN:
			_inbox.append([kind, data])
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
	NetBus.poll_messages()
	for message: Array in _inbox:
		match message[0]:
			NetEvent.Kind.BASELINE:
				session.install(message[1], NetBus.ping_ms)
				_reset_sampler()
				_baseline_ready(message[1])
			NetEvent.Kind.TERRAIN:
				session.receive_terrain(message[1])
			-1:
				session.receive_state(message[1])
	_inbox.clear()
	if phase == Phase.ONLINE:
		var started := PerformanceStats.begin()
		super(delta)
		_refresh_input_lock()
		PerformanceStats.end(PerformanceStats.CLIENT_TICK, started)

func _process(delta: float) -> void:
	if phase == Phase.ONLINE:
		super(delta)

func _round_phase() -> int:
	return session.latest_authority["checkpoint"]["rules"][MatchRules.State.PHASE]

func _leave_result() -> void:
	_view.pvp_hud.set_status("等待其他玩家返回房间…")
	NetBus.send_event(NetEvent.Kind.LEAVE)

func _refresh_input_lock() -> void:
	controls.frozen = phase != Phase.ONLINE or _pause_open or _round_phase() != PhaseRule.PLAYING

func _set_pause(open: bool) -> void:
	super(open)
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
	if error != OK and phase == Phase.RECONNECTING and is_inside_tree():
		_go_offline("重连超时" if error == ERR_TIMEOUT else NetSession.room_error(error))

func _go_offline(message: String) -> void:
	phase = Phase.OFFLINE
	_refresh_input_lock()
	_view.pvp_hud.set_status(message)

func _exit_tree() -> void:
	if phase == Phase.RECONNECTING:
		NetSession.disconnect_client()
	NetBus.manual_poll = false
	super()
