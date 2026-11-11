extends Node


const BotHandle := preload("res://tests/harness/team_bot_input.gd")

const RESULT_PREFIX := "team_match_probe_"
const LOBBY_ADDR := "127.0.0.1"
const TILE := 64
const REPLICA_COUNT := 5

const ENTER_TIMEOUT := 90.0
const TEAMS_TIMEOUT := 25.0
const ROUND_STATE_TIMEOUT := 30.0
const SETTLE := 1.2
const POS_TOL := 100.0
const CLOSE_PX := 400.0
const GRENADE_PX := 170.0
const RENDEZVOUS_MAX := 100.0
const VOLLEY := 2.6
const NEAR_PX := 45.0
const BRAWL_MAX := 210.0
const FIGHT_PX := 520.0
const LEAVE_AT := 2.5
const OBSERVE_MAX := 110.0
const PEER_WAIT := 120.0
const PULSE_ON := 0.30
const PULSE_OFF := 0.25

enum {
	PH_LOBBY,
	PH_ENTER,
	PH_PLAY,
	PH_MEET,
	PH_BRAWL,
	PH_SWAP,
	PH_OBSERVE,
	PH_DONE,
}
enum { MEET_SEEK, MEET_SWITCH_BULLET, MEET_VOLLEY, MEET_GL_SWITCH, MEET_GL_FIRE, MEET_SETTLE, MEET_OVER }

var who := "c1"
var idx := 1
var lobby_port := 29200

var lobby: Node = null
var _lobby_attached := false
var _created := false
var _joined := false
var _pick_emitted := false
var _picked := false
var _started := false
var _rooms: Array = []
var _room_states := 0
var _list_rows := 0
var _wait_rows := 0
var _wait_count_text := ""
var _room_team_counts := {1: 0, 2: 0}
const PROBE_TEAM_SIZE := 3

var _game: Node = null
var _local: Node2D = null
var _bot = null
var _entered := false
var _phase := PH_LOBBY
var _phase_t := 0.0
var _round_state_t := -1.0
var _t := 0.0
var _role := 0
var _team := 0
var _teams: Dictionary = {}
var _snap_world: Dictionary = {}
var _snap_gaps: Array[float] = []
var _last_snap_us := 0
var _snap_max_gap := 0.0
var _snap_max_phase := -1
var _obs_max_gap := 0.0
var _round_state := -1
var _round := 0
var _scores: Dictionary = {}
var _rounds_won: Dictionary = {}
var _match_over := false
var _played_rounds: Array[int] = []

var _shooter := false
var _shooter_role := 0
var _victim_role := 0
var _meet_sub := MEET_SEEK
var _sub_t := 0.0
var _shots := 0
var _seen_bullet_ids: Dictionary = {}
var _near_ids: Dictionary = {}
var _near_count := 0
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

var _pos_r1 := Vector2i(-1, -1)
var _pos_r2 := Vector2i(-1, -1)
var _conv_px := -1.0
var _r1_winner := 0
var _esc_done := false
var _leave_t := -1.0
var _gone_roles: Array[int] = []
var _left_in_replica := -1
var _obs_playing := true
var _obs_playing_bad := false

var _done := false
var _quitting := false
var _lines: Array[String] = []
var _fails: Array[String] = []



func _ready() -> void:
	NetBus.local_snapshot_world.connect(_on_snap_world)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(_on_kill_event)
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


# 连上大厅:上报昵称 → 帧末挂真大厅页。★ 页挂在探针场景下(不是本节点下):换场时 change_scene_to_file 会 free 掉探针场景,页随之消失 —— 这正是生产里的形状。
#   留在树上的话,它的 _tick_claim_timeout 会在 claim 后 25s 调 _return_to_lobby → NetBus.stop(),把正在进行的对局从客户端这边掐断(症状是「进局 25s 后掉线」,且不报错)。
func _on_lobby_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", "BOT%d" % idx)
	_attach_lobby.call_deferred()


