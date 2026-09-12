extends Node

# 大乱斗压力探针(场景模式):一个进程当大厅/裁判,再拉起 N 个 headless 客户端子进程,
# 每个客户端**跑真 `royale_game` 场景**(不是只连上数快照的轻量客户端 —— 卡顿就发生在
# 建图/副本/HUD/后处理那个世界里),并用脚本机器人把局内行为踩一遍。
#
# 用法:
#   "$GODOT" --headless --path . res://tests/royale_soak_probe.tscn [-- --clients=4 --match=60 --run=90]
# 无参 = 大厅/裁判。**跑前先确认 7777 空闲**(有僵尸 Godot 占着会直接 FAIL)。
# 收尾建议用 tests/royale_soak_probe.sh(Windows 下 bash kill 杀不死 headless Godot)。
#
# 埋点(每客户端写一份 user://soak_cN.result):
#   - 主循环帧间隔 avg/p95/max、>33ms 帧数、>100ms 卡顿次数与最坏发生时刻
#   - 收到快照的 次数/字节每秒、**到达间隔 max/p95**(这条从客户端视角量 worker 侧有没有停)
#   - round_state / kill_event / hit_event 计数、本地玩家倒地(复活)次数
#   - 是否等到 MATCH_OVER
#
# ★ 边界(报告里必须照抄,别把数字说过头):
#   1. headless 客户端**没有渲染** → 量到的是网络 + 模拟 + 场景树成本,**不含画面**。
#      "渲染卡不卡" 本探针答不了,得开真客户端看。
#   2. 大乱斗客户端上报的输入包**不带 seq**(royale_game.gd 的 pkt 无该字段),
#      故快照里的 ack_seq 恒为 0 → 客户端无从推算 _pending_input 积压。
#      输入积压是本机压测量不到的**代码级风险**,只在报告里给机制与触发条件。
#   3. 崩溃判据 = 结果文件缺失 / 客户端进程消失,**不是** "没看见报错"。
#   4. MATCH_OVER 之后 royale_game 那条 6s 回主菜单的换场路径**不在本探针覆盖内**
#      (客户端在 MATCH_OVER 当场写结果并退出,否则换场会把探针自己摘掉、丢掉全部读数)。

const BotInput := preload("res://tests/soak_bot_input.gd")

const RESULT_PREFIX := "soak_"
const ROOM_FILE := "user://royale_soak_room.txt"
const INVITE := "927"
const ADDR := "127.0.0.1"

var _role := "lobby"
var _idx := 1
var _clients := 4
var _match_secs := 60        # 一局时长(经 player_options 的 match_time 下发;role1 那份生效)
var _run_secs := 120.0       # 每客户端观测窗上限(> match_secs,好等到 MATCH_OVER)

# ── 客户端状态 ──
var _start_us := 0
var _flow_us := 0
var _match_running := false
var _match_over := false
var _bot = null
var _local: Node2D = null
var _game: Node = null

# ── 埋点 ──
var _proc_gaps: Array = []
var _stalls_100 := 0
var _frames_33 := 0
var _worst_ms := 0.0
var _worst_at := 0.0
var _last_proc_us := 0
var _snap_count := 0
var _snap_bytes := 0
var _snap_gaps: Array = []
var _snap_worst_ms := 0.0
var _last_snap_us := 0
var _round_states := 0
var _kills := 0
var _hits := 0
var _deaths := 0
var _was_downed := false
var _done := false
var _others: Dictionary = {}      # role(int) -> canonical 位置(快照来,给机器人指路)
var _suicide_at: Array = []       # 计划自杀的时刻(距进对局秒数):压 K 自杀 → 复活链路
var _saw_left := 0                # 收到过几份「left 非空」的 round_state(别人离场了)
var _esc_done := false            # 本端是否已执行「按 ESC 离场」
# 卡顿/事件的时间轴(只记 >33ms 的帧与关键事件,上限各 40 条):报告里要对"哪一帧卡了、
# 当时场上发生了什么"——只给一个 max 值没法归因,而"四端同时卡在同一点"这类线索全靠它。
var _marks: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--clients="):
			_clients = maxi(int(a.trim_prefix("--clients=")), 2)
		elif a.begins_with("--match="):
			_match_secs = maxi(int(a.trim_prefix("--match=")), 20)
		elif a.begins_with("--run="):
			_run_secs = float(a.trim_prefix("--run="))
	_idx = int(_role.trim_prefix("c")) if _role.begins_with("c") else 1
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


