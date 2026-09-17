extends Node

# 断线重连(rc1 Task 8)的**真链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_probe.tscn
# 判据:文本 `RECONNECT PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ═══ 六相(每相的存在理由见 .superpowers/sdd/rc1-task-8-brief.md)═══
#   ① 正向:客户端 A 闪断 → 自动重连被接受,且**身体没被销毁**(instance_id 不变)
#   ② 反向:错 token 的 reclaim 被拒(worker 打「拒绝 reclaim …令牌不匹配」+ 踢连接)
#   ③ 身体冻结:掉线后该 role 的玩家 global_position 不变(钉 `_enter_grace` 里的 reset_state)
#   ④ 超时移出:掉线不回来 → GraceWindow.DEFAULT_SECONDS 之后 worker 收场退出
#   ⑤ 大乱斗相:①②③ 在 `--royale` worker 上再跑一遍,**并核验"reclaim 不重新摆位"** ——
#      重连后重发的那条 `match_start` 必须带与首次**同一个** spawn(钉 `RoyaleHost.role_spawns()`
#      覆写没有 `_spawned_once` 副作用;取数点与理由见 `reconnect_watcher._actor_assert`)
#   ⑥ 启动等待态:空载 `--royale` worker 不得在 1~3s 窗口内退出
#
# ═══ 拓扑(自当裁判;全部子进程由本进程 `OS.create_process` 直接拉起)═══
#   w1v1  29001  真 `server_main.gd --worker --port 29001`              → c1(role1) + c2(role2)
#   wroy  29002  真 `--worker --royale --port 29002 --roles 1,2`        → r1 + r2
#   widle 29090  真 `--worker --royale`(一个玩家都不连)               → 相⑥
#   ★ 这三个端口**必须落在真大厅的 worker 端口池之外**,理由见下方常量区的长注释。
#
# ═══ 跑之前的前提 ═══
#   **请确认没有真大厅在跑**(本机若有 `Cyancular Ruins Server.exe` 占着 7777,先看它是不是
#   你要留着的那一个 —— **不要杀它**)。本探针**不占 7777**(它不自当大厅,worker 由本进程
#   直接拉起),但它的收尾会**按 UDP 端口杀进程**(`ProcUtil.kill_udp_port`,见 `_kill_children`),
#   所以"探针用的端口与别人重不重合"是真问题 —— 那正是端口挪到池外要解决的事(常量区那段注释)。
#   ★ **为什么 worker 由本进程直接拉起,而不是走大厅**(royale_c2_probe 走 RoomManager):
#     本探针的判据有一半落在 **worker 自己的日志**上(「拒绝 reclaim」/「进宽限」/「宽限期到」),
#     而 Windows 下 `OS.create_process` 的子进程 stdout **不被父进程继承**(仓内既有结论,
#     royale_soak_probe 的注释也记了同一件事)—— 由大厅拉起的 worker,其日志是盲区,只有
#     `--log-file` 能救,而 argv 只有本进程能改。argv 形状与 WorkerLauncher 的逐字同款,
#     差别只有多一个 `--log-file`。
#     **断线重连这条链路不经过大厅**(token 由大厅发,但重连本身只走 worker),故大厅不入环
#     不影响覆盖;token 仍由真 `LobbyRooms.new_token()` 生成、经真 RPC(`report_token`)上报。
#   ★ 客户端的**加入段**(claim/player_options/report_token)是探针镜像 `lobby_page._claim_role_worker`
#     的三条 RPC —— 与 royale_probe 的「轻量客户端」同一手法;**进入对局后的每一帧都是真场景**
#     (`pvp_game.tscn` / `royale_game.tscn`),重连段(断开→重连→reclaim→match_start→_on_resumed)
#     走的是 100% 生产代码。
#
# ═══ 触发方式(闪断怎么造)═══
#   brief 写的是「客户端 A 主动 `NetBus.stop()`」—— **那条路触发不了重连**:`NetBus.stop()` 把
#   `multiplayer_peer` 置空,引擎在 `set_multiplayer_peer` 里先 `clear()`、状态当场复位成
#   DISCONNECTED,CONNECTED→DISCONNECTED 那一跃从未被观测到 → `server_disconnected` 不发
#   (Task 6 审查实测 + 读引擎源码,已写进 `pvp_match_client._begin_reconnect` 的注释)。
#   本探针改用**直接调 `_game._begin_reconnect()`**(brief 明确允许的第二种):
#   它与生产路径上 `_on_server_message` 收到「服务器断开」后调的是**同一个函数**,
#   其内部 `NetBus.stop()` → `start_client` 是**真 ENet 断开 + 真重连**,worker 侧看到的
#   `peer_left` 与真闪断完全一致。另一半用的是**真** `server_disconnected`:
#   错 token 被 worker `disconnect_peer` 踢掉那一次,客户端是真收到 `服务器断开` 的。
#
# ═══ ★★ 已知红:相③ 在**当前生产代码**上恒红(本探针存在的意义就是这个)═══
# 症状:掉线后该 role 的身体**保持掉线前按着的键**整个宽限期(实测:掉线前蹲着 → 窗口内
#       162/162 个快照样本的 `pose` 仍是 SQUAT;掉线前蹲走着 → 掉线后还能再走 230px)。
# 根因(读码 + 逐项排除 + 反证,**不是**地形/倒地/水中/攀附):
#   `server_main._enter_grace()` 调 `src.reset_state()` 把 `_held` 清零,但**不清
#   `_host._pending_input[role]`**;而 `MatchHost._physics_process` 每 tick 从队列里取一包
#   `apply_packet()`,它是**整体覆盖** `_held`(`packet_input_source.gd:102-110`)→ 那条在
#   掉线瞬间**已经排在队列里**的包,会在复位**之后**把 `_held` 整个写回。之后队列空了、
#   `clear_edges()` 又**不清 `_held`**(`:113-116`)→ 于是"掉线前按着的那几个键"被**重新武装
#   并保持到宽限期结束**(乃至宽限期到点、`mark_disconnected` 之前)。
#   · 对比:`_on_reclaim()` 的接受路径**有**清队列(`server_main.gd:309` `_pending_input[role] = []`)
#     —— 只差这一处,`_enter_grace` 漏了同一句。
# 排除法(都用快照字段,见 reconnect_watcher 的相③诊断行):
#   `downed=false`(倒地时 `_physics_process` 走 `_tick_downed` 早退、姿态不更新)、`hp=50`(满血)、
#   `waterproof=10`(满氧,不在水里)、身体所在格的**中心与脚底**都不是通道格(梯/锁链,读地图确认)
#   → `is_squat` 只可能来自 `input_source.is_action_pressed("down")` → 输入源里确实还按着 S。
# 反证(证明它是**竞态**而不是"某条链路坏了"):去掉确定性装置连跑两趟,卡住的是 1v1 还是大乱斗
#   **会互换** —— 取决于掉线那一刻服务器的输入队列是不是恰好空(客户端 60Hz 上行 vs 服务器
#   每 tick 只消费一包 → 队列长度在 0~2 抖动)。
# 建议改法(**未改**:硬约束"不要为了让探针过而改任何生产代码"):在 `_enter_grace` 里把队列也清掉
#   (与 `_on_reclaim` 同款),例如 `src.reset_state()` 之前加
#   `if _host._pending_input.has(role): _host._pending_input[role] = []`。
#   改完之后相③应当转绿 —— 那也正是这条断言存在的价值。
# ═══ 时间预算(为什么必须并行)═══
#   `--quit-after 3600` 在 `max_fps=60` 下 = **60s 墙钟**,而相④要等满一个 30s 宽限期 ——
#   故三组 worker/客户端**全部并行**跑,且每个子进程自带 `--quit-after`(150s)兜底。

