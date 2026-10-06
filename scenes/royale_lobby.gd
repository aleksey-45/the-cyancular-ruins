extends LobbyPage

# 大乱斗大厅(RoyaleServer 分支):建房(公开/私密+邀请码+人数上限)/公开房间列表点击加入/
# 等待室实时成员列表 + 房主开局。自建服务器(RoyaleHost 死斗 worker)。
# 协议走 NetBusExt(royale_* 系列);开局复用原版 go_match(role,port) 转连 worker。
# 视觉项(小地图/轨迹/血条/颜色)沿用「1v1」设置(Settings.pvp_*),此处不重复摆放。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# 连接状态机 / 转连 worker / 按钮工厂都在基类 `LobbyPage` 里(与 1v1 匹配页共用)——
# 本文件只留大乱斗的差异:版式、建房与等待室两个面板、房间态渲染、超时梯顺序。

const WEAPON_NAMES := {1: "手枪", 2: "步枪", 3: "重狙", 4: "霰弹", 5: "榴弹"}

var _royale_ack := true       # 建房/加入后是否已收到服务器 royale_room_state
var _royale_sent_ms := 0

# ── 建房面板控件 ──
var _max_slider: HSlider
var _max_label: Label
var _weapon_checks: Array[CheckButton] = []

# ── 等待室 ──
var _wait_panel: PanelContainer = null
var _create_panel: PanelContainer = null   # 右列创建面板(进等待室时隐藏)
var _wait_title: Label
var _wait_players: VBoxContainer
var _wait_count: Label
var _start_btn: Button
var _in_room := false
var _my_room := {}     # 最近一次 royale_room_state
var _host := false


func _ready() -> void:
	# 根 Control 默认尺寸 0×0:居中面板(PRESET_CENTER)按零尺寸父级计算会飞到屏幕外
	# (自检实测等待室在 (-320,-149));设满矩形锚点让根铺满 1920×1440 视口
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()

	# ── 左列 = **入口区**:昵称 / 房号 / 建房 / 加入 / 状态,聚成一块(三页同坐标)──
	# ★★ 2026-09-30 用户裁定:入口控件必须**聚在一起**;原来那套"加入沉到页面底部
	#   (y=812)、离昵称八百像素"的散版式废弃。右列只剩**设置**(不再承担"创建"那颗按钮)。
	#   各页右列的设置内容不同是**真差异**,保留。
	var name_le := UiFactory.line_edit(self, Vector2(60, 60), Vector2(320, 52), "昵称(排行榜显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	# 房号:没房时填对手的码、有房时显示自己的码并把框设为只读(见 `_update_code_label`)
	_code_edit = UiFactory.line_edit(self, Vector2(60, 124), Vector2(320, 52), "房间号", "")
	# 建房 / 加入:两颗**等宽等高**,与上面两行一起构成三行等高的入口块
	_create_btn = _page_button("建房", Vector2(60, 188), Vector2(154, 52), _on_create_pressed)
	_join_btn = _page_button("加入", Vector2(226, 188), Vector2(154, 52), _on_join_pressed)

	_status = UiFactory.label("", 16, UiFactory.C_TEXT)
	_status.position = Vector2(60, 260)
	_status.size = Vector2(900, 110)
	add_child(_status)

	# ★ 2026-09-30 删除「刷新列表」按钮(用户裁定:没用;理由见 `LobbyPage` 同名处)、
	#   顶部那条「房间码:——(建房后显示)」标签(房间码改在「房间号」框里显示、进房后只读)、
	#   以及那行提示文字(它说的"填进下面点加入"已随入口区聚拢而失效)。
	#   ★ 同日再改:标题与空态文案**字号互换**(标题 32、空态 16),标题改叫「房间列表」。
	var cap := UiFactory.label("房间列表", 32, UiFactory.C_TEXT_DIM)
	cap.position = Vector2(60, 376)
	cap.size = Vector2(700, 42)
	add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 426)
	scroll.size = Vector2(680, 430)
	add_child(scroll)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(640, 0)
	scroll.add_child(vb)
	_list_box = vb

	var back := _page_button("返回主菜单", Vector2(60, 1000), Vector2(200, 48), func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	_build_create_panel()

	# ── 本页专属信号(其余共用信号在 _finish_lobby_ready 里接)──
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state)

	_finish_lobby_ready()


