extends Node

# 断线重连(rc1 Task 8)的**真链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn
#   ★ 用 **14400**(=240s 安全网)而不是别处的 3600:本探针要跑满一个 60s 宽限期,整跑 ~72s 墙钟,
#     3600(=60s)连整跑都盖不住,机器一忙就会先耗尽安全网(表现是"一行 ALL-OK 都没有",看着像坏了)。
#   ★ `--quit-after` 的单位是**帧**,本工程 `run/max_fps=60`(project.godot)⇒ 1 帧 = 1/60s
#     (实测 600 帧 = 10.0s + ~1.2s 启动开销)。下面每个预算都是按这个换算写的。
# 判据:文本 `RECONNECT PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ═══ 六相(每相的存在理由见 .superpowers/sdd/rc1-task-8-brief.md)═══
#   ① 正向:客户端 A 闪断 → 自动重连被接受,且**身体没被销毁**(instance_id 不变);同相另判两条
#      **C2 断言**:**重连后 ack 锚点必须重新咬合**(`_acked ≤ 本端 _input_seq`)与**回滚次数不持续增长**
#      (后者是 spec §3.4 的明文要求) —— 取数点与理由见 `reconnect_watcher._actor_assert`
#   ② 反向:错 token 的 reclaim 被拒(服务端日志打「拒绝 reclaim …令牌不匹配」+ 踢连接)
#   ③ 身体冻结:掉线后该 role 的**快照 `pose` 离开 SQUAT**(★ 判据是**姿态**,不是位移 ——
#      撞墙/卡坑时位移天然为 0、能空转骗过;位移仍打出来,只作读数。钉 `_enter_grace` 里那两件事)
#   ④ 超时移出:掉线不回来 → GraceWindow.DEFAULT_SECONDS 之后服务端收场。
#      ★ 单进程之后"收场"= **结束这一局**(那条日志是「1v1 宽限期到,对手未归,对局结束」),
#      **不再是"worker 进程退出"** —— 进程还要继续当大厅,判据因此改成"日志出现那一行"
#      (旧形态里它与"进程还在不在"是同一件事,现在不是)。
#   ⑤ 大乱斗相:①②③ 在大乱斗那一支的服务端上再跑一遍,**并核验"reclaim 不重新摆位"** ——
#      重连后重发的那条 `match_start` 必须带与首次**同一个** spawn(钉 `RoyaleHost.role_spawns()`
#      覆写没有 `_spawned_once` 副作用;取数点与理由见 `reconnect_watcher._actor_assert`)
#   ⑥ 启动等待态(单进程形态下**重写过**,见 `_idle_tick`):**空载服务端**(一个玩家都不连)
#      ①不得自杀/退出、②必须一直占着自己那个端口(仍在监听)。旧形态这一相判的是"空载
#      `--royale` worker 就绪后 1~3s 内不退出 + 之后按 M1 守卫正当退出";那道 M1 守卫
#      (`可用玩家 <2 持续 10s`)**只活在开了局的会话里**(`MatchSession._process`),
#      一个没人来的服务端**根本没有会话** ⇒ "之后正当退出"那一半在新形态下**不存在**,
#      照旧写就是永远为真的空壳。现在锁的是"没人来 ≠ 自杀",反向断言改成"端口仍被它持有"。
#   ⑦ 世界补态(仅 1v1):actor 掉线的窗口里**服务器侧**世界变过两处 —— 拆掉一格可破坏的墙
#      (`--test-destroy-tile`,见下方 P7_DESTROY_AFTER)与 witness 捡走一把地面武器
#      (`--test-ground-teleport` + witness 按 F)—— 重连后 `match_sync` 补态必须把两处都补上:
#      不补就是**幻影墙**(撞上去 → 本地预测与服务端分歧 → 可能回滚循环)与**幽灵枪**。
#      断言在 `reconnect_watcher._p7_assert`(actor 侧)+ 本文件 `_server_evidence`(服务端日志)。
#
# ═══ 拓扑(自当裁判;**没有 worker**)═══
#   单进程单端口之后,服务端 = 大厅 + 对局**同一个进程**。本探针因此拉起**三个普通服务端**
#   (`res://server/server_main.tscn -- --port P`,与生产手跑逐字同一条命令),客户端连上去
#   **走真大厅流程**建房/加入,再由 `RoomManager` 在**服务端进程内**开局:
#   s1v1  29001  `--port 29001 --test-ground-teleport --test-destroy-tile 136,64,7.5`
#                → c1(role1,建房)+ c2(role2,加入)→ 相①~④⑦
#   sroy  29002  `--port 29002`  → r1(role1,建大乱斗房)+ r2(role2,加入)+ r1 发 royale_start
#                → 相⑤(大乱斗那一支)
#   sidle 29090  `--port 29090`(一个玩家都不连)                        → 相⑥
#   ★ 三个端口都是**本探针自己挑的**(29xxx),与 7777 毫不相干 —— 单进程之后**没有端口池**
#     了(旧形态的池 7800~8299 随 `WorkerLauncher` 一起删除),所以"别撞池"这条护栏退役,
#     留下的是它真正要保的那件事:**不许碰用户自己的服务端(7777)**。
#
# ═══ 跑之前的前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本机若有 `Cyancular Ruins Server.exe`,那是用户自己
#   的服务端 —— **不要杀它**)。本探针**不占 7777**:三个服务端都在 29xxx,收尾**按 PID 杀**
#   本进程拉起过的全部子进程,另按**自己那三个端口**兜底一刀(见 `_kill_children`)。
#   ★ **为什么服务端由本进程直接拉起,而不是让客户端自己去起**(生产里那一步是
#     `LocalServer.launch_and_connect`):本探针的判据有一半落在 **服务端自己的日志**上
#     (「拒绝 reclaim」/「进宽限」/「宽限期到」/「全员离开」),而 Windows 下
#     `OS.create_process` 的子进程 stdout **不被父进程继承**(仓内既有结论,royale_soak_probe
#     的注释也记了同一件事)—— 由客户端拉起的服务端,其日志是盲区,只有 `--log-file` 能救,
#     而 argv 只有本进程(裁判)能改。故**服务端进程**由裁判拉起;
#     ★ 客户端的**进场走真大厅流程**(与生产逐字同路):建房/加入 → `go_match` → claim;
#     与旧形态的差别是**没有"转连 worker"那一步** —— 连接全程不动,`go_match` 只是
#     "进对局场景"(见 `lobby_page._do_go_match`)。token 由服务端 `LobbyRooms.new_token()`
#     生成、经真 RPC(`session_token` / `report_token`)下发与上报,探针**不再自己造 token**。
#   ★ 客户端的**加入段**镜像 `lobby_page._claim_role` 的三条 RPC(claim/player_options/report_token)
#     —— 与 royale_probe 的「轻量客户端」同一手法;**进入对局后的每一帧都是真场景**
#     (`pvp_game.tscn` / `royale_game.tscn`),重连段(断开→重连→reclaim→match_start→_on_resumed)
#     走的是 100% 生产代码。
#
# ═══ 触发方式(闪断怎么造)═══
#   brief 写的是「客户端 A 主动 `NetBus.stop()`」—— **那条路触发不了重连**:`NetBus.stop()` 把
#   `multiplayer_peer` 置空,引擎在 `set_multiplayer_peer` 里先 `clear()`、状态当场复位成
#   DISCONNECTED,CONNECTED→DISCONNECTED 那一跃从未被观测到 → `server_disconnected` 不发
#   (Task 6 审查实测 + 读引擎源码,已写进 `pvp_match_client._begin_reconnect` 的注释)。
#   本探针改用**直接调 `_game._begin_reconnect()`**(brief 明确允许的第二种):
#   它与生产路径上 `_on_server_message` 收到「连接断开」后调的是**同一个函数**,
#   其内部 `NetBus.stop()` → `start_client` 是**真 ENet 断开 + 真重连**,服务端侧看到的
#   `peer_left` 与真闪断完全一致。另一半用的是**真** `server_disconnected`:
#   错 token 被 `MatchSession._on_reclaim` 的 `disconnect_peer` 踢掉那一次,客户端是真收到
#   「连接断开」的(`NetBus` 把 `server_disconnected` 转成那条 `server_message`)。
#
# ═══ 相③ 的历史:它**当年恒红**(本探针抓出的第一个 bug,修复在 `7c95d68`)═══
# 症状(修复**前**):掉线后该 role 的身体**保持掉线前按着的键**整个宽限期(当年实测:掉线前蹲着 →
#       窗口内 162/162 个快照样本的 `pose` 仍是 SQUAT;掉线前蹲走着 → 掉线后还能再走 230px)。
# 根因(读码 + 逐项排除 + 反证,**不是**地形/倒地/水中/攀附):
#   `server_main._enter_grace()` 只调了 `src.reset_state()` 把 `_held` 清零,当时**没有**清
#   `_host._pending_input[role]`;而 `MatchHost._physics_process` 每 tick 从队列里取一包
#   `apply_packet()`,它是**整体覆盖** `_held`(`packet_input_source.gd:102-110`)→ 那条在
#   掉线瞬间**已经排在队列里**的包,会在复位**之后**把 `_held` 整个写回。之后队列空了、
#   `clear_edges()` 又**不清 `_held`**(`:113-116`)→ 于是"掉线前按着的那几个键"被**重新武装
#   并保持到宽限期结束**(乃至宽限期到点、`mark_disconnected` 之前)。
#   · 对比:`_on_reclaim()` 的接受路径**一直有**清队列(`server_main.gd:316`)—— 当年只差那一处。
# 排除法(都用快照字段,见 reconnect_watcher 的相③诊断行):
#   `downed=false`(倒地时 `_physics_process` 走 `_tick_downed` 早退、姿态不更新)、`hp=50`(满血)、
#   `waterproof=10`(满氧,不在水里)、身体所在格的**中心与脚底**都不是通道格(梯/锁链,读地图确认)
#   → `is_squat` 只可能来自 `input_source.is_action_pressed("down")` → 输入源里确实还按着 S。
# 反证(证明它是**竞态**而不是"某条链路坏了"):去掉确定性装置连跑两趟,卡住的是 1v1 还是大乱斗
#   **会互换** —— 取决于掉线那一刻服务器的输入队列是不是恰好空(客户端 60Hz 上行 vs 服务器
#   每 tick 只消费一包 → 队列长度在 0~2 抖动)。
# ★ 修复 = 在 `_enter_grace` 里补上清队列(与 `_on_reclaim` 同款),`7c95d68` 落地,相③ 当场转绿。
#   **本探针就是抓出它的那一件工具**;那个确定性装置留着不删 —— 它保证"谁删掉
#   `_pending_input[role] = []` 那一行谁红"(没有装置时这个竞态只有 ~50% 命中,见 watcher 的注释)。
# ═══ 时间预算(为什么必须并行)═══
#   整跑约 **72s 墙钟**(相④要等满一个 60s 宽限期:前半段"开机→进局→闪断→重连→相⑦"≈12s),
#   安全网是 `--quit-after 14400`(240s)——
#   早先用 3600(=60s)时连整跑都盖不住,已按 289cd86 提到 14400(见文件头跑法那两条) ——
#   故三组 服务端/客户端 **全部并行**跑,且每个子进程自带 `--quit-after`(18000 帧 ≈ 300s)兜底。

