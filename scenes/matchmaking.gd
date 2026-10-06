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

var _auto_refreshed := false   # 「点了看起来未满却已满/已失效的房」后只自动刷新一次(见 _on_server_message)
var _join_sent_ms := 0     # 刚发出 join_room 的时间戳:服务端无任何应答(幽灵房间)时兜底回大厅刷新
# 刚请求加入的房号,**等服务端答"成功"了才写进 `PvpSession`**(见 `_on_room_joined`;I1)
var _join_code_pending := ""


func _ready() -> void:
	_add_lobby_background()

	# ── 左列 = **入口区**:昵称 / 房号 / 建房 / 加入 / 状态,聚成一块(三页同坐标)──
	# ★★ 2026-09-30 用户裁定:入口控件必须**聚在一起**(昵称、房号、建房、加入、状态一块儿),
	#   不要 royale/team 那套"加入沉到页面底部、离昵称八百像素"的散版式。
	#   ⇒ 以本页原版式为基准,另两页向它对齐;**右列只剩设置**(不再承担"创建"那颗按钮)。
	#   右列面板的内容差异保留：1v1 为对战选项开关组，
	#   大乱斗包含人数上限、单局限时与时间粒子规则，3v3 采用预设配置。
	var name_le := UiFactory.line_edit(self, Vector2(60, 60), Vector2(320, 52), "昵称(头上显示)", PvpSession.player_name)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	# 房号:没房时填对手的码、有房时显示自己的码并把框设为只读(见 `_update_code_label`)
	_code_edit = UiFactory.line_edit(self, Vector2(60, 124), Vector2(320, 52), "房间号", "")

	# 建房 / 加入:两颗**等宽等高**,与上面两行一起构成三行等高的入口块。
	# ★ 2026-09-30 用户裁定:三行同高 52、块宽 320;建房原 200×48、加入原 140×48(大小不一)。
	_create_btn = _page_button("建房", Vector2(60, 188), Vector2(154, 52), _on_create_pressed)
	_join_btn = _page_button("加入", Vector2(226, 188), Vector2(154, 52), _on_join_pressed)

	_status = UiFactory.label("", 16, UiFactory.C_TEXT)
	_status.position = Vector2(60, 260)
	_status.size = Vector2(900, 110)
	add_child(_status)

	# ★ 2026-09-30 用户裁定:标题与空态文案**字号互换**(标题 32、空态 16),标题改叫「房间列表」。
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

	_page_button("返回主菜单", Vector2(60, 1000), Vector2(200, 48), _on_back_pressed)

	_build_options_panel()

	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBus.local_room_list.connect(_on_room_list)

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
	panel.position = Vector2(1000, 60)          # 与另两页同坐标
	panel.custom_minimum_size = Vector2(620, 0)  # 同宽
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

	# 选图(房主生效):三页共用基类那一节
	_add_map_picker(vb)

	# 禁用武器(房主生效):2 列网格 + 定尺寸剪影(横排会溢出屏幕)
	vb.add_child(UiFactory.label("禁用武器(房主生效):", 32, UiFactory.C_ACCENT))
	_add_weapon_grid(vb, 26)   # 26:剪影是长条形,列挨太近会与邻列挤在一起(本页版式值)

	# 角色颜色(色相 0-360,即选即用,双方各自染自己)
	_add_hue_row(vb, "自己角色颜色:", Vector2(280, 24), Vector2(48, 24))

	# ★ 2026-09-30:本面板**只是设置**(「建房」在左列入口区,与昵称/房号/加入聚在一起)——
	#   与另两页同构:左列管"开一局/加入",右列管"这一局怎么打"。
	#   (今天早些时候这里曾短暂放过一颗「创 建 房 间」按钮,随入口区聚拢一并撤掉。)


# ★ 2026-09-30 删除本页的「刷新」按钮与其覆写(用户裁定:没用;理由见 `LobbyPage` 同名处)。
#   `_auto_refreshed` **保留** —— 它服务的是另一件事:点了一间"看起来未满却已满/已失效"的房
#   之后,只自动刷一次列表(避免连点连刷)。那道闸现在只在「建房」时放开
#   (没有手动刷新了,而建房本来就是"用户明确要重来"的那个动作)。


# 列表区的空态(**基类 `_show_empty_list` 的实现**):清空 + 放一条说明。
# ★ 文案里的按钮名必须与**实际标签**逐字一致 —— 建房那颗按钮就叫「建房」
#   (2026-09-30 起三页同名),引成「建房」就是一条悬空引用。
func _show_empty_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	# ★ 2026-09-30 用户裁定:与页面上方「房间列表」标题**字号互换** —— 标题 32、空态 16。
	_list_box.add_child(UiFactory.label("还没有房间 —— 点「建房」开一局", 16, UiFactory.C_TEXT_DIM))


