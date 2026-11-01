# 联机模块 bug 台账(2026-10-30)

> 配套:[00-总览与结论.md](00-总览与结论.md)(范围 / 落地顺序)、[01-代码与注释审查.md](01-代码与注释审查.md)(结构 / 注释 / 文档漂移)。
> 基线:工作树 `326d586b`(2026-10-30)。**本轮只审查、未修任何代码**;每条都写明"修之前先要什么证据"。
> 判据一律 grep 文本,不建议靠退出码;守卫建议一律先答"去掉什么它才会红"。

## 0. 口径

| 字段 | 取值 |
|---|---|
| 严重度 | **P1** = 玩家可感的错误状态 / 联机不同步 / 数据错;**P2** = 可观测但能绕过、或会静默吃掉某条路径;**P3** = 只影响维护与诊断 |
| 置信度 | **confirmed** = 已从源码路径推出触发链;**likely** = 路径基本清楚但有未验证前提;**suspect** = 现象可疑,需实测 |
| 来源 | **用户实机** / **本轮静态** / **旧报告复核**([`.superpowers/bughunt/REPORT.md`](../../../../.superpowers/bughunt/REPORT.md),2026-10-22) |
| 状态 | **待定位** / **待修** / **已修(本轮无)** |

合计:**23 条**(用户报 2 + 本轮新确认 21)。其中 P1 5 条、P2 12 条、P3 6 条。
**本轮已修 24 条**(2026-10-30 七批:B5 用户追加的 BUG-24 也在内);另登记 **BUG-25**(测试基建,已修,见 §2.9):第一批 8 条(BUG-02 / 06 / 11 / 13 / 15 / 16 / 17 / 19 泄漏面,见 [`registered-debt.md` §二十六](../../../eng/registered-debt.md));第二批 6 条(BUG-08 / 18 / 20 / 21 / 22 / 23,见 §二十九);第三批 1 条(用户实机报的 **BUG-01**,见 §三十);第四批 1 条(**BUG-07** 版本拒绝,随 B4 协议批 v7 落地,见 §三十一);第五批 1 条(**BUG-03** 重连补子格,见 §三十二);第六批 6 条(**BUG-04/05/09/10/12/14** 收尾,见 §三十三)。状态见各条标题。

---

## 1. 用户已报(待定位)

### BUG-01 ｜ P1 ｜ 每把枪械的子弹数量不独立(**已定位并修复 2026-10-30**)

**根因(已定位;与最初猜的三条候选都不同 —— 是"条目已被重建、却仍让 `_equip_index` 做残弹写回")**。
`WeaponComponent._equip_index()` 切枪时会把旧枪的 `mag_ammo` 写回 `inventory.held[_current_index]`;
但下面两处调用点**在调用之前就已经把条目换掉了**,于是写回落到**另一把枪**的条目上:

1. **`pick_up()` 的「背包满 ⇒ 替换手上那把」**(`weapon_component.gd:250-258`,旧实现):
   先 `inventory.held[_current_index] = {type: 新枪, inst: 旧, mag: 地面残弹}`,再 `_equip_index(_current_index, flush)`
   ⇒ 写回把**旧枪实弹**盖到刚写入的**新条目**上;随后 `_equip_index` 的 `pending_mag` 正是从该条目取
   ⇒ **新枪残弹 = 旧枪残弹**(地面那件的残弹被丢掉)。这是"背包满时捡枪,新枪子弹跟着上一把走"的现场。
2. **`random_keep_one()`(倒地随机保留一把)**(旧实现):替换 `held` 前不 flush 当前枪条目(条目陈旧 = 少扣刚打的发数),
   替换成 1 条后仍调**默认 flush** 的 `_equip_index(0)` ⇒ 旧枪实弹覆盖**保留那把**的条目;掉落的当前枪则带陈旧条目值。

**探针复现(未修状态,逐字)**:`KH gun_ammo_independence PROBE: FAIL | 新枪残弹必须来自地面那件(5),不能继承旧枪实弹(3);实得 3; 新枪的背包条目残弹也必须是 5(实得 3); 随机保留那把的条目残弹必须是它自己的(22,kept_idx=1);实得 7; 倒地掉落的当前枪必须带真实实弹 7(不是条目陈旧值 11),实得 [11, 33]`

**改了什么**([`weapon_component.gd`](../../../../scenes/player/weapon_component.gd)):
`_equip_index(index, flush_current: bool = true)` 增加"是否把旧枪实弹写回条目"的开关,并在注释里钉死两个 `false` 调用点的理由;
`pick_up()` 替换分支改传 `false`(旧枪实弹已由 `_last_dropped` 带走);`random_keep_one()` 先 `_flush_current_mag()`
(把当前枪真实实弹落进它自己的条目)再 `_equip_index(0, false)`。**档位**:单系统(玩法逻辑,不动协议/存档)。

**守卫**:新增 [`tests/probe/gun_ammo_independence_probe.gd`](../../../../tests/probe/gun_ammo_independence_probe.gd)(+`.tscn`,8 条 + `EXPECTED_CHECKS`):
① 背包满拾取替换 → 新枪残弹取地面值;② 新枪条目残弹也是地面值;③ 被换下那把带自己的实弹;④ 随机保留项条目正确;
⑤ 倒地掉落的当前枪带真实实弹(不是条目陈旧值);⑥ 对照:背包没满的拾取路径不变。
**变异验证(三条,逐条改坏确认红)**:`pick_up` 改回默认 flush ⇒ ①/② 红;`random_keep_one` 去掉 flush ⇒ ⑤ 红;
`random_keep_one` 改回默认 flush ⇒ ④ 红。还原后 `KH gun_ammo_independence PROBE: ALL-OK`。

**边界(照实)**:
- 同帧多次切枪的"未入树写回跳过"窗口(原候选 1)未单独改:它修的是"别把 0 写回",与本次的两处重建路径无关;
  真机可达但需要同帧两次切枪事件,已留 `_mag_ready` 抓手,登记为后续项。
- `restore_inventory`(回滚重建)后调用方 `equip_index` 仍会瞬时把旧实例实弹写进恢复条目;紧随其后的
  `apply_mag(st["mag"])` 会把它纠正回来、下一帧 capture 再 flush ⇒ **瞬时、自愈**,未改(见 §二十九 边界)。
- 原候选 2(C2 条目滞后)与候选 4(`pickup_sync` 缺 mag 默认 0)与本 bug 无关,仍可能各自独立成立,保留登记。

---
### BUG-02 ｜ P1 ｜ 结算页 MVP 总是标给败方(**已修 2026-10-30**)

**已复核、不成立的路径**(四段逐行核对,均无取反):

