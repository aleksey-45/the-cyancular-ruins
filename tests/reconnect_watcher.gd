extends Node

# 断线重连探针的**客户端侧驱动/观察者**(见 reconnect_probe.gd 文件头)。
# 由 `reconnect_probe.gd --role=<who>` 实例化后**挂到 `get_tree().root`**:探针场景 → 真对局场景
# 的那次换场不会把它带走,故它能在换场**之后**读真 `pvp_game` / `royale_game` 实例的状态。
#
# 它做三件事:
#   ① 进场段(**单进程单端口之后必走大厅**):connect → `lobby_name` → 建房(`slot == 1`)或
#      从公开列表加入(`slot == 2`)→ 等 `go_match` → 在**同一条连接上** claim_role /
#      player_options / report_token(镜像 `lobby_page._claim_role` 的三条 RPC)→ 等
#      `match_start` → 进真对局场景。
#      ★★ **不能**像旧形态那样"连上就 claim":单进程之后所有房共用一个端口/一个服务端进程,
#      `MatchSession._on_role_claimed` 靠**房记录的名册**(`roster`)挡串线 —— 名册外的 caller
#      当场被判「拒绝串线连接」并踢掉(旧形态靠"端口独占 + 进程独占"隐式隔离,那个隔离没了)。
#      ★ token 也**不再由探针自造**:它是服务端 `_open_match` 里 `LobbyRooms.new_token()`
#      发的(`session_token`),claim 后原样 `report_token` 上报。
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
# ═══ 相⑦(仅 1v1):掉线窗口里**服务器侧**世界变过 ═══
#   动机(阶段 2-A 的主缺口):actor 掉线的那 30 秒里服务器侧拆了墙、地面上的枪被捡走;
#   重连后靠 `pvp_match_client._on_resumed` 那一拉(match_sync)补回 —— 不补的话客户端留着
#   **幻影墙**(撞上去 → 本地预测与服务端分歧 → 可能回滚循环)与**幽灵枪**(看着在、按 F 无效)。
#   两处变化都必须由**服务器侧**制造(探针进程拿不到服务端进程里的 `_host`:大厅与对局虽在
#   同一个进程,但那是**另一个** OS 进程,见 reconnect_probe.gd 的「拓扑」),
#   所以走两个测试开关 + witness 的动作:
#     · 拆墙:服务端命令行 `--test-destroy-tile 136,64,<delay>`(见 reconnect_probe.gd)
#     · 捡枪:服务端带 `--test-ground-teleport` 把枪喂到脚下,**本文件(c2)按 F**
#   判据在 `_actor_assert` 尾部的 `_p7_assert`(actor 侧)+ 裁判读服务端日志(③,防空转)。
#   ★ 这一相唯一的失败模式是"看起来绿、其实什么都没验" —— 变化若落在闪断**之前**,actor
#     自己就收到了事件、主判据照样绿。故每条主判据都配一条**前置**断言盯这件事。
#
# ═══ 时间轴(相对**本端**看到 PLAYING 的那一刻 `_tp`)═══
#   actor:0.0 按住 S(必须先跑起来)· 1.5 塞确定性装置的包 · 1.6 闪断(错 token)
#          · 6.5 恢复真 token · 9.5 断言相①②⑤⑦(为什么不是更早见 `T_ACTOR_END` 上方)
#   witness:2.5~5.2 观测窗口(相③)· 3.5~5.0 (c2)按 F 捡枪(相⑦)· 5.6 (c2/r2)永久掉线 · 6.2 收工
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
#   进宽限,服务端的「进宽限」就变成 3 次、到点收场的那个 role 也换了人 —— 相④的判据(时间差)
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

# ── 相⑦(仅 1v1;设计见文件头)──
# 与 reconnect_probe.gd 拉起 s1v1 时那串 `--test-destroy-tile 136,64,<delay>` **同源**:
# 改一处要改两处。★ 改错了**不会**假绿 —— 该格若不在服务器拆的名单里,① 会红;若那格本来
# 就是空气,「①前置」会红(闪断时本端那格就已经是 EMPTY)。
const P7_CELL := Vector2i(136, 64)
# witness 开始/结束按 F 的时刻。★ 起点必须**晚于** actor 的闪断(T_DROP=1.6)+ 两端 `_tp` 漂移
# (实测 ~0.7s,见文件头「时间轴」):早了的话 actor 还在线、会直接收到 weapon_removed,
# 相⑦ ② 就退化成"空转的绿"(本文件的前置断言会红,但那时是诊断、不是结论)。
# 终点必须早于 witness 自己的永久掉线(T_W_DROP=5.6)—— 掉线后再按就没人收边沿了。
const T_W_PICKUP := 3.5
const T_W_PICKUP_END := 5.0
const PICKUP_RETRY := 0.35  # 按 F 的重试间隔(服务器 `nearest_within` 每帧都喂枪,一次就够;
                            # 重试只是兜住"这一帧恰好没喂到"的抖动)