const PREFIX := "reconnect_probe_"
# ═══ ★★ 三个 worker 端口必须落在**大厅的 worker 端口池之外** ═══
# 池的定义在 `server/worker_launcher.gd`:`WORKER_PORT_BASE = 7800`、`WORKER_PORT_SPAN = 500`
# → 池 = **7800~8299**。本探针原先写的是 7901/7902/7990,**三个数都在池里**,而本机上常驻
# 一个真大厅(`Cyancular Ruins Server.exe`,占 7777)—— 只要那一刻有人建房,大厅就会把**同一个
# 端口**发给那局的真 worker,后果有两层,都不是"红一条断言"这个量级:
#   ① 真 worker bind 失败当场退出 —— 别人的对局被本探针搅掉;
#   ② 本探针收尾的 `ProcUtil.kill_udp_port(W1V1/WROY/WIDLE)` 是"按 UDP 端口找属主并强杀",
#      **不看那是谁的进程** → 会把那个真 worker 一起杀掉。
# 故一律取池外(29xxx,同时远离常见服务端口)。★ 改这三个数之前先读这段;改完顺手核对
# `worker_launcher.gd` 的池上界没被调大。
const W1V1 := 29001       # 1v1 worker 端口(池外)
const WROY := 29002       # 大乱斗 worker 端口(池外)
const WIDLE := 29090      # 空载大乱斗 worker 端口(池外)
const CHILD_QUIT_AFTER := "9000"   # 子进程兜底(150s):正常由探针自己收尾/杀端口
const BOOT_TIMEOUT := 30.0         # 等 worker/客户端就绪的上限
const FINAL_TIMEOUT := 58.0        # 本进程的收工上限(必须留在 --quit-after 3600 的 60s 之内)
# 相⑥的窗口:worker 打完「就绪」后的 [1,3] 秒内不得退出、不得打「全员离开,大乱斗结束」
const IDLE_LOW := 1.0
const IDLE_HIGH := 3.0
const IDLE_BONUS := 14.0           # 之后按既有 M1 守卫正当退出(10s);这一相**必须有它**
const GRACE_MIN := 29.0            # 相④的时间判据(宽限期 30s ± 上面两种粒度)
const GRACE_MAX := 36.0

