class_name MpLobby
extends LobbyPage

# 统一联机大厅:1v1 / 大乱斗 / 3v3 三套协议在本页合并。顶栏(昵称/地址/启服) → 模式筛选 + 创建/加入 → 房卡网格 → 状态栏。
# ★ 一条纪律:三个模式在本页的差异全部收在 _mode / _current_mode 两个变量上(筛选值 / 创建弹层形态 / 等待室形态 / 转连方式);别再按"哪个页面"分叉。
# ★ ack 梯顺序 = worker → claim → 大厅 → ack(合并后唯一一条):1v1 旧页那条 join 梯的职责由末尾那条(建房/加入 8s 无应答)覆盖。三套服务端注册表原样保留:本页并发调三次现有列房 RPC,前端合并打标。
# ★★ 静态骨架在 scenes/mp_lobby.tscn 里:版式(页面留白 / 各行坐标 / 控件尺寸 / 间距 / 固定文案)一律去编辑器里拖,别回来加坐标常量。
#
# ★★ 2026-10-22 Task 10 拆件(纯搬移,行为零变化):本页只留四件事 ——
#   ① 编排(_build_ui 按语义名把骨架接给四块面板) ② RPC 发送(Wire.rpc_id(...) 的名字与参数逐字未动)
#   ③ 模式切换状态(_mode / _create_mode / _wait_mode / _current_mode) ④ 信号转发(NetBus / NetBusExt 的入口 handler)。
#   四块面板在 scenes/mp_lobby/ 下:
#     · room_list.gd    —— 房间列表 / 刷新归并 / 加入弹层 / 房卡绘制
#     · create_panel.gd —— 建房弹层:模式分段按钮、弹层显隐、建房载荷与 player_options 的组装
#     · options_form.gd —— 建房表单行显隐(_form_rows 那张表)与控件值读写
#     · wait_room.gd    —— 等待室:选边 / 开始按钮 / 满员文案 / 房主判断 / 名单行
#   ★ 节点路径(%NodeName)、信号、文案、_form_rows 键名一律逐字不变;_build_ui 的登记逻辑也仍在(只是分给各面板的 register)。
#   ★★ 节点句柄里 _grid / _wait_panel / _wait_title / _wait_body / _wait_count / _wait_hue / _wait_start / _wait_pick_a / _wait_pick_b / _wait_leave
#     留在本页:测试(honest 口径,tests/harness/{rejoin,team_match}_watcher.gd)用 get("_grid") / get("_wait_body") 读它们 —— 搬走 = 探针静默拿到 null。

var _mode := ""                    # 当前筛选:"" = 全部;否则 PvpSession.MODE_*
var _grid: GridContainer = null
var _create_btn: Button = null
var _join_btn: Button = null

# 等待室的面板句柄(行为在 wait_room.gd;句柄留本页,理由见文件头)。
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
# 我当前是否在某间房里(等待室亮着):wait_room.show 置真、hide 置假、_lobby_action_allowed 读 —— 与面板可见性同一生命周期,分两处写状态就是漂的成因。
var _in_room := false

# 建房弹层当前选中的模式(模式切换状态)。★ 弹层本体 / 压暗罩 / 三颗分段按钮的行为在 scenes/mp_lobby/create_panel.gd,
# 它 apply() 时写这里;本页「确定」那条 RPC 分派读同一份(状态只住一处,别在面板里再存一份)。
var _create_mode := PvpSession.MODE_PVP

# 我当前所在那间房的模式(转连时按它选场景)。★★ 它与 PvpSession.room_mode 不是一回事:后者是凭据的模式(供列表里判"这一行是不是我的房"),
# 它在"建了房但 note_room 还没跑到"这一档上是空串 —— 拿它去分派 _enter_match_scene 会把 1v1 的对局静默切进 team_game.tscn(不报错)。别合并成一个字段。
var _current_mode := ""

var _ack := true
var _sent_ms := 0

# 刚发出的加入请求的房号(1v1 的 room_joined 载荷只有 role,拿不到房号,只能靠它暂存)。
# ★★ 漏了给它赋值 = 两条真缺陷:① _current_mode 停在空串 ⇒ _enter_match_scene() 落进 else ⇒ 1v1 的加入者被送进错场景;② note_room() 从不被调用 ⇒ 自己那间房永远是灰的。
var _join_pending := ""

