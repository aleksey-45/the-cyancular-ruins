# 联机:断线重连(阶段 2-A / 2-B / 3)

> **本文件从 [`netplay.md`](netplay.md) 拆出**（2026-10-13）。**为什么拆**:原文件 59 KB,已到
> `CLAUDE.md:5` 那条 64KB 预算线的 92%,再加内容就会**自己越线**（后半本被截断 = 没写）。
> **怎么用**:重连相关的判据、状态机与已知缺陷都在这儿;匹配进图与通道表见
> [`netplay.md`](netplay.md) 与 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)。
> ★ 任何冲突**以源码为准**（`scenes/pvp_match_client.gd` / `server/`）。

#### 断线重连

**路径甲(阶段 1)**:与 worker 的连接闪断 → 客户端自己**连回同一个端口**、重新认领 role、**不切场景、不重建世界**。★ **路径乙(阶段 2-B)是另一条路**,见下节。★ **阶段 3** 见再下一节。

- **token 由大厅生成,不在 worker**:`NetBusExt` 的三条新 RPC(`session_token` / `report_token` / `reclaim_role`)+ `core/net/pvp_session.gd` 的 `token`/`worker_port`。★ **必须在 `go_match` 之前发** —— go_match 一到客户端就 `NetBus.stop()` 断大厅,之后再发就**静默丢失**。客户端 claim 之后经 `report_token` 报给 worker,worker **只归档不校验**;校验发生在宽限期里的 `reclaim_role`。★ **`go_match` / `claim_role` 的签名一律没动**:原 NetBus 与原版服务端逐字节一致是硬纪律(改 RPC 方法表 = 与它的所有 RPC 失联),故三条新 RPC 全在 `NetBusExt`;对原版 worker 本节点不存在 → 静默丢弃、优雅降级成"不能重连"。
- **宽限期唯一入口 `GraceWindow.DEFAULT_SECONDS`**(`core/net/grace_window.gd`,当前 **60s**,纯逻辑、时间由调用方传入):掉线**不立刻移出**(大乱斗)/**不立刻退进程**(1v1),到点才走既有语义(`server_main._expire_graces` 每秒轮询)。1v1 那一支到点是"收场退进程" = **对手白拿这一段**。★ 它同时是客户端重试预算的上界(`pvp_match_client._on_reconnect_retry_tick` 读**同一个常量**)。★ **2026-09-21:30 → 60,三模式统一**(用户为「回大厅后回局」裁定)。**原先那句「别再把时长放大」已作废**。★ **改这个数要同时看三处**:① 客户端重试预算(自动跟随);② **三个 `*_PORT_REUSE_DELAY` 必须严格大于它**(守卫 `tests/smoke/grace_window_smoke`（已删·2026-10-09） ⑧);③ **按宽限期算出来的测试预算**(`reconnect_probe`（已删·2026-10-09） 的 `GRACE_MIN/MAX`+`FINAL_TIMEOUT`、`team_match_watcher.OBSERVE_MAX`、`team_match_probe` 的 `RESULT_WAIT`)—— 漏改第三处会让**真链路探针先耗尽安全网、不打印任何 verdict**,按本仓判据读成红。
- **★ 掉线者的身体不销毁 → 服务端对局状态一条都不用恢复**:`server_main._on_peer_left` 只 `_claims.erase(role)` + `_enter_grace(role)`,**不碰 `players`**。分数/阵亡/血量/背包/位置/世界破坏/地面武器全在活着的节点与进程内存里。它同时是 1v1 能做重连的**前提**。
- ★★ **`_enter_grace` 必须同时做两件事:`input_sources[role].reset_state()` 和 `_host._pending_input[role] = []`**。**只做前者不够**:掉线瞬间队列里可能还压着一条**已经到达**的包,而 `apply_packet()` 是**整体覆盖** ⇒ 那条包会在复位**之后**把 `_held` 原样写回,之后队列空了而 `clear_edges()` **不含 `_held`** ⇒ 掉线前按着的键被**重新武装并保持整个宽限期**。★ 这个 bug 真发生过,**前 7 个任务的单元式验证全都没照出来,是真链路探针抓的**(守卫 `reconnect_probe`（已删·2026-10-09） 相③)。`_on_reclaim` 的接受路径有同一行。
- **worker 侧 `reclaim_role`(`server_main._on_reclaim`)三条拒绝条件一条都不能少**:①未开局 ②该 role **不在宽限期**里 ③token 不匹配 —— 任何一条不满足都**踢连接**(**不能让它静默留在局里收快照**)。接受后:重绑 `peer_by_role`、**把新 `PacketInputSource` 挂回那个还活着的玩家节点**(换表里的引用不够,玩家手里仍攥着旧源)、清 `_pending_input`、`_ack_seq[role]` 归 0,然后 `NetBus.reply(caller, "match_start", …)`(★ 走 `reply` 不走 `rpc_id`)。
- ★ **客户端同名纪律:同一个 role 只许发一次 `reclaim_role`**(`scenes/pvp_match_client.gd:_try_reclaim`,本功能最易写错且症状最怪的一处)—— worker 接受第一次时就 `_grace.leave(role)` 了,同一条连接上再发一次必进拒绝条件② → **它踢连接**,表现是"刚重连上几秒又断",看着像网络抖动;且因为 token 是对的,查 token 查不出问题。★ **两条时间尺度别合并**:`RECONNECT_RETRY_MS`(2s)= 节拍,`RECONNECT_ATTEMPT_TIMEOUT_MS`(5s)= 一次握手自己的寿命 —— 合并会反复掐掉正在握手的尝试;而**只**看节拍不掐尝试时,ENet 自己的连接超时实测 **~31.8s** ⇒ 最坏卡在冻结世界 ~33s。
- ★★ **重连成功必须重置本地 C2**:`_input_seq`/`_have_prev_seq`/`_prev_sent_seq` 清零 + **重建 `PredictionRollback` 并重新 bind + 设 `map_px`**(漏了**都不报错**:没 bind → `_p == null` 直接返回、C2 静默失效;没设 map_px → 跨接缝那一帧按裸距离比、白跑一次回滚)。★★ **重连后跨纪元的旧 ack 必须丢掉**(`_on_snapshot_own` 里 `ack > _input_seq` 即 return):握手落地到 `match_start` 到达之间客户端仍在用**断线前那个 seq 空间**发包,服务器下一 tick 消费到它就把 `_ack_seq[role]` 从 0 写回那个大数 → 那条快照落在**刚重建**的 rollback 上 → `_acked` 被抬到新纪元追不上的高度,之后所有真实 ack(1,2,3…)全丢,**断线前活了多久就哑多久**(症状:不报错、**回滚恒为 0**、`sync_soft_state` 不再被调)。★ **两侧的复位互为理由**(服务端归 0 是为了客户端的 `_acked`,客户端重置是为了服务端的 0),只改一侧会得到镜像的同一个洞;守卫 = 探针相① 的 `_acked ≤ _input_seq` 断言。
- **触发点只有"服务器断开"一条,而对局场景此前没人订阅它**:`NetBus.local_server_message` 的消费者原先只有 `lobby_page`,所以服务器一断客户端**毫无反应**。本批在 `pvp_match_client._subscribe_reconnect()` 里接上它,顺带接 `NetBus.local_match_start`(★ 那一条在对局里**此前零订阅者** —— 唯一消费者是 `lobby_page._on_match_start`,而对局场景里它不在树上 → 静默 no-op,故"重连成功"的收尾**必须**在这里接)。菜单开着时收到的断开**先不动、但不是放弃**:账记 `_pending_disconnect`,关菜单时 `_recheck_disconnect()` 补。★ 按 ESC 回主菜单**不会**触发重连(`NetBus.stop()` 把 `multiplayer_peer` 置空,引擎在 `set_multiplayer_peer` 里先 `clear()`、状态当场复位 → CONNECTED→DISCONNECTED 那一跃**从未被观测到**)。
- **三档端口归还延迟**(`server/lobby/worker_launcher.gd`:`WORKER_PORT_REUSE_DELAY` 1v1 = **120s** / `ROYALE_PORT_REUSE_DELAY` = 360s / `TEAM_PORT_REUSE_DELAY` = 360s)—— ★★ **它们今天都不再是"端口会不会被提前复用"的界**:房**活到 worker 退出**,而端口只在 `teardown_room` 里归还 ⇒ 归还是**从 worker 退出起算**的。于是"重连的客户端手里那个端口还在不在"由**凭据里的 `worker_pid`** 精确回答,与这三个常量取多少**无关**。★ **30 → 120 那段历史教训留档**(原 30s **等于**宽限期,而**相等同样不安全**),但那条不等式的**承重地位已被取代**,只剩 `tests/smoke/grace_window_smoke`（已删·2026-10-09） ⑧ 的一条 **belt**(三档必须**严格大于** `DEFAULT_SECONDS`)。
- **★★ 阶段 2-A(2026-09-18):重连成功后**也**要拉一次 `match_sync`** —— 这是本节**最反直觉**的一处。路径甲**不切场景、不重建世界**,很容易认定"没什么要补的":但**世界在掉线那段时间里变过** —— 对面把墙拆了、地面上的枪被捡走/丢出/换局重铺。★ **不拉不报错**,只是世界悄悄不一致:客户端留着服务器已摧毁的墙 = **幻影墙**(撞上去 → 本地预测与服务端分歧 → 滚回滚),或者本地凭空多/少几把枪 = **幽灵枪**(看着在、按 F 无效)。
  - ★★ **新的承重事实:补态这一次应答既不校正出生点、也不告警** —— 发送前置 `_resync_pull_pending`(由 `_on_resumed` 置位),被 `_on_match_sync` 首行读一次即清。★ **没有它,1v1 每局换边会让不一致必然发生** → 一条假告警 + 把玩家瞬移走。★ 这个局部量**读一次即清**,"再读一次来决定还原"会让还原被**静默跳过**。★ 大乱斗那一端走的是**同一个函数**,不存在"只补了 1v1"这种分叉。★ **本节引 `pvp_match_client` 一律用函数名/符号名、不写行号**。
  - **`match_sync` 的数据面因此长出两块**:① **`destroyed`** = `MatchHost.destroyed_cells()` —— `grid` 与建局基线 `_base_grid` **不同**的那些格(顺序确定,因为载荷要能在两端逐字比对)。★ 判据刻意取"**与基线不同**"而**不是**"当前为空"(后者在将来出现"加砖/复原"类改动时会**静默漏报**)。★ **空数组连键都不带**;规模上限 **841** 条 `Vector2i`。★ 投递时机只有**一处**:`match_sync` 应答。② 客户端应用走 **`_on_remote_tile_destroyed(cell, true)` 的静默形态**(那些砖是**掉线期间**被拆的 —— 不静默就会逐格播碎片粒子)。★ 复用它而**不另写一套**:那套顺序全仓只有一份。
  - **地面武器一律「先清后灌」**:★ **不清就直接 add,掉线期间已被服务器移除的那些会变成永久幽灵枪**。★ 进场那次本地本来就是空的,清一遍是 **no-op**,故不为两种情况分叉。
  - ★ **「只删不还」那半个缺口也已闭合**:`destroyed` 只表达「与基线**不同**」的格 ⇒ 被服务器换局还原掉的格**永不进载荷**,客户端会留下**幻影洞**。**现在**:补态那一路**先 `reset_destructibles()` 再应用 `destroyed`**。★ **顺序不可换**;★ **只在补态那一路做**。★ **仍剩的边界**:服务器今天**只拆不加砖**;若将来出现"加砖"类改动,客户端应用侧只有"拆"那一半 → 会留下**幻影墙**,那个方向本来就未闭合。守卫:`tests/probe/resync_world_probe.tscn`(★ 还原那一条**另跨两维**(墙体瓦片层 + `_destructible_sub` 子格),只断 `current_grid` 时"只改 grid、不重铺瓦片也不重建碰撞"会**照样全绿**)。
- 守卫:`reconnect_probe.tscn`（已删·2026-10-09） 是**真链路七相**端到端探针(自当裁判、三个端口**必须落在真大厅的 worker 端口池之外**;触发闪断用**直接调 `_game._begin_reconnect()`**):①正向(自动重连被接受,**身体 instance_id 不变**;另判 C2 锚点重新咬合 + 回滚次数不持续增长)②反向(错 token 被拒 + 踢连接)③身体冻结(掉线后该 role 的**快照 `pose` 离开 SQUAT** —— ★ 判据是**姿态**不是位移:撞墙/卡坑时 `global_position` 天然不变、能空转骗过)④超时移出⑤大乱斗相⑥启动等待态⑦**掉线窗口内世界变过**(含**反向断言**(被捡走那把在本地表里**必须没有**,专钉"先清后灌")+ **正向的规模断言**(本端表必须与补态载荷**同规模** —— 反向那条在 `after == []` 时会**一起空过**,那正是"一把枪都看不见却打印 ALL-OK"的假绿))。判据是**文本 `RECONNECT PROBE: ALL-OK`**。
  - ★ 相⑦ 的唯一失败模式是"假绿",两处专门守卫:① 服务端侧拆格走测试开关 **`--test-destroy-tile <col>,<row>[,<delay>]`**(与真爆炸**同一条广播链**);② 断言里必须含 **worker 日志的 `[test] 拆格` 那一行**(少了它,若那格本来就是空气,主断言会假绿)。★ **延迟取 7.5s 不是 3.0**:建局到 PLAYING 差一个 `COUNTDOWN_TIME`(3s),`3.0` 恰好落在 actor **还在线**的那一刻 ⇒ 相⑦ 以"全绿"通过而**什么都没验**。**跑前先确认无真大厅**(收尾**按 PID 杀**本进程拉起过的全部子进程)。

#### 阶段 3:可见性 + 两个既有缺陷

四处,三条互不重叠的链:

- **3.1 「掉线中」= `round_state` 长出 `grace` 字段**(`{role(int) -> 剩余秒(float)}`)。★ 它的**唯一出口是 `MatchState._send_round_state(data)`**(三个生产者 `MatchRound` / `RoyaleHost` / `TeamHost` 都调它)⇒ 生产目录里 `_rpc_all("round_state"` **除出口自身外零命中**(守卫 `tests/probe/grace_feed_probe`（已删·2026-10-09） 的 ④)。★ 那一处就是出口的**实现**,不是漏网的旁路,别照着"零命中"去把它删掉。读数的**持有者是 `server_main`**,它经 `_sync_grace_snapshot()` 把值**推进**宿主的 `grace_snapshot` 字段 —— **推**而不是"宿主去问",避免 back-reference。★ **空表不带该键**;三个客户端 + `match_result_payload` 都对缺键无感。★★ **1v1/3v3 不每秒广播 `round_state`** —— 三个客户端里有两处 `COUNTDOWN 且 round > 1` 的分支**不是幂等的**(`pvp_game` 会 `reset_destructibles()`、`team_game` 会重发 `match_sync`),每秒多播一次 = 倒计时 3 秒里那些活各干 3 遍。秒数由客户端**本地走秒**(`GraceWindow.tick_display`)。★ 3v3 **刻意不消费** `grace`,有反向断言钉住这个不对称是**有意**的。
- **3.2 + 3.4 「重连中」= `ui/hud/status_banner.tscn`(CanvasLayer layer 140)**,由**基类** `PvpMatchClient` 在**已有的** `_subscribe_reconnect()` 里实例化 ⇒ 三个模式**零新调用点**。**五个**转折点驱动:`_begin_reconnect`(断开被察觉就亮)/ `_on_reconnect_retry_tick`(报剩余预算)/ `_on_resumed`(收)/ `_cancel_reconnect`(收)/ `_abort_reconnect`(收)。★ 权威口径在 `ui/hud/status_banner.gd` 的 `set_text` 上方;`reconnect_status_probe`（已删·2026-10-09） 的相④**不手抄**这份名单,而是从「给 `_reconnecting` 赋值的函数」**推导**出全集 —— 故漏一个转折点时它红的是**推导面**。★★ 层位 **140 只住在 `.tscn` 里** —— `.new()` 建出来是 CanvasLayer 默认的 layer 1,画在 HUD(130)/小地图(131)**底下**且**不报错**;守卫 `tests/probe/hud_declarative_probe`（已删·2026-10-09） 的 ⑧。
- **3.3 `opponent_left` 不再是死路**:服务端调用点在 `server_main._notify_opponent_left()`,由 `_expire_graces` 的 **1v1 收场分支**在 `get_tree().quit(0)` **之前**调;只发给 `_claims` 里还在的人,走 `NetBus.reply`。★ 只在**收场**发、**不在 `_enter_grace` 发** —— 掉线时就宣告"对手已离开"会把阶段 1 的整条重连功能作废。★★ **两条时序都要收口**:通知先到 ⇒ 既有的 `_match_ended` 闸挡住重连循环启动;断开先到 ⇒ 只有 `_cancel_reconnect()` 能叫停已经在飞的那个循环。⇒ 不论谁先到,结局都是「2.5s 后回主菜单」,**不叠加一个 60 秒的重连循环**。

---

## 实测读数（2026-10-13 从**代码注释**搬出）

> 原始台账（带原行号与出处）：[`2026-10-13-comment-diet-ledger.md`](../2026-10-13-comment-diet-ledger.md) §5 / §7。

- **跨纪元 ack 的哑火窗口实测 ≈ 560 帧 ≈ 9s**（一局中段可以上万帧）。机制：服务器在 `_on_reclaim`
  把 `_ack_seq[role]` 归 0，而客户端要到 `_on_resumed` 才归零 ⇒ 中间那段**两端对不上**。
  ★ **症状全是不报错的**：回滚恒 0、`sync_soft_state` **不再被调用** ⇒ 地上的枪没了、手上也没多、还开不了火。
  ⇒ 排查这类"静默失联"要先看 ack 序列而不是先看坐标。
- **对手离开的两种到达时序**（通知先到 / 断开先到）**都必须收口**：前者的闸是 `_match_ended`，
  后者只有 `_cancel_reconnect()` 能叫停已在飞的循环。★ **60 秒那条路还有第二个后果**：
  它会把**刚建出来的主菜单**当成 `old` 退役（于是屏幕上"闪一下"）。
- **重连时间线**（ENet 自身超时 31.8s 与本机 33.8s）记在 [`netplay.md`](netplay.md) 的「实测读数」一节 ——
  那里是判重试预算的**唯一依据**。
