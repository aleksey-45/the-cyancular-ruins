class_name ReconnectDriver
extends RefCounted

# 局内自动重连状态机组合件(2026-10-30 从 PvpMatchClient 拆出;S-17 第二刀):断线检测 → 重试预算 → 重连 → 回大厅。
# 形状是组合:宿主只剩 _subscribe_reconnect / _recheck_disconnect / _cancel_reconnect / _exit_tree 与横幅两件;
# 横幅文本走 set_status Callable,C2 重置与补态拉取走 pull_resync Callable。细节见 docs/eng/netplay-reconnect.md。

# 节拍 = 多久看一眼;一次尝试寿命 = 一次握手最多活多久。★ 不掐尝试会在高 RTT 链路上反复掐掉正在握手的连接(ENet 自身超时实测 ~31.8s,一次能吃掉半个宽限期预算)。
const RECONNECT_RETRY_MS := 2000
const RECONNECT_ATTEMPT_TIMEOUT_MS := 5000

var _client: Node = null
var _set_status: Callable = Callable()
var _pull_resync: Callable = Callable()

var _reconnecting := false
var _reconnect_started_ms := 0   # ★ 真实断开时刻(不是"关菜单"时刻,见 _begin_reconnect)
var _reclaim_sent := false   # ★ 本条连接上是否已发过 reclaim(判据见 _on_reconnect_retry_tick)
var _pending_disconnect := false   # 断线时菜单开着 → 记账,关菜单再来(见 recheck_disconnect)
var _attempt_started_ms := 0   # 当前这次连接尝试的起飞时刻;0 = 没有进行中的尝试
var _retry_timer: SceneTreeTimer = null   # 单一定时器(判据见 _schedule_reconnect_retry)


func bind(client: Node, set_status: Callable, pull_resync: Callable) -> void:
	_client = client
	_set_status = set_status
	_pull_resync = pull_resync


# 三个子类各自 _ready 里经宿主 _subscribe_reconnect() 调一次。★ 真断线必须从 multiplayer.server_disconnected
# 直连:local_server_message 还承载连接失败/文本播报,按文本猜会误判;reclaim 后的 match_start 由 local_match_start 接。
func subscribe() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	_client.multiplayer.server_disconnected.connect(_on_hard_disconnect)
	NetBus.local_match_start.connect(_on_match_start_event)


func _on_server_message(_msg: String) -> void:
	pass


func _on_hard_disconnect() -> void:
	if _client._match_ended or _reconnecting:
		return
	_pending_disconnect = true
	_begin_reconnect()


# 菜单关掉时补一次(宿主 _recheck_disconnect 委托):菜单开着时真掉线,那次 _begin_reconnect 被守卫挡下,账记在 _pending_disconnect 上,关菜单这一刻补上(不补 = 玩家留在快照停更的静止世界里)。
func recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


# 局内自动重连:不切场景、不重建世界,只把连接接回去。★ "不重建场景"不等于"世界没变"(见 _on_resumed)。
func _begin_reconnect() -> void:
	# ★ MATCH_OVER / 对手离开那两条延时回菜单的路子会先 NetBus.stop(),而它断开的是我们自己。
	if _client._match_ended:
		return
	# ★ 预算起算点 = 真实断开这一刻(在菜单守卫之前):菜单开着的闪断若等关菜单才起算,等于凭空多拿一段预算。
	if _reconnect_started_ms == 0:
		_reconnect_started_ms = Time.get_ticks_msec()
	# ★ 菜单开着先不动(先接回再走人会留下"人已走、role 仍被占"的幽灵),账记在 _pending_disconnect 上。
	if _client._menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")   # 原版 worker / 老大厅 → 优雅降级
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
	_reclaim_sent = false   # 新连接 = 新的一次 reclaim 额度(旧连接上那次的成败已无意义)
	_attempt_started_ms = 0   # 上一轮(若有)就此作废
	# ★ 上一轮那两条一次性结局回调仍挂在 MultiplayerAPI 上(不随 peer 换掉、也不随 NetBus.stop() 清),不摘干净的话
	# 握手成功那一次会把旧回调一起叫起来(_try_reclaim 被叫两次 / 新的尝试记账被清零)。
	if _client.multiplayer.connected_to_server.is_connected(_try_reclaim):
		_client.multiplayer.connected_to_server.disconnect(_try_reclaim)
	if _client.multiplayer.connection_failed.is_connected(_on_reconnect_failed):
		_client.multiplayer.connection_failed.disconnect(_on_reconnect_failed)
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		_schedule_reconnect_retry()
		return
	_attempt_started_ms = Time.get_ticks_msec()
	_client.multiplayer.connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	_client.multiplayer.connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)
	# ★★ 成功这条也要挂定时器:不挂的话"一次尝试尚未返回"的整段期间一次 tick 都没有 —— 宽限期判据从不被求值。
	_schedule_reconnect_retry()


