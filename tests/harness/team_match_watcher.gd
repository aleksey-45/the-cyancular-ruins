extends Node

# 3v3 真链路探针(`tests/probe/team_match_probe.*`)的**观察者**(客户端子进程用)。
# 挂在 `get_tree().root` 上:换场(真 `team_lobby` → 真 `team_game`)不会把它带走
# → 它能在**换场之后**读真 `team_game` 实例的状态(与 royale_c2_watcher / reconnect_watcher 同款)。
#
# ★ 它做的四件事:
#   ① 驱动**真大厅页**(`scenes/team_lobby.tscn`):建房 / 点房间列表加入 / 选边 / 房主开局。
#      —— 这就是"A 册/B 册那五条从没被真跑过"里的①:等待室渲染路径(`team_room_state`)。
#   ② 换场后接管**真 `team_game`**:注入脚本手柄(`team_bot_input.gd`),按快照驱动走位/开火。
#   ③ 按相位采样并做**客户端侧**断言(收敛 / 队友弹穿透 / 换边 / 掉线观察窗)。
#   ④ 把带 `REC ` 前缀的结构化读数写进结果文件,交给裁判(探针进程)做跨端比对。
#
# ★ 为什么读数要写成行文本而不是"客户端自己判完就完事":跨端断言(6 端队伍表是否与大厅一致、
#   队内/队间距离、换边是否对调、掉线后其余端还在收快照)**天然需要全部 6 端的数据在一处**,
#   而 6 端是 6 个独立进程。裁判读结果文件就是那个"一处"(与 royale_c2_probe 的 `_read_result`
#   同一手法;子进程 stdout 父进程看不到,见探针文件头)。
#
# ★ 相位编号是本文件自己的(相①..相⑤),与其它探针的编号无关。
#
# ═══ 相⑤ 的一处**照实偏离**(brief 写的是"排行榜里 6 号标「离开」")═══
#   3v3 的 `TeamHost._broadcast_round_state` 载荷**没有** `left` / `alive` / `names` 三个键
#   (它们只在大乱斗版里有),而 3v3 的 HUD(`ui/team_hud.gd`)是"按队记分条",**没有**排行榜 ——
#   所以"排行榜标离开"在 3v3 里**没有对应物**。客户端真正可观测的等价信号有两条,本探针都取:
#     ① `round_state` 恒为 PLAYING(服务器不终局、该队少人继续);
#     ② 掉线者在**世界快照**里消失 → `team_game._on_snapshot_world` 把它的副本/头顶 ID 一起拆掉
#        (`_replica_for(role) == null`)。这正是"该 role 已被移出对局"在客户端的**唯一**投影。
#   两条都要等宽限期(60s)到点才成立 —— 观察窗按它定,见 OBSERVE_MAX。

const BotHandle := preload("res://tests/harness/team_bot_input.gd")

const RESULT_PREFIX := "team_match_probe_"
const LOBBY_ADDR := "127.0.0.1"
const TILE := 64
const REPLICA_COUNT := 5          # 3v3:自己以外 5 个角色(副本数是**断言**,见 _check_team_visual_layer)

# ── 时间预算(逐条都有理由;改前先读相位注释)──
const ENTER_TIMEOUT := 90.0      # 从挂页到"进 team_game 且拿到队伍表"的兜底
const TEAMS_TIMEOUT := 25.0      # 进局后等 match_sync 应答
const SETTLE := 1.2              # PLAYING 后静置多久再采样(COUNTDOWN 期间输入冻结,人不会动)
const POS_TOL := 100.0           # C2 收敛判据(px):快照滞后一 tick ≈ 11.7px,100 留足余量
# 相③ 的"到位"判据。★ **子弹那一半与榴弹那一半不同**:brief 对子弹只说"朝队友开一枪",
# 对榴弹才要求"贴脸"。把子弹也卡在 170px 会让整相挂在**走位**上(留存的 6 份判决日志里,
# 甲一次都没进过 170px),
# 而子弹的证据链(乙端数"从我身边 ≤45px 飞过的非自己子弹")在 400px 上照样成立 ——
# 目标站着不动,子弹飞过去必然要掠过它。榴弹仍要 170px(爆炸半径 350px,170 稳在内圈附近)。
const CLOSE_PX := 400.0          # 甲进入这个距离且有视线即开火(子弹那半边)
const GRENADE_PX := 170.0        # 榴弹那半边的"贴脸"判据
const RENDEZVOUS_MAX := 100.0    # 相③ 走位 + 连射 + 榴弹的总窗口(平台跳跃图上走位很慢)
const VOLLEY := 2.6              # 对队友的连射时长
const NEAR_PX := 45.0            # (乙端)"子弹从我身边飞过"的判定半径(权威命中半径 40 + 余量)
const BRAWL_MAX := 210.0         # 相④ 打到 9 杀的上限(脚本机器人互射)
const FIGHT_PX := 520.0          # 混战:进入这个距离且视线通畅就开火
const LEAVE_AT := 2.5            # 第 2 局 PLAYING 后多久按 ESC(相⑤)
# 相⑤ 观察窗。★ 推导:必须盖住「宽限期(`GraceWindow.DEFAULT_SECONDS`)到点」这一刻 ——
#   掉线者被移出对局发生在宽限到期时,而 `_expire_graces` 每秒才轮询一次(故实际落在 60~61s),
#   本端还要从第 2 局 PLAYING 起算(`_tick_swap` 里 6 号按 ESC 与本端进窗**同一拍**)。
#   取 110 = 60 + 50(旧值 60 = 30 + 30,同形:盖住宽限期后余下 ~50s 给负载与轮询粒度)。
#   ★ 改 `GraceWindow.DEFAULT_SECONDS` 必须重算这里;它同时进 `team_match_probe.RESULT_WAIT` 的求和。
const OBSERVE_MAX := 110.0
const PEER_WAIT := 120.0         # 等其它 5 端写结果的上限(本端最后一个走)
# 开火脉冲:三类武器(全自动按住连发 / 半自动按下单发 / heavy_aim 松开发射)在**脉冲**下都能开火。
const PULSE_ON := 0.30
const PULSE_OFF := 0.25

# ── 相位 ──
enum {
	PH_LOBBY,      # 驱动大厅页(建房/加入/选边/开局)
	PH_ENTER,      # 等换场 + 队伍表(相①前半)
	PH_PLAY,       # 第 1 局 PLAYING:采样 + 收敛(相①后半、相②)
	PH_MEET,       # 相③:走近队友 → 连射(穿透)/ 榴弹(满效)
	PH_BRAWL,      # 相④:混战到 ROUND_OVER
	PH_SWAP,       # 相④后半:第 2 局 PLAYING 采样(换边)+ 6 号离场
	PH_OBSERVE,    # 相⑤:观察窗
	PH_DONE,
}
# 相③ 的子状态
enum { MEET_SEEK, MEET_SWITCH_BULLET, MEET_VOLLEY, MEET_GL_SWITCH, MEET_GL_FIRE, MEET_SETTLE, MEET_OVER }

# ── 注入(探针进程给)──
var who := "c1"
var idx := 1
var lobby_port := 29200

# ── 大厅阶段 ──
var lobby: Node = null           # 真 team_lobby 页(探针把它挂在**探针场景**下 → 换场时被自然 free)
var _lobby_attached := false
var _created := false
var _joined := false
var _pick_emitted := false
var _picked := false
var _started := false
var _rooms: Array = []
var _room_states := 0            # 收到几份 team_room_state(等待室渲染路径的证据)
var _list_rows := 0              # 房间列表渲染出的行数
var _wait_rows := 0              # 等待室名单行数(含两队标题行)
var _wait_count_text := ""       # 等待室计数文案

# ── 对局阶段 ──
var _game: Node = null
var _local: Node2D = null
var _bot = null
var _entered := false
var _phase := PH_LOBBY
var _phase_t := 0.0
var _t := 0.0
var _role := 0
var _team := 0
var _teams: Dictionary = {}
var _snap_world: Dictionary = {}
var _snap_gaps: Array[float] = []
var _last_snap_us := 0
var _snap_max_gap := 0.0          # 全会话最大快照间隔(含进对局建世界那段 —— 见 _on_snap_world)
var _snap_max_phase := -1         # 它发生在哪个相位
var _obs_max_gap := 0.0           # ★ **观察窗内**的最大间隔(相⑤ 的判据用这个)
var _round_state := -1
var _round := 0
var _scores: Dictionary = {}
var _rounds_won: Dictionary = {}
var _match_over := false
var _played_rounds: Array[int] = []

# ── 相③ ──
var _shooter := false
var _shooter_role := 0
var _victim_role := 0
var _meet_sub := MEET_SEEK
var _sub_t := 0.0
var _shots := 0                  # 本端朝队友开火的**本地子弹生成数**(证据:枪真的响了)
var _seen_bullet_ids: Dictionary = {}
var _near_ids: Dictionary = {}
var _near_count := 0             # (乙端)从身边飞过的**非自己**子弹数
var _hp_before := -1
var _hp_after_bullet := -1
var _hp_after_grenade := -1
var _bullet_rec := ""
var _grenade_rec := ""
var _gl_reason := ""
var _dist_at_fire := -1.0
var _ready_to_fire := false
var _vic_pos_before := Vector2.INF
var _vic_knock := 0.0
var _pulse_t := 0.0

# ── 采样 / 观察 ──
var _pos_r1 := Vector2i(-1, -1)
var _pos_r2 := Vector2i(-1, -1)
var _conv_px := -1.0
var _r1_winner := 0
var _esc_done := false
var _leave_t := -1.0
var _gone_roles: Array[int] = []   # 快照里消失的 role(= 已被服务器移出对局)
var _left_in_replica := -1         # 观察窗结束时,掉线者的副本是否已拆(-1 = 未判)
var _obs_playing := true          # 观察窗内 round_state 是否恒为 PLAYING
var _obs_playing_bad := false