# 建房 = **在自己这台机器上开服 + 建房**(没有"在别人电脑上建房"这回事)。
# ★ 2026-09-30:前置判据换成"连着的是不是我那台"(`LobbyPage._ensure_own_server`)——
#   原判据是"有没有连着",于是**客机点建房会把建房 RPC 发给房主的服务器**
#   (详见那个函数的注释:会开出一间谁也进不来的死房,并把客机自己的连接弄断)。
func _on_create_pressed() -> void:
	# ★★ 顺序不能反:**先**过"能不能操作"这一关,**再**动服务端与隧道(与另两页同款)。
	#   `_ensure_own_server()` 是无条件"拆旧起新",在房里按建房会先把当前这局的
	#   服务端与隧道拆掉,随后 `_with_lobby` 才拒绝 ⇒ 房间没了、新的也没建出来。
	if not _lobby_action_allowed():
		return
	if not await _ensure_own_server():
		return
	_auto_refreshed = false   # 新开一局:放开「只自动刷新一次」的闸门
	_with_lobby(func() -> void:
		NetBus.rpc_id(1, "create_room")
		_status.text = "建房中…(拿到房间码后告诉对手)")


func _on_join_pressed() -> void:
	_join_code(_code_edit.text.strip_edges())


# 加入某房间码(手动输入或点房间列表)。
func _join_code(code: String) -> void:
	# ★★ 房号**只暂存**,等服务端答"加进去了"才写进 `PvpSession`(`_on_room_joined`)——
	#   这就是 I1:原先在**发 RPC 之前**写,于是任何一次**失败**的加入(房间已满 /
	#   对局已进行中 / 敲错房号)都会把 `room_code` 留成**别人的**那间房,此后
	#   `can_rejoin_to(我自己的房)` 恒 false ⇒ **自己那间房那一行永远是灰的**,
	#   且没有任何操作能把它恢复(要等下一次成功加入)。
	_join_with_code(code, func() -> void:
		_join_code_pending = code
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
		# ★ 对局中的房 players 记的是**冻结名单**的条数(1v1 恒 2)→ 自然落进 full 那一档排到最后,
		#   正是想要的观感(在打的排最后,可加入的排前面),不需要为它另写一条排序。
		(full if int(r.get("players", 2)) >= 2 else partial).append(r)
	var order: Array = partial + full
	if order.is_empty():
		var empty := UiFactory.label("还没有房间 —— 点「建房」开一局", 16, UiFactory.C_TEXT_DIM)
		empty.size = Vector2(600, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个房间"
		return
	for r in order:
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		# ★ 对局中的房**照列**但**点不动**(用户要求:"所有人都可以看到所有房间(包括游戏已经
		#   进行的房间)…无论在对战还是掉线 C 都不应该进去")。服务端 `join_room` 那边也拒
		#   (`room.started`)—— **两半都要**:`disabled` 是体验,服务端那道才是保证
		#   (在「房间号」框里手敲房号、或旧客户端绕过界面,照样进不去)。
		# ★ 自己那间房是这一档的**唯一例外**(持凭据者点它 = 回局)—— 见紧随其后那一段。
		var in_match := bool(r.get("in_match", false))
		var occ: String = ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   玩家: " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s    %s%s" % [code, "对局中" if in_match else "%d/2" % players, occ]
		UiFactory.style_control(btn, 16)
		UiFactory.style_row_button(btn)
		btn.custom_minimum_size = Vector2(600, 46)
		# 左对齐:房间号是定宽段(「房间」+定长码),人数也是定宽段,故左对齐后
		# 两行的房间号列 / 人数列天然对齐。原先居中排版,行的长短一变整串就跟着左右漂
		# ——「1/2」在两行里位置都不同,读起来是一堆居中的字而不是一张表。
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# ★ 对局中的行**不接 handler、也不吃键盘焦点**:焦点环能落到它上面等于邀请一次注定
		#   失败的按下(`UiFactory.style_row_button` 早就带了 disabled 的样式,不新增任何颜色)。
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
				# ★ `in_match` 必须传进去(I2):自己那间**还没开局**的房要走普通加入,
				#   拿它去回局只会收到一句"凭据失效"(见 `try_rejoin_row` 的注释)。
				if not try_rejoin_row(code, in_match):
					_join_code(code))
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(未满优先;对局中的照列:自己的房可点(回局),别人的点不动)" % order.size()


# 本页比大乱斗多两段:①点了失效/已满的房间 → 提示并自动刷新一次(列表常驻陈旧房间,点了必失败);
# ②已入房后房主/对端掉线被大厅取消配对 → 直接刷新恢复可操作。其余才是"原样显示"。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting and (t == "连接断开" or t == "连接失败"):
		return   # 重启本机服期间,旧连接被杀的断连提示是预期噪音,不覆盖状态
	if t == "房间已满" or t == "房间不存在":
		# 推迟到帧末:server_message 在大厅 peer 的 poll 调用栈内到达,
		# 栈内立刻 NetBus.stop()(重连)会把正在 poll 的 peer 提前 free → 原生段错误
		_join_sent_ms = 0   # 服务端已明确应答,停掉 join 兜底
		_join_code_pending = ""   # 加入被拒 ⇒ 那间房与我无关,别留给下一次的成功信号(I1)
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
	# ★ 同 `_on_room_joined`:建房那条路也要记 —— 否则房主从列表里点**自己**那间房时,
	#   `can_rejoin_to(code)` 因房号不符而假,那一行被当"别人的房"禁用(回局入口对房主失效)。
	PvpSession.note_room(code)
	_room_code = code
	_update_code_label()
	_set_in_room(true)   # 入房:建房按钮收起(与另两页进等待室同款)
	# ★ 顺手把隧道拉起来(房主的第三步,见 docs/netplay.md 的总览):
	#   房间码就是隧道网络名的输入,而客机要靠隧道才找得到这台机器。
	# ★ 失败/未安装**不阻塞建房**(房间照样开得出来),但**这个房没人进得来** ——
	#   手填地址那条路已删,"局域网直连"这个退路**不存在**(2026-09-29 订正:原先这里和
	#   下面两句都写着"只有局域网能加入",那是地址框还在时的事)。
	var note := ""
	# ★ 2026-09-30:闸门与另两页同款 —— 本端已经在这串码的网上就不重起
	#   (`start_host` 内部会先 `stop()`,无脑重起等于把已经连进来的客人一起踢掉)。
	if Tunnel.available() and PvpSession.server_port > 0 and not Tunnel.on_network(code):
		if Tunnel.start_host(PvpSession.server_port, code):
			var no_relay := Tunnel.no_relay_hint()
			note = no_relay if not no_relay.is_empty() else "远程可加入(隧道已启动)"
		else:
			note = "**隧道启动失败,别人进不来**"
	else:
		note = Tunnel.missing_hint() + ";别人进不来"
	_status.text = "房间码 %s —— 告诉对手(%s)" % [code, note]


# 服务端答"加进去了" —— **本页唯一**记加入房号的地方(见 `_join_code` 的 I1 那段)。
func _on_room_joined(role: int) -> void:
	if not _join_code_pending.is_empty():
		PvpSession.note_room(_join_code_pending)
		_room_code = _join_code_pending
		_update_code_label()
		_join_code_pending = ""
	# 注意:此处不清 _join_sent_ms——入房后到 go_match 之间若房主掉线、大厅关房,
	# 客户端会收不到 go_match 也没有任何后续;保留该兜底计时(超时自动刷新回大厅)。
	_status.text = "已加入,等待开战……"
	_set_in_room(true)


# 入房应答超时兜底:UDP 连不上不会立刻报失败,这里定时自动回大厅,
# 不让「点了幽灵房间」永久停在"等待配对"。
# ★ 本页的梯顺序是 [回局 → join → 大厅 → claim];**别重排**。
func _process(_delta: float) -> void:
	# 0) 回局(路径乙):请求发出后大厅 15s 无应答 —— 早于下面几条梯,因为此刻它们都还没启动
	if _tick_rejoin_timeout():
		return
	# 1) join_room 发出去 10s 服务端无任何应答(幽灵房间/丢包):自动刷新列表恢复可操作
	if _claimed_ms == 0 and _join_sent_ms > 0 \
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

func _send_list_request() -> void:
	NetBus.rpc_id(1, "list_rooms")


# ①服务器权威规则项(回合回血 / 禁武器,以 role1 那份为准)②本端角色色相。
# 两者都**已生效**;完整链路见 _build_options_panel 顶部注释。
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"map": Settings.mp_map_path,
	}