# 「模式未知 ⇒ 三张表都问一次」这一次尝试还在飞。★ 三张表里只有一间存在,另两张必然回「房间不存在」/「房间已满」—— 那是预期噪音:既不显示、也不花掉那次自动刷新额度(_auto_refreshed)。
# ★★ 关闸只能靠 _multi_left 数应答条数,不能靠"任一正向应答就收尾":1v1 的 join_room 成功是立即回的,而 royale/team 是 call_deferred + await ⇒ 正向一到就关闸,
# 那两张表稍后到的 absent 会漏出去触发一次刷新 —— 后果不是"多一条提示",而是那一次性额度被花掉:之后第一张真陈旧卡片被拒时反而不会自动刷新了。
var _probe_multi_join := false
var _multi_left := 0               # 这一次尝试里还没被认领的应答数(起手 = 3 个请求)

var _auto_refreshed := false

# ── 四块面板(纯搬移;见文件头)──
var _rooms: RoomList = null
var _form: OptionsForm = null
var _create_dialog: CreatePanel = null
var _wait: WaitRoom = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

	Wire.local_room_list.connect(_on_room_list)
	Wire.local_room_created.connect(_on_room_created)
	Wire.local_room_joined.connect(_on_room_joined)
	Wire.local_royale_rooms.connect(_on_royale_rooms)
	Wire.local_royale_room_state.connect(_on_room_state_royale)
	Wire.local_team_rooms.connect(_on_team_rooms)
	Wire.local_team_room_state.connect(_on_room_state_team)
	Wire.local_pvp_room_state.connect(_on_pvp_room_state)

	_finish_lobby_ready()

	# Beta 页预选的筛选模式(从主菜单直接进来时为 "")。★★ 它读的是 entry_mode 而不是 room_mode:后者是凭据的模式,混用会把一个凭据字段写成非凭据的值,而 can_rejoin_to() 正是拿 room_mode 判"这一行是不是我的房"。
	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)



# 把骨架接上代码:①顶栏控件按语义名接上本页 ②四块面板各自 register(按语义名取节点 + 接自己的信号 + 建自己的动态块)。
# ★★ 版式一律改 .tscn。★ 本方法只做 UI:NetBus / NetBusExt 的 connect 与 _finish_lobby_ready() 留在 _ready 里 —— 树外实例化本页的夹具故意不入树(不入树 ⇒ _ready 不跑 ⇒ 不建 socket),别把接线并进来。零守卫:那两个 lobby_* 夹具探针已删(2026-10-09)。
# ★ 控件的信号在各面板 register 里接(不挪进 _ready):"按钮画在屏上、按下去毫无反应"没有任何运行时信号可观测。
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

	_create_btn = %CreateBtn
	_create_btn.pressed.connect(_open_create_dialog)
	_join_btn = %JoinBtn

	_grid = %CardGrid
	# ★ 状态栏文本是 room_list.redraw() 的输出,骨架里它是空的(清运行时字面量那一步把它清回了中性)⇒ 这里不需要、也不该再灌一个初值。
	_status = %StatusLabel
	%BackBtn.pressed.connect(_on_back_pressed)

	# 四块面板:先建再接线(本页只做编排;面板的行为在 scenes/mp_lobby/)。
	_rooms = RoomList.new()
	_rooms.setup(self)
	_form = OptionsForm.new()
	_create_dialog = CreatePanel.new()
	_create_dialog.setup(self, _form)
	_wait = WaitRoom.new()
	_wait.setup(self)
	_join_btn.pressed.connect(_rooms.toggle_join_panel)
	_rooms.register(self)
	_form.register(self)
	_create_dialog.register(self)
	_wait.register(self)


func _on_back_pressed() -> void:
	Wire.stop()
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
	_rooms.set_filter_selected(mode)
	_rooms.redraw()



# 三个载荷入口各自把条目并入同一张表,再统一重绘。★ 每条都打上 mode 标 —— 卡片要显示模式、筛选器也按它过滤,而服务端载荷里没有这个键。
func _ingest_rooms(mode: String, rooms: Array) -> void:
	_rooms.ingest(mode, rooms)
	# ★ 不无条件清 _ack / _sent_ms:它们是加入的 8s 兜底,而一次列房应答并不能证明那次加入有应答 —— 无条件下会刚好在"加入请求丢了、用户又点了一次刷新"时把兜底拆掉;只有"没有待应答的加入"时清才安全。
	if _join_pending.is_empty():
		_ack = true
		_sent_ms = 0
	if _rooms.all_got():
		_rooms.redraw()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	# Beta 房与普通房互不可见(客户端侧;服务器侧 join 守卫是第二道)。
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))