# ── 大厅段(单进程单端口之后**进场必走**,见文件头 ①)──
# 重问列表的节拍:列表是**请求/响应**式的,而建房与"加入者第一次问"之间必然差一拍
# (`create_room` 要走一次 RPC 往返 + 服务端 `_defer_begin_match` 那类延后),故必须重试;
# 0.5s 与 `rejoin_watcher`/`team_match_watcher` 的刷新梯同一量级。
const LOBBY_RETRY := 0.5
# 等 `session_token` 的上限。★ token 与 go_match 是两条 RPC(session_token 走 NetBusExt、
# go_match 走 NetBus,前者由服务端**先同步发**、后者 `call_deferred` 到帧末),正常必然先到;
# 这一档只是兜住"同一帧内顺序反了"的抖动 —— 没有它,claim 会不带 token 发出去,而
# **服务器只认自己发的那一份** → 相① 的 reclaim 必被拒(症状是"重连永远回不来")。
# 到点还没 token 就照发(那一刻的失败会在相① 里响亮地红,而不是静默等死)。
const CLAIM_TOKEN_WAIT := 2.0

# 脚本手柄(见 `_p7_witness_tick`:F 的读口是**边沿**,必须走本仓既有的办法上报)。
const BotInput := preload("res://tests/ground_bot_input.gd")

var who := "c1"
var port := 0
# 服务端真正下发的那份 token(`session_token` 信号里的原值)。★ 探针**不再自造**它:
# 单进程之后服务端在 `_open_match` 里 `LobbyRooms.new_token()` 生成并只认自己那一份,
# 相①/② 都靠"把真 token 换回去"来演 —— 故它必须存下来。
var token := ""
var slot := 1
var scene_path := "res://scenes/pvp_game.tscn"
var is_royale := false
var is_actor := true
var drop_permanently := false

# ── 大厅段状态(见文件头 ①)──
var _lobby_code := ""            # 本支那一间房的房号(房主建房时收到 / 加入者从列表里读)
var _lobby_join_sent := false    # 加入者:加入请求已发出(别重复发)
var _lobby_state_players := 0    # 大乱斗房:等待室状态里的人数(房主据此发 royale_start)
var _lobby_start_sent := false   # 大乱斗房主:royale_start 已发出
var _lobby_t := 0.0              # 下一次问列表/判开局的时刻
var _go_role := -1               # go_match 带来的权威 role(-1 = 还没到)
var _claim_sent := false
var _claim_wait := 0.0           # 等 session_token 的累计时长(上限见 CLAIM_TOKEN_WAIT)

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
var _resumed_spawn := Vector2i(-1, -1)   # 重连后服务端重发的那份
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
# ── 相⑦ 观测量(actor 侧;见 `_p7_assert`)──
var _p7_grid_before := -1               # 闪断那一刻本端 grid[P7_CELL.y][P7_CELL.x]
var _p7_gw_before: Array = []           # 闪断那一刻本端地面武器的 inst 集合
var _p7_payloads := 0                   # 收到过几条 match_sync 载荷(进场那条 + 重连补态那条)
var _p7_payloads_at_drop := 0
var _p7_sync_insts: Array = []          # 最近一条载荷里的地面武器 inst 集合(服务器权威)
var _p7_sync_destroyed: Array = []      # 最近一条载荷里的 destroyed(与基线不同的格)
var _p7_tile_ev := 0                    # 收到过几条该格的 tile_destroyed 广播
var _p7_tile_ev_at_drop := 0
# ── 相⑦ 观测量(witness 侧)──
var _bot = null                         # 脚本手柄(`ground_bot_input.gd`;F 的边沿读口)
var _pickup_t := -1.0                   # 下次按 F 的时刻
var _p7_my_removed: Array = []          # 服务器广播的「我捡走了」inst(by_role == 本端 role)