# ══ 裁判:起大厅 + 拉起 N 个客户端 + 收结果 ══
func _run_orchestrator() -> void:
	var err := NetBus.start_server()
	if err != OK:
		print("SOAK: 大厅监听失败 err=%d(7777 被占?先清僵尸 Godot)" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	if FileAccess.file_exists(ROOM_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOM_FILE))
	for i in range(1, _clients + 1):
		var p := "user://%s%s.result" % [RESULT_PREFIX, _result_tag(i)]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var exe := OS.get_executable_path()
	for i in range(1, _clients + 1):
		OS.create_process(exe, PackedStringArray(["--headless", "--path",
				ProjectSettings.globalize_path("res://"), "res://tests/royale_soak_probe.tscn",
				"--", "--role=c%d" % i, "--clients=%d" % _clients,
				"--match=%d" % _match_secs, "--run=%.0f" % _run_secs]))
	print("SOAK: 大厅就绪,%d 客户端已拉起(match=%ds run=%.0fs)" % [_clients, _match_secs, _run_secs])
	var deadline := Time.get_ticks_msec() + int((_run_secs + 120.0) * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(2.0).timeout
		var finished := 0
		for i in range(1, _clients + 1):
			var r := _read_result(i)
			if r.begins_with("OK") or r.begins_with("FAIL"):
				finished += 1
		if finished >= _clients:
			break
	var bad := 0
	print("SOAK: ── 各客户端读数 ──")
	for i in range(1, _clients + 1):
		var r := _read_result(i)
		if not (r.begins_with("OK") or r.begins_with("FAIL")):
			bad += 1
			print("  c%d: ★ 无结果文件 = 进程没跑完(崩溃/挂死)→ %s" % [i, r])
		else:
			if r.begins_with("FAIL"):
				bad += 1
			print("  c%d: %s" % [i, r])
	print("SOAK: %s(%d/%d 客户端正常收尾)" % [
			"ALL-OK" if bad == 0 else "有 %d 个客户端异常" % bad, _clients - bad, _clients])
	get_tree().quit(0 if bad == 0 else 1)


func _result_tag(i: int) -> String:
	return "c%d" % i


func _read_result(i: int) -> String:
	var p := "user://%s%s.result" % [RESULT_PREFIX, _result_tag(i)]
	if not FileAccess.file_exists(p):
		return "(未完成)"
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else "(读取失败)"


# ══ 客户端 ══
func _run_client() -> void:
	Engine.max_fps = 60     # 与真客户端同节奏;不设就变成"跑多快算多快",帧间隔读数失去意义
	_flow_us = Time.get_ticks_msec()
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(func(_k: int, _v: int) -> void:
		_kills += 1
		_mark("%.1fs 击杀播报" % _elapsed()))
	NetBus.local_hit_event.connect(func(_r: int, _d: int, _p: Vector2) -> void:
		_hits += 1
		_mark("%.1fs 受击 %d 伤" % [_elapsed(), _d]))
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_go_match.connect(_on_go_match)
	# 开局三载荷的第二条投递路径:worker 在同一帧发 peer_info/peer_hues/match_options 与 match_start,
	# 那一刻 royale_game 还没建 → 由本节点接住缓存进 PvpSession(与 royale_lobby 同款)。
	NetBus.local_peer_info.connect(func(n: Dictionary) -> void: PvpSession.pending_peer_info = n)
	NetBusExt.local_peer_hues.connect(func(h: Dictionary) -> void: PvpSession.pending_peer_hues = h)
	NetBusExt.local_match_options.connect(func(o: Dictionary) -> void: PvpSession.pending_match_options = o)
	# 全流程兜底:连大厅→建房/加入→转连→claim→match_start 走不完就 FAIL 退出(否则挂死)
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		if is_inside_tree() and not _match_running:
			_finish(false, "60s 内没进对局(流程卡住)"))
	multiplayer.connected_to_server.connect(func() -> void:
		NetBus.rpc_id(1, "lobby_name", "BOT%d" % _idx)
		_after_lobby_connected(), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_finish(false, "连大厅失败"), CONNECT_ONE_SHOT)
	var e := NetBus.start_client(ADDR)
	if e != OK:
		_finish(false, "start_client 失败 %d" % e)


