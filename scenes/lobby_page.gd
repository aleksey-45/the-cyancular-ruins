class_name LobbyPage
extends Control

# 大厅页的共享基类(统一大厅 mp_lobby extends 它)。
# ★ 为什么:大厅页本是一份「连大厅 → 列房间 → 配对了转连 worker」的状态机,历史上按模式复制成了三份实现 —— 同一处修正要改三遍,漏一处不报错(表现是「1v1 里好了、另两个没变」);三页合一后,凡是各模式语义相同的都上提到这里,子类只留真正的差异。
# ★ 上提判据是「剔掉注释后的代码是否逐字相同」(不是「看起来像」);那些只差 1~3 行的差异全部落成下方「子类钩子」。刻意不在这里的:_ready 与整页 chrome / 三个弹层(它们是 mp_lobby.tscn 的静态骨架)、各模式的 _on_room_list 变体(N 人房行样式与文案都不同)、_process 的派发(梯顺序与页面专属梯有关,合并会改行为)。要再上提一批,先按同样口径量一遍差异。
# ★ 本类读 Settings autoload(禁用武器网格那个设置区块要用),故不放进 ui/ui_factory.gd —— 那个工厂至今零 autoload 依赖(Settings 读写全留在调用方),是它的一条不变量。

# 本机服务器一键启停(同目录 Cyancular Ruins Server.exe)。用 preload 而非全局类名,避免新脚本未进全局类缓存时整份场景解析失败;常量可继承,子类直接读本常量、无需各自再声明。
const LocalServer := preload("res://core/net/local_server.gd")


# ── 共用状态(子类不要再声明一次)──
var _addr_edit: LineEdit
var _status: Label
var _ip_label: Label = null   # 常驻本机 IP 提示(进页/重启后即显示,不靠易被刷掉的状态栏)
var _connected := false
var _connected_addr := ""          # 当前连的是哪个地址(地址框改了要重连)
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
# 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _lobby_start_ms := 0
var _connecting_worker := false   # 是否在转连对局 worker(用于超时兜底提示)
var _go_start_ms := 0
var _claimed_ms := 0       # 已向 worker claim,等 match_start 的起始时间(0=未 claim)
# 大厅配对结果:go_match 在大厅 peer 的 poll() 调用栈内到达,不能就地切连接 → 存下来帧末执行
var _pending_go_role := -1
var _pending_go_port := -1


# ── 页面基建(子类在 _ready 里调)── ★ 页面底色(不透明深色)现在是骨架里的那个 ColorRect:全局清屏色被 Level0 设成浅蓝之后白字界面会看不清,所以每一页都得自带一块不透明底。


# 收尾(建完本页全部控件、接完本页自己的信号之后调):接共用信号 + 递归补像素字体 + 进页自动拉一次房间列表;子类那几条信号先接后接都行(互不相干)。
func _finish_lobby_ready() -> void:
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBusExt.local_session_token.connect(_on_session_token)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	_request_list.call_deferred("正在连接服务器获取房间列表…")


# ── 设置区块(子类建房用)── 读写 Settings,故留在本类而不是 ui/ui_factory.gd(那个工厂零 autoload 依赖)。

# 禁用武器网格(2 列 + 定尺寸剪影,横排会溢出屏幕)。勾选直写 Settings.pvp_disabled_weapons + save()(房主开关,禁用项随 player_options 上发);h_sep 是调用方的版式值(剪影是长条形,列距本就不同),on_cell 给需要额外记账的调用方。
# ★★ 间距键名分两层,别混:GridContainer 认 h_separation / v_separation,而 HBoxContainer / VBoxContainer 只认 separation —— 把 h_separation 写在 HBox 上会被存下来但永不读取(静默无效覆盖,合一前的旧大厅页里就有写错过的一份)。
func _add_weapon_grid(parent: Node, h_sep: int, on_cell: Callable = Callable()) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", h_sep)
	wgrid.add_theme_constant_override("v_separation", 6)
	parent.add_child(wgrid)
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
		return   # 转连对局 worker 的连接走 _on_go_match,不在这里接管
	_lobby_start_ms = 0
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	var act := _pending_action
	if act.is_valid():
		_pending_action = Callable()
		act.call()
	else:
		_request_list("已连接,正在获取房间列表…")   # 连上即自动刷新,无需手点


func _on_lobby_connect_failed() -> void:
	if _connecting_worker:
		return
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	_status.text = "连接服务器失败,请检查地址"


