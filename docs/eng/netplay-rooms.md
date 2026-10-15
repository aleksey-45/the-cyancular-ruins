# 联机:房间寿命 / 回收判据 / 回大厅后回局

> **本文件从 [`netplay.md`](netplay.md) 拆出**（2026-10-13,理由同上）。覆盖:对局中的房(寿命、回收梯、
> 可见性与拒绝)与**凭据表 / 「列表里自己那间房」**(阶段 2-B)。
> ★ 端口池常量与三档延迟的**唯一来源**是 `server/lobby/worker_launcher.gd`;约定文档见
> [`room-lifecycle-conventions.md`](room-lifecycle-conventions.md)。任何冲突**以源码为准**。

#### 对局中的房:寿命 / 回收判据 / 可见性与拒绝

- **★ 对局中的房(`started` / `in_match`)寿命改到「worker 进程退出」**;回收由 **`RoomManager._reclaim_finished_matches`**(30s 梯,`MATCH_SWEEP_INTERVAL`)按 **worker 进程还在不在**判 —— 那是三种模式**唯一的精确界**(三模式的 worker 都在对局结束时自己退)。★★ **兜底仍是既有的 2h 超龄清扫**(`_sweep_stale_rooms`,连 worker 一起杀),**两条路径并存、不是二选一**。判据落在 `RoomManager._match_over(port, pid)` + `WorkerLauncher.pid_alive(pid)`。
  - ★ **为什么不按宽限期收**:宽限期是 **worker 侧**状态,**大厅看不见**;照"开局后宽限期到点就收"做会把房在开打 60 秒后拆掉,而**一局打到中段掉线的玩家再也回不去**。故判据**刻意不读**宽限期。
  - ★ **代价照实登记**:双方都在 `go_match` 后立刻消失时,那一个 worker 与那一个端口会白占到 **2h 兜底**为止(玩家侧有 12s 转连 / 25s claim 兜底,不会卡住)。
  - ★★ **pid 复用是这套判据的已知边界**(照实登记,**不修**):`WorkerLauncher.pid_alive` 就是 `OS.is_process_running(pid)`,而 **pid 复用在本机实测过「几分钟内」就发生**。**误判方向是"多留"而非"错杀"**(降级成 2h 兜底,不会拆掉正在打的局),但实测的复用率让这条降级**是常态而不是罕见**。
  - ★ **1v1 worker 的报到超时梯**:`server_main._process` 补了**第四支** —— worker 就绪后 30s 仍无人 `claim_role`(且 `_host == null`、未开局)即打印超时并 `quit(0)`。★★ **门必须是「正的 worker-only 标志」**(`var _worker := false`),**不得写成"以 worker-only 标志的否定为门"**:后者在**大厅里恒真**。★★ **新登记:`server_main._process` 的四支梯子必须门在「正的 worker 标志」上,因为"以 worker-only 标志的否定为门"对大厅恒真。** 实测:第四支梯一度写成三个否定的合取时,**大厅四项全成立** ⇒ `start_server.bat` 起的专用大厅**开机 30 秒后打印报到超时并 `quit(0)` 自杀**,7777 上的建房/配对/转连全部死掉。修法两层:**① 把大厅分支整体 `set_process(false)`**(把"非 worker 进程进梯"整类**结构性地**关掉)、**② 把门换成正的 `_worker`**。★ **为什么自动化照不到**:`duel_spawn_timeout_smoke`（已删·2026-10-09） 起的是**带 `--worker` 的 worker**,**结构上永远进不了大厅模式**。★★ **哪一条是承重的:③(`set_process(false)`)而不是 ①②** —— `_worker == false` 与 `_worker or …` 两种写法**都能过 ①②**,真正把"大厅进程进梯"**结构性地**关掉的是 ③。**别把 ①② 读成主保险**。