const PREFIX := "reconnect_probe_"
# ═══ ★★ 三个服务端端口都是**本探针自己挑的**(29xxx)★★
# 旧形态这里写的是"worker 端口必须落在大厅的端口池(7800~8299)之外" —— 那条护栏随
# `server/worker_launcher.gd` 一起**退役了**:单进程单端口之后没有端口池,也没有别人(用户
# 自己的大厅)会往某个号段发端口。留下的是它真正要保的那件事,换个说法继续成立:
#   **本探针只用自己挑的这几个号,绝不碰 7777(用户自己的服务端)。**
# 旧护栏的两条后果里,②(收尾按端口杀会误杀别人的 worker)也随之消失 —— 现在按端口杀到的
# 只可能是本探针自己拉起的那三个服务端(它们的 pid 也记着,端口那一刀只是兜底)。
# ★ 改这三个数时只需保证:不与 7777 重合、彼此不重合。
const S1V1 := 29001       # 1v1 那一支的服务端端口
const SROY := 29002       # 大乱斗那一支的服务端端口
const SIDLE := 29090      # 空载服务端端口(相⑥)
# 子进程兜底(18000 帧 ≈ 300s)。★ 这个"一直在跑"本身是**承重**的:actor 写完结果后要**保持连接**待命
# (见 reconnect_watcher 文件头「actor 收工后不退出」),它若自己先退,相位④ 的落点就换了人。
# 故它必须大于本进程的收工上限 `FINAL_TIMEOUT`(118s)与整跑长度(~72s)。
# ★ **照实登记**:旧值 9000(150s)按 60fps 换算**仍然满足**上面那两条(150 > 118 > 72)——
#   所以这次翻倍是**留余量**(与 FINAL_TIMEOUT 的 58 → 118 同一个"翻倍"形状),不是不等式要求。
#   别把它当成"旧值已失效"来引述;真要动它,上面那两条不等式的方向仍必须成立。
const CHILD_QUIT_AFTER := "18000"
const BOOT_TIMEOUT := 30.0         # 等服务端/客户端就绪的上限
# 本进程的收工上限。★ 推导:整跑 ≈ **60**(相④要等满的宽限期)+ **~12**(前半段:开机/进局/
#   闪断/重连/相⑦)≈ 72s ⇒ 上限必须**大于 72**。取 118 = 2 × `GRACE_MIN`(旧的 58 正是 2 × 29,
#   同一个形状),比下限多留 ~46s 给负载抖动;仍远小于 `--quit-after 14400`(=240s)那道安全网。
const FINAL_TIMEOUT := 118.0
# 相⑥的窗口:空载服务端打完「服务器就绪,等待玩家……」后的 [1,3] 秒内不得退出(判据与
# 旧形态的差别见 `_idle_tick`,那道 M1 守卫的"之后正当退出"在新形态下不存在)。
const IDLE_LOW := 1.0
const IDLE_HIGH := 3.0
const IDLE_BONUS := 14.0           # 观测期长度:到点判"仍然活着 + 仍占着自己的端口"
# 相④的时间判据(宽限期 60s ± 两种粒度;★ 改 `GraceWindow.DEFAULT_SECONDS` 必须重算这三个数)。
# 下界 59 = 60 − 1(本进程记「进宽限」那一刻与服务器真正 `enter` 之间有 ~0.3s 的采样粒度,取整);
# 上界 68 = 60 + 1(`_expire_graces` 每秒轮询一次的粒度)+ 7(负载余量;旧值 30/36 同形)。
const GRACE_MIN := 59.0
const GRACE_MAX := 68.0
# ── 相⑦:s1v1 服务端的两个测试开关(生产路径都不带;argv 解析见 server/server_main.gd)──
# 拆格延迟(秒)的**计时起点是建局**(`MatchHost._ready`,即 COUNTDOWN 开始),而 watcher 的时钟
# 以 **PLAYING** 为 0,两者差一个 `COUNTDOWN_TIME`(3s)。换算后要同时满足:
#   · 晚于 actor 的闪断(PLAYING+1.6 ≈ 建局+4.6):早了 actor 还在线,会自己收到 tile_destroyed,
#     相⑦ ① 就变成"服务器什么都没补"的假绿(它由 ①前置 报红,但那是诊断、不是结论);
#   · 早于 actor 的重连补态(PLAYING+7.6 ≈ 建局+10.6):晚了补态载荷里没有这一格,① 必红。
# 7.5 ≈ PLAYING+4.5,两侧各余 ~3s。★ 这个换算**跑一次就能核** —— witness 会把收到
# `tile_destroyed` 的 el 记进自己的日志(引擎日志两边都不带时间戳,只能这样对时)。
const P7_DESTROY_AFTER := "7.5"

