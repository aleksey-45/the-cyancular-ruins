class_name LobbyPage
extends Control

# 大厅页的**共享基类**(统一大厅 `mp_lobby` extends 它)。
#
# - 为什么:大厅页负责房间列表展示、对局匹配与进入对局的状态机，历史上按
#   「1v1 / 大乱斗 / 3v3」叉开时**复制**成了三份实现 —— 于是同一处修正要改三遍,漏一处**不报错**
#   (表现是"1v1 里好了、另两个没变")。2026-09-15 起逐批统一集中处理(计划 3.6),2026-10-03 三页合一:
#   凡是各模式**语义相同**的都上提到这里;子类只留真正的差异。
#
# - 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像"),与 `scenes/pvp_match_client.gd`
#   相同机制。上提的函数里 `_push_lobby_name` / `_on_lobby_connected` / `_on_lobby_connect_failed`
#   是**逐字相同**,其余只差 1~3 行 —— 那些行全部落成下方"子类钩子"。
#
# - 刻意**不**在这里的(差的不是重复,是第二根结构轴;现只有 `mp_lobby` 一个子类):
#   - `_ready`(版式与画出的东西不同)与**整页 chrome / 三个弹层**(2026-10-03 起它们是
#     `scenes/mp_lobby.tscn` 的**静态基础结构框架** —— 连"建树"这件事都不在代码里了);
#   - `_on_room_list` vs `_on_royale_rooms` vs `_on_team_rooms`(2 人房 vs N 人房,行样式与文案都不同);
#   - `_process` 的**派发**(见下方三条 `_tick_*` 的告警 —— 梯顺序与页面专属梯有关,合并会改行为)。
#   要再上提一批,先按同样的口径量一遍差异(剔注释后逐行 diff),别凭印象搬。
#
# - 本类读 `Settings` autoload(禁用武器网格那个设置区块要用),故**不**放进 `ui/ui_factory.gd`
#   —— 那个工厂至今零 autoload 依赖(3.7 把 Settings 读写全留在调用方),是它的一条不变量。

# 本机服务端托管(同目录 Cyancular Ruins Server.exe)。preload 而非全局类名,
# 避免新脚本未进全局类缓存时整份场景解析失败。
const LocalServer := preload("res://core/net/local_server.gd")
const Tunnel := preload("res://core/net/tunnel.gd")


# ── 共用状态(子类不要再声明一次)──
var _status: Label
var _room_code := ""
var _code_edit: LineEdit = null
var _connected := false
var _connected_addr := "127.0.0.1"   # 已连服务端的地址记账(测试探针读写)
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
# 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _lobby_start_ms := 0
# ── 进对局(不再有"转连到另一个端口"这一步)──
var _claimed_ms := 0       # 已 claim,等 match_start 的起始时间(0=未 claim)
# 大厅配对结果:go_match 在大厅 peer 的 poll() 调用栈内到达,不能就地切场景 → 存下来帧末执行
var _pending_go_role := -1


# ── 页面基建(子类在 `_ready` 里调)──
# - 页面底色(不透明深色)现在是**基础结构框架里的那个 `ColorRect`**:全局清屏色被 Level0 设成浅蓝
#   之后,白字界面会看不清 —— 所以每一页都得自带一块不透明底。`_add_lobby_background()`
#   随 2026-10-03 那次迁移退役(底色已进 `scenes/mp_lobby.tscn`)。


# 收尾(建完本页全部控件、接完本页自己的信号之后调):接共用信号 + 递归补像素字体 +
# 进页自动拉一次房间列表。子类各自那几条信号先接后接都行(互不相干)。
func _finish_lobby_ready() -> void:
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBusExt.local_session_token.connect(_on_session_token)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	# 进页自动连大厅拉房间列表(列表区域不再是一片空白;手动刷新仍可用)
	_request_list.call_deferred("正在连接服务器获取房间列表…")


# ── 设置区块(子类建房用)──
# 读写 Settings,故留在本类而不是 `ui/ui_factory.gd` —— 那个工厂至今零 autoload 依赖。