func _after_lobby_connected() -> void:
	if _idx == 1:
		# 房主:建房(私密 + 邀请码,房号写中间文件给其余人读)→ 满员后 royale_start
		NetBusExt.local_royale_room_state.connect(func(state: Dictionary) -> void:
			var code := str(state.get("code", ""))
			if code != "" and not FileAccess.file_exists(ROOM_FILE):
				var rf := FileAccess.open(ROOM_FILE, FileAccess.WRITE)
				rf.store_string(code)
				rf.close()
			var n: int = (state.get("players", []) as Array).size()
			if n >= _clients and not _match_running:
				print("SOAK[c1]: 房内 %d 人 → 开局" % n)
				NetBusExt.rpc_id(1, "royale_start"))
		NetBusExt.rpc_id(1, "royale_create", {
			"is_public": false, "invite_code": INVITE, "max_players": _clients,
			"round_full_heal": false, "disabled_weapons": [],
		})
	else:
		# 其余:等 c1 把房号写出来再加入
		_wait_room_code.call_deferred()


func _wait_room_code() -> void:
	var code := ""
	for _i in range(150):
		await get_tree().create_timer(0.2).timeout
		if FileAccess.file_exists(ROOM_FILE):
			var rf := FileAccess.open(ROOM_FILE, FileAccess.READ)
			code = rf.get_as_text().strip_edges()
			rf.close()
			if code != "":
				break
	if code == "":
		_finish(false, "没等到房号文件")
		return
	NetBusExt.rpc_id(1, "royale_join", code, INVITE)


# go_match 在大厅 peer 的 poll 调用栈内到达 → 转连必须推到帧末(与 royale_lobby 同款)
func _on_go_match(role: int, port: int) -> void:
	PvpSession.role = role
	PvpSession.royale = true
	PvpSession.clear_pending_payloads()
	_do_go_match.call_deferred(role, port)


func _do_go_match(role: int, port: int) -> void:
	multiplayer.connected_to_server.connect(func() -> void:
		NetBus.rpc_id(1, "claim_role", role, "BOT%d" % _idx)
		NetBusExt.rpc_id(1, "player_options", {
			"hue": float((_idx - 1) * 40),
			"round_full_heal": false,
			"disabled_weapons": [],
			"match_time": _match_secs,
		}), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_finish(false, "连 worker 失败"), CONNECT_ONE_SHOT)
	NetBus.stop()
	var e := NetBus.start_client(ADDR, port)
	if e != OK:
		_finish(false, "start_client(worker) 失败 %d" % e)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	if spawn.x < 0:
		_finish(false, "match_start 出生点无效")
		return
	# RPC 在 poll 调用栈内到达,栈内建大物理世界会偶发原生段错误(与 royale_lobby 同款)
	_enter_match.call_deferred()


func _enter_match() -> void:
	_game = (load("res://scenes/royale_game.tscn") as PackedScene).instantiate()
	add_child(_game)
	await get_tree().process_frame
	_local = get_tree().get_first_node_in_group("player") as Node2D
	if _local == null:
		_finish(false, "对局场景里没找到 player 组的本地玩家")
		return
	_bot = BotInput.new()
	_local.set_input_source(_bot)
	# 各客户端错开时刻按 K(自杀→复活链路);只压在观测窗的前 2/3,别撞 MATCH_OVER
	_suicide_at = [15.0 + 7.0 * float(_idx), 45.0 + 5.0 * float(_idx)]
	_match_running = true
	_start_us = Time.get_ticks_msec()
	_last_proc_us = Time.get_ticks_usec()
	print("SOAK[c%d]: 进对局 role=%d spawn=%s" % [_idx, PvpSession.role, str(PvpSession.spawn)])
	set_process(true)
	set_physics_process(true)