- **★ 列表可见性与拒绝入房是同一件事的两半**:列表载荷各加 **`in_match` 键**(三模式同名同义、加法式扩展),列表构造抽成 **`LobbyRooms.room_list_payload()` / `royale_list_payload()` / `team_list_payload()` 纯函数** —— ★ 因为 `NetBus.reply` 在无对端时**静默跳过**,不抽成纯函数探针就**观测不到列表内容**。三模式拒绝文案统一成「**该房间的对局已进行中,无法加入**」;★ **`mp_lobby._on_server_message` 的自动刷新分支只认旧文案**,新文案落进 `else` **只显示不刷新** —— **改文案 = 静默改行为**,`room_sweep_lint` 有源码级断言钉住三条文案与三条守卫。
  - ★ 拒绝那一半的探针用**非满房**造(用满房造会被「房间已满」喂绿,等于没验)。
- **★ 房记录上多了两个字段**:① **`worker_pid`** —— spawn **成功之后**登记(四处),**`0` = 拉起中,一律判"没结束"**(位置不能挪到 spawn 之前)。② **`roster`** —— **开局那一刻**由 **`LobbyRooms.freeze_roster(room)`** 冻结的 `[{role, name}]`。★ **名单必须冻结**:成员转连后 `players` 会空、`_peer_names` 会被擦掉,读它们只会渲染出「玩家, 玩家」。列表行的**人数与名字都取自 `roster`**。
- **`WorkerLauncher` 多了端口→pid 表**:`pid_of(port)`(未登记 / 已归还 ⇒ 0)与 `static pid_alive(pid)`(`pid <= 0` ⇒ false)。★ `release_now` **必须同时清 pid** —— 只清一半会让一个已经结束(甚至端口已被复用给别的局)的对局被判成"还在",房永不出现在回收名单里。
- **三张注册表仍然各管各的**(房号空间重叠是既有事实),★ 别为"看得见"去合并三张表,那正是「按 code 撞库会拆错房」那个老坑(判据只能是 `room is RoyaleRoom` / `room is TeamRoom`)。
- **★ 守缺口照实登记**:本批**没有**真链路探针覆盖「线上投递的 `in_match` 行 + 真的拒绝」。那一半由后继回局计划的 `tests/probe/rejoin_probe.tscn` 相 c3 覆盖。
- ★★ **本批的两个「假绿」陷阱**:① **`tools/room_sweep_lint` 的 `_check_*` 出错不会让它变红** —— GDScript 的脚本错误**不给 `_fail` 赋值**,只让**出错的那个函数当场结束**,调用方照常往下走 ⇒ **verdict 仍是 OK**,那一组断言被静默跳过。**已堵**:每个 `_check_*` 末行把**本函数名**记进 `_done`,`_finish()` 拿 `CHECK_NAMES` 对账,名单不全即红(另加一条反向:实跑条数 ≠ 名单长度也红)。② **`tests/probe/lobby_visibility_probe`（已删·2026-10-09） 相④ 是「手工调」`_reclaim_finished_matches()` 的** —— 把 `_process` 里那次**接线**删掉,行为探针**照样 `ALL-OK`**,而生产里房永远不会被回收。**已堵**:`room_sweep_lint._check_reclaim_ladder` 的**源码级**接线断言 + 一条反向(回收不许绕道直接删注册表)。
- **用户自跑的真协议回归**:`tests/smoke/pvp_room_smoke.sh`(建房→配对→`go_match`;**红了先看 `on_peer_left` 的 `if room.started: continue`**)。★★ **订正(2026-10-13)**:这里原先还写着一个 `tools/room_sweep_lint.sh` —— **那个包装脚本不存在**(`tools/` 下没有它)。规范检查器本体是 `tools/room_sweep_lint.gd`,跑法 `"$GODOT" --headless --path . -s res://tools/room_sweep_lint.gd`,**不碰任何端口**,agent 可直接跑。

#### 回大厅后回局(阶段 2-B:凭据表 / 「列表里自己那间房」)

**路径乙**:在局内按 ESC 回主菜单之后,玩家凭一份**凭据**回到**原来那一局**。★ 它与阶段 1(路径甲)**不是同一条路**:路径甲是闪断后自己连回**同一个端口**、**不切场景**;这条路**会重建场景**。它成立的前提是**服务器那具身体从未销毁**。★ 本批**不新增任何场景/RPC 路径** —— 大厅的应答复用的是 `go_match`(**`NetBus` 的方法表一个字没动**)。