func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = _lobby_fallback_addr()
		_addr_edit.text = addr
	PvpSession.server_address = addr
	# ★★ NetBus.can_send_to_server() 不是可选项:_connected 是本端自己的记账(只在连上 / 连接失败 / 主动重连时翻),不随对端断开更新 —— 服务器掉线或踢人之后它仍是 true,于是「已连上」这条快路会把请求发往一个 ENet 已拆掉的 peer,也就是那条 Unable to send packet on channel 0(而它是周期性的:刷新列表 / 加入 / 建房都走这里)。
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


# 请求房间列表:状态文案由调用方给(各调用点文案不同),RPC 由子类发(协议不同)。
func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		_send_list_request())


func _on_refresh_pressed() -> void:
	_request_list("刷新房间列表…")


# 一键启动/重启本机服务器:杀旧实例 → 拉起同目录服务端 exe → 强制重连 127.0.0.1 刷新列表(协程,按钮回调内 await)。
func _on_local_server_pressed() -> void:
	_status.text = "正在启动/重启本机服务器…(%s)" % LocalServer.lan_ip_hint()
	var msg: String = await LocalServer.restart()
	_ip_label.text = LocalServer.lan_ip_hint()
	_status.text = msg
	if not msg.begins_with("本机服务器"):
		return   # 找不到 exe 等失败:保留提示,不动现有连接
	NetBus.stop()
	_connected = false
	_connected_addr = ""
	_addr_edit.text = "127.0.0.1"
	_on_local_server_ready()
	_request_list("本机服务器已就绪(%s),正在获取房间列表…" % LocalServer.lan_ip_hint())


# 服务器文本播报。重启本机服期间旧连接被杀的「服务器断开」是预期噪音,不覆盖状态 —— 基类给的是「照抄到状态栏」的默认实现;子类另有「房间已满 / 不存在 ⇒ 自动刷新列表」等段,整段覆写本函数。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t



# 大厅在 go_match 之前下发的一次性会话令牌(断线重连用)。★ 先存进 _pending_token 而不是直接写 PvpSession:go_match 也是本帧到达的,两者由 _do_go_match.call_deferred 在帧末一起落到 PvpSession,顺序就不会被 RPC 到达次序左右(时序硬约束:token 必须先于 go_match 发出 —— 客户端收到 go_match 当场 NetBus.stop() 断大厅,晚发的载荷静默丢失)。
var _pending_token := ""

func _on_session_token(token: String) -> void:
	_pending_token = token


# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若立刻 NetBus.stop(),正在 poll 的 peer 引用被清零、在自己的调用栈内被 free ⇒ 偶发原生段错误(实测「对手连入配对完成的一瞬间」闪退)。故把整个切换推迟到帧末执行。
# ★ 帧末还不够:**再等一帧**才真正 stop()。go_match / session_token 是大厅对这台客户端的最后两条定向包,同帧就把连接拆掉会让服务端那一拍的发送落到已拆的 ENet peer 上(引擎报 `Unable to send packet on channel 0, max channels: 0`);多等一帧是让它们落地,代价只有 16ms 进对局。
func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	_pending_go_port = port
	_on_go_match_extra()
	_status.text = _go_match_status()
	_do_go_match.call_deferred()


# ── 回大厅后回局 ── 入口 = 本页房间列表里「自己那间房」那一行被按下(见 try_rejoin_row;三个大厅页共用这一份)。本页做三件事:① 发 rejoin_request(房间号, token) —— ★ 此刻本页一定连着大厅(那一行就是 room_list 载荷里来的),故这里不连大厅、不碰地址框、也不走 _with_lobby:照原稿搬会 NetBus.stop() + 重连一次,把刚拿到的列表连同自己那一行一起丢掉;② 大厅复用 go_match 把它送回原 worker,之后与首次进场逐字同一条路;③ 唯一的岔路在 _claim_role_worker(对局已经开着 ⇒ 必须发 reclaim_role)。
# ★ 原稿那条「地址取 PvpSession.server_address 而不是地址框」的绕法随入口一起作废:它防的是「从主菜单按按钮进来时页还没连上」那一档,而现在玩家就站在已经连上的那一页上。
var _rejoin_sent_ms := 0


