extends Node

# 断线重连探针的**客户端侧驱动/观察者**(见 reconnect_probe.gd 文件头)。
# 由 `reconnect_probe.gd --role=<who>` 实例化后**挂到 `get_tree().root`**:探针场景 → 真对局场景
# 的那次换场不会把它带走,故它能在换场**之后**读真 `pvp_game` / `royale_game` 实例的状态。
#
# 它做三件事:
#   ① 加入段(镜像 `lobby_page._claim_role_worker` 的三条 RPC):connect → claim_role /
#      player_options / report_token → 等 `match_start` → 进真对局场景;
#   ② 演出段(两种角色):
#      · **actor**(c1/r1):按住 S(蹲;★ 不是"按右" —— 第一版按了右,身体蹲走着掉进坑里,
#        姿态与位移两条读数同时被地形污染,见 `_actor_tick` 的注释)→ 闪断(调真 `_begin_reconnect()`,先塞一个**错 token**)
#        → 相②(错 token 被拒 + 被踢)→ 相①(恢复真 token 后被接受、身体没被销毁);
#      · **witness**(c2/r2):从快照里盯 role1 的身体 → 相③(掉线后**快照 `pose` 离开 SQUAT**;
#        位移只作读数,判据是姿态 —— 见 `POSE_SQUAT` 上方的注释);
#   ③ 收工:写 `user://reconnect_probe_<who>.result`(父进程只认这个 + 引擎日志)。
#
# ★ 客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 自己再落一份
#   `user://reconnect_probe_<who>.log`(阶段轨迹),失败时父进程把它摊开。
#
# ═══ 时间轴(相对**本端**看到 PLAYING 的那一刻 `_tp`)═══
#   actor:0.0 按住 S(必须先跑起来)· 1.5 塞确定性装置的包 · 1.6 闪断(错 token)
#          · 6.5 恢复真 token · 9.5 断言相①②⑤(为什么不是更早见 `T_ACTOR_END` 上方)
#   witness:2.5~5.2 观测窗口(相③)· 5.6 (c2/r2)永久掉线 · 6.2 收工
#   ★★ **两端的 `_tp` 并不对齐**(旧注释写的是"相差 ≤1 帧、窗口对齐到 ±0.02s"—— **实测证伪**,
#      2026-09-17):两端各自从"自己第一次处理到 `st==1` 那条 round_state"起算,而客户端进对局要
#      建场景(大乱斗那份带 N 个副本 + HUD,最重),主线程一停就是零点几秒 —— Godot 会丢这段
#      `_process` delta,于是**时钟与快照流一起后移**。实测到的一档(wroy 的 r2):`_tp` 之后
#      0.7s 才落第一条快照样本,而 actor 在同一段里照常 0.6s 就闪断了 —— 于是「闪断前最后一条
#      样本必须蹲着」那条前置断言**取不到样本**(pose=-1)而变红。两端实测漂移量级 ~0.7s。
#      故本文件所有"跨端"的余量都按 **±1.5s 漂移**留(见下两条),别按"对齐"读:
#   ★ 为什么闪断在 1.6(而不是 0.6):**前置断言要拿到"窗口开始之前的蹲姿样本"**,而见证者的
#     样本流可能比 actor 的闪断晚 ~0.7s 才开始 → 闪断越晚,这段观测才越不会被漂移吃掉。
#     1.6s 给了 ~1.5s 的容差(旧值 0.6 只有 0.6s,正是 2026-09-17 实跑到的那一档)。
#   ★ 为什么 6.5 恢复真 token 而窗口到 5.2:**节拍**是 2s(`RECONNECT_RETRY_MS`),闪断(1.6)
#     之后的尝试在 1.6 / 3.6 / 5.6 / 7.6 —— 恢复得比 7.6 早即可,于是接受的**最早**可能落在
#     `_tp`+7.6,而窗口在 5.2 就关了 → 相③的观测窗口里**不会有**"重连成功、身体重新跑起来"
#     污染,余量 2.4s(旧时间轴只有 0.4s,同样在漂移之下)。
#   ★ 按住 S**必须在闪断之前就跑够时间**:第一版把它写在闪断那一刻的同一帧,那一帧紧接着
#     `NetBus.stop()`,held 的包一个都没发出去 → 相③量到的"位移 0"是**空转的绿**(身体自始至终
#     没动过,冻结与不冻结都测不出来)。相③的前置断言就是为这一档设的。
#
# ═══ actor 收工后**不退出** ═══
#   相④ 要的是"某个 role 永久掉线、宽限期到点收场"。若 actor 在写完成绩后退出,它的 role 也会
#   进宽限,worker 的「进宽限」就变成 3 次、到点收场的那个 role 也换了人 —— 相④的判据(时间差)
#   立刻失去意义。故 actor 写完结果后**保持连接**待命,由裁判杀端口收尾。