var _role := "lobby"
# ── 裁判态 ──
var _t := 0.0
var _stage := 0
var _exe := ""
var _res := ""
var _failures: Array[String] = []
var _notes: Array[String] = []
var _s1v1_pid := 0
var _sroy_pid := 0
var _sidle_pid := 0
# 本进程拉起过的**全部**子进程的 PID(3 个服务端 + 4 个客户端)。收尾按它杀 —— 只按端口杀会
# 漏掉客户端(它们是从**临时端口**连出去的),见 `_kill_children`。
var _child_pids: Array[int] = []
var _idle_ready_t := -1.0
var _idle_alive_ok := false
var _idle_bonus_ok := false
var _grace_stamps: Array[float] = []   # 1v1 服务端每次「进宽限」被首次看到的时刻
var _expiry_t := -1.0
var _expiry_seen := false
var _done := false


func _ready() -> void:
	# 角色:无参 = 裁判;子进程由本进程用 `--who=<c1|c2|r1|r2>` 拉起(`--role=` 一并认,
	# 方便人工前台单起某一个客户端)。★ 两处**必须都认**:漏认 `--who=` 会让子进程回落成
	# "裁判"→ 它自己也去拉起服务端与客户端(端口冲突 + 递归),而表现只是几条
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
	print("PROBE: 裁判就绪(exe=%s);拉起 1v1 服务端(%d)与空载服务端(%d)" % [
			_exe.get_file(), S1V1, SIDLE])
	# ★ argv 与生产手跑逐字同一条命令:`server_main.tscn -- --port P`(没有 `--worker` ——
	#   那个开关及其同族参数已随子进程形态一起删除)。测试开关仍只落在 29xxx 这一支上。
	_s1v1_pid = _spawn_server(["--port", str(S1V1), "--test-ground-teleport",
			"--test-destroy-tile", "136,64," + P7_DESTROY_AFTER], "s1v1")
	_sidle_pid = _spawn_server(["--port", str(SIDLE)], "sidle")


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