# 房间列表里某一行被按下时,先问这一句(子类的 _on_room_list 调它)。返回 true = 这一行是我的房、凭据还在、而且是对局中 ⇒ 已走回局;false = 交给调用方走普通加入。
# ★★ 它同时是行可点性的判据(页面渲染那一行时也要问同一句)—— 两处共用一个函数,免得「看着可点、点了没用」或反过来。
# ★★ 两个条件缺一不可,且次序不变(先问「是不是我的房 + 凭据还在」,再轮到「对局中」):写反成先看 in_match ⇒ 自己那间房连点都点不到;而只看前一条的话,手里有凭据时自己那间还没开局的等待中的房也会走回局分支 —— 那种房在大厅侧没有凭据表条目,必收 rejoin_denied,而普通加入那一半根本不会发生(本函数已 return true),玩家看到的是「点了自己的房,冒出一句与眼前这间房无关的拒绝」。等待中的房本来就该走普通加入。
func try_rejoin_row(code: String, in_match: bool, mode: String) -> bool:
	if not PvpSession.can_rejoin_to(code, mode):
		return false
	if not in_match:
		return false
	PvpSession.rejoin = true
	_request_rejoin()
	return true


func _request_rejoin() -> void:
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
	NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token)


# 大厅答「回不去了」(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。★ 必须清:否则那一行永远是可点的,而每次点都是同一句失败。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	# ★ 凭据一清,那一行在下一次渲染时必须回到「对局中(灰色、点不动)」。本页没有就地改一行的路径,重拉列表是唯一的重渲染入口。
	_request_list("已刷新房间列表")


# 回局请求发出后大厅一直没应答的兜底(15s):没有它玩家会停在一句「正在回到对局…」上,而本页其它兜底梯(worker 转连 / claim)此时都还没启动。★ 判据里带 PvpSession.rejoin:回局成功时它已被清掉,这条梯自然失效。
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
	await get_tree().process_frame   # 见 _on_go_match 上方:让大厅最后两条定向包先落地,再断连接
	if _pending_go_role < 0:
		return
	var role := _pending_go_role
	var port := _pending_go_port
	_pending_go_role = -1
	_pending_go_port = -1
	PvpSession.role = role
	# ★ 只在真收到新 token 时才覆盖:回局那条路大厅不重发 session_token(客户端那一份就是凭据本身),无条件写会把手里唯一能证明「我是原来那个人」的串抹成空 ⇒ reclaim_role 必被 worker 拒(令牌不匹配)并踢连接,而现场一个字都没有。
	if _pending_token != "":
		PvpSession.token = _pending_token
	PvpSession.worker_port = port      # 局内自动重连要直连同一个端口
	_pending_token = ""
	multiplayer.connected_to_server.connect(_claim_role_worker.bind(role), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void: _on_worker_connect_failed(), CONNECT_ONE_SHOT)
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
	# ★★ 回局与首次进场的唯一分叉:对局已经开着,claim_role 这条走不得,必须改发 reclaim_role(宽限期内重新认领自己那个 role)。
	# ★ 它的失败形态是「静默」、不是「被踢」:server_main._begin_match 在开局那一刻就 NetBus.role_claimed.disconnect(_on_role_claimed) —— 迟到的 claim_role 根本没有收件人,既不踢人也不打印(_match_started 那第一款判据因此不可达)。⇒ 可观察的后果是「这个客户端再也回不来」:它卡在大厅页,靠本页 claim 兜底梯(_return_to_lobby)收场。
	# ★ 回局时不发 player_options / report_token:worker 侧两条 handler 都按 _claims[r] == caller 反查,而此刻新 peer 还没进 _claims(要等 reclaim 被接受)⇒ 两条都静默 no-op;而 token 首次 claim 时就报过一次,worker 手里那份正是要比对的那份。
	if PvpSession.rejoin:
		PvpSession.rejoin = false
		NetBusExt.rpc_id(1, "reclaim_role", role, PvpSession.token)
		return
	# claim_role 保持原版 2 参(大厅/worker 兼容);本端选项走扩展节点 NetBusExt
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	# token 走扩展节点(原 NetBus 的 claim_role 签名一律不动);原版 worker 无本节点 ⇒ 静默丢弃 ⇒ 那局就是「不能重连」,不影响对局本身。
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)


# 转连 worker 失败/无应答的兜底:断开当前连接回大厅,连上后 _on_lobby_connected 自动刷新列表。没有它,worker 死掉时玩家会永久停在「正在连接对局服务器」上,只能自己找出路。
func _return_to_lobby(msg: String) -> void:
	_connecting_worker = false
	_claimed_ms = 0
	# ★ 回局失败的各种兜底都汇到这里:不清 rejoin 就会让页停在「回局态」反复重试(每次都失败);token 不清 —— 它可能还有效(比如只是 worker 端口没放行),玩家可以在列表里再点一次那一行。
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


# ── 超时梯(共用的三条)── ★ 本基类不提供 _process:梯顺序由子类定(合一前的两个旧页就不同),且各有一条页面专属梯。顺序看着无所谓,实际有差:某一 tick 里「大厅-8s 先清 _pending_action、claim-25s 再 _return_to_lobby」若被并成只跑后者,_pending_action 就不再被清 —— 单看代码看不出来。故派发留在子类,这里只给函数体。

