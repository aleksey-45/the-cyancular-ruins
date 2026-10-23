extends LobbyPage

# 统一联机大厅:1v1 / 大乱斗 / 3v3 三套协议在本页合并。顶栏(昵称/地址/启服) → 模式筛选 + 创建/加入 → 房卡网格 → 状态栏。
# ★ 一条纪律:三个模式在本页的差异全部收在 _mode / _current_mode 两个变量上(筛选值 / 创建弹层形态 / 等待室形态 / 转连方式);别再按"哪个页面"分叉。
# ★ ack 梯顺序 = worker → claim → 大厅 → ack(合并后唯一一条):1v1 旧页那条 join 梯的职责由末尾那条(建房/加入 8s 无应答)覆盖。三套服务端注册表原样保留:本页并发调三次现有列房 RPC,前端合并打标。
# ★★ 静态骨架在 scenes/mp_lobby.tscn 里:版式(页面留白 / 各行坐标 / 控件尺寸 / 间距 / 固定文案)一律去编辑器里拖,别回来加坐标常量。
# 本脚本只做三件事:按语义名接上骨架(_build_ui)、填动态部分(房卡行 / 名单行 / 禁用武器网格 / 地图选择器 / Beta 时间参数行)、按模式分叉(_apply_create_form 与 _show_wait_room 两处)。

# ★ 只有这三个版式常量留在代码里:房卡是运行时按载荷建的(_make_card),而它的宽必须与 .tscn 里 CardGrid 的 offset_left/right + h_separation 一致 —— 同一件事有两个来源,改一个就要改另一个,否则卡片与网格错位(而不报错)。
# ★ 其余版式常量(各行 / 各块的 y 与空档、按钮尺寸)已随迁移进 .tscn,代码里不再有副本。
const PAGE_MARGIN := 76.0
const CARD_COLUMNS := 4
const CARD_GAP := 24.0

var _mode := ""                    # 当前筛选:"" = 全部;否则 PvpSession.MODE_*
var _rooms_by_mode := {}           # mode -> Array(载荷条目,已打 "mode" 键)
var _grid: GridContainer = null
var _filter_btns := {}             # mode -> Button(含 "" = 全部)
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null

# 创建弹层:压暗罩与弹层本体是两个节点 —— 罩子铺满整页(拦下背后的点击),本体居中。
var _create_panel: PanelContainer = null
var _create_mask: ColorRect = null
# ★ 弹层里要按名取到的容器,键名固定:_build_ui 按这几个键登记、_apply_create_form 按这几个键取 —— 键名对不上不报错,只是那一行永远不隐藏。max_players / match_time / weapons / privacy 按模式显隐,map 三模式都可见,beta 由 PvpSession.beta_mode 在建面板那一刻定。
var _form_rows := {}
var _create_mode := PvpSession.MODE_PVP
var _create_mode_btns := {}   # mode -> Button(三颗分段按钮;`_apply_create_form` 用它置灰当前项)
var _public_check: CheckButton = null
var _invite_edit: LineEdit = null
var _max_slider: HSlider = null
var _time_slider: HSlider = null
var _weapon_checks: Array[CheckButton] = []   # 建房时读勾选态(与旧大乱斗页同款)

# 等待室:三个模式共用一个面板(每次 _show_wait_room 清空重填),而不是每个 handler 各建一份;名单行数 / 按钮显隐 / 颜色行显隐全部收在 _show_wait_room 一处 —— 那是本页按模式分叉的第二个(也是最后一个)落点。
var _wait_panel: PanelContainer = null
var _wait_title: Label = null             # 标题带里面那颗 Label(房间号写在它的 text 上)
var _wait_body: VBoxContainer = null      # 名单/分队容器:每次重填前整批清空
var _wait_count: Label = null
var _wait_hue: Control = null             # 角色颜色行(1v1/大乱斗可见;3v3 用队色 ⇒ 收起)
var _wait_start: Button = null
var _wait_pick_a: Button = null
var _wait_pick_b: Button = null
var _wait_leave: Button = null
# 面板当前画的是哪个模式 —— 「开始游戏」/「退出房间」按它分派。
# ★ 与 _current_mode 分开:后者是"我所在那间房"的模式(转连选场景用),这里是"面板上画的形态"。两者通常相等,但语义不同,别合并。
var _wait_mode := ""
# 我当前是否在某间房里(等待室亮着):_show_wait_room 置真、_hide_wait_room 置假、_lobby_action_allowed 读 —— 与面板可见性同一生命周期,分两处写状态就是漂的成因。
var _in_room := false
# ★★ 进等待室时要一并收起这两颗入口按钮:只加 _lobby_action_allowed() 不够 —— 「＋ 创建房间」是直接绑 _open_create_dialog 的,压根不问那道闸门,玩家照样能把创建弹层开在等待室上面
# (压暗罩建得更早 ⇒ 落在面板底下,观感上罩不住等待室)。收起这颗按钮才是真正解决层级问题的那一半;_toggle_join_panel 同理。
var _create_btn: Button = null
var _join_btn: Button = null

# 我当前所在那间房的模式(转连时按它选场景)。★★ 它与 PvpSession.room_mode 不是一回事:后者是凭据的模式(供列表里判"这一行是不是我的房"),
# 它在"建了房但 note_room 还没跑到"这一档上是空串 —— 拿它去分派 _enter_match_scene 会把 1v1 的对局静默切进 team_game.tscn(不报错)。别合并成一个字段。
var _current_mode := ""

var _ack := true
var _sent_ms := 0

var _got := {"pvp": false, "royale": false, "team": false}

# 刚发出的加入请求的房号(1v1 的 room_joined 载荷只有 role,拿不到房号,只能靠它暂存)。
# ★★ 漏了给它赋值 = 两条真缺陷:① _current_mode 停在空串 ⇒ _enter_match_scene() 落进 else ⇒ 1v1 的加入者被送进错场景;② note_room() 从不被调用 ⇒ 自己那间房永远是灰的。
var _join_pending := ""

# 「模式未知 ⇒ 三张表都问一次」这一次尝试还在飞。★ 三张表里只有一间存在,另两张必然回「房间不存在」/「房间已满」—— 那是预期噪音:既不显示、也不花掉那次自动刷新额度(_auto_refreshed)。
# ★★ 关闸只能靠 _multi_left 数应答条数,不能靠"任一正向应答就收尾":1v1 的 join_room 成功是立即回的,而 royale/team 是 call_deferred + await ⇒ 正向一到就关闸,
# 那两张表稍后到的 absent 会漏出去触发一次刷新 —— 后果不是"多一条提示",而是那一次性额度被花掉:之后第一张真陈旧卡片被拒时反而不会自动刷新了。
var _probe_multi_join := false
var _multi_left := 0               # 这一次尝试里还没被认领的应答数(起手 = 3 个请求)

