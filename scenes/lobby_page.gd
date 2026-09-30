class_name LobbyPage
extends Control

# 大厅页的**共享基类**(1v1 `matchmaking` / 大乱斗 `royale_lobby` / 3v3 `team_lobby` 都 extends 它)。
#
# ★ 为什么:三个大厅页本是一份「连大厅 → 列房间 → 配对了进对局」的状态机,按模式叉开时
#   **复制**了整份实现 —— 于是同一处修正要改三遍,漏一处**不报错**。2026-09-15 收口(计划 3.6):
#   凡是语义相同的都上提到这里;子类只留真正的差异。
#
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像"),与 `scenes/pvp_match_client.gd`
#   同款。上提的函数里 `_push_lobby_name` / `_on_lobby_connected` / `_on_lobby_connect_failed`
#   是**逐字相同**,其余只差 1~3 行 —— 那些行全部落成下方"子类钩子"。
#
# ★★ 2026-09-28 的**根本变化**(单进程单端口):原先"配对成功"= 停掉大厅连接、转连到另一台
#   worker 进程;现在服务端只有**一个**进程、**一个**端口,客户端从进大厅到打完**全程连着它**。
#   于是本类里与"转连"有关的一整套东西(转连超时梯 / 转连失败回调 / 转连状态标记)整体消失,
#   `go_match` 退化成"进对局场景"这一个信号。
#
# ★ 本类读 `Settings` / `NetBus` autoload(设置区块与连接),故**不**放进 `ui/ui_factory.gd`
#   —— 那个工厂至今零 autoload 依赖(3.7 把 Settings 读写全留在调用方),是它的一条不变量。

# 本机服务端一键启停(同目录 Cyancular Ruins Server.exe)。preload 而非全局类名,
# 避免新脚本未进全局类缓存时整份场景解析失败(本项目踩过同类坑)。
# 常量可继承:三页 `_ready` 里的 LocalServer.SERVER_EXE 等直接读本常量,无需各自再声明。
const LocalServer := preload("res://core/net/local_server.gd")
# 远程联机的隧道(EasyTier)。理由同上:preload 而非全局类名。
const Tunnel := preload("res://core/net/tunnel.gd")


# ── 共用状态(三页同名同义;子类不要再声明一次)──
var _status: Label
var _list_box: VBoxContainer
# ★ 2026-09-30:原先这里还有一个 `_ip_label`(页面顶部那条「房间码:——(建房后显示)」)。
#   用户裁定删掉它 —— **房间码直接显示在「房间号」输入框里,并把框设为只读**。
#   所以那个框有了两个身份(建/加入前 = 输入对手的码;进房后 = 显示自己的码),由
#   `_update_code_label()` 一处切换。声明提到基类,因为渲染它的是基类那个函数。
var _code_edit: LineEdit = null
# 入口区两个按钮(三页同名同义)。★ 在房里时**置灰不可点,不隐藏** ——
#   隐藏会让入口突然消失(玩家看不到"现在为什么不能建房"),置灰则保留位置与提示。
var _create_btn: Button = null
var _join_btn: Button = null
var _connected := false
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
# 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _lobby_start_ms := 0
var _claimed_ms := 0       # 已向服务端 claim,等 match_start 的起始时间(0=未 claim)
# 大厅配对结果:go_match 在大厅 peer 的 poll() 调用栈内到达,不能就地切场景 → 存下来帧末执行
var _pending_go_role := -1
# 本端这一局的房间码(建房/加入成功后记下;界面上的「房间码 xxx」读它)
var _room_code := ""


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
	NetBusExt.local_session_token.connect(_on_session_token)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	_update_code_label()
	# 进页拉一次房间列表 —— 但**只在已经连着的时候**(回大厅、回局那两条路)。
	# ★ 没连着时 `_request_list` 只写一句"还没开局…",不会去连任何东西(理由见它头顶那段)。
	_request_list.call_deferred("已连接,正在获取房间列表…")


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


# 对端文本播报(`NetBus.local_server_message`)。断连提示在**建房/重连期间**是预期噪音 ——
# 客户端会主动 `NetBus.stop()` 拆掉旧连接,那条「连接断开」不该覆盖我们自己的状态文案。
# 这条各页同款,故基类直接实现(大乱斗/3v3 页就用这一份)。
# 1v1 另有"房间已满/不存在 → 自动刷新列表""配对已取消 → 刷新恢复可操作"两段,整段覆写本函数。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_status.text = t