# 相⑥:空载服务端的启动等待态(**本相在单进程形态下重写过,见下**)。
# 旧形态判的是"空载 `--royale` worker 在打完「就绪」后 1~3s 内不得退出",反向断言是
# "之后按 M1 守卫(`可用玩家 <2` 持续 10s)正当退出" —— 那条守卫存在的理由是"每局一个进程,
# 没人来就该把进程和端口还回去"。单进程之后:
#   · 没有 worker,只有一个**大厅与对局同进程**的服务端;
#   · `MatchSession._process` 里那道"可用玩家不足"的超时**只活在开过局的会话里** ——
#     一个没人连的服务端根本没有会话,故"之后正当退出"这一半**不存在**;
#   · 而它的正确行为恰恰是**常驻**:大厅要一直挂在端口上等人来(生产就是这么用的)。
# 于是本相锁的东西如实改成两件(缺一不可,否则就是空壳):
#   ① **没人来 ≠ 自杀**:就绪后 [1,3]s 与整个 IDLE_BONUS 观测期内都不得退出,日志里也不得
#      出现任何收场字样(旧形态那条"开机约 1s 自杀"的 Critical 换到新形态就是"给大厅加一条
#      '没人就退出'的看门狗" —— 它会**静默端掉用户自己的服务端**);
#   ② **反向(防空转)**:观测期结束时它必须**仍占着自己那个 UDP 端口** —— "进程还活着"可以靠
#      "挂死后僵着"骗过,而"端口仍被它持有"证明大厅真的还在监听。**必须让真帧跑过开机态**
#      (Task 4 的教训:只调 handler、不让 `_process` 跑过,18 条断言全绿仍漏掉自杀)。
func _idle_tick() -> void:
	if _idle_ready_t < 0.0:
		# 就绪行的**端口号也要对**:它证明这一跑真的 bind 到了本探针挑的那个端口
		# (旧形态这里等的是「大乱斗 worker 就绪」,那个分支已随 `--royale` 一起消失)。
		if _has(_log_path("sidle"), "服务器就绪,等待玩家……(端口 %d)" % SIDLE):
			_idle_ready_t = _t
			print("PROBE: 空载服务端已就绪(端口 %d,t=%.1fs),开始相⑥窗口" % [SIDLE, _t])
		return
	var age := _t - _idle_ready_t
	if age >= IDLE_LOW and age <= IDLE_HIGH:
		if OS.is_process_running(_sidle_pid):
			_idle_alive_ok = true
	if age >= IDLE_HIGH and not _idle_checked_flag:
		# ① 1~3s 窗口内进程活着(**至少看到一次**,窗口内每帧都看)
		_check(_idle_alive_ok, "相⑥:空载服务端在就绪后 1~3s 窗口内仍活着")
		_check(not _idle_teardown_seen(), "相⑥:空载服务端未打任何收场/退出字样(没人来 ≠ 自杀)")
		_idle_checked_flag = true
	if age >= IDLE_BONUS and not _idle_bonus_ok:
		# ★★ 反向断言:这条**不能省** —— 没有它,"没退出"可以靠"挂死后僵着"作弊通过。
		#   判据 = **端口属主仍是它**(`Get-NetUDPEndpoint` 的写法与 `ProcUtil.kill_udp_port`
		#   逐字同源,含那条 `Select -ExpandProperty` 的坑:写成 `% OwningProcess` 取不到属性、
		#   实测拿空且不报错)。
		_idle_bonus_ok = true
		var alive := OS.is_process_running(_sidle_pid)
		var owners := _udp_port_owners(SIDLE)
		_check(alive, "相⑥:空载服务端在 %.0fs 观测期结束时仍活着" % IDLE_BONUS)
		_check(owners.has(_sidle_pid),
				"相⑥:空载服务端**仍占着端口 %d**(仍在监听;属主查询实得 %s,本进程拉起的 pid=%d)"
				% [SIDLE, str(owners), _sidle_pid])
		_check(not _idle_teardown_seen(), "相⑥:观测期内始终没有收场/退出字样")
		print("PROBE: 相⑥完成(窗口内存活=%s,结束时存活=%s,端口属主=%s)"
				% [str(_idle_alive_ok), str(alive), str(owners)])