var _auto_refreshed := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state_royale)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state_team)

	_finish_lobby_ready()

	# Beta 页预选的筛选模式(从主菜单直接进来时为 "")。★★ 它读的是 entry_mode 而不是 room_mode:后者是凭据的模式,混用会把一个凭据字段写成非凭据的值,而 can_rejoin_to() 正是拿 room_mode 判"这一行是不是我的房"。
	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)



# 把骨架接上代码:①按语义名取到脚本要用的节点 ②把控件的信号接上 ③把动态块建起来 ④三个弹层建完即隐藏。★★ 版式一律改 .tscn。
# ★ 本方法只做 UI:NetBus / NetBusExt 的 connect 与 _finish_lobby_ready() 留在 _ready 里 —— 树外实例化本页的夹具故意不入树(不入树 ⇒ _ready 不跑 ⇒ 不建 socket),别把接线并进来。零守卫:那两个 lobby_* 夹具探针已删(2026-10-09)。
# ★ 控件的信号在这里接(不挪进 _ready):"按钮画在屏上、按下去毫无反应"没有任何运行时信号可观测。★ 两处先灌值再 connect(别调换):button_pressed / value 赋值都会发信号,先连上就会在建树那一刻把值写回 Settings 并播一次音效。
func _build_ui() -> void:
	var name_le: LineEdit = %NameEdit
	name_le.text = PvpSession.player_name
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())
	_addr_edit = %AddrEdit
	_addr_edit.text = PvpSession.server_address
	%RefreshBtn.pressed.connect(_on_refresh_pressed)
	%LocalServerBtn.pressed.connect(_on_local_server_pressed)
	%LocalServerBtn.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"
	# 右上那条 IP 提示:右对齐靠锚点 + GROW_DIRECTION_BEGIN(已在骨架里定死 —— 写死宽度会让它向右长、被屏幕右缘裁掉);文案随本机 LAN IP 变,故每次建页重灌。
	_ip_label = %IpLabel
	_ip_label.text = LocalServer.lan_ip_hint()

	_filter_btns = {}
	for f in [["", %FilterAll], [PvpSession.MODE_PVP, %FilterPvp],
			[PvpSession.MODE_TEAM, %FilterTeam], [PvpSession.MODE_ROYALE, %FilterRoyale]]:
		var m: String = f[0]
		var b: Button = f[1]
		b.button_pressed = (m == _mode)
		b.pressed.connect(func() -> void: _set_filter(m))
		_filter_btns[m] = b
	_create_btn = %CreateBtn
	_create_btn.pressed.connect(_open_create_dialog)
	_join_btn = %JoinBtn
	_join_btn.pressed.connect(_toggle_join_panel)

	_grid = %CardGrid
	# ★ 状态栏文本是 _redraw_cards() 的输出,骨架里它是空的(清运行时字面量那一步把它清回了中性)⇒ 这里不需要、也不该再灌一个初值。
	_status = %StatusLabel
	%BackBtn.pressed.connect(_on_back_pressed)

	_join_panel = %JoinPanel
	_join_code_edit = %JoinCodeEdit
	_join_invite_edit = %JoinInviteEdit
	_join_panel.visible = false
	%JoinOkBtn.pressed.connect(func() -> void:
		_join_panel.visible = false
		_join_code(_join_code_edit.text.strip_edges(), _mode, _join_invite_edit.text))
	%JoinCancelBtn.pressed.connect(func() -> void: _join_panel.visible = false)

	# 创建弹层:压暗罩 + 面板 + 分层控件。★ 压暗罩铺满整页 + mouse_filter = STOP(拦下背后的点击 = 点弹层外不会误触房卡)在骨架里;它的颜色是调色板纪律的已知例外(全屏遮罩不属于 C_PLATE 那条「HUD 底板 0.1」家族,见 docs/eng/ui.md):Color(0,0,0,0.55) 与 ui/screens/match_result.gd 的 MASK_COLOR、暂停菜单逐字同值 —— 改一处就要一起改(值现在住在 .tscn 里)。
	_create_mask = %CreateMask
	_create_mask.visible = false
	_create_panel = %CreatePanel
	_create_panel.visible = false
	%CreateCloseBtn.pressed.connect(func() -> void: _set_create_visible(false))
	%CreateCancelBtn.pressed.connect(func() -> void: _set_create_visible(false))
	%CreateOkBtn.pressed.connect(_on_create_pressed)

	# 三颗模式分段按钮(ButtonGroup 互斥;模式色在骨架里)。★ 必须登记进 _create_mode_btns:_apply_create_form 靠它把当前项置灰。
	_create_mode_btns = {PvpSession.MODE_PVP: %CreateModePvp,
			PvpSession.MODE_TEAM: %CreateModeTeam, PvpSession.MODE_ROYALE: %CreateModeRoyale}
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		(_create_mode_btns[m] as Button).pressed.connect(func() -> void: _apply_create_form(m))

	_public_check = %PublicCheck
	_invite_edit = %InviteEdit
	_public_check.button_pressed = true
	_invite_edit.visible = false
	_public_check.toggled.connect(func(on: bool) -> void:
		_invite_edit.visible = not on)

	_max_slider = %MaxPlayersSlider
	_max_slider.value_changed.connect(func(v: float) -> void:
		(%MaxPlayersLabel as Label).text = "%d 人" % int(v))

	# 一局限时(分钟;仅大乱斗可见)。★ 上界 15 是 ROYALE_MATCH_TIME_CEILING 那条上界链的第三环(Settings.royale_match_min 的写入端),别在这里改数值(见 docs/eng/modes.md);值从 Settings 灌。
	_time_slider = %MatchTimeSlider
	_time_slider.value = Settings.royale_match_min
	(%MatchTimeLabel as Label).text = "%d 分钟" % int(Settings.royale_match_min)
	_time_slider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		(%MatchTimeLabel as Label).text = "%d 分钟" % int(v))

	# 「每回合开始回满血」房主选项(仅 1v1 可见)。★★ 它必须留在创建弹层里:Settings.pvp_round_full_heal 的写入方只有这一颗勾选框,而它仍被 _player_options() 读取并上报 —— 移走就等于玩家再也打不开它。
	# ★ 它是房主 / 服务器规则(大乱斗恒 false、3v3 压根不发),故归属创建弹层。
	%FullHealCheck.button_pressed = Settings.pvp_round_full_heal
	%FullHealCheck.toggled.connect(func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save())

	_form_rows = {
		"privacy": %PrivacyRow, "max_players": %MaxPlayersRow, "match_time": %MatchTimeRow,
		"full_heal": %FullHealRow, "weapons": %WeaponsBlock, "map": %MapBlock,
		"beta": %BetaBlock,
	}

	# 「禁用武器」网格:行 = WeaponRegistry(每台武器一颗勾选框),故留代码。★ 回调把 cb 与 type_id 都收进 _weapon_checks —— 少收 type_id 那半,_checked_weapons() 会永远返回 [0] 且不报错。
	_add_weapon_grid(%WeaponsBlock, 20, func(cell: Node, type_id: int) -> void:
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("type_id", type_id)
		_weapon_checks.append(cb))

	# 地图选择器(基类 _add_map_picker 写 Settings.mp_map_path):整块在代码里建 —— 缩略图是 MapCatalog 现烘的,放进骨架只会是一份死重量(且运行时会变成两个选择器)。
	_add_map_picker(%MapBlock)

	%BetaBlock.visible = PvpSession.beta_mode
	_add_time_params(%BetaBlock)

	_wait_panel = %WaitPanel
	_wait_panel.visible = false
	_wait_title = %WaitTitle
	_wait_body = %WaitBody
	_wait_count = %WaitCount
	_wait_hue = %WaitHueRow
	_wait_pick_a = %WaitPickABtn
	_wait_pick_b = %WaitPickBBtn
	_wait_start = %WaitStartBtn
	_wait_leave = %WaitLeaveBtn
	# ★ 选边按钮用 bind(队号) 而不是两条匿名 lambda:绑定实参能被 Callable.get_bound_arguments() 读出来 —— 两颗按钮的文案只差一个 A/B 字,对调之后行为是错的且没有任何运行时信号。
	# 零守卫:读绑实参的那条断言随 lobby_* 探针一起删了(2026-10-09)。
	_wait_pick_a.pressed.connect(_on_wait_pick.bind(1))
	_wait_pick_b.pressed.connect(_on_wait_pick.bind(2))
	_wait_start.pressed.connect(_on_wait_start_pressed)
	_wait_leave.pressed.connect(_on_wait_leave_pressed)

	# 角色颜色行(仅 1v1 / 大乱斗可见;3v3 用队色 ⇒ _show_wait_room 整行收起)。★ 它住等待室而不是创建弹层:创建弹层一进等待室就收起,放那儿等于房主建完房改不了、加入者全程没见过。
	# ★★ 行本身是静态骨架(标签 + 滑条 + 预览色块),这里只灌值 + 接写回 —— 与设置页那两个音量滑条同款(值由脚本灌、信号由脚本接)。
	var hue_slider: HSlider = %WaitHueSlider
	var hue_chip: ColorRect = %WaitHueChip
	hue_slider.value = Settings.pvp_color_hue
	hue_chip.color = UiFactory.hue_preview_color(Settings.pvp_color_hue)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		hue_chip.color = UiFactory.hue_preview_color(v))


