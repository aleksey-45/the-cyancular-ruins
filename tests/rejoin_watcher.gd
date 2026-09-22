extends Node

# 回局真链路探针的**观察者**(每端一个,挂在 root 上;换场不会把它带走)。
# 三端各跑一条剧本:
#   c1 = actor:建房 → 开局 → 进 pvp_game → 到 PLAYING → **ESC + 点「回到主菜单」** →
#        **自己重连大厅 → 再挂一份真大厅页 → 在房间列表里点自己那间房那一行** → 回到**原局**。
#        断言四条(见 `_tick_c1` 的相 3):
#          ⓪ 那一行**可点**(`disabled == false`)—— ★ 这是**新入口本身**的断言:前置计划交付的行为是
#             "对局中的房一律 disabled",而回局这一档要在**同一行**上把它翻过来。少了这一条,
#             "次序写反"(先按 in_match 禁用)会以"c1 一直点不动 → 超时"的形式表现,与"回局坏了"分不开。
#          ① 回局后进了 `pvp_game`;
#          ② `PvpSession.role` 与离开前**一致**(大厅把凭据里的 role 发对了);
#          ③ **重新收到服务器广播**(PLAYING 的 `round_state` 计数严格增长)—— 这是"真的回到
#             那一局"的唯一客观证据:离场期间客户端断着、一条广播都收不到。
#        ★ 不拿 instance_id 做断言:路径乙**会重建场景**,节点 ID 必然不同 —— 服务端那具身体
#          确实没销毁,但客户端**观测不到**它,写成断言就是伪断言。服务端身体未销毁由
#          `tests/reconnect_probe` 相①(路径甲,不重建场景)钉住。
#        ★ **不点主菜单里那颗按钮**(它已随用户裁定取消):回主菜单之后,本端**自己再挂一份大厅页**
#          (与首次挂载同一手法,见 `_attach_page_in`)—— 探针要在意的"玩家自己找到那间房"这一段,
#          落在**列表里点行**上;而主菜单那几步只是换场,不承载判据。
#   c2 = 对手:点列表加入 → 进 pvp_game → **在场上留满一个观察窗**(`C2_OBSERVE`),然后才落盘。
#        ★ brief 把 c2 定位成"这一局还在的见证",但**没有给它任何断言**(进了局就 `_finish`,
#          零条断言也算 OK)。这里补四条**它自己能观测**的:在场并看到 PLAYING / 掉线者的身体
#          每一帧都在权威快照里(身体不销毁)/ 观察窗内一直是 PLAYING 且局号未变(没有重启过一局)
#          / 快照连续。没有这几条,c1 那边"回到的是**同一局**"就没有第二个人作证。
#   c3 = 第三人:**只连大厅**:①列表里看得见这个房(in_match=true)②加入被拒。
#        ★ ② 是用户点名的要求("C 可以看到 A 与 B 的房间,尽管无论在对战还是掉线 C 都不应该进去")
#          —— 服务端的 `join_room` 守卫由这一条在**真链路**上验一次。
#        ★ 它同时是 c1 那一行的**反向对照**:同一行、同一份载荷,c3 手里没有凭据 ⇒ 客户端不该
#          把它变可点(本端断言:那一行 `disabled == true`)。
# 失败时把结果写进 `user://rejoin_probe_<who>.result`(子进程 stdout 父进程看不到)。
#
# ★ 与 team_match_watcher 同款的两条纪律:
#   ① **先置位再入树**:大厅页 `_ready` 会 deferred 跑一次 `_request_list`,只有"已连同地址"
#      那一支会复用现有连接(否则它会 `NetBus.stop()` 并按默认端口 7777 重连 —— 那是**用户自己的
#      服务端**,本探针明确规定不碰)。
#   ② 页挂在**探针场景**下(不是本节点下):换场时它随探针场景一起被 free —— 那正是生产的形状。
#
# ═══ ★ 与 task-8-brief.md 的偏离(逐条;理由都在实现处再写一遍)═══
#   ① **c2 的加入触发条件**:brief 写的是 `_room_code != ""` 才点行,而 `_room_code` 只在
#      `local_room_created` 里赋值 —— 那条信号**只有建房者(c1)收得到**,c2 恒为空串 ⇒
#      c2 **永远不加入** ⇒ 房永远凑不齐两人 ⇒ 整跑在 40s 的 `BOOT_TIMEOUT` 上红。改成"列表里
#      有可点的行就点"。
#   ② **周期刷新列表**(三个角色都要):房间列表是**请求/响应**式的,而挂页时那 1~2 次请求
#      通常落在"房还没建 / 对局还没开"之前,之后**再也不会有列表到达** —— c2 看不到房、c3 看不到
#      `in_match`(它只在 in_match 那一行上才动手,故早刷新不会误入房)。梯节拍沿用
#      `team_match_watcher._tick_lobby_join` 的 1.5s,并且**只在连接活着时发**(绝不让页走到
#      "未连 → 重连默认端口 7777"那一条)。
#   ③ **c1 回主菜单后要先自己把大厅连接接回来**(生产里那一步是"页 `_ready` → `_with_lobby` →
#      `NetBus.start_client(addr)`,端口取**默认 7777**;本探针的大厅在池外 29300,照那条走会去连
#      用户的 7777 并且永远连不上)。所以本端按"先连上、再挂页"的同一手法自己做一次,让页走
#      **已连**的快路 —— 这正是生产里"玩家站在一个已经连着的大厅页上"的那个前提。
#   ④ `_page` 一律用 `is_instance_valid` 判死活(brief 在 `_tick_c2` 里只判 `== null`):
#      换场后 `_page` 是**已释放对象**,对已释放对象取字段会抛
#      `Invalid access … previously freed`(本仓实测踩过,见 team_match_watcher 文件头)。
#   ⑤ `_rec` 的读数**要活到结果文件里**(brief 的 `_finish` 用 WRITE 打开结果文件 → 之前 `_rec`
#      写进去的行全被截掉,读日志的人拿不到任何中间读数)。
#   ⑥ c3 那条"看到了对局中的房"原来是 `_fail(...)` 后紧跟一条**无条件** `_ok(...)` —— 同一件事
#      同时进失败账本和成功账本,输出自相矛盾。改成 if/else。
#   ⑦ 每条判词的断言计数(`_checks` + `MIN_CHECKS_*`):被截断的跑不许打印 OK。