# 禁用武器网格(2 列 + 定尺寸剪影,横排会溢出屏幕)。勾选直写 Settings.pvp_disabled_weapons
# + save()(房主开关,禁用项随 player_options 上发)。
# h_sep 是**调用方**的版式值(剪影是长条形,列距本就不同)。
# on_cell 给需要额外记账的调用方(要把勾选框收进自己的表,建房时读勾选态)。
# - 字号 32 写成**字面量**而非形参:kh_l5 的字号规范只认整数字面量实参,改成变量会让
#   这一处**静默脱保**(调用方本来就都传 32,没有参数化的理由)。
# 注意： 间距键名分两层,别混:`GridContainer` 认 `h_separation` / `v_separation`,而
#    `HBoxContainer` / `VBoxContainer` **只认** `separation` —— 把 `h_separation` 写在 HBox 上
#   会被存下来但**永不读取**(静默无效覆盖;合一前的两个旧大厅页里就有一份写错过)。
func _add_weapon_grid(parent: Node, h_sep: int, on_cell: Callable = Callable()) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", h_sep)
	wgrid.add_theme_constant_override("v_separation", 6)
	parent.add_child(wgrid)
	# 显式 int:入库的是 Array[int],循环变量跟着同类型,别让它退化成 Variant。
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



# ── 大厅连接(两个模式共用;差异全落在下方"子类钩子")──

# 把当前昵称上报给大厅(房间列表展示在房玩家)
func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)


func _on_lobby_connected() -> void:
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
	_lobby_start_ms = 0
	_connected = false
	_pending_action = Callable()
	_status.text = "未检测到本地服务器——请创建房间或输入 5 位房间号加入"


# 连大厅并执行目标动作;已连上则直接执行。
func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	# 注意： `NetBus.can_send_to_server()`:确保对端 peer 仍然存活有效
	if _connected and NetBus.can_send_to_server():
		action.call()
		return
	_status.text = "正在连接本地大厅…"
	_connected = false
	_pending_action = action
	_on_lobby_reconnect()
	NetBus.stop()
	var port := PvpSession.server_port
	var err := NetBus.start_client("127.0.0.1", port)
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


# 服务器文本播报。重启本机服期间旧连接被杀的「服务器断开」是预期噪音,不覆盖状态 ——
# 基类给的是"照抄到状态栏"的默认实现。
# 子类另有"房间已满/不存在 → 自动刷新列表""配对已取消 → 刷新恢复可操作"等段,整段覆写本函数。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t


# ── 进入对局会话 ──

# 大厅在 go_match **之前**下发的一次性会话令牌(断线重连用)。
# - 先存进 `_pending_token` 而不是直接写 PvpSession:go_match 也是本帧到达的,两者由
#   `_do_go_match.call_deferred` 在帧末一起落到 PvpSession,顺序就不会被 RPC 到达次序左右。
#   (时序硬约束:token 必须先于 go_match 发出 —— 客户端收到 go_match 当场 NetBus.stop()
#    断大厅,晚发的载荷静默丢失。大厅侧的发送点见 room_manager 三处 spawn 前。)
var _pending_token := ""

func _on_session_token(token: String) -> void:
	_pending_token = token


# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若立刻切场景,会在自己的
# 调用栈内 free 掉大厅/重建大物理世界 → 偶发原生段错误。故把整个切换推迟到帧末执行。
func _on_go_match(role: int, port: int) -> void:
	# 端口就是**此刻连着的那一个**(单进程单端口):记下来给局内断线重连用。
	#   不再有"转连到另一个端口"这回事,故这里不做任何连接动作。
	# - **客机不能照单全收**:`go_match` 报的是**房主的**服务端端口,而客机连的是自己那条
	#   转发的绑定口(`Tunnel.forward_port()`)。收下它,局内重连就会去连一个对客机无意义的号
	#   —— 同一台机器上更糟:那个号连到的是**另一个实例**的服务端。
	#   判据 = "本端有没有转发":有 = 客机(保留自己的),没有 = 房主(接受服务端报的)。
	if port > 0 and Tunnel.forward_port() <= 0:
		PvpSession.server_port = port
	_pending_go_role = role
	_on_go_match_extra()
	_status.text = _go_match_status()
	_do_go_match.call_deferred()