# ── 房间码展示 ──
# 房间码的**唯一渲染点**(三页共用)。
# ★★ 2026-09-30 用户裁定:不再有单独的「房间码:——(建房后显示)」标签 ——
#   **建房后码就出现在「房间号」那个框里,并且框不可编辑**。
#   于是那个框有两个身份,由本函数一处切换:
#     · 没房(`_room_code` 空)→ 清空 + 可编辑:供玩家填**对手**的码点「加入」;
#     · 有房 → 显示**自己的**码 + 只读:此刻它不再是输入框,而是"把这串数报给对手"的展示位
#       (在房里还能改这一格没有任何意义,改坏了下次「加入」还会拿它去连)。
# ★ 退出房间时必须调本函数把 `_room_code` 清掉(否则框会一直卡在只读的旧码上)。
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

# 进房后的成功反馈(大乱斗/3v3 两页共用):房主"已创建 + 把房号报出去",客机"已加入"。
# ★ 2026-10-02 起多一档:内置节点表已删,`relay.txt` 没节点时这间房**别人远程进不来**,
#   反馈不能只说"把房间号报给对手"完事 —— 要把修法一并给出去(`Tunnel.no_relay_hint`,
#   文案唯一来源在 Tunnel,别在这里再拼一遍)。
#   ★ 只对**房主**说:客机连的是别人那台,自己这端有没有节点无关。
func _set_room_entered_status(code: String, is_host: bool) -> void:
	if not is_host:
		_status.text = "已加入房间 %s" % code
		return
	var no_relay := Tunnel.no_relay_hint()
	_status.text = ("房间 %s 已创建 —— 把房间号报给对手" % code) if no_relay.is_empty() \
			else ("房间 %s 已创建;%s" % [code, no_relay])


# ── 入口按钮的可用性 ──
# 在房里时把「建房」与「加入」都**置灰**(`disabled = true`),不隐藏。
# ★ 置灰的样式由 `UiFactory.style_button` 提供(灰底 + `C_TEXT_DIM` 字色),不需要另配。
# ★ 只管可用性,不参与任何协议判断:在房里点建房本来也会被服务端挡住
#   (`"你已经在房间里了"`),那一条仍然在。
func _set_entry_buttons_enabled(on: bool) -> void:
	if _create_btn != null:
		_create_btn.disabled = not on
	if _join_btn != null:
		_join_btn.disabled = not on


# ── 两个设置区块(三页各手抄一份)──
# 都读写 Settings,故留在本类而不是 `ui/ui_factory.gd` —— 那个工厂至今零 autoload 依赖。

# 禁用武器网格(2 列 + 定尺寸剪影,横排会溢出屏幕)。勾选直写 Settings.pvp_disabled_weapons
# + save():三页语义相同(房主开关,禁用项随 player_options 上发)。
# h_sep 是各页的**版式值**(1v1 页 26 / 大乱斗页 10 —— 剪影是长条形,列距本就不同)。
# on_cell 给需要额外记账的页面(大乱斗要把勾选框收进 _weapon_checks,建房时读勾选态)。
# ★ 字号 32 写成**字面量**而非形参:kh_l5 的字号规范只认整数字面量实参,改成变量会让
#   这一处**静默脱保**。
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
# ★ 键必须是 "separation":**HBoxContainer 只认 separation,h_separation 是 GridContainer 的键**
#   (h_separation 写在 HBox 上会被存下来但**永不读取** = 静默无效覆盖)。
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


# ── 大厅连接(三个模式共用;差异全落在下方"子类钩子")──

# 把当前昵称上报给大厅(房间列表展示在房玩家)
func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)


func _on_lobby_connected() -> void:
	_lobby_start_ms = 0
	_connected = true
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
	_status.text = "连接失败 —— 检查网络,或重开一次建房"