func _go_match_status() -> String:
	return "配对成功,进入对局……"


# 配对成功:停 join 兜底,转由 claim 兜底接管
func _on_go_match_extra() -> void:
	_join_sent_ms = 0


# claim 后 25s 仍未 match_start:对方未就绪(房间失效 / 对端掉线)→
# 放弃本局并自动重连,恢复列表/建房能力(原「等待配对」永久卡死)
func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已回到房间列表并刷新,请换一个房间"


func _on_return_to_lobby() -> void:
	_join_sent_ms = 0
	_set_in_room(false)   # 回列表:建房按钮放回来(与另两页"退房恢复创建面板"同款)


# 换服务器重连:清掉旧列表(旧房间号在新服上必然「房间不存在」)
func _on_lobby_reconnect() -> void:
	_show_empty_list()
	_set_in_room(false)


# 本页"在不在房里"的唯一开关点(`_on_room_created` / `_on_room_joined` 置真,
# `_on_return_to_lobby` / `_on_lobby_reconnect` 置假 —— 后者是 `_return_to_lobby()` 的收口)。
# ★ 只管**入口的可见性**,不参与任何协议判断:在房里点建房本来也会被服务端
#   (`"你已经在房间里了"`)挡住,那一条仍然在。
func _set_in_room(in_room: bool) -> void:
	_set_entry_buttons_enabled(not in_room)


func _enter_match_scene() -> void:
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
