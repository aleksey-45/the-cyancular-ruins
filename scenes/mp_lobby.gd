extends LobbyPage

# 统一联机大厅(**取代**此前三个分立的大厅页;1v1 / 大乱斗 / 3v3 三套协议在这里合并)。
# 顶栏(昵称/地址/启服) → 模式筛选 + 创建/加入 → 房卡网格 → 状态栏。
# 三套服务端注册表原样保留:本页**并发调三次**现有列房 RPC,前端合并打标(设计 §3.7.3)。
#
# ★ 一条纪律:三个模式在这里的差异**全部**收在 `_mode` 这一个变量上
#   (筛选值 / 创建弹层的形态 / 等待室的形态 / 转连方式)。别再按"哪个页面"分叉 ——
#   那正是本次要消灭的重复。
# ★ 本页的梯顺序 = `[worker → claim → 大厅 → ack]`(与旧的大乱斗/3v3 页同款):
#   1v1 旧页那条 `[worker → join → 大厅 → claim]` 随三页一起退役;合并后**只有**这一条,
#   而它必须容纳三模式 —— join 那条梯的职责由 ack 那条(建房/加入 8s 无应答)覆盖。
#
# ★ 场景是裸 Control,UI 全在代码里建(与三个旧页同款);控件一律走 UiFactory,字号 16 的倍数。

# ── 版式常量(真实像素;1920×1440 设计稿)──
# ★ 2026-10-03(尺度,第一档):页边距 40 → 56、卡间距 22 → 24、卡片高 400 → 440;
#   随之重排的是各行/各按钮的绝对坐标(本页是绝对定位,改一个就得跟一串 ——
#   漏一处就重叠)。按钮宽度那一档**不**跟 `menu_button` 的 640 默认值走:
#   本页的按钮各有实际文本宽度(见各处注释),640 会把整行挤爆。
# ★★ 2026-10-03(尺度,第二档,用户:「margin 和 padding 还是不够」):页边距 56 → **76**。
#   ★★ `ROW_H` 必须同时 64 → **72**:`UiFactory._btn_box` 的上下内边距抬到 20 之后,
#      32 号字按钮的**最低高度 = 32 + 40 = 72**,而 `Control.size` 会被 `custom_minimum_size`
#      **顶高** —— 行高还写 64 的话按钮会比它所在的那一行高出 8px、压到下一行上(且不报错)。
#   ★ 每一行/每一块的 y 都从上一块的底边 + 具名空档推出来,别再写一串魔数(见下)。
const PAGE_MARGIN := 76.0
const CARD_COLUMNS := 4
const CARD_GAP := 24.0
# 顶栏两行 / 筛选行 / 底栏那一行的行高(= 按钮的最低高度,见上)。
const ROW_H := 72.0
# 顶栏两行之间的空档。
const ROW_GAP := 16.0
# 顶栏第二行 → 筛选行。
const FILTER_GAP := 52.0
# 筛选行 → 房卡网格顶边。
const GRID_GAP := 176.0

var _mode := ""                    # 当前**筛选**:"" = 全部;否则 PvpSession.MODE_*
var _rooms_by_mode := {}           # mode -> Array(载荷条目,已打 "mode" 键)
var _grid: GridContainer = null
var _filter_btns := {}             # mode -> Button(含 "" = 全部)
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null

# ── 创建房间弹层(Task 4)──
# 压暗罩与弹层本体分开两个节点:罩子铺满整页(拦下背后的点击)、本体居中。
var _create_panel: PanelContainer = null
var _create_mask: ColorRect = null
# 弹层里需要被外部（`_apply_create_form` / 探针）按名取到的容器 —— 键名固定,
# `_build_create_panel` 必须按这几个键登记,`_apply_create_form` 按这几个键取。
# ★ 键名对不上**不报错**,只是"那一行永远不隐藏"。
# `max_players`/`match_time`/`weapons`/`privacy` 由 `_apply_create_form` **按模式**显隐;
# `map` 三模式都可见(登记只为探针能取到);`beta` 由 `PvpSession.beta_mode` 在**建面板时**定
#(`_add_time_params` 自己门控),与模式无关 —— 故 `_apply_create_form` 不碰它。
var _form_rows := {}
var _create_mode := PvpSession.MODE_PVP
var _create_mode_btns := {}   # mode -> Button(三颗分段按钮;`_apply_create_form` 用它置灰当前项)
var _public_check: CheckButton = null
var _invite_edit: LineEdit = null
var _max_slider: HSlider = null
var _time_slider: HSlider = null
var _weapon_checks: Array[CheckButton] = []   # 建房时读勾选态(与旧大乱斗页同款)

# ── 等待室(Task 5)──
# 三个模式共用**一个**面板(每次 `_show_wait_room` 清空重填),而不是每个 handler 各建一份。
# ★ 名单行数 / 按钮显隐 / 颜色行显隐**全部**收在 `_show_wait_room` 一处 —— 那是本页
#   "按模式分叉"的第二个(也是最后一个)落点(第一个是 `_apply_create_form`)。
var _wait_panel: PanelContainer = null
var _wait_box: VBoxContainer = null       # 面板根(标题/正文/尾部都挂在它下面)
var _wait_title: Label = null
var _wait_body: VBoxContainer = null      # 名单/分队容器:每次重填前整批清空
var _wait_count: Label = null
var _wait_hue: Control = null             # 角色颜色行(1v1/大乱斗可见;3v3 用队色 ⇒ 收起)
var _wait_start: Button = null
var _wait_pick_a: Button = null
var _wait_pick_b: Button = null
var _wait_leave: Button = null
# 面板当前画的是**哪个模式** —— 「开始游戏」/「退出房间」按它分派。
# ★ 与 `_current_mode` 分开:`_current_mode` 是"我所在那间房"的模式(转连选场景用),
#   而这里是"面板上画的形态"。两者通常相等,但语义不同,别合并。
var _wait_mode := ""
# 我当前是否在**某间房里**(等待室亮着)。★ 三个读写点:`_show_wait_room` 置真、
# `_hide_wait_room` 置假、`_lobby_action_allowed` 读 —— 与面板可见性**同一生命周期**,
# 分两处写状态就是漂的成因(两个旧页各有这一档,统一页丢了它)。
var _in_room := false
# 进等待室时**一并收起**的两颗入口按钮。★★ 只加 `_lobby_action_allowed()` 不够:
# 「＋ 创建房间」是**直接**绑 `_open_create_dialog` 的,压根不问那道闸门 ⇒ 玩家照样能把
# 创建弹层开在等待室上面,而压暗罩建得更早 ⇒ 落在面板**底下**(观感上罩不住等待室)。
# 收起这颗按钮才是真正解决层级问题的那一半；`_toggle_join_panel` 同理。
var _create_btn: Button = null
var _join_btn: Button = null

# **我当前所在那间房**的模式(转连时按它选场景)。
# ★★ 它与 `PvpSession.room_mode` **不是一回事**:后者是**凭据**的模式(供列表里判"这一行
#   是不是我的房"),在"建了房但 `note_room` 还没跑到"这一档上是**空串** —— 拿它去分派
#   `_enter_match_scene` 会把 1v1 的对局**静默切进 `team_game.tscn`**(不报错)。别合并成一个字段。
var _current_mode := ""

# 建房/加入的 8s 无应答兜底(合并后只剩这一条 ack 梯)
var _ack := true
var _sent_ms := 0

# 三个模式各自的"已收到应答"标记(三条 RPC 各自到达)
var _got := {"pvp": false, "royale": false, "team": false}

# 刚发出的加入请求的房号(1v1 的 `room_joined` 载荷只有 role,拿不到房号,只能靠它暂存)。
# ★★ 漏了给它赋值 = **两条**真缺陷:①`_current_mode` 停在空串 ⇒ `_enter_match_scene()`
#    落进 else ⇒ 1v1 的加入者被送进错场景;②`note_room()` 从不被调用 ⇒ 自己那间房永远是灰的。
var _join_pending := ""

# 「模式未知 ⇒ 三张表都问一次」这一次尝试还在飞。
# ★★ 三张表里**只有一间**存在,另两张表必然回「房间不存在」(或「房间已满」)——
#    那是**预期噪音**:既不显示、也**不花掉**那次自动刷新额度(`_auto_refreshed`)。
# ★★ 关闸只能靠 `_multi_left` 数**应答条数**,不能靠"任一正向应答就收尾":
#    1v1 的 `join_room` 成功是**立即**回的,而 royale/team 是 `call_deferred` + `await` ⇒
#    正向一到就关闸,那两张表稍后到的 absent 会漏出去触发一次刷新 —— 后果不是"多一条提示",
#    而是**那一次性额度被花掉**:之后第一张**真**陈旧卡片被拒时反而**不会**自动刷新了。
var _probe_multi_join := false
var _multi_left := 0               # 这一次尝试里**还没被认领**的应答数(起手 = 3 个请求)

# 「点了看起来未满却已满」后**只自动刷新一次**(手动刷新/重启本机服会放开闸门)。
var _auto_refreshed := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()
	_build_top_bar()
	_build_filter_bar()
	_build_card_grid()
	_build_status_bar()

	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state_royale)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state_team)

	_finish_lobby_ready()

	# Beta 页预选的**筛选**模式(从主菜单直接进来时为 "")。
	# ★★ 它读的是 `entry_mode` 而**不是** `room_mode`:后者是**凭据**的模式,混用会让
	#    "从 Beta 页进大乱斗"这件事把一个凭据字段写成非凭据的值 —— 而 `can_rejoin_to()`
	#    正是拿 `room_mode` 判"这一行是不是我的房"。
	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)


