class_name LobbyPage
extends Control


const LocalServer := preload("res://core/net/local_server.gd")


var _addr_edit: LineEdit
var _status: Label
var _ip_label: Label = null
var _connected := false
var _connected_addr := ""
var _pending_action: Callable = Callable()
# 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _lobby_start_ms := 0
var _connecting_worker := false
var _go_start_ms := 0
var _claimed_ms := 0
var _claim_connected: Callable = Callable()
var _worker_fail: Callable = Callable()
var _pending_go_role := -1
var _pending_go_port := -1


func _bind_worker_once(role: int) -> void:
	_unbind_worker_once()
	_claim_connected = _claim_role_worker.bind(role)
	multiplayer.connected_to_server.connect(_claim_connected, CONNECT_ONE_SHOT)
	_worker_fail = Callable(self, "_on_worker_connect_failed")
	multiplayer.connection_failed.connect(_worker_fail, CONNECT_ONE_SHOT)


func _unbind_worker_once() -> void:
	if _claim_connected.is_valid() and multiplayer.connected_to_server.is_connected(_claim_connected):
		multiplayer.connected_to_server.disconnect(_claim_connected)
	_claim_connected = Callable()
	if _worker_fail.is_valid() and multiplayer.connection_failed.is_connected(_worker_fail):
		multiplayer.connection_failed.disconnect(_worker_fail)
	_worker_fail = Callable()




func _finish_lobby_ready() -> void:
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBusExt.local_session_token.connect(_on_session_token)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	# ★ headless(CI / 冒烟 / ui_shots 的 --headless 分支)不发起真实 UDP 连接:大厅状态机与版式
	#   不需要真服务器,若照常 _request_list 会向配置里的公网地址 create_client(不占端口,但仍是真连接)。
	#   非 headless(真玩家)行为不变。
	if DisplayServer.get_name() == "headless":
		_status.text = "headless:跳过自动连接(不发真实连接请求)"
		return
	_request_list.call_deferred("正在连接服务器获取房间列表…")



# 禁用武器网格(2 列 + 定尺寸剪影,横排会溢出屏幕)。
# ★★ 间距键名分两层,别混:GridContainer 认 h_separation / v_separation,而 HBoxContainer / VBoxContainer 只认 separation —— 把 h_separation 写在 HBox 上会被存下来但永不读取(静默无效覆盖,合一前的旧大厅页里就有写错过的一份)。
# 可视区高度 = 内容驱动下限(约 3 行 32px 剪影),用 token 表达而不是魔法数 144。
func _add_weapon_grid(parent: Node, h_sep: int, on_cell: Callable = Callable()) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", h_sep)
	wgrid.add_theme_constant_override("v_separation", UiFactory.SP_2)
	wgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, UiFactory.SP_9 * 2 + UiFactory.SP_4)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.add_child(wgrid)
	parent.add_child(scroll)
	for type_id: int in WeaponRegistry.all_ids():
		var type_i := type_id
		var cell := WeaponIcons.make_weapon_check(type_i, Settings.pvp_disabled_weapons.has(type_i),
				32, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(type_i):
					Settings.pvp_disabled_weapons.append(type_i)
				elif not on:
					Settings.pvp_disabled_weapons.erase(type_i)
				Settings.save())
		if on_cell.is_valid():
			on_cell.call(cell, type_i)
		wgrid.add_child(cell)




func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)


func _on_lobby_connected() -> void:
	if _connecting_worker:
		return
	_lobby_start_ms = 0
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	var act := _pending_action
	if act.is_valid():
		_pending_action = Callable()
		act.call()
	else:
		_request_list("已连接,正在获取房间列表…")


func _on_lobby_connect_failed() -> void:
	if _connecting_worker:
		return
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	var addr := _addr_edit.text.strip_edges()
	if addr.is_empty():
		_status.text = "连接服务器失败——请填服务端地址(本机起服填 127.0.0.1;局域网填对方局域网 IP)"
	else:
		_status.text = "连接服务器失败(%s)——局域网请填服务端电脑的局域网 IP,并放行 UDP 7777" % addr


