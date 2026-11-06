class_name ReconnectDriver
extends RefCounted


# 节拍 = 多久看一眼;一次尝试寿命 = 一次握手最多活多久。★ 不掐尝试会在高 RTT 链路上反复掐掉正在握手的连接(ENet 自身超时实测 ~31.8s,一次能吃掉半个宽限期预算)。
const RECONNECT_RETRY_MS := 2000
const RECONNECT_ATTEMPT_TIMEOUT_MS := 5000

var _state: ClientState = null
var _ports: ClientPorts = null
var _set_status: Callable = Callable()
var _pull_resync: Callable = Callable()

var _reconnecting := false
var _reconnect_started_ms := 0
var _reclaim_sent := false
var _pending_disconnect := false
var _attempt_started_ms := 0
var _retry_timer: SceneTreeTimer = null


func bind(state: ClientState, ports: ClientPorts) -> void:
	_state = state
	_ports = ports
	_set_status = ports.set_status
	_pull_resync = ports.pull_resync


func subscribe() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	_ports.multiplayer.call().server_disconnected.connect(_on_hard_disconnect)
	NetBus.local_match_start.connect(_on_match_start_event)


func _on_server_message(_msg: String) -> void:
	pass


func _on_hard_disconnect() -> void:
	if _state._match_ended or _reconnecting:
		return
	_pending_disconnect = true
	_begin_reconnect()


func recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


func _begin_reconnect() -> void:
	if _state._match_ended:
		return
	if _reconnect_started_ms == 0:
		_reconnect_started_ms = Time.get_ticks_msec()
	if _state._menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")
		return
	_reconnecting = true
	_set_status.call("与服务器断线,正在重连…")
	NetDiag.log_event("reconnect_begin", {"role": PvpSession.role, "port": PvpSession.worker_port,
			"has_token": PvpSession.token != ""}, true)
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


func _retry_connect() -> void:
	if not _reconnecting:
		return
	NetBus.stop()
	_reclaim_sent = false
	_attempt_started_ms = 0
	if _ports.multiplayer.call().connected_to_server.is_connected(_try_reclaim):
		_ports.multiplayer.call().connected_to_server.disconnect(_try_reclaim)
	if _ports.multiplayer.call().connection_failed.is_connected(_on_reconnect_failed):
		_ports.multiplayer.call().connection_failed.disconnect(_on_reconnect_failed)
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		_schedule_reconnect_retry()
		return
	_attempt_started_ms = Time.get_ticks_msec()
	_ports.multiplayer.call().connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	_ports.multiplayer.call().connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)
	_schedule_reconnect_retry()


func _on_reconnect_failed() -> void:
	_attempt_started_ms = 0
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return
	if _reclaim_sent:
		return
	_attempt_started_ms = 0
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token, NetCodec.PROTO_VERSION)
	_schedule_reconnect_retry()


func _schedule_reconnect_retry() -> void:
	if not _reconnecting:
		return
	if _retry_timer != null and _retry_timer.time_left > 0.0:
		return
	_retry_timer = _ports.get_tree.call().create_timer(RECONNECT_RETRY_MS / 1000.0)
	_retry_timer.timeout.connect(_on_reconnect_retry_tick)


func _on_reconnect_retry_tick() -> void:
	if not _reconnecting:
		return
	var left := int(GraceWindow.DEFAULT_SECONDS) \
			- int((Time.get_ticks_msec() - _reconnect_started_ms) / 1000)
	_set_status.call("与服务器断线,正在重连…(剩余 %ds)" % maxi(left, 0))
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	var attempt_age := Time.get_ticks_msec() - _attempt_started_ms
	if _attempt_started_ms > 0 and attempt_age < RECONNECT_ATTEMPT_TIMEOUT_MS:
		_schedule_reconnect_retry()
		return
	_retry_connect()


func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	if not _reconnecting:
		return
	_on_resumed()


func _on_resumed() -> void:
	_reconnecting = false
	NetDiag.log_event("reconnect_resumed", {"role": PvpSession.role,
			"down_ms": Time.get_ticks_msec() - _reconnect_started_ms}, true)
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status.call("")
	_pull_resync.call()
	print("[pvp] 重连成功")


func cancel() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status.call("")


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	_set_status.call("")
	NetBus.stop()
	Level0.safe_change_scene(_ports.get_tree.call(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


func on_exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()