# 连上房主那台服务端(连不上就先连)之后执行 action。
# ★★ 2026-09-29:**"手填服务器地址"那条路整体删除**,故本函数的连接参数**只**来自 `PvpSession` ——
#   而写它的只有两处,都在本文件内(`_on_create_pressed` 各页自己那份、以及 `_join_with_code`)。
#   原先它还兼着"解析地址框 → 与 `_connected_addr` 比对 → 不等就重连",那是本文件里
#   最容易出错的一段:地址框一旦没同步(比如端口是 await 之后才知道的),比较就不等,
#   于是它会把**刚建好的连接当场拆掉**再连一次。
#   地址框没了,那一整类错法随之消失。
# ★ 走到下面的连接分支的**只有"加入"那条路**:建房那一路的连接是 `launch_and_connect()`
#   内部建好的(探活那一步),到这里已是快路。
func _with_lobby(action: Callable) -> void:
	if not _lobby_action_allowed():
		return
	# ★★ `NetBus.can_send_to_server()` **不是可选项**:`_connected` 是**本端自己的记账**
	#   (只在连上 / 连接失败 / 主动重连时翻),**不随对端断开更新** —— 对端掉线或踢人之后
	#   它仍是 true,于是"已连上"这条快路会把请求发往一个 **ENet 已拆掉的 peer**,也就是那条
	#   `Unable to send packet on channel 0, max channels: 0`(而它是**周期性**的:刷新列表 /
	#   加入 / 建房都走这里 ⇒ 断线后连点几次就报几次)。
	#   加了这一判,断线后的第一次点击就落到下面的**重连**路径:动作存进 `_pending_action`,
	#   连上之后自动补发 ⇒ 既不报错,也顺手修好"断了、界面看着还连着"这个状态。
	if _connected and NetBus.can_send_to_server():
		action.call()
		return
	_status.text = "正在连接房主…"
	_connected = false
	_pending_action = action
	_on_lobby_reconnect()
	NetBus.stop()
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.server_port)
	if err != OK:
		_status.text = "启动连接失败(%d)" % err
		_pending_action = Callable()
	else:
		_lobby_start_ms = Time.get_ticks_msec()


# 请求房间列表:状态文案由调用方给(各页文案不同),RPC 由子类发(协议不同)。
# ★★ **没连着时不拨号**(2026-09-29 修)。单进程单端口 + 手填地址删除之后,"服务端"只可能是
#   **本机刚拉起的那台**(建房)或**隧道带上来的那台**(加入)——
#   界面上根本没有"连一台服务端"这回事。原先这里无条件走 `_with_lobby`,于是
#   **每次进大厅页**都会 `start_client(127.0.0.1:7777)` 去连一台并不存在的服务端:
#   状态栏挂着"正在连接服务器…"(用户 2026-09-29 就是照这句话问的)、8 秒后变超时,
#   而它描述的事情**根本没发生过**。
# ★ `reconnect=true` 是给**回局**那条路留的口子:那一刻 `PvpSession` 里还留着上次那台的
#   地址/端口,断线后确实该重连回去 —— 那不是"还没开局"。
func _request_list(msg: String, reconnect := false) -> void:
	if NetBus.can_send_to_server() or reconnect:
		_with_lobby(func() -> void:
			_status.text = msg
			_send_list_request())
		return
	_connected = false
	_status.text = "还没开局 —— 点「建房」开一局,或用对手给的房间号「加入」"
	# ★★ 2026-09-30 修:这里原来只改状态栏、**不碰列表区** —— 而三条"还没有房间…"原先只在
	#   **大厅应答**里渲染,没连上时又不发请求 ⇒ **首屏列表区永远一片空白**
	#   (标题写着「房间(点自己那间可回到对局)」、底下什么都没有)。首屏就是玩家最常看到的一屏。
	_show_empty_list()


# 列表区的"空态"(**必需覆写**:各页容器与文案不同)。
# 调用点两处:① 上面这条"没连上,没有列表可拉";② 各页自己清列表时。
func _show_empty_list() -> void:
	push_error("LobbyPage: 子类必须覆写 _show_empty_list()")


# ★ 2026-09-30 删除「刷新」/「刷新列表」按钮(用户裁定:没用)。
#   理由:房间列表**只在三种时机会变**,而三种都由代码自己盯着,不需要玩家点:
#     ① 连上大厅时自动拉一次(`_finish_lobby_ready`);
#     ② 退房 / 回列表 / 回局失败时自动重拉(`_on_leave_room` / `_return_to_lobby`);
#     ③ 「房间已满」「房间不存在」被拒时自动刷一次(`matchmaking._on_server_message`)。
#   而列表本身的内容就是"我这台服务器上的房间"(通常只有自己那一间)+ 回局入口,
#   陈旧窗口极小。留着它反而让三页的版式各自多一颗按钮、还都不一样。
#   重新进一次大厅页也会重拉,那是玩家的自然动作。