# ── 版式 ────────────────────────────────────────────────────────────

# 本页的按钮:32 号字 + 方向 B 的描边式(设计稿 §3.2「输入框/按钮高 64,字号 32」)。
#   旧页那套 16 号按钮工厂已随三个旧大厅页一起退役,基类不再提供。
# ★ `accent` 非 null 时走**分段筛选按钮**(选中态画该模式色),否则普通菜单按钮
#   (由 `variant` 选 primary / quiet / gold)。
func _mp_button(text: String, pos: Vector2, size: Vector2, fn: Callable,
		variant: String = "primary", accent = null) -> Button:
	var b: Button
	if accent != null:
		b = UiFactory.menu_filter_button(text, 32, size, accent)
	else:
		b = UiFactory.menu_button(text, 32, size, variant)
	b.position = pos
	b.size = size
	add_child(b)
	b.pressed.connect(fn)
	return b


# 顶栏:昵称行 / 服务器地址行 / 右上本机局域网 IP。
# ★ 各控件的 x 由「前一个的右边缘 + 间距」推出来(绝对定位;改宽度必须跟着改 x,
#   否则按钮会叠在一起 —— 而**不会报任何错**)。行 y 由 PAGE_MARGIN / ROW_H / ROW_GAP 推。
func _build_top_bar() -> void:
	var y1 := PAGE_MARGIN
	var y2 := PAGE_MARGIN + ROW_H + ROW_GAP
	var label_w := 240.0
	var x_edit := PAGE_MARGIN + label_w + 16.0
	var name_l := UiFactory.label("昵称", 32, UiFactory.C_TEXT)
	name_l.position = Vector2(PAGE_MARGIN, y1)
	name_l.size = Vector2(label_w, ROW_H)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(name_l)
	# 宽 620(不是 660):右上那条 IP 提示按文本宽(≈860)向左展开,输入框再宽 40px
	# 就会与它**横向重叠**(两者同在顶栏第一行,叠上去不报错、只是字压在框线上)。
	var name_le := UiFactory.line_edit(self, Vector2(x_edit, y1), Vector2(620, ROW_H),
			"昵称(头上显示)", PvpSession.player_name)
	UiFactory.style_control(name_le, 32)   # 本次版式统一到 32(基类 line_edit 的默认是 16)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	var addr_l := UiFactory.label("服务器地址", 32, UiFactory.C_TEXT)
	addr_l.position = Vector2(PAGE_MARGIN, y2)
	addr_l.size = Vector2(label_w, ROW_H)
	addr_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(addr_l)
	_addr_edit = UiFactory.line_edit(self, Vector2(x_edit, y2), Vector2(620, ROW_H),
			"服务器地址", PvpSession.server_address)
	UiFactory.style_control(_addr_edit, 32)
	# 两颗都是**小按钮**(不该按 `menu_button` 的 640 默认值走):宽度按各自文本取
	# 「刷新列表」4 字 ≈128px、「启动/重启本机服务器」10 字 ≈336px,加内边距(40×2)再留余量。
	var x_refresh := x_edit + 620.0 + 16.0
	_mp_button("刷新列表", Vector2(x_refresh, y2), Vector2(260, ROW_H), _on_refresh_pressed)
	var srv := _mp_button("启动/重启本机服务器", Vector2(x_refresh + 260.0 + 16.0, y2),
			Vector2(440, ROW_H), _on_local_server_pressed)
	srv.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"

	# 右上:本机局域网 IP(常驻显示,不靠易被刷掉的状态栏)。
	# ★★ **右对齐必须靠锚点,不能靠 `position` + `horizontal_alignment`** —— Label 的 `size`
	#   会被它的**最小尺寸(= 文本宽度)**顶开:提示全文约 860px 宽,写死 500 只会让矩形
	#   从 `position` 往**右**长、被屏幕右缘裁掉(2026-10-03 之前一直如此:
	#   后半句「(朋友在「服务器地址」里填它)」根本看不见 —— 而那是这条提示**唯一有用**的半句)。
	#   锚到右上 + `GROW_DIRECTION_BEGIN`:右边缘钉在 1920 − PAGE_MARGIN,文本向**左**展开。
	#   ★ 这是本次尺度调整**顺带**修的一处(不在任务清单里):它就是「内容被裁到读不出来」那类。
	_ip_label = UiFactory.label(LocalServer.lan_ip_hint(), 32, UiFactory.C_ACCENT)
	_ip_label.anchor_left = 1.0
	_ip_label.anchor_right = 1.0
	_ip_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_ip_label.offset_left = -1200.0     # 盒子够宽即可(文本右对齐 ⇒ 右边不留空)
	_ip_label.offset_right = -PAGE_MARGIN
	_ip_label.offset_top = PAGE_MARGIN
	_ip_label.offset_bottom = PAGE_MARGIN + ROW_H
	_ip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_ip_label)


# 筛选行的 y / 房卡网格的顶边:都从上面的具名常量推出来(改一处不会漏另一处)。
func _filter_row_y() -> float:
	return PAGE_MARGIN + ROW_H * 2.0 + ROW_GAP + FILTER_GAP


func _grid_top_y() -> float:
	return _filter_row_y() + ROW_H + GRID_GAP


# 筛选行:四颗分段按钮(全部 / 1v1 / 3v3 / 大乱斗)+ 右侧创建/加入。
# ★ 2026-10-03(尺度,第一档):y 230 → 252、筛选按钮 160×60 → 200×72(步进 160+12 → 200+16)、
#   创建/加入 280×60 → 320×72 并靠右对齐(右边缘 = 1920 − PAGE_MARGIN)。
# ★★ 第二档:`_btn_box` 内边距 30/14 → 40/20 之后,200 宽**装不下**「大 乱 斗」
#   (3 个全角字 ≈96 + 4 个空格 ≈64 + 两侧 80 = 240)—— 控件会被 `custom_minimum_size`
#   顶宽到 240,与步进 216 打架(相邻两颗**重叠**)。故 fw 200 → **220**、步进 236,
#   并把行 y 改成推出式。
func _build_filter_bar() -> void:
	var y := _filter_row_y()
	var group := ButtonGroup.new()
	var filters := [["", "全部"], [PvpSession.MODE_PVP, "1 v 1"],
			[PvpSession.MODE_TEAM, "3 v 3"], [PvpSession.MODE_ROYALE, "大 乱 斗"]]
	var fw := 220.0
	var x := PAGE_MARGIN
	for f in filters:
		var m: String = f[0]
		# 分段按钮:选中态 = **该模式的模式色**(未选中 = C_EDGE,与其余按钮同款)。
		# ★ 选中那一档由 Button 自己的 toggle 状态画,ButtonGroup 保证互斥;颜色织在
		#   `pressed` 主题项里(见 `UiFactory.menu_filter_button`)—— 只改常态色是**看不见**的。
		var b := _mp_button(str(f[1]), Vector2(x, y), Vector2(fw, ROW_H),
				func() -> void: _set_filter(m), "primary", MODE_COLOR.get(m, UiFactory.C_ACCENT))
		b.button_group = group
		b.button_pressed = (m == _mode)
		_filter_btns[m] = b
		x += fw + 16.0
	# 「＋ 创建房间」是这一屏的主行动 ⇒ gold 档(琥珀描边 + 琥珀字)。两颗靠右、间距 24,
	# 右边缘 = 1920 − PAGE_MARGIN(与顶栏的 IP、底栏的「返回主菜单」同一条边)。
	_create_btn = _mp_button("＋ 创建房间",
			Vector2(1920.0 - PAGE_MARGIN - 320.0 * 2.0 - 24.0, y),
			Vector2(320, ROW_H), _open_create_dialog, "gold")
	_join_btn = _mp_button("加入房间", Vector2(1920.0 - PAGE_MARGIN - 320.0, y),
			Vector2(320, ROW_H), _toggle_join_panel)


func _build_card_grid() -> void:
	_grid = GridContainer.new()
	_grid.columns = CARD_COLUMNS
	_grid.add_theme_constant_override("h_separation", int(CARD_GAP))
	_grid.add_theme_constant_override("v_separation", int(CARD_GAP))
	# 卡片顶边:筛选行底之下留一档空(GRID_GAP),与旧版的比例一致。
	_grid.position = Vector2(PAGE_MARGIN, _grid_top_y())
	_grid.size = Vector2(1920.0 - PAGE_MARGIN * 2.0, 0)
	add_child(_grid)


func _build_status_bar() -> void:
	# 一栏字浮在空底上读不出"这是个栏位" ⇒ 给它一块 `menu_panel()` 的底(方向 B 的凿刻压边)。
	# ★ 内边距仍显式给小值((32,16) 而不是工厂默认的 64/46):这一条只有 ROW_H 高,
	#   46×2 会让面板被内容顶高、压到底边(而 `bar.size` 是写死的 —— 顶高只会让它与底边打架)。
	#   y 取「1440 − 边距 − 行高」(底边留 PAGE_MARGIN)。
	var bar := UiFactory.menu_panel(Vector2(32, 16))
	bar.position = Vector2(PAGE_MARGIN, 1440.0 - PAGE_MARGIN - ROW_H)
	bar.size = Vector2(1500, ROW_H)
	add_child(bar)
	_status = UiFactory.label("", 32, UiFactory.C_TEXT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	(bar.get_node("Body") as Container).add_child(_status)
	_mp_button("返回主菜单", Vector2(1920.0 - PAGE_MARGIN - 260.0, 1440.0 - PAGE_MARGIN - ROW_H),
			Vector2(260, ROW_H), _on_back_pressed)


func _on_back_pressed() -> void:
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# 手动刷新 = 用户明确要重来 ⇒ 放开「只自动刷新一次」的闸门(否则下一次「房间已满」不会自动刷新)。
func _on_refresh_pressed() -> void:
	_auto_refreshed = false
	_request_list("刷新房间列表…")


# 重启本机服后同样放开闸门(否则下一次房间已满不会自动刷新)。
func _on_local_server_ready() -> void:
	_auto_refreshed = false


# ── 筛选 ────────────────────────────────────────────────────────────

# 切筛选模式。★ 三颗分段按钮的选中态与 `_mode` 是**同一件事的两半**,收在这里刷新,
#   别在按钮 handler 里各写一遍(那样"程序改了 `_mode`"这条路就漏了)。
func _set_filter(mode: String) -> void:
	_mode = mode
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)
	_redraw_cards()


