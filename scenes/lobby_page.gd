class_name LobbyPage
extends Control

# 大厅页的**共享基类**(1v1 `matchmaking` / 大乱斗 `royale_lobby` 都 extends 它)。
#
# ★ 为什么:两个大厅页本是一份「连大厅 → 列房间 → 配对了转连 worker」的状态机,按
#   「1v1 / 大乱斗」叉开时**复制**了整份实现 —— 于是同一处修正要改两遍,漏一处**不报错**
#   (表现是"1v1 里好了、大乱斗里没变",或反过来)。2026-09-15 收口(计划 3.6):
#   凡是两个模式**语义相同**的都上提到这里;子类只留真正的差异。
#
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像"),与 `scenes/pvp_match_client.gd`
#   同款。上提的函数里 `_push_lobby_name` / `_on_lobby_connected` / `_on_lobby_connect_failed`
#   是**逐字相同**,其余只差 1~3 行 —— 那些行全部落成下方"子类钩子"。
#
# ★ 刻意**不**在这里的(差的不是重复,是第二根结构轴):
#   · `_ready`(两页版式完全不同)、`_build_options_panel` / `_build_create_panel` / `_build_wait_panel`;
#   · `_on_room_list` vs `_on_royale_rooms`(2 人房 vs N 人房,行样式与文案都不同);
#   · `_process` 的**派发**(见下方三条 `_tick_*` 的告警 —— 两页梯顺序不同,合并会改行为)。
#   要再上提一批,先按同样的口径量一遍差异(剔注释后逐行 diff),别凭印象搬。
#
# ★ 本类读 `Settings` autoload(后补的两个设置区块要用),故**不**放进 `ui/ui_factory.gd` ——
#   那个工厂至今零 autoload 依赖(3.7 把 Settings 读写全留在调用方),是它的一条不变量。

# 本机服务器一键启停(同目录 Cyancular Ruins Server.exe)。preload 而非全局类名,
# 避免新脚本未进全局类缓存时整份场景解析失败(本项目踩过同类坑)。
# 常量可继承:两页 `_ready` 里的 LocalServer.lan_ip_hint() 直接读本常量,无需各自再声明。
const LocalServer := preload("res://core/net/local_server.gd")


# ── 共用状态(两页同名同义;子类不要再声明一次)──
var _addr_edit: LineEdit
var _status: Label
var _list_box: VBoxContainer
var _ip_label: Label = null   # 常驻本机 IP 提示(进页/重启后即显示,不靠易被刷掉的状态栏)
var _connected := false
var _connected_addr := ""          # 当前连的是哪个地址(地址框改了要重连)
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
# 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _lobby_start_ms := 0
# ── 转连对局 worker(两页同款)──
var _connecting_worker := false   # 是否在转连对局 worker(用于超时兜底提示)
var _go_start_ms := 0
var _claimed_ms := 0       # 已向 worker claim,等 match_start 的起始时间(0=未 claim)
# 大厅配对结果:go_match 在大厅 peer 的 poll() 调用栈内到达,不能就地切连接 → 存下来帧末执行
var _pending_go_role := -1
var _pending_go_port := -1


# ── 页面基建(子类在 _ready 里按各自的版式顺序调用)──

# 不透明深色底:全局清屏色被 Level0 设成浅蓝后,白字界面会看不清。
func _add_lobby_background() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.size = get_viewport_rect().size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	move_child(bg, 0)   # 垫底,不挡后续控件


# 收尾(建完本页全部控件、接完本页自己的信号之后调):接共用信号 + 递归补像素字体 +
# 进页自动拉一次房间列表。子类各自那几条信号先接后接都行(互不相干)。
func _finish_lobby_ready() -> void:
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)
	UiFactory.apply_font_recursive(self)
	# 进页自动连大厅拉房间列表(列表区域不再是一片空白;手动刷新仍可用)
	_request_list.call_deferred("正在连接服务器获取房间列表…")