# 转连 worker 12s 无连接(死端口/worker 死了)。返回 true = 已处理,调用方应 return。
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

# 地址框为空时的回落地(1v1 回退云大厅;大乱斗需自建服,回退 127.0.0.1)
func _lobby_fallback_addr() -> String:
	push_error("LobbyPage: 子类必须覆写 _lobby_fallback_addr()")
	return ""


# 发一次"列房间"RPC(1v1 走 NetBus 的 list_rooms;大乱斗走 NetBusExt 的 royale_list)
func _send_list_request() -> void:
	push_error("LobbyPage: 子类必须覆写 _send_list_request()")


# 报到时随 player_options 上发的本端选项(两边字段不同:大乱斗多 match_time、回合回血恒 false)
func _player_options() -> Dictionary:
	push_error("LobbyPage: 子类必须覆写 _player_options()")
	return {}


# ── 时间玩法(Beta)建房参数(两个 Beta 大厅页共用;普通态不显示也不上报)── 值住在 time_rules(TimeRules 实例),建房/上报前 clamp;服务器侧还会再 clamp 一次(上报不可信)。
var time_rules := TimeRules.new()


func _add_time_params(vb: VBoxContainer) -> void:
	if not PvpSession.beta_mode:
		return
	vb.add_child(UiFactory.label("时间颗粒规则(房主可调,开局生效):", 32, UiFactory.C_ACCENT))
	_trow(vb, "初始颗粒", 1000.0, "initial", TimeRules.R_INITIAL, 50.0, false)
	_trow(vb, "颗粒上限", 1800.0, "cap", TimeRules.R_CAP, 100.0, false)
	_trow(vb, "回溯燃烧/秒", 150.0, "rewind_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "加速燃烧/秒", 70.0, "haste_burn", TimeRules.R_BURN, 5.0, false)
	_trow(vb, "短时额度", 250.0, "window", TimeRules.R_WINDOW, 10.0, false)
	_trow(vb, "回复/秒", 50.0, "regen", TimeRules.R_REGEN, 5.0, false)
	_trow(vb, "击杀获取 %", 50.0, "kill_ratio", Vector2(0.0, 100.0), 5.0, true)
	_trow(vb, "拆砖获取/子格", 10.0, "block_gain", TimeRules.R_BLOCK, 1.0, false)
	_trow(vb, "伤害获取/点", 4.0, "damage_gain", TimeRules.R_DAMAGE, 1.0, false)


# 一行参数 = 标签 + 滑条 + 当前值标签(数字必须可见:盲拖参数没法用)。
func _trow(vb: VBoxContainer, text: String, initial: float, field: String,
		rng: Vector2, step: float, as_percent: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UiFactory.label(text, 32)
	l.custom_minimum_size = Vector2(300, 0)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = rng.x
	sl.max_value = rng.y
	sl.step = step
	sl.value = initial
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(220, 28)
	UiFactory.style_slider(sl)
	row.add_child(sl)
	var val := UiFactory.label(_fmt_param(initial, as_percent), 32, UiFactory.C_ACCENT)
	val.custom_minimum_size = Vector2(110, 0)
	row.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		time_rules.set(field, v / 100.0 if as_percent else v)
		val.text = _fmt_param(v, as_percent))
	vb.add_child(row)


static func _fmt_param(v: float, as_percent: bool) -> String:
	return ("%d%%" % int(round(v))) if as_percent else str(int(round(v)))


## Beta 房创建载荷的附加字段(普通态返回空字典 → 合并无副作用)。
func _beta_payload() -> Dictionary:
	if not PvpSession.beta_mode:
		return {}
	time_rules.clamp_self()
	return {"beta": true, "time": time_rules.to_dict()}


# ── 建房/对战选项面板里的「选图」一节(三个联机页共用)── 房主选 ⇒ 存 Settings.mp_map_path ⇒ 报到时随 player_options 上报 ⇒ worker 开局定图。★ 存档里那张图被删 / 改名时归一化成「随机」:否则上报的坏路径只会让服务器静默回落默认图,玩家以为选的是别的图。
func _add_map_picker(vb: VBoxContainer) -> void:
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.mp_map_path, 2, 260.0, "地　图(房主选;缩略图 = 开局地形简略图)")
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


# 进对局场景。★ 各模式的切场方式刻意不同,别为了「统一」改掉:1v1 直切;大乱斗 / 3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内到达,栈内切场景会在这个栈里 free 大厅 / 重建大物理世界 ⇒ 偶发原生段错误(曾实测)。
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