const BAD_TOKEN := "00000000deadbeef"   # 长度同真 token(16 hex),但值必然不匹配
const T_DROP := 1.6        # 闪断时刻(相对本端看到 PLAYING);为什么不是 0.6 见文件头「时间轴」
# ── 闪断前的一小串输入包(**确定性装置**,只服务相③)──
# 为什么要有它(历史上):`_enter_grace` 当年**漏了清 `_host._pending_input[role]`** 那一行
# (修复 `7c95d68`;症状与根因见 reconnect_probe.gd 文件头的「相③ 的历史」)。那是个**竞态**:
# 掉线那一刻服务器队列里**可能**还压着没消费完的包(客户端 60Hz 上行、服务器每 tick 只消费一个
# → 队列长度在 0~2 之间抖动),有那条包就会在 `reset_state()` **之后**被 `apply_packet` 施加一次、
# 把 `_held` 整个写回去("掉线前按着的那几个键"被重新武装整个宽限期)。不塞这一串时它约 **50%
# 命中**(实测:同一份代码连跑两趟,卡住的是 1v1 还是大乱斗会互换),探针会飘;**塞了就必然命中**
# —— 这才是它今天仍然留在这里的理由:谁把 `_pending_input[role] = []` 那一行删掉,相③ 必红,
# 而不是"有时红、复现不了"。
# ★ 反证(证明"承重的是包里的 held,不是包本身"):把它整段换成恒中性(held=0)重跑,相③转绿。
const BURST_N := 10
const BURST_AT := 1.50     # 比闪断早 0.1s:够 RPC 落地(下一帧 flush),又不至于被服务器排空
var _burst_done := false
const T_RESTORE := 6.5     # 恢复真 token → 落在 7.6 那一拍(见文件头「时间轴」)
# ★ 为什么是 9.5 而不是"收工越早越好":`_actor_assert` 里有一条 **"重连后快照续上"**
#   (`_snap_count > _snap_at_drop + 20`),它量的是**接受之后到断言之间**收到多少条快照 ——
#   而接受最早落在 `_tp`+7.6(见上),故断言时刻直接决定了这条断言的余量:8.0 = 只留 0.4s
#   ≈ 24 条,踩在边界上(2026-09-17 实测到恰好 +20 → 红);9.5 = 1.9s ≈ 114 条,余量充足。
const T_ACTOR_END := 9.5
# 相⑤(重连后那条 match_start 的 spawn 断言,见 `_actor_assert`)要等**重发的那条 match_start
# 到手**才判得了。正常时它在 el≈7.7 就到了(闪断 1.6 被拒 → 3.6 被拒 → 5.6 被拒 → 7.6 被接受),
# 比 9.5 早;但节拍是 2s 一跳,真被抖掉一次就会落到 11.6 —— 那时断言早已跑完、结果文件
# 已经写出去了,补记的失败**进不了结果文件**。故把断言时刻推迟到"它到了"或到这个上限。
const T_ACTOR_END_MAX := 13.0
# ── 相① 的 C2 断言(2026-09-17 整支审查的 C 项)──
# ★ 为什么要量它:重连时服务器把 `_ack_seq[role]` 归 0 重协商锚点,而客户端在 `_on_resumed` 之前
#   仍用**断线前那个 seq 空间**发包(`_input_seq` 从 N 继续涨)→ 服务器下一 tick 消费到的就是那个
#   大 seq、`_ack_seq` 当场被写回 N+1;那条快照(unreliable)又恰好落在**刚重建**的 rollback 上 →
#   `_acked` 被抬到新纪元追不上的高度,`on_authoritative` 的 `ack <= _acked` 把之后所有真实 ack
#   全丢,直到客户端自己的 seq 爬过它(**断线前活了多久就哑多久**;一局中段可上万帧)。
#   症状就是 `prediction_rollback.gd` 记过的那个静默退化:不报错、**回滚恒为 0**、背包(soft state)
#   不再同步。判据取那条"**合法 ack 永不超过本端已发 seq**"(服务器只可能 ack 它消费过的包):
#   每个采样点都必须 `_acked <= _input_seq` —— 被毒死时 `_acked` 是个大数而 `_input_seq` 刚从 0 起爬。
#   ★ `_acked` 没有公开读口(`PredictionRollback` 只暴露 `rollback_count()`/`last_applied()`,而被
#     毒死时前者恒 0、后者照常单调 —— 两个都分不出这件事),故这里直读私有字段。
const C2_ANCHOR_WINDOW := 3.0   # 重连后连续采锚点的窗口(秒)
# spec §3.4 字面要求的那条(**回滚次数不持续增长**):重连完成后再采一次回滚次数,增量必须是个小常数。
# 它守的是**另一档**故障:`_on_resumed` 若不重置 `_input_seq`/rollback,环里断线前那些记录会被当成
# "未确认输入"逐帧重放 → 每帧一次回滚、计数线性涨(1.5s 里 ~90 次)。正常档位实测 0~1。
const RB_GROWTH_WINDOW := 1.5
const RB_GROWTH_TOL := 12
const W_START := 2.5
const W_END := 5.2
const T_W_DROP := 5.6
const T_W_END := 6.2
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
# ── 相⑤:两次 `match_start` 的出生点必须相同 ──
var _first_spawn := Vector2i(-1, -1)     # 首次 match_start 带的那份
var _resumed_spawn := Vector2i(-1, -1)   # 重连后 worker 重发的那份
var _resumed_spawn_seen := false
var _saw_reconnecting := false
var _drop_done := false
var _restored := false
var _pressed := false
var _own_vel := Vector2.ZERO
var _track: Array = []              # 相③:role1 的快照样本 [t, pos, speed]
# ── 相①:C2 锚点观测量(判据在 `_actor_assert`)──
var _resume_el := -1.0              # 观测到 `_on_resumed` 落地(`_reconnecting` 转假)的时刻
var _rb_at_resume := -1             # 那一刻的 rollback_count
var _rb_after := -1                 # RB_GROWTH_WINDOW 之后的 rollback_count
var _anchor_samples: Array = []     # [el, acked, input_seq]
var _snap_ack_max := 0              # 收到过的最大快照 ack_seq(诊断:毒源那个数就是它)
var _samples_open := true
var _perm_dropped := false
var _done := false


