# 回滚源头治理 Plan（时间线/事件/本地状态对齐）

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ★ **写于 2026-11-01**。只出计划，**未开始实现**；用户已明确「每个任务先给猜测/证据，再跑测试」。
>
> ★ **开工前置**：`git status --short` 干净；`python tools/check_naming.py` 绿。本轮触碰**回滚环 / 预测状态 / 事件时刻**（档 3），工作区若有他人在飞改动，等其提交后再动手（逐 hunk 认领）。

**Goal:** 把「代码层面可以消掉的回滚」逐个从源头消掉：不再让客户端/服务器在同一 tick、同一输入下算出不同结果。目标不是「零回滚」（网络抖动/迟到包/服务器少 tick 天然会触发一次），而是**消灭“持续/每帧”回滚**，并把剩余回滚压到“与网络状况同阶”。

**Architecture:** 三条主线，全部围绕「两端用同一份状态 + 同一份事件时间线」：
1. **本地独有状态清零**：凡影响 `_physics_process` 结果、又不在 `capture_state()` 里的字段，一律删掉或进整态；
2. **事件按 tick/seq 对齐**：命中已有 `apply_external_event(seq)` 先例；拆砖/拾取/换武器目前是“到达即应用”，要与服务器 tick 对齐；
3. **权威态应用单一实现**：单机 `Player.rewind_restore` / 服务器 `match_host` 的回溯恢复 / 客户端 `restore_state` 现在是三份复制，合并成一份（差异用参数表达）。

**Tech Stack:** Godot 4.7.1 标准版（非 GDExtension）/ GDScript / ENet。

**Spec / 必读：**
- [`docs/eng/netcode-snapshots.md`](../../eng/netcode-snapshots.md)（`ack`/`c2`/整态）
- [`core/net/prediction_rollback.gd`](../../../core/net/prediction_rollback.gd)（`_close_enough` / `_handle_ack` / `apply_external_event`）
- [`server/match/match_combat.gd`](../../../server/match/match_combat.gd)（命中回放与 `_stepped_seq`）
- [`docs/archive/superpowers/plans/2026-10-28-hit-event-align.md`](../archive/superpowers/plans/2026-10-28-hit-event-align.md)（**已落地**的事件 seq 对齐先例，本计划照它的形状做拆砖；2026-11-01 归档）
- [`docs/eng/registered-debt.md`](../../eng/registered-debt.md) §四十九（`_auto_jump_assist` 本地表现量当时被“文档化”成边界，本计划把它改回源头解决）

---

## 0. 现状事实（写计划时点，行号引用前先 grep 复核）

| 事实 | 位置 |
|---|---|
| 回滚 = `restore_state(权威 c2)` + 重放 `(ack, last_applied]`；`_close_enough` 比 pos/vel/hp/down | `core/net/prediction_rollback.gd::_handle_ack` / `_close_enough` |
| `_auto_jump_assist` 只在「有横向输入 + 空中」分支递减；**站在地上永不衰减**；且不在 `capture_state()` | `scenes/player/player.gd`（grep `_auto_jump_assist`） |
| 拆砖在客户端**到达即应用**：`TileSync.on_cell/on_sub` 直接改 `MazeGenerator.current_subgrid` / `TileDefs` / 碰撞 | `scenes/mp_client/tile_sync.gd` |
| 单机已有“按时间回放地形”的机器：`TileLedger`（拆砖账本）+ `WorldRewind`（世界快照/回放），PvP 不建 | `scenes/level_0.gd`（`_tile_ledger` / `_rewind`） |
| 权威态应用有三份：单机 `Player.rewind_restore`、服务器 `match_host` 回溯恢复、客户端 `Player.restore_state` | 三处 grep `rewind_restore` / `restore_state` |
| 服务器输入队列溢出 = 丢最旧一条（真丢一个 tick 的输入） | `core/net/packet_input_source.gd::push_pending` |
| 回滚计数可观测：`PredictionRollback.rollback_count()`；`--diag` 会记 `rollback` 事件 | `core/net/prediction_rollback.gd` / `core/net/net_diag.gd` |
| 速率口径：输入**记录** 60Hz / 输入**发包** 30Hz(2 条/包, reliable 通道 1) / 下行快照 60Hz | `core/net/input_uplink.gd` / `core/net/input_wire.gd` / `server/match/match_state.gd` |

**为什么这套能消掉“持续回滚”：** 持续回滚的形态是「每次 ack 都判分歧」——只可能来自「重放用的状态/世界与预测时不同」。上面三类源头（本地独有状态、事件时刻、三份实现漂移）都会制造这个形态；网络抖动型回滚是偶发的，不在此列。

---

## 1. 已拍板 / 关键设计决定

1. **范围** = 非 beta 的 1v1/对抗/大乱斗回滚源头；**不含** beta 时间玩法（回溯/加速）、不含传输层冗余策略的最终选型（只做测量与最小改动）。
2. **不新增线格式字段**（`PROTO_VERSION` 不动）：`_auto_jump_assist` 走“删除”而不是“加进 c2”；拆砖对齐优先用**服务器已有的 tick/seq 域**，不新造时钟。
3. **每个任务都先给“猜测 + 证据”，再动手、再跑测试**（用户明确要求）。
4. **守卫按档位**：本轮触碰回滚环（档 3）⇒ 每条承重断言做变异验证 + 真链路跑批 + 逐任务评审；纯性能项按档 2。
5. **不碰** beta 时间玩法、不碰房间/端口/版本号、不顺手重构无关文件。

