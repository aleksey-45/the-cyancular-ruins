extends Node

# 断线重连探针的**客户端侧驱动/观察者**(见 reconnect_probe.gd 文件头)。
# 由 `reconnect_probe.gd --role=<who>` 实例化后**挂到 `get_tree().root`**:探针场景 → 真对局场景
# 的那次换场不会把它带走,故它能在换场**之后**读真 `pvp_game` / `royale_game` 实例的状态。
#
# 它做三件事:
#   ① 加入段(镜像 `lobby_page._claim_role_worker` 的三条 RPC):connect → claim_role /
#      player_options / report_token → 等 `match_start` → 进真对局场景;
#   ② 演出段(两种角色):
#      · **actor**(c1/r1):按住右 → 闪断(调真 `_begin_reconnect()`,先塞一个**错 token**)
#        → 相②(错 token 被拒 + 被踢)→ 相①(恢复真 token 后被接受、身体没被销毁);
#      · **witness**(c2/r2):从快照里盯 role1 的身体 → 相③(掉线后 global_position 不变);
#   ③ 收工:写 `user://reconnect_probe_<who>.result`(父进程只认这个 + 引擎日志)。
#
# ★ 客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 自己再落一份
#   `user://reconnect_probe_<who>.log`(阶段轨迹),失败时父进程把它摊开。
#
# ═══ 时间轴(相对**本端**看到 PLAYING 的那一刻 `_tp`)═══
#   两个客户端各自从自己的 PLAYING 起算,而 PLAYING 是服务器**同一条广播**给的(60Hz),
#   两端的 `_tp` 相差 ≤1 帧 → 见证者的观测窗口对齐到 ±0.02s,而窗口有 2.7s 长。
#   actor:0.0 按住右(必须先跑起来)· 0.6 闪断(错 token)· 3.5 恢复真 token · 6.0 断言相①②
#   witness:1.5~4.2 观测窗口(相③,前置速度取闪断前最后一个样本)· 4.6 (c2)永久掉线 · 5.2 收工
#   ★ 按住右**必须在闪断之前就跑够时间**:第一版把它写在闪断那一刻的同一帧,那一帧紧接着
#     `NetBus.stop()`,held=right 的包一个都没发出去 → 相③量到的"位移 0"是**空转的绿**
#     (身体自始至终没动过,冻结与不冻结都测不出来)。相③的前置断言就是为这一档设的。
#   ★ 为什么 3.5 恢复真 token 而窗口到 4.2:**节拍**是 2s(`RECONNECT_RETRY_MS`),闪断后
#     第一次尝试在 0.6、第二次 2.6、第三次 4.6 —— 恢复得比 4.6 早即可,而 4.6 必然晚于窗口
#     结束(SceneTreeTimer 只会晚不会早),故相③的观测窗口里**不会有**"重连成功、身体重新
#     跑起来"污染。
#
# ═══ actor 收工后**不退出** ═══
#   相④ 要的是"某个 role 永久掉线、宽限期到点收场"。若 actor 在写完成绩后退出,它的 role 也会
#   进宽限,worker 的「进宽限」就变成 3 次、到点收场的那个 role 也换了人 —— 相④的判据(时间差)
#   立刻失去意义。故 actor 写完结果后**保持连接**待命,由裁判杀端口收尾。