# 按钮工厂:字体/字号纪律走 UiFactory,尺寸与位置由本页版式给(KH 原布局值)。
# 不用 UiFactory.button():它的 420×64 是主菜单按钮列的约定,与大厅页的绝对定位小按钮不合。
func _page_button(text: String, pos: Vector2, size: Vector2, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	UiFactory.style_control(b, 16)
	UiFactory.style_button(b)
	b.position = pos
	b.custom_minimum_size = size
	b.size = size
	b.pressed.connect(fn)
	add_child(b)
	return b


# ── 两个设置区块(两页各手抄一份)──
# 都读写 Settings,故留在本类而不是 `ui/ui_factory.gd` —— 那个工厂至今零 autoload 依赖。

# 禁用武器网格(2 列 + 定尺寸剪影,横排会溢出屏幕)。勾选直写 Settings.pvp_disabled_weapons
# + save():两页语义相同(房主开关,禁用项随 player_options 上发)。
# h_sep 是各页的**版式值**(1v1 页 26 / 大乱斗页 10 —— 剪影是长条形,列距本就不同)。
# on_cell 给需要额外记账的页面(大乱斗要把勾选框收进 _weapon_checks,建房时读勾选态)。
# ★ 字号 32 写成**字面量**而非形参:kh_l5 的字号规范只认整数字面量实参,改成变量会让
#   这一处**静默脱保**(两页的值本来就都是 32,没有参数化的理由)。
func _add_weapon_grid(parent: Node, h_sep: int, on_cell: Callable = Callable()) -> void:
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", h_sep)
	wgrid.add_theme_constant_override("v_separation", 6)
	parent.add_child(wgrid)
	# 显式 int:循环变量来自字面量数组,`var slot_i := slot` 推断不出类型会整文件解析失败
	for slot: int in [1, 2, 3, 4, 5, 6]:
		var slot_i := slot
		var cell := WeaponIcons.make_weapon_check(slot_i, Settings.pvp_disabled_weapons.has(slot_i),
				32, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(slot_i):
					Settings.pvp_disabled_weapons.append(slot_i)
				elif not on:
					Settings.pvp_disabled_weapons.erase(slot_i)
				Settings.save())
		if on_cell.is_valid():
			on_cell.call(cell, slot_i)
		wgrid.add_child(cell)


# 角色色相行(滑条 + 预览色块,即选即存 Settings.pvp_color_hue)。
# label_text 非空时在**行内**先放标签;大乱斗页的标签另起一行(该页版式),故传 "" 并在外面自己加。
# slider/chip 尺寸也是各页版式(280×24 / 48×24 与 300×30 / 46×30),故走参数。
# ★ 键必须是 "separation":**HBoxContainer 只认 separation,h_separation 是 GridContainer 的键**
#   (h_separation 写在 HBox 上会被存下来但**永不读取** = 静默无效覆盖)。两页原文正好一正一误:
#   1v1 页写 separation(=12,生效),大乱斗页写 h_separation(死覆盖,实际是默认 4)。
#   收口后统一走正确键 → 大乱斗页这一行的间距由 4 变 12,是本次**唯一**的有意观感变化。
func _add_hue_row(parent: Node, label_text: String, slider_size: Vector2,
		chip_size: Vector2) -> HBoxContainer:
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 12)
	parent.add_child(crow)
	if not label_text.is_empty():
		crow.add_child(UiFactory.label(label_text, 32))
	var hue_slider := HSlider.new()
	hue_slider.min_value = 0.0
	hue_slider.max_value = 360.0
	hue_slider.step = 5.0
	hue_slider.value = Settings.pvp_color_hue
	hue_slider.custom_minimum_size = slider_size
	UiFactory.style_slider(hue_slider)
	crow.add_child(hue_slider)
	var chip := ColorRect.new()
	chip.custom_minimum_size = chip_size
	chip.color = UiFactory.hue_preview_color(Settings.pvp_color_hue)
	crow.add_child(chip)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		chip.color = UiFactory.hue_preview_color(v))
	return crow


# ── 大厅连接(两个模式共用;差异全落在下方"子类钩子")──

# 把当前昵称上报给大厅(房间列表展示在房玩家)
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


# 按当前地址框连大厅;已连同一地址则直接执行。改地址会自动重连(不会连到旧地址)。
func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = _lobby_fallback_addr()
		_addr_edit.text = addr
	PvpSession.server_address = addr
	if _connected and _connected_addr == addr:
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


# 请求房间列表:状态文案由调用方给(两页文案不同),RPC 由子类发(协议不同)。
func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		_send_list_request())


func _on_refresh_pressed() -> void:
	_request_list("刷新房间列表…")


# 一键启动/重启本机服务器:杀旧实例 → 拉起同目录服务端 exe → 强制重连 127.0.0.1 刷新列表。
# 协程,按钮回调内 await。
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


# 服务器文本播报。重启本机服期间旧连接被杀的「服务器断开」是预期噪音,不覆盖状态 ——
# 这条两页同款,故基类直接实现(大乱斗页就用这一份)。
# 1v1 另有"房间已满/不存在 → 自动刷新列表""配对已取消 → 刷新恢复可操作"两段,整段覆写本函数。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t


# ── 转连对局 worker ──

# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若立刻 NetBus.stop(),
# 正在 poll 的 peer 引用被清零、在自己的调用栈内被 free → 偶发原生段错误
# (实测「对手连入配对完成的一瞬间」闪退)。故把整个切换推迟到帧末(deferred
# flush 已脱离 poll 栈)执行。
func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	_pending_go_port = port
	_on_go_match_extra()
	_status.text = _go_match_status()
	_do_go_match.call_deferred()