func _on_back_pressed() -> void:
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# 手动刷新 = 用户明确要重来 ⇒ 放开「只自动刷新一次」的闸门(否则下一次「房间已满」不会自动刷新)。
func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")


func _on_local_server_ready() -> void:
	_auto_refreshed = false



# 切筛选模式。★ 三颗分段按钮的选中态与 _mode 是同一件事的两半,收在这里刷新 —— 在按钮 handler 里各写一遍的话,"程序改了 _mode"这条路就漏了。
func _set_filter(mode: String) -> void:
	_mode = mode
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)
	_redraw_cards()



# 三个载荷入口各自把条目并入同一张表,再统一重绘。★ 每条都打上 mode 标 —— 卡片要显示模式、筛选器也按它过滤,而服务端载荷里没有这个键。
func _ingest_rooms(mode: String, rooms: Array) -> void:
	var tagged: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (r as Dictionary).duplicate()
		d["mode"] = mode
		tagged.append(d)
	_rooms_by_mode[mode] = tagged
	_got[mode] = true
	# ★ 不无条件清 _ack / _sent_ms:它们是加入的 8s 兜底,而一次列房应答并不能证明那次加入有应答 —— 无条件下会刚好在"加入请求丢了、用户又点了一次刷新"时把兜底拆掉;只有"没有待应答的加入"时清才安全。
	if _join_pending.is_empty():
		_ack = true
		_sent_ms = 0
	if _got.values().all(func(v: bool) -> bool: return v):
		_redraw_cards()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	# Beta 房与普通房互不可见(客户端侧;服务器侧 join 守卫是第二道)。
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


# 重绘整张网格。★★ 必须先 remove_child 再 queue_free:只 queue_free 的话旧节点要到帧末才没,同帧再建一次就会在网格里留下两批卡叠着(它们都还是 _grid 的子节点,get_children() 数得出来)。
# 生产里三条 RPC 应答确实可能落在同一帧(_ingest_rooms 每收到一条就可能触发一次重绘)。本仓在"热重建视觉"那处踩过同款(WeaponPickup.configure)。
func _redraw_cards() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		# 未满优先、满房排最后 —— 在每个模式内部排。★★ sort_custom 的比较函数返回 true = a 排在 b 前面(不是"a 该往后挪"):要"未满的在前",就必须在 a 未满而 b 满时返回 true。
		# 写反(a 满时返回 true)= 满房排到了前面,与状态栏文案相反;而断言全按 meta 找卡、对顺序不敏感 ⇒ 零守卫(顺序断言随 lobby_* 探针已删·2026-10-09)。1v1 载荷没有 max_players ⇒ 默认 2,与卡片那处同一个默认值。
		var rows: Array = _rooms_by_mode.get(mode, []).duplicate()
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_full := int(a.get("players", 0)) >= int(a.get("max_players", 2))
			var b_full := int(b.get("players", 0)) >= int(b.get("max_players", 2))
			return not a_full and b_full)
		for r in rows:
			total += 1
			if _mode != "" and mode != _mode:
				continue
			_grid.add_child(_make_card(r))
			shown += 1
	if shown == 0:
		var empty := UiFactory.label("暂无房间 —— 点「＋ 创建房间」开一局吧", 32, UiFactory.C_TEXT_DIM)
		_grid.add_child(empty)
	_status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]



# 模式色(与对局无关的一套,只在菜单系用)。★ 3v3 刻意不用蓝 —— #639BFF 就是 UiFactory.C_TEAM_A(队 1 的队色),而队色在 3v3 里是有玩法语义的颜色("一眼看出谁是队友"),撞色会让大厅的「3v3」与对局的「队 1」混淆。
# ★★ 模式色定义在 ui/factory/ui_factory.gd(调色板单一来源是硬约束:颜色只在那里定义,不要再写 Color(...) 字面量)。这里只引用不写字面量,否则同一套颜色会被定义两遍、静默漂移。
const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "3 v 3",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}