---

## Global Constraints

- 判据一律 **grep 判词文本**（`ROLLBACK FIDELITY PROBE: ALL-OK` / `ALLSCRIPT: OK(...)` / `RUN_ALL OK(...)` / `SOAK: ALL-OK`），退出码不是判据。
- 新断言必须自带**条数闸**（`EXPECTED_CHECKS` / `_require_ran`），否则 `ALL-OK` 只等于“没有失败输出”。
- 跑测试先问用户；任何占 **7777** 的步骤先查 `lobby_alive`；真链路跑批前后本线 Godot 进程必须为 0；时序类结论**同配置跑两次**。
- 逐个文件 `git add`（新 `.gd` 连 `.gd.uid`），绝不 `git add -A`；提交信息 `type(scope): 中文一句话`；**推送先问用户**（本机公网不稳，2026-11-01 曾连续 3 次 push 失败）。
- 每次提交前 `python tools/check_naming.py`；注释额度按 `docs/eng/comment-style.md`。
- 每次任务收尾：更新 `docs/eng/registered-debt.md` 的对应小节 + `tests/README.md` 的计数口径（若新增/删除支）。

---

## 任务

### R0a · 公网实测基线（已完成，2026-11-01，第一版代码）

**方法（可复现）：** `git worktree` 检出 `ce092f9b`（= 构建 `RoF_v0.5.3_202611011137` 的源码）→ 探针
`tests/probe/cloud_rollback_probe.tscn`（**只在 worktree 里，未入库**）连公网大厅 `120.53.107.140`：
create 建房 → join 加入 → 房主自动 `pvp_start` → 两端实例化**真实客户端** `pvp_game`（本地预测 + `PredictionRollback`）。
输入注入 `PacketInputSource`：`ax` 恒 0（**不按方向键 ⇒ 自动跳跃/迈台阶不可能触发**）+ 周期开火 + 可选原地跳。

**读数（1v1，60s/局；每端 `rollback_count()`）：**

| 场景 | A（房主） | B | 失败字段 |
|---|---|---|---|
| 站桩开火 · 第 1 局 | 4 | 20 | 未采集 |
| 站桩开火 · 第 2 局 | 4 | 2 | `vel` 全占 |
| 站桩开火 + 原地跳 · 第 1 局 | 1 | 1 | `vel` |
| 站桩开火 + 原地跳 · 第 2 局 | 0 | 1 | `vel` |
| 站桩开火 + 原地跳 + **被打中**（45s） | 3 | 9 | `pos` / `hp` / `down` |

**结论（据此修正本计划的后继假设）：**
1. 排除自动跳跃后**没有持续回滚**：量级 0~20 次/分钟/端，两局波动大 ⇒ 网络抖动/丢 tick 型，不是结构性预测错误。
2. `vel`-only 分歧（站桩/跳）与 `hp`/`down` 分歧（挨打）要**分开看**：
   - `hp`/`down` = 受击不可预测、服务器权威纠正，**设计内行为，不算要消灭的回滚**；
   - `pos`（跳/落地）量级 0~4/局，属跳落那一 tick 的容差问题；
   - `vel` = 最可能的残余源头是**服务器输入队列丢 tick / ack 与预测 tick 错位**（R4），待 `--diag` 验证。
3. 因此后续“回滚率”**必须分类统计**（movement / combat / unknown），目标只针对 movement 类。
4. **loopback 对照（2026-11-01 追加）**：本机 `127.0.0.1`、两个真实客户端、站桩开火 20s：HUD ping 19ms / ENet RTT 22ms
   （≈ 一帧的测量下限，非网络延迟），**仍出现 2 次 `vel`-only 回滚**。本机没有网络抖动 ⇒ 这类 `vel` 分歧与网络无关，
   候选是“开火/后坐路径的火力时刻或输入消费时序”（见 R6），不是“后坐没预测”（后坐**是**预测的，见 R6 证据）。

### R0 · 基线测量（不改产品代码）

**状态：** 第一版公网基线见 §R0a（已完成）；本任务剩余“当前版本对照 + `--diag` 事件级验证”，拆到 R0b / R0c。


**猜测：** 当前“上楼梯”场景的持续回滚主要来自 R1（本地独有状态）与 R2（拆砖时刻）；1v1 平地对枪主要是正常网络抖动型回滚。

**做什么：**
- [ ] 在 `--diag` 下跑一局 1v1（真链路），记录 `rollback` 事件频率；再跑一局“沿台阶上下 + 打穿掩体”的场景（manual 或探针驱动），记录频率。
- [ ] 记录同配置两次（噪声/信号）；把两组数字写进本计划的 §2 结果表。
- [ ] 确认 `rollback_count()` 与 diag 事件计数对得上（避免两个口径）。

**验收：** 两行基线数字（场景 / rollback每局 / 每分钟），写进计划文件；不改代码。

**不做：** 不为了让数字好看而先改代码。

---

### R0b · 当前版本对照（同探针）

**要回答：** 上面那些非自动跳跃回滚，在当前版本（含 `a46f0323..83fe9487` 的修复）里变好/持平/变差？

**做什么：**
- [ ] 用同一探针、同场景（站桩开火 / 原地跳 / 挨打）跑**当前版本**（另建 worktree），各两次。
- [ ] 把数字并进 §R0a 的表（新增一列或一张表），标注 build 与日期。
- [ ] 结论写进本计划；**不允许**只报好看的场景。