func _do_go_match() -> void:
	if _pending_go_role < 0:
		return
	var role := _pending_go_role
	var port := _pending_go_port
	_pending_go_role = -1
	_pending_go_port = -1
	PvpSession.role = role
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
	# claim_role 保持原版 2 参(大厅/worker 兼容);本端选项走扩展节点 NetBusExt
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())


# 转连 worker 失败/无应答的兜底:断开当前连接回大厅,连上后 _on_lobby_connected 自动刷新列表。
# 没有它,worker 死掉时玩家会永久停在"正在连接对局服务器/等待配对",只能自己找出路。
func _return_to_lobby(msg: String) -> void:
	_connecting_worker = false
	_claimed_ms = 0
	_on_return_to_lobby()
	NetBus.stop()
	_connected = false
	# 重连也要起表:否则 _process 那条「8s 没连上大厅就给明确提示」的兜底对新连接不成立,
	# UDP 静默丢包时状态栏会停在"已返回大厅并刷新"而实际没刷新(用户只能手点「刷新」自救)。
	_lobby_start_ms = Time.get_ticks_msec()
	_status.text = msg
	NetBus.start_client(PvpSession.server_address)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	_enter_match_scene()


# ── 超时梯(两页共用的三条)──
# ★ 本基类**不提供 `_process`**:两页的梯顺序不同(1v1 是 [worker→join→大厅→claim],
#   大乱斗是 [worker→claim→大厅→ack]),且各有一条页面专属梯。顺序看着无所谓,实际有差:
#   1v1 那一 tick 里「大厅-8s 先清 _pending_action、claim-25s 再 _return_to_lobby」若被并成
#   只跑后者,_pending_action 就不再被清 —— 单看代码看不出来。故派发留在各子类,这里只给函数体。

# 转连 worker 12s 无连接(死端口/worker 死了)。返回 true = 已处理,调用方应 return。
func _tick_worker_connect_timeout() -> bool:
	if _connecting_worker and Time.get_ticks_msec() - _go_start_ms > 12000:
		_return_to_lobby(_worker_timeout_msg())
		return true
	return false


# 大厅连接超时兜底:同因(UDP 静默丢包),8 秒仍没连上就给明确提示。
# 原实现**不** return(后面还有别的梯要跑),故本函数无返回值。
func _tick_lobby_connect_timeout() -> void:
	if not _connecting_worker and _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "连接大厅超时——请检查地址/网络(UDP 7777)"


# claim 后 25s 仍未 match_start:对方未就绪 / worker 中途死掉。
# 返回 true = 已处理,调用方应 return。
func _tick_claim_timeout() -> bool:
	if _claimed_ms > 0 and Time.get_ticks_msec() - _claimed_ms > 25000:
		_return_to_lobby(_claim_timeout_msg())
		return true
	return false


# ── 子类钩子 ──
# 必需项:基类给**会报错**的兜底 —— 漏覆写=当场可见,不是静默错值
# (与 `PvpMatchClient._apply_peer_names` 同款)。

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


# go_match 到达时的状态栏文案
func _go_match_status() -> String:
	push_error("LobbyPage: 子类必须覆写 _go_match_status()")
	return ""


# 转连 worker 的 connection_failed 回调
func _on_worker_connect_failed() -> void:
	push_error("LobbyPage: 子类必须覆写 _on_worker_connect_failed()")


# 两条超时梯各自的文案(1v1 说"换一个房间";大乱斗要说清端口要放行)
func _worker_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _worker_timeout_msg()")
	return ""


func _claim_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _claim_timeout_msg()")
	return ""


# 进对局场景。★ 两页**刻意不同**,别为了"统一"改掉任何一边:
#   1v1 直切;大乱斗必须 call_deferred —— 它的 match_start 在 NetBus.poll 调用栈内到达,
#   栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
func _enter_match_scene() -> void:
	push_error("LobbyPage: 子类必须覆写 _enter_match_scene()")


# ── 默认空实现的钩子(只有一页需要)──

# 大厅操作闸门:返回 false = 拒绝本次操作(状态栏文案由覆写方自己写)
func _lobby_action_allowed() -> bool:
	return true


# 换服务器重连**之前**(1v1 要清掉旧列表:旧房间号在新服上必然"房间不存在")
func _on_lobby_reconnect() -> void:
	pass


# go_match 到达时的页面专属记账(1v1 要停 join 兜底计时)
func _on_go_match_extra() -> void:
	pass


# 回大厅**之前**的页面专属清理(1v1 停 join 兜底;大乱斗要退出等待室、恢复创建面板)
func _on_return_to_lobby() -> void:
	pass


# 本机服重启就绪、即将重连之前(1v1 要放开"只自动刷新一次"的闸门)
func _on_local_server_ready() -> void:
	pass