func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = _lobby_fallback_addr()
		_addr_edit.text = addr
	PvpSession.server_address = addr
	# ★★ NetBus.can_send_to_server() 不是可选项:_connected 是本端自己的记账(只在连上 / 连接失败 / 主动重连时翻),不随对端断开更新 —— 服务器掉线或踢人之后它仍是 true,于是「已连上」这条快路会把请求发往一个 ENet 已拆掉的 peer,也就是那条 Unable。
	# 加了这一判,断线后的第一次点击就落到下面的重连路径:动作存进 _pending_action,连上大厅之后自动补发 ⇒ 既不报错,也顺手修好「服务器断了、界面看着还连着」这个状态。
	if _connected and _connected_addr == addr and NetBus.can_send_to_server():
		action.call()
		return
	_status.text = "正在连接服务器…"
	_connected = false
	_pending_action = action
	_on_lobby_reconnect()
	NetBus.stop()
	var err := NetBus.start_client(addr)
	if err != OK:
		_status.text = "启动连接失败(%d)" % err
		_pending_action = Callable()
	else:
		_lobby_start_ms = Time.get_ticks_msec()


func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		_send_list_request())


func _on_refresh_pressed() -> void:
	_request_list("刷新房间列表…")


func _on_local_server_pressed() -> void:
	_status.text = "正在启动/重启本机服务器…(%s)" % LocalServer.lan_ip_hint()
	var msg: String = await LocalServer.restart()
	_ip_label.text = LocalServer.lan_ip_hint()
	_status.text = msg
	if not msg.begins_with("本机服务器"):
		return
	NetBus.stop()
	_connected = false
	_connected_addr = ""
	_addr_edit.text = "127.0.0.1"
	_on_local_server_ready()
	_request_list("本机服务器已就绪(%s),正在获取房间列表…" % LocalServer.lan_ip_hint())


func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t



var _pending_token := ""

func _on_session_token(token: String) -> void:
	_pending_token = token


# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若立刻 NetBus.stop(),正在 poll 的 peer 引用被清零、在自己的调用栈内被 free ⇒ 偶发原生段错误(实测「对手连入配对完成的一瞬间」闪退)。
# ★ 帧末还不够:再等一帧才真正 stop()。go_match / session_token 是大厅对这台客户端的最后两条定向包,同帧就把连接拆掉会让服务端那一拍的发送落到已拆的 ENet peer 上(引擎报 `Unable to send packet on channel 0, max channels: 0`);多等一帧是让它们落地,代价只有 16ms 进对局。
func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	_pending_go_port = port
	_on_go_match_extra()
	_status.text = _go_match_status()
	_do_go_match.call_deferred()


var _rejoin_sent_ms := 0


func try_rejoin_row(code: String, in_match: bool, mode: String) -> bool:
	if not PvpSession.can_rejoin_to(code, mode):
		return false
	if not in_match:
		return false
	PvpSession.rejoin = true
	_request_rejoin(mode)
	return true


func _request_rejoin(mode: String) -> void:
	if not PvpSession.can_rejoin():
		PvpSession.rejoin = false
		_status.text = "回局凭据已失效,请重新建房/加入"
		return
	# ★★ 发送前先判活(与 _with_lobby 快路里那条同一条纪律、同一个症状):回局入口刻意不走 _with_lobby(它会把刚拿到的列表连同自己那一行一起丢掉),所以这一判必须自带 —— 断线后那一行还画在屏上(列表是断线前拉的),点它等于把 rejoin_request 打在 ENet 已拆掉的 peer 上。
	# 走 _request_list 顺带把重连拉起来(它内部会判活并落到重连路径),而不是把玩家留在一句「正在回到对局…」上;rejoin 也要清掉 —— 否则下一次 go_match 会错走 reclaim_role 分支(_claim_role_worker 只看这个开关)。
	if not NetBus.can_send_to_server():
		PvpSession.rejoin = false
		_request_list("与大厅的连接已断开——正在重连并刷新房间列表…")
		return
	_rejoin_sent_ms = Time.get_ticks_msec()
	_status.text = "正在回到对局…"
	NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token, mode)