# ── 合并与重绘 ──────────────────────────────────────────────────────

# 三个载荷入口各自把条目并入同一张表,再统一重绘。
# ★ 每条都**打上 mode 标** —— 卡片要显示模式,筛选器也按它过滤;服务端载荷里没有这个键
#   (三套注册表各管各的,谁也不该知道别人)。
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
	# ★ 不无条件清 `_ack`/`_sent_ms`:它们是**加入**的 8s 兜底,而一次**列房应答**并不能证明
	#   那次加入有应答 —— 无条件下会刚好在"加入请求丢了、用户又点了一次刷新"时把兜底拆掉。
	#   只有"没有待应答的加入"时清才是安全的。
	if _join_pending.is_empty():
		_ack = true
		_sent_ms = 0
	if _got.values().all(func(v: bool) -> bool: return v):
		_redraw_cards()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	# Beta 房与普通房互不可见(客户端侧;服务器侧 join 守卫是第二道)
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


# 重绘整张网格。
# ★★ **必须先 `remove_child` 再 `queue_free`** —— 只 `queue_free` 的话旧节点要到**帧末**才没,
#   同帧再建一次就会在网格里留下**两批卡叠着**(而且它们都还是 `_grid` 的子节点,
#   `get_children()` 数得出来)。生产里三条 RPC 应答**确实可能落在同一帧**
#   (`_ingest_rooms` 每收到一条就可能触发一次重绘)。本仓在"热重建视觉"那处踩过同款
#   (`WeaponPickup.configure` 的注释)。
func _redraw_cards() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		# 未满优先、满房排最后 —— **在每个模式内部**排(旧 1v1 页那条观感纪律)。
		# ★★ `sort_custom` 的比较函数返回 true = **a 排在 b 前面**(不是"a 该往后挪")。
		#    所以要"未满的在前",就必须在 **a 未满而 b 满** 时返回 true。写反(在 a 满时
		#    返回 true)= **满房排到了前面**,与状态栏文案、旧页(`partial + full`)全都相反,
		#    而其它断言全按 meta 找卡、对顺序不敏感 ⇒ 只有探针里那条顺序断言能红。
		# 1v1 的载荷没有 max_players ⇒ 取默认 2,与卡片那一处同一个默认值。
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


# ── 造卡 ────────────────────────────────────────────────────────────

# 模式色(与对局**无关**的一套,只在菜单系用)。★ 3v3 刻意**不用蓝** —— `#639BFF` 就是
# `UiFactory.C_TEAM_A`(队 1 的队色),而队色在 3v3 里是**有玩法语义**的颜色
# ("一眼看出谁是队友")。拿它当模式色会让大厅的「3v3」与对局的「队 1」撞色。
# ★★ 两个模式色**定义在 `ui/factory/ui_factory.gd`**(调色板单一来源是本项目的硬约束:
#    「颜色只在那里定义…不要再写 `Color(...)` 字面量」)。这里只引用,不写字面量 ——
#    写在这里不会报错,只会让计划 ③ 的调色板工作**再定义一遍同样的颜色**、两份静默漂移。
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


# 一张房卡 = **一颗 Button**(卡本体就是可点区域)。
# ★ 为什么不是 PanelContainer + 覆盖层:那样"点不动"就要靠探针去数覆盖层的连接数,
#   而 `disabled` / `focus_mode` / `pressed` 这三个原生属性都在 Button 上 —— 探针的三条
#   断言(`disabled` / 0 连接 / 不吃焦点)直接落在同一个节点上,没有第二处真值。
# ★ 子节点一律 `mouse_filter = IGNORE`:内容画在 Button 之上,但点击必须落到卡本体,
#   否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	_style_card(btn)
	# 卡高 400 → 440(2026-10-03 尺度):卡内边距同时放大,不抬高度会把正文挤到贴边。
	btn.custom_minimum_size = Vector2(_card_width(), 440)
	btn.size = Vector2(_card_width(), 440)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""   # 内容全部自绘

	# 卡底 = 凿刻压边:外层 `C_BORDER` 线由 Button 自己的 stylebox 画,内层 `C_INNER` 线
	# 由这块内缩 1px 的透明底 PanelContainer 画 —— 与 `UiFactory.menu_panel()` **同一个形状**。
	# ★ 外壳**必须**仍是 Button(卡的 `text` 恒空 + `meta("code")` 是探针找卡的唯一据点),
	#   所以不能真的把卡换成 PanelContainer。
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

	# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**(`can_rejoin_to` 已在上面算好),
	#    这一档**可点**(点了走回局);不是我的房,才轮到「对局中 ⇒ 禁用」那一档。
	#    反过来写 = 回局这一档连点都点不到,而**一行报错都没有**。
	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)   # 整体压暗:一眼看出这间进不去
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			# ★★ 回局那条路**也要**记下模式 —— 与"加入"那条同款。
			#    ESC 回主菜单 → 多人模式(新页,`_current_mode == ""`)→ 点自己那间**对局中**的房
			#    → `try_rejoin_row` → `go_match` → `match_start` → `_enter_match_scene()`
			#    落进 else ⇒ **回局也会进错场景**。没有这一行,`_enter_match_scene` 的
			#    else(push_error)就是唯一能把它喊出来的地方。
			_current_mode = mode
			if not try_rejoin_row(code, in_match, mode):
				_join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


# 卡头 = 一条**标题带**(方向 B):`C_HEADER` 底 + 只有下边一条 `C_BORDER` 线,
# 左 = 模式名(模式色),右 = 状态角标。
# ★ 与 `UiFactory.header_strip()` 同一个味道,但那条工厂版标题色固定为金、也不带右侧角标,
#   故这里按同一套版式拼一条(色仍只从 `UiFactory` 取,不写字面量)。
# ★ 角标三档的**次序**:`对局中` 优先于 `私密 · 我的` —— 一间对局中的私密房对**别人**
#   根本不列出,能同时满足两条的只有"我的房且已开局",那时"对局中"是更有用的信息。
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
	# 与 `UiFactory.header_strip` 同一轮放大(16/8 → 28/14 的那一档):12/6 → 20/12。
	# ★ 这里是**第二份**字面量(工厂那条标题带不带右侧角标,故没走工厂)——两边要同步手改。
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
	# ★ 三档取色**刻意避开 `C_WARN`** —— 它在调色板里被钉死为「弹夹见底」**单一语义**
	#   (`ui_factory.gd` 的 `C_WARN` 注释明写"**只**用于「低弹量/耗尽」")。拿它表"私密"
	#   会让那个金色在大厅与 HUD 里指两件事。这里用中性亮白:不抢强调色,也不借用语义色。
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	# 角标是**次要**信息(16):正文那些行都是 32,角标小一号才读成"状态贴纸"而不是又一个字段。
	var badge_l := UiFactory.label(badge, 16, badge_col)
	badge_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(badge_l)
	return strip


# 房卡底(方向 B 的凿刻感):外层一条 `C_BORDER`(常态)/ `C_ACCENT`(悬停/焦点),
# 填充走 `C_SURFACE`。内层那条 `C_INNER` 线由子节点那块 frame 画(见 `_make_card`)。
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


# 卡身:房间号(48) → 副标(32) → [地图缩略图 120×120 | 人数/房主] → 名单(最多 3 行)。
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
	# ★ 1v1 的载荷**没有** max_players(1v1 恒 2 人)—— 前端补,而不是去动那三个载荷的形状。
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("players", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


# 副标按模式给不同的一行(它就是各模式"规则摘要"的位置)。
func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


# 地图缩略图。★ 复用 MapCatalog 那套(选图面板已经在用它现画地形简略图)——
#   **不要**另写一份画法:两份必然漂,而漂了不报错,只是两张图长得不一样。
#   `map` 为空(= 未上报 / 随机)时退化成一块模式色占位,而不是留一个空洞。
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 签名 `MapCatalog.texture(path: String, cell_px: int = CELL_PX) -> ImageTexture`
		# —— 与 `ui/map_picker.gd` 同一个入口。
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


# 名单行:**最多 3 行**,超出显示 `…等 N 人`。
# ★ 名字走 `UiFactory.fit_name(名字, 14)` 定宽截断(与结算页同款)—— 不截的话长昵称会
#   把卡顶宽(卡宽是 4 列网格算出来的固定值,顶宽 = 整行错位)。
func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		# 名单是卡上的**次要**信息 ⇒ 16 号(房间号 48 / 正文 32 / 次要 16)。
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				16, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 16, UiFactory.C_TEXT_DIM))
	return box


# ── 拉列表(三条并发)────────────────────────────────────────────────