# ── 收尾 ──
var _done := false
var _quitting := false
var _lines: Array[String] = []
var _fails: Array[String] = []


# ════════════════════ 生命周期 ════════════════════

func _ready() -> void:
	NetBus.local_snapshot_world.connect(_on_snap_world)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(_on_kill_event)
	# match_sync 应答计数:换边后客户端**必须重拉一次**(A 册/B 册约定,见 team_game._on_round_state)
	# —— 只数次数,内容比对在相④ 的出生点断言里。
	NetBus.local_match_sync.connect(func(_p: Dictionary) -> void: _msync += 1)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_failed)
	var e := NetBus.start_client(LOBBY_ADDR, lobby_port)
	if e != OK:
		_fail("start_client(大厅 %s:%d)失败 err=%d" % [LOBBY_ADDR, lobby_port, e])
		_finish()
		return
	_log("观察者就绪;连大厅 %s:%d" % [LOBBY_ADDR, lobby_port])


func _on_lobby_failed() -> void:
	_fail("连大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port])
	_finish()


# 连上大厅:上报昵称 → **帧末**挂真大厅页。
# ★ 页挂在**探针场景**下(不是本节点下):换场时 `change_scene_to_file` 会 free 掉探针场景,
#   页随之消失 —— 这正是生产里的形状。留在树上的话,它的 `_tick_claim_timeout` 会在 claim 后
#   25s 调 `_return_to_lobby` → `NetBus.stop()`,把正在进行的对局从客户端这边掐断
#   (症状是"进局 25s 后掉线",且不报错)。
func _on_lobby_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", "BOT%d" % idx)
	_attach_lobby.call_deferred()


func _attach_lobby() -> void:
	if _lobby_attached:
		return
	var cs := get_tree().current_scene
	if cs == null:
		return
	lobby = load("res://scenes/team_lobby.tscn").instantiate()
	# ★★ `_with_lobby` 的快路判据是两个**字符串**相等(`_connected_addr == 地址框`),故只预置
	#   已连**不够**:页的地址框初值取的就是 `PvpSession.server_address`,而它的生产默认是
	#   **云服**(`core/net/pvp_session.gd` 初值 120.53.107.140)。不拨这一行,下面两个 set 白设 ——
	#   一帧后页发现"已连地址(127.0.0.1)≠ 地址框(云服)"⇒ `NetBus.stop()` + 按**默认端口
	#   7777** 去连公网生产服(还会在它上面真的建房),而本探针的大厅(池外端口)被晾着。
	#   ★ 这个坑**静默**:日志里满是本端自己的「已连接服务器」,看着像连上了(实测的症状是
	#   探针侧"一条 `玩家连入` 都没有 + 45s 后没有 3v3 房")。回归源 `fad4759`。
	#   范本:`tests/harness/rejoin_watcher.gd::_on_node_added` / `tests/probe/royale_c2_probe.gd::_run_client`。
	#   守卫:`_tick_lobby` 首段(连错地址当场点名)。
	PvpSession.server_address = LOBBY_ADDR
	# ★ 本进程已经连上大厅(上面 start_client),而页的 `_ready` 会 deferred 跑一次
	#   `_request_list` → `_with_lobby`:只有"已连同地址"那一支会复用现有连接,否则它会
	#   `NetBus.stop()` 再按**默认端口 7777** 重连 —— 而本探针的大厅在池外端口(见探针文件头)。
	#   故**先置位再入树**,让页走"已连"分支。
	lobby.set("_connected", true)
	lobby.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(lobby)
	_lobby_attached = true
	_log("真大厅页已挂载(current_scene=%s)" % cs.name)


func _physics_process(delta: float) -> void:
	if _quitting:
		return
	# ★ 对局场景可能已经**退役**(MATCH_OVER 后客户端 6s 自动回主菜单 → `safe_change_scene`
	#   把整具世界拆掉),而本观察者挂在 root 上、**照样在跑** —— 不判这一档就会每帧对已释放
	#   实例取字段:`Invalid access to property or key 'global_position' on a base object of type
	#   'previously freed'`(实测 run14)。退役即收工:把手上读数落盘、退出。
	if _local != null and not is_instance_valid(_local):
		if not _done:
			_fail("对局世界已退役(客户端已离开对局)——观察者停止采样")
			_finish()
		return
	_t += delta
	_phase_t += delta
	_sub_t += delta
	if not _entered:
		_try_enter_game()
	_heartbeat(delta)
	_tick_k2(delta)
	match _phase:
		PH_LOBBY:
			_tick_lobby()
			_tick_start()
			if _entered:
				_phase = PH_ENTER
				_phase_t = 0.0
		PH_ENTER:
			_tick_enter()
		PH_PLAY:
			_tick_play()
		PH_MEET:
			_tick_meet(delta)
		PH_BRAWL:
			_tick_brawl_phase(delta)
		PH_SWAP:
			_tick_swap(delta)
		PH_OBSERVE:
			_tick_observe()
		PH_DONE:
			pass


# 心跳(诊断用):每 5s 一行。探针挂住/超时时,这三样一起看就能定位到底卡在哪:
#   相位 + 目标距离 + 视线 —— "机器人走不到人"与"走到了但打不死"是两种完全不同的故障,
#   只看"没打出 9 杀"分辨不出来。也顺带把"到底有没有交战"记下来(比分/局号)。
var _hb_t := 5.0


func _heartbeat(delta: float) -> void:
	_hb_t -= delta
	if _hb_t > 0.0 or not _entered:
		return
	_hb_t = 5.0
	if _local == null or _bot == null:
		return
	var tgt := Vector2.INF
	if _phase == PH_MEET:
		# 甲的目标是乙、乙的目标是甲(**两个分支必须不同** —— 早先写成同一个表达式时,
		# 乙的心跳一直在报"到自己"的距离(144px),读数看起来像"两边距离对不上",
		# 排查时白绕了一圈)
		tgt = _pos_of(_victim_role) if _shooter else _pos_of(_shooter_role)
	elif _phase == PH_BRAWL:
		tgt = _nearest_enemy()
	var d := -1.0
	var los := false
	if tgt != Vector2.INF:
		d = _delta(_local.global_position, tgt).length()
		los = _los_to(tgt)
	_log("♥ t=%.0f 相位=%d 角色=%d/队%d 目标距=%.0f 视线=%d 比分=%s 局%d 状态%d 甲=%d"
			% [_t, _phase, _role, _team, d, 1 if los else 0, _dict_str(_scores), _round,
			_round_state, 1 if _shooter else 0])


# ════════════════════ 大厅阶段 ════════════════════

# ★★ 本函数**只读页的 UI 状态、只按真按钮**,而页自己的信号处理(`_on_room_state` 里建等待室)
#   与我的处理**同帧竞争**:我只在 `_ready` 里连信号(比页早 → 我的处理器先跑),所以"读页的
#   等待室控件"这件事**不能**放在信号处理器里 —— 实测:`team_room_state` 刚到那一帧
#   `_pick_a` 还是 null,当场 `_fail` 并**永久卡住**(选边永不发出 → 全流程停摆)。
#   故:信号处理器只登记原始数据,页的 UI 状态一律在这里(下一帧起)轮询取用。
func _tick_lobby() -> void:
	# ★ 换场那一刻页已被 free,而本帧的相位还没切走(先 tick 后判 `_entered`)→ 必须挡掉
	#   对已释放实例的访问,否则每跑都在换场那一帧抛一条 SCRIPT ERROR(实测)。
	if lobby == null or not is_instance_valid(lobby):
		return
	if not _lobby_attached:
		if _phase_t > ENTER_TIMEOUT:
			_fail("大厅页没挂上(%.0fs)" % ENTER_TIMEOUT)
			_finish()
		return
	# ★★ 守卫(照 `royale_c2_watcher._stage_lobby`):本端连的必须是**本探针的大厅**,不能是云服。
	#   入树后一帧,页 `_ready` 那次 deferred `_request_list` 已跑完:地址框的值被写回
	#   `PvpSession.server_address`,而连错时 `_connected_addr` 也会跟着变成那个错地址。
	#   (`_attach_lobby` 预置的 `_connected_addr` 是**我们自己**写的值,它单独证明不了什么 ——
	#    真正会露馅的是 `PvpSession.server_address`。)当场点名,别让下一个人再从
	#   "45s 后没有 3v3 房"逆推。★ 漏了 `_attach_lobby` 那行预置就是这个守卫拦的。
	if PvpSession.server_address != LOBBY_ADDR or String(lobby.get("_connected_addr")) != LOBBY_ADDR:
		_fail("本端连的是 %s,不是本探针大厅 %s —— 检查 _attach_lobby 里 PvpSession.server_address 的预置"
				% [PvpSession.server_address, LOBBY_ADDR])
		_finish()
		return
	# 房间列表渲染路径:页把每个房间画成**一行按钮**(空态画的是一个 Label,不算行)
	if _list_rows == 0:
		var n := _list_button_count()
		if n > 0:
			_list_rows = n
			_log("房间列表渲染出 %d 行房间" % _list_rows)
	if idx == 1:
		if not _created and _phase_t > 0.6:
			_created = true
			_log("点「创 建 房 间」")
			lobby.call("_on_create_pressed")
	else:
		_tick_lobby_join()
	_tick_pick()


# c2..c6:点公开列表里的房间行(真按钮回调)。
# ★ 首份列表**必然**是空的(c2 挂页时 c1 还没建房),而 `team_list` 是**请求/响应**式
#   —— 不重问就永远是空。故这里按 1.5s 周期点一次「刷新列表」(真按钮),直到进房。
func _tick_lobby_join() -> void:
	if _joined or lobby == null or not is_instance_valid(lobby):
		return
	_refresh_t -= 1.0 / 60.0
	if _refresh_t <= 0.0 and _phase_t > 1.0:
		_refresh_t = 1.5
		lobby.call("_on_refresh_pressed")
		return
	if _rooms.is_empty():
		return
	var code := str((_rooms[0] as Dictionary).get("code", ""))
	if code.is_empty():
		return
	_joined = true
	var lb = lobby.get("_list_box")
	if lb != null:
		for c in lb.get_children():
			if c is Button and str((c as Button).text).contains(code):
				(c as Button).pressed.emit()
				_log("点房间列表行 %s(真按钮回调)" % code)
				return
	_log("列表行未就绪 → 直接调 _join_room(%s)(列表行回调也是调它)" % code)
	lobby.call("_join_room", code, "")


var _refresh_t := 1.2


func _list_button_count() -> int:
	var lb = lobby.get("_list_box")
	if lb == null:
		return 0
	var n := 0
	for c in lb.get_children():
		if c is Button:
			n += 1
	return n


func _on_team_rooms(rooms: Array) -> void:
	_rooms = rooms


# 等待室渲染(`team_room_state`)—— A 册自检里"从没收到过 team_room_state"的那条路径。
# 本处理器**只登记**(理由见 `_tick_lobby` 上方那段);读页控件在 `_tick_pick`。
func _on_room_state(state: Dictionary) -> void:
	_room_states += 1
	if _room_states == 1:
		_log("等待室:收到第 1 份 team_room_state(your_role=%d players=%d team_size=%s)"
				% [int(state.get("your_role", 0)), (state.get("players", []) as Array).size(),
				str(state.get("team_size", -1))])
	# 选边是否已经生效(服务器回了"该队已满"时状态不变 → 由 `_tick_pick` 重试)
	var my_role := int(state.get("your_role", 0))
	var want := 1 if idx <= 3 else 2
	for p in (state.get("players", []) as Array):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == my_role \
				and int(p.get("team", 0)) == want:
			_picked = true


# 选边(真按钮回调 → team_pick)。等页把等待室建出来(见 `_tick_lobby` 上方那段)。
func _tick_pick() -> void:
	if _picked or _room_states <= 0 or lobby == null or not is_instance_valid(lobby):
		return
	# 已发过但没生效(服务器回过"该队已满")→ 每 2s 重试
	if _pick_emitted:
		_pick_retry_t -= 1.0 / 60.0
		if _pick_retry_t > 0.0:
			return
		_pick_retry_t = 2.0
	# 顺手登记等待室的渲染结果(此刻页的 `_on_room_state` 一定已经跑过了)
	if _wait_rows == 0:
		var wp = lobby.get("_wait_players")
		if wp != null:
			_wait_rows = wp.get_child_count()
		var wc = lobby.get("_wait_count")
		if wc != null:
			_wait_count_text = str((wc as Label).text)
	var want := 1 if idx <= 3 else 2
	var btn = lobby.get("_pick_a" if want == 1 else "_pick_b")
	if btn == null:
		return     # 等待室还没建出来 → 下一帧再看(这里**不能** _fail)
	if _wait_rows > 0 and not _pick_logged:
		_pick_logged = true
		_log("等待室已渲染(名单行 %d,计数 %s)" % [_wait_rows, _wait_count_text])
	_pick_emitted = true
	(btn as Button).pressed.emit()
	_log("点「加入 %s 队」" % ("A" if want == 1 else "B"))


var _pick_logged := false
var _pick_retry_t := 2.0
var _kills_attr := 0
var _kills_unattr := 0
# ★ 相⑤ 补:K 键自杀的**端到端**(3v3 里 A 册收尾批才把 `suicide_request` 接上 worker,
#   此前它在 3v3 是**静默丢弃**的)。第 3 号客户端在第 2 局 PLAYING 里按一次 K,
#   观测「权威快照 downed=true → 2s 后 false」这条链(1 次击杀不足以改变局面)。
# ★ 这个观测**必须跨相位跑**(PH_SWAP → PH_OBSERVE):早先写在 `_tick_swap` 里,而
#   `_tick_swap` 在 PH_SWAP 结束(1.2s)后就不再被调 ⇒ 观测窗口只有 0.2s ⇒ **永远等不到复活**
#   (实测 run9:六端 0 端报告走通,而 K 其实已经按下去了)。
func _tick_k2(delta: float) -> void:
	if idx != 3 or _game == null or _phase < PH_SWAP:
		return
	if not _k2_pressed and _round == 2 and _round_state == 1 and _phase_t > 1.0:
		_k2_pressed = true
		_log("★ 相⑤ 补:按 K 自杀脱困(3v3 的 K 端到端)")
		_k_suicide()
		return
	if not _k2_pressed or _k2_revived:
		return
	_k2_t += delta
	var own: Dictionary = (_snap_world.get("players", {}) as Dictionary).get(str(_role), {})
	if bool(own.get("downed", false)):
		_k2_downed = true
	elif _k2_downed:
		_k2_revived = true
		_rec("K2 downed=1 revived=1 secs=%.1f" % _k2_t)
		_log("★ 相⑤ 补:K 自杀 → 倒地 → 复活(%.1fs)" % _k2_t)
	elif _k2_t > 8.0:
		_k2_revived = true      # 只报一次
		_rec("K2 downed=0 revived=0")
		_fail("按 K 后 8s 内权威快照始终没有 downed=true(3v3 的 K 端到端没走通)")


var _backoff := false                # 相④ 回退模式(见 _tick_backoff)
var _backoff_t := 0.0
var _backoff_n := 0
var _since_kill := 0.0
var _last_score_total := -1
var _msync := 0                      # 收到几份 match_sync 应答(进场 1 次 + 每局 COUNTDOWN 重拉)
var _k2_pressed := false             # 相⑤ 补:第 2 局按 K(3v3 的 K 端到端)
var _k2_downed := false
var _k2_revived := false
var _k2_t := 0.0


# c1:两队各 3 人 → 「开始游戏」按钮可见 → 点它(真按钮回调 → team_start)
func _tick_start() -> void:
	if idx != 1 or _started or not _lobby_attached:
		return
	if lobby == null or not is_instance_valid(lobby):
		return
	var b = lobby.get("_start_btn")
	if b == null or not (b as Button).visible:
		return
	_started = true
	_log("两队各 3 人 → 点「开 始 游 戏」(真按钮回调)")
	(b as Button).pressed.emit()


# ════════════════════ 对局阶段 ════════════════════

func _is_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("team_game.gd")


func _try_enter_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		return
	var local = cs.get("_local")
	if local == null:
		return     # 场景 `_ready` 还没跑完(局部玩家未就位)
	_game = cs
	_local = local
	_role = PvpSession.role
	# ★★ **序前提的运行时断言**:本观察者必须排在游戏场景**之前**(树序),否则它写的输入
	#    会在玩家已处理完那一帧才落到手柄上 ⇒ 边沿全部丢失、服务器侧又不跳不开火,而**不报错**。
	#    前提的来源:本节点由探针用 `root.add_child` 在换场**之前**挂上(树序在前)。
	if cs.get_index() < get_index():
		_fail("观察者在树序里排在游戏场景**之后**(index %d vs %d)—— 输入边沿会整帧丢失"
				% [get_index(), cs.get_index()])
	else:
		_log("树序就位:观察者 index=%d 在游戏场景 index=%d 之前" % [get_index(), cs.get_index()])
	_bot = BotHandle.new()
	_local.set_input_source(_bot)
	_entered = true
	_phase_t = 0.0
	_log("已进入 team_game(role=%d spawn=%s)" % [_role, str(PvpSession.spawn)])


# ── 相①(前半):队伍表 ──

func _tick_enter() -> void:
	if _teams.is_empty():
		var t = _game.get("_teams")
		if t is Dictionary and not (t as Dictionary).is_empty():
			_teams = (t as Dictionary).duplicate()
			_team = int(_teams.get(_role, 0))
			_rec("TEAMS role=%d team=%d map=%s" % [_role, _team, _teams_str()])
			_log("队伍表:role=%d team=%d %s" % [_role, _team, _teams_str()])
			# 相③ 角色指派(全端各自独立算出同一结果,不需要协调):
			#   "甲" = 1 队里 role 最小者,"乙" = 1 队里 role 次小者。
			var a: Array = []
			for r in _teams:
				if int(_teams[r]) == 1:
					a.append(int(r))
			a.sort()
			_shooter_role = int(a[0]) if a.size() >= 2 else 0
			_shooter = a.size() >= 2 and _role == _shooter_role
			_victim_role = int(a[1]) if a.size() >= 2 else 0
			if _shooter:
				_log("本端是甲:目标队友(乙)role=%d" % _victim_role)
		elif _phase_t > TEAMS_TIMEOUT:
			_fail("进局后 %.0fs 没收到 match_sync(队伍表为空)" % TEAMS_TIMEOUT)
			_finish()
			return
	if _round_state != 1:
		return
	_phase = PH_PLAY
	_phase_t = 0.0


# ── 相②(采样)+ 相①(收敛)──

func _tick_play() -> void:
	if _phase_t < SETTLE:
		return
	var cell := GridPathfinder.cell_of(_local.global_position, TILE, _dims().x, _dims().y)
	_pos_r1 = cell
	var own: Dictionary = (_snap_world.get("players", {}) as Dictionary).get(str(_role), {})
	if own.is_empty():
		_fail("没收到含自己那份的世界快照(收敛判据缺地面真值)")
	else:
		var sp: Vector2 = own.get("pos", _local.global_position)
		_conv_px = _delta(_local.global_position, sp).length()
		var ok := _conv_px <= POS_TOL
		_rec("CONV px=%.1f tol=%.0f ok=%d" % [_conv_px, POS_TOL, 1 if ok else 0])
		if not ok:
			_fail("本地玩家与权威快照未收敛:%.1fpx > %.0f" % [_conv_px, POS_TOL])
	_rec("R1POS role=%d team=%d cell=%d,%d" % [_role, _team, cell.x, cell.y])
	_log("相② 第 1 局出生格 %s(team=%d,收敛 %.1fpx)" % [str(cell), _team, _conv_px])
	_check_team_visual_layer()
	_phase = PH_MEET
	_phase_t = 0.0
	_sub_t = 0.0
	_meet_sub = MEET_SEEK
	_hp_before = _hp_of(_victim_role)


# ── 队色 + 分队碰撞层:**两端是否真的对齐**(A 册定的契约,客户端这一半在 team_game)──
# 契约(A 册 `TeamHost._init` 末段 / `_apply_team_layers`):
#   1 队 玩家 layer=2 mask=1|4|16 ;2 队 玩家 layer=16(TERM_ENEMY_LAYER) mask=1|4|2
#   副本幽灵体 layer 按**它代表的那名玩家**的队,mask 恒 0。
# 队色:`_apply_tint(..., color_override)` 走 **modulate 比值** ⇒ 有效身体色 = modulate × 主色。
# ★ 为什么这条要在真链路里查:服务端与客户端**各自**实现一半(A 册服务端 / B 册客户端),两边
#   数值不一致 = 可走空间不一致 = **每帧回滚**(不报错,只表现为"手感发飘");而队色错 =
#   6 个人里认不出队友。两者都只有"拿真对象的真字段比对"才看得出来。
func _check_team_visual_layer() -> void:
	var want_layer := 2 if _team == 1 else TeamHost.TEAM_ENEMY_LAYER
	var layer_ok: bool = _local.collision_layer == want_layer
	var mask_ok := false
	if _team == 1:
		mask_ok = (_local.collision_mask & 2) == 0 \
				and (_local.collision_mask & TeamHost.TEAM_ENEMY_LAYER) != 0 \
				and (_local.collision_mask & 1) != 0     # 地形位不能丢(丢了会穿墙)
	elif _team == 2:
		mask_ok = (_local.collision_mask & 2) != 0 and (_local.collision_mask & 1) != 0
	var ghosts_bad := 0
	var tints_bad := 0
	var n := 0
	# ★★ 副本数**必须断言**:`ghosts_bad`/`tints_bad` 数的是"副本里有多少个错的",副本**一个都没建**
	#    时两个计数天然是 0 ⇒ 全绿而**什么都没验**(恒真空位 —— 评审点名的那个)。
	var want_reps: int = REPLICA_COUNT
	var reps: Dictionary = _game.get("_replicas")
	for role in reps:
		var r = reps[role]
		if r == null or not is_instance_valid(r):
			continue
		n += 1
		var ot := int(_teams.get(int(role), 0))
		var g = r.get_node_or_null("GhostBody")
		var want_g := 2 if ot == 1 else TeamHost.TEAM_ENEMY_LAYER
		if g != null and (int(g.collision_layer) != want_g or int(g.collision_mask) != 0):
			ghosts_bad += 1
		var spr = r.get_node_or_null("AnimatedSprite2D")
		if spr != null:
			var want_c: Color = UiFactory.C_TEAM_A if ot == 1 else UiFactory.C_TEAM_B
			var got: Color = (spr as CanvasItem).modulate * PvpMatchClient.BODY_BASE_COLOR
			if not _color_close(got, want_c):
				tints_bad += 1
	_rec("TEAMFMT layer=%d mask=%d ok_layer=%d ok_mask=%d reps=%d ghosts_bad=%d tints_bad=%d"
			% [_local.collision_layer, _local.collision_mask, 1 if layer_ok else 0,
			1 if mask_ok else 0, n, ghosts_bad, tints_bad])
	_log("队色/分队层:自己 layer=%d mask=%d(层对=%s 掩码对=%s);副本 %d 个(幽灵层错 %d,队色错 %d)"
			% [_local.collision_layer, _local.collision_mask, str(layer_ok), str(mask_ok),
			n, ghosts_bad, tints_bad])
	if n != want_reps:
		_fail("副本数 %d != %d(队友的队色/幽灵层**一个都没验到** —— 计数天然为 0 的恒真空位)"
				% [n, want_reps])
	if not layer_ok or not mask_ok:
		_fail("自己那一半的分队碰撞层与 A 册契约不符(layer=%d mask=%d team=%d)"
				% [_local.collision_layer, _local.collision_mask, _team])
	if ghosts_bad > 0:
		_fail("有 %d 个副本的幽灵体层与队不符(队友会互挡 → C2 每帧回滚)" % ghosts_bad)
	if tints_bad > 0:
		_fail("有 %d 个副本的身体色不是队色(6 人局里认不出队友)" % tints_bad)


func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.06 and absf(a.g - b.g) < 0.06 and absf(a.b - b.b) < 0.06


# ── 相③:队友弹穿透(负)+ 榴弹满效(正)──

func _tick_meet(delta: float) -> void:
	if _shooter:
		_tick_meet_shooter(delta)
		return
	# 乙:**也朝甲走**(相向而行 —— 平台跳跃图上单向走位成功率太低,留存的日志里单侧走一整个
# 窗口都还没贴合(见报告 §7)。
	# 1800px)。走到 CLOSE_PX*1.5 内就站住不动:射击要打的是**静止靶**,两边一起飘会打不中。
	if _role == _victim_role:
		var sp := _pos_of(_shooter_role)
		if sp != Vector2.INF:
			if _delta(_local.global_position, sp).length() > CLOSE_PX * 1.5:
				_nav_to(sp, CLOSE_PX * 1.2, delta)
			else:
				_bot.axis = 0.0
				_bot.attack = false
				_bot.hold_up = false
				_bot.hold_down = false
		_count_near_bullets()
	else:
		# 其余四人:站着不动,别干扰读数
		_bot.axis = 0.0
		_bot.attack = false
	if _phase_t > RENDEZVOUS_MAX:
		_phase = PH_BRAWL
		_phase_t = 0.0


func _tick_meet_shooter(delta: float) -> void:
	# ★ 甲的**超时兜底**:走位窗口用完就带着手上有的读数进混战 —— 早先这个超时只写在不走位的
	#   那一支里,于是甲若一直没能贴脸(出生点落在密封小间/中间隔着到不了的地形),它会
	#   **在 PH_MEET 里一直待到整局结束**(实测 run10:t=226 还在相位 3,而别人早进了混战),
	#   相③ 连一条 BULLET 读数都不会有。
	if _phase_t > RENDEZVOUS_MAX:
		_bot.axis = 0.0
		_bot.attack = false
		if _bullet_rec == "":
			# ★★ `dist` / `los` **必须是真读数**(超时那一刻的实测值):早先这里写死 `-1.0` 与 `0`,
			#   而裁判的判词却把它们当成"读数"念出来 —— 那等于在报告里放了一个永远是假的数。
			#   没有目标快照(乙那份还没到)时才留 `-1`(那是"没有读数",不是"距离是 -1")。
			var d_to := -1.0
			var los_now := 0
			var vp_to := _pos_of(_victim_role)
			if vp_to != Vector2.INF:
				d_to = _delta(_local.global_position, vp_to).length()
				los_now = 1 if _los_to(vp_to) else 0
			_bullet_rec = "BULLET shots=%d dist=%.0f los=%d before=%d after=%d hit=0 timeout=1 wtype=%d" % [
					_shots, d_to, los_now, _hp_before, _hp_of(_victim_role), _weapon_type()]
			_rec(_bullet_rec)
		if _grenade_rec == "":
			_grenade_rec = "GRENADE thrown=0 reason=rendezvous_timeout before=%d after=-1" % _hp_before
			_rec(_grenade_rec)
		_phase = PH_BRAWL
		_phase_t = 0.0
		return
	var vp := _pos_of(_victim_role)
	if vp == Vector2.INF:
		return
	match _meet_sub:
		MEET_SEEK:
			var d := _delta(_local.global_position, vp).length()
			if d <= CLOSE_PX and _los_to(vp):
				# ★ 到位后**站住**:射击要打的是静止靶(两边一起飘必然打不中)
				_bot.axis = 0.0
				_bot.hold_up = false
				_bot.hold_down = false
				_meet_sub = MEET_SWITCH_BULLET
				_sub_t = 0.0
				_ready_to_fire = true
				_hp_before = _hp_of(_victim_role)
				_log("甲就位(dist=%.0f los=1)→ 向队友 role=%d 连射 %.1fs" % [d, _victim_role, VOLLEY])
			else:
				_nav_to(vp, CLOSE_PX * 0.6, delta)
				_bot.attack = false
		MEET_SWITCH_BULLET:
			# ★★ "子弹穿透队友"这一半**必须用出弹类武器测**:5 号榴弹(打出去的是榴弹)与
			#   6 号激光(即时光束、不产生子弹)都会让这条断言变成**假红/空绿**。手上是这两种
			#   就换到背包里的出弹枪(1~4);换不了就**照实标未覆盖(枪种)**,不硬判。
			_bot.axis = 0.0
			_bot.attack = false
			var t := _weapon_type()
			if t >= 1 and t <= 4:
				_meet_sub = MEET_VOLLEY
				_sub_t = 0.0
				_hp_before = _hp_of(_victim_role)
				_log("甲就位(武器 %d,dist=%.0f los=1)→ 向队友 role=%d 连射 %.1fs"
						% [t, _delta(_local.global_position, vp).length(), _victim_role, VOLLEY])
			else:
				var bi := _bullet_weapon_index()
				if bi < 0:
					_bullet_rec = "BULLET shots=0 wtype=%d reason=no_bullet_weapon" % t
					_rec(_bullet_rec)
					_log("相③ 子弹那一半未覆盖:背包里没有出弹类武器(手上是 %d 号)" % t)
					_meet_sub = MEET_GL_SWITCH
					_sub_t = 0.0
				elif _sub_t > 2.0:
					_bullet_rec = "BULLET shots=0 wtype=%d reason=bullet_switch_timeout" % t
					_rec(_bullet_rec)
					_meet_sub = MEET_GL_SWITCH
					_sub_t = 0.0
				else:
					_bot.press_switch_index(bi + 1)
		MEET_VOLLEY:
			_dist_at_fire = _delta(_local.global_position, vp).length()
			_bot.axis = 0.0
			_bot.aim = _delta(_local.global_position, vp).normalized()
			_pulse_attack(delta)
			# 取**峰值并发数**(不是"这一轮生成了多少发"):子弹会飞出去消失,瞬时值可能正好
			# 落在两发之间(=0);而霰弹枪一发就是 8 丸 ⇒ `shots=8` 只等价于"**至少响过一枪**"。
			_shots = maxi(_shots, _local_bullet_count())
			if _sub_t >= VOLLEY:
				_bot.attack = false
				_hp_after_bullet = _hp_of(_victim_role)
				# ★ 记下**手上的武器类型**(1..6):6=激光枪是**即时光束、不产生子弹** ——
				#   此时 `shots=0` 是**正确行为**而不是"枪没响",而"乙 hp 不变"也就成了空断言。
				#   裁判据此把那一半判成**未覆盖**(而不是留一条空的绿,也不是假红)。
				_bullet_rec = "BULLET shots=%d dist=%.0f los=%d before=%d after=%d hit=%d wtype=%d" % [
						_shots, _dist_at_fire, 1 if _los_to(vp) else 0, _hp_before, _hp_after_bullet,
						1 if _hp_after_bullet != _hp_before else 0, _weapon_type()]
				_rec(_bullet_rec)
				_log("相③ 子弹:" + _bullet_rec)
				_meet_sub = MEET_GL_SWITCH
				_sub_t = 0.0
				_vic_pos_before = vp
		MEET_GL_SWITCH:
			if not _bot.attack:
				_bot.axis = 0.0
				_bot.aim = _delta(_local.global_position, vp).normalized()
			_bot.attack = false
			if _sub_t < 0.05:
				return
			var r := _gl_equip()
			if r == "ok":
				_meet_sub = MEET_GL_FIRE
				_sub_t = 0.0
				_hp_before = _hp_of(_victim_role)
				_vic_pos_before = vp
				_log("甲已换到榴弹发射器 → 朝队友投弹")
			elif r != "switching":
				_grenade_rec = "GRENADE thrown=0 reason=%s before=%d after=-1" % [r, _hp_before]
				_rec(_grenade_rec)
				_log("相③ 榴弹未投出:" + r)
				_meet_sub = MEET_SETTLE
				_sub_t = 0.0
		MEET_GL_FIRE:
			var d := _delta(_local.global_position, vp).length()
			if d > GRENADE_PX or not _los_to(vp):
				_nav_to(vp, GRENADE_PX * 0.5, delta)
				_bot.attack = false
			else:
				_bot.axis = 0.0
				_bot.aim = _delta(_local.global_position, vp).normalized()
				_pulse_attack(delta)
			_vic_knock = maxf(_vic_knock, _delta(vp, _vic_pos_before).length())
			if _sub_t >= 3.0:
				_bot.attack = false
				_hp_after_grenade = _hp_of(_victim_role)
				_grenade_rec = "GRENADE thrown=1 dist=%.0f before=%d after=%d dmg=%d moved=%.0f" % [
						d, _hp_before, _hp_after_grenade, _hp_before - _hp_after_grenade, _vic_knock]
				_rec(_grenade_rec)
				_log("相③ 榴弹:" + _grenade_rec)
				if _hp_after_grenade >= _hp_before:
					_fail("相③ 榴弹对队友未造成伤害(before=%d after=%d):爆炸满效这条没成立"
							% [_hp_before, _hp_after_grenade])
				_meet_sub = MEET_SETTLE
				_sub_t = 0.0
		MEET_SETTLE:
			_bot.axis = 0.0
			_bot.attack = false
			if _sub_t >= 1.0:
				_meet_sub = MEET_OVER
		MEET_OVER:
			_phase = PH_BRAWL
			_phase_t = 0.0


# 开火脉冲:三类武器(全自动/半自动/heavy_aim 松开发射)在脉冲下都能开火。
func _pulse_attack(delta: float) -> void:
	_pulse_t += delta
	var period := PULSE_ON + PULSE_OFF
	var ph := fmod(_pulse_t, period)
	var on := ph < PULSE_ON
	# ★ **两个边沿都要显式报给手柄**(见 handle 的注释):半自动只在 just_pressed 那一帧开火,
	#   而 `heavy_aim`(m82a1/榴弹发射器)只在 **just_released** 那一帧开火。
	if on and not _bot.attack:
		_bot.press_attack_edge()
	elif not on and _bot.attack:
		_bot.release_attack_edge()
	_bot.attack = on


# 找背包里的榴弹发射器(类型 id 5)并切到它。返回 "ok" / "switching" / 失败原因。
func _gl_equip() -> String:
	var w = _current_weapon()
	if w == null:
		return "no_weapon"
	var idx_gl := -1
	for i in range(_local.weapons.inventory.held.size()):
		if int((_local.weapons.inventory.held[i] as Dictionary).get("type", 0)) == 5:
			idx_gl = i
			break
	if idx_gl < 0:
		return "no_grenade_launcher"
	if int(_local.weapons.current_type_id()) == 5:
		return "ok"
	_bot.press_switch_index(idx_gl + 1)
	if _sub_t > 2.0:
		return "switch_timeout"
	return "switching"


# 乙端:数"从身边飞过"的**非自己**子弹(服务器广播给非射手端的视觉副本)。
# 这是"子弹真的到达了乙的位置"的证据 —— 没有它,"乙 hp 不变"可以靠"子弹根本没飞到"骗过。
func _count_near_bullets() -> void:
	var me := _local.global_position
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b) or not (b is Node2D):
			continue
		if b.get("shooter") == _local:
			continue
		var id := b.get_instance_id()
		if _near_ids.has(id):
			continue
		if _delta(me, (b as Node2D).global_position).length() <= NEAR_PX:
			_near_ids[id] = true
			_near_count += 1