- **★ 入口不是按钮,是房间列表里「自己那间房」那一行**(用户裁定:「不能有回到对局按钮」「玩家必须自己找到对应的房间」—— **别再把它做成主菜单按钮**)。统一大厅的行渲染**与行被按下共用同一个判据** `PvpSession.can_rejoin_to(code, mode)`(★ **模式也要对** —— 三张注册表的房号空间共用);对局中的房那一行**对持凭据的本人可点、对别人照旧 `disabled`**。
  - ★★ **问这两问的次序是承重的**:"是不是我的房 + 凭据还在"必须**先于**"`in_match` ⇒ disabled"被问到。写反 = **回局入口连点都点不到,而一行报错都没有**(表现只是"回到大厅后自己那间房是灰的")。★ 交换同一个布尔的左右操作数(`not mine and in_match`)不是次序反转(真值表逐行相同);真正会翻车的唯一写法是把它拆成前置守卫。★★ **Task 7 实测过这条次序反转的可见度:当时全部既有测试面一条都没红** —— 五个探针/冒烟 + 四个场景加载,逐条 `ALL-OK` / `EXIT=0`。**唯一咬得住这一档的是当时新加的相⑧**(`lobby_visibility_probe`（已删·2026-10-09）,现 `EXPECTED_CHECKS` = 38;含一条**独立的正向对照**"普通未满的房仍可点" —— 缺了它,把判据写成 `not mine` 一类会让**正常加入整个坏掉**而全绿)。
  - `PvpSession` 的 `room_code` / `rejoin` 两个字段 + `can_rejoin()` / `can_rejoin_to(code, mode)` / `clear_rejoin()` / `note_room(code, mode)`;`room_mode`(凭据属于哪个模式)+ `entry_mode`(进大厅时的初始筛选,★ 与 `room_mode` 语义不同)。★ `enter_mode(m)` 与 `PvpSession.mode` **已整体删除**。★ `clear_rejoin()` 与 `reset()` **分开**(后者会把 `server_address` 也拨回云默认 = 把人踢到另一台机器)。
  - ★★ **凭据必须活过"回主菜单 → 再进大厅页"那一拍,别再往 `reset()` 里加清凭据的行**(C1 的整条修复)。原稿曾让 `reset()` 一并清凭据,而**主菜单那颗「多 人 模 式」每按一次就调它一次** ⇒ 从对局按 ESC 回主菜单、再按「1 v 1」时凭据**正好在那一拍**被抹掉 ⇒ 自己那间"对局中"的房在列表里**恒为灰、点不动**(表现就是"回不去",一行报错都没有)。**凭据真正的死处只有四类,全部落在 `clear_rejoin()` 的调用点上**:① **换房号或换模式**(`note_room` 的两个参数)/ ② 大厅答"回不去了"(`_on_rejoin_denied`)/ ③ 回局 15s 无应答(`_tick_rejoin_timeout`)/ ④ 玩家进了**另一间**房(`note_room`)。守卫:`reconnect_smoke.gd`（已删·2026-10-09） §④(**反向**断言 `reset()` 不许碰凭据)。
  - ★★ **凭据自带模式(2026-10-03 改)**:`PvpSession.room_mode` 记下「这份凭据属于哪个模式」,由 `note_room(code, mode)` 在**进房那一拍**写入;`can_rejoin_to(code, mode)` 房号与模式**都要对上**。★ 它取代了原先的 `mode` + `enter_mode(m)`(那套的写入点是**主菜单三个联机按钮**,而合一后没有那三个按钮了)。★ 判据仍然是**三张注册表共用同一个 4 位房号空间**:不判模式时,你在 1v1 攒下的 `room_code` 会让**同号的 3v3 房**看起来像「我的房」。★ **换了房号或换了模式才 `clear_rejoin()`;同房号同模式重进必须留着**。守卫:`reconnect_smoke`（已删·2026-10-09） + `lobby_visibility_probe`（已删·2026-10-09） 相⑦d。
  - ★ **服务端那一半不是判据**:三条 join 守卫保持"对局中即拒绝"(有源码断言钉着),**刻意不含凭据分支** —— "是不是我的房 + 凭据还在"只存在于客户端渲染与 `try_rejoin_row`。