# 一张房卡 = 一颗 Button(卡本体就是可点区域)。★ 不用 PanelContainer + 覆盖层:那样"点不动"的判据会散在覆盖层的连接数上,而 disabled / focus_mode / pressed 三个原生属性都在 Button 上,判据落在同一个节点上。
# ★ 子节点一律 mouse_filter = IGNORE:内容画在 Button 之上,但点击必须落到卡本体,否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	_style_card(btn)
	btn.custom_minimum_size = Vector2(_card_width(), 440)
	btn.size = Vector2(_card_width(), 440)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""   # 内容全部自绘

	# ★ 卡底:外层 C_BORDER 线由 Button 自己的 stylebox 画,内层 C_INNER 线由这块内缩 1px 的透明底 PanelContainer 画(与 UiFactory.menu_panel() 同一个形状)。外壳必须仍是 Button(卡的 text 恒空 + meta("code") 是找卡的据点),所以不能真的把卡换成 PanelContainer;零守卫:读 meta("code") 的探针已删(2026-10-09)。
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 1.0
	frame.offset_top = 1.0
	frame.offset_right = -1.0
	frame.offset_bottom = -1.0
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)   # 只画线、不画底(底在外层 Button 上)
	fsb.border_color = UiFactory.C_INNER
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(0)
	fsb.content_margin_left = 26.0
	fsb.content_margin_right = 26.0
	fsb.content_margin_top = 20.0
	fsb.content_margin_bottom = 20.0
	frame.add_theme_stylebox_override("panel", fsb)
	btn.add_child(frame)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 12)
	frame.add_child(col)

	col.add_child(_card_header(mode, r))
	col.add_child(_card_body(r))

	# ★★ 次序是承重的:先问「这是我的房吗 + 凭据还在吗」(can_rejoin_to 已在上面算好),这一档可点(点了走回局);不是我的房,才轮到「对局中 ⇒ 禁用」那一档。
	# 反过来写 = 回局这一档连点都点不到,而一行报错都没有。
	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)   # 整体压暗:一眼看出这间进不去
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			# ★★ 回局那条路也要记下模式 —— 与"加入"那条同款。ESC 回主菜单 → 多人模式(新页,_current_mode == "")→ 点自己那间对局中的房 → try_rejoin_row → go_match → match_start → _enter_match_scene() 落进 else ⇒ 回局也会进错场景。
			# 没有这一行,_enter_match_scene 的 else(push_error)就是唯一能把它喊出来的地方。
			_current_mode = mode
			if not try_rejoin_row(code, in_match, mode):
				_join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


# 卡头 = 一条标题带(方向 B):C_HEADER 底 + 只有下边一条 C_BORDER 线;左 = 模式名(模式色),右 = 状态角标。★ 与 UiFactory.header_strip() 同一个味道,但工厂版标题色固定为金、也不带右侧角标,故按同一套版式拼一条。
# ★ 角标三档次序:对局中 优先于 私密 · 我的 —— 一间对局中的私密房对别人根本不列出,能同时满足两条的只有"我的房且已开局",那时"对局中"是更有用的信息。
func _card_header(mode: String, r: Dictionary) -> Control:
	var strip := PanelContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = UiFactory.C_BORDER
	# 与 UiFactory.header_strip 同一轮放大(12/6 → 20/12)。★ 这里是第二份字面量(工厂那条标题带不带右侧角标,故没走工厂)—— 两边要同步手改。
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	strip.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	strip.add_child(row)

	var name_l := UiFactory.label(str(MODE_LABEL[mode]), 32, MODE_COLOR[mode])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)

	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var badge := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	# ★ 三档取色刻意避开 C_WARN —— 它在调色板里被钉死为「弹夹见底」单一语义(ui_factory.gd 明写只用于「低弹量/耗尽」);拿它表"私密"会让那个金色在大厅与 HUD 里指两件事。
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	var badge_l := UiFactory.label(badge, 16, badge_col)
	badge_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(badge_l)
	return strip