# 空载服务端的日志里出现了"收场/退出"字样吗?旧形态这一条判的是「全员离开,大乱斗结束」
# (Task 4 的自杀路径)。新形态下那行字**不可能出现**(没有会话就没人在数"可用玩家"),
# 故判据放宽到"任何收场/退出痕迹" —— 服务端自己那条「隧道就绪…后退出」不算(那是自检模式),
# 它不会出现在不带 `--tunnel` 的 argv 上;真出现收场字样就说明有人给大厅加了看门狗。
func _idle_teardown_seen() -> bool:
	var txt := _read(_log_path("sidle"))
	for needle in ["结束", "关闭", "释放端口", "退出释放"]:
		if txt.contains(needle):
			return true
	return false


# 某个 UDP 端口现在的属主 pid 列表(去重;查询失败/非 Windows → 空数组)。
# ★ 与 `ProcUtil.kill_udp_port` **同一条 PowerShell**(取属主必须 `Select -ExpandProperty
#   OwningProcess`,写成 `% OwningProcess` 会拿空且不报错 —— 见 ProcUtil 文件头那条 ⚠)。
#   这里**只查不杀**:相⑥ 要的是"端口还在它手里"这个事实。
func _udp_port_owners(port: int) -> Array:
	var out: Array = []
	if OS.get_name() != "Windows":
		return out   # 与 ProcUtil 同口径:这套查询只在 Windows 有意义
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; $p"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], out, true)
	var pids: Array = []
	for line in out:
		for tok in str(line).split("\n"):
			var s := tok.strip_edges()
			if s.is_valid_int():
				pids.append(int(s))
	return pids