var _role := "lobby"
# ── 裁判态 ──
var _t := 0.0
var _stage := 0
var _exe := ""
var _res := ""
var _failures: Array[String] = []
var _notes: Array[String] = []
var _w1v1_pid := 0
var _wroy_pid := 0
var _widle_pid := 0
# 本进程拉起过的**全部**子进程的 PID(worker + 4 个客户端)。收尾按它杀 —— 只按端口杀会漏掉
# 客户端(它们是从**临时端口**连出去的),见 `_kill_children`。
var _child_pids: Array[int] = []
var _idle_ready_t := -1.0
var _idle_alive_ok := false
var _idle_bonus_ok := false
var _grace_stamps: Array[float] = []   # 1v1 worker 每次「进宽限」被首次看到的时刻
var _expiry_t := -1.0
var _expiry_seen := false
var _done := false


func _ready() -> void:
	# 角色:无参 = 裁判;子进程由本进程用 `--who=<c1|c2|r1|r2>` 拉起(`--role=` 一并认,
	# 方便人工前台单起某一个客户端)。★ 两处**必须都认**:漏认 `--who=` 会让子进程回落成
	# "裁判"→ 它自己也去拉起 worker 与客户端(端口冲突 + 递归),而表现只是几条
	# "Couldn't create an ENet host" —— 第一版实测踩到。
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--who="):
			_role = a.trim_prefix("--who=")
	if _role != "lobby":
		_run_client()
		return
	_run_orchestrator()


# ════════════════════ 裁判 ════════════════════

