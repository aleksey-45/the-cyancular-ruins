extends LobbyPage

# 匹配场景:建房 / 加入 / 房间列表(点击即加入)。
# 连上大厅(默认 120.53.107.140:7777)后,「IP 右侧 刷新」列出全部房间(方块=房间号+人数,
# 未满优先排前;点击方块直接加入)。点入后由大厅配对发 go_match → 转连该局 worker。
# 场景是裸 Control(matchmaking.tscn 无子节点、无 connection),UI 全在代码里建;
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# 连接状态机 / 转连 worker / 按钮工厂都在基类 `LobbyPage` 里(与大乱斗大厅共用)——
# 本文件只留 1v1 的差异:版式、房间列表渲染、server_message 的三段处理、超时梯顺序。

# 开关行/滑条行的**标签列宽**(本页原值 440;版式调参,各页面本就不同 —— 见 UiFactory.check_row 的注释)。
const OPT_LABEL_W := 440.0

var _code_edit: LineEdit
var _auto_refreshed := false   # 「点了看起来未满却已满」后只自动刷新一次,手动刷新再放开
var _join_sent_ms := 0     # 刚发出 join_room 的时间戳:服务端无任何应答(幽灵房间)时兜底回大厅刷新


func _ready() -> void:
	_add_lobby_background()
	_addr_edit = UiFactory.line_edit(self, Vector2(60, 120), Vector2(240, 36), "服务器地址", PvpSession.server_address)
	_page_button("刷新", Vector2(330, 120), Vector2(90, 36), _on_refresh_pressed)
	# 一键本机开服:客户端各模式共用同目录的 Cyancular Ruins Server.exe
	var srv_btn := _page_button("启动/重启本机服务器", Vector2(432, 114), Vector2(200, 48),
			_on_local_server_pressed)
	srv_btn.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"
	_ip_label = UiFactory.label(LocalServer.lan_ip_hint(), 16, UiFactory.C_ACCENT)
	_ip_label.position = Vector2(432, 166)
	add_child(_ip_label)

	var name_le := UiFactory.line_edit(self, Vector2(60, 60), Vector2(240, 36), "昵称(头上显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	_code_edit = UiFactory.line_edit(self, Vector2(60, 180), Vector2(240, 36), "房间号(加入时填)", "")

	_status = UiFactory.label("", 16)
	_status.position = Vector2(60, 320)
	_status.size = Vector2(720, 60)
	add_child(_status)

	_page_button("建房", Vector2(60, 240), Vector2(180, 48), _on_create_pressed)
	_page_button("加入", Vector2(260, 240), Vector2(180, 48), _on_join_pressed)
	# 返回放在整列最下方:原先在 y=400 —— 上不着天下不着地地插在状态行与房间列表之间,
	# 既不属于上面的表单、也不属于下面的列表(2026-09-13 视觉评析)。
	_page_button("返回", Vector2(60, 1090), Vector2(180, 48), _on_back_pressed)

	var cap := UiFactory.label("房间列表(点击即加入;也可在上方填房间号)", 16, UiFactory.C_TEXT_DIM)
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

	_build_options_panel()
	_finish_lobby_ready()


# ── 对战选项面板(右侧)──
# 本面板的选项分三类,**全部已生效**(2026-09-14 逐条核实;勿再照旧注释改成"待接线")——
#  ① 服务器权威规则项:每回合回满血、禁用武器。
#     勾选写进 Settings → _claim_role_worker 随 player_options 上发 →
#     server_main._on_player_options 归档(server_main.gd:206) →
#     MatchBootstrap.start_on 取 **role1(房主)** 那份(server_main.gd:300) →
#     MatchHost 读 round_full_heal / disabled_weapons(match_host.gd:60-61)。
#     ★ 权威以**房主(role1)**的选项为准;非房主勾了不生效 —— 这是设计,不是缺陷。
#  ② 角色颜色(色相 0-360):**必须经服务器中转**。随 player_options 上发 → 服务器按 role
#     汇总(server_main.gd:313 _claim_hues)→ match_sync 的 hues 回下发 → 客户端染对手身体。
#     它管的正是"别人身上的颜色",所以不能只读本机 Settings。
#  ③ 本机显示项:显示敌方武器轨迹 / 显示敌方血量条 / 打开小地图(含小地图显示敌方位置)。
#     只写 Settings,由 pvp_client / royale_game 在 _ready 里直接读,不上发。
func _build_options_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(980, 60)
	panel.custom_minimum_size = Vector2(640, 0)
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	vb.add_child(UiFactory.label("—— 对战选项 ——", 32, UiFactory.C_ACCENT))
	vb.add_child(UiFactory.label("(规则项以房主设置为准)", 16, UiFactory.C_TEXT_DIM))

	vb.add_child(UiFactory.check_row("显示敌方武器轨迹", Settings.pvp_show_trajectories, OPT_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_trajectories = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("每回合开始回满血(房主生效)", Settings.pvp_round_full_heal, OPT_LABEL_W, func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("显示敌方血量条", Settings.pvp_show_enemy_hp, OPT_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_enemy_hp = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("打开小地图", Settings.pvp_show_minimap, OPT_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_minimap = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("小地图显示敌方位置", Settings.pvp_minimap_show_enemy, OPT_LABEL_W, func(on: bool) -> void:
		Settings.pvp_minimap_show_enemy = on
		Settings.save()))

	# 禁用武器(房主生效):2 列网格 + 定尺寸剪影(横排会溢出屏幕)
	vb.add_child(UiFactory.label("禁用武器(房主生效):", 32, UiFactory.C_ACCENT))
	var wgrid := GridContainer.new()
	wgrid.columns = 2
	wgrid.add_theme_constant_override("h_separation", 26)   # 剪影是长条形,列挨太近会与邻列挤在一起
	wgrid.add_theme_constant_override("v_separation", 6)
	vb.add_child(wgrid)
	for slot in [1, 2, 3, 4, 5, 6]:
		var captured_slot: int = slot
		var cell := WeaponComponent.make_weapon_check(captured_slot, Settings.pvp_disabled_weapons.has(captured_slot),
				32, func(on: bool) -> void:
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
	crow.add_child(UiFactory.label("自己角色颜色:", 32))
	var hue_slider := HSlider.new()
	hue_slider.min_value = 0.0
	hue_slider.max_value = 360.0
	hue_slider.step = 5.0
	hue_slider.value = Settings.pvp_color_hue
	hue_slider.custom_minimum_size = Vector2(280, 24)
	UiFactory.style_slider(hue_slider)
	crow.add_child(hue_slider)
	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(48, 24)
	chip.color = UiFactory.hue_preview_color(Settings.pvp_color_hue)
	crow.add_child(chip)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		chip.color = UiFactory.hue_preview_color(v))


# 本页刷新要先放开「只自动刷新一次」的闸门(手动刷新=用户明确要重来)
func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")


# 清空房间列表区(重连/换地址时旧列表是陈旧数据,点了必失败)
func _clear_room_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	_list_box.add_child(UiFactory.label("正在连接服务器获取房间列表…", 32))


func _on_create_pressed() -> void:
	_with_lobby(func() -> void:
		NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间号后可刷新让对手看到)")


func _on_join_pressed() -> void:
	_join_code(_code_edit.text.strip_edges())


# 加入某房间号(手动输入或点房间列表)
func _join_code(code: String) -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_status.text = "加入房间 %s,等待配对…" % code
		_join_sent_ms = Time.get_ticks_msec()
		NetBus.rpc_id(1, "join_room", code))


# 房间列表:未满优先在前;已满/失效的房间由服务器拒绝并自动刷新列表
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
		var empty := UiFactory.label("暂无房间 —— 点「建房」开一局吧", 16)
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
		btn.text = "房间 %s    %d/2%s" % [code, players, occ]
		UiFactory.style_control(btn, 16)
		UiFactory.style_row_button(btn)
		btn.custom_minimum_size = Vector2(600, 46)
		# 左对齐:房间号是定宽段(「房间」+定长码),人数也是定宽段,故左对齐后
		# 两行的房间号列 / 人数列天然对齐。原先居中排版,行的长短一变整串就跟着左右漂
		# ——「1/2」在两行里位置都不同,读起来是一堆居中的字而不是一张表。
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# 点击方块直接加入(已满的由服务器拒绝并自动刷新列表)
		btn.disabled = false
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			_join_code(code))
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(未满优先)" % order.size()


# 本页比大乱斗多两段:①点了失效/已满的房间 → 提示并自动刷新一次(列表常驻陈旧房间,点了必失败);
# ②已入房后房主/对端掉线被大厅取消配对 → 直接刷新恢复可操作。其余才是"原样显示"。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting and (t == "服务器断开" or t == "连接失败"):
		return   # 重启本机服期间,旧连接被杀的断连提示是预期噪音,不覆盖状态
	if t == "房间已满" or t == "房间不存在":
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


func _on_room_joined(role: int) -> void:
	# 注意:此处不清 _join_sent_ms——入房后到 go_match 之间若房主掉线、大厅关房,
	# 客户端会收不到 go_match 也没有任何后续;保留该兜底计时(超时自动刷新回大厅)。
	_status.text = "已加入,等待开战……"


# 转连 worker / 入房应答超时兜底:UDP 连不上不会立刻报失败,这里定时自动回大厅,
# 不让「点了幽灵房间」永久停在"正在连接对局服务器/等待配对"。
# ★ 本页的梯顺序是 [worker → join → 大厅 → claim],与基类注释里登记的一致;**别重排**。
func _process(_delta: float) -> void:
	# 1) 转连 worker 12s 无连接(死端口):不再只是提示,直接回大厅并刷新
	if _tick_worker_connect_timeout():
		return
	# 2) join_room 发出去 10s 服务端无任何应答(幽灵房间/丢包):自动刷新列表恢复可操作
	if not _connecting_worker and _claimed_ms == 0 and _join_sent_ms > 0 \
			and Time.get_ticks_msec() - _join_sent_ms > 10000:
		_join_sent_ms = 0
		_request_list("房间无响应(可能已失效)——已自动刷新列表,请重选")
		return
	_tick_lobby_connect_timeout()
	_tick_claim_timeout()


func _on_back_pressed() -> void:
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# ── 基类钩子(本页实现)────────────────────────────────────────────

# 空地址回退默认云大厅(写死 127.0.0.1 必失败且超时极慢)
func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


func _send_list_request() -> void:
	NetBus.rpc_id(1, "list_rooms")


# ①服务器权威规则项(回合回血 / 禁武器,以 role1 那份为准)②本端角色色相。
# 两者都**已生效**;完整链路见 _build_options_panel 顶部注释。
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
	}


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"


# 配对成功:停 join 兜底,转由转连 worker/claim 兜底接管
func _on_go_match_extra() -> void:
	_join_sent_ms = 0


# 对局 worker 连不上(幽灵房间/端口已死)→ 停本段等待,自动回大厅刷新
func _on_worker_connect_failed() -> void:
	if _connecting_worker:
		_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")


func _worker_timeout_msg() -> String:
	return "对局服务器无响应(房间可能已失效)——已返回大厅并刷新,请换一个房间"


# claim 后 25s 仍未 match_start:对方未就绪(房间失效/对端掉线/云服无降级开局)→
# 放弃本局并自动重连大厅,恢复列表/建房能力(原「连接对局服务器」永久卡死)
func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间"


func _on_return_to_lobby() -> void:
	_join_sent_ms = 0


# 重启本机服后「只自动刷新一次」的闸门要放开(否则下一次房间已满不会自动刷新)
func _on_local_server_ready() -> void:
	_auto_refreshed = false


# 换服务器重连:清掉旧列表(旧房间号在新服上必然「房间不存在」)
func _on_lobby_reconnect() -> void:
	_clear_room_list()


func _enter_match_scene() -> void:
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
