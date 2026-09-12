extends Control

# 本机服务器一键启停(同目录 Cyancular Ruins Server.exe)。preload 而非全局类名,
# 避免新脚本未进全局类缓存时整份场景解析失败(royale_lobby 蓝屏同款教训)。
const LocalServer := preload("res://Globals/local_server.gd")
# 匹配场景:建房 / 加入 / 房间列表(点击即加入)。
# 连上大厅(默认 120.53.107.140:7777)后,「IP 右侧 刷新」列出全部房间(方块=房间号+人数,
# 未满优先排前;点击方块直接加入)。点入后由大厅配对发 go_match → 转连该局 worker。
# 右侧为对战选项面板(像素风,实验分支 KikuchiHeinr):本地视觉项即选即用;
# 服务器权威项(回合回血/禁武器)以房主(role1)为准,随 claim_role 上报。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"

var _addr_edit: LineEdit
var _code_edit: LineEdit
var _status: Label
var _ai_duel_btn: Button = null
var _list_box: VBoxContainer
var _connected := false
var _connected_addr := ""          # 当前连的是哪个地址(地址框改了要重连)
var _auto_refreshed := false   # 「点了看起来未满却已满」后只自动刷新一次,手动刷新再放开
var _pending_action: Callable = Callable()   # 连上后要执行的建房/加入/刷新
var _connecting_worker := false   # 是否在转连对局 worker(用于超时兜底提示)
var _go_start_ms := 0
var _lobby_start_ms := 0   # 连大厅计时(UDP 被静默丢包时 connection_failed 要等很久,8s 给明确提示)
var _ip_label: Label = null   # 常驻本机 IP 提示
var _map_opt: OptionButton = null   # 房主选图(随机/文件名)
var _join_sent_ms := 0     # 刚发出 join_room 的时间戳:服务端无任何应答(幽灵房间)时兜底回大厅刷新
var _claimed_ms := 0       # 已向 worker claim,等 match_start 的起始时间(0=未 claim)

func _ready() -> void:
	_addr_edit = _make_line_edit(Vector2(60, 120), "服务器地址", PvpSession.server_address)
	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.position = Vector2(330, 120)
	refresh.size = Vector2(90, 36)
	refresh.pressed.connect(_on_refresh_pressed)
	add_child(refresh)
	# 一键本机开服:1v1 与大乱斗共用同目录的 Cyancular Ruins Server.exe
	var srv_btn := Button.new()
	srv_btn.text = "启动/重启本机服务器"
	srv_btn.position = Vector2(432, 114)
	srv_btn.size = Vector2(200, 48)
	srv_btn.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"
	srv_btn.pressed.connect(_on_local_server_pressed)
	add_child(srv_btn)
	_ip_label = Label.new()
	_ip_label.position = Vector2(432, 166)
	_ip_label.add_theme_font_size_override("font_size", 20)
	_ip_label.add_theme_color_override("font_color", Color(0.65, 0.9, 1.0))
	_ip_label.text = LocalServer.lan_ip_hint()
	add_child(_ip_label)

	var name_le := _make_line_edit(Vector2(60, 60), "昵称(头上显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	_code_edit = _make_line_edit(Vector2(60, 180), "房间号(加入时填)", "")

	_status = Label.new()
	_status.position = Vector2(60, 320)
	_status.size = Vector2(720, 60)
	add_child(_status)

	_make_button(Vector2(60, 240), "建房", _on_create_pressed)
	_make_button(Vector2(260, 240), "加入", _on_join_pressed)
	# AI 补位对战(实验性):建房等待期房主可改为与 AI 开局(仅自建服务端支持)
	_ai_duel_btn = _make_button(Vector2(460, 240), "AI 对战", func() -> void:
		_status.text = "AI 补位开局中…"
		_ai_duel_btn.visible = false
		NetBusExt.c2s("ai_duel"))
	_ai_duel_btn.visible = false
	_make_button(Vector2(60, 400), "返回", func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://Scenes/main_menu.tscn"))

	var cap := Label.new()
	cap.text = "房间列表(只读展示;加入请在上方填房间号)"
	cap.position = Vector2(60, 460)
	cap.size = Vector2(700, 30)
	add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 500)
	scroll.size = Vector2(640, 560)
	add_child(scroll)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(600, 0)
	scroll.add_child(vb)
	_list_box = vb

	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_server_message.connect(_on_server_message)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_connect_failed)

	# 不透明深色底:全局清屏色被 Level0 设成浅蓝后,白字界面会看不清。
	# 本场景根节点 Control 无满矩形锚(尺寸 0),满矩形子节点会跟着为 0 → 显式给固定窗口尺寸。
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.size = get_viewport_rect().size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	move_child(bg, 0)   # 垫底,不挡后续控件

	_build_options_panel()
	_apply_pixel_font(self)

	# 进页自动连大厅拉房间列表(列表区域不再是一片空白;手动刷新仍可用)
	_request_list.call_deferred("正在连接服务器获取房间列表…")