# ── 建房的前置:**每次建房都从零启动一套** ──
# 语义(2026-09-30 用户裁定):**建房 = 全新的服务端 + 全新的隧道 + 全新的房间**。
#   所以这里无条件地:停掉当前连接 → 停掉隧道 → 停掉本机服务端 → 选端口、启动服务端、连接。
#   ★ 不做"已经是我那台就复用"的判断:房间号决定隧道网络名,换房间就一定换网络,隧道反正要重建;
#     服务端跟着一起重来,心智模型与服务端状态都只剩一种(不存在"同一台上挂着两间房")。
#   ★ `stop_owned()` 只杀"本客户端拉起的那台",别人开的服不受影响;没拉起过就是 no-op。
# 返回 false = 这台起不来(界面文案已写好),调用方直接 return。
func _ensure_own_server() -> bool:
	NetBus.stop()
	_connected = false
	Tunnel.stop()
	LocalServer.stop_owned()
	_status.text = "正在建房…"
	PvpSession.server_address = "127.0.0.1"
	var port: int = await LocalServer.launch_and_connect()
	if port < 0:
		_status.text = "建房失败 —— 确认 %s 与客户端在同一目录" % LocalServer.SERVER_EXE
		return false
	PvpSession.server_port = port
	_update_code_label()
	return true


# ── 房间码加入:房间码 → 隧道 → 连上房主的服务端 ──
# 三页共用。`action` 是"连上之后要发的加入 RPC"(各页协议不同)。
#
# 分两种情形,判据是**这串码是不是我当前所在的那张网**(不是"我有没有连着"):
#   · 是同一张网 → 直接用当前连接,房间只是那台服务器上的逻辑实体;
#   · 不是 → 起 EasyTier 隧道、从房主主机名里读到端口、连 `127.0.0.1:<端口>`,连上后发加入 RPC。
# ★ 2026-09-29:原先这里还有一条"隧道失败就用地址框直连"的退路,已随手填地址一并删除 ——
#   那条退路本身也是坏的(地址框给的是不带端口的 IP,而端口自随机化后不是常量)。
func _join_with_code(code: String, action: Callable) -> void:
	if code.is_empty():
		_status.text = "请填房间码"
		return
	if not Tunnel.is_valid_room(code):
		_status.text = "房间码是 5 位数字(例 48213)"
		return
	# ★★ 2026-09-30 修:本判据原为 `_connected and NetBus.can_send_to_server()` —— 它分不出
	#   "同一张网上的房间"与"另一台机器",于是"已连着房主 A 时输房主 B 的码"会把 B 的码
	#   发去 **A 的服务器**,拿到一句把人引向"码敲错了"的「房间不存在」,而 B 那台
	#   **从头到尾没被连过**(唯一出路是先「返回主菜单」—— 只有那里调 `NetBus.stop()`,
	#   而界面上没有任何东西提示这件事)。
	#   ★ 房间码同时是 EasyTier 的网络名(`network-name = "cyr-<码>"`)⇒ **换一串码就是换一张网**。
	#   ★ 同一张网时**不能**重连:重连会换 peer id,而服务端房记录里存的正是 peer id
	#     (`room.players`)⇒ 一断一重连,它会把我当成掉线。
	if Tunnel.on_network(code) and NetBus.can_send_to_server():
		action.call()
		return
	if not Tunnel.available():
		_status.text = Tunnel.missing_hint()
		return
	# ★★ 没有初始节点 = 客机**不可能**找到房主(2026-09-29 实测:EasyTier 既没有默认初始节点、
	#   也没有局域网自动发现 —— 不带 `-p`/`-e` 时 peer 列表里**永远只有本机**一条)。
	#   在这里说清楚,别让它退化成下面那句"找不到房间 N" —— 那句话会把玩家引向
	#   "房间码敲错了"这个**错误方向**,而真正要改的是初始节点。
	if not Tunnel.has_initial_peers():
		_status.text = ("远程联机需要一个初始节点(中继):把共享节点地址按行写进 %s,"
				% Tunnel.relay_file()
				+ "房主与客机填同一份。")
		return
	# ── 走到这里 = 换到另一张网:先把旧的收干净 ──
	# ★ 三件都要收:旧连接、旧隧道、**以及"我如果是房主,本机那台服务端"**。
	#   漏掉最后一件的后果:我方服务端继续跑着、房里也还挂着我一具身体 ——
	#   对别人就是一台**看得见、却永远开不了局的服务器**(我不会再回去 claim)。
	#   `stop_owned()` 只杀"本客户端拉起的那台",绝不动别人开的服;没拉起过就是 no-op。
	if Tunnel.is_running() or not Tunnel.current_code().is_empty():
		NetBus.stop()
		_connected = false
		LocalServer.stop_owned()
		Tunnel.stop()
		_status.text = "正在切换到房间 %s 所在的网络…" % code
	else:
		_status.text = "正在连接房间 %s(建立隧道,最多 60 秒)…" % code
	var got: Dictionary = await Tunnel.start_client(code)
	if got.is_empty():
		_status.text = ("找不到房间 %s —— 可能是:房主已关房、码敲错了、"
				+ "或两端的初始节点填的不是同一个") % code
		return
	# ★ 连接参数在这里落下(`_with_lobby` 只读 `PvpSession`,不再从界面上取)。
	#   ★★ 端口取**本机转发的绑定口**,不是房主那个端口号(2026-10-01 解耦,见
	#      `Tunnel.add_udp_forward`):客机连的是自己那条 `127.0.0.1:Q`,房主端口只当转发目标。
	PvpSession.server_address = "127.0.0.1"
	var fwd := Tunnel.forward_port()
	PvpSession.server_port = fwd if fwd > 0 else int(got["port"])
	_status.text = "已找到房主(%s),正在加入…" % str(got["host_ip"])
	_with_lobby(action)