# ── 相④:混战到 ROUND_OVER ──

func _tick_brawl_phase(delta: float) -> void:
	_tick_backoff(delta)
	_tick_brawl(delta)


# ★★ **回退模式**(照实登记,报告里要写明占比):脚本机器人在**平台跳跃图**上无法可靠接近
#    对手(**全部留存日志里 `killA=0`**:至今没有一次有归因击杀;真正的障碍看起来是
#    "走位到达"而不是"开火" —— 但这一点本探针**没有**独立验证过,见报告 §7)。
#    对局只在**先到 9 杀**时收局,所以"打不到人"= 相④ 的换边断言与相⑤ 全都跑不到。
#    这里在"混战 90s 且最近 20s 一次击杀都没有"之后,让机器人**每 4s 按一次 K**(自杀脱困:
#    `不分死因`给对方队 +1)把状态机推到 ROUND_OVER。它是**记录在案**的降级:
#      · 每端写 `REC BACKOFF n=N`,裁判把它当成**读数**打出来(不隐藏);
#      · "真实交火击杀"另有独立读数(`killA`/`killU`),报告照实分栏。
#    这样相④ 的判据仍然是**非空转**的:它验的是**回合机 + 整队换边 + 换边重拉 match_sync**,
#    那三样与"谁杀的"无关,坏了照样红。
func _tick_backoff(delta: float) -> void:
	if _backoff:
		_backoff_t -= delta
		if _backoff_t <= 0.0:
			_backoff_t = 4.0
			_backoff_n += 1
			_rec("BACKOFF n=%d" % _backoff_n)
			_k_suicide()
		return
	_since_kill += delta
	# 判据用"**比分多久没动**"而不是"多久没收到 kill_event":两者大多同源,但比分会因为
	# 任何一端的击杀而前进,而"离收局还差多少"才是这里要问的事。
	var total := int(_scores.get(1, 0)) + int(_scores.get(2, 0))
	if total != _last_score_total:
		_last_score_total = total
		_since_kill = 0.0
	# ★★ **第 2 局不启动回退模式**:相⑤ 的观察窗要求"对局仍在 PLAYING",而回退模式的 K 会
	#   把第 2 局也推到收局 → 两局胜 = MATCH_OVER → 六端 6s 后自动退场,观察窗被截断
	#   (实测 run14)。第 1 局的回退只为了"让 9 杀能到达、从而验到回合机与换边"。
	if _round >= 2:
		return
	if _phase_t > 75.0 and _since_kill > 12.0:
		_backoff = true
		_backoff_t = 0.5
		_log("★ 相④ 回退模式:90s 无击杀 → 按 K 推动回合(真实交火击杀 %d 次)" % _kills_attr)