# ── 像素风格:递归给已有控件挂像素字体 ──
func _apply_pixel_font(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer \
			or root is GridContainer or root is ScrollContainer):
		var pf: FontFile = load(PIXEL_FONT)
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		_apply_pixel_font(n)


# ── 对战选项面板(右侧)──
func _build_options_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(980, 60)
	panel.custom_minimum_size = Vector2(640, 0)
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	vb.add_child(_opt_label("—— 对战选项 ——", 36, Color(0.55, 0.95, 1.0)))
	vb.add_child(_opt_label("(规则项以房主设置为准)", 20, Color(0.7, 0.75, 0.8)))

	vb.add_child(_opt_check("显示敌方武器轨迹", Settings.pvp_show_trajectories, func(on: bool) -> void:
		Settings.pvp_show_trajectories = on
		Settings.save()))
	vb.add_child(_opt_check("每回合开始回满血(房主生效)", Settings.pvp_round_full_heal, func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save()))
	vb.add_child(_opt_check("显示敌方血量条", Settings.pvp_show_enemy_hp, func(on: bool) -> void:
		Settings.pvp_show_enemy_hp = on
		Settings.save()))
	vb.add_child(_opt_check("打开小地图", Settings.pvp_show_minimap, func(on: bool) -> void:
		Settings.pvp_show_minimap = on
		Settings.save()))
	vb.add_child(_opt_check("小地图显示敌方位置", Settings.pvp_minimap_show_enemy, func(on: bool) -> void:
		Settings.pvp_minimap_show_enemy = on
		Settings.save()))

	# 禁用武器(房主生效):2 列网格 + 定尺寸剪影(横排会溢出屏幕)
	vb.add_child(_opt_label("禁用武器(房主生效):", 24))
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", 10)
	wgrid.add_theme_constant_override("v_separation", 6)
	vb.add_child(wgrid)
	for slot in [1, 2, 3, 4, 5, 6, 7]:
		var captured_slot: int = slot
		var cell := WeaponComponent.make_weapon_check(captured_slot, Settings.pvp_disabled_weapons.has(captured_slot),
				24, func(on: bool) -> void:
				if on and not Settings.pvp_disabled_weapons.has(captured_slot):
					Settings.pvp_disabled_weapons.append(slot)
				elif not on:
					Settings.pvp_disabled_weapons.erase(slot)
				Settings.save())
		wgrid.add_child(cell)

	# 角色颜色(色相 0-360,即选即用,双方各自染自己)
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 12)
	vb.add_child(crow)
	crow.add_child(_opt_label("自己角色颜色:", 24))
	var hue_slider := HSlider.new()
	hue_slider.min_value = 0.0
	hue_slider.max_value = 360.0
	hue_slider.step = 5.0
	hue_slider.value = Settings.pvp_color_hue
	hue_slider.custom_minimum_size = Vector2(280, 24)
	crow.add_child(hue_slider)
	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(48, 24)
	chip.color = _hue_preview_color(Settings.pvp_color_hue)
	crow.add_child(chip)

	# 地图选择(房主生效;服务端没带该图文件时回退默认图)
	crow.add_child(_opt_label("地图:", 24))
	_map_opt = OptionButton.new()
	_map_opt.add_item("随机(默认)")
	var maps1: Array[String] = RoomManager.list_maps()
	for i in maps1.size():
		_map_opt.add_item(maps1[i])
		if maps1[i] == Settings.last_map:
			_map_opt.selected = i + 1
	_map_opt.custom_minimum_size = Vector2(240, 40)
	_map_opt.add_theme_font_size_override("font_size", 20)
	_map_opt.item_selected.connect(func(i: int) -> void:
		Settings.last_map = "" if i == 0 else maps1[i - 1]
		Settings.save())
	crow.add_child(_map_opt)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		chip.color = _hue_preview_color(v))


# 色相预览(玩家本体是青蓝系,按色相旋转取近似展示色)
func _hue_preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, 0.75, 1.0)


func _opt_label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l


func _opt_check(text: String, initial: bool, on_toggle: Callable) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	cb.button_pressed = initial
	cb.add_theme_font_size_override("font_size", 24)
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	return cb