var _idle_checked_flag := false


func _idle_checked() -> bool:
	return _idle_checked_flag


# 相 0:等 1v1 服务端报「就绪」→ 拉起两个客户端(建房/加入由客户端自己走大厅流程)
func _stage_boot() -> void:
	if _t > BOOT_TIMEOUT:
		_finish("服务端未在 %.0fs 内就绪(s1v1 日志=%s)" % [BOOT_TIMEOUT, _tail(_log_path("s1v1"))])
		return
	if not _has(_log_path("s1v1"), "服务器就绪,等待玩家……(端口 %d)" % S1V1):
		return
	print("PROBE: 1v1 服务端就绪(t=%.1fs),拉起 c1/c2" % _t)
	# ★ token 不再由探针生成:单进程之后它由服务端 `_open_match` 里的 `LobbyRooms.new_token()`
	#   发下来(`session_token`),客户端 claim 后原样 `report_token` 上报 —— 探针只驱动大厅。
	_spawn_client("c1", S1V1, 1, "pvp")
	_spawn_client("c2", S1V1, 2, "pvp")
	_stage = 1


# 相 1:等 1v1 两个客户端进对局并到 PLAYING → 这时才拉起大乱斗那一支(把启动 CPU 尖峰错开)
func _stage_clients_playing() -> void:
	if not _has(_log_path("c1"), "PLAYING"):
		if _t > BOOT_TIMEOUT:
			_finish("c1 未在 %.0fs 内进对局并到 PLAYING\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	print("PROBE: c1 已进对局且到 PLAYING(t=%.1fs),拉起大乱斗服务端(%d)" % [_t, SROY])
	_sroy_pid = _spawn_server(["--port", str(SROY)], "sroy")
	_stage = 2


# 相 2:收 4 份客户端结果 + 相④(1v1 宽限期到点)+ 相⑥ 的收尾
func _stage_collect() -> void:
	# 大乱斗服务端就绪后拉起 r1/r2(r1 建房 + r2 加入 + r1 发 royale_start)
	if _r1_launched == false and _has(_log_path("sroy"), "服务器就绪,等待玩家……(端口 %d)" % SROY):
		_r1_launched = true
		print("PROBE: 大乱斗服务端就绪(t=%.1fs),拉起 r1/r2" % _t)
		_spawn_client("r1", SROY, 1, "royale")
		_spawn_client("r2", SROY, 2, "royale")
	_track_grace()
	if _all_results() and not _evidence_checked:
		_evidence_checked = true
		_server_evidence()
	if not _done and _all_results() and _expiry_seen and _idle_checked_flag \
			and (not _r1_launched or _t > _idle_ready_t + IDLE_BONUS):
		_finish("")


var _r1_launched := false
var _evidence_checked := false


# 服务端侧证据:相②(拒绝)与相①(接受)的**另一半**在服务端自己的日志里。
# ★ 这一节正是 brief 点名的那条:「服务端日志里要盯『拒绝 reclaim』(Task 5 审查预警的 M35:
#   客户端按『连接』记账、服务端按『role 是否还在宽限期』判,非对称断线那一档会被拒+踢)——
#   探针应以断言的形式盯住它,而不是只人工看日志」。
#   判据落在服务端日志上而不是只说"客户端被踢了":被踢也可能是别的原因(比如判据②),而
#   **只有服务端自己打出来的理由**能区分"令牌不匹配"与"该 role 不在宽限期"。
# ★ 这些行现在由 `server/match_session.gd` 打出(**本进程拉起的服务端进程**,`--log-file` 收)。
func _server_evidence() -> void:
	for tag in ["s1v1", "sroy"]:
		var txt := _read(_log_path(tag))
		_check(txt.contains("拒绝 reclaim") and txt.contains("令牌不匹配"),
				"相②(%s):服务端打了「拒绝 reclaim …令牌不匹配」" % tag)
		_check(txt.count("重连成功") == 1,
				"相①(%s):服务端恰好接受了一次 reclaim(实得 %d 次)" % [tag, txt.count("重连成功")])
		_check(_grace_entries(txt) >= 1,
				"相③(%s):服务端走了宽限期(身体留在场上,不是当场移出)" % tag)
		_check(_count_start_lines(txt) == 1,
				"相①(%s):对局只开了一次(重连没有重开一局)" % tag)
	# 相⑦ ③:**防空转**。相⑦ 的其余判据都在"客户端世界 = 服务器世界"这个等式上,而那个等式
	# 在"服务器其实什么都没拆"时**照样成立**(actor 那格本来就是空气 → grid==EMPTY 恒真)。
	# 这一条证明"服务器真的动了手":它由 `MatchHost._debug_destroy_tile` 打出,那一行同时也是
	# 探针能读到**服务端内部动作**的**唯一**通道(服务端是独立进程,见文件头「拓扑」)。
	# ★ 服务端日志是本进程拉起、本进程读的,故这里直接取 `_log_path("s1v1")` 而不进上面的循环。
	_check(_has(_log_path("s1v1"), "[test] 拆格"),
			"相⑦ ③:s1v1 服务端日志里有「[test] 拆格」(--test-destroy-tile 真的触发了)"
			+ "—— 没有它,相⑦ ① 可能是「服务器什么都没做」的假绿")


# 「对局 <房号> 开始(<模式备注>)」这一行的条数(= 这一局只开了一次)。
# ★ 为什么不直接 `count("对局开始")`:单进程之后这一行由 `MatchSession._begin_match` 打出,
#   形如「对局 04217 开始(大乱斗 2 人,其中 AI 0)」—— 房号夹在中间,子串判据必然落空。
#   而房号是服务端随机生成的(5 位,客户端才知道),探针读日志时无从预先知道它 —— 故按
#   **行首 + " 开始"** 判。★ 别退回"count 某个含房号的完整串":那需要先反向解析房号,
#   而解析一旦漂了,这条断言会**静默变成恒假**(比恒真更坏:它会把好实现判红)。
func _count_start_lines(txt: String) -> int:
	var n := 0
	for line in txt.split("\n"):
		if line.begins_with("对局 ") and line.contains(" 开始"):
			n += 1
	return n


# "某个 role 进宽限"在服务端日志里有**两种行**,任何一处判据都必须**两个都数**
# (`MatchSession._on_peer_left` 按那一刻 `claims` 空不空二选一打印):
#   · 「玩家掉线进宽限(剩 N 人在线)」—— 掉线后房里还有别人;
#   · 「全员离开,进宽限等待重连」    —— 掉的是最后一个真人。
# ★ 为什么必须两个都数:两条支路的胜负取决于**两端各自的时钟**(它们只在 ±1.5s 内对齐,见
#   watcher 文件头「时间轴」)—— 例如大乱斗那一支里 r2 的永久掉线可能落在 r1 重连成功**之前**,
#   那一刻 claims 恰好空 ⇒ 打的是第二种行。只认第一种会得到一条**时红时绿**的断言。
func _grace_entries(txt: String) -> int:
	return txt.count("玩家掉线进宽限") + txt.count("全员离开,进宽限等待重连")


# 相④:1v1 服务端的宽限期到点收场。
# ★ 判据是**时间差**不只是"打了那行字":宽限期(`GraceWindow.DEFAULT_SECONDS`)是 spec 的硬承诺,
#   只断言"最终会收场"会把"10s 就判超时"这种坏实现放过去。`_expire_graces` 每秒轮询一次 →
#   实测落在 [60,61]s,本进程的采样粒度再加 ~0.3s。起点取**第二次**「进宽限」(第一次是 c1 的闪断、
#   被 reclaim 救回;第二次是 c2 的永久掉线 —— 它就是该到点的那一个),两行都在服务端日志里带序号校验。
# ★★ 单进程形态下"进宽限"有**两种行**(见 `_grace_entries`):旧形态只有一种,照旧写会漏掉整条断言。
func _track_grace() -> void:
	var txt := _read(_log_path("s1v1"))
	if txt == "":
		return
	var n := _grace_entries(txt)
	while _grace_stamps.size() < n:
		_grace_stamps.append(_t)
		print("PROBE: 1v1 服务端第 %d 次「进宽限」(t=%.1fs)" % [_grace_stamps.size(), _t])
	if not _expiry_seen and txt.contains("1v1 宽限期到,对手未归,对局结束"):
		_expiry_seen = true
		_expiry_t = _t
		_check(_grace_stamps.size() == 2,
				"相④:1v1 服务端恰好两次「进宽限」(c1 闪断 + c2 永久掉线),实得 %d" % _grace_stamps.size())
		if _grace_stamps.size() >= 1:
			var since := _t - _grace_stamps[_grace_stamps.size() - 1]
			_check(since >= GRACE_MIN and since <= GRACE_MAX,
					"相④:宽限期到点耗时 %.1fs ∈ [%.0f, %.0f](GraceWindow.DEFAULT_SECONDS=60)"
					% [since, GRACE_MIN, GRACE_MAX])
		print("PROBE: 相④ 1v1 服务端收场(结束这一局,t=%.1fs)" % _t)


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

# 拉起一个**普通服务端**(不带任何 `--worker` 同族参数 —— 那些已随子进程形态删除)。
# ★ `--log-file` 是必需的,不是可选:服务端判据(拒绝 reclaim / 进宽限 / 收场 / [test] 拆格)
#   全在它自己的日志里,而 Windows 下 `OS.create_process` 的子进程 stdout 不被父进程继承。
func _spawn_server(server_args: Array, tag: String) -> int:
	var argv := PackedStringArray(["--headless", "--path", _res, "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _log_path(tag), "res://server/server_main.tscn", "--"])
	for a in server_args:
		argv.append(str(a))
	print("PROBE: spawn 服务端 %s argv=%s" % [tag, str(argv)])
	return _record_pid(OS.create_process(_exe, argv))


# 拉起一个客户端。★ `--slot` 决定它在大厅里当**房主**(1)还是**加入者**(2):
# 单进程单端口之后服务端按房记录的名册接受 claim(不在名册里的 claim 被判「串线」踢掉),
# 故客户端必须先走大厅(建房/加入),不能像旧形态那样直连 worker 端口就 claim。
func _spawn_client(who: String, port: int, slot: int, scene: String) -> int:
	var argv := PackedStringArray(["--headless", "--path", _res, "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who), "res://tests/reconnect_probe.tscn", "--",
			"--who=" + who, "--port=" + str(port), "--slot=" + str(slot),
			"--scene=" + scene])
	print("PROBE: spawn 客户端 %s(port=%d slot=%d scene=%s)" % [who, port, slot, scene])
	return _record_pid(OS.create_process(_exe, argv))


func _record_pid(pid: int) -> int:
	if pid > 0:
		_child_pids.append(pid)
	return pid


# 收尾:两条路一起走,缺一不可。
#   ① **按 PID 杀全部子进程**(本仓既有先例:`tests/*.sh` 用 `taskkill /PID`;GDScript 侧是
#      `OS.kill`)。为什么非有这一条:四个**客户端**是从临时端口连出去的,不占 S1V1/SROY/SIDLE
#      任何一个,**只按端口杀根本杀不到它们** —— 于是上一跑的 c1/r1 会留下来,后果实测过两条:
#        · 持续敲下一次运行的服务端(上一次审查观察到 3 条「该 role 不在宽限期」);
#        · 一直攥着自己的 `user://reconnect_probe_<who>.log` → 下一跑 `_clean()` 的删除**失败**
#          (旧代码忽略返回值,静默),新进程随即截断该文件、残留进程按旧偏移续写 → 文件里出现
#          空洞与陈旧行(所以 `_clean()` 现在会报出来)。
#   ② **仍按 UDP 端口补一刀**:它兜住"PID 记录漏了"这一档(服务端才是真 ENet 绑定端口的那一侧),
#      成本是三条 PowerShell,且与本仓 `tests/*.sh` 的 `taskkill + kill_port` 双保险同款。
#      ★ 杀的这三个端口**都是本探针自己挑的**(旧形态这里杀的是 worker 端口,而 worker 的 pid
#      记不到 —— 它由 WorkerLauncher 拉起;现在服务端是本进程拉起的,故只有兜底价值)。
func _kill_children() -> void:
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	for p in [S1V1, SROY, SIDLE]:
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
	for tag in ["c1", "c2", "r1", "r2", "s1v1", "sroy", "sidle"]:
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
	for tag in ["c1", "c2", "r1", "r2", "s1v1", "sroy", "sidle"]:
		out += "  [%s 引擎日志]\n%s\n" % [tag, _tail(_log_path(tag))]
	return out


# ════════════════════ 客户端子进程 ════════════════════
# 观察者挂 `root`(不是本场景):换场(探针场景 → 真对局场景)不会把它带走。
# ★ 不再传 `--token=`:token 由**服务端**在建局那一刻生成并下发(`session_token`),客户端
#   claim 后原样 `report_token` 上报 —— 探针自己造 token 在单进程形态下**没有意义**
#   (服务端只认自己发出去的那一份,自造的一定被判「令牌不匹配」)。
func _run_client() -> void:
	var w: Node = load("res://tests/reconnect_watcher.gd").new()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--who="):
			w.who = a.trim_prefix("--who=")
		elif a.begins_with("--port="):
			w.port = int(a.trim_prefix("--port="))
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