const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 60.0      # 从挂页到"进 pvp_game 且到 PLAYING"
const PLAY_SETTLE := 3.0         # PLAYING 后静置(让快照跑起来,身体有个明确的位置读数)
const REJOIN_TIMEOUT := 30.0     # 点了自己那行之后等回到 pvp_game
const RESULT_WAIT := 40.0        # c3 等"一个不会来的 room_joined"的上限
const REFRESH_EVERY := 1.5       # 大厅页列表刷新节拍(见文件头偏离②)
const C2_OBSERVE := 40.0         # c2 的观察窗(PLAYING 之后;覆盖 c1 的离场 + 回局)
const C2_SNAP_GAP_MAX_MS := 1500.0

# 一条**绿**的跑至少要跑到的断言数(只对"否则会打印 OK"的那一跑生效,见 `_finish`)。
#   c1 = 4(行可点 / 进了对局 / role 一致 / 广播恢复)
#   c2 = 4(在场见 PLAYING / 对手身体一直在 / 局没变 / 快照连续)
#   c3 = 3(看得见 / 同一行对第三人仍禁用 / 加入被拒)
const MIN_CHECKS := {"c1": 4, "c2": 4, "c3": 3}

var who := ""
var lobby_port := 29300

var _page: Node = null
var _game: Node = null
var _t := 0.0
var _phase := 0
var _phase_t := 0.0
var _done := false
var _fails: Array[String] = []
var _recs: Array[String] = []
var _checks := 0
var _body_id_before := 0
var _playing_seen := false        # 已收到服务器广播的 PLAYING(state==1)
var _playing_count := 0           # PLAYING 广播的累计条数(回局后必须严格增长)
var _playing_at_leave := 0        # 离场那一刻的计数(回局后拿它比对)
var _role_before := 0             # 离场前的 role(回局后不许变)
var _joins := 0                   # c3:收到 room_joined 的次数
var _go_match := 0                # c3:收到 go_match 的次数
var _server_msgs: Array[String] = []
var _room_rows := -1              # c3:最近一次列表里"对局中"的行数
var _room_code := ""
var _row_seen := false            # c1:自己那间房那一行已经出现在列表里
var _row_disabled := true         # c1:那一行的 `disabled`(新入口的断言:必须是 false)
var _c3_row_disabled := true      # c3:同一行的 `disabled`(反向对照:必须是 true)
var _refresh_t := 0.0
# c2 的观察读数(PLAYING 那一刻清零,窗口结束时统一判定)
var _obs_started := false
var _obs_t := 0.0
var _obs_round := -1
var _obs_state_bad := false
var _snap_last_ms := 0
var _snap_max_gap := 0.0
var _snap_total := 0
var _snap_with_opp := 0
# c2/c3 的兜底计时(等不到该等的东西时要**自己判红**,而不是让裁判只收到 2/3 份结果)
var _hard_t := 0.0
# c2/c3 落盘后**保持在线**(见 _finish:裁判还要继续观察这一局),只有 c1(actor)自己退。
var hold_alive := false
# c1 回主菜单后"大厅连接已经接回来"这一步完成了吗
var _lobby_back := false
var _lobby_back_sent := false