# ── 进对局 ──

# 大厅在 `go_match` **之前**下发的一次性会话令牌(断线重连用)。
# ★ 先存进 `_pending_token` 而不是直接写 PvpSession:go_match 也是本帧到达的,两者由
#   `_do_go_match.call_deferred` 在帧末一起落到 PvpSession,顺序就不会被 RPC 到达次序左右。
var _pending_token := ""


func _on_session_token(token: String) -> void:
	_pending_token = token


# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若就地切场景,会在自己的调用栈内
# free 掉正在 poll 的 peer → 偶发原生段错误(实测「对手连入配对完成的一瞬间」闪退)。
# 故把整个切换推迟到帧末(deferred flush 已脱离 poll 栈)执行。
func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	# ★ 端口就是**此刻连着的那一个**(单进程单端口):记下来给局内断线重连用。
	#   不再有"转连到另一个端口"这回事,故这里不做任何连接动作。
	# ★★ 但**客机不能照单全收**:`go_match` 报的是**房主的**服务端端口,而客机连的是自己
	#   那条转发的绑定口(`Tunnel.forward_port()`)。收下它,局内重连就会去连一个对客机
	#   无意义的号 —— 同一台机器上更糟:那个号连到的是**另一个实例**的服务端。
	#   判据 = "本端有没有转发":有 = 客机(保留自己的),没有 = 房主(接受服务端报的)。
	if port > 0 and Tunnel.forward_port() <= 0:
		PvpSession.server_port = port
	_on_go_match_extra()
	_status.text = _go_match_status()
	_do_go_match.call_deferred()


# ── 回大厅后回局(spec §3.4 路径乙)──
# 入口 = **本页房间列表里"自己那间房"那一行被按下**(见 `try_rejoin_row`;三个大厅页共用这一份)。
# 本页做三件事:
#   ① 发 `rejoin_request(房间号, token)` —— ★ **此刻本页一定连着大厅**(那一行就是 `room_list`
#      载荷里来的),故这里**不连大厅、不碰地址框、也不走 `_with_lobby`**:照原稿搬会
#      `NetBus.stop()` + 重连一次,把刚拿到的列表连同自己那一行一起丢掉。
#   ② 大厅复用 `go_match` 把它送回原局 —— 之后与首次进场**逐字同一条路**。
#   ③ 唯一的岔路在 `_claim_role`(对局已经开着 → 必须发 `reclaim_role`)。
var _rejoin_sent_ms := 0