### R0c · `--diag` 事件级验证（验证/否定 R4 假设）—— 已做，2026-11-01，本机 13 局

**要回答：** `vel`-only 分歧是不是“服务器丢 tick / ack 错位”造成的？

**做了什么：**
- [x] 探针加 `--diag`：记录每条 `rollback` 事件的 `field` / `pos_err` / `vel_err`，以及回滚前后各 3 tick 的
      `ack` / `gap` / `seq` / 速度 / 开火态；服务器侧用 `CYR_DIAG=1` 收 `diag-*.jsonl` 看 `queue_drop` / `snap_gap`。
- [x] 若“每次 `vel` 分歧前 1~2 tick 内出现过 ack 跳变/丢包”占比高 ⇒ 确认 R4；否则重新标定。
- [x] 把逐字读数写进本计划（§R6 的读数与归因表）。

**读数（逐字）：**
- `queue_drop`：**全部 13 局（含 3 局作废）合计 0 条**；服务端 `metrics` 里 `queue` 心跳正常、`snap_gap` 0 条。
- `ack` 跳变只在**开局窗口**出现（`gap` 从 71 一路涨、`ack` 从 0 一跳 72），原因是 `MatchHost` 的 `COUNTDOWN`
  分支清空输入队列 + `reset_state()`（`server/match/match_host.gd:219-222`）——**不是丢包/重传**（输入走 reliable 通道 1）。
- 结论：**R4 在本机 loopback 未复现**（本机无抖动，队列不积压）；R4 只在公网抖动下才可能发生 ⇒ 本计划保留 R4，
  但它的证据只能来自公网读数（§R0a 的 A4/B20 那两局，当时未采字段）。

### R0b · 当前版本对照（同探针）—— 由 §R6 一并覆盖

### R1 · 删除 `_auto_jump_assist`（P0，源头清零）—— **已完成 2026-11-01**

**猜测（已由代码确认）：** 它只在「有横向输入 + 空中」递减 ⇒ 站在地上永不衰减；且不在 `capture_state()` ⇒ 回滚重放时该值与原预测不同 ⇒ 横移速度不同 ⇒ 再回滚。上台阶/自动跳反复触发它，所以是“疯狂回滚”的最强候选。

**改了什么（`scenes/player/player.gd`，档 2）：**
- [x] 删掉 `_auto_jump_assist` 字段、`AUTO_JUMP_ASSIST_S` 常量、`_tick_horizontal` 里的强制满速分支、`_try_step_or_jump` 里的两处赋值
      （原常量位置留一行"为什么删"，避免以后又有人把它当"本地表现量"加回来）。
- [x] 保留「起跳/迈台阶瞬间把 `velocity.x` 拉满」（`velocity` 本来就在整态里），其它手感参数**一个没动**：空中横移回到
      正常 `approach_air` 缓动。
- [x] 给 `tests/probe/stair_climb_probe.tscn` 加 **⑥ 非空转前提 + ⑦ 回放确定性**（`EXPECTED_CHECKS 5 → 7`）：
      夹具另造一格高（64px）的墙 → 一直向右走到墙前触发**自动跳** → 跳起后空中窗口 `capture_state()` →
      跑 18 帧记 `pos/vel` 轨迹 → `restore_state(capture)` → **同一串输入**重放 18 帧 ⇒ 逐帧**精确相等**。
      ⑥ 断言"自动跳离地且两遍窗口都在空中"，否则 ⑦ 在平地上恒真（探针不写恒真断言）。
- [x] 变异验证（逐字）：把 assist 原样加回去 ⇒
      `KH stair_climb PROBE: FAIL | ⑥ ★ 夹具前置:自动跳离地,且回放窗口整段在空中(第一遍 17/18、第二遍 18/18 帧离地); ⑦ ★ 回放确定性:capture→18 帧→restore→同一串输入重放,逐帧 pos/vel 精确一致(18 帧不一致)`；
      还原 ⇒ `KH stair_climb PROBE: ALL-OK`。★ 删之前用同一探针也跑过一次（当时窗口还是 24 帧，故 ⑥ 也红）：
      `FAIL | ⑥ …(第一遍 23/24、第二遍 22/24 帧离地); ⑦ …(24 帧不一致)`。
      ①~⑤（爬上/不掉速/位移 90%+/不腾空/不下坠）在变异前后**都是绿** ⇒ 变异只打"回放可复现性"，没动"上台阶不掉速"。

**验收：** `KH stair_climb PROBE: ALL-OK`（7 条）· 变异红/绿原文（上）· 回归 `STEP JUMP OK(12 条断言)` ·
`ROLLBACK FIDELITY PROBE: ALL-OK` · `SNAPSHOT SIZE PROBE: ALL-OK` ·
**R0 走位场景前后对比**（本机 loopback，`ax=1` 一直向右、不开火，2×30s，同配置两次）：

| 批 | A 端回滚 | B 端回滚 | 形态 |
|---|---|---|---|
| R1 之前 | 1 次 / 2 次（`pos`） | 1 次 / 2 次（`pos`） | 每端都是"1 次开局窗口 + 1 次隔 4~5 帧跟进" |
| R1 之后 | 2 次 / 2 次（`pos`） | 0 次 / 2 次（`pos`） | 同上，形态没变 |