func _ready() -> void:
	var lp := "user://reconnect_probe_%s.log" % who
	if FileAccess.file_exists(lp):
		# 删不掉(多半是上一跑的同名客户端还活着、还攥着这个文件)→ 后面 `seek_end()` 会把新
		# 内容**接在陈旧内容后面**,读日志的人会照旧行归因。故失败要出声音,别静默。
		var rm := DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
		if rm != OK:
			push_warning("PROBE[%s]: 删不掉上一跑的 %s(错误 %d)—— 本文件里会有陈旧行" % [who, lp, rm])
	PvpSession.role = slot
	PvpSession.server_port = port          # ★ 单进程单端口:大厅与对局都是**这一台**,
	PvpSession.server_address = "127.0.0.1"  #   重连(`_retry_connect`)也直连它
	PvpSession.player_name = who.to_upper()
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(_on_server_message)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)   # 相①的 ack 读数(见 `_actor_assert`)
	NetBus.local_round_state.connect(_on_round_state)
	# ── 大厅段(见文件头 ①):建房/加入 → go_match → 在同一条连接上 claim ──
	NetBus.local_room_created.connect(func(code: String) -> void:
		_lobby_code = code
		_log("建房成功:%s(占住 slot 1)" % code))
	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_go_match.connect(_on_go_match)
	NetBusExt.local_session_token.connect(func(t: String) -> void:
		token = t
		PvpSession.token = t
		_log("收到服务端下发的 session_token(%d 位 hex),claim 时原样上报" % t.length()))
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_royale_room_state)
	# 相⑦:补态载荷(服务器对 match_sync 的应答)与那一格砖的广播。
	# ★ 两处都**不消费**信号,只是旁听 —— 生产路径的消费者(`pvp_game._on_match_sync` /
	#   `_on_remote_tile_destroyed`)照常跑,本观察者只是把同一份数据留个底。
	# ★ 订阅**按模式门控**:相⑦ 只跑 1v1(`_p7_assert` / `_p7_witness_tick` 都是 `is_royale` 门控的),
	#   而这几个订阅原先对四个客户端一视同仁 —— 后果不是"多跑一点",而是大乱斗客户端的日志里
	#   混进一串「相⑦:…」字样(它们谁也不判、只打印),读日志的人会照着一相不存在的断言归因。
	if not is_royale:
		NetBus.local_match_sync.connect(_on_match_sync_payload)
		NetBus.local_tile_destroyed.connect(_on_tile_destroyed)
		if not is_actor:
			NetBus.local_weapon_removed.connect(_p7_on_removed)   # 相⑦:witness 侧的交叉证据
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void: _log("连服务端失败"), CONNECT_ONE_SHOT)
	var err := NetBus.start_client("127.0.0.1", port)
	_log("观察者就绪(role=%s port=%d scene=%s actor=%s)" % [who, port, scene_path, str(is_actor)])
	if err != OK:
		_finish("start_client 失败 %d" % err)


# ── 大厅段(单进程单端口之后**进场必走**,见文件头 ①)──
# 连上服务端只是"进了大厅",**还不是对局里的人**:服务端按房记录的名册(`roster`)接受 claim,
# 名册外的 caller 会被 `MatchSession._on_role_claimed` 判「拒绝串线连接」当场踢掉。
# 故先由本端驱动大厅:房主建房、加入者从公开列表里挑那一间加入;1v1 由服务端 `pairing_ready`
# 自动开局,大乱斗由房主在两人到齐后发 `royale_start`(与生产等待室那颗「开始」逐字同路)。
func _on_connected() -> void:
	_log("已连服务端 %d → 上报昵称,走大厅流程(%s)" % [port, "房主" if slot == 1 else "加入者"])
	NetBus.rpc_id(1, "lobby_name", who.to_upper())
	if slot == 1:
		if is_royale:
			# 上限 2:`royale_start` 的硬闸门是「人数 >= ROYALE_MIN_PLAYERS(2)」,
			# 而 `_open_match` 把参战 role 集合取成房里的玩家 role ⇒ 正好 1、2 两个 role。
			NetBusExt.rpc_id(1, "royale_create", {"max_players": 2})
		else:
			NetBus.rpc_id(1, "create_room")
		return
	_lobby_t = 0.0   # 加入者:立刻问一次列表
	_request_lobby_list()


func _request_lobby_list() -> void:
	if is_royale:
		NetBusExt.rpc_id(1, "royale_list")
	else:
		NetBus.rpc_id(1, "list_rooms")