func _run_orchestrator() -> void:
	_exe = OS.get_executable_path()
	_res = ProjectSettings.globalize_path("res://")
	_clean()
	print("PROBE: 裁判就绪(exe=%s);拉起 1v1 worker(%d)与空载大乱斗 worker(%d)" % [
			_exe.get_file(), W1V1, WIDLE])
	_w1v1_pid = _spawn_worker(["--worker", "--port", str(W1V1)], "w1v1")
	_widle_pid = _spawn_worker(["--worker", "--royale", "--port", str(WIDLE),
			"--roles", "1,2", "--ai-roles", "2"], "widle")


func _process(delta: float) -> void:
	if _role != "lobby" or _done:
		return
	_t += delta
	if _t > FINAL_TIMEOUT:
		_finish("超时(%.0fs;阶段 %d)\n%s" % [FINAL_TIMEOUT, _stage, _dump()])
		return
	_idle_tick()
	match _stage:
		0:
			_stage_boot()
		1:
			_stage_clients_playing()
		2:
			_stage_collect()


# 相⑥:空载大乱斗 worker 的启动等待态。**必须让真帧跑过开机态** —— Task 4 的 Critical 正是
# "开机约 1s 自杀",而当时那个临时探针只调 `_on_peer_left`/`_expire_graces` 断言其返回状态、
# 没让 `_process` 跑过,18 条断言全绿仍漏掉它。
func _idle_tick() -> void:
	if _idle_ready_t < 0.0:
		if _has(_log_path("widle"), "大乱斗 worker 就绪"):
			_idle_ready_t = _t
			print("PROBE: 空载大乱斗 worker 已就绪(t=%.1fs),开始相⑥窗口" % _t)
		return
	var age := _t - _idle_ready_t
	if age >= IDLE_LOW and age <= IDLE_HIGH:
		if OS.is_process_running(_widle_pid):
			_idle_alive_ok = true
	if age >= IDLE_HIGH and not _idle_checked_flag:
		# ① 1~3s 窗口内进程活着(**至少看到一次**,窗口内每帧都看)
		_check(_idle_alive_ok, "相⑥:空载 worker 在就绪后 1~3s 窗口内仍活着")
		# ② 整个观测期都不得打「全员离开,大乱斗结束」(那正是 Task 4 的自杀路径)
		_check(not _has(_log_path("widle"), "全员离开,大乱斗结束"),
				"相⑥:空载 worker 未打「全员离开,大乱斗结束」")
		_idle_checked_flag = true
	if age >= IDLE_BONUS and not _idle_bonus_ok:
		# ★ 反向断言:这条**不能省** —— 没有它,"1~3s 内没退出"可以靠"永不退出"作弊通过。
		#   空载 worker 按既有的 M1 守卫(`可用玩家 <2 人` 持续 10s)正当地退出并释放端口。
		_idle_bonus_ok = true
		var exited := not OS.is_process_running(_widle_pid)
		_check(exited, "相⑥:空载 worker 之后按 M1 守卫正当退出(证明上一相不是空转)")
		_check(_has(_log_path("widle"), "超时退出释放端口"),
				"相⑥:退出理由是 M1 守卫(「可用玩家 …超时退出释放端口」)")
		print("PROBE: 相⑥完成(窗口内存活=%s,之后正当退出=%s)" % [str(_idle_alive_ok), str(exited)])


var _idle_checked_flag := false


func _idle_checked() -> bool:
	return _idle_checked_flag


# 相 0:等两个 worker 报「就绪」→ 拉起 1v1 的两个客户端
func _stage_boot() -> void:
	if _t > BOOT_TIMEOUT:
		_finish("worker 未在 %.0fs 内就绪(1v1 日志=%s)" % [BOOT_TIMEOUT, _tail(_log_path("w1v1"))])
		return
	if not _has(_log_path("w1v1"), "worker 就绪"):
		return
	print("PROBE: 1v1 worker 就绪(t=%.1fs),拉起 c1/c2" % _t)
	var t1 := LobbyRooms.new_token()
	var t2 := LobbyRooms.new_token()
	_spawn_client("c1", W1V1, t1, 1, "pvp")
	_spawn_client("c2", W1V1, t2, 2, "pvp")
	_stage = 1