func _ready() -> void:
	hold_alive = who != "c1"
	NetBus.local_room_created.connect(func(code: String) -> void:
		_room_code = code
		_log("建房成功:%s" % code))
	NetBus.local_room_joined.connect(func(_role: int) -> void:
		_joins += 1
		_log("收到 room_joined(第 %d 次)" % _joins))
	NetBus.local_go_match.connect(func(_role: int, port: int) -> void:
		_go_match += 1
		_log("收到 go_match(第 %d 次,port=%d)" % [_go_match, port]))
	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_round_state.connect(_on_round_state)
	# c2 的"这一局还在"读数(见文件头 c2 那一段)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_server_message.connect(func(t: String) -> void:
		_server_msgs.append(t)
		_log("server_message: %s" % t))
	multiplayer.connected_to_server.connect(_on_lobby_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_fail("连大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port]))
	NetBus.start_client(LOBBY_ADDR, lobby_port)


func _on_lobby_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", "BOT%d" % (1 if who == "c1" else (2 if who == "c2" else 3)))
	_attach_page.call_deferred()


func _attach_page() -> void:
	_attach_page_in(get_tree().current_scene,
			(on_create if who == "c1" else on_refresh))


# 把一份**真**大厅页挂进当前场景(首次进场与 c1 回局前各一次,同一份实现)。
# ★ 三行"先置位再入树"(缺一不可):
#   ① `PvpSession.server_address = LOBBY_ADDR` —— `matchmaking.gd` 的地址框**默认值取的就是它**
#      (`ui_factory.line_edit(..., PvpSession.server_address)`),而 `_with_lobby` 的快路判据是
#      `_connected_addr == _addr_edit.text` ⇒ 不拨它,页 `_ready` 那次 deferred `_request_list`
#      会判"地址变了"→ `NetBus.stop()` + 按**默认端口 7777** 重连:本进程与探针大厅(29300)的
#      连接当场拆掉,而本探针明确规定不碰 7777(症状是"c1 从这一刻起什么都收不到")。
#   ② 同一行对**转连 worker** 也是必需的:`_do_go_match` 用 `PvpSession.server_address` 连 worker,
#      而 worker 就在 127.0.0.1 —— 不拨它,c1/c2 会去连**云地址**上的 29350(必失败)。
#   ③ `_connected` / `_connected_addr`:让页走"已连"的快路(本进程已经连上大厅了)。
func _attach_page_in(cs: Node, action: Callable) -> void:
	if cs == null or _page != null:
		return
	_page = load("res://scenes/matchmaking.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	_page.set("_connected", true)
	_page.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(_page)
	_log("真大厅页已挂载(%s)" % cs.name)
	action.call()


func on_create() -> void:
	_page.call("_on_create_pressed")


func on_refresh() -> void:
	_page.call("_on_refresh_pressed")


# 周期性点一次「刷新列表」(**真按钮回调**)。★ 见文件头偏离②:列表是请求/响应式的,挂页那
# 1~2 次请求常常落在"房还没建 / 对局还没开"之前;不补这一梯,c2 与 c3 会永远停在空列表上
# (brief 里没有这条梯)。
# ★ `can_send_to_server()` 那道闸不是可选的:页的 `_with_lobby` 在**未连**时会落到
#   `NetBus.start_client(addr)`(**默认端口 7777**)—— 那是用户自己的服务端,本探针不碰。
func _tick_refresh(delta: float, done: bool) -> void:
	if done or not is_instance_valid(_page) or not NetBus.can_send_to_server():
		return
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_EVERY
	_page.call("_on_refresh_pressed")


# 在房间列表里按**房号**找那一行(三页的按钮文案都是 `"房间 %s …" % code`,逐字对应)。
# ★ 找不到时调用方必须**立刻 FAIL**,不能静默等超时 —— 那种失败与"回局坏了"在输出上长得一样。
func _find_row_button(code: String) -> Button:
	if not is_instance_valid(_page) or _page.get("_list_box") == null or code == "":
		return null
	for c in _page.get("_list_box").get_children():
		if c is Button and (c as Button).text.begins_with("房间 %s" % code):
			return c
	return null


# 列表里第一个**可点的**行(房号未知时的退路;c2 用 —— 大厅是本进程起的,只有 c1 那一间房)。
func _first_row_button() -> Button:
	if not is_instance_valid(_page) or _page.get("_list_box") == null:
		return null
	for c in _page.get("_list_box").get_children():
		if c is Button and not (c as Button).disabled:
			return c
	return null


func _on_room_list(rooms: Array) -> void:
	# ★ 刷新梯的节拍**在收到列表这一拍重置**:下一拍再问是"这份是新的吗",不是"到点了吗"。
	_refresh_t = REFRESH_EVERY
	if who == "c1":
		# ★ c1 读的是那一行的**可点性**:手里的凭据就是"这一行是我的"的证明 ⇒ 必须可点。
		#   它只能在这里取 —— `disabled` 是客户端**渲染出来的 Button** 上的状态,载荷里没有这个字段。
		var mine := _find_row_button(_room_code)
		if mine != null:
			_row_seen = true
			_row_disabled = mine.disabled
			_rec("ROW code=%s disabled=%s" % [_room_code, str(_row_disabled)])
		return
	if who != "c3":
		return
	var in_match := 0
	for r in rooms:
		if typeof(r) == TYPE_DICTIONARY and bool(r.get("in_match", false)):
			in_match += 1
			_room_code = str(r.get("code", ""))
			_rec("ROW code=%s in_match=1 names=%s" % [_room_code, str(r.get("names", []))])
	_room_rows = in_match
	if in_match == 1:
		# ★ c3 读的是同一行的**另一半**:它**没有**凭据 ⇒ 必须不可点(`try_rejoin_row` 会返回 false
		#   走普通加入)。c1 与 c3 这两条合起来才说明"可点性"是**按人**判的,而不是"一律可点"。
		var row := _find_row_button(_room_code)
		if row != null:
			_c3_row_disabled = row.disabled
		if _phase == 0:
			# 看见了 → 立刻试图进去(必须被拒)
			_phase = 1
			_phase_t = 0.0
			_log("列表里看到对局中的房 %s → 试图加入(应当被拒)" % _room_code)
			_page.call("_join_code", _room_code)


# 服务器广播的回合状态。★ PLAYING 的判据取**服务器广播的 round_state**(state==1),不是本地
# `_round_locked` 的默认值 —— 后者在第一条 round_state 到达**之前**就是 false,照它判会在刚进
# 场景那一帧就"以为"开打了(`team_match_watcher` 用的是同一个读数)。
func _on_round_state(data: Dictionary) -> void:
	var st := int(data.get("state", -1))
	if st == 1:
		if not _playing_seen and who == "c2":
			# c2 的观察窗从**它自己**看到的第一条 PLAYING 起算(之前的窗口含建场景那一大段)
			_obs_started = true
			_obs_round = int(data.get("round", 0))
			_obs_t = 0.0
			_snap_last_ms = 0
			_snap_max_gap = 0.0
			_snap_total = 0
			_snap_with_opp = 0
		_playing_seen = true
		_playing_count += 1
		return
	# 非 PLAYING 的广播:观察窗内出现任何一条(换局 COUNTDOWN / 本局收场)**就是**"这一局变了"
	# (换局与收局都先广播 COUNTDOWN/ROUND_OVER,故判据只在这一条上)。
	if who == "c2" and _obs_started:
		_obs_state_bad = true


# c2 的"这一局还在"读数:权威快照的频率 + 掉线者的身体还在不在。
func _on_snapshot_world(world: Dictionary) -> void:
	if who != "c2" or not _obs_started:
		return
	var now := Time.get_ticks_msec()
	if _snap_last_ms > 0:
		_snap_max_gap = maxf(_snap_max_gap, float(now - _snap_last_ms) / 1000.0)
	_snap_last_ms = now
	_snap_total += 1
	var ps: Dictionary = world.get("players", {})
	if ps.has(str(3 - int(PvpSession.role))):
		_snap_with_opp += 1


func _physics_process(delta: float) -> void:
	if _done:
		return
	_refresh_game()          # ★ 每帧重认对局场景(离场再进 = 一具**全新**的节点树)
	_t += delta
	_phase_t += delta
	_hard_t += delta
	match who:
		"c1":
			_tick_c1(delta)
		"c2":
			_tick_c2(delta)
		"c3":
			_tick_c3(delta)


# 每帧重认对局场景。★ **绝不能缓存**:本端的剧本里游戏场景会连换三次
# (大厅 → pvp_game → 主菜单 → pvp_game),旧那具早被 `safe_change_scene` 退役掉,
# 对着已释放实例取字段会报 `Invalid access to property or key … on a base object of type
# 'previously freed'`。`_game` 为 null 表示"此刻不在对局里"(大厅页 / 主菜单 / 换场中间)。
func _refresh_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		_game = null
		return
	if cs.get("_local") == null:
		return     # 场景 `_ready` 还没跑完(局部玩家未就位)
	if _game != cs:
		_log("进入对局场景(role=%d)" % PvpSession.role)
	_game = cs


# 与 team_match_watcher._is_game 同款:按**脚本类型**认(名字会随场景改,类型不会)
func _is_game(n: Node) -> bool:
	return n is PvpMatchClient


# ── c1(actor)──
var _c1_sub := 0      # 0 建房/等开局 1 打一会 2 已按 ESC 回主菜单 3 已点自己那间房那一行
func _tick_c1(delta: float) -> void:
	# ★ 只看**总预算**,不看 `_page` 的死活:相 2 里本端**故意**要经历"页被换场带走 → 再挂一份",
	#   把 `not is_instance_valid(_page)` 写进这条守卫会让相 2 永远进不去(总超时兜底)。
	#   各相自己的界(等列表 / 等回局)写在各自的 `_phase_t` 判据里。
	if _phase_t > ENTER_TIMEOUT + REJOIN_TIMEOUT + RESULT_WAIT:
		_finish("c1 超时(阶段 %d)" % _c1_sub)
		return
	match _c1_sub:
		0:
			if _game != null:
				_c1_sub = 1
				_phase_t = 0.0
			return
		1:
			if _game != null and _playing_seen and _phase_t > PLAY_SETTLE:
				_body_id_before = int(_game.get("_local").get_instance_id())
				_playing_at_leave = _playing_count
				_role_before = int(PvpSession.role)
				_log("PLAYING 就位(role=%d,PLAYING 计数=%d);按 ESC 回主菜单" % [_role_before, _playing_at_leave])
				_rec("LEAVE role=%d plays=%d id=%d" % [_role_before, _playing_at_leave, _body_id_before])
				_esc_and_menu()
				_c1_sub = 2
				_phase_t = 0.0
			return
		2:
			# ★ 回到主菜单之后,本端**自己再挂一份大厅页**(与首次进场同一手法)。生产里玩家是
			#   在主菜单点「1 v 1」进这一页的,那一步只是换场、不承载任何判据;本探针要在意的
			#   是**"自己在列表里找到那间房"那一段**,也就是下面的点行。
			if _game != null:
				return                    # 还在对局场景里(换场还没发生)
			if is_instance_valid(_page) and not _page.is_inside_tree():
				_page = null              # 旧的被换场带走了(它挂在旧场景下 = 生产的形状)
			if not is_instance_valid(_page):
				_page = null
				if not _lobby_back:
					# ★ 偏离③:先把大厅连接接回来(否则页的 `_with_lobby` 会去连**默认端口 7777**)
					if NetBus.can_send_to_server():
						_lobby_back = true
					else:
						_connect_lobby_back()
						return
				_attach_page_in(get_tree().current_scene, on_refresh)
				return
			_tick_refresh(delta, _row_seen)
			if not _row_seen:
				if _phase_t > ENTER_TIMEOUT:
					_fail("c1 ★ 回到大厅页后 %.0fs 没在列表里看到自己那间房(%s)" % [ENTER_TIMEOUT, _room_code])
					_finish("")
				return                    # 列表还没到
			var row := _find_row_button(_room_code)
			if row == null:
				# ★ 立刻 FAIL,不静默等超时(那种失败与"回局坏了"长得一样)
				_fail("c1 ★ 列表里没有自己那间房那一行(code=%s)—— 显示方案那一半坏了?" % _room_code)
				_finish("")
				return
			if row.disabled:
				# ★★ 这一条就是**新入口本身**:同一个房、同一份载荷,别人(见 c3)看到的是
				#    disabled,而**手里有凭据的本人**必须可点。次序写反(先按 in_match 禁用)
				#    会在这一条上当场红 —— 而不是以"点了没反应"的形式混进超时里。
				_fail("c1 ★ 自己那间对局中的房那一行是 disabled —— 回局入口不存在(次序写反?)")
			else:
				_ok("c1 ★ 自己那间对局中的房那一行**可点**(disabled=false)")
			_log("找到自己那间房那一行 → 点它")
			row.pressed.emit()
			_c1_sub = 3
			_phase_t = 0.0
			return
		3:
			if _phase_t > REJOIN_TIMEOUT:
				# ★ 自己判红(不靠总超时):判词要点明**卡在哪一步**,否则与"回局坏了"分不开。
				_fail("c1 ★ 点了自己那间房后 %.0fs 没回到对局(进 pvp_game=%s / PLAYING 计数 %d→%d)"
						% [REJOIN_TIMEOUT, str(_game != null), _playing_at_leave, _playing_count])
				_finish("")
				return
			if _game == null:
				return
			if not _playing_seen or _playing_count <= _playing_at_leave:
				return    # 还没重新收到服务器的广播
			_ok("c1 回到对局并进入 pvp_game")
			if int(PvpSession.role) != _role_before:
				_fail("c1 ★ 回局后 role 变了(%d → %d):大厅把凭据里的 role 发错了" %
						[_role_before, int(PvpSession.role)])
			else:
				_ok("c1 ★ 回局后 role 与离开前一致(%d)" % _role_before)
			# ★ 这一条才是"真的回到那一局"的证据:离场期间**没有任何** round_state 到达
			#   (客户端断着),回来之后又开始收 —— 计数必须**严格增长**。
			_ok("c1 ★ 回局后重新收到服务器广播(PLAYING 计数 %d → %d)" % [_playing_at_leave, _playing_count])
			_rec("BACK id_before=%d role=%d plays=%d→%d" % [_body_id_before, _role_before,
					_playing_at_leave, _playing_count])
			_finish("")
			return


# 回主菜单之后把大厅连接接回来(偏离③;理由见文件头)。★ 端口是**本探针的大厅端口**,
# 不是默认的 7777 —— 页自己的重连路径永远按默认端口走,这正是必须在本端先连上的原因。
func _connect_lobby_back() -> void:
	if _lobby_back_sent:
		return
	_lobby_back_sent = true
	NetBus.stop()
	var err := NetBus.start_client(LOBBY_ADDR, lobby_port)
	if err != OK:
		_fail("c1 ★ 回大厅:start_client(%s:%d) 失败 err=%d" % [LOBBY_ADDR, lobby_port, err])
		_finish("")
		return
	multiplayer.connection_failed.connect(func() -> void:
		_fail("c1 ★ 回大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port])
		_finish(""), CONNECT_ONE_SHOT)
	multiplayer.connected_to_server.connect(func() -> void:
		_lobby_back = true
		NetBus.rpc_id(1, "lobby_name", "BOT1")
		_log("已重新连上大厅(%s:%d)→ 现在挂大厅页找自己那间房" % [LOBBY_ADDR, lobby_port]),
			CONNECT_ONE_SHOT)


func _esc_and_menu() -> void:
	var pm: Node = null
	for c in _game.get_children():
		if c is PauseMenu:
			pm = c
			break
	if pm == null:
		_fail("对局场景里没找到 PauseMenu")
		_finish("")
		return
	# 真 ESC(理由见 team_match_watcher._esc_leave:keycode 与 physical_keycode 都要给)
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	_rec("PAUSE_MENU opened=%d" % (1 if bool(pm.get("_open")) else 0))
	_log("按 ESC 打开暂停菜单(opened=%s)→ 点「回 到 主 菜 单」" % str(bool(pm.get("_open"))))
	pm.call("go_menu")


# ── c2(对手:这一局还在的见证)──
var _c2_joined := false
func _tick_c2(delta: float) -> void:
	if _game == null:
		# ── 还在大厅:等列表里出现那间房 → 点它(真按钮回调,与真人加入逐字同一条路)──
		if not is_instance_valid(_page):
			if _hard_t > ENTER_TIMEOUT:
				_fail("c2 ★ %.0fs 没能经大厅进入对局(页没挂上/建房没成功?)" % ENTER_TIMEOUT)
				_finish("")
			return
		_tick_refresh(delta, _c2_joined)
		if _c2_joined:
			return
		# ★ 偏离①:brief 这里判的是 `_room_code != ""`,而那条只在"我建的房"上成立(c2 收不到
		#   `room_created`)⇒ 照 brief 写 c2 永远不加入。改成"列表里有可点的行就点"。
		var row := _first_row_button()
		if row == null:
			if _hard_t > ENTER_TIMEOUT:
				_fail("c2 ★ %.0fs 没在房间列表里看到可加入的房(c1 没建成?)" % ENTER_TIMEOUT)
				_finish("")
			return
		_c2_joined = true
		_rec("JOIN row=%s" % row.text)
		_log("点房间列表第一行加入(真按钮回调):%s" % row.text)
		row.pressed.emit()
		return
	# ── 已在场:留满一个观察窗再落盘(见文件头 c2 那一段)──
	if not _obs_started:
		if _hard_t > ENTER_TIMEOUT + 20.0:
			_fail("c2 ★ 进了对局但 %.0fs 内没收到 PLAYING 广播" % (ENTER_TIMEOUT + 20.0))
			_finish("")
		return
	_obs_t += delta
	if _obs_t < C2_OBSERVE:
		return
	_ok("c2 ★ 在场并看到 PLAYING(这一局的见证端)")
	if _snap_total > 0 and _snap_with_opp == _snap_total:
		_ok("c2 ★ 观察窗内掉线者的身体每一帧都在权威快照里(%d/%d 帧,role %d 从未被销毁)"
				% [_snap_with_opp, _snap_total, 3 - int(PvpSession.role)])
	else:
		_fail("c2 ★ 掉线者的身体在权威快照里缺席过(%d/%d 帧有它)—— 身体被销毁了?"
				% [_snap_with_opp, _snap_total])
	if _obs_state_bad:
		_fail("c2 ★ 观察窗内对局离开过 PLAYING 或换了局 —— 回局前后**不是同一局**(也可能只是有人阵亡)")
	else:
		_ok("c2 ★ 观察窗内一直是 PLAYING 且局号未变(%d)—— 这一局从头到尾没重启过" % _obs_round)
	if _snap_max_gap > C2_SNAP_GAP_MAX_MS:
		_fail("c2 ★ 观察窗内权威快照间隔 %.0fms > %.0fms(服务器停过?)"
				% [_snap_max_gap, C2_SNAP_GAP_MAX_MS])
	else:
		_ok("c2 ★ 观察窗内权威快照连续(最大间隔 %.0fms,共 %d 帧)" % [_snap_max_gap, _snap_total])
	_rec("OBS plays=%d snaps=%d with_opp=%d maxgap=%.0fms round=%d state_bad=%s" % [
			_playing_count, _snap_total, _snap_with_opp, _snap_max_gap, _obs_round,
			str(_obs_state_bad)])
	_finish("")


# ── c3(第三人)──
func _tick_c3(delta: float) -> void:
	_tick_refresh(delta, _phase == 1)
	if _phase == 0:
		# ★ 兜底:等不到"对局中"那一行时**自己判红**并落盘 —— 否则裁判只会收到 2/3 份结果,
		#   读起来像"探针坏了",而真正的问题是"c3 什么都没看到"。
		if _hard_t > ENTER_TIMEOUT:
			_fail("c3 ★ %.0fs 内没在列表里看到那个对局中的房(实得 %d 行;server_message=%s)"
					% [ENTER_TIMEOUT, _room_rows, str(_server_msgs)])
			_finish("")
		return
	if _phase_t > RESULT_WAIT:
		# 等够了:这才是 c3 的结论时刻
		if _room_rows != 1:
			_fail("c3 ★ 没在列表里看到那个对局中的房(实得 %d 行)" % _room_rows)
		else:
			_ok("c3 ★ 第三人能看到对局中的房(1 行,code=%s)" % _room_code)
		# ★ 反向对照(c1 那条断言的另一半):同一行、同一份载荷,手里**没有凭据**的人看到的
		#   必须是"点不动"。两条合起来才说明可点性是**按人**判的,而不是"那一刻所有人都能进"。
		if not _c3_row_disabled:
			_fail("c3 ★ 那一行对**没有凭据的第三人**也是可点的 —— 可点性不是按人判的")
		else:
			_ok("c3 ★ 同一行对第三人仍是 disabled(按人判:凭据在他的手里,不在我手里)")
		var joins_before := _joins
		var go_before := _go_match
		var refused := false
		for m in _server_msgs:
			if m.contains("无法加入") or m.contains("对局已进行中") or m.contains("房间不存在"):
				refused = true
		if joins_before != 0 or go_before != 0 or not refused:
			_fail("c3 ★ 加入被拒这条没成立(room_joined=%d 次 / go_match=%d 次 / 拒绝提示=%s)"
					% [joins_before, go_before, str(_server_msgs)])
		else:
			_ok("c3 ★ 加入被拒(无 room_joined / 无 go_match / 有拒绝提示)")
		_rec("REFUSE joins=%d go=%d msgs=%s" % [joins_before, go_before, str(_server_msgs)])
		_finish("")


# ── 结果与日志 ──
func _log(s: String) -> void:
	print("WATCHER[%s] t=%.1f %s" % [who, _t, s])


func _ok(msg: String) -> void:
	_checks += 1
	print("WATCHER[%s] OK " % who + msg)
	_rec("OK " + msg)


func _fail(msg: String) -> void:
	_checks += 1
	_fails.append(msg)
	print("WATCHER[%s] FAIL " % who + msg)


func _rec(line: String) -> void:
	# ★ 偏离⑤:读数进内存,`_finish` 时**连同断言账本一起**写进结果文件。
	#   (brief 的 `_rec` 直接写文件,而 `_finish` 用 WRITE 打开同一个文件 → 之前那些行全被截掉,
	#    读日志的人拿不到任何中间读数。)
	_recs.append(line)
	_log("REC " + line)


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if why != "" and _fails.is_empty():
		_fail(why)
	# ★★ 计数守卫(只对"否则会打印 OK"的那一跑生效):本探针是回局这条路**唯一的**观测者,
	#   一段被截断的跑(阶段梯没走到、客户端早退、`--quit-after` 到期)不许读成通过。
	var min_checks := int(MIN_CHECKS.get(who, 1))
	if _fails.is_empty() and _checks < min_checks:
		_fail("只跑了 %d 条断言(期望 ≥ %d)—— 有阶段没跑到,这个 OK 不算数" % [_checks, min_checks])
	var head := "OK" if _fails.is_empty() else "FAIL(%d)" % _fails.size()
	var f := FileAccess.open("user://rejoin_probe_%s.result" % who, FileAccess.WRITE)
	if f != null:
		f.store_line(head)
		for e in _recs:
			f.store_line("REC " + e)
		for e in _fails:
			f.store_line("  - %s" % e)
		f.close()
	# ★★ **c2 / c3 落盘后不退出**(`hold_alive`):它们的结果只是"我这边的读数",而**对局必须继续
	#   活着** —— c2 是对手,它一退,worker 就把 role 2 送进宽限期(相② 的前提"这一局还在"就
	#   变了味);c3 虽然不在局里,留着也不花任何代价。真正的收尾是**裁判按 PID 杀**
	#   (`_kill_children`),子进程另有一条 `--quit-after` 兜底。
	#   c1 是 actor:它的剧本跑完就该退,退出不改变任何结论。
	if hold_alive:
		print("WATCHER[%s] 结果已落盘,保持在线等裁判收尾" % who)
		return
	get_tree().quit(0 if _fails.is_empty() else 1)