# 基类钩子。★ **不是一条统一 RPC** —— 三条并发、各自到达,合并后重绘。
#   代价照实登记:刷新延迟由最慢那份决定(设计 §3.7.3)。
#   token 仍要带(B1 甲案):大厅据此把"持凭据本人自己那间私密房"也列出来。
func _send_list_request() -> void:
	_got = {"pvp": false, "royale": false, "team": false}
	_rooms_by_mode.clear()
	NetBus.rpc_id(1, "list_rooms")
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
	NetBusExt.rpc_id(1, "team_list", PvpSession.token)


# ── 大厅回复 ────────────────────────────────────────────────────────

# 1v1 建房:建房者就是房主。记房号 + 记模式(转连时按 `_current_mode` 选场景)。
func _on_room_created(code: String) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(code, _current_mode)
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图(设计 §3.7.2):1v1 的 `create_room` 签名冻结,塞不进 payload。
	# ★ 这里**无条件**发 —— 走到本 handler 的就是建房者,也就是房主。
	NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code
	# 建房成功 ⇒ 亮起等待室(1v1 旧页建房后没有任何"我在等"的界面,状态只落状态栏)。
	# 建房者 role 恒 1(见 `lobby_rooms.create_room` 的 `room.player_role[caller] = 1`)。
	_show_wait_room(_pvp_wait_state(code, 1), PvpSession.MODE_PVP)


# 服务端答"加进去了"。★ 房号从 `_join_pending` 取(`room_joined` 载荷只有 role)——
# 这里同时是**唯一**记 1v1 加入房号的地方(I1:失败的加入不得留下 `room_code`,否则
# `can_rejoin_to(我自己的房)` 恒 false,自己那间房永远是灰的)。
func _on_room_joined(role: int) -> void:
	# ★★ 模式**直接定死**,不从别处推 —— 触发的是这条 handler,就只可能是 1v1。
	_current_mode = PvpSession.MODE_PVP
	# 房号先拷出来:`room_joined` 载荷只有 role,房号唯一来源是 `_join_pending`。
	var code := _join_pending
	if not _join_pending.is_empty():
		PvpSession.note_room(_join_pending, _current_mode)
		_join_pending = ""
	_ack = true
	_sent_ms = 0
	# ★ 只是**认领一格**,不是"多表尝试到此为止" —— 另两张表的 absent 还在路上
	#   (`join_room` 立即回,royale/team 是 call_deferred + await)。见 `_probe_multi_join`。
	_claim_multi_reply()
	_status.text = "已加入,等待开战……"
	# 加入成功 = 「我在等」这件事该有个界面(旧 1v1 页只落状态栏)。
	if not code.is_empty():
		_show_wait_room(_pvp_wait_state(code, role), PvpSession.MODE_PVP)


func _on_room_state_royale(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_ROYALE
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图(设计 §3.7.2)。★ 只有**房主**该发 —— 非房主发会被服务端静默拒(**不报错**,
	#   所以必须自己判,否则每个加入者都会白发一次)。
	# ★ 判据用服务器下发的 `host_role` / `your_role` 两条(它们按 peer 单独下发,不是按昵称
	#   反查 —— 两人同名时会命中先出现的那个,本仓踩过)。
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
	# 补发地图(与上面大乱斗那条同款同判据):只有房主该发,非房主发被服务端静默拒。
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
	_status.text = "已进入 3v3 房间 %s,等待选边/开局…" % code
	_show_wait_room(state, PvpSession.MODE_TEAM)


# 大厅文本播报。
# ★★ 收到**任何**一句服务端文案,就证明"它回了" ⇒ 一律解除 8 秒兜底(`_ack` / `_sent_ms`)。
#    兜底的语义是「服务器**一个字都没回**」;枚举白名单是替一个不需要枚举的东西枚举 ——
#    漏一条(「邀请码错误」「你已经在房间里了」「该房间的对局已进行中,无法加入」…)就会让
#    8 秒后 `_process` 把**真拒绝**覆盖成「地址不通/服务器不是最新版」,玩家看到的是
#    与实情相反的解释。
# ★ 「模式未知的三连发」里的拒绝是**预期噪音**(三张表只有一间存在):吞掉、**不显示也不刷新**
#    —— 刷新额度是一次性的,被噪音花掉 = 之后那第一张**真**陈旧卡片被拒时反而不会自动刷新。
# ★ 非多表尝试时「房间已满 / 房间不存在」仍走旧 1v1 的行为:提示并**自动刷新一次**
#   (列表不刷新就一直挂着那几间;闸门由 `_auto_refreshed` 把着)。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	_ack = true
	_sent_ms = 0
	if _swallow_absent(t):
		_claim_multi_reply()
		# ★★ 闸门在**这一条**上关掉、而三张表**一张都没接受**(`_join_pending` 没被任何
		#    success handler 清过)⇒ 这一次加入是**失败**,必须显式收尾(见 `_settle_multi_fail`)。
		#    少了这一支,手敲房号写错 / 房间已满时三条应答全被吞、8s 兜底又被上面两行解除,
		#    状态栏就**永远**停在「加入房间 X,等待配对…」而**一行报错都没有**。
		# ★ `_join_pending` 是"有没有表接受"的现成判据:三个加入成功 handler
		#    (`_on_room_joined` / 两个 `room_state`)**都**会把它清空,而吞掉的 absent 不清。
		if not _probe_multi_join and not _join_pending.is_empty():
			_settle_multi_fail(t)
		return
	if t == "房间已满" or t == "房间不存在":
		# 服务端已明确应答 ⇒ 那间房与我无关,别留给下一次的成功信号(I1)。
		_join_pending = ""
		if not _auto_refreshed:
			# ★ 推迟到帧末:server_message 在大厅 peer 的 poll 调用栈内到达,栈内立刻
			#   NetBus.stop()(重连)会把正在 poll 的 peer 提前 free → 原生段错误。
			_auto_refreshed = true
			_request_list.call_deferred("%s → 已自动刷新列表" % t)
		else:
			_status.text = t
	elif t.begins_with("配对已取消"):
		# 已入房后房主/对端掉线被大厅取消:房间已不在,直接刷新恢复可操作(不叠加闸门)。
		_join_pending = ""
		_request_list.call_deferred("配对已取消(对手离开)——已刷新列表,请重选")
	else:
		_status.text = t


# 「模式未知的三连发」回来的应答是不是**预期噪音**?(三张表只有一间存在。)
# ★ 调用方(`_on_server_message`)**吞掉它之后还要认领一格**(`_claim_multi_reply`)——
#   顺序不能反:认领可能当场关掉闸门,那时这一句就不该再被吞。
func _swallow_absent(t: String) -> bool:
	return _probe_multi_join and (t == "房间不存在" or t == "房间已满")


# 「模式未知的三连发」**一张表都没接受**时的收尾(2026-10-03 ①)。
# ★ 与 `_on_server_message` 非多表那一支("房间已满 / 房间不存在" → 提示并**自动刷新一次**)
#   **同款同闸门**(`_auto_refreshed` 一次性)—— 于是"手敲房号写错 / 房间已满"在两条路上
#   表现一致;而三张表的 absent 是**预期噪音**,只有"全拒"这一档才升级成真失败。
# ★ 只在 `_claim_multi_reply` 把闸门收到 0、且没有任何一张表接受时被调(判据在调用点)。
func _settle_multi_fail(t: String) -> void:
	_join_pending = ""
	if not _auto_refreshed:
		# ★ 推迟到帧末:与下面那条同因(server_message 在大厅 peer 的 poll 调用栈内到达)。
		_auto_refreshed = true
		_request_list.call_deferred("%s → 已自动刷新列表" % t)
	else:
		_status.text = t


# 多表尝试期间:每收到**一条**服务端应答就认领一格,认领完即关闸。
# ★★ 闸门由**应答条数**关,不由"任一正向应答"关 —— 1v1 的 `join_room` 成功是**立即**回的,
#    而 royale/team 是 `call_deferred` + `await`:正向一到就关闸,那两张表稍后到的 absent
#    会漏出去、误触发一次自动刷新(一次性额度被噪音花掉,之后真拒绝时反而不会刷新)。
# ★ 另两条关闸路径:8s 一个字都没回(见 `_process`)、以及下一次加入开始时重设。
func _claim_multi_reply() -> void:
	if not _probe_multi_join:
		return
	_multi_left -= 1
	if _multi_left <= 0:
		_probe_multi_join = false


# ── 加入 ────────────────────────────────────────────────────────────

func _toggle_join_panel() -> void:
	if _join_panel == null:
		_build_join_panel()
		# ★ 首次点击是「打开」,不是「开关翻转」—— 新建的 PanelContainer 默认 visible,
		#   若无条件 `not visible` 会把刚建好的弹层**当场关掉**(点了没反应)。
		_join_panel.visible = true
		return
	_join_panel.visible = not _join_panel.visible


func _build_join_panel() -> void:
	_join_panel = UiFactory.menu_panel()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	vb.custom_minimum_size = Vector2(640, 0)
	(_join_panel.get_node("Body") as Container).add_child(vb)
	vb.add_child(UiFactory.header_strip("加入房间", 32))
	_join_code_edit = UiFactory.line_edit(vb, Vector2.ZERO, Vector2(560, 64), "房间号", "")
	_join_code_edit.custom_minimum_size = Vector2(560, 64)
	UiFactory.style_control(_join_code_edit, 32)
	_join_invite_edit = UiFactory.line_edit(vb, Vector2.ZERO, Vector2(560, 64),
			"邀请码(私密房,可空)", "")
	_join_invite_edit.custom_minimum_size = Vector2(560, 64)
	UiFactory.style_control(_join_invite_edit, 32)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vb.add_child(row)
	var join := UiFactory.menu_button("加 入", 32, Vector2(220, 64), "gold")
	join.pressed.connect(func() -> void:
		_join_panel.visible = false
		_join_code(_join_code_edit.text.strip_edges(), _mode, _join_invite_edit.text))
	row.add_child(join)
	var cancel := UiFactory.menu_button("取 消", 32, Vector2(220, 64), "quiet")
	cancel.pressed.connect(func() -> void: _join_panel.visible = false)
	row.add_child(cancel)
	add_child(_join_panel)
	# 居中锚点必须在入树之后设:未入树时父级尺寸为 0,面板会飞到屏幕左上角外(两个旧页都踩过)。
	_join_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_join_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_join_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# 加入某房间号。★ 模式未知(从"全部"列表点的、或手敲房号)时,三张表**都试一次**:
#   三张里只有一间存在,另外那两张表的「房间不存在 / 房间已满」是**预期噪音** ——
#   由 `_on_server_message` 经 `_swallow_absent` 吞掉(**不显示、也不花掉自动刷新额度**),
#   每吞一条认领一格(`_claim_multi_reply`),认领满三格才关闸。
#   ★ 注意 1v1 那条成功应答**不会**提前关闸 —— 理由见 `_probe_multi_join` 的字段注释。
# ★ `invite` 是**可选第三参**:私密房不在列表里,邀请码是加入它的唯一途径(设计 §3.2);
#   卡片按下那条路只传前两参(它本来就不该带邀请码)。
func _join_code(code: String, mode: String, invite: String = "") -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		# ★★ 三件事一件都不能少,否则 1v1 的**加入者**会被送进错场景(见字段声明处那段):
		#   ① 暂存房号(1v1 的 `room_joined` 载荷只有 role,拿不到房号);
		#   ② 模式未知时三张表都问一次;③ invite 必须真的传下去(私密房的唯一途径)。
		_join_pending = code
		# ★★ 模式已知 ⇒ **在发起加入这一刻**就把 `_current_mode` 置上(见字段声明处那段)。
		#   卡片点击那条路**总是**知道模式,本来就该在此记;而 `mode == ""`(在"全部"筛选下
		#   手敲房号)时**不设** —— 那种情况本来就要等应答才知道是哪张表。
		#   ★ 为什么必须在**这里**记、而不能只靠 `_on_room_state_*`:等待室广播是
		#     `call_deferred` + 再等一帧,且发送前 `if rr.in_match: return` ⇒ 房主若在
		#     "有人加入"的同一两帧内开局,那次广播会被**静默吞掉**,响应式的 `_on_room_state_*`
		#     **永远不会来** ⇒ 只靠它记的话 `_current_mode` 恒空 ⇒ `_enter_match_scene` 落进
		#     else(push_error、不切场景)⇒ 加入者**卡在大厅**。
		#   ★ 加入**失败**时 `_current_mode` 留着这个旧值**无害**:`_enter_match_scene` 只在
		#     `match_start` 到达时才跑,而加入失败根本不会有 `match_start`;下一次建房/加入
		#     会把它覆盖掉(`_lobby_action_allowed` 只读它、且另有 `_in_room` 兜底)。
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
			# 模式未知:三张表都问一次(只有一间会成功)
			NetBus.rpc_id(1, "join_room", code)
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode))