# 相 1:等 1v1 两个客户端进对局并到 PLAYING → 这时才拉起大乱斗那一组(把启动 CPU 尖峰错开)
func _stage_clients_playing() -> void:
	if not _has(_log_path("c1"), "PLAYING"):
		if _t > BOOT_TIMEOUT:
			_finish("c1 未在 %.0fs 内进对局并到 PLAYING\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	print("PROBE: c1 已进对局且到 PLAYING(t=%.1fs),拉起大乱斗 worker(%d)" % [_t, WROY])
	_wroy_pid = _spawn_worker(["--worker", "--royale", "--port", str(WROY), "--roles", "1,2"], "wroy")
	_stage = 2


# 相 2:收 4 份客户端结果 + 相④(1v1 宽限期到点)+ 相⑥ 的收尾
func _stage_collect() -> void:
	# 大乱斗 worker 就绪后拉起 r1/r2
	if _r1_launched == false and _has(_log_path("wroy"), "大乱斗 worker 就绪"):
		_r1_launched = true
		print("PROBE: 大乱斗 worker 就绪(t=%.1fs),拉起 r1/r2" % _t)
		var t1 := LobbyRooms.new_token()
		var t2 := LobbyRooms.new_token()
		_spawn_client("r1", WROY, t1, 1, "royale")
		_spawn_client("r2", WROY, t2, 2, "royale")
	_track_grace()
	if _all_results() and not _evidence_checked:
		_evidence_checked = true
		_worker_evidence()
	if not _done and _all_results() and _expiry_seen and _idle_checked_flag \
			and (not _r1_launched or _t > _idle_ready_t + IDLE_BONUS):
		_finish("")


var _r1_launched := false
var _evidence_checked := false


# worker 侧证据:相②(拒绝)与相①(接受)的**另一半**在 worker 自己的日志里。
# ★ 这一节正是 brief 点名的那条:「worker 日志里要盯『拒绝 reclaim』(Task 5 审查预警的 M35:
#   客户端按『连接』记账、worker 按『role 是否还在宽限期』判,非对称断线那一档会被拒+踢)——
#   探针应以断言的形式盯住它,而不是只人工看日志」。
#   判据落在 worker 日志上而不是只说"客户端被踢了":被踢也可能是别的原因(比如判据②),而
#   **只有 worker 自己打出来的理由**能区分"令牌不匹配"与"该 role 不在宽限期"。
func _worker_evidence() -> void:
	for tag in ["w1v1", "wroy"]:
		var txt := _read(_log_path(tag))
		_check(txt.contains("拒绝 reclaim") and txt.contains("令牌不匹配"),
				"相②(%s):worker 打了「拒绝 reclaim …令牌不匹配」" % tag)
		_check(txt.count("重连成功") == 1,
				"相①(%s):worker 恰好接受了一次 reclaim(实得 %d 次)" % [tag, txt.count("重连成功")])
		_check(txt.contains("玩家掉线进宽限"),
				"相③(%s):worker 走了宽限期(身体留在场上,不是当场移出)" % tag)
		_check(txt.count("对局开始") == 1, "相①(%s):对局只开了一次(重连没有重开一局)" % tag)


# 相④:1v1 worker 的宽限期到点收场。
# ★ 判据是**时间差**不只是"打了那行字":宽限期 30s 是 spec 的硬承诺,只断言"最终会退出"
#   会把"10s 就判超时"这种坏实现放过去。`_expire_graces` 每秒轮询一次 → 实测落在 [30,31]s,
#   本进程的采样粒度再加 ~0.3s。起点取**第二次**「进宽限」(第一次是 c1 的闪断、被 reclaim 救回;
#   第二次是 c2 的永久掉线 —— 它就是该到点的那一个),两行都在 worker 日志里带序号校验。
func _track_grace() -> void:
	var txt := _read(_log_path("w1v1"))
	if txt == "":
		return
	var n := txt.count("玩家掉线进宽限(1v1)")
	while _grace_stamps.size() < n:
		_grace_stamps.append(_t)
		print("PROBE: 1v1 worker 第 %d 次「进宽限」(t=%.1fs)" % [_grace_stamps.size(), _t])
	if not _expiry_seen and txt.contains("1v1 宽限期到,对手未归,对局结束"):
		_expiry_seen = true
		_expiry_t = _t
		_check(_grace_stamps.size() == 2,
				"相④:1v1 worker 恰好两次「进宽限」(c1 闪断 + c2 永久掉线),实得 %d" % _grace_stamps.size())
		if _grace_stamps.size() >= 1:
			var since := _t - _grace_stamps[_grace_stamps.size() - 1]
			_check(since >= GRACE_MIN and since <= GRACE_MAX,
					"相④:宽限期到点耗时 %.1fs ∈ [%.0f, %.0f](GraceWindow.DEFAULT_SECONDS=30)"
					% [since, GRACE_MIN, GRACE_MAX])
		print("PROBE: 相④ 1v1 worker 收场退出(t=%.1fs)" % _t)


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	# 收四个客户端的结果文件(它们是自己写的;子进程 stdout 父进程看不到)
	for w in ["c1", "c2", "r1", "r2"]:
		var r := _read_result(w)
		if r == "":
			_check(false, "%s 未写结果文件" % w)
		elif r.begins_with("OK"):
			_notes.append("%s: %s" % [w, r])
		else:
			_check(false, "%s: %s" % [w, r])
	_kill_children()
	if why != "":
		_check(false, why)
	print("═══ 探针明细 ═══")
	for n in _notes:
		print("  · " + n)
	for f in _failures:
		print("  ✗ " + f)
	if _failures.is_empty():
		print("RECONNECT PROBE: ALL-OK")
	else:
		print("RECONNECT PROBE: %d 条失败" % _failures.size())
		print(_dump())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("  OK  %s" % msg)
	else:
		_failures.append(msg)
		print("  FAIL %s" % msg)


func _all_results() -> bool:
	for w in ["c1", "c2", "r1", "r2"]:
		if _read_result(w) == "":
			return false
	return true


# ── 子进程 ──

func _spawn_worker(worker_args: Array, tag: String) -> int:
	var argv := PackedStringArray(["--headless", "--path", _res, "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _log_path(tag), "res://server/server_main.tscn", "--"])
	for a in worker_args:
		argv.append(str(a))
	print("PROBE: spawn worker %s argv=%s" % [tag, str(argv)])
	return _record_pid(OS.create_process(_exe, argv))


func _spawn_client(who: String, port: int, token: String, slot: int, scene: String) -> int:
	var argv := PackedStringArray(["--headless", "--path", _res, "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who), "res://tests/reconnect_probe.tscn", "--",
			"--who=" + who, "--port=" + str(port), "--token=" + token, "--slot=" + str(slot),
			"--scene=" + scene])
	print("PROBE: spawn 客户端 %s(port=%d slot=%d scene=%s)" % [who, port, slot, scene])
	return _record_pid(OS.create_process(_exe, argv))


func _record_pid(pid: int) -> int:
	if pid > 0:
		_child_pids.append(pid)
	return pid


# 收尾:两条路一起走,缺一不可。
#   ① **按 PID 杀全部子进程**(本仓既有先例:`tests/*.sh` 用 `taskkill /PID`;GDScript 侧是
#      `OS.kill`)。为什么非有这一条:四个**客户端**是从临时端口连出去的,不占 W1V1/WROY/WIDLE
#      任何一个,**只按端口杀根本杀不到它们** —— 于是上一跑的 c1/r1 会留下来,后果实测过两条:
#        · 持续敲下一次运行的 W1V1/WROY(上一次审查观察到 3 条「该 role 不在宽限期」);
#        · 一直攥着自己的 `user://reconnect_probe_<who>.log` → 下一跑 `_clean()` 的删除**失败**
#          (旧代码忽略返回值,静默),新进程随即截断该文件、残留进程按旧偏移续写 → 文件里出现
#          空洞与陈旧行(所以 `_clean()` 现在会报出来)。
#   ② **仍保留按 UDP 端口杀 worker**:它兜住"PID 记录漏了"这一档(worker 是真 ENet 绑定端口的
#      那一侧),成本是两条 PowerShell,且与本仓 `tests/*.sh` 的 `taskkill + kill_port` 双保险同款。
func _kill_children() -> void:
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	for p in [W1V1, WROY, WIDLE]:
		ProcUtil.kill_udp_port(p)


# ── 文件 ──

func _log_path(tag: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s.godotlog" % [PREFIX, tag])


func _godot_log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s.godotlog" % [PREFIX, who])


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _has(path: String, needle: String) -> bool:
	return _read(path).contains(needle)


func _read_result(who: String) -> String:
	return _read(ProjectSettings.globalize_path("user://%s%s.result" % [PREFIX, who])).strip_edges()


func _tail(path: String) -> String:
	var lines := _read(path).split("\n")
	if lines.size() <= 20:
		return "\n".join(lines)
	return "…(前 %d 行省略)\n" % (lines.size() - 20) + "\n".join(lines.slice(lines.size() - 20))


# 开工前清掉上一跑的产物。★ 删除**必须看返回值**:上一跑的客户端若还活着(它攥着自己的
# `.log`),删除会失败,而失败被忽略的后果不是"少删一个文件" —— 本跑的新进程会截断同一个文件、
# 残留进程按它自己的旧偏移继续写 → 日志里出现空洞与陈旧行,人会照着这些行做出错误归因。
func _clean() -> void:
	for tag in ["c1", "c2", "r1", "r2", "w1v1", "wroy", "widle"]:
		for suffix in ["result", "godotlog"]:
			var p := "user://%s%s.%s" % [PREFIX, tag, suffix]
			if not FileAccess.file_exists(p):
				continue
			var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
			if err != OK:
				push_warning("PROBE: 删不掉上一跑的 %s(错误 %d)—— 多半是上一跑的进程还活着;"
						% [p, err] + "本跑该文件的日志会与残留内容混在一起,别照它归因")


# 超时/失败时把子进程的日志摊开(否则子进程里发生了什么完全看不见)
func _dump() -> String:
	var out := ""
	for tag in ["c1", "c2", "r1", "r2", "w1v1", "wroy", "widle"]:
		out += "  [%s 引擎日志]\n%s\n" % [tag, _tail(_log_path(tag))]
	return out


# ════════════════════ 客户端子进程 ════════════════════
# 观察者挂 `root`(不是本场景):换场(探针场景 → 真对局场景)不会把它带走。
func _run_client() -> void:
	var w: Node = load("res://tests/reconnect_watcher.gd").new()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--who="):
			w.who = a.trim_prefix("--who=")
		elif a.begins_with("--port="):
			w.port = int(a.trim_prefix("--port="))
		elif a.begins_with("--token="):
			w.token = a.trim_prefix("--token=")
		elif a.begins_with("--slot="):
			w.slot = int(a.trim_prefix("--slot="))
		elif a.begins_with("--scene="):
			w.is_royale = a.trim_prefix("--scene=") == "royale"
			w.scene_path = "res://scenes/royale_game.tscn" if w.is_royale \
					else "res://scenes/pvp_game.tscn"
	# 谁是闪断者、谁是见证者、谁在最后**永久**掉线(相④):按 role 名定,写死不猜
	w.is_actor = w.who == "c1" or w.who == "r1"
	w.drop_permanently = w.who == "c2"
	print("PROBE[%s]: 观察者就绪(port=%d slot=%d scene=%s)" % [w.who, w.port, w.slot, w.scene_path])
	get_tree().root.add_child.call_deferred(w)