func _make_line_edit(pos: Vector2, placeholder: String, initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = Vector2(240, 36)
	le.placeholder_text = placeholder
	le.text = initial
	add_child(le)
	return le

func _make_button(pos: Vector2, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(180, 48)
	b.pressed.connect(fn)
	add_child(b)
	return b

func _on_lobby_connected() -> void:
	if _connecting_worker:
		return   # 转连对局 worker 的连接走 _on_go_match,不在这里接管
	_lobby_start_ms = 0
	_connected = true
	_connected_addr = PvpSession.server_address
	_push_lobby_name()
	NetBusExt.client_hello()   # 能力协商:换回服务器 build/caps(旧服不响应 → 超时降级)
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

# 把当前昵称上报给大厅(房间列表展示在房玩家)
func _push_lobby_name() -> void:
	if _connected:
		NetBus.rpc_id(1, "lobby_name", PvpSession.player_name)

# 按当前地址框连大厅;已连同一地址则直接执行。改地址会自动重连(不会连到旧地址)。
func _with_lobby(action: Callable) -> void:
	var addr := _addr_edit.text.strip_edges()
	if addr == "":
		addr = PvpSession.server_address   # 空地址回退默认大厅(127.0.0.1 必失败且超时极慢)
		_addr_edit.text = addr
	PvpSession.server_address = addr
	if _connected and _connected_addr == addr:
		action.call()
		return
	_status.text = "正在连接服务器…"
	_connected = false
	_pending_action = action
	_clear_room_list()   # 换服务器重连:清掉旧列表(旧房间号在新服上必然「房间不存在」)
	NetBus.stop()
	var err := NetBus.start_client(addr)
	if err != OK:
		_status.text = "启动连接失败(%d)" % err
		_pending_action = Callable()
	else:
		_lobby_start_ms = Time.get_ticks_msec()

# 清空房间列表区(重连/换地址时旧列表是陈旧数据,点了必失败)
func _clear_room_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var tip := Label.new()
	tip.text = "正在连接服务器获取房间列表…"
	tip.add_theme_font_size_override("font_size", 24)
	_list_box.add_child(tip)

func _on_create_pressed() -> void:
	_with_lobby(func() -> void:
		NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间号后可刷新让对手看到)")

func _on_join_pressed() -> void:
	_join_code(_code_edit.text.strip_edges())

# 加入某房间号(手动输入)
func _join_code(code: String) -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	PvpSession.room_code = code
	_with_lobby(func() -> void:
		_status.text = "加入房间 %s,等待配对…" % code
		_join_sent_ms = Time.get_ticks_msec()
		NetBus.rpc_id(1, "join_room", code))

func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")


# 一键启动/重启本机服务器(与大乱斗大厅同款):杀旧实例 → 拉起同目录服务端 exe →
# 强制重连 127.0.0.1 刷新列表。协程,按钮回调内 await。
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
	_auto_refreshed = false
	_request_list("本机服务器已就绪(%s),正在获取房间列表…" % LocalServer.lan_ip_hint())

func _request_list(msg: String) -> void:
	_with_lobby(func() -> void:
		_status.text = msg
		NetBus.rpc_id(1, "list_rooms"))

# 房间列表:未满优先在前,已满置灰不可点
func _on_room_list(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var partial: Array = []
	var full: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		(full if int(r.get("players", 2)) >= 2 else partial).append(r)
	var order: Array = partial + full
	if order.is_empty():
		var empty := Label.new()
		empty.text = "暂无房间 —— 点「建房」开一局吧"
		empty.size = Vector2(600, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个房间"
		return
	for r in order:
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var occ: String = ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   玩家: " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s      %d/2%s" % [code, players, occ]
		btn.custom_minimum_size = Vector2(600, 46)
		# 点击方块直接加入(已满的由服务器拒绝并自动刷新列表)
		btn.disabled = false
		btn.focus_mode = Control.FOCUS_ALL
		btn.add_theme_font_size_override("font_size", 24)
		var pf: FontFile = load(PIXEL_FONT)
		if pf != null:
			btn.add_theme_font_override("font", pf)
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			_join_code(code))
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(未满优先)" % order.size()

func _on_server_message(t: String) -> void:
	if LocalServer.restarting and (t == "服务器断开" or t == "连接失败"):
		return   # 重启本机服期间,旧连接被杀的断连提示是预期噪音,不覆盖状态
	if t == "房间已满" or t == "房间不存在":
		# 点了失效/已满的房间 → 提示并自动刷新一次(列表常驻陈旧房间,点了必失败)
		# 推迟到帧末:server_message 在大厅 peer 的 poll 调用栈内到达,
		# 栈内立刻 NetBus.stop()(重连)会把正在 poll 的 peer 提前 free → 原生段错误
		_join_sent_ms = 0   # 服务端已明确应答,停掉 join 兜底
		if not _auto_refreshed:
			_auto_refreshed = true
			_request_list.call_deferred("%s → 已自动刷新列表" % t)
		else:
			_status.text = t
	elif t.begins_with("配对已取消"):
		# 已入房后房主/对端掉线被大厅取消:房间已不在,直接刷新恢复可操作(不叠加 _auto_refreshed 门)
		_join_sent_ms = 0
		_request_list.call_deferred("配对已取消(对手离开)——已刷新列表,请重选")
	else:
		_status.text = t

func _on_room_created(code: String) -> void:
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code
	_ai_duel_btn.visible = true   # 房主等待期可选与 AI 对战(实验性,仅自建服)

func _on_room_joined(role: int) -> void:
	# 注意:此处不清 _join_sent_ms——入房后到 go_match 之间若房主掉线、大厅关房,
	# 客户端会收不到 go_match 也没有任何后续;保留该兜底计时(超时自动刷新回大厅)。
	_status.text = "已加入,等待开战……"
	_ai_duel_btn.visible = false   # 真人已补位,不需要 AI

# 大厅配对完成:断开大厅 → 转连对局 worker,并 claim 大厅分配的角色。
# go_match 在大厅 peer 的 poll() 调用栈内作为 RPC 到达;此处若立刻 NetBus.stop(),
# 正在 poll 的 peer 引用被清零、在自己的调用栈内被 free → 偶发原生段错误
# (实测「对手连入配对完成的一瞬间」闪退)。故把整个切换推迟到帧末(deferred
# flush 已脱离 poll 栈)执行。
var _pending_go_role := -1
var _pending_go_port := -1

func _on_go_match(role: int, port: int) -> void:
	_pending_go_role = role
	_pending_go_port = port
	_join_sent_ms = 0   # 配对成功:停 join 兜底,转由转连 worker/claim 兜底接管
	_status.text = "配对成功,连接对局服务器……"
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
	multiplayer.connection_failed.connect(func() -> void:
		if _connecting_worker:
			# 对局 worker 连不上(幽灵房间/端口已死)→ 停本段等待,自动回大厅刷新
			_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")
	, CONNECT_ONE_SHOT)
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
	NetBusExt.c2s("player_options", {
		"hue": Settings.pvp_color_hue,
		"map": (Settings.last_map if _map_opt == null else ("" if _map_opt.selected == 0 else _map_opt.get_item_text(_map_opt.selected))),
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
	})

# 幽灵房间/死 worker 兜底:断开当前连接回大厅,连上后 _on_lobby_connected 自动刷新列表。
func _return_to_lobby(msg: String) -> void:
	_connecting_worker = false
	_claimed_ms = 0
	_join_sent_ms = 0
	NetBus.stop()
	_connected = false
	_status.text = msg
	NetBus.start_client(PvpSession.server_address)

# 转连 worker / 入房应答超时兜底:UDP 连不上不会立刻报失败,这里定时自动回大厅,
# 不让「点了幽灵房间」永久停在"正在连接对局服务器/等待配对"。
func _process(_delta: float) -> void:
	# 1) 转连 worker 12s 无连接(死端口):不再只是提示,直接回大厅并刷新
	if _connecting_worker and Time.get_ticks_msec() - _go_start_ms > 12000:
		_return_to_lobby("对局服务器无响应(房间可能已失效)——已返回大厅并刷新,请换一个房间")
		return
	# 2) join_room 发出去 10s 服务端无任何应答(幽灵房间/丢包):自动刷新列表恢复可操作
	if not _connecting_worker and _claimed_ms == 0 and _join_sent_ms > 0 \
			and Time.get_ticks_msec() - _join_sent_ms > 10000:
		_join_sent_ms = 0
		_request_list("房间无响应(可能已失效)——已自动刷新列表,请重选")
		return
	# 大厅连接超时兜底:同因(UDP 静默丢包),8 秒仍没连上就给明确提示
	if not _connecting_worker and _lobby_start_ms > 0 and not _connected \
			and Time.get_ticks_msec() - _lobby_start_ms > 8000:
		_lobby_start_ms = 0
		_pending_action = Callable()
		_status.text = "连接大厅超时——请检查地址/网络(UDP 7777)"
	# claim 后 25s 仍未 match_start:对方未就绪(房间失效/对端掉线/云服无降级开局)→
	# 放弃本局并自动重连大厅,恢复列表/建房能力(原「连接对局服务器」永久卡死)
	if _claimed_ms > 0 and Time.get_ticks_msec() - _claimed_ms > 25000:
		_return_to_lobby("对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间")

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	# RPC 在 NetBus.poll 调用栈内到达(worker→客户端 match_start);直接在栈内切场景会
	# 在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(进图蓝屏/卡退)。
	# 延迟到帧末再切,脱离 poll 栈(大乱斗侧同款;本分支整合时曾丢失,现补回)。
	get_tree().call_deferred("change_scene_to_file", "res://Scenes/pvp_game.tscn")