func _on_reconnect_failed() -> void:
	_attempt_started_ms = 0   # 这次尝试已有结局(失败)→ 下一拍重开,不必再等尝试超时
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return   # 期间已收场(超时/已离开) → 不发
	# ★★ 本条连接上只发一次 reclaim:worker 接受第一次时就 _grace.leave(role) 了,再发一次必被它踢连接。
	if _reclaim_sent:
		return
	_attempt_started_ms = 0
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token, NetCodec.PROTO_VERSION)
	_schedule_reconnect_retry()


# 重试节拍(单一定时器)。★ 一个时刻只能有一个定时器在等;已有的没到点就直接返回,链条不会断:
func _schedule_reconnect_retry() -> void:
	if not _reconnecting:
		return
	if _retry_timer != null and _retry_timer.time_left > 0.0:
		return
	_retry_timer = _client.get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0)
	_retry_timer.timeout.connect(_on_reconnect_retry_tick)


func _on_reconnect_retry_tick() -> void:
	if not _reconnecting:
		return
	# 横幅上显示还剩多少预算(失败之前就要有可见反馈)。★ 读的是 GraceWindow.DEFAULT_SECONDS,与收场判据同一个常量。
	var left := int(GraceWindow.DEFAULT_SECONDS) \
			- int((Time.get_ticks_msec() - _reconnect_started_ms) / 1000)
	_set_status.call("与服务器断线,正在重连…(剩余 %ds)" % maxi(left, 0))
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	# ★★ 同一 role 只许发一次 reclaim,再发必被 worker 踢;已发且连接活着 ⇒ 该等它的 match_start(真发不出去时 can_send_to_server() 为 false)。
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	var attempt_age := Time.get_ticks_msec() - _attempt_started_ms
	if _attempt_started_ms > 0 and attempt_age < RECONNECT_ATTEMPT_TIMEOUT_MS:
		_schedule_reconnect_retry()
		return
	_retry_connect()


func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	# ★ 非重连态收到它 = 首次进场那一份或异常来源,两种都不动本地世界:本路径不重建场景,role / spawn / map_path 一个都不回写。
	if not _reconnecting:
		return
	_on_resumed()


# 重连成功:本类只负责状态与横幅;C2 重置与补态拉取在宿主 _pull_resync() 里(经 bind 的 Callable)。
func _on_resumed() -> void:
	_reconnecting = false
	NetDiag.log_event("reconnect_resumed", {"role": PvpSession.role,
			"down_ms": Time.get_ticks_msec() - _reconnect_started_ms}, true)
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status.call("")   # 重连成功 → 收起横幅(阶段 3)
	_pull_resync.call()
	print("[pvp] 重连成功")


# 宿主 _cancel_reconnect() 委托:「对手已离开」是终局,停掉正在跑的重连循环。★ worker 收场"先发 opponent_left、紧接着 quit(0)",到达顺序不保证 ⇒ 由此口收口。
func cancel() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status.call("")   # 「对手已离开」是终局:横幅一并收起,让位给 HUD 的中央播报


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	# ★ 先收起横幅再换场:换场是 await 一帧的,留着文字只会在主菜单上闪一帧;原因本身仍留在下面那行 print 里。
	_set_status.call("")
	NetBus.stop()
	Level0.safe_change_scene(_client.get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


# 场景离开 → 停掉正在跑的重连(宿主 _exit_tree 委托)。★ 只在真在重连时断连(本函数跑在新场景 _ready 之后)。
func on_exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()