func _tick_brawl(delta: float) -> void:
	if _phase_t > BRAWL_MAX:
		_fail("相④ %.0fs 内没打到 9 杀(ROUND_OVER 未出现;脚本机器人互射未收敛)" % BRAWL_MAX)
		_finish()
		return
	# 最近的那个敌人**可能到不了**(BFS 无路:它在空中/在一个小连通区里)—— 那就换下一个:
	# 不换的话机器人会抱着一个够不到的目标原地卡到 K 用光(实测:c1 在 t=35 连按两次 K
	# 都是"路径空"造成的,而它当时离**别的**敌人只有 2000px 出头)。
	if _path.is_empty():
		_brawl_skip += 1
		_path_to = Vector2i(-99, -99)
		_stuck_t = 0.0
		if _brawl_skip > 5:
			_brawl_skip = 0
	var tgt := _nearest_enemy()
	if tgt == Vector2.INF:
		_bot.axis = 0.0
		_bot.attack = false
		return
	var d := _delta(_local.global_position, tgt)
	# ★ **提前量**:两边都在动,照当前位置开火等于每发都打在敌人身后(理论上;本探针未能
	#   用读数证明过它 —— 见报告 §7 的未覆盖栏:(两边在动 +
	#   弹道飞行时间)。按快照里的 `vel` 外推 `dist / 弹速` 秒。
	#   弹速取 1000px/s 作常数:六把枪实际在 900~1400 之间,没必要为它引武器表(打不中才是问题)。
	var t_lead: float = clampf(d.length() / 1000.0, 0.0, 0.5)
	var aim_at := tgt + _vel_of(_nearest_enemy_role()) * t_lead
	_bot.aim = _delta(_local.global_position, aim_at).normalized()
	# ★ **一律逼近到 ~100px 再打**:远距离对射在本探针里从未产生击杀(两边都在动 +
	#   弹道飞行时间 → 每发都擦过去);贴脸打时飞行时间 ~0.1s,提前量几乎不起作用。
	#   隔墙那档(有距离但无视线)也走同一条:贴近到 100px 往往就绕到同一侧了
	#   (实测的僵局正是"两边各贴一堵墙、相距 320px、视线 0"卡了 40s)。
	if d.length() <= 140.0:
		_bot.axis = 0.0
		_pulse_attack(delta)
	elif d.length() <= FIGHT_PX and _los_to(tgt):
		_nav_to(tgt, 100.0, delta)
		_pulse_attack(delta)
	else:
		_bot.attack = false
		_nav_to(tgt, 100.0, delta)