- **回局路径 = 复用 `go_match`**:点行 → `LobbyPage.try_rejoin_row(code, in_match, mode)`(返回 true = 已走回局,调用方**不再**走普通加入)→ `rejoin_request(room_code, token)` → 大厅 `LobbyRooms.on_rejoin_request` 查凭据表 → `NetBus.reply(caller, "go_match", role, port)` → 客户端与首次进场**逐字同一条路**。★ 第二个入参 `in_match` 是**只有"我的房 **且** 对局中"才走回局** —— 只看凭据的话,**自己那间还没开局的等待中的房**也会走回局,而那种房在大厅侧没有凭据表条目 ⇒ 必收一句与眼前这间房无关的"凭据失效",**普通加入那一半还不发生**。
  - **唯一分叉在认领那一步**:`_claim_role_worker` 看 `PvpSession.rejoin`,发 `reclaim_role` 而不是 `claim_role`。★ **走错那一条的失败是"静默"、不是"被踢"**:`server_main._begin_match` 在开局那一刻就 `NetBus.role_claimed.disconnect(_on_role_claimed)` ⇒ 迟到的 `claim_role` **根本没有收件人**,既不踢也不打印;可观察的后果是"**这个客户端再也回不来**"。
  - ★★ **`_do_go_match` 里"只在真收到新 token 时才覆盖"那一行是承重的**:回局路上大厅**不重发** `session_token`(客户端手里那份**就是**凭据本身),无条件覆盖会把唯一能证明"我是原来那个人"的串抹成空 → `reclaim_role` 必被 worker 按"令牌不匹配"拒**并踢连接**,现场一个字都没有。真链路反证实测(删掉那行 → worker 打印 `令牌不匹配`)。
  - 客户端三条兜底:`_request_rejoin` 发前判活(回局入口**刻意不走 `_with_lobby`**,那条路会 `NetBus.stop()` 重连一次,把刚拿到的列表连同自己那一行一起丢掉)/ 大厅 15s 无应答 / 大厅答"回不去了"(`_on_rejoin_denied`:清凭据 + **重拉列表**)。
- **凭据表 `server/lobby/rejoin_registry.gd`(`RejoinRegistry`)**:token → `(code, role, worker_port, worker_pid, expires_at)`。★ 它**独立于房对象**(回局的查询要在大厅侧**活过拆除**);三个房类原先各有一份 `tokens` 字段**已随本批删除**。★ 纯逻辑、**不读时钟**(`now` 由调用方传)⇒ `-s` 可测。
  - **判据是纯函数 `RejoinRegistry.decision(entry, code, worker_alive)`**:返回 `""` = 放行,否则是给玩家看的拒绝理由。★ 三种拒绝**顺序有意义**("凭据根本不存在"必须先于"房间号不符")。
  - **`TOKEN_TTL_SECONDS`(1h)只是表的 GC 上界,"这一局还在不在"由 `worker_pid` 的活性回答**。★ 分工的理由:"一局打多久"三模式各不同、且**没有可读常量**,而"worker 退了吗"精确且与模式无关。★ TTL **不得短于宽限期**(跨文件不变量,`rejoin_registry_smoke`（已删·2026-10-09） ②b 钉住)。
  - ★★ **作废该房凭据走 `rejoin.drop_port(worker_port)` —— 键是 worker 端口,不是房间号**:三张注册表的房号**共用同一个 4 位空间**,按 `room.code` 反查会**误伤同号的另一间房**(实测:按 code 作废一次清掉 **2** 份凭据、按端口只清 **1** 份 —— 而失效那间的玩家只是"回不去",**一行日志都没有**)。★ 端口**每间房独占** ⇒ 它是那张表上唯一可用的键。★ `drop_port` 对 `port <= 0` **一律什么都不清**。守卫 `rejoin_keying_probe.tscn`（已删·2026-10-09）:**两个方向都断**。
  - **表的 GC 搭 30s 回收梯**(`RoomManager._reclaim_finished_matches` 首行 `lobby.rejoin.prune(...)`),**不另立定时器**。