# 房间列表里某一行被按下时,**先问这一句**(三页的 `_on_room_list` 都调它)。
# 返回 true = 这一行是我的房、凭据还在、**而且是"对局中"** ⇒ 已走回局;false = 交给调用方走普通加入。
# ★★ 它同时是**行可点性**的判据(页面渲染那一行时也要问同一句)—— 两处共用一个函数,
#    免得"看着可点、点了没用"或反过来。
# ★★ 两个条件缺一不可,**且次序不变**(先问"是不是我的房 + 凭据还在",再轮到"对局中"):
#    · `can_rejoin_to(code)`(房号 + 凭据):写反成"先看 in_match" ⇒ 自己那间房**连点都点不到**;
#    · `in_match`:只看前一条的话,手里有凭据时**自己那间还没开局的等待中的房**也会走回局分支
#      —— 而那种房在大厅侧**没有凭据表条目**(凭据是开局前才发的),于是必收 `rejoin_denied`
#      ("凭据失效"),而**普通加入那一半根本不会发生**。
func try_rejoin_row(code: String, in_match: bool) -> bool:
	if not PvpSession.can_rejoin_to(code):
		return false
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
	# ★★ 发送前先判活(与 `_with_lobby` 快路里那条**同一条纪律**、同一个症状):回局入口
	#     **刻意不走 `_with_lobby`**(它会把刚拿到的列表连同自己那一行一起丢掉),所以这一判
	#     必须自带。断线后那一行**还画在屏上**(列表是断线前拉的),点它等于把 `rejoin_request`
	#     打在 ENet 已拆掉的 peer 上 —— 正是那条 `Unable to send packet on channel 0`。
	#     走 `_request_list` 顺带把重连拉起来,而不是把玩家留在一句"正在回到对局…"上;
	#     **`rejoin` 也要清掉** —— 否则下一次 `go_match` 会错走 `reclaim_role` 分支。
	if not NetBus.can_send_to_server():
		PvpSession.rejoin = false
		_request_list("连接断了 —— 正在重连并刷新房间列表…", true)
		return
	_rejoin_sent_ms = Time.get_ticks_msec()
	_status.text = "正在回到对局…"
	NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token)


# 大厅答"回不去了"(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。
# ★ 必须清:否则那一行**永远是可点的**,而每次点都是同一句失败(玩家完全不知道为什么)。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	# ★ 凭据一清,那一行在**下一次渲染**时必须回到"对局中(灰色、点不动)"。本页没有"就地改一行"
	#   的路径,重拉列表是唯一的重渲染入口 —— 少了它,玩家眼前那行还停在"可点"的样子上。
	_request_list("已刷新房间列表")


# 回局请求发出后大厅一直没应答的兜底(15s)。没有它,玩家会停在一句"正在回到对局…"上,
# 而本页的其它兜底梯(claim)此时**都还没启动**(它们要等 `go_match` 之后)。
# ★ 判据里带 `PvpSession.rejoin`:回局成功时它已被清掉,这条梯自然失效(claim 那条接管)。
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
	# ★ 只在**真收到新 token** 时才覆盖:回局那条路大厅**不重发** `session_token`(客户端那
	#   一份就是凭据本身),无条件写会把手里唯一能证明"我是原来那个人"的串抹成空
	#   → `reclaim_role` 必被拒(理由"令牌不匹配")并**踢连接**,而现场一个字都没有。
	if _pending_token != "":
		PvpSession.token = _pending_token
	_pending_token = ""
	# ★★ 与原形的分界就在这里:原先是 `NetBus.stop()` + `start_client(地址, worker 端口)`
	#   —— 断开大厅、连到另一个进程。现在服务端只有那一个,**连接不动**,claim 直接发在
	#   这条既有的连接上。
	_claim_role(role)


func _claim_role(role: int) -> void:
	_claimed_ms = Time.get_ticks_msec()
	# ★★ 回局(路径乙)与首次进场的**唯一分叉**:对局**已经开着**,`claim_role` 这条走不得,
	#   必须改发 `reclaim_role`(宽限期内重新认领自己那个 role)。
	#   ★ **它的失败形态是"静默"、不是"被踢"**:`MatchSession._begin_match` 在开局那一刻就
	#   `NetBus.role_claimed.disconnect(_on_role_claimed)` —— 迟到的 `claim_role`
	#   **根本没有收件人**,既不踢人也不打印。⇒ 可观察的后果是"**这个客户端再也回不来**":
	#   它卡在大厅页,靠本页 claim 兜底梯(`_return_to_lobby`)收场。
	if PvpSession.rejoin:
		PvpSession.rejoin = false
		NetBusExt.rpc_id(1, "reclaim_role", role, PvpSession.token)
		return
	# claim_role 保持原版 2 参(与原版服务端的协议兼容);本端选项走扩展节点 NetBusExt
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	# token 走扩展节点(原 NetBus 的 claim_role 签名一律不动)。原版服务端无本节点 →
	# 静默丢弃 → 那局就是"不能重连",不影响对局本身。
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)