# 基类钩子:不是一条统一 RPC —— 三条并发、各自到达,合并后重绘(刷新延迟由最慢那份决定);token 仍要带,大厅据此把持凭据本人自己那间私密房也列出来。
func _send_list_request() -> void:
	_rooms.reset_got()
	_rooms.clear_rooms()
	Wire.send(WireKind.LIST_ROOMS, [])
	Wire.send(WireKind.ROYALE_LIST, [PvpSession.token])
	Wire.send(WireKind.TEAM_LIST, [PvpSession.token])



func _on_room_created(code: String) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(code, _current_mode)
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	# 补发地图:1v1 的 create_room 签名冻结,塞不进 payload。★ 这里无条件下发 —— 走到本 handler 的就是建房者,也就是房主。
	Wire.send(WireKind.ROOM_MAP, [code, Settings.mp_map_path])
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code
	# 先摆一个本侧占位(房主 = 自己 / 1 人);服务器 pvp_room_state 一到就用真名单刷新。
	_wait.show(_wait.pvp_wait_state(code, 1, 1, 1), PvpSession.MODE_PVP)


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
		# 占位:加入者不知道谁是房主(服务器按 peer 下发 your_role/host_role)⇒ host_role 填 0,真状态下一帧到。
		_wait.show(_wait.pvp_wait_state(code, role, 0, 2), PvpSession.MODE_PVP)


# 1v1 等待室实时状态(2026-10-24:开局改由房主点「开始游戏」)。载荷 = {code, players, host_role, your_role, in_match}。
# ★ 与 _on_room_state_royale 同款:房号/模式都以服务器载荷为准;1v1 没有地图补发(房主建房时已发过 room_map)。
func _on_pvp_room_state(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_wait.show(state, PvpSession.MODE_PVP)


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
		Wire.send(WireKind.ROOM_MAP, [code, Settings.mp_map_path])
	_status.text = "已进入大乱斗房间 %s,等待开局…" % code
	_wait.show(state, PvpSession.MODE_ROYALE)


func _on_room_state_team(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_TEAM
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_join_pending = ""
	_ack = true
	_sent_ms = 0
	_claim_multi_reply()
	var code := str(state.get("code", ""))
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		Wire.send(WireKind.ROOM_MAP, [code, Settings.mp_map_path])
	_status.text = "已进入 3v3 房间 %s,等待选边/开局…" % code
	_wait.show(state, PvpSession.MODE_TEAM)


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
			# ★ 推迟到帧末:server_message 在大厅 peer 的 poll 调用栈内到达,栈内立刻 Wire.stop()(重连)会把正在 poll 的 peer 提前 free → 原生段错误。
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
			Wire.send(WireKind.ROYALE_JOIN, [code, invite, PvpSession.beta_mode])
		elif mode == PvpSession.MODE_TEAM:
			Wire.send(WireKind.TEAM_JOIN, [code, invite, PvpSession.beta_mode])
		elif mode == PvpSession.MODE_PVP:
			Wire.send(WireKind.JOIN_ROOM, [code])
		else:
			Wire.send(WireKind.JOIN_ROOM, [code])
			Wire.send(WireKind.ROYALE_JOIN, [code, invite, PvpSession.beta_mode])
			Wire.send(WireKind.TEAM_JOIN, [code, invite, PvpSession.beta_mode]))


# 点「＋ 创建房间」只显示弹层。★ 每次打开都重刷模式相关行显隐(create_panel.open → apply),不挪进 _ready —— 面板建好之后玩家仍可能改筛选模式,那时这条链必须再跑一次。
func _open_create_dialog() -> void:
	_create_dialog.open()


# 建房:按模式分派 RPC。1v1 的 create_room 是原版 NetBus 的 RPC、签名冻结(不带 payload),它的 map / disabled_weapons 都从 player_options 走。
func _on_create_pressed() -> void:
	# ★ 按下即收起弹层(不等应答 —— _with_lobby 的行动可能是异步的:没连上时它会先建连接、连上后才跑 action)。结果一律走状态栏(成功 = 房间号;失败 = 服务端那句文案),玩家要改选项再按「＋ 创建房间」重开即可。
	_create_dialog.set_visible(false)
	var mode := _create_mode
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		var payload := _create_dialog.build_payload(mode)
		payload.merge(_beta_payload())   # Beta 态追加 {"beta":true,"time":{…}};普通态空合入
		if mode == PvpSession.MODE_ROYALE:
			Wire.send(WireKind.ROYALE_CREATE, [payload])
		elif mode == PvpSession.MODE_TEAM:
			Wire.send(WireKind.TEAM_CREATE, [payload])
		else:
			Wire.send(WireKind.CREATE_ROOM, [])
		_status.text = "建房中…(拿到房间号后可叫对方刷新列表点进来)")