func _vel_of(role: int) -> Vector2:
	var ps: Dictionary = _snap_world.get("players", {})
	var dd: Dictionary = ps.get(str(role), {})
	return dd.get("vel", Vector2.ZERO)


# 最近的敌人;`_brawl_skip` 用于"最近那个够不到时退而求其次"(见 _tick_brawl)
func _nearest_enemy() -> Vector2:
	var arr: Array = []
	var ps: Dictionary = _snap_world.get("players", {})
	for rs in ps:
		var r := int(rs)
		if r == _role or int(_teams.get(r, 0)) == _team:
			continue
		var p: Vector2 = (ps[rs] as Dictionary).get("pos", Vector2.INF)
		if p == Vector2.INF:
			continue
		arr.append([_delta(_local.global_position, p).length(), p, r])
	if arr.is_empty():
		return Vector2.INF
	arr.sort_custom(func(a, b) -> bool: return float(a[0]) < float(b[0]))
	var i := mini(_brawl_skip, arr.size() - 1)
	_brawl_pick = int(arr[i][2])
	return arr[i][1]


# 当前选中的敌人 role(供提前量读 `vel` 用;与 `_nearest_enemy()` 同一次排序取同一个)
func _nearest_enemy_role() -> int:
	return _brawl_pick


# ── 相④后半:第 2 局 PLAYING 采样(换边)+ 6 号离场 ──