# 大厅答「回不去了」(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。★ 必须清:否则那一行永远是可点的,而每次点都是同一句失败。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	_request_list("已刷新房间列表")


func _tick_rejoin_timeout() -> bool:
	if PvpSession.rejoin and _rejoin_sent_ms > 0 \
			and Time.get_ticks_msec() - _rejoin_sent_ms > 15000:
		_rejoin_sent_ms = 0
		PvpSession.clear_rejoin()
		_status.text = "回局请求无响应——已放弃,请重新建房/加入"
		return true
	return false


func _do_go_match() -> void:
	if _pending_go_role < 0:
		return
	await get_tree().process_frame
	if _pending_go_role < 0:
		return
	var role := _pending_go_role
	var port := _pending_go_port
	_pending_go_role = -1
	_pending_go_port = -1
	PvpSession.role = role
	if _pending_token != "":
		PvpSession.token = _pending_token
	PvpSession.worker_port = port
	_pending_token = ""
	_bind_worker_once(role)
	NetBus.stop()
	_connecting_worker = true
	_go_start_ms = Time.get_ticks_msec()
	var err := NetBus.start_client(PvpSession.server_address, port)
	if err != OK:
		_connecting_worker = false
		_status.text = "连接对局服务器失败(%d)" % err


func _claim_role_worker(role: int) -> void:
	_connecting_worker = false
	_claimed_ms = Time.get_ticks_msec()
	if PvpSession.rejoin:
		PvpSession.rejoin = false
		NetBusExt.rpc_id(1, "reclaim_role", role, PvpSession.token, NetCodec.PROTO_VERSION)
		return
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name, NetCodec.PROTO_VERSION)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)


func _return_to_lobby(msg: String) -> void:
	_unbind_worker_once()
	_connecting_worker = false
	_claimed_ms = 0
	PvpSession.rejoin = false
	_rejoin_sent_ms = 0
	_on_return_to_lobby()
	NetBus.stop()
	_connected = false
	# 重连也要起表:否则 _process 那条「8s 没连上大厅就给明确提示」的兜底对新连接不成立,UDP 静默丢包时状态栏会停在「已返回大厅并刷新」而实际没刷新。
	_lobby_start_ms = Time.get_ticks_msec()
	_status.text = msg
	NetBus.start_client(PvpSession.server_address)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	_enter_match_scene()



func _tick_worker_connect_timeout() -> bool:
	if _connecting_worker and Time.get_ticks_msec() - _go_start_ms > 12000:
		_return_to_lobby(_worker_timeout_msg())
		return true
	return false


# 大厅连接超时兜底:同因(UDP 静默丢包),8 秒仍没连上就给明确提示。原实现不 return(后面还有别的梯要跑),故本函数无返回值。
func _tick_lobby_connect_timeout() -> void:
	if not _connecting_worker and _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "连接大厅超时——请检查地址/网络(UDP 7777)"


func _tick_claim_timeout() -> bool:
	if _claimed_ms > 0 and Time.get_ticks_msec() - _claimed_ms > 25000:
		_return_to_lobby(_claim_timeout_msg())
		return true
	return false


# ── 子类钩子 ── 必需项:基类给会报错的兜底 —— 漏覆写 = 当场可见,不是静默错值。

func _lobby_fallback_addr() -> String:
	push_error("LobbyPage: 子类必须覆写 _lobby_fallback_addr()")
	return ""


func _send_list_request() -> void:
	push_error("LobbyPage: 子类必须覆写 _send_list_request()")


func _player_options() -> Dictionary:
	push_error("LobbyPage: 子类必须覆写 _player_options()")
	return {}


var time_rules := TimeRules.new()