# ── 建房面板(右列)──
func _build_create_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(1000, 60)
	panel.custom_minimum_size = Vector2(620, 0)
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	add_child(panel)
	_create_panel = panel   # 成员引用:进等待室时隐藏、退房恢复
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	vb.add_child(UiFactory.label("—— 创建大乱斗房间%s ——" % (" · Beta 时间玩法" if PvpSession.beta_mode else ""), 32, UiFactory.C_ACCENT))
	_build_max_players_row(vb)
	_build_match_time_row(vb)

	_add_map_picker(vb)
	_add_time_params(vb)

	vb.add_child(UiFactory.label("禁用武器(房主生效,开局带进对局):", 32))
	_add_weapon_grid(vb, 10, func(cell: Node, slot: int) -> void:
		# 本页要多记一笔:建房时读 _weapon_checks 的勾选态(1v1 页不留引用,直接读 Settings)
		var cb: CheckButton = cell.get_meta("cb")
		cb.set_meta("slot", slot)
		_weapon_checks.append(cb))

	# (自己角色颜色的选色行 D1 已**搬进等待室面板** —— 原先在这里,建房面板一进等待室就
	#  隐藏,于是"房间里没人能改颜色":房主建房后就看不到了,加入者从头到尾没见过。
	#  选色现在对**全员**开放在等待室里,开局 claim 时随 player_options 上发生效。)

	vb.add_child(UiFactory.label("(小地图/轨迹/血条等其余视觉项沿用「1v1」设置;\n复活一律满血,一局 5 分钟,击杀最多者胜)", 16, UiFactory.C_TEXT_DIM))

	# ★ 2026-09-30:这一面板现在**只是设置**(「建房」已搬到左列入口区)——
	#   与另两页同构:左列管"开一局/加入",右列管"这一局怎么打"。


# ── 建房面版的设置行(阶段 5.5:原先 _build_create_panel 是 69 净行的"一屏控件清单")──
# ★ 2026-09-29:原先这里还有一行「公开房间(不勾选 = 私密,凭邀请码进入)」+ 一个邀请码输入框,
#   已整体删除 —— 房间码本身就是隧道的 network-secret,能连上这台服务器的人必然已经知道它,
#   私密房那道"再对一个码"挡不住任何人,只给房主添一道手续。


func _build_max_players_row(vb: VBoxContainer) -> void:
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 14)
	vb.add_child(mrow)
	mrow.add_child(UiFactory.label("人数上限:", 32))
	_max_slider = HSlider.new()
	_max_slider.min_value = 2
	_max_slider.max_value = 8
	_max_slider.step = 1
	_max_slider.value = 4
	_max_slider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(_max_slider)
	_max_slider.value_changed.connect(func(v: float) -> void:
		_max_label.text = "%d 人" % int(v))
	mrow.add_child(_max_slider)
	_max_label = UiFactory.label("4 人", 32, UiFactory.C_TEXT)
	mrow.add_child(_max_label)