- ★ **私密房玩家的回局入口(2026-09-29 用户改判并已落地)**:**私密房只对本人列出**。★ **身份只能靠凭据、不能靠 peer**(玩家转连 worker 时大厅那条连接早就断了,`players` 也被摘干净)⇒ 判据是 **`RejoinRegistry.owns(token, code, now_ms)`**:这份凭据是不是**这一间房**的。★ 它**只看 TTL、不看 worker 活性**(列表只回答"要不要给你看那一行")。
  - **改动面刻意收窄**:两份载荷与两个 handler 各多一个**带默认值**的 token 参数(**不传 = 与从前逐字相同**);`NetBusExt` 的 `royale_list` / `team_list` 各多一个 `token` 形参(★ 改的是 **NetBusExt** —— **原版 `NetBus` 的方法表一个字没动**);统一大厅请求列表时带上 `PvpSession.token`。**客户端行可点性无需改动**。守卫:`lobby_visibility_probe`（已删·2026-10-09） 相⑨(7 条,38 → **45**)+ `rejoin_registry_smoke`（已删·2026-10-09） 段⑦(5 条,7 → **8**)。★ 相⑨ 的**正向对照**(公开房对无凭据者照列)与 **3v3 同款**两条都不是客套。★ 照实登记:`owns` 里 `token.is_empty()` 那个早退**今天是一根保险带,不是承重件**。
- **★★ 已知边界与守缺口(照实登记,别读成"已修好")**:
  - **回局只在宽限期内真正成功**:宽限到期后 worker 会 `mark_disconnected` 或收场退进程,而届时大厅**仍可能放行**,客户端连过去会被 `_on_reclaim` 的判据②**踢连接**。
  - **pid 复用**:与 §对局中的房 登记的是**同一条已知边界**(**别在两处各写一份**)。
  - ★ **`_request_rejoin` 的判活守卫没有任何行为面证据**:它那条**假分支**只有"点那一行的那一刻大厅连接已经断了"才进得去,而那一刻它会**真的开一次大厅连接**(统一大厅默认还是云地址)⇒ 拿它做断言等于让探针去连**用户自己的服务端**,故**探针明令不碰**。登记为**环境缺口,不是探针缺口**。
  - **引擎自己那条 `max channels: 0`**:回局那条路同样会踢连接,**已登记、不修**。
  - **`ai_duel` 那条 spawn 路径不登记凭据**:`RoomManager.ai_duel` 既不发 `session_token` 也不调 `_grant_rejoin`,且**开局即把房从注册表摘除** ⇒ **AI 对战局没有回局入口**。照实登记,不修。
- **守卫与判词**(判据一律是**文本**,不看退出码):`rejoin_registry_smoke.gd`（已删·2026-10-09）(`-s`)→ `REJOIN REGISTRY: ALL-OK`(段数对账 7/7)/ `rejoin_keying_probe.tscn`（已删·2026-10-09） → `KH REJOIN-KEY PROBE: ALL-OK` / `tests/probe/rejoin_probe.tscn`(+ `rejoin_watcher.gd` + `rejoin_probe.sh`)→ **`REJOIN PROBE: ALL-OK`** —— 真链路**三端**(c1 = actor 离场再回局、c2 = 见证端、c3 = 第三人看得见进不去),自当大厅与裁判(**池外端口 29300;worker 起投 29350**),★ **不占也不杀 7777**。
  - ★★★ **c1 的两次进场都走生产入口**:`_enter_main_menu()` → **按主菜单上那颗「1 v 1」**。**曾经它绕过主菜单直接挂页**,而主菜单那一步**正是** C1 抹掉凭据的那一步 ⇒ 唯一会红的观测者刚好绕过了唯一会红的那一步。守卫是**反证**:把 `reset()` 清凭据那四行放回去 ⇒ 探针红。★ 两个**探针自身的**坑:① **`freed_node == null` 在 Godot 4.7 是 `true`** —— 判"页还在不在"只能用 `is_instance_valid()`;② **相 0 的推进条件只能是"真进了对局"**。★ **用户跑**(整跑约 60~110 秒;收尾**按 PID** 杀子进程)。
  - 既有探针被本批**加相**:`lobby_visibility_probe`（已删·2026-10-09）(相⑤⑥⑦⑧⑨)/ `grace_window_smoke`（已删·2026-10-09）(⑧ 钉 `DEFAULT_SECONDS` + 三档延迟的 belt;⑨ **按宽限期算出来的跑批预算逐条钉住**。★ 落伍的症状不是"红一条断言",而是**探针自己先到点:一行裁决都不打印**,与真失败**长得一模一样**;这个坑**已烂过两次**)。
  - ★ **跑法分工**:agent 可跑 = `--import`、全部 `-s` 冒烟、`lobby_visibility_probe.tscn`（已删·2026-10-09）、各页面 `--quit-after 120` 启动自检;**用户跑** = `rejoin_probe.sh`、`reconnect_probe.tscn`(池外端口,但耗时长且按 PID 杀子进程)、以及一切占 **7777** 的既有脚本。★ **加新断言时留意 `EXPECTED_CHECKS` 那类计数**。