# ── 创建房间弹层(Task 4)────────────────────────────────────────
#
# 点「＋ 创建房间」才展开;按模式变形(设计 §3.4 那张表 —— 差异全收在 `_apply_create_form`)。
# 房主选项从"常驻右栏"搬进弹层:列表要占满整页,常驻右栏会把 4 列房卡挤成 3 列。

# 全屏压暗罩(黑 0.55,与 `ui/screens/match_result.gd` 的 `MASK_COLOR` / 暂停菜单同值)。
# ★ 它是调色板纪律的**已知例外**:全屏遮罩不属于 `C_PLATE` 那条「HUD 底板 0.1」家族
#   (见 CLAUDE.md §UI)。沿用与本仓既有遮罩**逐字相同**的字面量,不新造调色板 token
#   —— 新造一个只会让同一种黑在两处漂开。
const CREATE_MASK_COLOR := Color(0, 0, 0, 0.55)


# 点「＋ 创建房间」才建/显示。★ 只建一次、之后只改可见性(重建会把滑块拖回默认值)。
func _open_create_dialog() -> void:
	if _create_panel == null:
		_build_create_panel()
	_create_mode = _mode if _mode != "" else PvpSession.MODE_PVP
	_apply_create_form(_create_mode)
	_set_create_visible(true)


# 弹层与压暗罩一起显隐(罩子单独隐藏会留下一层吃掉点击的全屏黑)。
func _set_create_visible(v: bool) -> void:
	_create_panel.visible = v
	if _create_mask != null:
		_create_mask.visible = v


func _build_create_panel() -> void:
	# 压暗罩:铺满整页 + STOP = 拦下背后的点击(点弹层外不会误触房卡)。
	_create_mask = ColorRect.new()
	_create_mask.color = CREATE_MASK_COLOR
	_create_mask.mouse_filter = Control.MOUSE_FILTER_STOP
	_create_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_mask.visible = false
	add_child(_create_mask)

	_create_panel = UiFactory.menu_panel()
	_create_panel.visible = false
	add_child(_create_panel)

	# ★ 内容**必须**加在 `Body` 里 —— 只有它承载 `menu_panel()` 的内边距(加在外层 =
	#   padding 完全失效、内容直接顶到外线上,而画面上只表现为"挤",不报错)。
	var root_vb := VBoxContainer.new()
	root_vb.add_theme_constant_override("separation", 32)
	(_create_panel.get_node("Body") as Container).add_child(root_vb)

	# 标题行:标题带 + 右上角 ×(关闭)。
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 16)
	root_vb.add_child(title_row)
	# ★ 标题换 `header_strip()`(方向 B 的标题带)——它是 Label 的**外层容器**,
	#   所以 `title_row` 里那颗 × 仍然按文案找得到(`lobby_create_form_probe`)。
	var title := UiFactory.header_strip("创 建 房 间", 48)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	# 关闭键是**次要动作**(与「取 消」同款 quiet)。高度用 72 = 32 号字按钮的新最低高度
	# (见 `UiFactory._btn_box` 的侧写),与左侧标题带等高。
	var close := UiFactory.menu_button("×", 32, Vector2(80, 72), "quiet")
	close.pressed.connect(func() -> void: _set_create_visible(false))
	title_row.add_child(close)

	# 双列:左 = 房型与人数/限时;右 = 禁用武器 + 地图。
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 48)
	root_vb.add_child(cols)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 28)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 28)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	# 左列:模式分段按钮(三颗)+ 公开/私密 + 邀请码 + 人数行 + 限时行。
	left.add_child(_build_create_mode_buttons())
	# 公开/私密 + 邀请码**整块**一个容器:1v1 下要整块隐藏(见 `_apply_create_form` 的注释)。
	var privacy_row := VBoxContainer.new()
	privacy_row.add_theme_constant_override("separation", 16)
	_build_public_row(privacy_row)
	left.add_child(privacy_row)
	_form_rows["privacy"] = privacy_row
	_build_max_players_row(left)
	_build_match_time_row(left)
	_build_full_heal_row(left)

	# Beta 时间玩法参数(设计 §3.4):基类 `_add_time_params` 现成,且**自门控** ——
	# 非 Beta 态它往容器里什么都不加。★ 这一段与**模式**无关(只看 `PvpSession.beta_mode`),
	# 故 `_apply_create_form` 不碰 `_form_rows["beta"]`,它的可见性在建面板这一刻定死。
	var beta_block := VBoxContainer.new()
	beta_block.add_theme_constant_override("separation", 16)
	beta_block.visible = PvpSession.beta_mode
	_add_time_params(beta_block)
	left.add_child(beta_block)
	_form_rows["beta"] = beta_block

	# 右列:禁用武器**整块**(标题 + 网格)。整块一个容器,才能一次显隐(设计 §3.4)。
	var wblock := VBoxContainer.new()
	wblock.add_theme_constant_override("separation", 16)
	# 区块标题 = 同款标题带(与设置页 / 单人开局面板的区块标题同一套;字号 32 是**面板内**
	# 分区的档,不与 48 的面板标题抢视线)。
	wblock.add_child(UiFactory.header_strip("禁用武器(房主生效,开局带进对局):", 32))
	# ★ 回调把 `cb` 与 `type_id` **都**收进 `_weapon_checks`(照旧大乱斗页的写法)——
	#   少收 `type_id` 那半,`_checked_weapons()` 会永远返回 `[0]` 且**不报错**。
	_add_weapon_grid(wblock, 20, func(cell: Node, type_id: int) -> void:
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("type_id", type_id)
		_weapon_checks.append(cb))
	right.add_child(wblock)
	_form_rows["weapons"] = wblock

	# 右列:地图选择(基类 `_add_map_picker` 写 Settings.mp_map_path)。整块登记,供探针查显隐。
	var map_block := VBoxContainer.new()
	map_block.add_theme_constant_override("separation", 16)
	_add_map_picker(map_block)
	right.add_child(map_block)
	_form_rows["map"] = map_block

	# 底部:取消 / 创建房间。
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 24)
	actions.alignment = BoxContainer.ALIGNMENT_END
	root_vb.add_child(actions)
	# 高度 88 = 与单人开局面板那对并排按钮同档(两处都是"弹层的行动行")。
	var cancel := UiFactory.menu_button("取 消", 32, Vector2(280, 88), "quiet")
	cancel.pressed.connect(func() -> void: _set_create_visible(false))
	actions.add_child(cancel)
	# 「创 建 房 间」= 弹层里的主行动 ⇒ gold 档(与筛选行那颗「＋ 创建房间」同色).
	var create := UiFactory.menu_button("创 建 房 间", 32, Vector2(400, 88), "gold")
	create.pressed.connect(_on_create_pressed)
	actions.add_child(create)

	# 居中锚点必须在**入树之后**设(未入树时父级尺寸为 0,面板会飞到屏幕左上角外)——
	# 与加入面板同款,见 `_build_join_panel`。
	_create_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_create_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_create_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# 三颗模式分段按钮(用 ButtonGroup 保证互斥,选中态由 Button 自己画 —— 与筛选行同款)。