const BAD_TOKEN := "00000000deadbeef"   # 长度同真 token(16 hex),但值必然不匹配
const T_DROP := 0.6        # 闪断时刻(相对本端看到 PLAYING)
# ── 闪断前的一小串输入包(**确定性装置**,只服务相③)──
# 为什么要有它:掉线那一刻服务器 `_pending_input[role]` 里**可能**还有没消费完的包(客户端 60Hz
# 上行、服务器每 tick 只消费一个 → 队列长度在 0~2 之间抖动),而 `_enter_grace` 的 `reset_state()`
# **不清队列**:那条迟到的包会在复位**之后**被 `apply_packet` 施加一次,把 `_held` 整个写回去 ——
# 而 `clear_edges()` 不清 `_held`、队列空了也不再 `apply_packet`,于是"掉线前按着的那几个键"
# 被**重新武装并保持整个宽限期**。不塞这一串时这个竞态约 50% 命中(实测:同一份代码连跑两趟,
# 卡住的是 1v1 还是大乱斗会互换),探针会飘;塞了就必然命中 —— 这才是它能当回归防卫的原因。
# ★ 反证(证明"承重的是包里的 held,不是包本身"):把它整段换成恒中性(held=0)重跑,相③转绿。
const BURST_N := 10
const BURST_AT := 0.50     # 比闪断早 0.1s:够 RPC 落地(下一帧 flush),又不至于被服务器排空
var _burst_done := false
const T_RESTORE := 3.5
const T_ACTOR_END := 6.0
const W_START := 1.5
const W_END := 4.2
const T_W_DROP := 4.6
const T_W_END := 5.2
# 身体冻结判据(px)。参考量级:move_speed=700、accel_ground=30(时间常数 33ms)→
# 不调 `_enter_grace` 里的 `reset_state()` 时,身体在整个窗口内保持 ~700px/s → 漂移 ≈ 1900px;
# 调了则 ~0.1s 内停住,窗口从掉线后 0.9s 才开始,尾部完全静止。
# ⚠ **位移这一条单独拎出来是可以空转的**:身体撞墙/卡进坑里时,不论调没调 `reset_state()`
#   位移都是 0 —— 本探针第一版的红绿就这么骗过了一次(反证跑出来才发现:不闪断时身体
#   也停在同一处)。故相③的**判据主体是姿态**(见下),位移只作辅助读数。
const DRIFT_TOL := 80.0
# ★★ 相③的判据主体:**姿态**(快照的 `pose` 字段 = `player.state`)。
#   `player.gd` 的 `enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }`,其中 SQUAT 逐帧由
#   `is_on_floor() and input_source.is_action_pressed("down")` 推导 —— 即"**输入源现在按着 S**"
#   这个事实本身。于是:
#     · 掉线前:身体蹲着(pose=SQUAT)= 前置(证明输入真的被服务器吃到了);
#     · 掉线后:调了 `reset_state()` → 输入清空 → 姿态在 0.2s 内离开 SQUAT;
#               没调 → 服务器继续按着 S → 姿态**整个宽限期都是 SQUAT**。
#   这条判据与地形无关(撞墙、卡坑都照样成立),这才是"身体冻结"真正该钉的东西。
const POSE_SQUAT := 4       # = player.gd 的 Pose.SQUAT(枚举末位;改枚举要同步这里)

var who := "c1"
var port := 0
var token := ""
var slot := 1
var scene_path := "res://scenes/pvp_game.tscn"
var is_royale := false
var is_actor := true
var drop_permanently := false

var _t := 0.0
var _stage := 0
var _tp := -1.0
var _entered := false
var _game: Node = null
var _playing := false
var _failures: Array[String] = []
var _notes: Array[String] = []
# ── 观测量 ──
var _snap_count := 0
var _snap_at_drop := 0
var _kick_count := 0
var _last_rs: Dictionary = {}       # 最近一条 round_state(相①"对局状态未被重置"的取数点)
var _rs_before: Dictionary = {}     # 闪断前最后一条
var _before_local_id := 0
var _before_game_id := 0
var _saw_reconnecting := false
var _drop_done := false
var _restored := false
var _pressed := false
var _own_vel := Vector2.ZERO
var _track: Array = []              # 相③:role1 的快照样本 [t, pos, speed]
var _samples_open := true
var _perm_dropped := false
var _done := false


func _ready() -> void:
	var lp := "user://reconnect_probe_%s.log" % who
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	PvpSession.role = slot
	PvpSession.token = token
	PvpSession.worker_port = port
	PvpSession.server_address = "127.0.0.1"
	PvpSession.player_name = who.to_upper()
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_round_state.connect(_on_round_state)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void: _log("连 worker 失败"), CONNECT_ONE_SHOT)
	var err := NetBus.start_client("127.0.0.1", port)
	_log("观察者就绪(role=%s port=%d scene=%s actor=%s)" % [who, port, scene_path, str(is_actor)])
	if err != OK:
		_finish("start_client 失败 %d" % err)