func _tick_swap(delta: float) -> void:
	_bot.axis = 0.0
	_bot.attack = false
	if _round_state != 1:
		return
	if _phase_t < SETTLE:
		return
	var cell := GridPathfinder.cell_of(_local.global_position, TILE, _dims().x, _dims().y)
	_pos_r2 = cell
	_rec("R2POS role=%d team=%d cell=%d,%d round=%d msync=%d" % [_role, _team, cell.x, cell.y,
			_round, _msync])
	_log("相④ 第 2 局出生格 %s(team=%d;match_sync 应答累计 %d 次)" % [str(cell), _team, _msync])
	# ★ 第 2 局**不再开火**:相⑤ 的观察窗要在"对局仍在 PLAYING"下才有意义,而再打满 9 杀
	#   会让第 2 局也结束(两局胜 = MATCH_OVER → 客户端 6s 后自动退场,观察窗被截断)。
	if idx == 6:
		_esc_leave()
		return
	_leave_t = _t
	_phase = PH_OBSERVE
	_phase_t = 0.0


# 局内按 ESC → 回主菜单(唯一走 `Level0.safe_change_scene` 的**局内**退出路径)。
func _esc_leave() -> void:
	if _esc_done:
		return
	_esc_done = true
	var pm: Node = null
	for c in _game.get_children():
		if c is PauseMenu:
			pm = c
			break
	if pm == null:
		_fail("对局场景里没找到 PauseMenu")
		_finish()
		return
	# 真 ESC:走 PauseMenu 自己的 `_unhandled_input`(ui_cancel → 开菜单)
	# ★ `keycode` 与 `physical_keycode` **都要设**:`PauseMenu._unhandled_input` 判的是
	#   `event.is_action_pressed("ui_cancel")`(走 InputMap),而默认 `ui_cancel` 绑的是
	#   **keycode** Escape —— 只给 physical 时 `is_action_pressed` 恒 false(实测 run11:
	#   菜单没打开,`_open` 仍是 false,而 `go_menu()` 照样把人送走了 ⇒ "离场绿、菜单红")。
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	var opened := bool(pm.get("_open"))
	# ★ 标签**不能**写成退役类名那种拼法(`esc`+`menu`):`kh_l4_probe` 会把
	#   "退役 EscMenu 仍有代码引用"判红 —— 它按**去注释后的全文小写**扫,日志字面量也在扫描面上
	#   (本仓的源码级守卫就是这么设计的:宁可误报,不给退役符号留活口)。故用中性标签。
	_rec("PAUSE_MENU opened=%d" % (1 if opened else 0))
	if not opened:
		_fail("按 ESC 没打开暂停菜单(_open 仍为 false)")
	_log("已按 ESC 打开菜单 → 点「回 到 主 菜 单」(t=%.1fs)" % _t)
	_finish()                      # 先落盘读数(离场会把本端的世界退役掉)
	pm.call("go_menu")
	get_tree().create_timer(0.4).timeout.connect(func() -> void: get_tree().quit(0))


# ── 相⑤:观察窗(其余 5 端)──

func _tick_observe() -> void:
	_bot.axis = 0.0
	_bot.attack = false
	if _round_state != 1 and not _match_over:
		_obs_playing_bad = true
	if _match_over:
		# MATCH_OVER = 服务器终局了 —— 那是相⑤ 要证的**反面**
		_fail("相⑤:6 号离场后服务器终局了(MATCH_OVER)—— 该队还有 2 人,不该终局")
		_finish()
		return
	if _phase_t > OBSERVE_MAX:
		_fail("相⑤ 观察窗 %.0fs 内没观察到掉线者被移出对局(快照里仍没有 role 消失)" % OBSERVE_MAX)
		_finish()
		return
	# 观测点(全部满足即收工):掉线者的 role 已从快照消失 + 副本已拆
	var gone := _gone_from_snapshot()
	if not gone.is_empty():
		var r := int(gone[0])
		_left_in_replica = 0 if _game.get("_replicas").has(r) else 1
		if _left_in_replica == 1 and _phase_t > LEAVE_AT + 1.0:
			_rec("LEFT gone=%s obsmax=%.0fms sessionmax=%.0fms(sessionmax_phase=%d) playing=%d replica_gone=1"
					% [str(gone), _obs_max_gap, _snap_max_gap, _snap_max_phase,
					1 if not _obs_playing_bad else 0])
			# ★ 这里打的是**两个不同的数**,别混:抽样窗口(观察窗)内的是 `_obs_max_gap`,
			#   全会话的是 `_snap_max_gap`(它含"进对局建世界"那一大段)。判据只用前者。
			_log("相⑤ 已观察到 role %s 被移出对局(副本已拆);观察窗 %.1fs(窗内最大间隔 %.0fms;"
					% [str(gone), _phase_t, _obs_max_gap]
					+ "全会话最大 %.0fms,发生于相位 %d)" % [_snap_max_gap, _snap_max_phase])
			if _obs_playing_bad:
				_fail("相⑤ 观察窗内 round_state 离开过 PLAYING(服务器不该因少人改状态)")
			# ★ 判据只用**观察窗内**的最大间隔(理由见 `_on_snap_world`:全会话最大值包含
			#   "进对局建世界"那一大段,拿它当判据会让每一跑都红 —— 那是伪影,不是服务器停了)。
			# ★★ **单端超 1s 也判红**(不做"多端才红"的容忍):可能是本进程自己卡了一下,
			#   也可能是**服务器对这一个 peer 的定向投递**异常(`snapshot_own` 逐 peer 定向发,
			#   只卡一端正是那条路的可疑症状),两者本探针**分不清** ⇒ 保守判红。
			if _obs_max_gap > 1000.0:
				_fail("相⑤ 观察窗内快照间隔 %.0fms > 1s(可能是本进程停顿,也可能是服务器对本 peer 的定向投递异常 —— 无法区分,保守判红)"
						% _obs_max_gap)
			_finish()
			return


# 快照里曾经出现、现在消失的 role(排除自己)
func _gone_from_snapshot() -> Array[int]:
	var out: Array[int] = []
	var ps: Dictionary = _snap_world.get("players", {})
	for r in _teams:
		var ri := int(r)
		if ri == _role:
			continue
		if not ps.has(str(ri)):
			out.append(ri)
	return out


# ════════════════════ 信号 ════════════════════

func _on_snap_world(snap: Dictionary) -> void:
	var now := Time.get_ticks_usec()
	if _last_snap_us > 0:
		var gap := float(now - _last_snap_us) / 1000.0
		_snap_gaps.append(gap)
		if gap > _snap_max_gap:
			_snap_max_gap = gap
			# ★ 记下**最大间隔发生在哪个相位**:整个会话的最大值会把"进对局建世界/建导航图"
			#   那一大段(实测 1~2s)算进去 —— 那一段本来就没有快照可收,是**测量窗口伪影**,
			#   不是"服务器停了"。相⑤ 要判的是**观察窗内**快照连不连,故两者分开记。
			_snap_max_phase = _phase
		if _phase == PH_OBSERVE and gap > _obs_max_gap:
			_obs_max_gap = gap
	_last_snap_us = now
	_snap_world = snap


# 击杀播报:分成**有归因**(真实交火:枪/爆炸,射手身份可查)与**无归因**(自杀 K / 溺水 /
# 坠落 —— `_attributed_killer` 返回 0)。★ 这个分栏是相④ 的"非空转"证据:如果 ROUND_OVER
# 全靠脚本机器人**自杀脱困**推出来的,那"打满一局"就名不副实 —— 报告要照实分开写。
func _on_kill_event(killer: int, _victim: int) -> void:
	_since_kill = 0.0
	if killer == 0:
		_kills_unattr += 1
	else:
		_kills_attr += 1