---

## 实测读数与不变量（2026-10-13 从**代码注释**搬出）

> 原始台账（带原行号与出处）：[`2026-10-13-comment-diet-ledger.md`](../2026-10-13-comment-diet-ledger.md) §4 / §7。
> ★ 房间/端口相关的**约定**在 [`room-lifecycle-conventions.md`](room-lifecycle-conventions.md)；
> 这里放的是**读数与判据**。

- **`ROYALE_MATCH_TIME_CEILING` 是两环链**：`settings` 侧钳位 + `mp_lobby` 的秒换算。
  残余暴露 **~3~25s**（两端各自钳一次，中间没有第三次校验）。
- **1v1 刻意没有"在局宽限"**：房龄 ≥2h + 一局几分钟 ⇒ 量级够不着。★ 但同一"开局转连窗口"
  在 1v1 里**同样成立** ⇒ 要收紧得**另行评估**（已登记债务，别当遗漏）。
- **凭据表 GC 搭在 30s 回收梯上**（不另立第二个定时器）—— 这是"少一个定时器"的取舍，不是省事。
- **`new_token` 的实测**：12 次抽样里 **8 次**落 **int64 负半区**（`%x` 带符号打印出来是负的）；
  2 万次抽样下两段 `%08x` 的**长度恒为 16** ⇒ 拼接口径（长度）可信，**数值符号不可信**。
- **`RoyaleRoom.match_time` 与 `player_options.match_time` 是"同一处两真值"**：改一个必须看另一个
  （重复真相源的候选，见 [`debt/duplicate-truth.md`](debt/duplicate-truth.md)）。
- **三张注册表的房号空间重叠**，且**三表的"房主"表示不同**（1v1 那张没有 `host` 字段）⇒
  任何"按房号找房 + 读房主"的代码都要分别处理；**回局路径乙的已知边界**：认领时已不在宽限期
  ⇒ worker 的 `_on_reclaim` 会踢连接。
- **`join_room` 在"已在房里"时的后果链**：`player_role` 从 1 **覆盖成 2** ⇒ 同一个 peer 占两个 role、
  worker 侧两个 role 指向同一 peer、**输入只喂得到 role 1**（这是"拒绝进房"那条判据的理由）。
- **`_flush_*_state` 实测**：断开信号**滞后超过一帧**；6 人局开局瞬间出现 **5 条 `max channels: 0`**。
- **`on_room_map` 的取舍**：不回话、不踢人，且**刻意不判空房**（空房让它自然被回收梯收走）。
- **`rejoin_registry` 的沿革**：`tokens` 字段原先住在 `Room`/`RoyaleRoom`/`TeamRoom` 三处，
  随 Task 4（2026-09-21）**整体删除**（`grep '\.tokens'` 今天 0 命中）；TTL 取 **1h** 的理由是
  与"房龄 ≥2h"同量级 —— **TTL 不是回局判据**（回局还要过宽限期与凭据），端口也不是通配。
- **`ai_duel` 的真实可达路径**（登记，未修）：已配对开局的 1v1 房在 `go_match` 后、
  `on_peer_left` 摘除前收到 AI 请求 ⇒ 再拉一个 worker **覆盖 `worker_port`** ⇒ **首个端口无人归还**；
  该 RPC 是 `any_peer`，暂无界面调用点。