func _process(_delta: float) -> void:
	if not _match_running or _done:
		return
	var now := Time.get_ticks_usec()
	var ms := float(now - _last_proc_us) / 1000.0
	_last_proc_us = now
	if ms > 0.0:
		_proc_gaps.append(ms)
		if ms > 33.0:
			_frames_33 += 1
			_mark("%.1fs 帧 %.0fms" % [float(now - _start_us) / 1e6, ms])
		if ms > 100.0:
			_stalls_100 += 1
		if ms > _worst_ms:
			_worst_ms = ms
			_worst_at = float(now - _start_us) / 1e6
	# 本地玩家倒地 → 复活次数(把复活路径也数进去)
	if _local != null and is_instance_valid(_local) and _local.has_method("is_downed"):
		var d: bool = _local.is_downed()
		if d and not _was_downed:
			_deaths += 1
			_mark("%.1fs 我方倒地" % _elapsed())
		_was_downed = d
	_check_deadline()


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _start_us) / 1000.0


func _mark(s: String) -> void:
	if _marks.size() < 40:
		_marks.append(s)


func _physics_process(_delta: float) -> void:
	if _bot == null or not _match_running or _done:
		return
	_bot.step()
	# ★ 让机器人**追着最近的对手打**:只按固定脚本走的话,开局散点相隔 15 格以上,
	#   整局根本不会交战 —— kill/hit/倒地/复活这些路径一次都踩不到(首压实测四项全 0)。
	#   故本帧步进后覆盖 axis/aim:相位脚本仍管跳/冲刺/蹲/切枪/开火,方向交给"找人"。
	var tgt: Vector2 = _nearest_other()
	if tgt != Vector2.INF:
		var me: Vector2 = _local.global_position
		var d: Vector2 = MazeGenerator.toroidal_delta_px(me, tgt,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		_bot.axis = signf(d.x)
		_bot.aim = d.normalized() if not d.is_zero_approx() else Vector2.RIGHT
	# K 自杀:压 server_main._on_suicide_request → RoyaleHost.request_suicide_role → 2s 复活
	var el := float(Time.get_ticks_msec() - _start_us) / 1000.0
	while not _suicide_at.is_empty() and el >= float(_suicide_at[0]):
		_suicide_at.pop_front()
		NetBusExt.rpc_id(1, "suicide_request")
	# 局内按 ESC 回主菜单(只让最后一个客户端做):见 _esc_leave
	if _idx == _clients and not _esc_done and el >= float(_match_secs) * 0.45:
		_esc_leave()


# 局内按 ESC 回主菜单 —— 唯一走过 `Level0.safe_change_scene` 的**局内**退出路径
# (本仓历史上那条路径偶发原生段错误,`_switching` 防重入就是为它加的)。
# 一次压到四件事:①该换场本身不崩;②服务器侧 `_on_peer_left` → `RoyaleHost.mark_disconnected`
# 把该 role 移出对局而其余人继续;③其余端收到 `round_state.left` 非空;④其余端把离场者的
# 副本/头顶 ID/血条一起拆掉(`royale_game._remove_replica` 那条路径)。
func _esc_leave() -> void:
	_esc_done = true
	_done = true   # 止住 _process/_check_deadline,离场后不再写第二份结果
	var pm: Node = null
	for c in _game.get_children():
		if c is PauseMenu:
			pm = c
			break
	if pm == null:
		_write_only("FAIL c%d 对局场景里没找到 PauseMenu" % _idx)
		get_tree().quit(1)
		return
	# ★ 先把读数落盘再离场:离场会把**本探针自己**(== current_scene 根)退役掉,之后写不了文件。
	#   若换场把进程搞崩(历史 bug 的形态),这份文件就**不会存在** → 裁判按「无结果文件」判 FAIL。
	_write_only("OK c%d 按 ESC 离场(t=%.1fs;只验不崩 + 其余端继续)" % [_idx, _elapsed()])
	print("SOAK[c%d]: t=%.1fs 按 ESC 回主菜单(换场前已落盘读数)" % [_idx, _elapsed()])
	# ★ 先捕获 SceneTree:退役后本节点不在树上,`get_tree()` 会返回 null(与主仓两处定时器同款坑)
	var t := get_tree()
	pm.go_menu()
	await t.process_frame
	await t.process_frame
	await t.process_frame
	print("SOAK[c%d]: ESC 离场后进程存活,current_scene 已换走=%s" % [_idx, str(t.current_scene != self)])
	t.quit(0)


# 最近的对手 canonical 位置(来自快照);没有对手时返回 INF
func _nearest_other() -> Vector2:
	if _others.is_empty() or _local == null or not is_instance_valid(_local):
		return Vector2.INF
	var me: Vector2 = _local.global_position
	var best := Vector2.INF
	var best_d := INF
	for r in _others:
		var p: Vector2 = _others[r]
		var d: float = MazeGenerator.toroidal_delta_px(me, p,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < best_d:
			best_d = d
			best = p
	return best


func _check_deadline() -> void:
	if _match_over or _done:
		return
	if Time.get_ticks_msec() - _start_us >= int(_run_secs * 1000.0):
		_finish(true, "观测窗 %.0fs 到时(未等到 MATCH_OVER)" % _run_secs)


func _on_snapshot(snap: Dictionary) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	if _last_snap_us > 0:
		var gap := float(now - _last_snap_us) / 1000.0
		_snap_gaps.append(gap)
		_snap_worst_ms = maxf(_snap_worst_ms, gap)
	_last_snap_us = now
	_snap_count += 1
	_snap_bytes += var_to_bytes(snap).size()
	# 顺手记下对手位置(机器人指路用)。royale_game 会把已离开者从快照里摘掉,这里跟着清。
	var ps: Dictionary = snap.get("players", {})
	_others.clear()
	for rs in ps:
		var r := int(rs)
		if r != PvpSession.role:
			_others[r] = (ps[rs] as Dictionary).get("pos", Vector2.ZERO)


func _on_round_state(data: Dictionary) -> void:
	if _done:
		return
	_round_states += 1
	if not (data.get("left", []) as Array).is_empty():
		_saw_left += 1
	# MATCH_OVER(=3)当场收尾:晚一步 royale_game 那条 6s 换场会把本探针一起摘掉、读数全丢
	if int(data.get("state", -1)) == 3 and _match_running:
		_match_over = true
		_finish(true, "跑到 MATCH_OVER")


# ══ 收尾:写结果文件 + 退出 ══
func _finish(ok: bool, why: String) -> void:
	if _done:
		return
	_done = true
	var secs := float(Time.get_ticks_msec() - _start_us) / 1000.0 if _match_running \
			else float(Time.get_ticks_msec() - _flow_us) / 1000.0
	var lines: Array[String] = []
	lines.append("%s c%d %s" % ["OK" if ok else "FAIL", _idx, why])
	if _match_running:
		lines.append("  观测 %.1fs:帧间隔 avg=%.2fms p95=%.2fms max=%.2fms(发生于 %.1fs 处);>33ms %d 帧,>100ms %d 次" % [
				secs, _avg(_proc_gaps), _pct(_proc_gaps, 0.95), _worst_ms, _worst_at,
				_frames_33, _stalls_100])
		lines.append("  快照 %d 次 / %.0f KB(≈%.1f KB/s);到达间隔 max=%.1fms p95=%.1fms" % [
				_snap_count, float(_snap_bytes) / 1024.0,
				float(_snap_bytes) / 1024.0 / maxf(secs, 0.001),
				_snap_worst_ms, _pct(_snap_gaps, 0.95)])
		lines.append("  事件:round_state %d,kill_event %d,hit_event %d,倒地(复活)%d 次,别人离场播报 %d 次" % [
				_round_states, _kills, _hits, _deaths, _saw_left])
		if not _marks.is_empty():
			lines.append("  时间轴:%s" % "; ".join(_marks))
	var text := "\n".join(lines)
	_write_only(text)
	print("SOAK[c%d]: %s" % [_idx, text.replace("\n", "\n  ")])
	get_tree().quit(0 if ok else 1)


# 只落盘、不退出(`_esc_leave` 要在离场前先留证据;离场后本节点已不在树上)
func _write_only(text: String) -> void:
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, _result_tag(_idx)], FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())


func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[clampi(int(p * float(s.size())), 0, s.size() - 1)])