func _on_round_state(data: Dictionary) -> void:
	var st := int(data.get("state", -1))
	_round_state = st
	_round = int(data.get("round", 0))
	_scores = data.get("scores", {})
	_rounds_won = data.get("rounds_won", {})
	if st == 1 and not _played_rounds.has(_round):
		_played_rounds.append(_round)
	if st == 2 and _phase == PH_BRAWL:
		_r1_winner = int(data.get("winner", 0))
		_rec("ROUND1 winner=%d scores=%s rounds_won=%s" % [
				_r1_winner, _dict_str(_scores), _dict_str(_rounds_won)])
		_log("第 1 局结束:胜者队 %d,比分 %s,局胜 %s" % [_r1_winner, _dict_str(_scores), _dict_str(_rounds_won)])
		_phase = PH_SWAP
		_phase_t = 0.0
	if st == 3:
		_match_over = true


# ════════════════════ 工具 ════════════════════

func _dims() -> Vector2i:
	var g: Array = MazeGenerator.current_grid
	if g == null or g.is_empty():
		return Vector2i(150, 100)
	return Vector2i((g[0] as Array).size(), g.size())


func _delta(a: Vector2, b: Vector2) -> Vector2:
	return MazeGenerator.toroidal_delta_px(a, b, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func _pos_of(role: int) -> Vector2:
	var ps: Dictionary = _snap_world.get("players", {})
	var d: Dictionary = ps.get(str(role), {})
	return d.get("pos", Vector2.INF)


func _hp_of(role: int) -> int:
	var ps: Dictionary = _snap_world.get("players", {})
	var d: Dictionary = ps.get(str(role), {})
	return int(d.get("hp", -1))


func _los_to(target: Vector2) -> bool:
	var d := _dims()
	var a := GridPathfinder.cell_of(_local.global_position, TILE, d.x, d.y)
	var b := GridPathfinder.cell_of(target, TILE, d.x, d.y)
	return MazeGenerator.has_line_of_sight(a, b)


# 背包里**出弹类**武器的下标(1~4 号:手枪/步枪/重狙/霰弹;0 = 没有)。
# ★ 排除 5 号榴弹(打出的是榴弹,不是子弹)与 6 号激光(即时光束、不产生子弹)。
func _bullet_weapon_index() -> int:
	if _local == null or _local.weapons == null:
		return -1
	for i in range(_local.weapons.inventory.held.size()):
		var t := int((_local.weapons.inventory.held[i] as Dictionary).get("type", 0))
		if t >= 1 and t <= 4:
			return i
	return -1


# 当前武器类型 id(1..6;0 = 空手)—— 与 `WeaponComponent.WEAPONS` 的键同源
func _weapon_type() -> int:
	if _local == null or _local.weapons == null:
		return 0
	return int(_local.weapons.current_type_id())


func _current_weapon():
	if _local == null or _local.weapons == null:
		return null
	return _local.weapons.current_weapon()


func _local_bullet_count() -> int:
	var n := 0
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b) and b.get("shooter") == _local:
			n += 1
	return n


# ════════ 机器人导航(相③ 走位 / 相④ 接近共用)════════
# ★★ 为什么不是"朝目标 x 硬走"(既有骨架 `royale_soak_probe` 的形状),也不是仓内那套
#    `GridPathfinder.astar_path_nearest`(敌人用的 4 邻域地板格图):**实测两种都到不了人**。
#    读数(本轮实测,见报告 §导航):
#      · 硬走:90s 内位移 ≈ 0(卡在同一格,`卡=90.0s`);
#      · 4 邻域地板格 A*:整个地图的最大连通区只有 **77 格(4%)** —— 地板格是按环面
#        4 邻接算的,而工厂图是**平台跳跃图**(台面之间隔空隙,靠跳跃跨),该图与"能走到的
#        地方"根本不是一回事:规划出来的路径第一步往往就不可执行。
#    故这里自建一张 **跳跃感知图**:节点 = 可站格(地板格 ∪ 通道格),边 = 玩家真能做出来的
#    位移(走 / 落 / 跳(上 1~3 格、横 -6~6 格,竖直与水平通道都要净空)/ 爬梯)。
#    Python 侧离线核对过同一套判据:全图 2095 个节点、最大连通区 **1792(85.5%)** ——
#    (133,64)/(118,14)/(64,79) 等实测出生点都在主连通区里。
# ★ 图**每局建一次**(实测 330ms,发生在开局 COUNTDOWN 里,不影响对局),不每帧重建。
var _nav_adj: Dictionary = {}       # cell -> Array[Vector2i](邻居表)
var _nav_built := false
var _path: Array = []
var _path_to := Vector2i(-99, -99)
var _repath_t := 0.0
var _stuck_t := 0.0
var _best_dist := INF
var _stuck_to := Vector2i(-99, -99)
var _brawl_skip := 0
var _brawl_pick := 0
var _last_node := Vector2i(-99, -99)   # 最近一次真正站在图节点上的格(BFS 起点,见 _nav_to)
var _k_used := 0                    # 本端用了几次 K 脱困(上限见 K_MAX)
const K_MAX := 2
const STUCK_K := 8.0                # 离目标最近距离 8s 没被刷新(<80px)且仍离得远 → 见 _nav_to


func _build_nav_graph() -> void:
	var d := _dims()
	_nav_adj.clear()
	var nodes: Array = []
	for y in d.y:
		for x in d.x:
			var c := Vector2i(x, y)
			if _standable(c):
				nodes.append(c)
	# ★★ 邻居必须**先按环面归一化再入表**:`_nav_cell_solid` 读格是 `posmod` 的,而键不是 ——
	#   落/跳那两条会算出 y+30(越界)这样的坐标,于是邻居表里出现**不是键**的格,
	#   下一帧 `_nav_adj[cur]` 当场 `Invalid access to property ... on Dictionary`:
	#   表现是主机器人**每帧抛错、原地不动**(实测:相③ 的甲 50s 一步没挪),
	#   而错误信息里的坐标(y=117 > rows-1=99)就是证据。
	for c in nodes:
		var keep: Array = []
		for n in _nav_neighbors(c):
			keep.append(_wrap_cell(n))
		_nav_adj[c] = keep
	_nav_built = true


func _wrap_cell(c: Vector2i) -> Vector2i:
	var d := _dims()
	return Vector2i(posmod(c.x, d.x), posmod(c.y, d.y))


func _nav_cell_solid(c: Vector2i) -> int:
	var g: Array = MazeGenerator.current_grid
	return int(g[posmod(c.y, g.size())][posmod(c.x, (g[0] as Array).size())])


func _nav_blocked(c: Vector2i) -> bool:
	return TileDefs.is_blocked(_nav_cell_solid(c))


func _nav_climbable(c: Vector2i) -> bool:
	return TileDefs.climb_speed(MazeGenerator.texture_of(_nav_cell_solid(c))) > 0.0


# 可站:通道格(梯/链)**或**地板格(空 + 下方实心 + 上方净空)
func _standable(c: Vector2i) -> bool:
	if _nav_climbable(c):
		return true
	return _nav_cell_solid(c) == 0 and _nav_blocked(c + Vector2i(0, 1)) \
			and _nav_cell_solid(c + Vector2i(0, -1)) == 0


func _nav_neighbors(c: Vector2i) -> Array:
	var out: Array = []
	for dx in [-1, 1]:                                   # 走
		var n := c + Vector2i(dx, 0)
		if _standable(n):
			out.append(n)
	if _nav_climbable(c):                                # 爬
		for dy in [-1, 1]:
			var n2 := c + Vector2i(0, dy)
			if _standable(n2) or _nav_climbable(n2):
				out.append(n2)
	for dx2 in [0, -1, 1]:                               # 落(同列/左右列,落到第一个可站格)
		if _nav_blocked(c + Vector2i(dx2, 1)):
			continue
		for k in range(1, 30):
			var n3 := c + Vector2i(dx2, k)
			if _nav_blocked(n3):
				break
			if _standable(n3):
				out.append(n3)
				break
	for dy2 in [1, 2, 3]:                                # 跳(上 1~3,横 -6~6,通道净空)
		var ok := true
		for k in range(1, dy2 + 1):
			if _nav_blocked(c + Vector2i(0, -k)):
				ok = false
				break
		if not ok:
			continue
		for dx3 in range(-6, 7):
			var nx: int = c.x + dx3
			var ny: int = c.y - dy2
			var dest := Vector2i(nx, ny)
			if not _standable(dest):
				continue
			var step := 1 if dx3 >= 0 else -1
			var xx: int = c.x
			var clear := true
			while xx != nx:
				xx += step
				if _nav_blocked(Vector2i(xx, ny)):
					clear = false
					break
			if clear:
				out.append(dest)
	return out


func _nearest_nav_node(c: Vector2i) -> Vector2i:
	if _nav_adj.has(c):
		return c
	for k in range(1, 7):
		for dy in [-k, k]:
			var n := c + Vector2i(0, dy)
			if _nav_adj.has(n):
				return n
	for k in range(1, 9):
		for dx in [-k, k]:
			var n2 := c + Vector2i(dx, 0)
			if _nav_adj.has(n2):
				return n2
	return c