func _ready() -> void:
	var lp := "user://reconnect_probe_%s.log" % who
	if FileAccess.file_exists(lp):
		# 删不掉(多半是上一跑的同名客户端还活着、还攥着这个文件)→ 后面 `seek_end()` 会把新
		# 内容**接在陈旧内容后面**,读日志的人会照旧行归因。故失败要出声音,别静默。
		var rm := DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
		if rm != OK:
			push_warning("PROBE[%s]: 删不掉上一跑的 %s(错误 %d)—— 本文件里会有陈旧行" % [who, lp, rm])
	PvpSession.role = slot
	PvpSession.token = token
	PvpSession.worker_port = port
	PvpSession.server_address = "127.0.0.1"
	PvpSession.player_name = who.to_upper()
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)   # 相①的 ack 读数(见 `_actor_assert`)
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
		# 相⑤ 的取数点(断言在 `_actor_assert` 里 —— 这里只记,不判):
		# `_finish` 一到就把结果文件写出去了,而重发这条可能比断言时刻还晚一两个节拍,
		# 故"判"必须发生在结果文件落盘之前(见 `_actor_tick` 的等待门 / `T_ACTOR_END_MAX`)。
		_resumed_spawn_seen = true
		_resumed_spawn = spawn
		_log("收到重连后的 match_start(role=%d spawn=%s,首次 spawn=%s)—— 本观察者不换场"
				% [role, str(spawn), str(_first_spawn)])
		return
	_entered = true
	_first_spawn = spawn
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