**这个对照判不了（照实）**：两个批各自随机到不同地图，同一批两局的 `walked` 在 1~2238px、`air_frames` 在 0~1751 之间乱跳
⇒ 分母不可比。**R1 的收益由 ⑥⑦ 直接证明（红→绿），不靠这张表**；表只用来证明"我没有为了让数字好看去动别的东西"。
两批都稳定出现的那条"隔 4~5 帧的 `pos` 跟进"**不是 assist**（它正是本条删掉的东西），已登记待查。

**边界（照实）：** 48/64px 大台阶起跳时若贴墙，横移会被物理吃掉一点（两端一致的物理，不会回滚）；手感只能试玩 ——
删掉 0.25s 窗口后，"越过台沿前半秒的横移"会比之前**略慢**（少了强制满速），是否可感只能试玩；若用户报"上台阶又变慢了"，
正确修法是把那 0.25s 的状态**进整态**（`capture_state` + 线格式），而不是再把本地计时器加回来。

---

### R2 · 拆砖事件按服务器 tick/seq 对齐（P1，收益最大）

**猜测：** 客户端收到拆砖事件就改地形，回滚重放用“更新后的地形”⇒ 重放结果 ≠ 原预测 ⇒ 在刚打穿的砖附近反复回滚（尤其楼梯/掩体）。

**两个候选方案（先写设计再选一个）：**
- **方案 A（小、先上）**：事件到达时把**预测环的 capture 清到事件锚点之后**，并让下一次 ack 走“权威锚定”而不是重放旧输入。
  实现点：`PredictionRollback` 加 `drop_before(seq)`；`TileSync` 拿到事件带的服务器 tick/seq（需服务器补字段）后调用。
  代价：事件到达那一下会接受一次“小橡皮筋”（≤ playout），但不会形成循环。
- **方案 B（正确、后做）**：复用单机 `TileLedger`：PvP 客户端也记“每 tick 的地形变更账本”，回滚重放前把地形回退到该 capture 的 tick，回放后前滚。
  代价：要定义 PvP 的“tick↔事件”映射与内存上限；单机的 `WorldRewind` 依赖 `TimeField`，必须做适配层，不能把时间玩法语义带进来。

**做什么：**
- [ ] 先写 §设计附录（两方案的影响面、字段、失败形态），用户拍板选 A 或 B。
- [ ] 服务器：拆砖广播补“服务器 tick/seq”（只加载荷字段，不改通道、不升 PROTO_VERSION；两端同 build）。
- [ ] 客户端：按选中方案实现；`TileSync` 不直接改地形的地方要抽成“按 tick 应用”的口。
- [ ] 守卫：新增场景探针（或扩展 `resync_*`）：模拟「先预测 10 帧 → 到达一条拆砖事件 → 下一次 ack 恰好在事件锚点」⇒ 断言**不产生连续两次以上回滚**（`rollback_count()` 增量 ≤1）。
- [ ] 变异：把事件改成“到达即应用但不清 capture” ⇒ 断言红。

**验收：** 守卫绿 + 变异红/绿原文；R0 场景（打穿掩体后跑过去）回滚频率前后对比；真链路批绿。

**边界：** 方案 A 的一次性小橡皮筋不可避免；方案 B 的内存与实现复杂度要登记。

---

### R3 · 权威态应用合并为单一实现（P2，防漂移）

**猜测：** 三份复制（单机回溯恢复 / 服务器回溯恢复 / 客户端 `restore_state`）已经出现过“只在一端修好”的缺陷（`mag/rld`、同型号 `winst` 都是这一类）⇒ 这类漂移会表现为“持续回滚”。

**做什么：**
- [ ] grep 三处函数体，列出**字段级差异表**（哪些字段写、哪些不写、哪些走 `apply_mag` 之类的分流）。
- [ ] 抽一个 `PlayerState.apply(player, st, opts)`（或等价的最小公共层），三处改为调用它；差异用 `opts` 表达（如 `flush_inventory=false`、`weapons=mode`）。
- [ ] 守卫：新增纯逻辑/场景探针，用**同一份 payload** 分别走三处入口，断言得到的 `capture_state()` 相等（除时间相关字段）。
- [ ] 变异：把其中一处改回旧写法 ⇒ 探针红。

**验收：** 三处入口 payload→state 一致；`rollback_fidelity_probe` 仍 ALL-OK；全量批绿。

**风险：** 档 3——三处入口各有微妙时序（`sync_soft_state` 早退、回滚重放中调用），必须先列差异表再动。

---

### R4 · 服务端输入队列不丢 tick（P3，需先测量）

**先对齐事实（2026-11-01 复核，别再口误）：**
- 输入**采样/记录 = 60Hz**：`InputUplink.seq` 每物理 tick 一条记录（`TICKS_PER_RECORD = 1`，`netcode-input-uplink.md`）；
- 输入**发包 = 30Hz**：每包 2 条记录（`INPUT_BATCH_TICKS = 2`），走 **reliable 通道 1**（保序）；
- 下行**快照 = 60Hz**（`SNAPSHOT_HZ = 60` / `SNAPSHOT_STRIDE = 1`）。
⇒ “30Hz”只是**发包频率**，不是输入降到 30Hz。