# ── 回大厅后回局(spec §3.4 路径乙;2026-09-21)──
# 入口 = **本页房间列表里"自己那间房"那一行被按下**(见 `try_rejoin_row`;三个大厅页共用这一份)。
# 本页做三件事:
#   ① 发 `rejoin_request(房间号, token)` —— -  **此刻本页一定连着大厅**(那一行就是 `room_list`
#      载荷里来的),故这里**不连大厅、不碰地址框、也不走 `_with_lobby`**:照原稿搬会
#      `NetBus.stop()` + 重连一次,把刚拿到的列表连同自己那一行一起丢掉。
#   ② 大厅复用 `go_match` 把它送回原对局会话 —— 之后与首次进场**逐字同一条路**。
#   ③ 唯一的岔路在 `_claim_role`(对局已经开着 → 必须发 `reclaim_role`)。
# - 原稿那条"地址取 `PvpSession.server_address` 而不是地址框(三个页的地址框默认值不同)"的绕法
#   随入口一起作废:它防的是"从主菜单按按钮进来时页还没连上、只能照地址框连"那一档,而现在
#   玩家**就站在已经连上的那一页**上。
var _rejoin_sent_ms := 0


# 房间列表里某一行被按下时,**先问这一句**(子类的 `_on_room_list` 调它)。
# 返回 true = 这一行是我的房、凭据还在、**而且是"对局中"**  ->  已走回局;false = 交给调用方走普通加入。
# 注意： 它同时是**行可点性**的判据(页面渲染那一行时也要问同一句)—— 两处共用一个函数,
#    免得"看着可点、点了没用"或反过来。
# 注意： 两个条件缺一不可,**且次序不变**(先问"是不是我的房 + 凭据还在",再轮到"对局中"):
#    - `can_rejoin_to(code, mode)`(房号 + 模式 + 凭据):写反成"先看 in_match"  ->  自己那间房**连点都点不到**;
#    - `in_match`(**2026-09-22 加**,I2):只看前一条的话,手里有凭据时**自己那间还没开局的
#      等待中的房**也会走回局分支 —— 而那种房在大厅侧**没有凭据表条目**(凭据是开局前才发的),
#      于是必收 `rejoin_denied`("凭据失效"),而**普通加入那一半根本不会发生**
#      (本函数已经 return true,调用方不再 `_join_code`)。玩家看到的是"点了自己的房,
#      冒出一句与眼前这间房无关的拒绝"。-  等待中的房本来就该走普通加入(与别人点它一样)。
func try_rejoin_row(code: String, in_match: bool, mode: String) -> bool:
	if not PvpSession.can_rejoin_to(code, mode):
		return false
	# 第二问:**这一行是不是"对局中"**(I2,2026-09-22 加)
	if not in_match:
		return false
	PvpSession.rejoin = true
	_request_rejoin()
	return true


func _request_rejoin() -> void:
	# 凭据不完整(理论上到不了:行本就不该可点)→ 清掉开关,别把玩家卡在"回局态"
	if not PvpSession.can_rejoin():
		PvpSession.rejoin = false
		_status.text = "回局凭据已失效,请重新建房/加入"
		return
	# 注意： 发送前先存活检测(与上面 `_with_lobby` 快路里那条**同一条纪律**、同一个症状):回局入口
	#    **刻意不走 `_with_lobby`**(它会把刚拿到的列表连同自己那一行一起丢掉),所以这一判
	#    必须自带。断线后那一行**还画在屏上**(列表是断线前拉的),点它等于把
	#    `rejoin_request` 打在 ENet 已拆掉的 peer 上 —— 正是那条
	#    `Unable to send packet on channel 0, max channels: 0`。
	#    走 `_request_list` 顺带把重连启动来(它内部会存活检测并落到重连路径),而不是把玩家
	#    留在一句"正在回到对局…"上;**`rejoin` 也要清掉** —— 否则下一次 `go_match` 会错走
	#    `reclaim_role` 分支(`_claim_role` 只看这个开关)。
	if not NetBus.can_send_to_server():
		PvpSession.rejoin = false
		_request_list("与大厅的连接已断开——正在重连并刷新房间列表…")
		return
	_rejoin_sent_ms = Time.get_ticks_msec()
	_status.text = "正在回到对局…"
	NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token)