# 大厅节拍(每帧从 `_process` 调;进对局后自然停摆 —— `_claim_sent` / `_go_role` 那些闸已关上)
func _lobby_tick(delta: float) -> void:
	# ① 等 token(它必须早于 claim 落到本端,理由见 CLAIM_TOKEN_WAIT)
	if _go_role >= 0 and not _claim_sent:
		_claim_wait += delta
		_try_claim()
		return
	if _claim_sent:
		return
	_lobby_t -= delta
	if _lobby_t > 0.0:
		return
	_lobby_t = LOBBY_RETRY
	if slot == 1:
		# 大乱斗房主:两人到齐 → 发开局。★ 与生产的等待室按钮同一条 RPC(`royale_start`),
		# 服务端还会再判一次"人数 >=2"与"只有房主能开";1v1 房主则什么都不用做
		# (服务端 `pairing_ready` 自己会开局)。
		if is_royale and not _lobby_start_sent and _lobby_state_players >= 2:
			_lobby_start_sent = true
			_log("等待室 2 人到齐 → 房主发起 royale_start")
			NetBusExt.rpc_id(1, "royale_start")
		return
	# 加入者:列表是请求/响应式的,建房与第一次问之间必然差一拍 ⇒ 重问到看见房为止
	# (`_on_room_list` / `_on_royale_rooms` 取到房号就把 `_lobby_join_sent` 置起,此后不再发)。
	_request_lobby_list()


# 1v1 房列表(公开房的**纯构造**载荷 [{code, players, names, in_match}])。
# ★ 本探针每一支只有这一台服务端、也只该有一间房(另一支在别的端口上),故取第一行即可;
#   仍按"有 code 才认"过滤,免得把空载荷当成房。
func _on_room_list(rooms: Array) -> void:
	if slot != 2 or _lobby_join_sent:
		return
	for r in rooms:
		if r is Dictionary and str(r.get("code", "")) != "":
			_lobby_code = str(r.get("code", ""))
			_lobby_join_sent = true
			_log("列表里看到房 %s(%s 人)→ 加入" % [_lobby_code, str(r.get("players", "?"))])
			NetBus.rpc_id(1, "join_room", _lobby_code)
			return


func _on_royale_rooms(rooms: Array) -> void:
	if slot != 2 or _lobby_join_sent:
		return
	for r in rooms:
		if r is Dictionary and str(r.get("code", "")) != "":
			_lobby_code = str(r.get("code", ""))
			_lobby_join_sent = true
			# 公开房:邀请码参数按大厅那一侧的判据只在私密房才校验,这里给空串即可。
			_log("大乱斗列表里看到房 %s → 加入" % _lobby_code)
			NetBusExt.rpc_id(1, "royale_join", _lobby_code)
			return


# 大乱斗等待室状态(只有房内成员收得到)。房主靠它判"人到齐了没"。
func _on_royale_room_state(state: Dictionary) -> void:
	_lobby_code = str(state.get("code", _lobby_code))
	_lobby_state_players = (state.get("players", []) as Array).size()
	_log("等待室状态:%d 人(code=%s)" % [_lobby_state_players, _lobby_code])


# 大厅配对完成。★★ 单进程单端口之后 `go_match` **只表示"进对局场景"**:连接全程不动,
# claim 直接发在**这条既有连接**上(与 `lobby_page._do_go_match` → `_claim_role` 逐字同路)。
# 旧形态在这里要做的是"`NetBus.stop()` + 转连 worker 端口" —— 那一步与 worker 一起没了。
func _on_go_match(role: int, go_port: int) -> void:
	if _claim_sent or _go_role >= 0:
		return
	_go_role = role
	PvpSession.role = role
	if go_port > 0:
		# 服务端端口 = 本端此刻连着的那一个(单端口)。写回去是为了让局内重连直连同一台。
		PvpSession.server_port = go_port
	_log("go_match role=%d port=%d → 在同一条连接上 claim(不转连)" % [role, go_port])
	_try_claim()