# ★ 必须登记进 `_create_mode_btns`:`_apply_create_form` 靠它把**当前项**置灰。
func _build_create_mode_buttons() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var group := ButtonGroup.new()
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		# 与筛选行同款:选中那一段画该模式的模式色(未选 = C_EDGE)。高度 = ROW_H(新最低高度)。
		var b := UiFactory.menu_filter_button(str(MODE_LABEL[m]), 32, Vector2(220, ROW_H), MODE_COLOR[m])
		b.button_group = group
		b.pressed.connect(func() -> void: _apply_create_form(m))
		_create_mode_btns[m] = b
		row.add_child(b)
	return row


# 公开/私密开关 + 邀请码输入框(私密时才显示 —— 勾选框直接控制输入框的 visible)。
func _build_public_row(parent: Node) -> void:
	_public_check = CheckButton.new()
	_public_check.text = "公开房间(不勾选 = 私密,凭邀请码进入)"
	_public_check.button_pressed = true
	UiFactory.style_check(_public_check, 32)
	_public_check.toggled.connect(func(on: bool) -> void:
		_invite_edit.visible = not on)
	parent.add_child(_public_check)

	_invite_edit = LineEdit.new()
	_invite_edit.placeholder_text = "邀请码(留空自动生成)"
	_invite_edit.visible = false
	_invite_edit.custom_minimum_size = Vector2(0, 64)
	UiFactory.style_control(_invite_edit, 32)
	UiFactory.style_line_edit(_invite_edit)
	parent.add_child(_invite_edit)


# 人数上限行(仅大乱斗可见)。整行登记进 `_form_rows["max_players"]`。
func _build_max_players_row(parent: Node) -> void:
	var row := HBoxContainer.new()
	# ★ HBox 只认 "separation";"h_separation" 是 GridContainer 的键(写在这里存得下、永不读)。
	row.add_theme_constant_override("separation", 16)
	row.add_child(UiFactory.label("人数上限:", 32))
	_max_slider = HSlider.new()
	_max_slider.min_value = 2
	_max_slider.max_value = 8
	_max_slider.step = 1
	_max_slider.value = 4
	_max_slider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(_max_slider)
	row.add_child(_max_slider)
	var lbl := UiFactory.label("4 人", 32, UiFactory.C_TEXT)
	_max_slider.value_changed.connect(func(v: float) -> void: lbl.text = "%d 人" % int(v))
	row.add_child(lbl)
	parent.add_child(row)
	_form_rows["max_players"] = row


# 一局限时(分钟;仅大乱斗可见)。整行登记进 `_form_rows["match_time"]`。
# ★ 滑条上界 15 与旧大乱斗页一致 —— `ROYALE_MATCH_TIME_CEILING` 那条上界链的**第三环**
#   (`Settings.royale_match_min` 的写入端),别在这里改数值(见 CLAUDE.md §大乱斗)。
func _build_match_time_row(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.add_child(UiFactory.label("一局限时:", 32))
	_time_slider = HSlider.new()
	_time_slider.min_value = 1.0
	_time_slider.max_value = 15.0
	_time_slider.step = 1.0
	_time_slider.value = Settings.royale_match_min
	_time_slider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(_time_slider)
	row.add_child(_time_slider)
	var lbl := UiFactory.label("%d 分钟" % int(Settings.royale_match_min), 32, UiFactory.C_TEXT)
	_time_slider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		lbl.text = "%d 分钟" % int(v))
	row.add_child(lbl)
	parent.add_child(row)
	_form_rows["match_time"] = row