func _attach_lobby() -> void:
	if _lobby_attached:
		return
	var cs := get_tree().current_scene
	if cs == null:
		return
	lobby = load("res://scenes/mp_lobby.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	lobby.set("_connected", true)
	lobby.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(lobby)
	lobby.call("_set_filter", PvpSession.MODE_TEAM)
	_lobby_attached = true
	_log("真大厅页已挂载(current_scene=%s)" % cs.name)


func _physics_process(delta: float) -> void:
	if _quitting:
		return
	# ★ 对局场景可能已经退役(MATCH_OVER 后客户端 6s 自动回主菜单 → safe_change_scene 把整具世界拆掉),而本观察者挂在 root 上、照样在跑 —— 不判这一档就会每帧对已释放实例取字段(实测 run14 报 previously freed)。
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



# ★★ 本函数只读页的 UI 状态、只按真按钮,而页自己的信号处理(_on_room_state 里建等待室)与我的处理同帧竞争:我只在 _ready 里连信号(比页早 → 我的处理器先跑),所以「读页的等待室控件」不能放在信号处理器里。
#   实测:team_room_state 刚到那一帧 _wait_pick_a 还是 null,当场 _fail 并永久卡住(选边永不发出 → 全流程停摆)。故:信号处理器只登记原始数据,页的 UI 状态一律在这里(下一帧起)轮询取用。
func _tick_lobby() -> void:
	# ★ 换场那一刻页已被 free,而本帧的相位还没切走(先 tick 后判 _entered)→ 必须挡掉对已释放实例的访问,否则每跑都在换场那一帧抛一条 SCRIPT ERROR(实测)。
	if lobby == null or not is_instance_valid(lobby):
		return
	if not _lobby_attached:
		if _phase_t > ENTER_TIMEOUT:
			_fail("大厅页没挂上(%.0fs)" % ENTER_TIMEOUT)
			_finish()
		return
	if PvpSession.server_address != LOBBY_ADDR or String(lobby.get("_connected_addr")) != LOBBY_ADDR:
		_fail("本端连的是 %s,不是本探针大厅 %s —— 检查 _attach_lobby 里 PvpSession.server_address 的预置"
				% [PvpSession.server_address, LOBBY_ADDR])
		_finish()
		return
	if _list_rows == 0:
		var n := _list_button_count()
		if n > 0:
			_list_rows = n
			_log("房间列表渲染出 %d 行房间" % _list_rows)
	if idx == 1:
		if not _created and _phase_t > 0.6:
			_created = true
			_log("点「创 建 房 间」")
			lobby.call("_open_create_dialog")
			lobby.call("_on_create_pressed")
	else:
		_tick_lobby_join()
	_tick_pick()


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
	var grid: Node = lobby.get("_grid")
	if grid != null:
		for c in grid.get_children():
			if c is Button and str(c.get_meta("code", "")) == code and not (c as Button).disabled:
				(c as Button).pressed.emit()
				_log("点房卡 %s(真按钮回调)" % code)
				return
	_log("房卡未就绪 → 直接调 _join_code(%s)(卡的回调也是调它)" % code)
	lobby.call("_join_code", code, PvpSession.MODE_TEAM)


var _refresh_t := 1.2


func _list_button_count() -> int:
	var grid: Node = lobby.get("_grid")
	if grid == null:
		return 0
	var n := 0
	for c in grid.get_children():
		if c is Button and str(c.get_meta("code", "")) != "":
			n += 1
	return n


func _on_team_rooms(rooms: Array) -> void:
	_rooms = rooms


func _on_room_state(state: Dictionary) -> void:
	_room_states += 1
	if _room_states == 1:
		_log("等待室:收到第 1 份 team_room_state(your_role=%d players=%d team_size=%s)"
				% [int(state.get("your_role", 0)), (state.get("players", []) as Array).size(),
				str(state.get("team_size", -1))])
	var my_role := int(state.get("your_role", 0))
	var want := 1 if idx <= 3 else 2
	_room_team_counts = {1: 0, 2: 0}
	for p in (state.get("players", []) as Array):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if _room_team_counts.has(t):
			_room_team_counts[t] = int(_room_team_counts[t]) + 1
		if int(p.get("role", 0)) == my_role and t == want:
			_picked = true


func _tick_pick() -> void:
	if _picked or _room_states <= 0 or lobby == null or not is_instance_valid(lobby):
		return
	if _pick_emitted:
		_pick_retry_t -= 1.0 / 60.0
		if _pick_retry_t > 0.0:
			return
		_pick_retry_t = 2.0
	if _wait_rows == 0:
		var wp = lobby.get("_wait_body")
		if wp != null:
			_wait_rows = wp.get_child_count()
		var wc = lobby.get("_wait_count")
		if wc != null:
			_wait_count_text = str((wc as Label).text)
	var want := 1 if idx <= 3 else 2
	var btn = lobby.get("_wait_pick_a" if want == 1 else "_wait_pick_b")
	if btn == null:
		return
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
# ★ 相⑤ 补:K 键自杀的端到端(3v3 里收尾批才把 suicide_request 接上 worker,此前它在 3v3 是静默丢弃的)。
# ★ 这个观测必须跨相位跑(PH_SWAP → PH_OBSERVE):早先写在 _tick_swap 里,而 _tick_swap 在 PH_SWAP 结束(1.2s)后就不再被调 ⇒ 观测窗口只有 0.2s ⇒ 永远等不到复活(实测 run9:六端 0 端报告走通,而 K 其实已经按下去了)。
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
		_k2_revived = true
		_rec("K2 downed=0 revived=0")
		_fail("按 K 后 8s 内权威快照始终没有 downed=true(3v3 的 K 端到端没走通)")


var _backoff := false
var _backoff_t := 0.0
var _backoff_n := 0
var _since_kill := 0.0
var _last_score_total := -1
var _msync := 0
var _k2_pressed := false
var _k2_downed := false
var _k2_revived := false
var _k2_t := 0.0


func _tick_start() -> void:
	if idx != 1 or _started or not _lobby_attached:
		return
	if lobby == null or not is_instance_valid(lobby):
		return
	var b = lobby.get("_wait_start")
	if b == null or not (b as Button).is_visible_in_tree():
		return
	if int(_room_team_counts[1]) < PROBE_TEAM_SIZE or int(_room_team_counts[2]) < PROBE_TEAM_SIZE:
		return
	_started = true
	_log("两队各 3 人 → 点「开 始 游 戏」(真按钮回调)")
	(b as Button).pressed.emit()



func _is_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("team_game.gd")


func _try_enter_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		return
	var st = cs.get("state")
	var local = st._local if st != null else null
	if local == null:
		return
	_game = cs
	_local = local
	_role = PvpSession.role
	# ★★ 序前提的运行时断言:本观察者必须排在游戏场景之前(树序),否则它写的输入会在玩家已处理完那一帧才落到手柄上 ⇒ 边沿全部丢失、服务器侧又不跳不开火,而不报错。
	#   前提的来源:本节点由探针用 root.add_child 在换场之前挂上(树序在前)。
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



func _tick_enter() -> void:
	if _teams.is_empty():
		var t = _game.get("_teams")
		if t is Dictionary and not (t as Dictionary).is_empty():
			_teams = (t as Dictionary).duplicate()
			_team = int(_teams.get(_role, 0))
			_round_state_t = _phase_t
			_rec("TEAMS role=%d team=%d map=%s" % [_role, _team, _teams_str()])
			_log("队伍表:role=%d team=%d %s" % [_role, _team, _teams_str()])
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
		if _round_state_t >= 0.0 and _phase_t - _round_state_t > ROUND_STATE_TIMEOUT:
			_fail("TEAMS 到手后 %.0fs 没等到 round_state=1(进局广播没来)" % ROUND_STATE_TIMEOUT)
			_finish()
		return
	_phase = PH_PLAY
	_phase_t = 0.0



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


func _check_team_visual_layer() -> void:
	# 2026-11-10 用户裁定:玩家之间不再物理互挡 ⇒ 三模式同一条口径:玩家层 = 2(player.tscn 默认)、mask 只剩地形位 1;
	# 副本的几何探针零碰撞(layer/mask = 0)⇒ 本地玩家的 move_and_slide 不会撞到任何对手身体。
	var layer_ok: bool = _local.collision_layer == 2
	var mask_ok: bool = _local.collision_mask == 1
	var probes_bad := 0
	var tints_bad := 0
	var n := 0
	var want_reps: int = REPLICA_COUNT
	var st = _game.get("state")
	var reps: Dictionary = st._replicas if st != null else {}
	for role in reps:
		var r = reps[role]
		if r == null or not is_instance_valid(r):
			continue
		n += 1
		var ot := int(_teams.get(int(role), 0))
		var g = r.get_node_or_null("HurtProbe")
		if g == null or int(g.collision_layer) != 0 or int(g.collision_mask) != 0:
			probes_bad += 1
		var spr = r.get_node_or_null("AnimatedSprite2D")
		if spr != null:
			var want_c: Color = UiFactory.C_TEAM_A if ot == 1 else UiFactory.C_TEAM_B
			var got: Color = (spr as CanvasItem).modulate * PvpMatchClient.BODY_BASE_COLOR
			if not _color_close(got, want_c):
				tints_bad += 1
	_rec("TEAMFMT layer=%d mask=%d ok_layer=%d ok_mask=%d reps=%d probes_bad=%d tints_bad=%d"
			% [_local.collision_layer, _local.collision_mask, 1 if layer_ok else 0,
			1 if mask_ok else 0, n, probes_bad, tints_bad])
	_log("队色/不互挡:自己 layer=%d mask=%d(层对=%s 掩码对=%s);副本 %d 个(几何探针非零碰撞 %d,队色错 %d)"
			% [_local.collision_layer, _local.collision_mask, str(layer_ok), str(mask_ok),
			n, probes_bad, tints_bad])
	if n != want_reps:
		_fail("副本数 %d != %d(队友的队色/无碰撞探针**一个都没验到** —— 计数天然为 0 的恒真空位)"
				% [n, want_reps])
	if not layer_ok or not mask_ok:
		_fail("玩家的碰撞层/掩码与契约不符(layer=%d mask=%d team=%d;期望 layer=2、mask 只剩地形位 1)"
				% [_local.collision_layer, _local.collision_mask, _team])
	if probes_bad > 0:
		_fail("有 %d 个副本的几何探针参与了碰撞(layer/mask 必须恒 0;非零 = 又变回挡你的对手)" % probes_bad)
	if tints_bad > 0:
		_fail("有 %d 个副本的身体色不是队色(6 人局里认不出队友)" % tints_bad)


func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.06 and absf(a.g - b.g) < 0.06 and absf(a.b - b.b) < 0.06



func _tick_meet(delta: float) -> void:
	if _shooter:
		_tick_meet_shooter(delta)
		return
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
		_bot.axis = 0.0
		_bot.attack = false
	if _phase_t > RENDEZVOUS_MAX:
		_phase = PH_BRAWL
		_phase_t = 0.0


func _tick_meet_shooter(delta: float) -> void:
	if _phase_t > RENDEZVOUS_MAX:
		_bot.axis = 0.0
		_bot.attack = false
		if _bullet_rec == "":
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
			_shots = maxi(_shots, _local_bullet_count())
			if _sub_t >= VOLLEY:
				_bot.attack = false
				_hp_after_bullet = _hp_of(_victim_role)
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


func _pulse_attack(delta: float) -> void:
	_pulse_t += delta
	var period := PULSE_ON + PULSE_OFF
	var ph := fmod(_pulse_t, period)
	var on := ph < PULSE_ON
	if on and not _bot.attack:
		_bot.press_attack_edge()
	elif not on and _bot.attack:
		_bot.release_attack_edge()
	_bot.attack = on


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



func _tick_brawl_phase(delta: float) -> void:
	_tick_backoff(delta)
	_tick_brawl(delta)


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
	# 判据用"比分多久没动"而不是"多久没收到 kill_event":两者大多同源,但比分会因为
	# 任何一端的击杀而前进,而"离收局还差多少"才是这里要问的事。
	var total := int(_scores.get(1, 0)) + int(_scores.get(2, 0))
	if total != _last_score_total:
		_last_score_total = total
		_since_kill = 0.0
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
	var t_lead: float = clampf(d.length() / 1000.0, 0.0, 0.5)
	var aim_at := tgt + _vel_of(_nearest_enemy_role()) * t_lead
	_bot.aim = _delta(_local.global_position, aim_at).normalized()
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


func _nearest_enemy_role() -> int:
	return _brawl_pick



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
	if idx == 6:
		_esc_leave()
		return
	_leave_t = _t
	_phase = PH_OBSERVE
	_phase_t = 0.0


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
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	var opened := bool(pm.get("_open"))
	_rec("PAUSE_MENU opened=%d" % (1 if opened else 0))
	if not opened:
		_fail("按 ESC 没打开暂停菜单(_open 仍为 false)")
	_log("已按 ESC 打开菜单 → 点「回 到 主 菜 单」(t=%.1fs)" % _t)
	_finish()
	pm.call("go_menu")
	get_tree().create_timer(0.4).timeout.connect(func() -> void: get_tree().quit(0))



func _tick_observe() -> void:
	_bot.axis = 0.0
	_bot.attack = false
	if _round_state != 1 and not _match_over:
		_obs_playing_bad = true
	if _match_over:
		_fail("相⑤:6 号离场后服务器终局了(MATCH_OVER)—— 该队还有 2 人,不该终局")
		_finish()
		return
	if _phase_t > OBSERVE_MAX:
		_fail("相⑤ 观察窗 %.0fs 内没观察到掉线者被移出对局(快照里仍没有 role 消失)" % OBSERVE_MAX)
		_finish()
		return
	var gone := _gone_from_snapshot()
	if not gone.is_empty():
		var r := int(gone[0])
		var st = _game.get("state")
		_left_in_replica = 0 if st != null and st._replicas.has(r) else 1
		if _left_in_replica == 1 and _phase_t > LEAVE_AT + 1.0:
			_rec("LEFT gone=%s obsmax=%.0fms sessionmax=%.0fms(sessionmax_phase=%d) playing=%d replica_gone=1"
					% [str(gone), _obs_max_gap, _snap_max_gap, _snap_max_phase,
					1 if not _obs_playing_bad else 0])
			_log("相⑤ 已观察到 role %s 被移出对局(副本已拆);观察窗 %.1fs(窗内最大间隔 %.0fms;"
					% [str(gone), _phase_t, _obs_max_gap]
					+ "全会话最大 %.0fms,发生于相位 %d)" % [_snap_max_gap, _snap_max_phase])
			if _obs_playing_bad:
				_fail("相⑤ 观察窗内 round_state 离开过 PLAYING(服务器不该因少人改状态)")
			if _obs_max_gap > 1000.0:
				_fail("相⑤ 观察窗内快照间隔 %.0fms > 1s(可能是本进程停顿,也可能是服务器对本 peer 的定向投递异常 —— 无法区分,保守判红)"
						% _obs_max_gap)
			_finish()
			return


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



func _on_snap_world(snap: Dictionary) -> void:
	var now := Time.get_ticks_usec()
	if _last_snap_us > 0:
		var gap := float(now - _last_snap_us) / 1000.0
		_snap_gaps.append(gap)
		if gap > _snap_max_gap:
			_snap_max_gap = gap
			_snap_max_phase = _phase
		if _phase == PH_OBSERVE and gap > _obs_max_gap:
			_obs_max_gap = gap
	_last_snap_us = now
	_snap_world = snap


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


var _nav_adj: Dictionary = {}
var _nav_built := false
var _path: Array = []
var _path_to := Vector2i(-99, -99)
var _repath_t := 0.0
var _stuck_t := 0.0
var _best_dist := INF
var _stuck_to := Vector2i(-99, -99)
var _brawl_skip := 0
var _brawl_pick := 0
var _last_node := Vector2i(-99, -99)
var _k_used := 0
const K_MAX := 2
const STUCK_K := 8.0


func _build_nav_graph() -> void:
	var d := _dims()
	_nav_adj.clear()
	var nodes: Array = []
	for y in d.y:
		for x in d.x:
			var c := Vector2i(x, y)
			if _standable(c):
				nodes.append(c)
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


func _standable(c: Vector2i) -> bool:
	if _nav_climbable(c):
		return true
	return _nav_cell_solid(c) == 0 and _nav_blocked(c + Vector2i(0, 1)) \
			and _nav_cell_solid(c + Vector2i(0, -1)) == 0


func _nav_neighbors(c: Vector2i) -> Array:
	var out: Array = []
	for dx in [-1, 1]:
		var n := c + Vector2i(dx, 0)
		if _standable(n):
			out.append(n)
	if _nav_climbable(c):
		for dy in [-1, 1]:
			var n2 := c + Vector2i(0, dy)
			if _standable(n2) or _nav_climbable(n2):
				out.append(n2)
	for dx2 in [0, -1, 1]:
		if _nav_blocked(c + Vector2i(dx2, 1)):
			continue
		for k in range(1, 30):
			var n3 := c + Vector2i(dx2, k)
			if _nav_blocked(n3):
				break
			if _standable(n3):
				out.append(n3)
				break
	for dy2 in [1, 2, 3]:
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
	_repath_t -= delta
	if _path_to != tc or _path.is_empty() or _repath_t <= 0.0:
		_path = _find_path(_last_node, tc)
		_path_to = tc
		_repath_t = 0.7
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
	if _nav_adj.has(my_cell):
		_last_node = my_cell
	var foot_cell := GridPathfinder.cell_of(Vector2(me.x, me.y + TILE * 0.5),
			TILE, _dims().x, _dims().y)
	var on_ladder := _nav_climbable(my_cell) or _nav_climbable(foot_cell)
	var latched := bool(_local.climb.is_latched())
	var want_vert := absf(wp.y) > TILE * 1.2
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
		_bot.hold_up = true
		_bot.hold_down = false
		_bot.axis = ax
		_bot.press_jump()
		return
	_bot.hold_up = false
	_bot.hold_down = false
	_bot.axis = ax
	if _local.is_on_floor() and (want_vert or absf(wp.x) > TILE * 0.6):
		_bot.press_jump()
	elif absf(_local.velocity.x) < 30.0 and absf(wp.x) > TILE * 0.5 and _local.is_on_floor():
		_bot.press_jump()


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