func _try_claim() -> void:
	if _claim_sent or _go_role < 0:
		return
	if token == "" and _claim_wait < CLAIM_TOKEN_WAIT:
		return   # 等服务端那份 token(理由见 CLAIM_TOKEN_WAIT)
	_claim_sent = true
	if token == "":
		_log("★ 等不到 session_token(%.1fs)—— 照发 claim,但这次 reclaim 必被拒" % CLAIM_TOKEN_WAIT)
	# 三条 RPC 的顺序与 `lobby_page._claim_role` 逐字一致:claim → player_options → report_token。
	# ★ 顺序有意义:`MatchSession._on_token_reported` 是**按 caller 反查 role** 归档 token 的,
	#   倒过来发会归错/归空。
	NetBus.rpc_id(1, "claim_role", _go_role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", {})
	if token != "":
		NetBusExt.rpc_id(1, "report_token", token)


# `match_start` 有**两个**到达时机:① 首次开局进场;② 服务端接受 reclaim 之后重发的那条。
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


# 相⑦:match_sync 的应答(进场那条 + 重连补态那条,同一口)。只留底,不判 ——
# 判在 `_p7_assert`:它要的是"补态那一刻服务器手里是什么",而这正是这条载荷。
# ★ 本观察者挂 root、比当前场景早一步订阅,故本函数**先于** `pvp_game._on_match_sync` 跑
#   (信号按连接顺序派发)—— 于是这里读到的地面武器表还是**补态之前**的旧值。判据不依赖
#   这个顺序:`_p7_assert` 取的是断言时刻的表(那时场景那条早跑完了)。
func _on_match_sync_payload(payload: Dictionary) -> void:
	_p7_payloads += 1
	var insts: Array = []
	for e in payload.get("ground_weapons", []):
		if e is Dictionary:
			insts.append(int(e.get("inst", 0)))
	_p7_sync_insts = insts
	var d: Array = []
	for c in payload.get("destroyed", []):
		if c is Vector2i:
			d.append(c)
	_p7_sync_destroyed = d
	_log("相⑦:收到 match_sync 载荷(第 %d 条;地面武器 %d 件,destroyed %s)"
			% [_p7_payloads, insts.size(), str(d)])


# 相⑦:那一格砖的广播(服务器拆墙时发)。两个用处:
#   · actor:证明"闪断之后没再收到它" —— ①(补态生效)才不是被事件救的;
#   · witness:把**收到它的时刻**(el)记进日志。拆格延迟是从建局起算的,换算到 PLAYING 口径
#     只能靠这个读数(两边的引擎日志都不带时间戳)。
func _on_tile_destroyed(cell: Vector2i) -> void:
	if cell != P7_CELL:
		return
	_p7_tile_ev += 1
	_log("相⑦:收到 tile_destroyed %s(el=%s,第 %d 次)"
			% [str(cell), "%.2f" % (_t - _tp) if _tp >= 0.0 else "未到 PLAYING", _p7_tile_ev])


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	# 大厅段(建房/加入 → go_match → claim)在**进对局之前**每帧推一下;进局后它自然停摆
	# (`_claim_sent` / `_go_role` 那些闸已经关上,`_lobby_tick` 当场早退)。
	_lobby_tick(delta)
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
		_p7_sample_at_drop()
		_before_local_id = (_game.get("_local") as Object).get_instance_id()
		_before_game_id = _game.get_instance_id()
		# 相②:先塞错 token —— 服务端读它发生在 `_try_reclaim` **发的那一刻**
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
	# 相②的客户端侧一半:错 token 那一发**真的被踢了**(服务端侧另一半在裁判的日志断言里)
	_check(_kick_count >= 1, "相②(客户端侧):错 token 被拒后收到「连接断开」(实得 %d)" % _kick_count)
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
	#   重连后服务端重发的那条 `match_start` 必须带**与首次同一个** spawn。
	#   它钉的是一条**没有任何其他断言拦得住**的回归:`RoyaleHost` 覆写的 `role_spawns()` 若被
	#   删掉(退回基类实现 —— 基类走 `_spawn_cell`,而大乱斗那个第二次起返回**动态复活点**、
	#   并带 `_spawned_once` 闩锁副作用),或者 `_round_spawns` 被就地改掉,reclaim 这条路径
	#   就会把**复活点**当出生点下发,客户端据此把玩家瞬移过去 —— 而相① 的其余判据
	#   (instance_id 不变 / 快照续上 / 大乱斗的 scores 与时钟)在那条回归下**全绿**。
	#   ★ 只把 spawn 打进日志、人眼对(旧版就是这样)等于没有防卫:这类"值悄悄变了"只有
	#     断言拦得住,故它现在是真断言。
	_check(_resumed_spawn_seen,
			"相⑤:重连后收到服务端重发的 match_start(判其 spawn 未变的前提)")
	_check(_resumed_spawn == _first_spawn,
			("相⑤:第二次 match_start 的 spawn 不得与首次不同(reclaim 不应重新摆位);"
			+ "首次 %s,重发 %s") % [str(_first_spawn), str(_resumed_spawn)])
	# ★★ 相⑦:补态(仅 1v1;设计见文件头)
	_p7_assert()
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


# ── 相⑦(actor 侧):掉线窗口里服务器侧世界变过的两处,重连补态必须都补上 ──
#   三条主判据(①拆墙 / ②幽灵枪 / ③在裁判那侧读服务端日志)逐条见下。
#   ★ 每条主判据都配一条**前置**:这一相唯一的失败模式是"看起来绿、其实什么都没验"
#     (变化若落在闪断之前,actor 自己就收到了事件,主判据照样绿)。

# 闪断那一刻取样。三个读数合起来才判得了"补态生效",而不是"变化根本不在窗口里"。
func _p7_sample_at_drop() -> void:
	if is_royale:
		return   # 大乱斗那一支的服务端不带这两个测试开关(见 reconnect_probe.gd),采了也没人判
	_p7_grid_before = _p7_grid()
	_p7_gw_before = _gw_insts()
	_p7_payloads_at_drop = _p7_payloads
	_p7_tile_ev_at_drop = _p7_tile_ev
	_log("相⑦ 取样:grid%s=%d(EMPTY=%d),地面武器 %d 件 %s;已收载荷 %d 条、该格广播 %d 条"
			% [str(P7_CELL), _p7_grid_before, MazeGenerator.EMPTY, _p7_gw_before.size(),
			str(_p7_gw_before), _p7_payloads, _p7_tile_ev_at_drop])


func _p7_assert() -> void:
	if is_royale:
		return
	# ── ① 拆墙(主判据:本端那格变空气)──
	# 前置 A:闪断那一刻本端那格还是**实心**的。
	#   ★ 它同时是"拆格延迟调错"的报警器:拆格若落在闪断**之前**,actor 还在线、会自己收到
	#     tile_destroyed → 本端早就 EMPTY 了,① 会以"服务器什么都没补"的假绿通过。
	_check(_p7_grid_before != MazeGenerator.EMPTY,
			("相⑦ ①前置:闪断时本端 grid%s 仍是实心(实得 %d)—— 红在这里 = 拆格落在闪断**之前**,"
			+ "把 reconnect_probe 的 P7_DESTROY_AFTER 往后挪") % [str(P7_CELL), _p7_grid_before])
	# 前置 B:闪断之后没有再收到那一格的广播(收到 = 那格是被事件修的,不是被补态修的)。
	_check(_p7_tile_ev == _p7_tile_ev_at_drop,
			("相⑦ ①前置:闪断之后没再收到该格的 tile_destroyed(实得 %d 条;>0 = 那格是被广播修的,"
			+ "补态那一路等于没验)") % (_p7_tile_ev - _p7_tile_ev_at_drop))
	var g_now := _p7_grid()
	_check(g_now == MazeGenerator.EMPTY,
			"相⑦ ①:重连补态后本端 grid%s == EMPTY(实得 %d)" % [str(P7_CELL), g_now])
	# ① 的"非空转"另一半:服务器在补态里**点名**了那一格(③ 证明它动了手,这条证明那件事
	# 进了补态载荷 —— 两者缺一,① 都可能是"本来就没这回事")。
	_check(_p7_sync_destroyed.has(P7_CELL),
			"相⑦ ①:补态载荷的 destroyed 里点名了该格(实得 %s)" % str(_p7_sync_destroyed))
	# ── ② 地面武器(主判据:witness 捡走的那把不得在本端表里留下)──
	# "witness 捡走的那把"= 闪断时本端表里有、而补态载荷(服务器权威)里没有的那个 inst。
	# ★ 不写死 inst:它是服务器每帧喂到 witness 脚下的那把(见 MatchGround._debug_keep_weapon_within_reach),
	#   由 `nearest_within` 决定,开局散点是随机的 → 写死必然漂。
	_check(_p7_payloads > _p7_payloads_at_drop,
			"相⑦ ②前置:重连补态载荷已到达(进场 %d 条 → 现 %d 条;没到 = ② 判的是旧数据)"
			% [_p7_payloads_at_drop, _p7_payloads])
	var picked: Array = []
	for inst in _p7_gw_before:
		if not _p7_sync_insts.has(inst):
			picked.append(inst)
	_check(not picked.is_empty(),
			("相⑦ ②前置:witness 真的捡走了一把(闪断时本端表 %d 件,其中 %d 件不在补态载荷里;"
			+ "0 件 = witness 那半没跑起来,② 会空转)") % [_p7_gw_before.size(), picked.size()])
	var after := _gw_insts()
	var left: Array = []
	for inst in picked:
		if after.has(inst):
			left.append(inst)
	# 主判据(按 inst 查):被捡走的那把必须**已经从本端表里清掉**。
	# ★ 这一条是"只 add 不 clear"那种实现的反向断言 —— 那正是**幽灵枪**的成因(枪画在地上、
	#   按 F 却无效,因为服务器手里早没了)。
	_check(left.is_empty(),
			"相⑦ ②:本端地面武器表里没有被捡走的那把(按 inst 查;被捡走 %s,仍残留 %s)"
			% [str(picked), str(left)])
	# 加强版:表里不得有**任何**补态载荷之外的条目(把 ② 从"这一把"扩到"全部")。
	var ghost: Array = []
	for inst in after:
		if not _p7_sync_insts.has(inst):
			ghost.append(inst)
	_check(ghost.is_empty(),
			"相⑦ ②:本端地面武器表 ⊆ 补态载荷(幽灵枪一条都不许有;多出来的是 %s)" % str(ghost))
	# ★ 主判据的另一半(必须有):上面两条都是**对 `after` 的过滤**,于是"清得对、但一把都没灌回来"
	#   (`after == []`)时两条**同时空过** —— 而那个回归是用户可见的:重连之后客户端**一把地面武器
	#   都没有**(服务器手里那 10 把一把也看不见、也捡不起来),本相却照样打印 ALL-OK。
	#   判据就是两边的**规模**相等(配合上一条"⊆"即集合相等)。
	#   ★ 为什么不会被"补态之后又新生成了一把"打红:窗口内服务器只被喂枪
	#     (`--test-ground-teleport` 只挪不造),witness 早在本相前半段就收手(`_p7_my_removed` 非空即 return)
	#     → 从补态到断言之间不会多出条目。
	_check(after.size() == _p7_sync_insts.size(),
			("相⑦ ②:本端表与补态载荷同规模(先清后灌的**灌**那一半必须落地;本端 %d 件 vs 载荷 %d 件 —— "
			+ "清了却一件都没加回来时,上面两条断言会同时空过)") % [after.size(), _p7_sync_insts.size()])
	# 一行读得出的汇总(进客户端日志;断言逐条的读数在上面各条 OK 行里)
	_log("相⑦ 汇总:%s 闪断时 %d → 补态后 %d;地面武器 闪断 %d 件 → 载荷 %d 件 → 现 %d 件(被捡走 %s)"
			% [str(P7_CELL), _p7_grid_before, g_now, _p7_gw_before.size(), _p7_sync_insts.size(),
			after.size(), str(picked)])


# 本端 grid 上那一格的值(-1 = 越界/网格还没建好;EMPTY=0 见 MazeGenerator)。
func _p7_grid() -> int:
	var grid := MazeGenerator.current_grid
	if grid.is_empty() or P7_CELL.y < 0 or P7_CELL.y >= grid.size():
		return -1
	var row: Array = grid[P7_CELL.y]
	if P7_CELL.x < 0 or P7_CELL.x >= row.size():
		return -1
	return int(row[P7_CELL.x])


# 本端地面武器表里的 inst 集合(补态前后各取一次,见 `_p7_assert`)。
func _gw_insts() -> Array:
	var out: Array = []
	var f = _game.get("ground_weapons") if _game != null else null
	if f == null:
		return out
	for e in (f as GroundWeaponField).entries:
		out.append(int(e["inst"]))
	return out


func _gw_size() -> int:
	var f = _game.get("ground_weapons") if _game != null else null
	return (f as GroundWeaponField).size() if f != null else -1


# ── witness(c2/r2):相③(盯 role1 的身体)──
func _witness_tick(el: float) -> void:
	if el >= W_END and _samples_open:
		_samples_open = false
		_witness_assert()
	if not is_royale:
		_p7_witness_tick(el)   # 相⑦ 的"制造变化"那半(仅 1v1)
	if drop_permanently and not _perm_dropped and el >= T_W_DROP:
		_perm_dropped = true
		# 相④:永久掉线(**不 reclaim**)—— 真 ENet 断开,服务端侧进宽限、到点收场。
		# ★ `NetBus.stop()` 不发 `server_disconnected`(见探针文件头),所以客户端的重连循环
		#   不会启动 —— 这正是"掉线后不回来"该有的样子。
		_log("永久掉线(NetBus.stop,不 reclaim)")
		NetBus.stop()
	if el >= T_W_END:
		_finish("")


# ── 相⑦(witness 侧):在 actor 的掉线窗口里捡走一把枪(= 制造"世界变了") ──
# ★ 为什么必须借**脚本手柄**而不是 `Input.action_press("F")`:F 的读口是
#   `is_action_just_pressed`(`local_input_source.gd`),而 `Input.action_press` 的"刚按下"
#   只在**按下那一帧**成立 —— 观察者的 `_process` 与对局场景的 `_physics_process` 不同帧,
#   从 `_process` 里按会整个错过(恒不生效、且一条报错都不给)。本仓既有的做法就是这份手柄
#   (`tests/ground_bot_input.gd`,`ground_net_probe` 用它在真对局里按 F / 长按 Q)。
#   ★ 顺序也承重:观察者挂在 root 上、比当前场景先一步,所以这里 `press_f()` 打的边沿会被
#     本帧 `pvp_match_client._physics_process` 的 `pack_record` 读走并上行(与 ground_net_watcher 同)。
func _p7_witness_tick(el: float) -> void:
	if _game == null:
		return
	if _bot == null:
		if el < W_START:
			return
		var lc = _game.get("_local")
		if not (lc is Node):
			return
		var bot = BotInput.new()
		(lc as Node).set_input_source(bot)
		_bot = bot
		_pickup_t = el + 0.1
		_log("相⑦:已接管本地输入源为脚本手柄(地面 %d 件),将在 %.1f~%.1fs 窗口里按 F"
				% [_gw_size(), T_W_PICKUP, T_W_PICKUP_END])
		return
	if el < T_W_PICKUP or el > T_W_PICKUP_END:
		return
	# ★ 只捡**一把**就收手:相⑦ 要的是"世界变了一次"。`--test-ground-teleport` 每帧都会把
	#   新的一把喂到脚下,不喊停的话每 0.35s 再捡一把,到第 5 把还会撞上背包的 4 把上限、
	#   走"替换 → 把换下的丢回地上"那条岔路(凭空多一条 weapon_spawned),于是"被捡走的那把"
	#   从一把变成一串 —— 判据不会错,但报告里说不清是哪一把。
	if not _p7_my_removed.is_empty():
		return
	if el >= _pickup_t:
		_pickup_t = el + PICKUP_RETRY
		_bot.press_f()
		_log("相⑦:按 F(el=%.2f;地面 %d 件,服务器已广播「我捡走了」%d 次 %s)"
				% [el, _gw_size(), _p7_my_removed.size(), str(_p7_my_removed)])


# 相⑦ 的交叉证据:服务器广播「这把是谁捡走的」时带 `by_role` —— 与本端 role 一致的那些
# 就是**我**捡走的。actor 那边没有这条事件(它掉线中收不到),它靠"闪断时表里有、补态载荷里
# 没有"反推出同一个 inst;两条路对上的那把才是"变化确实发生在窗口内"的证据。
func _p7_on_removed(data: Dictionary) -> void:
	if int(data.get("by_role", -1)) != int(PvpSession.role):
		return
	var inst := int(data.get("inst", 0))
	_p7_my_removed.append(inst)
	_log("相⑦:服务器广播「我捡走了」inst=%d(地面剩 %d 件)" % [inst, _gw_size()])


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
	# ── 相⑦(witness 侧):"我确实捡走了一把"的**交叉证据** ──
	# `_p7_my_removed` 原先只进日志、没有断言消费 —— 于是"按 F 那一半根本没生效"(服务器一次也没
	# 广播过 by_role == 本端 role 的 removal)时,actor 那边只会看到"② 前置:witness 没捡走任何
	# 一把"而报红,读的人分不清是"witness 没按"还是"按了但服务器没认"。这一行把它变成结论。
	# ★ 门控 `not is_royale`:相⑦ 只跑 1v1(订阅与 `_p7_witness_tick` 同样门控,见 `_ready`)。
	if not is_royale:
		_check(not _p7_my_removed.is_empty(),
				"相⑦(witness):服务器广播了「我捡走了」(by_role == 本端 role 的 weapon_removed 一次都没有 = 按 F 那半没生效)")


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