# 大厅答"回不去了"(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。
# - 必须清:否则那一行**永远是可点的**,而每次点都是同一句失败(玩家完全不知道为什么)。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	# - 凭据一清,那一行在**下一次渲染**时必须回到"对局中(灰色、点不动)"。本页没有"就地改一行"
	#   的路径,重拉列表是唯一的重渲染入口 —— 少了它,玩家眼前那行还停在"可点"的样子上。
	_request_list("已刷新房间列表")


# 回局请求发出后大厅一直没应答的保底处理(15s)。没有它,玩家会停在一句"正在回到对局…"上,
# 而本页的其它保底处理梯(对局认领 / claim)此时**都还没启动**(它们要等 `go_match` 之后)。
# - 判据里带 `PvpSession.rejoin`:回局成功时它已被清掉,这条梯自然失效(claim 那条接管)。
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
	var role := _pending_go_role
	_pending_go_role = -1
	PvpSession.role = role
	# - 只在**真收到新 token** 时才覆盖:回局那条路大厅**不重发** `session_token`(客户端那
	#   一份就是凭据本身),无条件写会把手里唯一能证明"我是原来那个人"的串抹成空
	#   → `reclaim_role` 必被拒(理由"令牌不匹配")并**踢连接**,而现场一个字都没有。
	if _pending_token != "":
		PvpSession.token = _pending_token
	_pending_token = ""
	# 局内断线自动重连统一指向当前端口：房主为服务端监听端口，客机为其本地转发端口。
	PvpSession.worker_port = PvpSession.server_port
	# 在单进程单端口架构下，客户端无需断开并重连到新端口，直接复用既有的 ENet 连接。
	# 保持当前连接还能确保客户端的 peer_id 保持不变，从而通过服务端 MatchSession 的开局名册校验。
	_claim_role(role)


func _claim_role(role: int) -> void:
	_claimed_ms = Time.get_ticks_msec()
	# 注意： 回局(路径乙)与首次进场的**唯一分叉**:对局**已经开着**,`claim_role` 这条走不得,
	#   必须改发 `reclaim_role`(宽限期内重新认领自己那个 role)。
	#   - **它的失败形态是"静默"、不是"被踢"**(2026-09-21 订正;原先这里写的是"会被
	#   `_on_role_claimed` 当判定为串线连接并主动断开,日志里留一行拒绝串线" —— **那句话是错的**,真链路探针
	#   实测服务端侧连一行拒绝都没有):`server_main._begin_match` 在开局那一刻就
	#   `NetBus.role_claimed.disconnect(_on_role_claimed)` —— 迟到的 `claim_role`
	#   **根本没有收件人**,既不踢人也不打印(`_match_started` 那第一款判据因此**不可达**)。
	#    ->  可观察的后果是"**这个客户端再也回不来**":它卡在大厅页,靠本页 claim 保底处理梯
	#   (`_return_to_lobby`)收场。-  反证(删掉本分支)红的仍是"点了自己那间房 30s 没回到对局"
	#   那条契约断言,证据是 **服务端日志里"某个拒绝行的缺席"** —— 最弱的一种信号形状,
	#   别指望日志告诉你走错了哪条。
	# - 回局时**不发** `player_options`/`report_token`:服务端对局宿主侧两条 handler 都按
	#   `_claims[r] == caller` 反查,而此刻新 peer 还没进 `_claims`(要等 reclaim 被接受)
	#   → 两条都静默 no-op;而 token 首次 claim 时就报过一次,服务端手里那份正是要比对的那份。
	if PvpSession.rejoin:
		PvpSession.rejoin = false
		NetBusExt.rpc_id(1, "reclaim_role", role, PvpSession.token)
		return
	# claim_role 保持原版 2 参(协议方法表兼容);本端选项走扩展节点 NetBusExt
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	# token 走扩展节点(原 NetBus 的 claim_role 签名一律不动)。未包含本节点的对端 →
	# 静默丢弃 → 那局就是"不能重连",不影响对局本身。
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)