# 一局限时(分钟):房主可调 1~15 分钟(默认 5);随房主报到 opts 带入 RoyaleHost
func _build_match_time_row(vb: VBoxContainer) -> void:
	var trow := HBoxContainer.new()
	# 键是 "separation":HBox 只认它,h_separation 是 GridContainer 的键(写在这里会被存下但
	# 永不读取 = 死覆盖)。别照抄禁用武器网格那两行 —— 那个是 GridContainer,键不一样。
	trow.add_theme_constant_override("separation", 12)
	vb.add_child(trow)
	trow.add_child(UiFactory.label("一局限时:", 32))
	var tslider := HSlider.new()
	tslider.min_value = 1.0
	tslider.max_value = 15.0
	tslider.step = 1.0
	tslider.value = Settings.royale_match_min
	tslider.custom_minimum_size = Vector2(300, 30)
	UiFactory.style_slider(tslider)
	trow.add_child(tslider)
	var tlabel := UiFactory.label("%d 分钟" % int(Settings.royale_match_min), 32, UiFactory.C_TEXT)
	trow.add_child(tlabel)
	tslider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		tlabel.text = "%d 分钟" % int(v))


# ── 动作 ──
# 建房 = **在自己这台机器上开服 + 建房**(没有"在别人电脑上建房"这回事)。
# ★ 2026-09-30:前置判据换成"连着的是不是我那台"(`LobbyPage._ensure_own_server`)——
#   原判据是"有没有连着",于是客机点建房会把建房 RPC 发给房主的服务器。
func _on_create_pressed() -> void:
	# ★★ 顺序不能反:**先**过"能不能操作"这一关,**再**动服务端与隧道。
	#   `_ensure_own_server()` 是无条件"拆旧起新"(建房 = 整套全新),在房里按建房会先把
	#   **当前这局**的服务端与隧道拆掉,而随后 `_with_lobby` 才拿 `_lobby_action_allowed()`
	#   拒绝 ⇒ 房间没了、新房间也没建出来(2026-10-01 用户实测:日志里"服务端/隧道被拆"
	#   之后就没有任何建房动静了)。守卫:`tests/netplay_probe.gd` 的建房顺序断言。
	if not _lobby_action_allowed():
		return
	if not await _ensure_own_server():
		return
	var disabled: Array = []
	for cb in _weapon_checks:
		if cb.button_pressed:
			disabled.append(int(cb.get_meta("slot", 0)))
	_with_lobby(func() -> void:
		_status.text = "建房中…"
		_royale_ack = false
		_royale_sent_ms = Time.get_ticks_msec()
		var payload := {
			"max_players": int(_max_slider.value),
			"round_full_heal": false,
			"disabled_weapons": disabled,
		}
		payload.merge(_beta_payload())   # Beta 态追加 {"beta":true,"time":{...}};普通态空合入
		NetBusExt.rpc_id(1, "royale_create", payload))

func _on_join_pressed() -> void:
	_join_room(_code_edit.text.strip_edges())

func _join_room(code: String) -> void:
	# 没连着服务端时把房间码当**远程**入口(起隧道 → 找到房主 → 连上去),见
	# `LobbyPage._join_with_code` 的两条路。
	_join_with_code(code, func() -> void:
		_status.text = "加入房间 %s …" % code
		_royale_ack = false
		_royale_sent_ms = Time.get_ticks_msec()
		NetBusExt.rpc_id(1, "royale_join", code, PvpSession.beta_mode))


# ── 服务器回复 ──
# 列表区的空态(**基类 `_show_empty_list` 的实现**):清空 + 放一条说明。
# ★ 与 `_on_royale_rooms` 的空分支**同一份文案**:那条走"大厅答了但一间都没有",
#   这条走"根本没连上、不去拉"(首屏最常见的那一屏 —— 以前这里是一片空白)。
func _show_empty_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var empty := UiFactory.label("还没有房间 —— 点「建房」开一局", 16, UiFactory.C_TEXT_DIM)
	empty.custom_minimum_size = Vector2(620, 40)
	_list_box.add_child(empty)