# 「每回合开始回满血」房主选项(**仅 1v1 可见**;2026-10-03 ②)。
# ★★ 为什么必须在这里补:被删掉的 1v1 旧页有这颗勾选框,而设计 §3.4 的创建弹层表与
#    §3.6 的设置项列表**都没收它** ⇒ `Settings.pvp_round_full_heal` 失去**唯一**写入方,
#    仍被 `_player_options()` 读取并上报,而玩家再也打不开它。
# ★ 它是**房主 / 服务器规则**(大乱斗那边恒 false、3v3 压根不发),故归属创建房间弹层。
# ★ 勾选态直写 Settings + save()(与 `_build_match_time_row` / `_add_hue_row` 同款)。
func _build_full_heal_row(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var check := CheckButton.new()
	check.text = "每回合开始回满血(房主生效)"
	check.button_pressed = Settings.pvp_round_full_heal
	UiFactory.style_check(check, 32)
	check.toggled.connect(func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save())
	row.add_child(check)
	parent.add_child(row)
	_form_rows["full_heal"] = row


# 禁用武器网格的勾选结果 → type_id 数组。★ 与 `LobbyPage._add_weapon_grid` 的 `on_cell`
# 回调配对:那个回调负责把 `cb` 与 `type_id` 一起收进 `_weapon_checks`(见 `_build_create_panel`)。
func _checked_weapons() -> Array:
	var out: Array = []
	for cb in _weapon_checks:
		if cb.button_pressed:
			out.append(int(cb.get_meta("type_id", 0)))
	return out


# 按模式变形 —— 本弹层**唯一**的分支(设计 §3.4 的那张表)。
# ★ 3v3 关掉禁用武器不只是"规则里没有":那两个勾选框写的是 `Settings.pvp_disabled_weapons`,
#   在 3v3 页勾一下会**连带改掉另两个模式**。那是功能缺陷,不是审美。
# ★★ 置灰要迭代 `_create_mode_btns` 的**值**:`for m in dict` 拿的是**键**(String)——
#    写成 `for b in _create_mode_btns: (b as Button)…` 会在每个键上取到 null,当场报错、
#    函数在置灰那一行断掉(可见性那三行在前,所以症状是"变形对了、按钮不置灰" + 一串报错)。
func _apply_create_form(mode: String) -> void:
	_create_mode = mode
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	_form_rows["max_players"].visible = is_royale
	_form_rows["match_time"].visible = is_royale
	# ★ 「每回合开始回满血」是 1v1 独有的房主规则(大乱斗恒 false、3v3 不发该键)⇒ 只 1v1 可见。
	_form_rows["full_heal"].visible = is_pvp
	_form_rows["weapons"].visible = not is_team
	# ★ 1v1 下那一行是**骗人的控件**:`create_room(caller)` 是原版 NetBus 的**冻结签名**、
	#   收不了 opts ⇒ 服务端永远建公开房(1v1 载荷里 `is_public` 恒 true)。让玩家取消勾选
	#   "公开"、填了邀请码,建出来仍是人人可见、无需码就能进的房 —— 比不给这个选项更坏。
	_form_rows["privacy"].visible = not is_pvp
	for m in _create_mode_btns:
		(_create_mode_btns[m] as Button).disabled = false
	(_create_mode_btns[mode] as Button).disabled = true   # 当前模式置灰(与等待室的选边同款)


# 按模式给三套 payload 的**公共部分** + 各自的私有键。
# ★ `map` 三个模式都上发(设计 §3.7.2):1v1 的 `create_room` 签名冻结、塞不进 payload,
#   故地图一律走 `room_map` 那条独立的 RPC —— 建房成功后由本端补发一次(见 `_on_room_created`
#   与两个 `room_state` handler)。
# ★ 3v3 **不带** `disabled_weapons`:禁用武器在 3v3 由弹层那一行关掉,值从 `player_options`
#   (报到时读 Settings)走,与建房载荷无关。
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


# 建房:按模式分派 RPC。1v1 的 `create_room` 是原版 NetBus 的 RPC、**签名冻结**(不带 payload),
# 它的 `map`/`disabled_weapons` 都从 `player_options`(报到时读 Settings)走。
func _on_create_pressed() -> void:
	# ★ 按下即收起弹层(**不等应答** —— `_with_lobby` 的行动可能是异步的:没连上时它会先
	#   建连接、连上后才跑 action)。结果一律走状态栏(成功 = 房间号;失败 = 服务端那句文案),
	#   玩家要改选项再按「＋ 创建房间」重开即可。
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


# ESC 关弹层(设计 §3.4)。★ **弹层不可见时一律不处理** —— 大厅页自己的返回语义
# (回主菜单)不能被这里抢掉;只有弹层挡着页面时才吞掉这一次 ESC。
func _unhandled_input(ev: InputEvent) -> void:
	if _create_panel == null or not _create_panel.visible:
		return
	if ev.is_action_pressed("ui_cancel"):
		_set_create_visible(false)
		get_viewport().set_input_as_handled()


# ── 等待室(Task 5)─────────────────────────────────────────────────
#
# 三个模式共用**一个**面板:建一次,之后每次 `_show_wait_room` 清空重填(设计 §3.5)。
#   · 1v1    : `等待对手… 1 / 2`(1v1 两人凑齐**自动**开局 ⇒ 没有「开始游戏」)
#   · 大乱斗 : 名单 + `N / M 人` + 房主「开始游戏」
#   · 3v3    : A 队 / B 队 / 未选边三档 + 两颗选边(自己那支置灰)+ 房主「开始游戏」(两队各满)
#   · 共同尾巴:角色颜色行(**仅 1v1 / 大乱斗**;3v3 用队色)+「退出房间」
#
# ★★ 四条 `_show_wait_room` 调用点 = 1v1 建房 / 1v1 加入 / 两个 `room_state`(见各 handler);
#    `_hide_wait_room()` 的**唯一**调用点是 `_on_return_to_lobby()`(转连与 claim 超时梯、
#    回局失败、大乱斗/3v3 的「退出房间」全都汇到它)。漏了它 = 退回大厅后等待室还盖在屏上,
#    而且**一行报错都没有** —— 玩家以为还卡在房里。


func _build_wait_panel() -> void:
	_wait_panel = UiFactory.menu_panel()
	_wait_panel.visible = false
	add_child(_wait_panel)

	_wait_box = VBoxContainer.new()
	_wait_box.add_theme_constant_override("separation", 20)
	_wait_box.custom_minimum_size = Vector2(800, 0)
	(_wait_panel.get_node("Body") as Container).add_child(_wait_box)

	# 标题 = 一条 `header_strip()` 标题带。★ `_wait_title` 仍是那条带**里面**的 Label
	#   (工厂的唯一子节点就是它)—— 探针按 `_wait_title.text` 读房间号,不能把它换成容器。
	var title_strip := UiFactory.header_strip("", 32)
	_wait_title = title_strip.get_child(0) as Label
	_wait_box.add_child(title_strip)

	_wait_body = VBoxContainer.new()
	_wait_body.add_theme_constant_override("separation", 12)
	_wait_box.add_child(_wait_body)

	_wait_count = UiFactory.label("", 32, UiFactory.C_TEXT)
	_wait_box.add_child(_wait_count)

	# 选边按钮(仅 3v3 可见)。★ 一次建、按模式显隐 —— 不重建(重建会连 handler 与
	# `_hide_wait_room` 之外的引用一起换掉)。
	var pick_row := HBoxContainer.new()
	pick_row.add_theme_constant_override("separation", 20)
	_wait_box.add_child(pick_row)
	_wait_pick_a = UiFactory.menu_button("加入 A 队", 32, Vector2(240, 56))
	# ★ 用 `bind(队号)` 而不是两条匿名 lambda:绑定实参能被 `Callable.get_bound_arguments()`
	#   读出来 —— 两颗按钮的文案只差一个 A/B 字,对调之后**行为是错的且没有任何运行时信号**,
	#   只有"读实参"这条断言看得见(计数断言 `size() == 1` 对调后照样绿)。
	_wait_pick_a.pressed.connect(_on_wait_pick.bind(1))
	pick_row.add_child(_wait_pick_a)
	_wait_pick_b = UiFactory.menu_button("加入 B 队", 32, Vector2(240, 56))
	_wait_pick_b.pressed.connect(_on_wait_pick.bind(2))
	pick_row.add_child(_wait_pick_b)

	# 角色颜色行(仅 1v1 / 大乱斗)。★ 它住**等待室**而不是创建弹层里:创建弹层一进等待室
	# 就收起,放那儿等于"房主建完房改不了、加入者全程没见过"(设计 §3.4 的既有裁定)。
	_wait_hue = _add_hue_row(_wait_box, "自己角色颜色:", Vector2(320, 30), Vector2(46, 30))

	# 「开 始 游 戏」= 等待室的主行动 ⇒ gold 档;「退出房间」= 弱化档(与主菜单「退 出」同款).
	_wait_start = UiFactory.menu_button("开 始 游 戏", 32, Vector2(440, 64), "gold")
	_wait_start.pressed.connect(_on_wait_start_pressed)
	_wait_box.add_child(_wait_start)
	_wait_leave = UiFactory.menu_button("退出房间", 32, Vector2(440, 56), "quiet")
	_wait_leave.pressed.connect(_on_wait_leave_pressed)
	_wait_box.add_child(_wait_leave)

	# 居中锚点必须在**入树之后**设:未入树时父级尺寸为 0,面板会飞到屏幕左上角外
	# (两个旧页都踩过;与 `_build_join_panel` / `_build_create_panel` 同款)。
	_wait_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_wait_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wait_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# 亮起 / 重填等待室。★ **清空重填**而不是就地改几行:名单人数、分队、按钮显隐在三个模式下
# 都不同,就地改必然漏一处 —— 而漏了**不报错**,只是上一个模式的行留在屏上(叠成两批名单)。
func _show_wait_room(state: Dictionary, mode: String) -> void:
	if _wait_panel == null:
		_build_wait_panel()
	_wait_mode = mode
	# 进等待室时**同时**收起创建弹层。★ `_create_panel` 可能还没建过(玩家没点过
	#   「＋ 创建房间」),那时没什么可收 —— 守卫即可,别在 wait 一侧凭空建一个空弹层。
	if _create_panel != null:
		_set_create_visible(false)
	_wait_panel.visible = true
	# 进房 = 收起两颗入口按钮 + 关掉可能开着的加入弹层(见 `_create_btn` 上方那段:
	# 闸门拦不住直接绑定的弹层,层级会翻过来)。与 `_hide_wait_room` 成对。
	_in_room = true
	if _create_btn != null:
		_create_btn.visible = false
	if _join_btn != null:
		_join_btn.visible = false
	if _join_panel != null:
		_join_panel.visible = false
	_wait_title.text = _wait_title_text(state, mode)

	# ★ 必须 `remove_child` 再 `queue_free`:只 `queue_free` 的话旧行要到**帧末**才没,
	#   同帧重填会两批名单叠着(与 `_redraw_cards` 同款纪律)。
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
		# 1v1 的 `room_joined` 载荷只有 role ⇒ 名单不来自服务器;这句是**本侧**的事实陈述。
		_wait_count.text = "等待对手… 1 / 2"
	elif mode == PvpSession.MODE_ROYALE:
		_fill_flat_roster(plist, my_role, host_role)
		_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [
				plist.size(), int(state.get("max_players", 4))]
	else:
		_fill_team_roster(state, plist, my_role, host_role)
		_wait_count.text = _team_count_text(state, plist)

	# 角色颜色行:3v3 用**队色**、个人色相在本模式是无效输入 ⇒ 整行收起(设计 §0 第 12 条)。
	_wait_hue.visible = not is_team
	# 选边按钮(仅 3v3)。★ 自己那支的按钮**置灰**:既少一次无意义的上行,也让
	# 「已在该队时再点该队」那条幂等 wart(服务器回"该队已满"、状态不变)不可达。
	var my_team := _team_of_role(state, my_role) if is_team else 0
	_wait_pick_a.visible = is_team and my_team != 1
	_wait_pick_b.visible = is_team and my_team != 2
	# 「开始游戏」:1v1 **没有**这颗按钮(两人凑齐自动开局);3v3 还要求两队各满。
	if is_pvp:
		_wait_start.visible = false
	elif mode == PvpSession.MODE_ROYALE:
		_wait_start.visible = is_host
	else:
		_wait_start.visible = is_host and _both_teams_full(
				state, int(state.get("team_size", LobbyRooms.TEAM_SIZE)))


# 收起等待室。★ **唯一**调用点是 `_on_return_to_lobby()`(见那一处)。
# 不恢复创建弹层 —— 玩家要建房会自己再点「＋ 创建房间」(设计 §3.5)。
# ★★ 两颗入口按钮在这里**恢复**,与 `_show_wait_room` 的收起成对:`_in_room` 与它们同生命周期。
# ★ 顺序要求:大乱斗/3v3 的「退出房间」是 `rpc_id` 之后紧接一句 `_request_list.call_deferred(...)`
#   —— 本函数(经 `_on_return_to_lobby`)必须排在**那句之前**跑完。排反了,那次刷新会被
#   自己的闸门拒掉 ⇒ 列表永远不更新且**不报错**(`call_deferred` 到帧末才执行,故同函数内
#   "排在前面"就够)。
func _hide_wait_room() -> void:
	if _wait_panel != null:
		_wait_panel.visible = false
	_in_room = false
	if _create_btn != null:
		_create_btn.visible = true
	if _join_btn != null:
		_join_btn.visible = true


# 选边(3v3)。★ 连接时用 `bind(队号)`(见 `_build_wait_panel`):队号是被绑死的实参,
# 不是运行时从别处推的 —— 探针据此断言 A 队那颗绑的是 1、B 队那颗绑的是 2。
func _on_wait_pick(team: int) -> void:
	NetBusExt.rpc_id(1, "team_pick", team)


# 「开始游戏」:只有大乱斗 / 3v3 会画出这颗按钮(1v1 下它恒不可见 ⇒ 到不了那两支)。
func _on_wait_start_pressed() -> void:
	_status.text = "开局中…"
	if _wait_mode == PvpSession.MODE_ROYALE:
		NetBusExt.rpc_id(1, "royale_start")
	elif _wait_mode == PvpSession.MODE_TEAM:
		NetBusExt.rpc_id(1, "team_start")


# 「退出房间」。★ 三个模式**不同款**(照两个旧页逐字对齐):
#   · 1v1 —— **没有** leave RPC:旧页就是 `NetBus.stop()` 走人(断开即触发大厅
#            `on_peer_left` 清房)。基类 `_return_to_lobby` 正好是那条收口
#            (`NetBus.stop()` + 重连 + 刷新列表)。
#   · 大乱斗 / 3v3 —— 有 leave RPC,且**不能断大厅 peer**:断开会走 `on_peer_left`
#            那条**另一条**路径去关房,同一件事就有了两个实现(旧页的注释)。
#            ⇒ 只发 leave,然后走共用的页面清理(`_on_return_to_lobby`)+ 重拉列表
#            —— **不重连**,大厅 peer 还在。
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


# 标题:`—— {模式名}房间 {code} ——`;私密房追加邀请码。
# ★ 邀请码**只在私密时**印:公开房的载荷里 `invite_code` 可能是空串、也可能带着房主随手
#   填的值 —— 印出来会让玩家以为"这房要码"。
func _wait_title_text(state: Dictionary, mode: String) -> String:
	var code := str(state.get("code", ""))
	var invite := ""
	if not bool(state.get("is_public", true)):
		invite = "  邀请码 %s" % str(state.get("invite_code", ""))
	return "—— %s房间 %s ——%s" % [str(MODE_LABEL.get(mode, mode)), code, invite]


# 名单行(大乱斗:平铺)。
func _fill_flat_roster(plist: Array, my_role: int, host_role: int) -> void:
	var shown := 0
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		shown += 1
		_wait_body.add_child(_roster_row(shown, p, my_role, host_role))


# 名单行(3v3:两队 + 未选边三档)。★ 两队标题**恒出**(哪怕 0 人):"这局有 A、B 两队"
# 是规则、不是当前人数;缺了空队的标题,新来的玩家看不出该往哪边站。
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


# 一行名单。★ 编号印**行序**(`n`)而不是 role —— role 是「最小空闲号」分配、有人退出后
#   不重排,印 role 会出现 1、3(两个旧页都在这里踩过)。
# ★★ `set_meta("roster_row", true)` 是探针**数名单行**的唯一据点:没有它,断言只能靠
#    遍历所有 Label 猜,而标题 / 人数行 / 分队标题全是 Label —— 极易假绿。
func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role := int(p.get("role", 0))
	var l := UiFactory.label("%d. %s%s%s" % [n, str(p.get("name", "玩家")),
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	l.set_meta("roster_row", true)
	return l


# 我在这个房间里在哪一队。★ 判据来自服务器按 peer **单独**下发的 `your_role`
# (旧页注释:按**昵称**在名单里反查,两人同名时会命中先出现的那个 → 高亮错行、
# `_host` 判错 → 真房主看不到开局按钮)。
func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


# 两队各满(= 3v3 的开局闸门,与 `LobbyRooms.team_ready` 同义)。★ 分母引 `team_size`
# 而不是写 "3":容量只有一个真值来源,写死的话 `TEAM_SIZE` 一改这行就**撒谎**且不报错。
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


# 1v1 的等待室载荷:1v1 **没有** `room_state` 这条下行载荷(`room_created` 只给房号、
# `room_joined` 只给 role),故在本侧拼一份最小形状 —— 与大乱斗/3v3 共用**同一个**
# `_show_wait_room`,而不是给 1v1 单开一条渲染路径(那正是本次要消灭的重复)。
func _pvp_wait_state(code: String, role: int) -> Dictionary:
	return {
		"code": code,
		"is_public": true,   # 1v1 没有私密房这条路径
		"players": [],       # 1v1 不画名单(设计 §3.5:`等待对手… 1 / 2`)
		"your_role": role,
		"host_role": role,
	}


# ── 转连与超时梯 ────────────────────────────────────────────────────

# ★★ 判据必须是**本页的 `_current_mode`**(我当前所在那间房的模式),**不是**
#   `PvpSession.room_mode`。后者是**凭据**的模式(供列表里判"这一行是不是我的房"),
#   它在"建了房但 `note_room` 还没跑到"这一档上是**空串**。
#   ⇒ 两个量语义不同,不要合并成一个字段。
# ★ 两页**刻意不同**的那条纪律现在按 `_current_mode` 分派(设计 §3.1.2):
#   1v1 直切;大乱斗/3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内
#   到达,栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
# ★★ `else` 那一支**刻意什么都不做、只 `push_error`**,不默认切任何一个场景。
#    理由:本函数有三条进入路径(建房 / 加入 / 回局),任何一条漏记 `_current_mode` 都会
#    落到这里 —— 那时"切一个默认场景"是**静默的错值**(玩家进了错的对局场景,只是看起来怪),
#    而"留在原地 + 一条红"是**响的**。本仓的取向一贯是前者不可接受。
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


# 梯顺序 `[worker → claim → 大厅 → ack]`(合并后唯一的一条;见文件头)。
# ★ 别重排:1v1 旧页那条 join 梯的职责由末尾的 ack 梯覆盖(建房/加入 8s 无应答)。
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
		# 8s **一个字都没回** ⇒ 这一次加入到此为止,多表闸门一并复位(见 `_claim_multi_reply`)。
		_probe_multi_join = false
		_multi_left = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"


# ── 基类钩子(本页实现)────────────────────────────────────────────────

# 空地址回退:取会话里的服务器地址(不再特判本机)。
func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


# 已在房间中(先退出房间再操作):`_with_lobby` 在 `_in_room` 时拒绝一切操作
# (列房 / 建房 / 加入)—— 不清房间态,玩家就再也刷不出列表、建不了房(两个旧页同款)。
# ★ 三个模式的文案**各自点名**(照旧页逐字同形):本页三模式共用一张列表,一句通用的
#   "已在房间里"会让玩家看不出自己卡在哪个模式的房里。
# ★★ 这道闸门**只挡得住最后那一次 RPC** —— 「＋ 创建房间」/「加入房间」两颗按钮由
#   `_show_wait_room` 直接收起(见 `_create_btn` 上方那段),两半缺一不可。
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


# 三个模式的权威规则项都上发,worker 各取自己认得的键(`server_main._on_player_options`
# 与 `MatchBootstrap` 都按 role1 那份生效)。不认得的键被静默忽略 —— 这是既有行为。
# ★ `time`(Beta 时间玩法规则)必须在这里 —— 它是**权威那一份**:worker 侧
#   `MatchHost` 读的正是 `options.get("time")`(见 server/match/match_host.gd),
#   而建房载荷里的 `time` 只存在房对象上、**没有任何读者**。漏了它 ⇒ Beta 局的时间经济
#   静默为空(一切结算短路),而那**不报错**。旧的两个大厅页各自带这一行
#   (大乱斗页 / 3v3 页),统一页不能把它丢了。
# ★★ **1v1 必须排除 `time`** —— 这是大厅**统一之后才出现的新路**:`PvpSession.beta_mode`
#   是**会话级**的,而统一大厅让 Beta 会话里的玩家能切到 1v1 建局。但 1v1 的
#   `create_room(caller)` 是原版 NetBus 的**冻结签名**、载荷里没有任何 beta 标记
#   ⇒ 那个房**没法按 beta 隔离** ⇒ 一个**没勾 Beta 的普通玩家能加进来、打上一局带时间经济
#   的 1v1**。设计里 Beta 页只有「错乱大乱斗」「时空 3v3」两张卡、**没有 1v1 beta**,
#   故 1v1 在 Beta 会话里退回普通局才是与"1v1 无法被隔离"这个事实一致的行为。
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict() if (PvpSession.beta_mode
				and _current_mode != PvpSession.MODE_PVP) else {},
	}


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"


func _on_worker_connect_failed() -> void:
	if _connecting_worker:
		_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")


func _worker_timeout_msg() -> String:
	# ★ 大乱斗 / 3v3 都是**自建服**(要自己放行 worker 端口段)⇒ 把端口段印出来是真信息;
	#   1v1 走云服,那句提示对它没有意义。端口段引 WorkerLauncher 的常量,不手写数字
	#   (旧页手写过 "7800~7999" 而实际池是 7800~8299 —— 照它放行防火墙会漏掉半个池子)。
	if _current_mode == PvpSession.MODE_ROYALE or _current_mode == PvpSession.MODE_TEAM:
		return "对局服务器无响应——请确认对局端口(%s UDP)已放行;已返回大厅并刷新" % _worker_port_span()
	return "对局服务器无响应(房间可能已失效)——已返回大厅并刷新,请换一个房间"


# worker 端口段文案(单一来源 = WorkerLauncher 的常量)。
func _worker_port_span() -> String:
	return "%d~%d" % [WorkerLauncher.WORKER_PORT_BASE,
			WorkerLauncher.WORKER_PORT_BASE + WorkerLauncher.WORKER_PORT_SPAN - 1]


func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间"


# 配对成功:停掉建房/加入的 ack 兜底,转由转连 worker / claim 两条梯接管。
func _on_go_match_extra() -> void:
	_sent_ms = 0


func _on_return_to_lobby() -> void:
	_sent_ms = 0
	_probe_multi_join = false
	# ★★ 等待室在这里收起 —— 这是它**唯一**的调用点:转连/claim 超时梯、回局失败、
	#    大乱斗/3v3 的「退出房间」全都汇到本钩子。漏了它 = 退回大厅后等待室还盖在屏幕上
	#    (而**一行报错都没有**),玩家以为"还卡在房里"。
	_hide_wait_room()


# 换服务器重连:清掉旧列表(旧房间号在新服上必然「房间不存在」)。
func _on_lobby_reconnect() -> void:
	_rooms_by_mode.clear()
	_redraw_cards()