1. 计算:[`match_state.gd:253-273`](../../../../server/match/match_state.gd#L253) `mvp_role()` = ACS 最高 → kills 多 → deaths 少 → role 升序;**取最大**。
2. 载荷:[`match_round.gd:232-235`](../../../../server/match/match_round.gd#L232)(1v1)/ [`team_host.gd:242-245`](../../../../server/hosts/team_host.gd#L242)(3v3)只在 `MATCH_OVER` 带 `match_winner` 与 `mvp`。
3. 适配:[`match_result_payload.gd:20-99`](../../../../ui/screens/match_result_payload.gd#L20) `for_duel`/`for_team` 用 `int(round.get("mvp"))` 与 role 比较,★ 位置在**排序后**计算 → 行列不错位。
4. 渲染:[`match_result.gd:105-114`](../../../../ui/screens/match_result.gd#L105) `mvp.section == idx and mvp.row == ri`,逐行比对,无 off-by-one。

**一条数学排除**:1v1 里 `match_winner` = 局胜最多者,而局胜靠击杀;`kscore = kills×100 + assists×50 + dealt/5 − deaths×50`([`score_rules.gd:40-46`](../../../../core/sim/score_rules.gd#L40)),胜方 kills 更多、deaths 更少 ⇒ **stats 正确时 ACS 必高于败方,★ 不可能落在败方**。所以现象若成立,根因必然在下面三处之一:

- **(a) 口径差 —— 这就是根因(用户 2026-10-30 确认"明明赢了,全场最佳却是对面")**:`mvp` 与 `match_winner` 是两把尺子,旧实现只按 ACS 最高、**与胜负完全脱钩**。★ 本轮原先"1v1 胜方 ACS 必高"的数学推导**是错的**:局内比分可以极端(赢的局 5-4、输的局 0-5)⇒ 败方总 kills 更多、deaths 更少 ⇒ ACS 反超。用户裁定:全场最佳必须出自胜方 ⇒ **已修**(见文末"已修")。
- **(b) 3v3 的 `_teams` 缺失/滞后**:[`match_result_payload.gd:73`](../../../../ui/screens/match_result_payload.gd#L73) 按 `teams.get(int(role), 0) != t` 分节,`_teams` 来自 `match_sync`;若终局前没到,所有人被跳过(页面空表)且 `_verdict_team(my_team=0)` 恒"失败"(`:135-136`)——从赢家视角看就是"我赢了但页面说失败,★ 在对家"。
- **(c) stats 归因/搬运错**:`_record_down`([`match_state.gd:292-322`](../../../../server/match/match_state.gd#L292))与 `dealt/taken`([`match_combat.gd:246-266`](../../../../server/match/match_combat.gd#L246))逐行核对**无取反**;剩下的可能是 `stats_payload` 的键类型(RPC 后 int/str 键)或客户端 `_last_round_state` 被后一条载荷覆盖。

**定位计划**(历史记录;本轮已按裁定直接修,见文末):
① 在 `MATCH_OVER` 广播点加一条 `--diag` 事件(`round_over`,含 `match_winner/mvp/stats` 原文),复现一局即可判定 (a)/(b)/(c);
② 纯逻辑侧补一支 `-s` 断言(Golden):给定一份 `stats`,断言 `mvp_role` 指向 ACS 最高者、且 `for_duel` 产出的 `mvp.row` 与该 role 的行号一致 —— 这条今天**没有任何断言**(`match_result_payload_smoke` 已删)。
**档位**:若确认是 (b),修 `match_sync` 到达时序或 `_verdict_team` 兜底 = 单系统;若 (c) 是归因错 = 承重面(结算数字),按档 3 走。

---


### BUG-24 ｜ P1 ｜ 打完对局房间不回收(worker 不主动退,回收梯只认进程死亡)(**已修 2026-10-30**)

- **现象(用户实报)**:一局打完(进结算页)后,房间里一直显示「对局中」,端口不归还;要等很久才消失。
- **根因**:`MatchRound._match_round_tick` 的 `MATCH_OVER` 分支是 `pass`(等玩家退出/服务器关房)⇒ **worker 不主动退**;大厅 `_reclaim_finished_matches` 的唯一判据 `_match_over = not pid_alive(pid)` ⇒ 客户端还连着(结算页不退)就永远不回收;唯一兜底 = 2h 超龄清扫。
- **修法**:`MatchRound.is_match_over()` + `server_main._process` 的 `MATCH_OVER_LINGER = 60s` 终局滞留到点 `quit(0)`(客户端已 `_match_ended`,断开不触发重连),房/端口随后 ≤30s 被回收梯收掉。
- **验收**:真链路打一局到 MATCH_OVER,不点返回,断言 ≤90s 内 `lobby.rooms` 里该房消失、端口回池(需真链路批)。**无自动断言**(worker 生命周期无 `-s` 地基)。
## 2. 本轮新确认

### BUG-03 ｜ P1 ｜ 重连补破坏态只补"整格已消失"的格,16px 子格破坏全部漏补(照旧 X6 的细化)(**已修 2026-10-30**)

- **证据**:[`match_state.gd:51-63`](../../../../server/match/match_state.gd#L51) 的 `destroyed_cells()` 只比较 64px 格级 `grid` 与 `_base_grid`;子格破坏路径只写 `damaged_subs`([`match_combat.gd:24-30`](../../../../server/match/match_combat.gd#L24)),格级 `grid` 要等 16 个子格全死才清零([`tile_defs.gd:288`](../../../../core/sim/tile_defs.gd#L288))。`match_sync` 只带 `destroyed_cells()`(`server_main.gd:371-374`),`damaged_subs` 从不上线。
- **影响**:掉线→宽限内重连后,客户端重建的世界比服务器多出**所有只被打掉部分子格的砖**(榴弹 `tile_break_unit=0.25` 打出的洞全在此列)。本地玩家/子弹撞在服务器不存在的墙上 ⇒ 每条快照一次回滚(橡皮筋),且大乱斗没有换局复位、整局无法自愈。
- **修法**:`match_sync` 载荷增加 `subs`(服务器已有的 `damaged_subs`),客户端在 `destroyed` 循环之后逐条 `tile_sync.on_sub(sub, true)`(`on_sub` 已支持 silent 与去重,重复投递无害)。**不要**改成"有子格死即报整格"——那是另一个方向的幽灵墙。
- **验收**:探针断言"造一次只死 1 个子格的破坏后,match_sync 载荷的子格集合非空且含该 sub";去掉写 `damaged_subs` 那行即红。档 **3**(改 match_sync 载荷)。

### BUG-04 ｜ P1 ｜ 回溯环缓不随换局复位,可回放到上一局的帧(仅 Beta 时间玩法)(**已修 2026-10-30**)

- **证据**:环缓唯一裁剪是深度裁剪([`match_host.gd:411-413`](../../../../server/match/match_host.gd#L411),默认 12s,[`time_rules.gd:107-110`](../../../../core/config/time_rules.gd#L107));`_rw_t0` 只在环空时重设(`:313-314`)。而 `_reset_world_and_clear_dynamics()`([`match_round.gd:148-196`](../../../../server/match/match_round.gd#L148))清子弹/重铺武器/还原砖,**一行都不碰** `_rw_buf/_rw_cursor/_rw_snap_t/_rw_t0/_rw_trail`。换局间隙 = 4s + 3s = **7s < 12s** ⇒ 新一局开局按住回溯可退进上一局的活体帧。
- **影响**:位置/HP/各槽弹量被写回上一局的值;开局时砖已还原,回放点可能落在本局墙体内。这正是 `_finish_rw` 那段"被复写的未来又被看到"注释要防的现象,只是漏了局边界。
- **修法**:在 `_reset_world_and_clear_dynamics()` 里(与 `damaged_subs.clear()` 同处)清 `_rw_buf/_rw_cursor/_rw_snap_t/_rw_t0/_rw_trail`,并处理"换局瞬间正处在回溯态"的 role(`src.frozen=false` + `remove_meta("time_rewinding")`),否则下一局该玩家输入源永久冻结。
- **验收**:探针断言"换局后 `_rw_buf[role]` 最老帧 t ≥ 换局时刻";去掉 clear 即红。档 **3**。

### BUG-05 ｜ P2 ｜ 回溯记录 `downed` 却从不还原,回放到死亡帧得到"0 血但活着"(仅 Beta)(**已修 2026-10-30**)

- **证据**:记录侧写了 `"downed": p.is_downed()`([`match_host.gd:381`](../../../../server/match/match_host.gd#L381));应用侧 `_apply_rw_frame` 全文不读该字段(`:417-480`),HP 被 `clampi` 成 0(`:434`)而 downed 仍 false。单机侧对应能力已存在且**全仓零调用**:[`combat_component.gd:100-101`](../../../../scenes/player/combat_component.gd#L100) `set_downed_by_rewind()`。
- **影响**:服务器上出现"hp=0 且未倒地"的非法态:血条空但人还在跑,下一次 1 点伤害立刻触发死亡流程;`_match_round_tick` 看不到倒地 ⇒ 不排复活、不掉武器、不记账。
- **修法**:`_apply_rw_frame` 里按单机顺序补 `combat.set_downed_by_rewind(bool(f["downed"]))`(该方法刻意不扣血、不发 `went_down`,正为此准备)。
- **验收**:探针"回放到死亡帧后 `is_downed() == frame["downed"]`",去掉那行即红。档 **3**。

### BUG-06 ｜ P1 ｜ 「启动/重启本机服务器」的端口属主探测对 **UDP 完全失明**(**已修 2026-10-30**)

- **证据**:[`local_server.gd:205-221`](../../../../core/net/local_server.gd#L205) `_pids_on_port()` 用 `netstat -ano` + `if cols.size() >= 5:`。实测本机 UDP 行形如 `UDP 0.0.0.0:7777 *:* 1234`,按空格切只有 **4 列**(UDP 没有 State 列)⇒ 恒不满足 `>= 5`,对任何 UDP 监听端口都返回空。写对的那份在同仓 [`tests/env.sh:47`](../../../../tests/env.sh#L47)(`awk '{print $NF}'`)。
- **影响**:三处都错 —— (a) `:45` 承诺的"清掉占用大厅端口的残留进程"是空操作(旧 bat 起的 `Godot*` 进程名不受 `taskkill /IM "Cyancular Ruins Server.exe"` 命中),旧实例继续占 7777,新实例 bind 失败静默退出;(b) `:59` 就绪轮询的第一类判据永假;(c) 反向也错:`:214` `line.contains(":%d " % port)` 会匹配 **TCP 行的对端地址**,本机某客户端连着远端 7777 时会假报"已启动"。
- **修法**:把"谁占着 UDP 端口"收成 `ProcUtil.pids_on_udp_port(port)`(用已经跑通的 `Get-NetUDPEndpoint`),`local_server` 的清理与就绪轮询、`kill_udp_port` 共用;删 `_pids_on_port`。档 **单系统**(副作用:名族护栏会让"别人的进程占 7777"从静默杀变成打印一行不杀,需确认取向)。

### BUG-07 ｜ P2 ｜ `PROTO_VERSION` 不一致没有拒绝路径:跨版本照常开局,之后双方静默冻结(**已修 2026-10-30,v7**)

- **证据**:[`net_codec.gd:918`](../../../../core/net/net_codec.gd#L918) 只校验版本字节 → 解码返回空;`net_bus.gd:252-253` 一条 `push_error` 后 return,比赛继续(`:255-256` 自己写着"该玩家整局动不了,且服务器侧不报任何错")。三个开局握手(`claim_role` / `match_sync` / `match_sync_data`)都不带版本位。
- **影响**:大厅 RPC 走 Godot 原生序列化,与 `PROTO_VERSION` 无关 ⇒ 跨版本照样建房/加入/配对/开局;之后 send_input/snapshot 全丢,双方各自一条 `push_error`,画面上"对手不动、自己也动不了"。可达:本机 `LocalServer` 拉起的 server exe 与客户端同目录,换版不同步是自然操作。
- **修法**:在已有的一次性开局握手里带 proto 字段,worker 发现不等就回 `server_message` + 拒绝开局并踢连接;客户端把解码失败升级成用户可见横幅。档 **3**。

### BUG-08 ｜ P2 ｜ `note_post_step` 的环淘汰漏清 `_inputs`:ack 断流时按 tick 无界增长(**已修 2026-10-30**)

- **证据**:[`prediction_rollback.gd:92-95`](../../../../core/net/prediction_rollback.gd#L92) 淘汰循环只 `_captures.erase(old)` + `_events.erase(old)`,**没有 `_inputs.erase(old)`**;而同一段在 `advance()`(`:82-86`)里是三个都清。生产路径走 `note_post_step`([`pvp_match_client.gd:435`](../../../../scenes/pvp_match_client.gd#L435))。
- **影响**:`_inputs` 的唯一回收者是 ack 驱动的 `_trim`;ack 正常时环里只有 1~3 条,看不出来;本人包通道停摆(重连中)而世界包还在、玩家照常步进时,`_inputs` 以 60 份/秒线性增长(每份 10 键 Dictionary + Vector2)。长期无 ack 的对局线性吃内存。
- **修法**:`:94` 后补一行 `_inputs.erase(old)`;更彻底是三个并行字典收成一个 `_ring[seq] = {rec, cap, events}`。档 **3**(回滚环),实质一行。

### BUG-09 ｜ P2 ｜ `ai_duel` 开局即摘房:端口在 worker 存活时归还进池,且抹掉活 worker 的 pid(**已修 2026-10-30**)

- **证据**:[`room_manager.gd:146-152`](../../../../server/lobby/room_manager.gd#L146) spawn 成功后立刻 `teardown_room(..., TEARDOWN_DELAYED, "", false, "match_end")`;`lobby_rooms.gd:747-748` 重新计时归还端口 ⇒ 120s 后 `release_now(port)`,而 `worker_launcher.gd:32-38` 会清 `_worker_ports/_worker_pids`。`worker_launcher.gd:11-14` 却称"承重的是『worker 进程活着 ⇒ 房对象与它占的端口都还在』"。
- **影响**:端口在 worker 存活期间进池;面板显示空闲、回收梯看不见这场局。`pick_port` 回绕命中时(约 500 次分配)新房 worker 绑失败 quit(1),spawn 只判 pid>0 ⇒ 照发 `go_match`,客户端连到旧 worker 被"拒绝串线连接"踢掉。
- **修法**:AI 局做成真 `in_match` 房交给 `_reclaim_finished_matches` 按 pid 回收;或新增"只 erase、不归还端口"的拆除形态 + 孤儿 pid 梯。档 **3**,须真链路跑 `ai_duel→再建房`。

### BUG-10 ｜ P2 ｜ 拆除收口体内**同步**跑 PowerShell:`kill_worker` 每次阻塞主线程数百毫秒(**已修 2026-10-30**)

- **证据**:`lobby_rooms.gd:743` `launcher.kill_worker(port)` → [`worker_launcher.gd:253`](../../../../server/lobby/worker_launcher.gd#L253) `ProcUtil.kill_udp_port(port)` → [`proc_util.gd:58`](../../../../core/net/proc_util.gd#L58) `OS.execute("powershell.exe", ..., false, true)`(阻塞)。
- **影响**:每次关房/超龄扫/worker 退出都冻一次主线程;大厅 poll 不走(建房/加入包排队);面板每次关房 UI 冻一次;关服按房数线性延长。
- **修法**:`OS.create_process` + 轮询(或 `OS.execute` 移到线程;本仓已有 `proc_util` 的 `OS.create_process` 用法可参照)。档 **单系统**(只改调用方式,不改判据)。

### BUG-11 ｜ P2 ｜ 1v1 worker 的 `claim_role` 没有 role 越界判据(注释声称有)(**已修 2026-10-30**)

- **证据**:[`server_main.gd:411-414`](../../../../server/server_main.gd#L411) 注释写"越界判据 = role 是否在本局参战集合内",而代码是 `or ((_royale or _team_mode) and not _role_set.has(role))` —— **1v1 两项皆 false ⇒ 判据恒不生效**;1v1 的 `_role_set` 已就位(`mode_context.gd:92-94` → `[1, 2]`)。
- **影响**:`claim_role(3, …)` 在 1v1 worker 上被接受;与真 role1 合起来凑满 `_claims.size() >= 2` 触发 `_begin_match`,大厅派来的 role2 一 claim 就被当串线踢掉,对局带幽灵 role 开起来。
- **修法**:去掉 `(_royale or _team_mode) and` 前缀,三模式统一 `not _role_set.has(role)`;配 `-s` 断言(`ctx.roles == [1,2]`)+ 源码断言。档 **单系统**(服务端接线)。

### BUG-12 ｜ P2 ｜ `ai_duel` 摘房时不通知同房第二人:guest 被静默留在已消失的等待室(**已修 2026-10-30**)

- **证据**:[`room_manager.gd:132`](../../../../server/lobby/room_manager.gd#L132) 门禁只判 caller 是房主;`:152` 的 teardown 传 `msg=""` 与 `false`,而 `lobby_rooms.gd:749` `if not msg.is_empty():` ⇒ 对房内任何人都不发一行。`ai_duel` 是 `any_peer` RPC,任何已连客户端可达。
- **影响**:房主在"自己+对手已在房"时点 AI 对战:房立刻消失,guest 收不到消息也收不到 `go_match`,停在等待室;此后 `pvp_start` 恒静默 return。
- **修法**:入口加 `if host_room.players.size() > 1: 拒绝`;或摘房时给非 caller 回一条 `server_message`。守卫:源码断言该 teardown 的 `msg` 实参非空。

### BUG-13 ｜ P2 ｜ 他人回溯残像在每次回溯约 0.2 秒后停摆(与代码自述矛盾)(**已修 2026-10-30**)

- **证据**:线上 `trail` 截到最近 4 点([`net_codec.gd:121`](../../../../core/net/net_codec.gd#L121) `TRAIL_WIRE_MAX := 4`,注释的取舍是"残像只少最老的几个点");服务端每 3 物理帧记一点、最多 10 点([`match_host.gd:334-339`](../../../../server/match/match_host.gd#L334)),换局/退出时清空(`:312`、`:349`)。而客户端判新点的条件是**数组变长**:[`pvp_match_client.gd:341`](../../../../scenes/pvp_match_client.gd#L341) `if new_trail.size() > trail.size():`。线上数组长度 0→4 之后**恒定 4**,于是只在前 4 个点(约 200ms,50ms/点)出残像,整段回溯余下时间一个都不再出。
- **影响**:注释宣称的取舍是"只少最老的几个点",实际是"除头 4 个点外全都没有";每次回溯都这样。
- **修法**:客户端改成比较**最后一个点**是否变化(或按"与上次不同的后缀"生成),每来一个新点出一张淡副本(20Hz),协议零改动。档 **单系统**;观感只能人眼验收。

### BUG-14 ｜ P3 ｜ 回局凭据只存房号不存模式:跨模式同号房互相列进对方列表(**已修 2026-10-30**)

- **证据**:[`rejoin_registry.gd:8`](../../../../server/lobby/rejoin_registry.gd#L8) 记录 `{code, role, worker_port, worker_pid, expires_at}`(无 mode),`decision`/`owns` 只比 code;而同仓 `room_registry.gd:8` 明写"同号跨 mode 共存是允许的",`lobby_rooms.gd:646` 也要求"必须带 kind"。
- **影响**:持 3v3 房 `"1234"` 凭据的玩家会在**大乱斗**列表看到无关私密房 `"1234"`(其 names/map 被泄漏);点它时 `decision` 也放行,但 `go_match` 用的是他自己那场。前提 = 两模式同号。
- **修法**:`grant()` 增 mode,`decision/owns` 加 mode 比较,两个 `list_payload` 传自己的 mode。档 **3**(凭据/回局)。

### BUG-15 ｜ P3 ｜ `--port` 解析零校验:`--port abc` 得 0,worker 静默绑随机端口(**已修 2026-10-30**)

- **证据**:[`mode_context.gd:55-57`](../../../../core/mp/mode_context.gd#L55) 对 `--port` 直接 `int(args[i + 1])`,无 `is_valid_int`/范围校验;而同函数对 `--roles/--teams` 非法直接 `_fail`(`:105-111`)。
- **影响**:`--port abc` ⇒ 0 ⇒ `create_server(0)` 绑随机端口返回 OK ⇒ worker 打印"就绪"、活着、占一个找不到的端口,靠 30s 报到梯才退。含未验证前提(ENet 放行 0)。
- **修法**:`--port` 走 `_parse_int_list` 同款校验,`ctx.ok=false` 的 `quit(1)` 分支已有。档 **单系统**。

### BUG-16 ｜ P3 ｜ `ProcUtil.kill_udp_port` 的"不是我们一族就不杀"警告永远到不了日志(**已修 2026-10-30**)

- **证据**:[`proc_util.gd:58`](../../../../core/net/proc_util.gd#L58) `OS.execute("powershell.exe", [...], [], false, true)` —— 第 3 参 output 是空数组(不捕获),第 5 参 `open_console=true`。要看见的正是 `:56-57` 的 `[ProcUtil] UDP <port> held by '...' -- not ours, not killing it`。
- **影响**:`open_console` 让 powershell 自开一个控制台、警告一闪即逝(且每次清端口弹一个窗),或输出写进随手丢弃的空 Array;而 `:17-19` 把这一行当成该取守护栏**唯一**的可见反馈。档 **皮**(只动诊断可见性)。

### BUG-17 ｜ P3 ｜ `encode_world` 的 200 人容量预算与循环不对称(潜在越界)(**已修 2026-10-30**)

- **证据**:[`net_codec.gd:162-165`](../../../../core/net/net_codec.gd#L162) `var n := mini(players.size(), 200)` 只约束 `resize`;[`:182`](../../../../core/net/net_codec.gd#L182) `for key in players:` 不封顶。N>200 时写越界,包被截断、解码端 `o != size` 判死 ⇒ 整帧丢。
- **影响**:现网 `ROYALE_MAX_PLAYERS=16` 撞不到;但这是"容量预算对不上写入量"的同款形态(探针 ⑤ 正是在防这类事)。
- **修法**:循环里 `if emitted >= 200: break`。档 **1**。

### BUG-18 ｜ P2 ｜ 转连 worker 的一次性回调不成对:回大厅 25s 后被"假 claim 梯"踢出大厅(**已修 2026-10-30**)

- **证据**:[`lobby_page.gd:253-254`](../../../../scenes/lobby_page.gd#L253) `multiplayer.connected_to_server.connect(_claim_role_worker.bind(role), CONNECT_ONE_SHOT)`,而 `_return_to_lobby()`(`:283-295`)只做 `NetBus.stop()` + `start_client(...)`,**没有任何 disconnect**;`_claim_role_worker` 首行 `_claimed_ms = Time.get_ticks_msec()`(`:265-266`),`_tick_claim_timeout` 在 25000ms 后 `_return_to_lobby(...)`(`:325-326`)。
- **影响**:worker 12s 连不上(`_tick_worker_connect_timeout` 的既有档)→ 回大厅重连;**大厅一连上,上一条 worker 转连留下的 one-shot 仍会把 `_claim_role_worker` 叫起来** ⇒ 向大厅 peer 发 `claim_role`/`player_options`/`report_token`,并起 25s claim 梯 ⇒ 玩家在大厅浏览时被无理由弹回、连接重建、列表与等待室状态丢失。另:[`pvp_match_client.gd:954-958`](../../../../scenes/pvp_match_client.gd#L954) 对同一条引擎事实已写了"每次先摘干净",两处纪律不一致。
- **修法**:收成 `_bind_worker_once(role)` / `_unbind_worker_once()`(匿名 lambda 换具名方法),`_do_go_match()` 与 `_return_to_lobby()` 成对调用(见 [01 S-20](01-代码与注释审查.md))。档 **单系统**。

### BUG-19 ｜ P2 ｜ 回溯残影宿主节点永不释放 + "1s 渐隐"是死路(两处泄漏)(**泄漏面已修 2026-10-30**;节拍器见 BUG-20 仍未修)

- **证据**:[`pvp_match_client.gd:346-352`](../../../../scenes/pvp_match_client.gd#L346) `AfterImage.spawn(ghost_host, anim, ...)` 自建的 `ghost_host` 在 `AfterImage` 自身 0.26s 后 `queue_free` 之后**再也没有人释放**;淡出取 `var spr := host.get_child(0) as Sprite2D`(`:358-361`),而 child 是 `AfterImage`(Node2D)⇒ **恒 null** ⇒ 手动渐隐从不执行;过期项在 `:362-366` 的 `alive` 里被丢弃,却不 `free`。
- **影响**:每次回溯每秒 20+ 个空 Node2D 永久挂在 `_world`(长局/多人回溯线性增长);对手在回溯中离场时(`_remove_replica` 只 free 副本)残影宿主照样漏。同一段代码还有 [BUG-13](02-bug台账.md)(残像 0.2s 后停摆)—— 三个症状同源:这块视效的清理与节拍都没有单一所有者。
- **修法**:`alive` 循环加 `else: g["node"].queue_free()`;淡出改 `(host.get_child(0) as CanvasItem)` 或删掉这层;`_remove_replica` 里调 `_time_fx_replica_rewind_off(rep)`。档 **单系统**(观感只能人眼验收)。

### BUG-20 ｜ P2 ｜ 他人加速重影的节拍器是**共享单例**,并按"副本数 × 帧率"双重缩放(**已修 2026-10-30**)

- **证据**:[`pvp_match_client.gd:277-289`](../../../../scenes/pvp_match_client.gd#L277) `for rep_node in _all_replicas(): … _time_fx_replica_on(rep)`,而 `_fx_other_t -= get_process_delta_time()`(`:315-317`)用的是**客户端根上的一个字段**。
- **影响**:k 个加速者时字段每帧被减 k 次 ⇒ 触发 ≈ `k/0.06` 对/秒(16 人 ≈500 张 AfterImage/s);且 `_physics_process` 链里读 idle delta ⇒ 30fps 时 0.033s、120fps 时 0.12s,与注释的 0.06s 无关。卡顿+泄漏的组合。
- **修法**:计时器搬进副本(或 `{rep: t}` 字典),函数签名加 `delta` 传物理 delta。档 **单系统**。

### BUG-21 ｜ P2 ｜ 用中文播报子串判定"服务器断开",第二条判据恒假(**已修 2026-10-30**)

- **证据**:[`pvp_match_client.gd:904-910`](../../../../scenes/pvp_match_client.gd#L904) `if msg.contains("断开") or msg.contains("断开连接"):` —— 后者恒被前者覆盖;`local_server_message`(`net_bus.gd:49-50`)同时承载 `server_message` 文本播报与本地 `server_disconnected` 的「服务器断开」。
- **影响**:任何含"断开"的服务端文案都会被当成断线并 `_begin_reconnect()` → `NetBus.stop()` 掐掉活连接;文案一改则重连静默失效。**判据是自然语言,不是状态**。
- **修法**:断开走专用信号(`multiplayer.server_disconnected` 直连),文本播报单列。档 **单系统**。

### BUG-22 ｜ P3 ｜ 权威爆炸按 `shooter` 匹配,但 `want` 可为 null ⇒ 会吃掉别人的榴弹(**已修 2026-10-30**)

- **证据**:[`pvp_match_client.gd:91-106`](../../../../scenes/pvp_match_client.gd#L91) `var want: Node = shooter if shooter != null else (_local if shooter_role == PvpSession.role else null)`;筛选条件含 `b.shooter != want`,只有"自己那发"才 early return。
- **影响**:快照还没建出射手副本时 `want == null`,而那一刻 `_on_bullet_spawn` 给出的视觉弹 `shooter` 也是 null ⇒ **最近那颗别人的榴弹**被 `queue_free()`(双爆/提前消失),大乱斗多榴弹时最易撞。
- **修法**:`want == null` 时直接 return,只在本端能定位射手时才 cull。档 **单系统**。

### BUG-23 ｜ P3 ｜ 3v3 倒地尸体仍挂血条(大乱斗有、3v3 漏)(**已修 2026-10-30**)

- **证据**:[`team_game.gd:233-235`](../../../../scenes/team_game.gd#L233) 只写 `_hp_bars[role].ratio = …`;大乱斗 [`royale_game.gd:121-125`](../../../../scenes/royale_game.gd#L121) 紧随 `visibility = not bool(data.get("downed", false))`,并注释"线上 hp 已钳到 0,否则会读成还活着"。
- **影响**:3v3 尸体头顶一条 0 血条,读成"残血还活着"。
- **修法**:照抄大乱斗那两行(可随 [01 S-18](01-代码与注释审查.md) 的副本集合合并一起做)。档 **皮**。

---


## 2.9 测试基建(本轮新登记)

### BUG-25 ｜ P2 ｜ 串行真链路批会被"上一支的残留"连累(**已修 2026-10-30**)

- **现象(2026-10-30 首跑)**:全批首跑 `pvp_match_smoke` FAIL 后,两个 `server_main.tscn` 大厅进程仍占 7777(console + exe 各一);随后 `royale_soak_probe` / `royale_role_cap_probe` 直接 `Couldn't create an ENet host err=20` 假 FAIL。清场后单跑三支全 **PASS**。
- **根因方向**:`pvp_match_smoke.sh` 的 `kill_procs $SERVER_PID` 在 Git Bash/MSYS 下不可靠(脚本自注);`kill_port`/`kill_port_range` 覆盖不到"两种 Godot 二进制各起一个大堂";`run_real.sh` 只在整批开始做 `lobby_alive` 闸,entry 之间不扫 7777。
- **影响**:任何一支失败 ⇒ 后续 entry 全假 FAIL,时序结论不可信。
- **根因(已定位)**:测试基建的清理原语(`lobby_alive` / `kill_port` / `kill_port_range` / `kill_procs`)按 **Git Bash/MSYS** 写(`netstat -ano` / `taskkill`);从 **WSL bash** 调用时这些命令是 Linux 版或不存在 ⇒ **全部静默 no-op**,闸三的 `tasklist | grep godot` 也恒 0。失败 entry 的 godot/7777 因此留下并污染后续。
- **修法**:`tests/env.sh` 与 `tests/run_real.sh` 加 **WSL 分支**(`uname -s == Linux` 时走 `powershell.exe`/`taskkill.exe` 互操作重定义同一批原语);另新增 `kill_lobby_by_cmdline`(按命令行清 `server_main.tscn`)并在 `pvp_match_smoke.sh` 全部收尾路径 + `run_real.sh` 的每支 entry 尾部/EXIT trap 调用。
- **验证**:修后单跑 `pvp_match_smoke` **PASS** 且跑后 `7777 空闲 / 无 godot 残留`;三份 shell `bash -n` 全过;完整真链路批见 §三十七。
- **验收**:故意让一支 FAIL,断言之后 `lobby_alive=false` 且 7777 属主为 0。
## 3. 旧 bughunt 报告(2026-10-22)复核对照

旧报告 17 条(X1~X17)在 `.superpowers/bughunt/REPORT.md`。本轮只复核了与本模块直接相关的几条:

| 旧 ID | 标题 | 本轮结论 |
|---|---|---|
| X1 | 16 人房实际 8 人(`--roles` 硬编码 1..8) | **已修**:`server_main.gd` 已无 `<= 8`,role 上界走 `ModeContext` 校验 |
| X2 | 开局散点间距崩到 1 格 | **仍在**:[`grid_pathfinder.gd:311-325`](../../../../core/sim/grid_pathfinder.gd#L311) 仍是 `clearance` 逐级 `-5` 放宽到 0 |
| X3 | 每局边界全量世界重建(3v3 两遍) | **待复核**:`match_round.gd:144` 已改"增量复位(2026-10-24)",3v3 那一半客户端是否仍做两遍未验 |
| X4 | 换局重铺地面武器用上一局拆迁后的 grid | **疑似仍在**:`_reset_world_and_clear_dynamics()` 里 `_reset_ground_weapons()`(`:154`)仍在还原砖(`:162` 起)**之前** |
| X5 | 3v3 隐藏禁用武器控件但仍上发设置 | **未复核** |
| X6 | 重连补态粒度(64px)< 破坏真相源(16px) | **仍在**,本轮细化为 BUG-03 |
| X7 | 播放时钟无夹逼 ⇒ 他人停流后单帧大跳 | **已修**(`player_replica.gd:8` 欠载外插上限 2 tick / 60px) |
| X8 | 快照对单 peer 饥饿 0.89~2.13s | **未复核**(需真链路 soak) |
| X9 | ACS 分母"已修"是 no-op(读 `_left_round` 写 `_leave_round`) | **已修**:`team_host.gd:265` 已把 `_leave_round` 写进 `_left_round`(1v1/大乱斗无局号,不需要) |
| X10 | 宽限期内掉线者身体可被继续击杀计分 | **未裁定**(代码仍是 `:39` 只排除 `MATCH_OVER`,宽限期倒地照旧入账) |
| X11~X13 | 探针假红/假绿/残留文件 | **未复核**(测试面) |
| X14 | 平局日志"胜者 role 0" | **未复核**(cosmetic) |
| X15 | 文档:16 人清单漏 worker 解析;`modes.md:78` 与 watcher 注释不符 | **未复核** |
| X16 | 1v1 除"能开局"外几乎零行为守卫 | **仍在**(与 [00-总览 §4](00-总览与结论.md) 的验证计划一致) |
| X17 | `rollout_fidelity_probe` 源码守卫只扫 `pvp_game.gd` | **未复核** |

---

## 4. 建议的修复顺序(每批都能独立验收)

| 批 | 内容 | 为什么这顺序 | 跑什么 |
|---|---|---|---|
| **B1** | BUG-06(local_server UDP)、BUG-11(1v1 claim_role)、BUG-13(残像停摆)、BUG-15(-port)、BUG-16(诊断)、BUG-17(200 人封顶) | 全在"单系统"档、单点改动、不动协议;BUG-06/11 是服务端接线,能靠人眼/日志验收 | 默认批 + 手动点一次"重启本机服务器" |
| **B2** | BUG-18(lobby_page 假 claim 梯)、BUG-21(子串判断开)、BUG-23(3v3 血条) | 大厅/客户端接线,单点;BUG-18 是用户在大厅就会撞到的,P2 里最优先 | 默认批 + 手动"worker 连不上→回大厅→再浏览 25s" |
| **B3** | BUG-19/20/22(残影泄漏 + 节拍器 + 爆炸 cull) | 同一块视效代码,一起改更安全;观感只能人眼 | 人眼:两人局各回溯一次,看 CPU/节点数 |
| **B4** | BUG-03(重连子格)、BUG-07(版本拒绝)、BUG-08(回滚环) | **已完成**:B4 协议批(v7:删差分 + trail 定点化 + BUG-07 版本握手)+ BUG-03 补态(载荷加 `destroyed_subs`)均已落地 | `net_wire_smoke`(5)+ `snapshot_size_probe`(5)+ 默认批 20/122 全绿;真链路(`pvp_match_smoke`/`rejoin_probe`/`team_match_probe`/`royale_soak`,占 7777)待用户认领 |
| **B5** | BUG-04/05(回溯跨局/倒地) | **已完成**:换局清回溯环 + 解冻回溯态 role(`reset_time_rewind_state`);`_apply_rw_frame` 还原 downed。无自动断言(服务器 Beta 回溯无探针基础),登记 §三十三 边界 | 真链路一局 Beta 回溯 + 人眼 |
| **B6** | BUG-09/10/12(AI 局摘房/同步 kill/guest 通知) | **已完成**:`TEARDOWN_ADOPT` + 孤儿 pid 梯(BUG-09);kill 改异步线程 + KILL 走延迟归还(BUG-10);房内>1 人拒绝 AI 对战(BUG-12)。`room_sweep_lint` 绿 | `room_sweep_lint` + 手动 `ai_duel` → 再建房(真链路待认领) |
| **B7** | BUG-01、BUG-02(用户实机报) | **已完成**:BUG-02 按用户裁定「MVP 出自胜方」修(§二十六);BUG-01 定位到"重建条目后仍写回旧枪实弹"并修 + 新增探针(§三十) | `gun_ammo_independence_probe` 8 条绿 |
| **B8** | 文档/注释:01 的 `DD-*` / `CM-*` / `G-*` | 纯文本与守卫补齐,零生产风险;但要在代码定稿之后一次性刷,避免二次漂移 | `python tools/check_naming.py` + 各支条数闸复核 |

> ★ 跑测试前先问用户(AGENTS.md §1):进入验证阶段先列"这轮要跑哪些测试",用户认领的自己跑,其余 agent 跑;任何占 7777 的步骤先查 `lobby_alive`。

---

## 5. 每条的"去掉什么才红"(守卫候选一览)

| ID | 建议守卫 | 去掉什么才红 |
|---|---|---|
| BUG-03 | `match_sync` 子格集合断言 | 删 `damaged_subs[sub] = true` |
| BUG-04 | 换局后环缓最老帧 t 断言 | 删那组 `_rw_*` clear |
| BUG-05 | 回放死亡帧后 `is_downed() == frame["downed"]` | 删 `set_downed_by_rewind` 那行 |
| BUG-06 | `pids_on_udp_port(7777)` 非空(用真监听器造) | 删 UDP 列判断修复 |
| BUG-07 | 版本不等时 `match_sync` 拒绝开局 | 删 proto 校验 |
| BUG-08 | 环淘汰后 `_inputs.size() == KEEP` | 删 `_inputs.erase(old)` |
| BUG-09/12 | 真链路:AI 局期间端口仍在占用表、guest 收到 `server_message` | 删对应的保活/通知 |
| BUG-11 | `-s`:`ctx.roles == [1, 2]` 且源码不带模式前缀 | 恢复 `(_royale or _team_mode) and` |
| BUG-13 | 无自动断言(观感),只能人眼 | — |
| BUG-18 | 真链路:worker 超时回大厅后 25s 内不被弹回 | 删 `_unbind_worker_once()` 调用 |
| BUG-19/20/22 | 无自动断言(视效/节点数),人眼 + 运行时节点计数 | — |
| BUG-21 | `-s`:文本"断开"不再触发重连;`server_disconnected` 信号触发 | 把判据改回子串匹配 |
| BUG-23 | 人眼(3v3 尸体无血条) | 删 `visible = not downed` 那行 |
| BUG-01 | `gun_ammo_independence_probe`(8 条,真 player.tscn) | 把 `pick_up`/`random_keep_one` 的 `_equip_index(..., false)` 改回默认 flush ⇒ 红 |
| BUG-02 | `-s`:给定 stats/候选集,断言 MVP 必在胜方 | 删 `candidates` 过滤 ⇒ 红(`mvp_choice_smoke`) |
| BUG-03 | `resync_substate_smoke`(5 条):`TileResync.partial_damaged_subs` 只补「格仍在」的死子格 | 删「格仍与基线相同」过滤 ⇒ 红;删排序 ⇒ ④红 |
| BUG-14 | `rejoin_mode_smoke`(4 条):凭据带 mode;decision/owns 按(房间号,模式)判 | 去掉 decision 的 mode 比较 ⇒ ②红;去掉 owns 的 mode 比较 ⇒ ③红;grant 不存 mode ⇒ ①红 |
| BUG-09 | `room_sweep_lint`(结构与回收梯) | AI 局走 `TEARDOWN_ADOPT` + `reap_orphans`(无自动断言,登记边界) |
| BUG-07 | 跨进程握手(claim/reclaim 带 proto,服务端拒+踢) | 无专属自动断言;变异 = 删 server_main._proto_matches 的两处调用 ⇒ 跨版本不再被拒(需真链路才能观测,登记边界) |
| BUG-17 | `encode_world` 200 人输入不越界 | 删循环封顶 |

---

## 6. 本轮已修记录(2026-10-30)

> 用户指令「开做」+ 裁定「MVP 是明明赢了、全场最佳却是对面」。纯逻辑面已自测(见文末证据);**真链路/端口相关批次未跑**(按 AGENTS §1 等用户认领)。

| ID | 改了什么 | 守卫 / 验证 |
|---|---|---|
| BUG-02 | ① 新增纯函数 [`ScoreRules.pick_mvp(stats, candidates)`](../../../../core/sim/score_rules.gd)(ACS → 击杀 → 阵亡 → role 升序;**先收第一个候选**修掉"全员负 ACS 返回 0");② [`MatchState.mvp_role(candidates)`](../../../../server/match/match_state.gd) 改为折表 + 调纯函数;③ 1v1 [`match_round.gd`](../../../../server/match/match_round.gd) 传 `[胜者 role]`、3v3 [`team_host.gd`](../../../../server/hosts/team_host.gd) 传 `_roles_of_team(胜队)`;④ 并列/平局/候选全失配时回落全 roster | 新增 [`tests/smoke/mvp_choice_smoke.gd`](../../../../tests/smoke/mvp_choice_smoke.gd) **6 条**断言(胜方候选 · 3v3 胜队候选 · 并列确定性 · 全员负 ACS);`MVP CHOICE OK(6 条断言)` |
| BUG-06 | [`ProcUtil`](../../../../core/net/proc_util.gd) 新增 `pids_on_udp_port` / `_pid_of_udp_line` / `_addr_has_port`(UDP 行 4 列、端口按冒号后整段解析);[`local_server.gd`](../../../../core/net/local_server.gd) 的残留清理与就绪轮询改调它、删 `_pids_on_port` | 新增 [`tests/smoke/net_argv_port_smoke.gd`](../../../../tests/smoke/net_argv_port_smoke.gd) ①②③(UDP 4 列解析 / TCP 与对端不误命中 / `:17777` 不当前缀);`NET ARGV OK(5 条断言)` |
| BUG-11 | [`server_main.gd`](../../../../server/server_main.gd) `_on_role_claimed` 去掉 `(_royale or _team_mode) and` 前缀 ⇒ 1v1 也按 `_role_set` 判越界 | 无自动断言(服务端接线);由 BUG-06/15 同批 smoke 间接覆盖 `ModeContext` 产出 |
| BUG-13 | [`pvp_match_client.gd`](../../../../scenes/pvp_match_client.gd) 新增 `_fresh_trail_points` / `_same_trail_pt`:按"新旧 trail 重叠段之后的点"判新点(不再按数组变长,线上长度饱和在 4) | 无自动断言(观感,按仓规人眼验收) |
| BUG-15 | [`mode_context.gd`](../../../../core/mp/mode_context.gd) 新增 `_parse_port`:非法 token / 缺值 / 越界一律 `ok=false` | `net_argv_port_smoke` ④⑤ |
| BUG-16 | [`proc_util.gd`](../../../../core/net/proc_util.gd) `kill_udp_port` 改为**捕获输出并 print**(原来 `OS.execute(..., [], false, true)` 让警告一闪即逝) | 无自动断言(诊断可见性) |
| BUG-17 | [`net_codec.gd`](../../../../core/net/net_codec.gd) `encode_world` 循环加 `emitted >= 200: break`,与 `resize` 预算对齐 | 无自动断言(现网 16 人撞不到;潜在越界) |
| BUG-19 | [`pvp_match_client.gd`](../../../../scenes/pvp_match_client.gd) 残影过期即 `queue_free`、淡出按 `CanvasItem` 取(旧 `as Sprite2D` 恒 null);[`royale_game.gd`](../../../../scenes/royale_game.gd) / [`team_game.gd`](../../../../scenes/team_game.gd) 的 `_remove_replica` 先 `_time_fx_replica_rewind_off(rep)` 再 free | 无自动断言(节点泄漏靠人眼/运行时节点数);**节拍器 BUG-20 仍未修** |

**验证证据(本机 headless,未占 7777/未弹窗)**:

- `python tools/check_naming.py` ⇒ `命名检查 OK(...)`
- `mvp_choice_smoke` ⇒ `MVP CHOICE OK(6 条断言)`
- `net_argv_port_smoke` ⇒ `NET ARGV OK(5 条断言)`
- `net_wire_smoke` ⇒ `NET WIRE OK(7 条断言)`(net_codec 回归)
- `snapshot_size_probe` ⇒ `SNAPSHOT SIZE PROBE: ALL-OK`(codec 回归)
- `allscript_probe` ⇒ `ALLSCRIPT: OK(192 个脚本全部加载)`(条数闸 190→192,两支新 smoke)

> 未跑:真链路批(`pvp_match_smoke` / `rejoin_probe` / `team_match_probe` / `royale_soak`)、`pvp_room_smoke` —— 会占 7777/端口池与拉子进程,按纪律先问用户。修复未提交(git 未 add)。

### 第二批(2026-10-30,客户端接线 + 回滚环;用户「继续修 bug」)

| ID | 改了什么 | 守卫 / 验证 |
|---|---|---|
| BUG-08 | [`prediction_rollback.gd`](../../../../core/net/prediction_rollback.gd) `note_post_step` 的环淘汰补 `_inputs.erase(old)`(与 `advance()` 同款三清) | 新增 [`tests/smoke/prediction_rollback_ring_smoke.gd`](../../../../tests/smoke/prediction_rollback_ring_smoke.gd) **3 条**;`ROLLBACK RING OK(3 条断言)`;**变异验证**:删掉该行 ⇒ 正好 2 条红(①②③里两处),加回 ⇒ 绿 |
| BUG-18 | [`lobby_page.gd`](../../../../scenes/lobby_page.gd) 转连 worker 的 `connected_to_server` / `connection_failed` 收成具名 Callable + `_bind_worker_once` / `_unbind_worker_once` 成对;`_do_go_match` 绑定、`_return_to_lobby` 先解绑(含 `is_connected` 守卫,避免对已自清的一次性连接 disconnect 报错) | 无自动断言(连接接线);人眼:worker 连不上→回大厅→浏览 25s 不再被弹回 |
| BUG-20 | [`pvp_match_client.gd`](../../../../scenes/pvp_match_client.gd) 他人加速重影节拍从单 float 改 **per-副本字典**,递减改用调用链传入的**物理 delta**(不再 `get_process_delta_time()`);`_time_fx_replica_off` 清表 | 无自动断言(观感/节拍);人眼:多人加速时重影频率不再随人数/帧率翻倍 |
| BUG-21 | [`pvp_match_client.gd`](../../../../scenes/pvp_match_client.gd) 局内断线判定从 `msg.contains("断开")` 文本子串改为 `multiplayer.server_disconnected` 直连 `_on_hard_disconnect`;`_on_server_message` 只留播报 | 无自动断言(接线);去掉文本猜状态后,文案改动不再影响重连 |
| BUG-22 | [`pvp_match_client.gd`](../../../../scenes/pvp_match_client.gd) 权威爆炸回收视觉弹前判 `want != null` —— 对手副本未建时不再把别人的榴弹 `queue_free()` | 无自动断言(视觉);大乱斗多榴弹时人眼 |
| BUG-23 | [`team_game.gd`](../../../../scenes/team_game.gd) 3v3 倒地尸体血条隐藏(`visible = not downed`,与大乱斗同口径) | 无自动断言(观感);3v3 尸体头顶不再挂 0 血条 |

**第二批验证证据(本机 headless,未占 7777/未弹窗)**:`prediction_rollback_ring_smoke` `ROLLBACK RING OK(3 条断言)`(含变异验证)· `allscript_probe` `ALLSCRIPT: OK(194 个脚本全部加载)`(条数闸 193→194)· `python tools/check_naming.py` 绿。`tests/README.md` 的闸值表与默认批读数(17 支 / 111 条闸断言)同批校正。

> 仍未跑:真链路批(占 7777/端口池、拉子进程,按纪律等用户认领)。BUG-01(每把枪残弹不独立)仍待定位;BUG-20 已修但观感只能人眼验收。

### 第三批(2026-10-30,用户实机报的 BUG-01:残弹独立性)

| ID | 改了什么 | 守卫 / 验证 |
|---|---|---|
| BUG-01 | [`weapon_component.gd`](../../../../scenes/player/weapon_component.gd):`_equip_index()` 增 `flush_current` 开关;`pick_up()` 替换分支传 `false`(旧枪实弹已由 `_last_dropped` 带走);`random_keep_one()` 先 `_flush_current_mag()`(当前枪条目落账)再 `_equip_index(0, false)` | 新增 [`tests/probe/gun_ammo_independence_probe.gd`](../../../../tests/probe/gun_ammo_independence_probe.gd)+`.tscn`(**8 条** + `EXPECTED_CHECKS`);未修时红色原文见 BUG-01 段;**变异验证 3 条**各自红、还原后 `KH gun_ammo_independence PROBE: ALL-OK` |

**第三批验证证据(本机 headless,未占 7777/未弹窗)**:`KH gun_ammo_independence PROBE: ALL-OK` · `ALLSCRIPT: OK(195 个脚本全部加载)`(条数闸 194→195)· `python tools/check_naming.py` 绿。`tests/README.md` 默认批读数同步为 **18 支 / 119 条闸断言**。

> 仍未跑:真链路批(占 7777/端口池、拉子进程,按纪律等用户认领)。BUG-01 的"同帧多次切枪窗口"与"`restore_inventory` 瞬时覆盖"按边界登记未改。
### 第四批(2026-10-30,B4 协议批 v7:删差分 + trail 定点化 + BUG-07 版本握手;档 3)

| 项 | 改了什么 | 守卫 / 验证 |
|---|---|---|
| S-01(审查项) | [`net_codec.gd`](../../../../core/net/net_codec.gd) 重写:`PROTO_VERSION 6→7`,删除全部 DELTA 机制(encode 的 full/prev/keyframes 分支、`apply_world`/`apply_own`、mask/位序表/周期相位/关键帧名额);解码侧 flags 必须恰为 FULL | `net_wire_smoke` 7→**5**、`snapshot_size_probe` 9→**5**(差分断言退役);差异见 [`registered-debt.md` §三十一](../../../eng/registered-debt.md) |
| S-22(审查项) | `trail` 从 2×float32 改 **2×i16(Q_SCALE 0.5px)**,与世界 pos/vel 同精度 | 世界条目 **25 B**(原 33)、最坏包 **536 B**(原 791)、N=16 常态 **408 B**(原 536);`net_wire_smoke` ③ / `snapshot_size_probe` ③⑤ 对 trail 加 ≤0.25 容差 |
| BUG-07 | `claim_role` / `reclaim_role` 带 `PROTO_VERSION`;`server_main._proto_matches()` 在入口校验,不符 ⇒ 回可见 `server_message` 并踢连接 | 无专属自动断言(跨进程握手);两条变异验证见 §三十一 |

**第四批验证证据(本机 headless;默认批不占 7777/不弹窗)**:`RUN_ALL OK(18 runs / 113 gated-assertions)`(18 支全绿)· `net_wire_smoke` readout 输入 42 B / 世界 2 人 50 B / 本人包 99 B · `SNAPSHOT SIZE PROBE: ALL-OK`(条目 25 B / 最坏 536 B)· `ALLSCRIPT: OK(195 个脚本)` · `python tools/check_naming.py` 绿。变异验证三条(实测):trail 步长错 ⇒ net_wire ③ 红;预算少算 ⇒ snapshot ④ 红;flags 判据删除 ⇒ net_wire ② 红;还原全绿。

> **仍未跑**:档 3 要求真链路跑批 —— `pvp_match_smoke` / `rejoin_probe` / `team_match_probe` / `royale_soak`(占 7777/端口池、拉子进程)按 AGENTS §1 等用户认领;两版之间的"同版"只由版本字节 + 握手守门,跨进程未见真包。

### 第五批(2026-10-30,榴弹 32px 破坏单位 + BUG-03 重连补子格;档 3)

| 项 | 改了什么 | 守卫 / 验证 |
|---|---|---|
| 用户裁定 | 榴弹最小破坏单位 16px→**32px**:`grenade_bullet.tscn` `tile_break_unit` 0.25→0.5;`Explosion.damage_tiles` 三档分派(64px/32px 块/16px 子格);`TileDefs.damage_block32` 收口(块内 4 子格同一伤害);碎片按破坏单位播(`Explosion.destructible_units`,一块一簇) | `tile_break_unit_smoke`(11)口径改 32px;变异:场景回 0.25 ⇒ ②红、爆炸分派失效 ⇒ ⑨红 |
| BUG-03 | 新增 `core/sim/tile_resync.gd`(纯逻辑);`MatchState.damaged_partial_subs()` 委托;`server_main` 载荷加 `destroyed_subs`(空不带键);客户端 `_on_match_sync` 在 `destroyed` 之后静默补 16px/32px 子格(复用 `_on_remote_sub_destroyed(sub,true)`) | 新增 `resync_substate_smoke`(5):部分破坏补齐 · 整格不重复 · 未动不发 · 顺序确定 · 无假阳性;变异:删整格过滤 ⇒ 4 处红、删排序 ⇒ ④红 |

**第五批验证证据(本机 headless;默认批不占 7777/不弹窗)**:`TILE BREAK UNIT OK(11 条断言)` · `RESYNC SUBSTATE OK(5 条断言)` · `ALLSCRIPT: OK(197 个脚本)` · `RUN_ALL OK(19 runs / 118 gated-assertions)`(19 支全绿)。

> **仍未跑**:真链路批(本批改了 `match_sync` 载荷,必须跨进程验:`pvp_match_smoke` / `rejoin_probe`;占 7777)等用户认领。
### 第六批(2026-10-30,收尾 6 条;台账 23 条全部修完)

| ID | 改了什么 | 守卫 / 验证 |
|---|---|---|
| BUG-04 | `MatchHost.reset_time_rewind_state()`(清环 + 解冻回溯态 role);`MatchRound._reset_world_and_clear_dynamics()` 早退前动态调用 | 无自动断言(服务器 Beta 回溯无探针地基),登记边界 |
| BUG-05 | `_apply_rw_frame` 补 `combat.set_downed_by_rewind(bool(f["downed"]))` | 无自动断言,同上 |
| BUG-09 | 新拆除形态 `TEARDOWN_ADOPT` + `WorkerLauncher.adopt_orphan/reap_orphans`;ai_duel 改用它 | `room_sweep_lint` 绿;行为待真链路 |
| BUG-10 | `ProcUtil.kill_udp_port_async`(Thread)+ `reap_kill_threads`;`kill_worker` 异步;KILL 改延迟归还 | 无自动断言(时序类,按仓规不写);`room_sweep_lint` 绿 |
| BUG-12 | `ai_duel` 房内 >1 人拒绝并回 `server_message` | 无自动断言 |
| BUG-14 | 凭据加 `mode`;`decision`/`owns`/`_grant_rejoin`/`rejoin_request` RPC 全带模式 | 新增 `rejoin_mode_smoke`(4);变异 3 条实测红→还原绿 |

**第六批验证证据(本机 headless;默认批不占 7777/不弹窗)**:`REJOIN MODE OK(4 条断言)` · `SMOKE_ROOM_SWEEP OK(10 项检查)` · `ALLSCRIPT: OK(198)` · `RUN_ALL OK(20 runs / 122 gated-assertions)`。

> **仍未跑**:真链路批(占 7777;v7 线格式 + `match_sync` 补态 + 大厅拆除/凭据改动都要跨进程验)等用户认领。BUG-04/05/09/10/12 五条无自动断言,只能真链路 + 人眼。