**猜测（修正后）：** 输入走可靠通道 ⇒ 网络丢包不会“丢 tick”，只会**重传延迟**；真正丢 tick 的是
**服务端输入队列溢出时丢最旧一条**（`PacketInputSource.push_pending`，cap 4~16 条 = 66~266ms）。50ms 公网下队列常驻
~2~3 条，平时够；抖动突发（一次积压 > cap）才会丢 ⇒ 每丢一条客户端多算一 tick ⇒ 一次回滚。多人局 worker CPU 高时（§四十八 8 人 ≈10ms/tick）更容易积压。

**做什么：**
- [ ] 用 `--diag` 的 `queue_drop` 事件统计每局“服务端丢 tick”次数（1v1 / 4 人 / 8 人，各两次）；同时记 `snap_gap` p95/p99 看抖动。
- [ ] 若丢 tick 确实存在：先试**最保守**的两条（不改协议语义）：① `QUEUE_CAP` 上限放宽（代价：输入延迟增加，必须用 playout/延迟读数证明可接受）；② 评估“把 30Hz 合包改成 60Hz 单记录包”（字节/秒不变、包数×2：重传延迟从“2 tick 一起补”变成“1 tick”，属发包策略调整，要核对带宽与 ENet 头开销）。
- [ ] 若仍丢：写“队列满时按服务器已消费数通知客户端重放”的设计（改协议，档 3，单独评审）。

**验收：** 丢 tick 次数前后对比；若不动协议必须有数据支撑。

**边界：** 只有数据表明丢 tick 频繁才做；不为了让计数器归零而牺牲延迟；`30Hz 发包`本身不是缺陷，别把“输入 30Hz”当结论。

---

### R6 · 开火/后坐路径的预测一致性核查（先诊断，不预设修法）

**先纠正一个事实（代码复核）：后坐**是**预测的，不是“没预测”。**
- `WeaponBase.fire()` 在两端同一份 `Player._physics_process` → `weapons.tick()` 里跑，客户端本地输入直接驱动开火；
  `fire()` 末尾 `player.apply_recoil(...)` 直接改 `velocity.x`；
- 影响“哪一 tick 开火/后坐”的武器状态（`fire_cd` / `aiming` / `fire_buf` / `aim_f` / `aim_cf` / `mag` / `rld` / `rld_t`）
  都进 `capture_state()`、`restore_state()` 也会回灌（`_apply_weapon_state`）⇒ 回滚重放能复现同一发。
- ⇒ **不需要**“把后坐加入预测”这种改动；要做的是查“为什么偶尔还是差一 tick”。

**loopback 证据（2026-11-01）**：本机 loopback、无网络抖动，20s 内仍有 **2 次 `vel`-only** 回滚（A 端 0 次、B 端 2 次）。

**候选假设（按可能性）：**
1. **输入消费/ack 时序**：服务器队列消费与客户端预测的 tick 对齐差一拍（reliable 通道无丢包，但服务端仍可能因积压/首包对齐差 1 tick）；
2. **缓冲开火 / 冷却继承**：`try_fire` 的 `_fire_buffered`（长冷却武器末 20% 缓冲）在两端 tick 边界不同；
3. **命中/击退事件**：loopback 下子弹仍可能命中（环面绕回），`hit_event` 注入与 `knock_velocity` 的时序；
4. **换局/复活瞬间**：`equip`/`restore_inventory` 与开火同 tick 的竞争。

**做什么（已做完，2026-11-01）：**
- [x] 在 `--diag` 下跑 **本机 loopback 1v1**（站桩开火 2×60s），记录每次 `rollback` 的 `field` / `pos_err`
      以及回滚前后 3 tick 的 `ack` / `fire_cd` / `_fire_buffered`（诊断字段只进 diag，不进快照）。
- [x] 用同一夹具把“同 tick 开火”与“跨 tick 开火（缓冲）”分开跑，看回滚是否只在某一类出现。
- [x] 结论写进本计划；**只有确认是“时序差一拍”且能用现有 ack/队列机制解释时**，才提出改法（大概率落在 R4 或开火缓冲对齐）。
- [x] 禁止把“后坐/开火”改成服务器确认制（50ms 上手感代价不可接受，见回滚 plan 的设计边界）。

**方法（可复现，探针未入库）：** 一次性探针 `.superpowers/sdd/_gen/loopback_diag_probe.tscn`（`.superpowers/` 已 gitignore，
不进 `allscript_probe` 的编译面）—— `server_main.tscn` 起本机大厅（`127.0.0.1:7777`）→ 两个真实客户端进程
`create`/`join` → 各自实例化 `pvp_game.tscn`（真预测 + `PredictionRollback`），用 `PacketInputSource` 注入
**只开火、不按方向**（`ax` 恒 0 ⇒ 自动跳跃/迈台阶不可能触发）的输入；`CYR_DIAG=1` + 每局独立 `CYR_LOG_DIR` 收集两端
`diag-*.jsonl`。探针把每次 rollback 的**前 3 帧 + 后 3 帧**打成一行 `LBRB {…}`（`ack / gap / seq / vx / vy / pos / floor /
fire_cd / _fire_buffered / aiming / mag / rld` + 服务器 `c2` 原始整态），按 `ack` 与 diag 的 `rollback` 行对齐。
开火档三选一：`edge`（冷却归零那一 tick 开火 = 同 tick）、`buffer`（只在冷却最后 20% 窗口内按 = 跨 tick 缓冲）、
`hold`（按住 20 帧 / 松 1 帧，复现早先那次 loopback 观测）。武器每局由服务器随机发 ⇒ 每局记 `LWEAPON`（类型/冷却/heavy/auto）。