# ESC 关弹层。★ 弹层不可见时一律不处理 —— 大厅页自己的返回语义(回主菜单)不能被这里抢掉;只有弹层挡着页面时才吞掉这一次 ESC。★ 弹层启动即建(骨架里就有)⇒ 没有 null 可判。
func _unhandled_input(ev: InputEvent) -> void:
	if not _create_dialog.is_open():
		return
	if ev.is_action_pressed("ui_cancel"):
		_create_dialog.set_visible(false)
		get_viewport().set_input_as_handled()


# 选边(仅 3v3)。★ 按 team 号上行,服务端"先拦后分"。
func _on_wait_pick(team: int) -> void:
	Wire.send(WireKind.TEAM_PICK, [team])


func _on_wait_start_pressed() -> void:
	_status.text = "开局中…"
	if _wait_mode == PvpSession.MODE_PVP:
		Wire.send(WireKind.PVP_START, [])   # 1v1(2026-10-24):两人齐后由房主触发
	elif _wait_mode == PvpSession.MODE_ROYALE:
		Wire.send(WireKind.ROYALE_START, [])
	elif _wait_mode == PvpSession.MODE_TEAM:
		Wire.send(WireKind.TEAM_START, [])


# 「退出房间」。★ 三个模式不同款(照两个旧页逐字对齐):1v1 没有 leave RPC —— 断开即触发大厅 on_peer_left 清房,基类 _return_to_lobby 正好是那条收口(Wire.stop() + 重连 + 刷新列表)。
# ★ 大乱斗 / 3v3 有 leave RPC,且不能断大厅 peer:断开会走 on_peer_left 那条另一条路径去关房,同一件事就有两个实现 ⇒ 只发 leave,然后走共用的页面清理(_on_return_to_lobby)+ 重拉列表 —— 不重连,大厅 peer 还在。
func _on_wait_leave_pressed() -> void:
	if _wait_mode == PvpSession.MODE_ROYALE:
		Wire.send(WireKind.ROYALE_LEAVE, [])
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	elif _wait_mode == PvpSession.MODE_TEAM:
		Wire.send(WireKind.TEAM_LEAVE, [])
		_on_return_to_lobby()
		_request_list.call_deferred("已退出房间")
	else:
		_return_to_lobby("已退出房间")



# ★★ 判据必须是本页的 _current_mode(我当前所在那间房的模式),不是 PvpSession.room_mode —— 后者是凭据的模式,它在"建了房但 note_room 还没跑到"那一档上是空串。两个量语义不同,不要合并成一个字段。
# ★ 两页刻意不同的那条纪律现在按 _current_mode 分派:1v1 直切;大乱斗 / 3v3 必须 call_deferred —— 它们的 match_start 在 Wire.poll 调用栈内到达,栈内切场景会在这个栈里 free 大厅 / 重建大物理世界 → 偶发原生段错误(曾实测)。
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
# ★ 三个模式的文案各自点名:本页三模式共用一张列表,一句通用的"已在房间里"会让玩家看不出自己卡在哪个模式的房里。★ 这道闸门只挡得住最后那一次 RPC —— 两颗入口按钮由 wait_room.show 直接收起(见 _create_btn 上方那段),两半缺一不可。
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
# ★ 键集由 ModeDefs.OPTION_KEYS 决定(2026-10-22 统一):3v3 不再上发禁用武器/回合回血(X5:界面藏了控件就不该让它生效);大乱斗不再上发回合回血(它没有回合);1v1 不再上发 match_time(只有大乱斗读)。
# ★★ 组装(ModeOptions.build)在 scenes/mp_lobby/create_panel.gd;快照的读取留在本页:下面那行 `"match_time": int(Settings.royale_match_min * 60.0)` 是
#    ROYALE_MATCH_TIME_CEILING 上界链的第二环,tools/room_sweep_lint.gd 钉着它必须住在 scenes/mp_lobby.gd 的源码里(别搬走那一行)。
func _player_options() -> Dictionary:
	return _create_dialog.player_options(_current_mode, {
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
	_wait.hide()


func _on_lobby_reconnect() -> void:
	_rooms.clear_rooms()
	_rooms.redraw()