# 本人那条快照(unreliable,带 `ack_seq` + 权威整态 `c2`)。这里只存一个诊断读数 ——
# 判据在 `_actor_assert`,它要的是"客户端**处理**到了哪个 ack",不是"收到过哪个"。
func _on_snapshot_own(own: Dictionary) -> void:
	_snap_ack_max = maxi(_snap_ack_max, int(own.get("ack_seq", 0)))


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
	# ── 相① 的 C2 观测(判据见 `_actor_assert`)──
	# ① `_reconnecting` 转假 = `_on_resumed` 落地:那一刻采一次回滚次数(新 rollback 刚建出来)
	if _saw_reconnecting and _resume_el < 0.0 and _game.get("_reconnecting") == false:
		_resume_el = el
		_rb_at_resume = _rollback_count()
	# ② 重连后按窗口连续采锚点(`_acked` vs 本端 `_input_seq`)
	if _resume_el >= 0.0 and el - _resume_el <= C2_ANCHOR_WINDOW:
		var rb: Object = _game.get("_rollback")
		if rb != null:
			_anchor_samples.append([el, int(rb.get("_acked")), int(_game.get("_input_seq"))])
	# ③ 窗口到点再采一次回滚次数(spec §3.4 那条的增量)
	if _resume_el >= 0.0 and _rb_after < 0 and el - _resume_el >= RB_GROWTH_WINDOW:
		_rb_after = _rollback_count()
		_log("相① C2 读数:重连后 %.1fs 回滚 %d → %d,锚点样本 %d 个(acked 最大 %d,本端 seq 末次 %d,收到最大快照 ack %d)"
				% [el - _resume_el, _rb_at_resume, _rb_after, _anchor_samples.size(),
				_anchor_max_acked(), _last_input_seq(), _snap_ack_max])
	# 相⑤的 spawn 断言要等重发的那条 match_start(见 T_ACTOR_END_MAX);等不到也照样断言,
	# 那一相会红并打明"没等到"(否则会以"没取到数"的形式静默变绿)。
	# ★ 另等 RB_GROWTH_WINDOW:回滚增量要观测够窗口才判得了(否则会以"没取到数"的形式误红)。
	if el >= T_ACTOR_END and (_resumed_spawn_seen or el >= T_ACTOR_END_MAX) \
			and (_resume_el < 0.0 or el - _resume_el >= RB_GROWTH_WINDOW):
		_actor_assert()


func _rollback_count() -> int:
	var rb: Object = _game.get("_rollback")
	return int(rb.call("rollback_count")) if rb != null else -1


func _anchor_max_acked() -> int:
	var m := 0
	for s in _anchor_samples:
		m = maxi(m, int(s[1]))
	return m