**读数（本机 loopback，1v1；表内 **9 局有效** = `edge`/`buffer` 各 2×60s + `hold` 5×20s；另有 2 局作废（探针冷启动 bug ⇒ 0 发）
与 1 局 15s 冒烟（未入表）。回滚数为 diag 逐条计数；"发数"是探针观测到的开火次数）**

| 档 | 局 | A 端（武器 / 回滚 / 字段 / 发数） | B 端（武器 / 回滚 / 字段 / 发数） |
|---|---|---|---|
| edge | 1 | 榴弹 cd1.4 / **3** / `""`×1,`down`×2 / 6 | s686 cd0.75 / **1** / `pos`×1 / 40 |
| edge | 2 | 手枪 cd0.3 / 0 / — / 154 | 激光 cd0.5 / 0 / — / 102 |
| buffer | 1、2 | （探针冷启动 bug ⇒ 两端 **0 发**，本档作废） | 同左 |
| buffer（修复后） | 3 | 巴雷特 cd1.2 / **0** / — / 8 | 激光（cd≤0.5 不能缓冲，退化） / 0 / — / 101 |
| buffer（修复后） | 4 | 手枪（同上退化） / 0 / — / 153 | 步枪 cd0.1（退化） / 0 / — / 316 |
| hold | 1 | 巴雷特 / 0 / — / 8 | 激光 / 0 / — / 11 |
| hold | 2 | s686 / **2** / `vel`×2 / 7 | 巴雷特 / 0 / — / 8 |
| hold | pre_1 | 榴弹 / **10** / `hp`×2,`down`×4,`pos`×3,`""`×1 / 2 | 手枪 / **6** / `pos`×2,`vel`×4 / 48 |
| hold | pre_2 | s686 / 1 / `""`×1 / 7 | 榴弹 / 6（探针轮询到 5）/ `hp`,`""`×2,`vel`,`down` / 2 |
| hold | pre_3 | 榴弹 / 5 / `hp`×2,`down`×2,`pos`×1 / 2 | 巴雷特 / 1 / `pos`×1 / 8 |

**归因（逐例，`LBRB` 上下文逐字对照 diag 的 `rollback` 行）**

- **A 类 · 开局前窗口（`ack` 长时间为 0）**：`hold` 第 2 局 A 的两次 `vel` 回滚在 f=59/62，而回滚前后 `ack` 一路是 **0**、
  `gap` 从 71 一路涨到 74，**第一条 ack=72 一到就触发**。同一时刻两端速度都巨大（客户端 `v=(0,7813)`、服务器 `c2.vel=(0,7733)`）
  而位置冻结在 `(3168, 2145.435)`。成因在服务器侧可读：`MatchHost` 的 `COUNTDOWN` 分支**清空输入队列 + `reset_state()`**
  （`server/match/match_host.gd:219-222`）⇒ 倒计时期间 `_ack_seq` 恒 0，客户端却在照常预测并累积 `seq`；开局第一个
  PLAYING ack 让预测环整段对不上 ⇒ 每局**最多一次** `vel` 回滚。**与开火无关**（两次都在 `fire_cd=0` 的冷枪状态）。
- **B 类 · 受击 / 倒地 / 复活（设计内）**：`down` 类的每一条 `LBRB` 里服务器 `c2` 都是 `hp=0 / down=true`
  （例：`pre_2` B f=193，服务器 `pos=(6543→6494)`、`c2.down=True`、客户端刚被传到复生点 `(6574→6491)`）；
  `pos` 类伴随 `PvpSession.spawn` 校正或复生传送（例：`edge` 第 1 局 B ack=499 时服务器一次性从 `(7534,4454)` 跳到
  `(7968,1798)`，客户端下一 ack 才跟上）；`hp` 类是挨打后服务器裁决回灌。**这些都是 C2 设计内的权威纠正**，不是要消灭的回滚。
- **C 类 · 未定案 1 例（样本量 = 1，已登记待查）**：`pre_1` B 在 f=777…803 连续 4 次 `vel`，服务器 `c2` 表现为
  “`vel.y` 每 tick +26.67（重力）连续累积、`vel.x` 按空气阻力衰减，但 `pos` 几乎不动、`hp=50 / down=false`”。
  判定与修法都需要服务器侧 `is_on_floor`/`slock` 的可观测性（当前 c2 不带 `on_floor`），本轮**未定案**。

**结论**

1. **后坐/开火没有“时序差一拍”的证据**：上表所有 `near_fire=True` 的 `vel`/`pos` 回滚，全部落在 B 类（死亡/复活窗口，
   `pre_2` B 已用 `c2.down=True` 直接证实）或 A 类（开局窗口）。4 局 60s 的**稳态**（两端合计 ≈880 发，含单端 316 发/局）
   稳态回滚 **0**；同 tick 与缓冲两种开火档都未产出稳态回滚。
2. 早先“loopback 20s 里 2 次 `vel`-only”的观测**能复现**，但归因是 **A 类开局窗口**或 **B 类战斗纠正**，**不是后坐**。
3. ⇒ **R6 不提出任何玩法改法**（尤其不改开火/后坐为服务器确认制）；R4 的“服务端丢 tick”假设在本机 13 局里 **0 条 `queue_drop`**，
   仍只能靠公网数据验。