# 对局启动失败或对端无响应时的兜底清理：重置连接并返回大厅，连接成功后触发列表刷新。
func _return_to_lobby(msg: String) -> void:
	_claimed_ms = 0
	# 回局失败时重置 rejoin 状态，避免页面滞留在重试状态；保留 token 以便后续重试。
	PvpSession.rejoin = false
	_rejoin_sent_ms = 0
	_on_return_to_lobby()
	NetBus.stop()
	_connected = false
	# 启动大厅连接计时，以便在连接超时时更新状态栏提示
	_lobby_start_ms = Time.get_ticks_msec()
	_status.text = msg
	NetBus.start_client("127.0.0.1", PvpSession.server_port)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	_enter_match_scene()


# ── 超时检测（基类通用逻辑）──
# 本基类不实现 `_process`，由子类（如 mp_lobby）统一调度执行顺序。
# 在单进程单端口架构下，客户端进入对局无需重新建立网络连接，因此移除了旧有的转连超时判定。

# 大厅连接超时检测：若 8 秒内未收到连接成功回调，更新状态栏提示。
func _tick_lobby_connect_timeout() -> void:
	if _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "未检测到本地服务器——请创建房间或输入 5 位房间号加入"


# 角色认领超时检测：发送 claim_role 后 25 秒仍未收到 match_start，触发回退大厅流程。
# 返回 true 表示超时已处理，调用方应提前返回。
func _tick_claim_timeout() -> bool:
	if _claimed_ms > 0 and Time.get_ticks_msec() - _claimed_ms > 25000:
		_return_to_lobby(_claim_timeout_msg())
		return true
	return false


# 建房前置:无条件清理旧连接、旧隧道与旧服务端,从零启动一台属于本机的全新服务端。
# 返回 true = 本机服务端已启动并连上;false = 启动失败(状态栏已报错)。
func _ensure_own_server() -> bool:
	NetBus.stop()
	Tunnel.stop()
	LocalServer.stop_owned()
	_status.text = "正在启动本机专属服务器…"
	PvpSession.server_address = "127.0.0.1"
	var port: int = await LocalServer.launch_and_connect()
	if port <= 0:
		_status.text = "启动本机服务器失败(检查 Cyancular Ruins Server.exe 与端口)"
		return false
	PvpSession.server_port = port
	_connected = true
	_connected_addr = PvpSession.server_address
	_update_code_label()
	return true


# 按房间码加入:
# 分两种情形,判据是**这串码是不是我当前所在的那张网**(不是"我有没有连着"):
#   - 是同一张网 → 直接用当前连接,房间只是那台服务器上的逻辑实体;
#   - 不是 → 起 EasyTier 隧道、从房主主机名里读到端口、连 127.0.0.1:<端口>,连上后发加入 RPC。
func _join_with_code(code: String, action: Callable) -> void:
	if code.is_empty():
		_status.text = "请填房间码"
		return
	if not Tunnel.is_valid_room(code):
		_status.text = "房间码是 5 位数字(例 48213)"
		return
	if Tunnel.on_network(code) and NetBus.can_send_to_server():
		action.call()
		return
	if not Tunnel.available():
		_status.text = Tunnel.missing_hint()
		return
	if not Tunnel.has_initial_peers():
		_status.text = ("远程联机需要一个初始节点(中继):把共享节点地址按行写进 %s,"
				% Tunnel.relay_file()
				+ "房主与客机填同一份。")
		return
	if Tunnel.is_running() or not Tunnel.current_code().is_empty():
		NetBus.stop()
		_connected = false
		LocalServer.stop_owned()
		Tunnel.stop()
		_status.text = "正在切换到房间 %s 所在的网络…" % code
	else:
		_status.text = "正在加入房间 %s 的网络,打洞中…" % code
	var got: Dictionary = await Tunnel.start_client(code)
	if got.is_empty():
		_status.text = ("找不到房间 %s —— 可能是:房主已关房、码敲错了、"
				+ "或两端的初始节点填的不是同一个") % code
		return
	PvpSession.server_address = "127.0.0.1"
	var fwd := Tunnel.forward_port()
	PvpSession.server_port = fwd if fwd > 0 else int(got.get("port", 0))
	_status.text = "已找到房主(%s),正在加入…" % str(got.get("host_ip", ""))
	_with_lobby(action)