func _add_time_params(vb: VBoxContainer) -> void:
	if not PvpSession.beta_mode:
		return
	var tp_label := UiFactory.ui_label("时间颗粒规则(房主可调,开局生效):", "h2")
	tp_label.add_theme_color_override("font_color", UiFactory.C_ACCENT)
	vb.add_child(tp_label)
	_trow(vb, "初始颗粒", 1000.0, "initial", TimeRules.R_INITIAL, 50.0, false)
	_trow(vb, "颗粒上限", 1800.0, "cap", TimeRules.R_CAP, 100.0, false)
	_trow(vb, "回溯燃烧/秒", 150.0, "rewind_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "加速燃烧/秒", 70.0, "haste_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "短时额度", 250.0, "window", TimeRules.R_WINDOW, 10.0, false)
	_trow(vb, "回复/秒", 50.0, "regen", TimeRules.R_REGEN, 5.0, false)
	_trow(vb, "击杀获取 %", 50.0, "kill_ratio", Vector2(0.0, 100.0), 5.0, true)
	_trow(vb, "拆砖获取/子格", 10.0, "block_gain", TimeRules.R_BLOCK, 1.0, false)
	_trow(vb, "伤害获取/点", 4.0, "damage_gain", TimeRules.R_DAMAGE, 1.0, false)


func _trow(vb: VBoxContainer, text: String, initial: float, field: String,
		rng: Vector2, step: float, as_percent: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiFactory.SP_3)
	var l := UiFactory.ui_label(text, "body")
	l.custom_minimum_size = Vector2(UiFactory.SP_10 * 4 - UiFactory.SP_4, 0)   # 参数名列宽(内容驱动)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = rng.x
	sl.max_value = rng.y
	sl.step = step
	sl.value = initial
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiFactory.style_slider(sl)
	row.add_child(sl)
	var val := UiFactory.ui_label(_fmt_param(initial, as_percent), "h2")
	val.add_theme_color_override("font_color", UiFactory.C_ACCENT)
	val.custom_minimum_size = Vector2(UiFactory.SP_9 + UiFactory.SP_8 + UiFactory.SP_1, 0)
	row.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		time_rules.set(field, v / 100.0 if as_percent else v)
		val.text = _fmt_param(v, as_percent))
	vb.add_child(row)


static func _fmt_param(v: float, as_percent: bool) -> String:
	return ("%d%%" % int(round(v))) if as_percent else str(int(round(v)))


func _beta_payload() -> Dictionary:
	if not PvpSession.beta_mode:
		return {}
	time_rules.clamp_self()
	return {"beta": true, "time": time_rules.to_dict()}


func _add_map_picker(vb: VBoxContainer) -> void:
	var picker := MapPicker.new()
	vb.add_child(picker)
	# 可视高 ≈ 3 行卡片(内容驱动);用 token 组合,不写 470 这类魔法数。
	picker.setup(Settings.mp_map_path, 2, float(UiFactory.SP_9 * 7 + UiFactory.SP_4),
			"地　图(房主选;缩略图 = 开局地形简略图)")
	Settings.mp_map_path = picker.selected
	picker.picked.connect(func(p: String) -> void:
		Settings.mp_map_path = p
		Settings.save())


func _go_match_status() -> String:
	push_error("LobbyPage: 子类必须覆写 _go_match_status()")
	return ""


func _on_worker_connect_failed() -> void:
	push_error("LobbyPage: 子类必须覆写 _on_worker_connect_failed()")


func _worker_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _worker_timeout_msg()")
	return ""


func _claim_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _claim_timeout_msg()")
	return ""


func _enter_match_scene() -> void:
	push_error("LobbyPage: 子类必须覆写 _enter_match_scene()")



func _lobby_action_allowed() -> bool:
	return true


func _on_lobby_reconnect() -> void:
	pass


func _on_go_match_extra() -> void:
	pass


func _on_return_to_lobby() -> void:
	pass


func _on_local_server_ready() -> void:
	pass