4. 采样口径：探针轮询 `rollback_count()` 会**漏同一帧的第二次回滚**（`pre_2` B：diag 6 条 / 探针 `LBRB` 5 条）⇒
   回滚**次数**一律以 diag 的 `rollback` 行为准，探针只负责提供上下文。
5. 两条待查已登记进 `registered-debt.md` §五十二：① A 类开局窗口两端“速度累积但位置不动”的态（是否该在倒计时里冻结速度）；
   ② C 类那 1 例稳态 `vel` 分歧（需要服务器侧 `on_floor` 诊断才能定案）。

**验收：** 逐字归因见上（每例都指到 `ack`/字段/两端速度/具体帧）；无未归因的**稳态**样本，唯一 1 例（C 类）已附证据登记待查并写清下一步。

### R5 · 跨平台浮点差异（只测量，不盲改）

**猜测：** 公网测试若是“Windows 客户端 + Linux 云服务器”，`move_and_slide` 浮点结果可能极小量不同，长期累积成周期性回滚。

**做什么：**
- [ ] 记录测试拓扑（两端 OS/同一台机器？），跑 R0 场景看“静止对枪时也回滚”是否出现。
- [ ] 若确认：选项是①放宽 `_close_enough` 的 pos 容差（有误判风险）②统一物理步长/固定点（大改，先不做）③服务端同平台化部署。**只出结论与建议，不在本计划里动手。**

### R7 · 开局窗口回滚（**速度冻结已试做并回退**；实测把成因改判为"首条 ack 之前的预测起点"）

**已测事实（§R6 A 类，逐字）：** `hold` 第 2 局两次 `vel` 回滚在 f=59/62，前后 `ack` 一路是 **0**、`gap` 71→74，
首条 ack=72 一到就触发；同一时刻客户端 `v=(0,7813)`、服务器 `c2.vel=(0,7733)`，`pos` 冻结在 `(3168, 2145.435)`。

**试过什么（2026-11-01，已回退，未入库）：** 按"倒计时只冻输入、没冻状态"的猜测**两端各加一处**
`velocity = Vector2.ZERO` —— 服务器 `MatchHost` 的 COUNTDOWN 分支（`server/match/match_host.gd:219` 之后）、
客户端 `PvpMatchClient._physics_process` 的 `_round_locked` 分支。

**实测结果（本机 loopback，`ax=1` 走位 2×30s + 站桩 2×20s）：没有可分辨改善，而且上下文直接否掉了假设。**
- 走位 2 局只有 1 局正常进局（另一局 worker 没拉起、探针被超时杀掉），A 端 0 次回滚但 `walked=49px`（几乎没动）；
- 站桩 2 局：A 0/0，B 1 次（`field=""`，f=5）。
- **关键上下文（`r7_hold_1` B，逐字）**：f=2…5 时 `ack=0`、客户端**在空中**（`floor=False`，`pos.y` 91.28→92.61，
  `v.y=26.67`）；f=6 首条 ack=14 到达时客户端才落地（`pos.y=100.91`、`v=0`），而服务器同刻 `pos=(8783.929, 100.9064)`。

**真正成因（据此改判）：** 客户端出生点比"服务器已落地后的位置"**高约 9.6px**（服务器先起、已落稳；客户端后建、还在落），
并且**首条 `round_state` 到达之前 `_round_locked` 是 `false`** ⇒ 客户端在"没有权威锚点"的窗口里预测并记 capture，
首条 ack 一到必然对不上 ⇒ **每局固定一次开局回滚**。与"速度累积"无关 —— 那条只在极少数"出生点悬空"的局里额外出现
（§R6 A 类），不是普遍形态。所以**速度冻结不是修法**，已 `git checkout` 回退。

**两条候选修法（都要先设计再动，档 3；本轮不动）：**
- **候选一（最小、先做）**：客户端出生后立刻**贴地**：`pvp_game._ready` 摆完位置后把本地玩家按与服务器同一套规则落稳
  （`restart_at(spawn)` + 一帧 `move_and_slide`，或 `apply_floor_snap()`；注意 9.6px > `floor_snap_length=4` ⇒ 光靠 snap 不够）。
  判据：开局首条 ack 的两端 `pos` 差 < 2px（`_close_enough` 的非贴身容差）。
- **候选二（更根本）**：**首条 ack 之前不记 capture，且首条 ack 直接锚定**（`PredictionRollback` 加"未锚定"态：
  第一次 ack 到达时 `restore_state(S)` 并把该 ack 之前的输入丢弃，而不是判一次分歧回滚）。这会动承重面，必须逐条变异验证。
- ★ **不建议**用"初始化 `_round_locked = true`"硬锁：中途重连进 PLAYING 的客户端可能收不到 `round_state`
  （服务器只在状态变化 / COUNTDOWN 每 0.5s 重播时发）⇒ 会被永久冻住。

**为什么这轮不做：** ① `PredictionRollback` / 出生摆位都是档 3 承重面；② 本机 loopback 夹具现在**不稳定** ——
同一批里第二/三组常出现 worker 未拉起、探针被超时杀掉（`r7_walk_1/3` 两次全废）⇒ "同配置 2 次"在这里不成立。
要动 R7，先把编排稳定下来（`r6_run.ps1` 的 wait/重试逻辑，或直接把探针入库成 `run_real` 支）再谈。

**验收（重写后）：** 先有稳定夹具 → 候选一 落地 → 探针 2×30s 两次都无开局回滚 → 再考虑候选二。