# BFS(节点 ~2000:A* 那套堆在这里换不来可感收益;图小,广度优先已足够)
func _find_path(from_cell: Vector2i, to_cell: Vector2i) -> Array:
	if not _nav_built:
		return []
	var a := _wrap_cell(from_cell)
	if not _nav_adj.has(a):
		a = _nearest_nav_node(a)
	var b := _nearest_nav_node(_wrap_cell(to_cell))
	if not _nav_adj.has(a) or not _nav_adj.has(b) or a == b:
		return []
	var prev: Dictionary = {a: a}
	var q: Array = [a]
	var qi := 0
	while qi < q.size():
		var cur: Vector2i = q[qi]
		qi += 1
		if cur == b:
			break
		for n in (_nav_adj[cur] as Array):
			if prev.has(n):
				continue
			prev[n] = cur
			q.append(n)
	if not prev.has(b):
		return []
	var path: Array = []
	var c := b
	while c != a:
		path.push_front(c)
		c = prev[c]
	return path


func _nav_to(target: Vector2, stop_px: float, delta: float) -> void:
	if _local == null or _bot == null:
		return
	if not _nav_built:
		_build_nav_graph()
	var me := _local.global_position
	var to_t := _delta(me, target)
	if to_t.length() <= stop_px:
		_bot.axis = 0.0
		_bot.hold_up = false
		_bot.hold_down = false
		return
	var tc := GridPathfinder.cell_of(target, TILE, _dims().x, _dims().y)
	# ★★ BFS 的**起点**用"最近一次真正站在图节点上的格",不是"当前格":
	#   机器人在空中(跳跃/坠落)时当前格是**空气**,`_nearest_nav_node` 可能就近落到
	#   **脚下的小连通区**(比如一个坑底),于是 BFS 恒返回空 → 判"路径空" → 连按 K 脱困。
	#   实测:甲(21,10)与乙(149,12)明明在同一个主连通区(1792 格),却被判"路径空"。
	_repath_t -= delta
	if _path_to != tc or _path.is_empty() or _repath_t <= 0.0:
		_path = _find_path(_last_node, tc)
		_path_to = tc
		_repath_t = 0.7
	# 卡住检测:★ 判据是「**离目标**的最近距离有没有被刷新」,不是"有没有动" ——
	#   原地蹦跳(平台图上很常见:起跳 200px 再落回)会把"位移"判据骗过去(实测:主角在
	#   同一格原地跳了 15s,`_stuck_t` 一直是 0 → K 脱困永远不触发)。
	# ★★ **到站后不再计时**:到站了当然"距离不再刷新" —— 不排除这一档,乙一到位就被判"卡住"
	#   而连按 K 自杀(实测:乙在 113px 处 15s 内按了 3 次 K,把**对方队**的比分从 1 送到 3,
	#   相④ 立刻退化成"自杀推分")。
	var dist := to_t.length()
	if dist <= stop_px * 2.0:
		_stuck_to = tc
		_best_dist = dist
		_stuck_t = 0.0
	elif tc != _stuck_to:
		_stuck_to = tc
		_best_dist = dist
		_stuck_t = 0.0
	elif dist < _best_dist - 80.0:
		_best_dist = dist
		_stuck_t = 0.0
	else:
		_stuck_t += delta
	var wp_cell := tc
	if not _path.is_empty():
		wp_cell = _path[0]
	var wp := _delta(me, Vector2(wp_cell.x * TILE + TILE * 0.5, wp_cell.y * TILE + TILE * 0.5))
	var ax := signf(wp.x) if absf(wp.x) > 8.0 else 0.0
	var my_cell := GridPathfinder.cell_of(me, TILE, _dims().x, _dims().y)
	# ★ 记住"最近一次真正站在图节点上的格":下一帧的 BFS **从它出发**(见文件上方那段注释)。
	#   放在这里(而不是 BFS 之前)是因为 `my_cell` 在这一行才声明;晚一帧无所谓。
	if _nav_adj.has(my_cell):
		_last_node = my_cell
	var foot_cell := GridPathfinder.cell_of(Vector2(me.x, me.y + TILE * 0.5),
			TILE, _dims().x, _dims().y)
	var on_ladder := _nav_climbable(my_cell) or _nav_climbable(foot_cell)
	var latched := bool(_local.climb.is_latched())
	var want_vert := absf(wp.y) > TILE * 1.2
	# ★ 卡死兜底:梯子上的死锁(爬到顶被挡/挂在梯顶)也在这一档里 —— 卡够久就按 K 脱困
	#   (K = 生产里的「自杀脱困」,见 TeamHost.request_suicide_role;本探针顺带覆盖它)。
	# ★ K 只在「**真的到不了**」时才按:路径为空(封闭小间 —— 实测出生点就可能落在 6 格
	#   密封口袋里,BFS 无路)或**长期**卡死(可规划但执行不了)。且一次对局最多 K_MAX 次:
	#   K 自杀按「不分死因」给**对方队**送分,按多了相④ 的 9 杀就全是送的。
	# ★★ **相③ 期间一律不许按 K**(只在相④ 混战里允许):K 是"自杀 → 重生在别处",而相③
	#   要的正是"两个人留在原地贴脸" —— 实测:乙在甲连射的 2.6s 里按了一次 K,重生到 3824px
	#   外,连射当场变成 `shots=0 dist=3824`(读数全废)。K 在相③ 里只会**自我拆台**。
	if _phase == PH_BRAWL and _stuck_t > STUCK_K and _k_used < K_MAX and _phase_t > 20.0 \
			and (_path.is_empty() or _stuck_t > STUCK_K * 2.0):
		_k_used += 1
		_stuck_t = 0.0
		_path.clear()
		_path_to = Vector2i(-99, -99)
		_rec("K used=%d phase=%d path_empty=%d" % [_k_used, _phase, 1 if _path.is_empty() else 0])
		_log("★ 卡住 %.0fs(路径%s)→ 按 K 自杀脱困(第 %d 次)"
				% [_stuck_t, "空" if _path.is_empty() else "非空", _k_used])
		_k_suicide()
		return
	if on_ladder and want_vert:
		_bot.hold_up = wp.y < 0.0
		_bot.hold_down = wp.y > 0.0
		_bot.axis = ax
		if not latched:
			_bot.press_jump()
		return
	if on_ladder and latched:
		# 想脱离梯子:按住上爬到顶,到顶那一帧的"按上"= 跳离(见 climb_component)
		_bot.hold_up = true
		_bot.hold_down = false
		_bot.axis = ax
		_bot.press_jump()
		return
	_bot.hold_up = false
	_bot.hold_down = false
	_bot.axis = ax
	# 平台图:赶路就跳(跨空隙);被挡也跳;目标在头顶也跳
	if _local.is_on_floor() and (want_vert or absf(wp.x) > TILE * 0.6):
		_bot.press_jump()
	elif absf(_local.velocity.x) < 30.0 and absf(wp.x) > TILE * 0.5 and _local.is_on_floor():
		_bot.press_jump()


# 按 K 走**游戏自己的** `_unhandled_input`(与 c2 探针按 K 同款),不直接发 RPC:
# 顺带把「3v3 里 K 分支还在」(A 册收尾批接的那条线)也验了。
func _k_suicide() -> void:
	if _game == null or not is_instance_valid(_game):
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_K
	_game.call("_unhandled_input", ev)


func _teams_str() -> String:
	var ks: Array = _teams.keys()
	ks.sort()
	var parts: Array[String] = []
	for k in ks:
		parts.append("%d:%d" % [int(k), int(_teams[k])])
	return ",".join(parts)


func _dict_str(d: Dictionary) -> String:
	var ks: Array = d.keys()
	ks.sort()
	var parts: Array[String] = []
	for k in ks:
		parts.append("%s:%s" % [str(k), str(d[k])])
	return ",".join(parts)


# ════════════════════ 结果 ════════════════════

func _rec(line: String) -> void:
	_lines.append("REC " + line)


func _fail(msg: String) -> void:
	_fails.append(msg)
	_log("FAIL " + msg)


func _finish() -> void:
	if _done:
		return
	_done = true
	_quitting = true
	var head := "%s %s role=%d team=%d" % ["OK" if _fails.is_empty() else "FAIL", who, _role, _team]
	var text := head + "\n" + "\n".join(_lines)
	if not _fails.is_empty():
		text += "\nFAILS " + " | ".join(_fails)
	# 跨端断言要的原始读数(裁判读这几行)
	text += "\nINFO room_states=%d list_rows=%d wait_rows=%d wait_count=%s played=%s match_over=%d" % [
			_room_states, _list_rows, _wait_rows, _wait_count_text, str(_played_rounds),
			1 if _match_over else 0]
	text += "\nINFO snapmax=%.0fms conv=%.1fpx near=%d shots=%d esc=%d gone=%s k=%d killA=%d killU=%d" % [
			_snap_max_gap, _conv_px, _near_count, _shots, 1 if _esc_done else 0,
			str(_gone_roles), _k_used, _kills_attr, _kills_unattr]
	var f := FileAccess.open(_result_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print("PROBE[%s]: %s" % [who, text.replace("\n", "\n  ")])
	if not _esc_done:
		_wait_peers_then_quit()


# 6 端是**同一局**里的六个进程:谁都不能先退 —— 任一端退出都会让服务器进宽限期,
# 若它是最后一个人还会直接收场。故所有端写完结果后**互相等**,到齐(或超时)再一起退
# (与 royale_c2_watcher 的 `_wait_peer_then_quit` 同款纪律)。
func _wait_peers_then_quit() -> void:
	var waited := 0.0
	while waited < PEER_WAIT:
		var n := 0
		for i in range(1, 7):
			if FileAccess.file_exists(ProjectSettings.globalize_path(
					"user://%sc%d.result" % [RESULT_PREFIX, i])):
				n += 1
		if n >= 6:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	print("PROBE[%s]: 六端结果已到齐(等了 %.1fs)→ 退出" % [who, waited])
	get_tree().quit(0 if _fails.is_empty() else 1)


func _result_path() -> String:
	return ProjectSettings.globalize_path("user://%s%s.result" % [RESULT_PREFIX, who])


func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := ProjectSettings.globalize_path("user://%s%s.log" % [RESULT_PREFIX, who])
	var fmode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, fmode)
	if f != null:
		f.seek_end()
		f.store_line("%6.1fs %s" % [_t, msg])
		f.close()