func _last_input_seq() -> int:
	return int(_anchor_samples[-1][2]) if not _anchor_samples.is_empty() else -1


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
	# ★★ 相① 的 C2 锚点断言(2026-09-17 整支审查的 C 项;机制与判据见 C2_ANCHOR_WINDOW 的注释)。
	#   判据:每个采样点都必须 `_acked <= _input_seq`(合法 ack 永不超过本端已发 seq)。
	var anchor_bad := 0
	var anchor_first := ""
	for s in _anchor_samples:
		if int(s[1]) > int(s[2]):
			anchor_bad += 1
			if anchor_first == "":
				anchor_first = "el=%.2f acked=%d input_seq=%d" % [float(s[0]), int(s[1]), int(s[2])]
	_check(not _anchor_samples.is_empty(),
			"相①:重连后采到 C2 锚点样本(观测到 `_on_resumed` 落地)")
	_check(anchor_bad == 0,
			("相①:重连后 C2 锚点重新咬合(`_acked ≤ 本端 _input_seq`;%d/%d 个样本越界,首个 %s)"
			+ ";收到过的最大快照 ack=%d") % [anchor_bad, _anchor_samples.size(), anchor_first,
			_snap_ack_max])
	# ★ spec §3.4 字面要求的那条:**重连后回滚次数不持续增长**(守的是"没重置 C2 → 逐帧重放旧记录"那档)。
	_check(_rb_at_resume >= 0 and _rb_after >= 0,
			"相①:重连后两次采到回滚次数(重连时 %d,%.1fs 后 %d)"
			% [_rb_at_resume, RB_GROWTH_WINDOW, _rb_after])
	if _rb_at_resume >= 0 and _rb_after >= 0:
		_check(_rb_after - _rb_at_resume <= RB_GROWTH_TOL,
				"相①:重连后回滚次数不持续增长(%.1fs 内增量 %d ≤ %d)"
				% [RB_GROWTH_WINDOW, _rb_after - _rb_at_resume, RB_GROWTH_TOL])
	# ★★ 相⑤的核心断言(1v1 与大乱斗都判,理由在大乱斗侧):**reclaim 不应重新摆位**。
	#   重连后 worker 重发的那条 `match_start` 必须带**与首次同一个** spawn。
	#   它钉的是一条**没有任何其他断言拦得住**的回归:`RoyaleHost` 覆写的 `role_spawns()` 若被
	#   删掉(退回基类实现 —— 基类走 `_spawn_cell`,而大乱斗那个第二次起返回**动态复活点**、
	#   并带 `_spawned_once` 闩锁副作用),或者 `_round_spawns` 被就地改掉,reclaim 这条路径
	#   就会把**复活点**当出生点下发,客户端据此把玩家瞬移过去 —— 而相① 的其余判据
	#   (instance_id 不变 / 快照续上 / 大乱斗的 scores 与时钟)在那条回归下**全绿**。
	#   ★ 只把 spawn 打进日志、人眼对(旧版就是这样)等于没有防卫:这类"值悄悄变了"只有
	#     断言拦得住,故它现在是真断言。
	_check(_resumed_spawn_seen,
			"相⑤:重连后收到 worker 重发的 match_start(判其 spawn 未变的前提)")
	_check(_resumed_spawn == _first_spawn,
			("相⑤:第二次 match_start 的 spawn 不得与首次不同(reclaim 不应重新摆位);"
			+ "首次 %s,重发 %s") % [str(_first_spawn), str(_resumed_spawn)])
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
	_log("相①/② 断言完成 kick=%d snap=+%d;锚点样本 %d 个(acked 最大 %d,越界 %d),回滚 %d → %d"
			% [_kick_count, _snap_count - _snap_at_drop, _anchor_samples.size(), _anchor_max_acked(),
			anchor_bad, _rb_at_resume, _rb_after])
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
	# 前置:**观测窗口开始之前**,快照里出现过蹲姿(pose=SQUAT)—— 蹲姿逐帧由"输入源此刻按着 S"
	# 推导,故它同时证明了两件事:① 输入真的被服务器吃到了;② 身体此刻在地面上(不是坠落中)。
	# ★ 判据是"**出现过**"、不是"闪断前**最后一条**样本是蹲姿"(旧写法):后者把"两端 `_tp` 对齐"
	#   当成了前提,而那个前提 2026-09-17 实测被证伪(见证者的样本流比 actor 的闪断晚 ~0.7s
	#   才开始,旧写法当场取不到样本、报 pose=-1)—— 见文件头「时间轴」那一节。
	#   语义没有松动:它要的仍然是"见证者**确实看到过** role1 被输入驱动到蹲姿",而不是"某个
	#   具体时刻的那一条样本"。取最后一条样本只作读数。
	var pre_speed := -1.0
	var pre_pose := -1
	var pre_at := -1.0
	for s in _track:
		if float(s[0]) < W_START and int(s[3]) == POSE_SQUAT:
			pre_at = float(s[0])
			pre_speed = float(s[2])
			pre_pose = int(s[3])
	_check(pre_pose == POSE_SQUAT,
			("相③前置:观测窗口(%.1fs)之前 role1 出现过蹲姿(pose=%d,期望 SQUAT=%d;"
			+ "该样本在 el=%.2fs,速度 %.0f px/s)")
			% [W_START, pre_pose, POSE_SQUAT, pre_at, pre_speed])
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
	# ⚠ 这一条**当年恒红**(`_enter_grace` 漏清 `_pending_input`,修复 `7c95d68`),本探针正是
	#   抓出它的那条;现在与"删掉那一行就必红"的确定性装置(story 见 reconnect_probe.gd 文件头的
	#   「相③ 的历史」与上面的 BURST_N 注释)一起当回归防卫。
	_check(squat_in_window == 0,
			("相③:掉线后该 role 的输入**没有**被清空(窗口内蹲姿样本 %d 个,期望 0)—— "
			+ "`_enter_grace` 的 `reset_state()` 被一条已排队的输入包撤销,见探针文件头「相③ 的历史」")
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