**边界：** 若候选一之后仍有 1 次开局回滚但**试玩不可见**（倒计时 UI 遮屏），允许永久停在这里并登记；判据是人眼，不是计数器归零。

### R8 · 服务器侧 `on_floor` 可观测性（P2，为 §R6 C 类那 1 例定案）

**已测事实（§R6 C 类，样本量 1）：** `pre_1` B 在 f=777…803 连续 4 次 `vel`；服务器 `c2` 是
"`vel.y` 每 tick +26.67（重力）累积、`vel.x` 按空气阻力衰减，但 `pos` 几乎不动、`hp=50 / down=false`"。
当前 `c2` 不带 `on_floor`，**无法判定是"服务器认为在空中"还是"`move_and_slide` 没跑"**。

**做什么（只诊断）：**
- [ ] 服务器 worker 在 `--diag` 下加**逐 tick 采样**（只在回滚前后开窗，别常开）：`is_on_floor / state / state_lock_timer /
      velocity / global_position`，写进 `diag` 的独立 event（**不进快照、不改协议、不升 PROTO_VERSION**）。
- [ ] 探针侧按 `ack` 把服务器采样与客户端逐帧读数并排打印；复现 2×20s（同 `hold` 夹具）。
- [ ] 判据：若服务器 `on_floor=false` 而客户端 `true` ⇒ 查**地形/碰撞差异**（拆砖事件未对齐＝R2 的下游、出生点在实体内）；
      若服务器 `on_floor=true` 却仍在累积 `vel.y` ⇒ 查 `_physics_process` 里 `move_and_slide()` 之前的分支（早退/姿态锁）。

**验收：** 要么定案成具体 bug 并转成一条正式任务（带守卫），要么写明"未复现，样本量=1，按噪声处理"。

**边界：** **不许**为了消掉它去放宽 `_close_enough` 的 `vel` 容差（那会把真分歧也吞掉）；诊断字段始终不进线格式。

---

## 执行顺序建议（按"风险 × 收益"排，不代表必须照抄）

1. ~~**R7**（两端各一行）~~ → **2026-11-01 试做无效已回退**（见 §R7）：先把本机 loopback 编排稳定（重试 / 入库成 `run_real` 支），
   再按改写后的候选一（出生贴地）/ 候选二（首条 ack 直接锚定）做；
2. ✅ **R1**（P0 源头：`_auto_jump_assist` 进不了整态）—— 已完成 2026-11-01（回放确定性探针红→绿）；
3. **R2**（拆砖事件按 tick 对齐，收益最大、改动最重）→ 先用守卫证明"不产生连续回滚"再上；
4. **R3**（三处权威态应用合一，防漂移）；
5. **R8**（给 C 类定案）/ **R4**（只在公网 `queue_drop` 有读数时才动）/ **R5**（只测量、不盲改）；
6. R6 的探针若要长期用，先按 §R8 的要求升级成可复跑形态（否则每次都是手工一次性）。

---

## 结果表

**已填（2026-11-01，第一版 `ce092f9b` / 公网 120.53.107.140，详见 §R0a）**

| 场景 | 修前 rollback/局 | 修后 | 配置/日期 |
|---|---|---|---|
| 1v1 站桩开火（60s） | A4 / B20（第 1 局）、A4 / B2（第 2 局） | 待公网复测（本机 loopback 稳态已 0，见下） | 公网 / 2026-11-01 |
| 1v1 站桩+原地跳（60s） | A1 / B1、A0 / B1 | 同上 | 公网 / 2026-11-01 |
| 1v1 站桩+跳+挨打（45s） | A3 / B9（pos/hp/down） | 同上 | 公网 / 2026-11-01 |

**已填（2026-11-01，当前版本，本机 loopback，§R6 的 9 局；回滚数是 diag 逐条计数，不是探针轮询）**

| 场景 | A 端 | B 端 | 分类（movement / combat / startup） | 配置/日期 |
|---|---|---|---|---|
| 1v1 站桩开火 · 同 tick（60s） | 3 | 1 | combat 4（hp/down/pos）· **movement 0** | loopback / 2026-11-01 |
| 1v1 站桩开火 · 同 tick（60s，第 2 局） | 0 | 0 | — | loopback / 2026-11-01 |
| 1v1 站桩开火 · 跨 tick 缓冲（60s ×2 有效） | 0 | 0 | **movement 0 / startup 0** | loopback / 2026-11-01 |
| 1v1 站桩开火 · hold 节拍（20s） | 2 | 0 | startup 2（`vel`，开局 ack=0 窗口） | loopback / 2026-11-01 |
| 1v1 hold + 对枪（20s ×3） | 1–10 | 1–6 | combat 为主（`down`/`hp`/`pos`）· 1 例 `vel` 未定案（§R6 C 类） | loopback / 2026-11-01 |
| 上楼梯（16px×10） | 待测 | — | — | 本机 |
| 打穿掩体后跑过去 | 待测 | — | — | 本机 |

**待填（后续任务）：** 上表后两行（上楼梯 / 拆掩体，属 R1/R2/R3 的收益验证）+ 公网复测列（§R0b）。

## 不做（明确排除）

- 不改 beta 时间玩法；不改命中事件（已对齐）；不改房间/端口/版本号；不改相机/表现层。
- 不引入「客户端也不预测、等服务器」这类大改（会直接毁手感）。