func _on_royale_rooms(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		var empty := UiFactory.label("还没有房间 —— 点「建房」开一局", 16, UiFactory.C_TEXT_DIM)
		empty.custom_minimum_size = Vector2(620, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个房间(对局中的照列:自己的房可点(回局),别人的点不动)"
		return
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		# Beta 房与普通房互不可见(独立房间池的客户端侧;服务器侧 join 守卫是第二道)
		if bool(r.get("beta", false)) != PvpSession.beta_mode:
			continue
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var maxp := int(r.get("max_players", 4))
		# ★ 对局中的房**照列**但**点不动**(与 1v1 页同款:可见性与拒绝入房是同一件事的两半;
		#   服务端 `royale_join` / `team_join` 的 in_match 守卫才是那道保证)。
		# ★ 自己那间房是这一档的**唯一例外**(持凭据者点它 = 回局)—— 见紧随其后那一段。
		var in_match := bool(r.get("in_match", false))
		var occ := ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   " + ", ".join(names)
		var btn := UiFactory.button("房间 %s      %s%s" % [code,
				"对局中" if in_match else "%d/%d" % [players, maxp], occ], 32, Vector2(620, 46))
		# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**,这一档**可点**(点了走回局);
		#    不是我的房,才轮到「对局中 ⇒ disabled」那一档(前置计划交付的既有行为)。
		#    反过来写(先按 in_match 禁用)= 回局这一档连点都点不到,而**一行报错都没有**
		#    —— 表现只是"回到大厅后自己那间房是灰的,回不去"。
		var mine := PvpSession.can_rejoin_to(code)
		btn.disabled = in_match and not mine
		if btn.disabled:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.focus_mode = Control.FOCUS_ALL
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				# 我的房**且对局中** ⇒ `try_rejoin_row` 自己走回局并返回 true;否则走普通加入
				# ★ `in_match` 必须传进去(I2):自己那间**还没开局**的等待室要走普通加入。
				if not try_rejoin_row(code, in_match):
					_join_room(code))
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(对局中的照列:自己的房可点(回局),别人的点不动)" % rooms.size()

# 房间实时状态 → 等待室面板
func _on_room_state(state: Dictionary) -> void:
	_in_room = true
	_royale_ack = true
	_my_room = state
	# ★ 记下自己这间房的房号(与 1v1 页 `_on_room_created`/`_on_room_joined` 同款):列表里那一行
	#   "是不是我的房"全靠它比(`can_rejoin_to`)。本页建房 / 点列表加入 / 填邀请码三条路
	#   **都只经这一个 handler**,故这一行就是本页唯一的记账点 —— 漏了它,回局入口对本页
	#   整个失效(房号恒空 ⇒ 自己那间房被当"别人的房"禁用),而**一行报错都没有**。
	# ★ 走 `note_room()` 而不是直接赋值:它顺手把**上一间房**的凭据作废(换了房号时)——
	#   等待室每收到一次房间状态都会走一遍本函数,同号时它是 no-op(见 `note_room` 的注释)。
	var code := str(state.get("code", ""))
	PvpSession.note_room(code)
	_room_code = code
	_update_code_label()
	var my_role := _my_role_in(state)
	_host = int(state.get("host_role", 0)) == my_role
	# ★ 房主建房后把隧道拉起来(房主的第三步,见 docs/netplay.md 的总览):房间码就是隧道网络名
	#   的输入,而客机要靠隧道才找得到这台机器。
	# ★★ 2026-09-30 修:闸门原为 `not Tunnel.is_running()` —— 本函数**每收到一次房间状态就会跑一遍**,
	#   原注释的理由("重起会把已经连进来的客人一起踢掉")对**同一间房的状态刷新**是对的,
	#   对**换了房号**是错的:房主退出房间再建一间时,`is_running()` 仍为真 ⇒ 网名**留在旧码上**
	#   ⇒ 房主手里的新码对外**完全失效**(朋友拿新码进的是 `cyr-<新码>`,那网上没人)。
	#   闸门改成"本端已经在**这串码对应的网**上了吗"(`on_network`):同码不重起、换码才重起。
	if _host and not Tunnel.on_network(code) and Tunnel.available() and PvpSession.server_port > 0:
		Tunnel.start_host(PvpSession.server_port, code)
		_update_code_label()
	if _create_panel != null:
		_create_panel.visible = false   # 进等待室:隐藏右列设置面板(与等待室并存太挤)
	_set_entry_buttons_enabled(false)   # ★ 建房/加入置灰(不隐藏 —— 入口位置保留)
	# ★ 状态栏换成**明确的成功反馈**:房主"已创建 + 把房号报出去",加入者"已加入"。
	#   2026-10-01 用户实测反馈:进房后状态栏是空的,看不出这一步到底成没成。
	_set_room_entered_status(code, _host)
	if _wait_panel == null:
		_build_wait_panel()
	_wait_panel.visible = true
	_wait_title.text = "—— 大乱斗房间 %s ——" % code
	for c in _wait_players.get_children():
		c.queue_free()
	var plist: Array = state.get("players", [])
	var shown := 0   # 行序(1..N)——见下面那条注释:不能直接印 role
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var role := int(p.get("role", 0))
		var nm := str(p.get("name", "玩家"))
		var is_me := role == my_role
		var is_host := int(state.get("host_role", 0)) == role
		shown += 1
		# ★ 编号印**行序**,不印 role:role 是「最小空闲号」分配、且**有人退出后不重排**
		#   (这是 --roles 协议的前提,权威 role 保持稳定以便服务端校验角色连接合法性),直接显示会跳号 ——
		#   3 人房中间那位退出 → 等待室显示 1、3(界面优化需求)。
		#   编号只是界面序号,与权威 role 脱钩;行序 = rr.players 的加入顺序。
		var row := UiFactory.label("%d. %s%s%s" % [shown, nm, "(我)" if is_me else "", "(房主)" if is_host else ""],
				32, UiFactory.C_TEXT if not is_me else UiFactory.C_ACCENT)
		_wait_players.add_child(row)
	_wait_count.text = "%d / %d 人(至少 2 人可开局)" % [plist.size(), int(state.get("max_players", 4))]
	_start_btn.visible = _host

# 我在这个房间里是几号。★ 服务器按 peer **单独**下发的 `your_role`(见 lobby_rooms 的
# _flush_royale_state)—— 原先按**昵称**在名单里反查,两人同名(默认都叫 Anon)时会命中
# 先出现的那个 → (我)/(房主) 高亮错行、`_host` 判错 → 真房主看不到开局按钮。
func _my_role_in(state: Dictionary) -> int:
	return int(state.get("your_role", 0))

func _build_wait_panel() -> void:
	_wait_panel = PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(640, 0)
	_wait_panel.add_child(vb)
	_wait_title = UiFactory.label("", 32, UiFactory.C_ACCENT)
	vb.add_child(_wait_title)
	_wait_players = VBoxContainer.new()
	_wait_players.add_theme_constant_override("separation", 8)
	vb.add_child(_wait_players)
	_wait_count = UiFactory.label("", 32, Color(0.8, 0.85, 0.9))
	vb.add_child(_wait_count)
	# 自己角色颜色(D1,2026-09-29):等待室全员可改 —— 原先滑条只在建房面板,建房面板一进
	# 等待室就隐藏 ⇒ 房主建完房改不了、加入者全程没见过,"房间里自定义颜色"形同虚设。
	# 值即选即存 Settings.pvp_color_hue;开局转连 worker 时随 player_options 上发
	# → 服务器 _claim_hues 汇总 → match_sync 回包 → 自己(本地直染)与所有副本(他人视角)都按它染色。
	# (网络端到端测试已验证双向参数传递，见 tests/royale_probe.gd 的 hues 断言。)
	vb.add_child(UiFactory.label("自己角色颜色(开局生效,所有人可见):", 32))
	_add_hue_row(vb, "", Vector2(320, 30), Vector2(46, 30))
	_start_btn = UiFactory.button("开 始 游 戏", 32, Vector2(360, 56))
	_start_btn.pressed.connect(func() -> void:
		_status.text = "开局中…"
		NetBusExt.rpc_id(1, "royale_start"))
	vb.add_child(_start_btn)
	var leave := UiFactory.button("退出房间", 32, Vector2(360, 48))
	leave.pressed.connect(_on_leave_room)
	vb.add_child(leave)
	add_child(_wait_panel)
	# 居中锚点必须在入树之后设置:未入树时父级尺寸为 0,面板会飞到屏幕左上角外(自检实测)
	_wait_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_wait_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wait_panel.grow_vertical = Control.GROW_DIRECTION_BOTH

func _on_leave_room() -> void:
	NetBusExt.rpc_id(1, "royale_leave")
	_in_room = false
	_my_room = {}
	# ★ 2026-09-30:退房要把「房间号」框交还给玩家 —— 清了 `_room_code` 它才恢复可编辑,
	#   否则框会一直卡在只读的旧码上(下一间房的码没处填)。
	_room_code = ""
	_update_code_label()
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true   # 退房恢复设置面板
	_set_entry_buttons_enabled(true)   # 建房/加入恢复可用
	_request_list.call_deferred("已退出房间")


# 转连 worker 12s 没连上(worker 死了/端口没放行)→ 回大厅重连 + 刷新列表;
# claim 后 25s 仍没 match_start(worker 中途死掉/对局没起来)同样回大厅。
# ★ 本页的梯顺序是 [回局 → claim → 大厅 → ack];**别重排**。
func _process(_delta: float) -> void:
	# 0) 回局(路径乙):请求发出后大厅 15s 无应答 —— 早于下面几条梯,因为此刻它们都还没启动
	if _tick_rejoin_timeout():
		return
	# 1) claim 后 25s 仍没 match_start(对局没起来):回大厅重连刷新
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	# 建房/加入 8s 无应答(对端没回应 / 版本不一致)
	if not _royale_ack and _royale_sent_ms > 0 and Time.get_ticks_msec() - _royale_sent_ms > 8000:
		_royale_sent_ms = 0
		_status.text = "8 秒无响应 —— 房主那边没回应,或双方版本不一致(请都用最新版)"


# ── 基类钩子(本页实现)────────────────────────────────────────────

# 已在大乱斗房间中(先退出房间再操作):_with_lobby 在 _in_room 时拒绝一切操作,
# 不清房间态就再也刷不出列表/建不了房。
func _lobby_action_allowed() -> bool:
	if _in_room:
		_status.text = "已在大乱斗房间中(先退出房间再操作)"
		return false
	return true


func _send_list_request() -> void:
	NetBusExt.rpc_id(1, "royale_list")


# 大乱斗多一项 match_time(一局限时),回合回血恒 false(大乱斗规则里没有回合)
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": false,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
		"time": time_rules.to_dict() if PvpSession.beta_mode else {},
	}


func _go_match_status() -> String:
	return "开局!进入对局……"


func _claim_timeout_msg() -> String:
	return "对局无响应(对局可能已结束)——已回到房间列表并刷新,请重试"


# 清房间态是必须的:_with_lobby 在 _in_room 时拒绝一切操作,不清就再也刷不出列表/建不了房。
func _on_return_to_lobby() -> void:
	_in_room = false
	_my_room = {}
	if _wait_panel != null:
		_wait_panel.visible = false
	if _create_panel != null:
		_create_panel.visible = true
	_set_entry_buttons_enabled(true)


# RPC 在 NetBus.poll 调用栈内到达(worker→客户端 match_start);直接在栈内切场景会
# 在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(与 go_match 同款,曾实测)。
# 延迟到帧末再切;改版后大乱斗建房→加入→开局→进图全链路须重测。
func _enter_match_scene() -> void:
	get_tree().call_deferred("change_scene_to_file", "res://scenes/royale_game.tscn")