# 房卡底(方向 B 的凿刻感):外层一条 C_BORDER(常态)/ C_ACCENT(悬停/焦点),填充走 C_SURFACE;内层那条 C_INNER 线由子节点那块 frame 画。
func _style_card(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _card_box(UiFactory.C_BORDER))
	b.add_theme_stylebox_override("hover", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("pressed", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("focus", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("disabled", _card_box(UiFactory.C_BORDER))


func _card_box(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_SURFACE
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	return sb


func _card_body(r: Dictionary) -> Control:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)

	box.add_child(UiFactory.label(str(r.get("code", "")), 48, UiFactory.C_TEXT))
	box.add_child(UiFactory.label(_card_subtitle(mode, r), 32, UiFactory.C_TEXT_DIM))

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_theme_constant_override("separation", 20)
	mid.add_child(_card_map_thumb(mode, str(r.get("map", ""))))
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 1v1 的载荷没有 max_players(1v1 恒 2 人)—— 前端补,而不是去动那三个载荷的形状。
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("players", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


# 地图缩略图。★ 复用 MapCatalog 那套(选图面板已经在用它现画):不要另写一份画法 —— 两份必然漂,而漂了不报错,只是两张图长得不一样。map 为空时退化成模式色占位,而不是留一个空洞。
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture = MapCatalog.texture(map_path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.add_child(tex)
	else:
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = MODE_COLOR[mode]
		fill.color.a = 0.25
		frame.add_child(fill)
	return frame


# ★ 名字走 UiFactory.fit_name(名字, 14) 定宽截断(与结算页同款)—— 不截的话长昵称会把卡顶宽(卡宽是 4 列网格算出来的固定值,顶宽 = 整行错位);名单最多 3 行,超出显示 …等 N 人。
func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				16, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 16, UiFactory.C_TEXT_DIM))
	return box



# 基类钩子:不是一条统一 RPC —— 三条并发、各自到达,合并后重绘(刷新延迟由最慢那份决定);token 仍要带,大厅据此把持凭据本人自己那间私密房也列出来。
func _send_list_request() -> void:
	_got = {"pvp": false, "royale": false, "team": false}
	_rooms_by_mode.clear()
	NetBus.rpc_id(1, "list_rooms")
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
	NetBusExt.rpc_id(1, "team_list", PvpSession.token)



func _on_room_created(code: String) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(code, _current_mode)
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图:1v1 的 create_room 签名冻结,塞不进 payload。★ 这里无条件下发 —— 走到本 handler 的就是建房者,也就是房主。
	NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code
	_show_wait_room(_pvp_wait_state(code, 1), PvpSession.MODE_PVP)


# 服务端答"加进去了"。★ 房号从 _join_pending 取(room_joined 载荷只有 role)—— 这里同时是唯一记 1v1 加入房号的地方:
# 失败的加入不得留下 room_code,否则 can_rejoin_to(我自己的房) 恒 false,自己那间房永远是灰的。
func _on_room_joined(role: int) -> void:
	# ★★ 模式直接定死,不从别处推 —— 触发的是这条 handler,就只可能是 1v1。
	_current_mode = PvpSession.MODE_PVP
	var code := _join_pending
	if not _join_pending.is_empty():
		PvpSession.note_room(_join_pending, _current_mode)
		_join_pending = ""
	_ack = true
	_sent_ms = 0
	# ★ 只是认领一格,不是"多表尝试到此为止" —— 另两张表的 absent 还在路上(join_room 立即回,royale/team 是 call_deferred + await)。
	_claim_multi_reply()
	_status.text = "已加入,等待开战……"
	if not code.is_empty():
		_show_wait_room(_pvp_wait_state(code, role), PvpSession.MODE_PVP)


func _on_room_state_royale(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_ROYALE
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图。★ 只有房主该发 —— 非房主发会被服务端静默拒(不报错,所以必须自己判,否则每个加入者都会白发一次)。
	# ★ 判据用服务器下发的 host_role / your_role 两条(它们按 peer 单独下发,不是按昵称反查 —— 两人同名时会命中先出现的那个,本仓踩过)。
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "已进入大乱斗房间 %s,等待开局…" % code
	_show_wait_room(state, PvpSession.MODE_ROYALE)


func _on_room_state_team(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_TEAM
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "已进入 3v3 房间 %s,等待选边/开局…" % code
	_show_wait_room(state, PvpSession.MODE_TEAM)


# 大厅文本播报。★★ 收到任何一句服务端文案,就证明"它回了" ⇒ 一律解除 8 秒兜底(_ack / _sent_ms);兜底的语义是「服务器一个字都没回」—— 枚举白名单是替一个不需要枚举的东西枚举,漏一条就会让 8 秒后 _process 把真拒绝覆盖成「地址不通/服务器不是最新版」。
# ★ 「模式未知的三连发」里的拒绝是预期噪音(三张表只有一间存在):吞掉、不显示也不刷新(刷新额度是一次性的)。非多表时「房间已满 / 房间不存在」仍走旧 1v1 的行为:提示并自动刷新一次(闸门由 _auto_refreshed 把着)。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_ack = true
	_sent_ms = 0
	if _swallow_absent(t):
		_claim_multi_reply()
		# ★★ 闸门在这一条上关掉、而三张表一张都没接受(_join_pending 没被任何 success handler 清过)⇒ 这一次加入是失败,必须显式收尾(见 _settle_multi_fail):少了这一支,手敲房号写错 / 房间已满时三条应答全被吞、8s 兜底又被上面两行解除,状态栏就永远停在「加入房间 X,等待配对…」而一行报错都没有。
		if not _probe_multi_join and not _join_pending.is_empty():
			_settle_multi_fail(t)
		return
	if t == "房间已满" or t == "房间不存在":
		# 服务端已明确应答 ⇒ 那间房与我无关,别留给下一次的成功信号。
		_join_pending = ""
		if not _auto_refreshed:
			# ★ 推迟到帧末:server_message 在大厅 peer 的 poll 调用栈内到达,栈内立刻 NetBus.stop()(重连)会把正在 poll 的 peer 提前 free → 原生段错误。
			_auto_refreshed = true
			_request_list.call_deferred("%s → 已自动刷新列表" % t)
		else:
			_status.text = t
	elif t.begins_with("配对已取消"):
		_join_pending = ""
		_request_list.call_deferred("配对已取消(对手离开)——已刷新列表,请重选")
	else:
		_status.text = t


# 「模式未知的三连发」回来的应答是不是预期噪音?(三张表只有一间存在。)★ 调用方吞掉它之后还要认领一格(_claim_multi_reply)—— 顺序不能反:认领可能当场关掉闸门,那时这一句就不该再被吞。
func _swallow_absent(t: String) -> bool:
	return _probe_multi_join and (t == "房间不存在" or t == "房间已满")


# 「模式未知的三连发」一张表都没接受时的收尾。★ 与 _on_server_message 非多表那一支同款同闸门(_auto_refreshed 一次性);三张表的 absent 是预期噪音,只有"全拒"这一档才升级成真失败。★ 只在 _claim_multi_reply 把闸门收到 0、且没有任何一张表接受时被调。
func _settle_multi_fail(t: String) -> void:
	_join_pending = ""
	if not _auto_refreshed:
		_auto_refreshed = true
		_request_list.call_deferred("%s → 已自动刷新列表" % t)
	else:
		_status.text = t


# 多表尝试期间:每收到一条服务端应答就认领一格,认领完即关闸。★★ 闸门由应答条数关,不由"任一正向应答"关 —— 1v1 的 join_room 成功是立即回的,而 royale/team 是 call_deferred + await,
# 正向一到就关闸,那两张表稍后到的 absent 会漏出去、误触发一次自动刷新(一次性额度被噪音花掉)。★ 另两条关闸路径:8s 一个字都没回(见 _process)、以及下一次加入开始时重设。
func _claim_multi_reply() -> void:
	if not _probe_multi_join:
		return
	_multi_left -= 1
	if _multi_left <= 0:
		_probe_multi_join = false



func _toggle_join_panel() -> void:
	_join_panel.visible = not _join_panel.visible


# 加入某房间号。★ 模式未知(从"全部"列表点的、或手敲房号)时,三张表都试一次:三张里只有一间存在,另外那两张表的「房间不存在 / 房间已满」是预期噪音 ——
# 由 _on_server_message 经 _swallow_absent 吞掉(不显示、也不花掉自动刷新额度),每吞一条认领一格(_claim_multi_reply),认领满三格才关闸;★ 1v1 那条成功应答不会提前关闸。
# ★ invite 是可选第三参:私密房不在列表里,邀请码是加入它的唯一途径;卡片按下那条路只传前两参(它本来就不该带邀请码)。
func _join_code(code: String, mode: String, invite: String = "") -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		# ★★ 三件事一件都不能少,否则 1v1 的加入者会被送进错场景(见字段声明处那段):① 暂存房号(1v1 的 room_joined 载荷只有 role,拿不到房号);
		# ② 模式未知时三张表都问一次;③ invite 必须真的传下去(私密房的唯一途径)。
		_join_pending = code
		# ★★ 模式已知 ⇒ 在发起加入这一刻就把 _current_mode 置上。卡片点击那条路总是知道模式,本来就该在此记;而 mode == ""(在"全部"筛选下手敲房号)时不设 —— 那种情况本来就要等应答才知道是哪张表。
		# ★ 为什么不能只靠 _on_room_state_*:等待室广播是 call_deferred + 再等一帧,且发送前 if rr.in_match: return ⇒ 房主若在"有人加入"的同一两帧内开局,那次广播会被静默吞掉,响应式的 handler 永远不会来
		# ⇒ _current_mode 恒空 ⇒ _enter_match_scene 落进 else(push_error、不切场景)⇒ 加入者卡在大厅。★ 加入失败时它留着旧值无害:_enter_match_scene 只在 match_start 到达时才跑。
		if mode != "":
			_current_mode = mode
		_probe_multi_join = mode == ""
		_multi_left = 3 if _probe_multi_join else 0
		_status.text = "加入房间 %s,等待配对…" % code
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_PVP:
			NetBus.rpc_id(1, "join_room", code)
		else:
			NetBus.rpc_id(1, "join_room", code)
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode))


# 创建房间弹层:按模式变形(差异全收在 _apply_create_form)。房主选项从"常驻右栏"搬进弹层 —— 列表要占满整页,常驻右栏会把 4 列房卡挤成 3 列。★ 弹层本体 / 压暗罩 / 标题行 / 双列版式 / 左列五行与右列两条区块标题都在 .tscn 里;_build_ui 只负责登记 _form_rows、接信号,并建出动态的三块(禁用武器网格 / 地图选择器 / Beta 时间参数行)。

# 点「＋ 创建房间」只显示弹层。★ 每次打开都重刷模式相关行显隐(_apply_create_form),不挪进 _ready —— 面板建好之后玩家仍可能改筛选模式,那时这条链必须再跑一次。
func _open_create_dialog() -> void:
	_create_mode = _mode if _mode != "" else PvpSession.MODE_PVP
	_apply_create_form(_create_mode)
	_set_create_visible(true)


# 弹层与压暗罩一起显隐(罩子单独隐藏会留下一层吃掉点击的全屏黑)。★ 两个节点都启动即建(骨架里就有)⇒ 这里没有 null 可判。
func _set_create_visible(v: bool) -> void:
	_create_panel.visible = v
	_create_mask.visible = v
# 禁用武器网格的勾选结果 → type_id 数组。★ 与 LobbyPage._add_weapon_grid 的 on_cell 回调配对:那个回调负责把 cb 与 type_id 一起收进 _weapon_checks(见 _build_ui)。
func _checked_weapons() -> Array:
	var out: Array = []
	for cb in _weapon_checks:
		if cb.button_pressed:
			out.append(int(cb.get_meta("type_id", 0)))
	return out


# 按模式变形 —— 本弹层唯一的分支。★ 3v3 关掉禁用武器不只是"规则里没有":那两个勾选框写的是 Settings.pvp_disabled_weapons,在 3v3 页勾一下会连带改掉另两个模式(功能缺陷,不是审美)。
# ★★ 置灰要迭代 _create_mode_btns 的值:for m in dict 拿的是键(String)—— 写成 for b in _create_mode_btns 会在每个键上取到 null,当场报错、函数在置灰那一行断掉。
func _apply_create_form(mode: String) -> void:
	_create_mode = mode
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	_form_rows["max_players"].visible = is_royale
	_form_rows["match_time"].visible = is_royale
	_form_rows["full_heal"].visible = is_pvp
	_form_rows["weapons"].visible = not is_team
	# ★ 1v1 下那一行是骗人的控件:create_room(caller) 是原版 NetBus 的冻结签名、收不了 opts ⇒ 服务端永远建公开房(1v1 载荷里 is_public 恒 true)。
	# 让玩家取消勾选"公开"、填了邀请码,建出来仍是人人可见、无需码就能进的房 —— 比不给这个选项更坏。
	_form_rows["privacy"].visible = not is_pvp
	for m in _create_mode_btns:
		(_create_mode_btns[m] as Button).disabled = false
	(_create_mode_btns[mode] as Button).disabled = true   # 当前模式置灰(与等待室的选边同款)


# 按模式给三套 payload 的公共部分 + 各自的私有键。★ map 三个模式都上发:1v1 的 create_room 签名冻结、塞不进 payload,故地图一律走 room_map 那条独立的 RPC(建房成功后由本端补发);3v3 不带 disabled_weapons,那一项从 player_options 走,与建房载荷无关。
func _create_payload(mode: String) -> Dictionary:
	var d := {
		"is_public": _public_check.button_pressed,
		"invite_code": _invite_edit.text.strip_edges(),
		"map": Settings.mp_map_path,
	}
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = int(_max_slider.value)
		d["match_time"] = int(_time_slider.value) * 60
		d["round_full_heal"] = false
		d["disabled_weapons"] = _checked_weapons()
	elif mode == PvpSession.MODE_PVP:
		d["disabled_weapons"] = _checked_weapons()
	return d


# 建房:按模式分派 RPC。1v1 的 create_room 是原版 NetBus 的 RPC、签名冻结(不带 payload),它的 map / disabled_weapons 都从 player_options 走。
func _on_create_pressed() -> void:
	# ★ 按下即收起弹层(不等应答 —— _with_lobby 的行动可能是异步的:没连上时它会先建连接、连上后才跑 action)。结果一律走状态栏(成功 = 房间号;失败 = 服务端那句文案),玩家要改选项再按「＋ 创建房间」重开即可。
	_set_create_visible(false)
	var mode := _create_mode
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		var payload := _create_payload(mode)
		payload.merge(_beta_payload())   # Beta 态追加 {"beta":true,"time":{…}};普通态空合入
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_create", payload)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_create", payload)
		else:
			NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间号后可叫对方刷新列表点进来)")


# ESC 关弹层。★ 弹层不可见时一律不处理 —— 大厅页自己的返回语义(回主菜单)不能被这里抢掉;只有弹层挡着页面时才吞掉这一次 ESC。★ _create_panel 启动即建(骨架里就有)⇒ 没有 null 可判。
func _unhandled_input(ev: InputEvent) -> void:
	if not _create_panel.visible:
		return
	if ev.is_action_pressed("ui_cancel"):
		_set_create_visible(false)
		get_viewport().set_input_as_handled()


# 等待室:三个模式共用一个面板(骨架里那一个,启动即建、默认隐藏),每次 _show_wait_room 清空重填。1v1:等待对手… 1 / 2(两人凑齐自动开局 ⇒ 没有「开始游戏」);
# 大乱斗:名单 + N / M 人 + 房主「开始游戏」;3v3:A 队 / B 队 / 未选边三档 + 两颗选边(自己那支置灰)+ 房主「开始游戏」(两队各满);共同尾巴:角色颜色行(仅 1v1 / 大乱斗)+「退出房间」。
# ★★ _show_wait_room 有四个调用点(1v1 建房 / 1v1 加入 / 两个 room_state);_hide_wait_room() 的唯一调用点是 _on_return_to_lobby()(转连与 claim 超时梯、回局失败、「退出房间」全汇到它)。漏了它 = 退回大厅后等待室还盖在屏上,而且一行报错都没有。★ 版式在 .tscn 里。


# 亮起 / 重填等待室。★ 清空重填而不是就地改几行:名单人数、分队、按钮显隐在三个模式下都不同,就地改必然漏一处 —— 而漏了不报错,只是上一个模式的行留在屏上(叠成两批名单)。
func _show_wait_room(state: Dictionary, mode: String) -> void:
	_wait_mode = mode
	_set_create_visible(false)
	_wait_panel.visible = true
	# 进房 = 收起两颗入口按钮 + 关掉可能开着的加入弹层(见 _create_btn 上方那段:闸门拦不住直接绑定的弹层,层级会翻过来)。与 _hide_wait_room 成对;三颗都启动即建(骨架 / _build_ui 登记)⇒ 没有 null 可判。
	_in_room = true
	_create_btn.visible = false
	_join_btn.visible = false
	_join_panel.visible = false
	_wait_title.text = _wait_title_text(state, mode)

	# ★ 必须 remove_child 再 queue_free:只 queue_free 的话旧行要到帧末才没,同帧重填会两批名单叠着(与 _redraw_cards 同款纪律)。
	for c in _wait_body.get_children():
		_wait_body.remove_child(c)
		c.queue_free()

	var my_role := int(state.get("your_role", 0))
	var host_role := int(state.get("host_role", 0))
	var is_host := host_role == my_role
	var plist: Array = state.get("players", [])
	var is_pvp := mode == PvpSession.MODE_PVP
	var is_team := mode == PvpSession.MODE_TEAM

	if is_pvp:
		_wait_count.text = "等待对手… 1 / 2"
	elif mode == PvpSession.MODE_ROYALE:
		_fill_flat_roster(plist, my_role, host_role)
		_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [
				plist.size(), int(state.get("max_players", 4))]
	else:
		_fill_team_roster(state, plist, my_role, host_role)
		_wait_count.text = _team_count_text(state, plist)

	# 角色颜色行:3v3 用队色、个人色相在本模式是无效输入 ⇒ 整行收起。
	_wait_hue.visible = not is_team
	# 选边按钮(仅 3v3)。★ 自己那支的按钮置灰:既少一次无意义的上行,也让「已在该队时再点该队」那条幂等 wart(服务器回"该队已满"、状态不变)不可达。
	var my_team := _team_of_role(state, my_role) if is_team else 0
	_wait_pick_a.visible = is_team and my_team != 1
	_wait_pick_b.visible = is_team and my_team != 2
	# 「开始游戏」:1v1 没有这颗按钮(两人凑齐自动开局);3v3 还要求两队各满。
	if is_pvp:
		_wait_start.visible = false
	elif mode == PvpSession.MODE_ROYALE:
		_wait_start.visible = is_host
	else:
		_wait_start.visible = is_host and _both_teams_full(
				state, int(state.get("team_size", LobbyRooms.TEAM_SIZE)))


# 收起等待室。★ 唯一调用点是 _on_return_to_lobby()。不恢复创建弹层 —— 玩家要建房会自己再点「＋ 创建房间」。★★ 两颗入口按钮在这里恢复,与 _show_wait_room 的收起成对。
# ★ 顺序要求:大乱斗 / 3v3 的「退出房间」是 rpc_id 之后紧接一句 _request_list.call_deferred(...) —— 本函数(经 _on_return_to_lobby)必须排在那句之前跑完;排反了,那次刷新会被自己的闸门拒掉 ⇒ 列表永远不更新且不报错。
func _hide_wait_room() -> void:
	_wait_panel.visible = false
	_in_room = false
	_create_btn.visible = true
	_join_btn.visible = true


func _on_wait_pick(team: int) -> void:
	NetBusExt.rpc_id(1, "team_pick", team)


func _on_wait_start_pressed() -> void:
	_status.text = "开局中…"
	if _wait_mode == PvpSession.MODE_ROYALE:
		NetBusExt.rpc_id(1, "royale_start")
	elif _wait_mode == PvpSession.MODE_TEAM:
		NetBusExt.rpc_id(1, "team_start")


# 「退出房间」。★ 三个模式不同款(照两个旧页逐字对齐):1v1 没有 leave RPC —— 断开即触发大厅 on_peer_left 清房,基类 _return_to_lobby 正好是那条收口(NetBus.stop() + 重连 + 刷新列表)。
# ★ 大乱斗 / 3v3 有 leave RPC,且不能断大厅 peer:断开会走 on_peer_left 那条另一条路径去关房,同一件事就有两个实现 ⇒ 只发 leave,然后走共用的页面清理(_on_return_to_lobby)+ 重拉列表 —— 不重连,大厅 peer 还在。
func _on_wait_leave_pressed() -> void:
	if _wait_mode == PvpSession.MODE_ROYALE:
		NetBusExt.rpc_id(1, "royale_leave")
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	elif _wait_mode == PvpSession.MODE_TEAM:
		NetBusExt.rpc_id(1, "team_leave")
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	else:
		_return_to_lobby("已退出房间")


# 标题:—— {模式名}房间 {code} ——。★ 邀请码只在私密时印:公开房的载荷里 invite_code 可能是空串、也可能带着房主随手填的值 —— 印出来会让玩家以为"这房要码"。
func _wait_title_text(state: Dictionary, mode: String) -> String:
	var code := str(state.get("code", ""))
	var invite := ""
	if not bool(state.get("is_public", true)):
		invite = "  邀请码 %s" % str(state.get("invite_code", ""))
	return "—— %s房间 %s ——%s" % [str(MODE_LABEL.get(mode, mode)), code, invite]


func _fill_flat_roster(plist: Array, my_role: int, host_role: int) -> void:
	var shown := 0
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		shown += 1
		_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


# 名单行(3v3:两队 + 未选边三档)。★ 两队标题恒出(哪怕 0 人):"这局有 A、B 两队"是规则、不是当前人数;缺了空队的标题,新来的玩家看不出该往哪边站。
func _fill_team_roster(state: Dictionary, plist: Array, my_role: int, host_role: int) -> void:
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0   # 未知队号归"未选边"(客户端侧口径,与服务端"先拦后分"同向)
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", LobbyRooms.TEAM_SIZE))
	var shown := 0
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		_wait_body.add_child(UiFactory.label("—— %s(%d/%d) ——" % [
				tag, (buckets[t] as Array).size(), team_size], 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			shown += 1
			_wait_body.add_child(_roster_row(shown, p, my_role, host_role))
	if not (buckets[0] as Array).is_empty():
		_wait_body.add_child(UiFactory.label("—— 未选边 ——", 32, UiFactory.C_TEXT_DIM))
		for p in buckets[0]:
			shown += 1
			_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


# 一行名单。★ 编号印行序(n)而不是 role —— role 是「最小空闲号」分配、有人退出后不重排,印 role 会出现 1、3(两个旧页都在这里踩过)。
# ★★ set_meta("roster_row", true) 本是探针数名单行的唯一据点 —— 零守卫:那个探针已删(2026-10-09),今天没有读者;标题 / 人数行 / 分队标题全是 Label,靠遍历猜极易假绿。
func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role := int(p.get("role", 0))
	var l := UiFactory.label("%d. %s%s%s" % [n, str(p.get("name", "玩家")),
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	l.set_meta("roster_row", true)
	return l


# 我在这个房间里在哪一队。★ 判据来自服务器按 peer 单独下发的 your_role:按昵称在名单里反查时,两人同名会命中先出现的那个 → 高亮错行、_host 判错 → 真房主看不到开局按钮。
func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


# 两队各满(= 3v3 的开局闸门,与 LobbyRooms.team_ready 同义)。★ 分母引 team_size 而不是写 "3":容量只有一个真值来源,写死的话 TEAM_SIZE 一改这行就撒谎且不报错。
func _both_teams_full(state: Dictionary, size: int) -> bool:
	var counts := {1: 0, 2: 0}
	for p in state.get("players", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if counts.has(t):
			counts[t] += 1
	return counts[1] == size and counts[2] == size


func _team_count_text(state: Dictionary, plist: Array) -> String:
	var picked := 0
	for p in plist:
		if typeof(p) == TYPE_DICTIONARY and int(p.get("team", 0)) != 0:
			picked += 1
	return "%d / %d 人(已选边 %d 人;两队各 %d 人才可开局)" % [
			plist.size(), LobbyRooms.TEAM_ROLES, picked,
			int(state.get("team_size", LobbyRooms.TEAM_SIZE))]


# 1v1 的等待室载荷:1v1 没有 room_state 这条下行载荷(room_created 只给房号、room_joined 只给 role),故在本侧拼一份最小形状,与大乱斗 / 3v3 共用同一个 _show_wait_room —— 而不是给 1v1 单开一条渲染路径。
func _pvp_wait_state(code: String, role: int) -> Dictionary:
	return {
		"code": code,
		"is_public": true,   # 1v1 没有私密房这条路径
		"players": [],       # 1v1 不画名单(设计 §3.5:`等待对手… 1 / 2`)
		"your_role": role,
		"host_role": role,
	}



# ★★ 判据必须是本页的 _current_mode(我当前所在那间房的模式),不是 PvpSession.room_mode —— 后者是凭据的模式,它在"建了房但 note_room 还没跑到"那一档上是空串。两个量语义不同,不要合并成一个字段。
# ★ 两页刻意不同的那条纪律现在按 _current_mode 分派:1v1 直切;大乱斗 / 3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内到达,栈内切场景会在这个栈里 free 大厅 / 重建大物理世界 → 偶发原生段错误(曾实测)。
# ★★ else 那一支刻意什么都不做、只 push_error,不默认切任何一个场景:本函数有三条进入路径(建房 / 加入 / 回局),任何一条漏记 _current_mode 都会落到这里 —— 切一个默认场景是静默的错值(玩家进了错的对局场景,只是看起来怪),而"留在原地 + 一条红"是响的。
func _enter_match_scene() -> void:
	if _current_mode == PvpSession.MODE_PVP:
		get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
	elif _current_mode == PvpSession.MODE_ROYALE:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/royale_game.tscn")
	elif _current_mode == PvpSession.MODE_TEAM:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/team_game.tscn")
	else:
		var msg := "mp_lobby: match_start 到了但 _current_mode 是「%s」—— 建房/加入/回局三条路里有一条没记模式。**不切场景**(切错的场景比留在原地更难查)。"
		push_error(msg % _current_mode)


# 梯顺序 = worker → claim → 大厅 → ack(合并后唯一的一条;见文件头)。★ 别重排:1v1 旧页那条 join 梯的职责由末尾的 ack 梯覆盖(建房 / 加入 8s 无应答)。
func _process(_delta: float) -> void:
	if _tick_rejoin_timeout():
		return
	if _tick_worker_connect_timeout():
		return
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	if not _ack and _sent_ms > 0 and Time.get_ticks_msec() - _sent_ms > 8000:
		_sent_ms = 0
		_probe_multi_join = false
		_multi_left = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"



func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


# 已在房间中(先退出房间再操作):_with_lobby 在 _in_room 时拒绝一切操作(列房 / 建房 / 加入)—— 不清房间态,玩家就再也刷不出列表、建不了房(两个旧页同款)。
# ★ 三个模式的文案各自点名:本页三模式共用一张列表,一句通用的"已在房间里"会让玩家看不出自己卡在哪个模式的房里。★ 这道闸门只挡得住最后那一次 RPC —— 两颗入口按钮由 _show_wait_room 直接收起(见 _create_btn 上方那段),两半缺一不可。
func _lobby_action_allowed() -> bool:
	if _in_room:
		if _current_mode == PvpSession.MODE_ROYALE:
			_status.text = "已在大乱斗房间中(先退出房间再操作)"
		elif _current_mode == PvpSession.MODE_TEAM:
			_status.text = "已在 3v3 房间中(先退出房间再操作)"
		else:
			_status.text = "已在 1v1 房间中(先退出房间再操作)"
		return false
	return true


# 三个模式的权威规则项都上发,worker 各取自己认得的键(server_main._on_player_options 与 MatchBootstrap 都按 role1 那份生效);不认得的键被静默忽略。
# ★ time(Beta 时间玩法规则)必须在这里 —— 它是权威那一份:worker 侧 MatchHost 读的正是 options.get("time"),而建房载荷里的 time 只存在房对象上、没有任何读者。漏了它 ⇒ Beta 局的时间经济静默为空(一切结算短路),而那不报错。
# ★★ 1v1 必须排除 time:PvpSession.beta_mode 是会话级的,而统一大厅让 Beta 会话里的玩家能切到 1v1 建局;但 1v1 的 create_room(caller) 是冻结签名、载荷里没有任何 beta 标记 ⇒ 那个房没法按 beta 隔离 ⇒ 没勾 Beta 的普通玩家能加进来打上一局带时间经济的 1v1。
func _player_options() -> Dictionary:
	# 键集由 ModeDefs.OPTION_KEYS 决定(2026-10-22 统一):3v3 不再上发禁用武器/回合回血 ——
	# 界面藏了控件就不该让它生效(X5);大乱斗不再上发回合回血(它没有回合);1v1 不再上发 match_time(只有大乱斗读)。
	return ModeOptions.build(_current_mode, {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict(),
		"beta": PvpSession.beta_mode,
	})


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"


func _on_worker_connect_failed() -> void:
	if _connecting_worker:
		_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")


func _worker_timeout_msg() -> String:
	# ★ 大乱斗 / 3v3 都是自建服(要自己放行 worker 端口段)⇒ 把端口段印出来是真信息;1v1 走云服,那句提示对它没有意义。端口段引 WorkerLauncher 的常量,不手写数字(旧页手写过 "7800~7999" 而实际池是 7800~8299 —— 照它放行防火墙会漏掉半个池子)。
	if _current_mode == PvpSession.MODE_ROYALE or _current_mode == PvpSession.MODE_TEAM:
		return "对局服务器无响应——请确认对局端口(%s UDP)已放行;已返回大厅并刷新" % _worker_port_span()
	return "对局服务器无响应(房间可能已失效)——已返回大厅并刷新,请换一个房间"


func _worker_port_span() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]


func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间"


func _on_go_match_extra() -> void:
	_sent_ms = 0


func _on_return_to_lobby() -> void:
	_sent_ms = 0
	_probe_multi_join = false
	_hide_wait_room()


func _on_lobby_reconnect() -> void:
	_rooms_by_mode.clear()
	_redraw_cards()