# 加入段:与 `lobby_page._claim_role_worker` 逐条对应(claim 保持原版 2 参;选项/token 走扩展节点)
func _on_connected() -> void:
	_log("已连 worker,claim role %d" % slot)
	NetBus.rpc_id(1, "claim_role", slot, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", {})
	NetBusExt.rpc_id(1, "report_token", token)


# `match_start` 有**两个**到达时机:① 首次开局进场;② worker 接受 reclaim 之后重发的那条。
# ② 绝不能二次换场(那条路本来就不重建世界)—— 用 `_entered` 挡住,场景内那半由
# `pvp_game._on_match_start_event` 处理(它只在 `_reconnecting` 为真时收尾)。
func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	if _entered:
		_log("收到重连后的 match_start(role=%d spawn=%s)—— 本观察者不换场" % [role, str(spawn)])
		return
	_entered = true
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	_log("match_start role=%d spawn=%s map=%s → 进对局场景" % [role, str(spawn), map_path])
	# `_enter_match_scene` 同款(1v1 是裸 change_scene_to_file;这里统一延到帧末,
	# 因为本函数跑在 RPC 的 poll 调用栈里)
	get_tree().call_deferred("change_scene_to_file", scene_path)


func _on_server_message(msg: String) -> void:
	if msg.contains("断开"):
		_kick_count += 1
		_log("收到「%s」(第 %d 次)—— 与错 token 被踢那一拍对得上" % [msg, _kick_count])


func _on_round_state(data: Dictionary) -> void:
	var st := int(data.get("state", -1))
	if st == 1 and not _playing:
		_playing = true
		_tp = _t
		_log("PLAYING")
	_last_rs = data
	if not _drop_done:
		_rs_before = data


func _on_snapshot_world(world: Dictionary) -> void:
	_snap_count += 1
	# role 1 那一份:见证者靠它做相③;actor 靠它给自己留一条诊断(本端速度 vs 权威速度)
	var pl: Dictionary = (world.get("players", {}) as Dictionary).get("1", {})
	if pl.is_empty():
		return
	_own_vel = pl.get("vel", Vector2.ZERO)
	if _playing and _tp >= 0.0 and _samples_open and not is_actor:
		_track.append([_t - _tp, pl.get("pos", Vector2.ZERO),
				(pl.get("vel", Vector2.ZERO) as Vector2).length(), int(pl.get("pose", -1)),
				bool(pl.get("downed", false)), float(pl.get("hp", -1.0)),
				float(pl.get("waterproof", -1.0))])


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	if _t > 58.0:
		_finish("观察者超时(阶段 %d)" % _stage)
		return
	if _game == null:
		var cs: Node = get_tree().current_scene
		if cs != null and cs.get("_local") != null:
			_game = cs
			_log("对局场景已就位")
	if _stage == 0:
		if _game != null and _playing:
			_stage = 1
		return
	var el := _t - _tp
	if is_actor:
		_actor_tick(el)
	else:
		_witness_tick(el)


# ── actor(c1/r1):闪断 → 相② → 相① ──
func _actor_tick(el: float) -> void:
	# ★ 按住 S(蹲)**从 PLAYING 那一刻就按**:闪断要发生在"输入已被服务器吃到"之后(相③前置)。
	# ★★ **不要**顺手把"按右"也加上:第一版按了右,身体蹲走着掉进地图上的一个坑、卡在坑壁,
	#   于是 `pose` 因为 `climb` 的 `latched` 分支(`_tick_crouch_and_dash` 在 latched/in_water
	#   时**不更新 is_squat`)而停在 SQUAT、位移也天然为 0 —— 两条读数同时被地形污染。
	#   原地蹲没有这个问题:身体站在出生点不动,`pose` 只反映"输入源此刻按没按着 S"。
	if not _pressed:
		_pressed = true
		Input.action_press("down")
	if not _burst_done and el >= BURST_AT:
		_burst_done = true
		# 带的正是"按着 S"(held=BIT_DOWN)—— 与此刻客户端的真实输入一致,不是伪造的键位
		for i in range(BURST_N):
			NetBus.rpc_id(1, "send_input", {"seq": 900000 + i, "ax": 0.0,
					"held": PacketInputSource.BIT_DOWN, "pressed": 0, "released": 0,
					"weapon": 0, "aim": Vector2.ZERO})
		_log("闪断前塞入 %d 条输入包(held=BIT_DOWN)作为相③的确定性装置" % BURST_N)
	if not _drop_done and el >= T_DROP:
		_drop_done = true
		_snap_at_drop = _snap_count
		_before_local_id = (_game.get("_local") as Object).get_instance_id()
		_before_game_id = _game.get_instance_id()
		# 相②:先塞错 token —— worker 读它发生在 `_try_reclaim` **发的那一刻**
		PvpSession.token = BAD_TOKEN
		var lv: Vector2 = (_game.get("_local") as Node2D).velocity
		_log("闪断(调真 _begin_reconnect,错 token=%s);local_id=%d game_id=%d snap=%d 本端速度=%s 快照速度=%s" % [
				BAD_TOKEN, _before_local_id, _before_game_id, _snap_at_drop, str(lv.round()),
				str(_own_vel.round())])
		_game.call("_begin_reconnect")
	if not _restored and el >= T_RESTORE:
		_restored = true
		PvpSession.token = token
		_log("恢复真 token(相②已验完),等下一次节拍 reclaim")
	if _drop_done and _game.get("_reconnecting") == true:
		_saw_reconnecting = true
	if el >= T_ACTOR_END:
		_actor_assert()


func _actor_assert() -> void:
	# 相②的客户端侧一半:错 token 那一发**真的被踢了**(worker 侧另一半在裁判的日志断言里)
	_check(_kick_count >= 1, "相②(客户端侧):错 token 被拒后收到「服务器断开」(实得 %d)" % _kick_count)
	# 相①:重连循环真的跑起来了、且已收尾
	_check(_saw_reconnecting, "相①:闪断后 `_reconnecting` 真的置起(重连循环在跑)")
	_check(_game.get("_reconnecting") == false, "相①:重连已收尾(_reconnecting 归假 = _on_resumed 跑过)")
	_check(NetBus.can_send_to_server(), "相①:连接真的接回来了(can_send_to_server)")
	# 相①的核心:身体没被销毁 —— 场景与玩家节点都是**同一个实例**
	_check((_game.get("_local") as Object).get_instance_id() == _before_local_id,
			"相①:玩家节点还是同一个 instance_id(身体没被销毁 = 状态一条都不用恢复)")
	_check(_game.get_instance_id() == _before_game_id, "相①:对局场景未被重建(同一 instance_id)")
	# 快照真的续上了(unreliable,断线期间没有;接回来必须重新开始涨)
	_check(_snap_count > _snap_at_drop + 20,
			"相①:重连后快照续上(+%d 条)" % (_snap_count - _snap_at_drop))
	# 大乱斗:对局状态一并没有被重置(比分相同 + 时钟继续走而不是回到 300)
	if is_royale and not _last_rs.is_empty() and not _rs_before.is_empty():
		_check(_last_rs.get("scores", {}) == _rs_before.get("scores", {}),
				"相①(大乱斗):round_state 的 scores 未变")
		var tb := float(_rs_before.get("timer", 0.0))
		var ta := float(_last_rs.get("timer", 0.0))
		_check(ta < tb and ta > tb - 15.0,
				"相①(大乱斗):对局时钟继续走(%.0f → %.0f),未被重置" % [tb, ta])
		_notes.append("%s(大乱斗): tick 前 %.0f → 后 %.0f, scores=%s" % [who, tb, ta,
				str(_last_rs.get("scores", {}))])
	_log("相①/② 断言完成 kick=%d snap=+%d" % [_kick_count, _snap_count - _snap_at_drop])
	_finish("", true)   # actor **不退出**(见文件头);裁判杀端口收尾


# ── witness(c2/r2):相③(盯 role1 的身体)──
func _witness_tick(el: float) -> void:
	if el >= W_END and _samples_open:
		_samples_open = false
		_witness_assert()
	if drop_permanently and not _perm_dropped and el >= T_W_DROP:
		_perm_dropped = true
		# 相④:永久掉线(**不 reclaim**)—— 真 ENet 断开,worker 侧进宽限、到点收场。
		# ★ `NetBus.stop()` 不发 `server_disconnected`(见探针文件头),所以客户端的重连循环
		#   不会启动 —— 这正是"掉线后不回来"该有的样子。
		_log("永久掉线(NetBus.stop,不 reclaim)")
		NetBus.stop()
	if el >= T_W_END:
		_finish("")


func _witness_assert() -> void:
	# 前置:闪断**前最后一个样本**里 role1 蹲着(pose=SQUAT)—— 蹲姿逐帧由"输入源此刻按着 S"
	# 推导,故它同时证明了两件事:① 输入真的被服务器吃到了;② 身体此刻在地面上(不是坠落中)。
	var pre_speed := -1.0
	var pre_pose := -1
	for s in _track:
		if float(s[0]) <= T_DROP:
			pre_speed = float(s[2])
			pre_pose = int(s[3])
	_check(pre_pose == POSE_SQUAT,
			"相③前置:闪断前 role1 处于蹲姿(pose=%d,期望 SQUAT=%d;速度 %.0f px/s)"
			% [pre_pose, POSE_SQUAT, pre_speed])
	# 窗口内的位移(环面最短向量:地图左右回绕,别拿裸距离比)
	var first: Variant = null
	var last: Variant = null
	var peak := 0.0
	var squat_in_window := 0
	var _downed_in_window := 0
	for s in _track:
		var st := float(s[0])
		if st >= W_START and st <= W_END:
			if first == null:
				first = s
			last = s
			peak = maxf(peak, float(s[2]))
			if int(s[3]) == POSE_SQUAT:
				squat_in_window += 1
			if bool(s[4]):
				_downed_in_window += 1
	if first == null or last == null:
		_check(false, "相③:观测窗口内一条快照样本都没有(role1 从快照里消失了?)")
		return
	# ★ 相③的判据主体(与地形无关):掉线后输入真的被清空 → 姿态离开蹲姿
	# ⚠ 这一条在**当前生产代码上恒红**,原因与建议改法见 reconnect_probe.gd 文件头的「已知红」节。
	_check(squat_in_window == 0,
			("相③:掉线后该 role 的输入**没有**被清空(窗口内蹲姿样本 %d 个,期望 0)—— "
			+ "`_enter_grace` 的 `reset_state()` 被一条已排队的输入包撤销,见探针文件头「已知红」")
			% squat_in_window)
	var drift: float = GridPathfinder.toroidal_delta_px(first[1], last[1],
			float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT)).length()
	# ★ brief 字面要的那条(global_position 不变)—— 留着,但**只作读数不作判据**:
	#   反证实测过它是可以空转的(身体撞墙/卡坑时,不调 `reset_state()` 位移照样是 0)。
	#   上面那条姿态才是承重的;谁要把本行改回 `_check`,`DRIFT_TOL` 的注释就是理由。
	_notes.append("%s: 相③样本 %d 条,窗口位移 %.1f px(阈值 %.0f;brief 的 position 读数,不作判据)"
			% [who, _track.size(), drift, DRIFT_TOL] +
			",窗口蹲姿样本 %d(**判据**),窗口峰值速度 %.0f px/s,前置姿态 %d/速度 %.0f"
			% [squat_in_window, peak, pre_pose, pre_speed])
	# 诊断行:姿态判据的**混淆项**一并打出来(那三个任何一个为真都会让 pose 卡住而与输入无关 ——
	# 倒地时整个 `_physics_process` 走 `_tick_downed` 早退、姿态根本不更新;水中/攀附时
	# `_tick_crouch_and_dash` 也早退)。第一版踩过的坑:身体掉进地图上的坑、卡在坑壁,
	# 读数全被地形污染,而当时的日志里看不到 `downed/hp/waterproof`。
	_log("相③ 断言完成:位移 %.1f px 蹲姿样本 %d 峰值 %.0f 前置姿态 %d 前置速度 %.0f(样本 %d);窗口 %.1fs %s(速度 %.0f,pose %d,downed %s,hp %.0f,wp %.0f)→ %.1fs %s(速度 %.0f,pose %d,downed %s,hp %.0f,wp %.0f);窗口内 downed 样本 %d"
			% [drift, squat_in_window, peak, pre_pose, pre_speed, _track.size(),
			float(first[0]), str((first[1] as Vector2).round()), float(first[2]), int(first[3]),
			str(bool(first[4])), float(first[5]), float(first[6]),
			float(last[0]), str((last[1] as Vector2).round()), float(last[2]), int(last[3]),
			str(bool(last[4])), float(last[5]), float(last[6]), _downed_in_window])


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)
	_log(("OK   " if ok else "FAIL ") + msg)


func _finish(why: String, stay_alive: bool = false) -> void:
	if _done:
		return
	_done = true
	if why != "":
		_check(false, why)
	var msg := "OK %s 断言全过" % who if _failures.is_empty() \
			else "FAIL " + "; ".join(_failures)
	var f := FileAccess.open("user://reconnect_probe_%s.result" % who, FileAccess.WRITE)
	if f != null:
		f.store_string(msg)
		f.close()
	_log("收工:%s" % msg)
	if stay_alive:
		# actor 保持连接待命(相④要的是"另一个 role 永久掉线",见文件头);
		# 停掉 _process 免得超时那条把自己判红
		set_process(false)
		return
	get_tree().quit(0 if _failures.is_empty() else 1)


# 自己落一份日志(子进程 stdout 父进程看不到)
func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://reconnect_probe_%s.log" % who
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, mode)
	if f != null:
		f.seek_end()
		f.store_line("%6.2fs %s" % [_t, msg])
		f.close()