# ── 房间码展示 ──
func _update_code_label() -> void:
	if _code_edit == null:
		return
	if _room_code.is_empty():
		_code_edit.text = ""
		_code_edit.editable = true
		_code_edit.placeholder_text = "房间号"
	else:
		_code_edit.text = _room_code
		_code_edit.editable = false
		_code_edit.placeholder_text = "你的房间号(报给对手)"


# 进房后的成功反馈:房主"已创建 + 把房号报出去",客机"已加入"。
func _set_room_entered_status(code: String, is_host: bool) -> void:
	if not is_host:
		_status.text = "已加入房间 %s" % code
		return
	var no_relay := Tunnel.no_relay_hint()
	_status.text = ("房间 %s 已创建 —— 把房间号报给对手" % code) if no_relay.is_empty() \
			else ("房间 %s 已创建;%s" % [code, no_relay])


# ── 子类钩子 ──
# 必需项:基类给**会报错**的保底处理 —— 漏覆写=当场可见,不是静默错值
# (与 `PvpMatchClient._apply_peer_names` 保持一致)。


# 发一次"列房间"RPC(1v1 走 NetBus 的 list_rooms;大乱斗走 NetBusExt 的 royale_list)
func _send_list_request() -> void:
	push_error("LobbyPage: 子类必须覆写 _send_list_request()")


# 报到时随 player_options 上发的本端选项(两边字段不同:大乱斗多 match_time、回合回血恒 false)
func _player_options() -> Dictionary:
	push_error("LobbyPage: 子类必须覆写 _player_options()")
	return {}


# ── 时间玩法(Beta)建房参数(两个 Beta 大厅页共用;普通态不显示也不上报)──
# 值住在 time_rules(TimeRules 实例),建房/上报前 clamp;服务器侧还会再 clamp 一次(上报不可信)。
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


# ── 建房/对战选项面板里的「选图」一节(三个联机页共用)──
# 房主选 → 存 Settings.mp_map_path → 报到时随 player_options 上报 → 服务端开局定图
# (`server_main._on_player_options` 归档、`MapCatalog.resolve_pvp_map` 校验、`match_start` 下发)。
# - 存档里那张图被删/改名时**归一化成"随机"**:否则上报的坏路径只会让服务器静默回落默认图,
#   玩家以为选的是别的图。
func _add_map_picker(vb: VBoxContainer) -> void:
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.mp_map_path, 2, 260.0, "地　图(房主选;缩略图 = 开局地形简略图)")
	Settings.mp_map_path = picker.selected
	picker.picked.connect(func(p: String) -> void:
		Settings.mp_map_path = p
		Settings.save())


# go_match 到达时的状态栏文案
func _go_match_status() -> String:
	push_error("LobbyPage: 子类必须覆写 _go_match_status()")
	return ""


# 角色认领超时提示文案（由子类根据模式定制具体提示信息）
func _claim_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _claim_timeout_msg()")
	return ""


# 进对局场景。-  各模式的切场方式**刻意不同**,别为了"统一"改掉:
#   1v1 直切;大乱斗 / 3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内到达,
#   栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
func _enter_match_scene() -> void:
	push_error("LobbyPage: 子类必须覆写 _enter_match_scene()")


# ── 默认空实现的钩子(只有一页需要)──

# 大厅操作门控前置校验:返回 false = 拒绝本次操作(状态栏文案由覆写方自己写)
func _lobby_action_allowed() -> bool:
	return true


# 换服务器重连**之前**(1v1 要清掉旧列表:旧房间号在新服上必然"房间不存在")
func _on_lobby_reconnect() -> void:
	pass


# go_match 到达时的页面专属记账(1v1 要停 join 保底处理计时)
func _on_go_match_extra() -> void:
	pass


# 回大厅**之前**的页面专属清理(1v1 停 join 保底处理;大乱斗要退出等待室、恢复创建面板)
func _on_return_to_lobby() -> void:
	pass


# 本机服重启就绪、即将重连之前(1v1 要放开"只自动刷新一次"的门控前置校验)
func _on_local_server_ready() -> void:
	pass