# claim 后仍等不到 match_start 的兜底:断开当前连接回大厅,连上后自动刷新列表。
# 没有它,那一局死掉时玩家会永久停在"等待配对",只能自己找出路。
func _return_to_lobby(msg: String) -> void:
	_claimed_ms = 0
	# ★ 回局失败的各种兜底都汇到这里:不清 `rejoin` 就会让页停在"回局态"反复重试(每次都失败)。
	#   `token` **不清** —— 它可能还有效,玩家可以在列表里再点一次那一行。
	PvpSession.rejoin = false
	_rejoin_sent_ms = 0
	_on_return_to_lobby()
	NetBus.stop()
	_connected = false
	# 重连也要起表:否则 `_tick_lobby_connect_timeout` 对新连接不成立,UDP 静默丢包时状态栏会
	# 停在"已返回大厅并刷新"而实际没刷新(用户只能手点「刷新」自救)。
	_lobby_start_ms = Time.get_ticks_msec()
	_status.text = msg
	NetBus.start_client(PvpSession.server_address, PvpSession.server_port)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	_enter_match_scene()


# ── 超时梯(共用)──
# ★ 本基类**不提供 `_process`**:各页的梯顺序不同(1v1 是 [join→大厅→claim],大乱斗另有
#   一条页面专属梯),且顺序看着无所谓、实际有差。故派发留在各子类,这里只给函数体。

# 大厅连接超时兜底:UDP 静默丢包时 `connection_failed` 要等很久,8 秒仍没连上就给明确提示。
func _tick_lobby_connect_timeout() -> void:
	if _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "连接超时 —— 检查网络"


# claim 后 25s 仍未 match_start:对方未就绪 / 服务端中途出错。
# 返回 true = 已处理,调用方应 return。
func _tick_claim_timeout() -> bool:
	if _claimed_ms > 0 and Time.get_ticks_msec() - _claimed_ms > 25000:
		_return_to_lobby(_claim_timeout_msg())
		return true
	return false


# ── 子类钩子 ──
# 必需项:基类给**会报错**的兜底 —— 漏覆写=当场可见,不是静默错值
# (与 `PvpMatchClient._apply_peer_names` 同款)。

# 发一次"列房间"RPC(1v1 走 NetBus 的 list_rooms;大乱斗走 NetBusExt 的 royale_list)
func _send_list_request() -> void:
	push_error("LobbyPage: 子类必须覆写 _send_list_request()")


# 报到时随 player_options 上发的本端选项(各模式字段不同:大乱斗多 match_time、回合回血恒 false)
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
# 房主选 → 存 Settings.mp_map_path → 报到时随 player_options 上报 → worker 开局定图
# (`server_main._on_player_options` 归档、`MapCatalog.resolve_pvp_map` 校验、`match_start` 下发)。
# ★ 存档里那张图被删/改名时**归一化成"随机"**:否则上报的坏路径只会让服务器静默回落默认图,
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


# claim 超时梯的文案(1v1 说"换一个房间";大乱斗要说清端口要放行)
func _claim_timeout_msg() -> String:
	push_error("LobbyPage: 子类必须覆写 _claim_timeout_msg()")
	return ""


# 进对局场景。★ 各页**刻意不同**,别为了"统一"改掉任何一边:
#   1v1 直切;大乱斗必须 call_deferred —— 它的 match_start 在 NetBus.poll 调用栈内到达,
#   栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
func _enter_match_scene() -> void:
	push_error("LobbyPage: 子类必须覆写 _enter_match_scene()")


# ── 默认空实现的钩子(只有一页需要)──

# 大厅操作闸门:返回 false = 拒绝本次操作(状态栏文案由覆写方自己写)
func _lobby_action_allowed() -> bool:
	return true


# 重连**之前**(1v1 要清掉旧列表:旧房间号在重连后必然"房间不存在")
func _on_lobby_reconnect() -> void:
	pass


# go_match 到达时的页面专属记账(1v1 要停 join 兜底计时)
func _on_go_match_extra() -> void:
	pass


# 回房间列表**之前**的页面专属清理(1v1 停 join 兜底;大乱斗要退出等待室、恢复创建面板)
func _on_return_to_lobby() -> void:
	pass
